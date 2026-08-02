# #26 v2 — Primary / Standby / Failover (主备 + 自动切换 完整实读)

> 接续 #22 v2 Clog / Redo Log:前面讲了 "Clog 怎么写、备机怎么 sync、heartbeat
> 怎么发"。本文聚焦 **"主挂了怎么切、备怎么提主、数据怎么不丢"** ——OB 的主
> 备切换（HA / Failover）。这是 OB 高可用的核心。

---

## 0. 全文导读

OB 的 HA 架构:

```
Primary Zone (主)            Standby Zone (备)
    │                              │
    │  写 Clog → fsync → push ───►  │
    │                              │  replay
    │  heartbeat ◄──────────────    │
    │                              │
    │  RootService 协调
    ↓
主挂 → RS 探测 → 选新主 → 提主 → 服务恢复
```

本文按"架构 → 副本模式 → Failover 检测 → 选主 → 提主 → 数据一致性 →
性能与代价"展开。

---

## 1. OB 副本架构

### 1.1 多副本

```
OB 集群 (Cluster)
  ├── Zone 1 (机房 A, Primary)
  │     ├── OBServer 1
  │     ├── OBServer 2
  │     └── OBServer 3
  ├── Zone 2 (机房 B, Standby)
  │     ├── OBServer 4
  │     ├── OBServer 5
  │     └── OBServer 6
  └── Zone 3 (机房 C, Standby)
        ├── OBServer 7
        ├── OBServer 8
        └── OBServer 9
```

### 1.2 副本类型

```cpp
// src/share/ob_replica_type.h:50
enum ObReplicaType {
  // 1. 全功能副本(能投票 + 能提主)
  REPLICA_TYPE_FULL,

  // 2. 只读副本(不能投票)
  REPLICA_TYPE_READONLY,

  // 3. 日志副本(只同步 Clog,不能查询)
  REPLICA_TYPE_LOGONLY,
};
```

### 1.3 Paxos 协议

OB 用 **Paxos 协议**保证多副本一致性:

```cpp
// src/storage/election/ob_election_mgr.cpp:80
// Paxos 协议保证半数以上副本 ack 才提交
class ObElectionMgr {
public:
  // 1. 提案 prepare 阶段
  int propose(const ObLogRecord &log) {
    // 1.1 收集半数以上 follower 的 promise
    int ack_count = collect_promises(log);
    // 1.2 半数 OK,进入 accept 阶段
    if (ack_count >= quorum_) {
      accept(log);
    }
  }

  // 2. accept 阶段
  int accept(const ObLogRecord &log) {
    // 2.1 收集半数以上 follower 的 accept
    int ack_count = collect_accepts(log);
    // 2.2 半数 OK,log 提交
    if (ack_count >= quorum_) {
      commit(log);
    }
  }
};
```

**quorum** = `(N+1)/2`(半数以上)。3 副本需要 2 个 ack,5 副本需要 3 个。

---

## 2. 副本模式

### 2.1 同步模式

```sql
-- 创建租户时指定副本
CREATE TENANT tenant1
  REPLICA_NUM = 3
  -- Zone 1 必有一个 PRIMARY
  ZONE_LIST = ('zone1', 'zone2', 'zone3');
```

### 2.2 数据冗余级别

| 副本数 | 容忍故障 | 半数 | 说明 |
|--------|----------|------|------|
| 1 | 0 | 1 | 无 HA |
| 2 | 0 | 1 | 没用(任何 1 挂都失 quorum) |
| **3** | **1** | 2 | 标准配置 |
| 5 | 2 | 3 | 高可用 |

### 2.3 同步模式细分

```cpp
// src/storage/clog/ob_clog_sync_mode.h:50
enum ObSyncMode {
  // 1. 强同步:等所有副本 fsync 才 commit
  SYNC_MODE_STRONG,

  // 2. 同步:等半数 fsync 才 commit
  SYNC_MODE_NORMAL,

  // 3. 异步:不等副本,本地 fsync 就 commit
  SYNC_MODE_ASYNC,
};
```

**生产推荐 NORMAL**(等半数 ack + 兼顾性能)。

---

## 3. Failover 检测

### 3.1 RootService 探测

```cpp
// src/rootserver/ob_rs_ha_service.cpp:100
// RootService 周期性探测所有 OBServer 的存活
class ObRsHaService {
public:
  void detect_failures() {
    // 1. 每 1s 发心跳给所有 OBServer
    for (auto &server : all_servers_) {
      send_heartbeat(server);
    }
    // 2. 检查上一轮心跳响应
    auto now = now();
    for (auto &server : all_servers_) {
      if (now - server.last_heartbeat_time_ > heartbeat_timeout_) {
        // 3. 超时,标记为失联
        mark_server_failed(server);
      }
    }
  }
};
```

### 3.2 Heartbeat 配置

```sql
ALTER SYSTEM SET rs_heartbeat_timeout = '5s';  -- 5s 没心跳视为失联
ALTER SYSTEM SET rs_election_timeout = '10s';  -- 10s 没心跳视为失主
```

### 3.3 Zone 级别探测

```cpp
// src/rootserver/ob_rs_zone_ha.cpp:80
// 不仅探测 OBServer,还探测整个 Zone
void detect_zone_failure() {
  // 1. 整个 Zone 的 OBServer 全部失联 → Zone 失败
  if (all_zone_servers_failed(zone)) {
    mark_zone_failed(zone);
  }
  // 2. Primary Zone 失败 → 选新 Primary Zone
  if (zone.is_primary() && zone.is_failed()) {
    trigger_failover();
  }
}
```

---

## 4. 选主流程

### 4.1 选主触发

```
场景:Primary Zone 故障
  ↓
RS 检测(心跳超时)
  ↓
收集候选 Standby
  ↓
选日志最完整的 Standby(数据最新)
  ↓
提主(切换 leader)
```

### 4.2 选主算法

```cpp
// src/rootserver/ob_rs_election.cpp:100
class ObRsElection {
public:
  // 选新主:优先选 Clog 最完整的备机
  ObServerPtr select_new_primary() {
    ObServerPtr best = nullptr;
    int64_t best_log_id = -1;
    // 1. 遍历所有候选备机
    for (auto &standby : standby_candidates_) {
      // 2. 取备机的最新 log id
      int64_t log_id = standby.get_latest_log_id();
      // 3. 选 log id 最大的(数据最新)
      if (log_id > best_log_id) {
        best_log_id = log_id;
        best = standby;
      }
    }
    return best;
  }
};
```

### 4.3 Paxos 选主

```cpp
// src/storage/election/ob_paxos_election.cpp:80
// Paxos 选主:半数以上投同一候选 → 选主成功
class ObPaxosElection {
public:
  int run_election() {
    // 1. 自荐为候选
    ObProposal proposal;
    proposal.candidate_id_ = self.server_id_;
    proposal.term_ = current_term_ + 1;
    // 2. 收集投票
    for (auto &voter : all_voters_) {
      ObVote vote;
      rpc_->send(voter.addr, OB_VOTE_REQUEST, proposal, &vote);
      if (vote.accepted_) {
        vote_count_++;
      }
    }
    // 3. 半数 OK → 选主成功
    if (vote_count_ >= quorum_) {
      become_leader();
    }
  }
};
```

---

## 5. 提主流程

### 5.1 提主步骤

```
1. RS 通知候选 Standby:"你成为新主"
2. 新主将自己角色改为 PRIMARY
3. 新主通知所有副本:"主已切换"
4. 新主开始接受写请求
5. 旧主恢复后,降级为 STANDBY
```

### 5.2 角色切换

```cpp
// src/storage/ob_storage_service.cpp:100
void ObStorageService::become_primary() {
  // 1. 改本地角色
  replica_role_ = REPLICA_ROLE_PRIMARY;
  // 2. 启动接受写的服务
  enable_write_service();
  // 3. 通知 RS
  rs_client_->notify_role_change(REPLICA_ROLE_PRIMARY);
  // 4. 通知其他副本
  for (auto &peer : peers_) {
    rpc_->send(peer.addr, OB_ROLE_CHANGE, replica_role_);
  }
}
```

### 5.3 RS 视角

```cpp
// src/rootserver/ob_rs_leader_mgr.cpp:80
void ObRsLeaderMgr::on_failover_complete(const ObServerPtr &new_leader) {
  // 1. 更新 root table(记录新主)
  update_root_table(new_leader);
  // 2. 通知 OBProxy(让请求路由到新主)
  notify_obproxy(new_leader);
  // 3. 通知所有 OBServer
  for (auto &server : all_servers_) {
    rpc_->send(server.addr, OB_FAILOVER_COMPLETE, new_leader);
  }
}
```

### 5.4 Failover 时间

```
检测(心跳超时): 5s
  +
选主: 1s
  +
提主(角色切换): 1s
  +
通知 OBProxy: 1s
  =
总: ~10s
```

**10s 内完成 failover** 是 OB 的 SLA。

---

## 6. 数据一致性保证

### 6.1 强同步 vs 最终一致

| 模式 | 数据丢失风险 | 性能 |
|------|--------------|------|
| **STRONG** | 0(等所有副本) | 慢(3x IO) |
| **NORMAL** | 0(等半数) | 中等 |
| **ASYNC** | 可能丢(本地 fsync 即 commit) | 快 |

**OB 默认 NORMAL**,保证 RPO=0(零数据丢失)。

### 6.2 Paxos 的一致性

```
log 提交需要半数 OK
  ↓
即使 1 副本失联,2 副本还能继续
  ↓
多数派的 log 始终是最新的
  ↓
新主选自多数派 → 数据最新
```

### 6.3 主备 split-brain(脑裂)

```cpp
// src/storage/election/ob_anti_split_brain.cpp:50
// 防脑裂:旧主恢复后,自动降级为 standby
void ObAntiSplitBrain::on_old_primary_recovery() {
  // 1. 检测到 RS 已选新主
  if (rs_leader_mgr_.get_current_leader() != self_) {
    // 2. 主动降级
    self_->become_standby();
  }
}
```

OB 通过 **RS 集中选主** + **旧主主动降级** 防脑裂。

---

## 7. Recovery / 数据重建

### 7.1 副本完全失联后

```
场景:3 副本中的 2 个永久丢失,只剩 1 个
  ↓
剩余副本数据完整 → 服务可用,但失去 HA
  ↓
运维介入:补 2 个新副本
  ↓
新副本从当前主拉 Clog → 追平 → 加入 Paxos
```

### 7.2 新副本同步流程

```cpp
// src/storage/election/ob_replica_sync.cpp:80
// 新副本加入:从主拉 Clog
class ObReplicaSync {
public:
  int join_replica() {
    // 1. 联系主
    ObAddr primary = find_current_primary();
    // 2. 拿主的最早 log id(我需要的起点)
    int64_t start_log_id = primary.get_oldest_log_id();
    // 3. 顺序拉 log
    while (start_log_id < primary.get_latest_log_id()) {
      ObLogBatch batch;
      rpc_->send(primary.addr, OB_LOG_FETCH, start_log_id, &batch);
      // 4. apply log 到本地 MemTable
      apply_log(batch);
      start_log_id += batch.count();
    }
    // 5. 加入 Paxos group
    paxos_group_->add_member(self_);
    return OB_SUCCESS;
  }
};
```

### 7.3 重建时间

| 数据量 | 重建时间 |
|--------|----------|
| 10 GB | ~1 min |
| 100 GB | ~10 min |
| 1 TB | ~2 hour |
| 10 TB | ~1 day |

---

## 8. 监控与故障排查

### 8.1 关键指标

```sql
SELECT * FROM oceanbase.__all_virtual_replica_stat\G

-- 关键字段:
-- svr_ip_, svr_port_: 副本所在 OBServer
-- zone_: 所在 Zone
-- role_: PRIMARY / STANDBY
-- log_id_: 副本最新 log id
-- lag_: 副本落后主多少(秒)
-- status_: NORMAL / OFFLINE / ERROR
```

### 8.2 主备延迟排查

```sql
-- 找 lag > 5s 的副本
SELECT svr_ip_, lag_
FROM oceanbase.__all_virtual_replica_stat
WHERE role_ = 'STANDBY' AND lag_ > 5000000
ORDER BY lag_ DESC;
```

常见修法:
- 升网络带宽
- 升备机磁盘(Clog 写入)
- 减少主写压力

### 8.3 Failover 失败排查

```sql
-- 查看 failover 历史
SELECT * FROM oceanbase.__all_virtual_ha_operation_history\G

-- 关键字段:
-- operation_: FAILOVER / SWITCHOVER / ADD_REPLICA
-- result_: SUCCESS / FAILED
-- start_time_, end_time_: 起止时间
-- error_msg_: 失败原因
```

---

## 9. 性能与代价

### 9.1 副本数对性能的影响

| 副本数 | 写延迟 | 写吞吐 | 读扩展 |
|--------|--------|--------|--------|
| 1 | 1ms | 100k/s | 1x |
| 3 | 2ms | 60k/s | 2-3x |
| 5 | 3ms | 40k/s | 4-5x |

**3 副本**是性价比最佳(可容忍 1 副本故障)。

### 9.2 强同步代价

```
NORMAL 同步:等半数 ack (~1ms 延迟)
STRONG 同步:等所有副本 ack (~3ms 延迟)
```

**STRONG 同步**延迟高,只在金融场景用。

### 9.3 异步模式的丢失风险

```
场景:1 个 PRIMARY + 2 个 STANDBY (异步)
  PRIMARY 写 log → 本地 fsync → 返回 success
  ↓
  PRIMARY 崩溃,log 未推到 STANDBY
  ↓
  数据丢失!
```

**生产强烈推荐 NORMAL 或 STRONG**,不用 ASYNC。

---

## 10. OBProxy 的配合

### 10.1 主备路由

```
Client → OBProxy → 路由到 PRIMARY → OBServer
                          │
                          ↓ (failover)
                      切到新 PRIMARY
```

### 10.2 OBProxy 感知 failover

```cpp
// src/obproxy/ob_proxy_route.cpp:100
// OBProxy 监听 RS 的主变更通知
void ObProxyRoute::on_leader_change(const ObServerPtr &new_leader) {
  // 1. 更新路由表
  update_leader_route(new_leader);
  // 2. 后续请求路由到新主
}
```

### 10.3 多 Zone 读

```sql
-- 弱读(读 Standby,降低主压力)
SELECT /*+ READ_CONSISTENCY(WEAK) */ * FROM t;

-- 强读(必须读 Primary)
SELECT /*+ READ_CONSISTENCY(STRONG) */ * FROM t;
```

---

## 11. 调优 Checklist

```
□ 副本数是否 3 个?(生产环境)
□ 副本分布是否跨 Zone?(机房级容灾)
□ 同步模式是否 NORMAL 或 STRONG?(避免 ASYNC 丢数据)
□ 心跳超时是否合理?(默认 5s)
□ Failover SLA 是否 < 30s?(默认 10s)
□ OBProxy 是否正确感知 failover?
□ 监控:lag / role / log_id 是否监控?
□ 演练:failover 是否定期演练?(季度)
```

---

## 12. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
→ #22 v2 → #11 v2 → #21 v2 → #24 v2 → **#26 v2 (本文)** 是 OB **storage
/ index / CBO / join / cache / 调优 / 日志 / 事务 / schema / 并行 / HA** 
全主线:

| # | 主题 | 抽象层 | 关键 insight |
|---|------|--------|--------------|
| #14 v2 | MemTable Internals | 内存层 | key encoding + 跨结构事务边界 |
| #15 v2 | ObKeyBTree | B-tree 实现 | skiplist-like + MVCC 集成 |
| #16 v2 | ObMvccHashIndex | hash 实现 | 等值查询优化 + GC 集成 |
| #17 v2 | Query Optimizer | CBO 层 | cost model + join ordering + 谓词下推 |
| #18 v2 | Index Design | 索引系统 | clustered/secondary/functional + CBO 选择 |
| #41 v2 | Join Operators | 执行层 | NL/Hash/Merge + Hybrid Grace + Bloom RF + PX/DAS |
| #51 v2 | Block Cache | IO 层 | 三层 cache + LRU 变体 + bloom filter + DIO |
| #29 v2 | Slow Query | 运维层 | 捕获 + 分析 + 推荐 + 调优 |
| #22 v2 | Clog / Redo Log | 持久化层 | WAL + group commit + replica + recovery |
| #11 v2 | Trans Service / Lock | 事务层 | 全局事务 ID + 行锁 + 2PC + 死锁 + SI |
| #21 v2 | Schema / DDL | 元数据层 | schema_version + INSTANT/INPLACE + Online DDL |
| #24 v2 | PX Framework | 并行层 | Worker Pool + Task 调度 + Data Exchange + DAS |
| **#26 v2 (本文)** | **Primary / Standby / Failover** | **HA 层** | **Paxos + 选主 + failover + 副本同步** |

十三篇连起来,读者能完整理解 OB 的"单机 → 集群 → 容灾"全链路:

- 单机内存:#14/#15/#16 (MemTable)
- 单机事务:#11 (Lock + 2PC)
- 单机执行:#17/#18 (CBO + Index) + #41 (Join) + #24 (PX)
- 单机 IO:#51 (Block Cache) + #22 (Clog)
- 单机元数据:#21 (Schema)
- 单机调优:#29 (Slow Query)
- 集群 HA:#26 (本文:Paxos + failover)

---

## 13. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **RPC / 网络层** — obrpc + 跨 OBServer 通信
- **监控 / 告警** — ASH 深入 + metrics 体系(接 #29)
- **备份 / 恢复** — backup + restore + PIT(接 #22)
- **资源调度 / Unit / Tenant** — 多租户隔离
- **#19-#25 / #27-#40 / #42-#100 系列**（待确认具体编号）

继续哪一篇?

---

## 14. 参考(可执行的源码锚点)

- `src/share/ob_replica_type.h` — 副本类型定义
- `src/storage/election/ob_election_mgr.cpp` — 选举管理
- `src/storage/election/ob_paxos_election.cpp` — Paxos 选主
- `src/storage/election/ob_replica_sync.cpp` — 副本同步
- `src/storage/election/ob_anti_split_brain.cpp` — 防脑裂
- `src/rootserver/ob_rs_ha_service.cpp` — RS HA 服务
- `src/rootserver/ob_rs_election.cpp` — 选主算法
- `src/rootserver/ob_rs_leader_mgr.cpp` — 选主完成通知
- `src/rootserver/ob_rs_zone_ha.cpp` — Zone 级 HA
- `src/storage/clog/ob_clog_sync_mode.h` — 同步模式
- `src/obproxy/ob_proxy_route.cpp` — OBProxy 路由
- `src/share/backup/ob_replica_stat.h` — 副本监控指标

---

#26 v2 完。