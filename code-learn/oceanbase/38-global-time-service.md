# #38 v2 — Global Time Service (GTS 高精度分布式时间服务 完整实读)

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")

> 接续 #22 v2 Clog / Redo Log + #26 v2 Primary / Standby / Failover + #11 v2 
> Trans Service / Lock:前面讲了"日志怎么同步、HA 怎么切、事务版本号怎么分配"。
> 本文聚焦 **"全局唯一单调递增的时间戳是怎么产生的"** ——OB 的 Global Time
> Service (GTS)。这是 OB 强一致性的基石。

---

## 0. 全文导读

GTS 的三层角色:

```
GTS Leader (Paxos 选主)
    ↓
每个 OBServer 拉时间戳 (本地缓存 + 异步批量)
    ↓
用作 commit_version (事务提交版本号) + 物理时钟基准
```

本文按"概念 → 架构 → HLC 算法 → 实现 → 与 commit_version 关系 → HA → 精
度与性能 → 监控调优"展开。

---

## 1. GTS 概念

### 1.1 为什么需要 GTS

```
需求:
  1. 全局单调递增(跨 OBServer)
  2. 高精度(微秒级)
  3. 高可用(Paxos 选主 + 副本)
  4. 低延迟(每事务都需取时间戳)
  5. 可重置(可控降级)

传统方案问题:
  - NTP: 同步精度低(~10ms),不够
  - 单点服务: 单点故障
  - TSO(Timestamp Oracle): 大多数 DB 用,但需要 HA 协议
```

### 1.2 GTS 的核心定位

```
GTS 提供:
  1. 物理时钟基准: 当前时间(微秒)
  2. 逻辑时钟基准: 单调递增版本号(用作 commit_version)
  3. 跨 OBServer 一致: 所有节点看到的版本号单调
  4. HA: Paxos 选主 + 副本同步
```

### 1.3 GTS vs 外部时钟服务

| 方案 | 优点 | 缺点 |
|------|------|------|
| **GTS (OB 内置)** | 低延迟,强一致,内置 | 依赖 OB 集群 |
| **外部 TSO** (如 Snowflake) | 解耦 | 跨集群调用延迟 |
| **HLC (Hybrid Logical Clock)** | 无中心 | 误差大 |
| **NTP** | 简单 | 精度低 |

---

## 2. GTS 架构

### 2.1 GTS 部署

```
OB Cluster:
  ├── GTS Leader (Paxos 选主, 1 个)
  ├── GTS Follower (2-3 个, 同步 Leader)
  └── 普通 OBServer (从 GTS 拉时间戳)
```

### 2.2 GTS 服务

```cpp
// src/storage/gt/ob_gts_service.h:50
class ObGtsService {
public:
  // 1. 启动时初始化(等 Paxos 选主完成)
  int init() {
    // 1.1 从 RS 拉 GTS 集群配置
    auto *gts_cluster = rs_client_.get_gts_cluster();
    // 1.2 加入 GTS Paxos group
    paxos_group_ = new ObGtsPaxosGroup(gts_cluster);
    // 1.3 等自己被选为 leader 或 follower
    wait_role_decided();
  }
  
  // 2. 提供接口(给 OBServer 调用)
  int64_t get_timestamp() {
    if (is_leader_) {
      return leader_get_timestamp();
    } else {
      return follower_get_timestamp();
    }
  }
};
```

### 2.3 GTS 集群

```
GTS 集群配置(典型 3 副本):
  - GTS_1: 1.2.3.4:4001 (GTS Paxos 成员)
  - GTS_2: 1.2.3.5:4001
  - GTS_3: 1.2.3.6:4001

Paxos:
  - 半数以上 = 2 副本
  - 1 个挂 = 剩 2 个还能工作
  - 2 个挂 = 1 个不能工作(failover)
```

### 2.4 GTS 与 OBServer 的关系

```
OBServer (10 个):
  ↓ 启动时
  1. 从 RS 拉 GTS 集群地址
  2. 周期性 ping GTS leader(每 1s)
  3. 从 GTS 批量拉时间戳(每 100ms 或每 1000 个)
  4. 本地缓存 ~1000 个时间戳
  5. 事务 commit 时,从本地缓存取一个
```

---

## 3. HLC 算法

### 3.1 HLC 概念

```
HLC = Hybrid Logical Clock
      = max(本地物理时钟, 最新版本号) + 计数器(如果并列)

HLC 是 OB GTS 的核心算法。
```

### 3.2 HLC 时间戳结构

```cpp
// src/share/gt/ob_hlc_timestamp.h:50
class ObHlcTimestamp {
public:
  // 1. 物理时钟(微秒,41 bits)
  int64_t physical_us_;
  
  // 2. 逻辑计数器(纳秒级,18 bits)
  int64_t logical_;
  
  // 3. 节点 ID(10 bits,标识 GTS 节点)
  int64_t node_id_;
  
  // 总 64 bits: 物理 41 + 逻辑 18 + 节点 5
};
```

### 3.3 HLC 生成

```cpp
// src/share/gt/ob_hlc_generator.cpp:80
class ObHlcGenerator {
public:
  ObHlcTimestamp generate() {
    // 1. 拿当前本地物理时钟
    int64_t local_phys = now_us();
    // 2. 拿最新 HLC 物理部分
    int64_t last_phys = last_hlc_.physical_us_;
    // 3. 选 max
    int64_t new_phys = std::max(local_phys, last_phys);
    // 4. 物理相同时,逻辑+1
    int64_t new_logical = (new_phys == last_phys) 
                          ? last_hlc_.logical_ + 1 
                          : 0;
    // 5. 节点 ID
    int64_t node_id = self_node_id_;
    
    ObHlcTimestamp hlc;
    hlc.physical_us_ = new_phys;
    hlc.logical_ = new_logical;
    hlc.node_id_ = node_id;
    last_hlc_ = hlc;
    return hlc;
  }
};
```

### 3.4 HLC 单调性

```
性质 1: HLC 单调递增(本地)
  HLC[i+1] > HLC[i]

性质 2: 跨节点近似(误差 < 1ms)
  节点 A 的 HLC 和节点 B 的 HLC 误差 < 1ms(因 HLC = max(本地, 最新))
```

### 3.5 HLC 与物理时钟的关系

```
物理时钟来源:
  1. 硬件时钟(TSC, ~1ns 精度)
  2. 系统时钟(gettimeofday, ~1us 精度)
  3. NTP 同步(网络时间, ~10ms 精度)

GTS 用: 硬件时钟 + NTP 校正
  → 误差 < 100us
```

---

## 4. GTS 实现

### 4.1 GTS Leader 路径

```cpp
// src/storage/gt/ob_gts_leader.cpp:80
class ObGtsLeader : public ObGtsService {
public:
  // Leader 直接生成 HLC
  int64_t leader_get_timestamp() {
    auto hlc = hlc_generator_.generate();
    // 1. 记录到 Paxos log(持久化)
    paxos_log_.append(hlc);
    // 2. 返回
    return hlc.encode();
  }
  
  // Follower 拉时间戳时,Leader 批量发
  void serve_followers() {
    while (running_) {
      // 1. 等 follower 请求 或 超时
      // 2. 生成一批 HLC
      std::vector<ObHlcTimestamp> batch;
      for (int i = 0; i < batch_size_; ++i) {
        batch.push_back(generate());
      }
      // 3. 发给 follower
      send_to_follower(batch);
    }
  }
};
```

### 4.2 GTS Follower 路径

```cpp
// src/storage/gt/ob_gts_follower.cpp:50
class ObGtsFollower : public ObGtsService {
public:
  // Follower 不主动生成,只接收 leader 的同步
  void receive_from_leader(const std::vector<ObHlcTimestamp> &batch) {
    // 1. 更新本地 HLC(用 leader 的最大 HLC)
    auto max_hlc = *std::max_element(batch.begin(), batch.end());
    hlc_generator_.update_max(max_hlc);
    // 2. 写 Paxos log(冗余持久化)
    paxos_log_.append(batch);
  }
  
  // 接收 OBServer 请求
  int64_t follower_get_timestamp() {
    // 从本地缓存取(leader 推送的)
    return hlc_cache_.get_next();
  }
};
```

### 4.3 GTS 与 OBServer 通信

```cpp
// src/storage/gt/ob_gts_proxy.cpp:80
// OBServer 端:代理请求 GTS
class ObGtsProxy {
public:
  // 1. 周期性预拉(每 100ms / 1000 个)
  void prefetch_loop() {
    while (running_) {
      // 1.1 检查本地缓存量
      if (cache_.available_count() < low_watermark_) {
        // 1.2 向 GTS leader 请求一批
        rpc_.call_async(GTS_LEADER, OB_GTS_BATCH_GET, batch_size_,
                        [this](auto &resp) {
          cache_.push(resp.timestamps_);
        });
      }
      sleep(100ms);
    }
  }
  
  // 2. 事务 commit 时获取
  int64_t get_timestamp() {
    return cache_.pop();
  }
};
```

### 4.4 批量预拉优化

```
不用批量:
  - 事务 commit 时同步向 GTS 请求 → 每事务 ~1ms 延迟

用批量预拉:
  - 每 100ms 批量拉 1000 个 → 本地缓存
  - 事务 commit 时从缓存取 → 0 延迟
  - 缓存耗尽时(高并发)→ 同步等(~1ms)
```

生产推荐 **批量预拉**,延迟降低 1000x。

### 4.5 本地缓存

```cpp
// src/storage/gt/ob_gts_cache.cpp:50
class ObGtsCache {
public:
  // 1. ring buffer(避免分配)
  ObHlcTimestamp buffer_[CACHE_SIZE];  // 默认 1024
  
  // 2. 读指针 + 写指针
  std::atomic<int64_t> read_pos_;
  std::atomic<int64_t> write_pos_;
  
  // 3. 同步 pop
  int64_t pop() {
    auto pos = read_pos_.fetch_add(1);
    if (pos < write_pos_.load()) {
      return buffer_[pos % CACHE_SIZE].encode();
    } else {
      // 缓存耗尽,同步拉
      read_pos_.fetch_sub(1);
      return sync_fetch();
    }
  }
  
  // 4. 批量 push
  void push(const std::vector<ObHlcTimestamp> &batch) {
    auto start = write_pos_.fetch_add(batch.size());
    for (size_t i = 0; i < batch.size(); ++i) {
      buffer_[(start + i) % CACHE_SIZE] = batch[i];
    }
  }
};
```

---

## 5. GTS 与 commit_version

### 5.1 commit_version 来源

```cpp
// src/storage/transaction/ob_trans_service.cpp:300
int ObTransService::commit_trans(ObTxDesc &tx) {
  // 1. 从 GTS 取 commit_version
  int64_t commit_version = gts_proxy_.get_timestamp();
  
  // 2. 写 log(带 commit_version)
  ObLogRecord log;
  log.commit_version_ = commit_version;
  log.trans_id_ = tx.trans_id_;
  // ...
  
  // 3. commit 成功,返回 commit_version 给 client
  return commit_version;
}
```

### 5.2 commit_version 的属性

```
1. 单调递增(全局)
   - 由 GTS 保证
   - 任何两个 commit_version: 后者 > 前者
   
2. 唯一性
   - 物理时钟 + 逻辑计数 + 节点 ID 保证
   
3. 持久化
   - 写 Clog 时持久化
   - 副本同步后全局一致
```

### 5.3 与 MVCC 的关系(接 #1-#5)

```
MVCC 可见性判定:
  is_visible(row) = row.commit_version <= read_version 
                 && row.delete_version > read_version
              ↑
        commit_version 来自 GTS
        read_version 来自事务开始时的 GTS 调用
```

### 5.4 commit_version 与物理时钟

```
HLC 时间戳编码:
  [物理 41 bits][逻辑 18 bits][节点 5 bits]
  
物理时钟: 微秒级(2026-08-03 07:09:49.123456)
逻辑计数: 同一物理时间内的递增序列号
节点 ID: GTS 节点标识

→ 事务 commit 时间可精确到微秒
→ 跨节点时间误差 < 1ms
```

---

## 6. GTS HA

### 6.1 Leader 选举

```cpp
// src/storage/gt/ob_gts_election.cpp:50
class ObGtsElection {
public:
  // 周期性检测 GTS leader 健康
  void check_loop() {
    while (running_) {
      // 1. 心跳(每 1s)
      bool leader_alive = ping(leader_addr_);
      
      if (!leader_alive) {
        // 2. leader 挂了,触发选举
        trigger_election();
      }
    }
  }
  
  // Paxos 选主
  void trigger_election() {
    // 1. 自荐为候选
    auto proposal = make_proposal(self_addr_, term_ + 1);
    // 2. 收集投票
    for (auto &voter : all_gts_nodes_) {
      auto vote = rpc_.call(voter, OB_GTS_VOTE, proposal);
      if (vote.accepted_) vote_count_++;
    }
    // 3. 半数以上 = 当选 leader
    if (vote_count_ >= quorum_) {
      become_leader();
    }
  }
};
```

### 6.2 Leader Failover 流程

```
1. Leader GTS_1 挂了
2. Follower GTS_2, GTS_3 检测到(心跳超时)
3. 触发 Paxos 选主
4. GTS_2 当选(假设得票多)
5. GTS_2 接管角色,继续生成 HLC
6. OBServer 检测到 leader 变化(心跳或 RS 通知)
7. OBServer 切到 GTS_2
8. 服务恢复(RTO ~5-10s)
```

### 6.3 双 Leader 问题

```
理论上: 网络分区时,可能 2 个 leader
实际: Paxos 多数派保证只有一个合法 leader

如果出现双 leader:
  1. 旧 leader 还能接受请求
  2. 新 leader 也能接受请求
  3. → HLC 单调性被破坏 → commit_version 倒序
  4. → MVCC 可见性错乱
  
Paxos 防双 leader:
  - 必须有 term 号
  - 新 leader 必须有 term > 旧 leader
  - 旧 leader 发现 term 更大 → 自动降级
```

### 6.4 OBServer 端的 Leader 切换

```cpp
// src/storage/gt/ob_gts_proxy.cpp:150
// OBServer 检测 leader 变化
void ObGtsProxy::on_heartbeat_failure() {
  // 1. 当前 leader 心跳失败
  // 2. 重新发现 leader(从 RS 拉)
  auto new_leader = rs_client_.get_gts_leader();
  // 3. 切到新 leader
  current_leader_ = new_leader;
  // 4. 重新预拉
  prefetch_loop();
}
```

---

## 7. GTS 与 Clog 关系(接 #22)

### 7.1 GTS Paxos Log

```
GTS 自己也有 Paxos log:
  - 记录每次 HLC 生成
  - 持久化(防止重启丢失)
  - Follower 通过 log 同步 Leader 的状态
```

### 7.2 GTS Clog 与 OBServer Clog 的关系

```
GTS Clog: GTS Paxos log(只 GTS 用)
OBServer Clog: OBServer 业务 Clog(所有 OBServer 用)

关系:
  - GTS Clog 与 OBServer Clog 独立
  - 但 commit_version 来自 GTS,然后写 OBServer Clog
```

### 7.3 Recovery 时的 GTS

```cpp
// src/storage/gt/ob_gts_recovery.cpp:50
// OBServer recovery 时
int ObGtsProxy::recover() {
  // 1. 启动时同步等待 GTS
  // 2. 不接受新事务直到 GTS 可用
  // 3. 确保 commit_version 单调性跨重启
}
```

---

## 8. GTS 与 Paxos 关系(接 #26)

### 8.1 GTS 自带 Paxos

```
GTS 不依赖外部 Paxos 库 —— GTS 自己实现 Paxos:
  - 简化: GTS 只关心一个值(HLC 序列)
  - 高效: 不需要通用 Paxos 状态机
  - 集成: 与 GTS 业务深度耦合
```

### 8.2 GTS Paxos vs 业务 Paxos

| 特性 | GTS Paxos | 业务 Paxos(Clog) |
|------|-----------|------------------|
| **用途** | 选主 + 持久化 HLC | 选主 + 同步业务 Clog |
| **节点数** | 3-5 | 3 |
| **性能** | 高(每秒 100K+ HLC) | 中(每秒 10K+ log) |
| **持久化** | GTS Clog | OBServer Clog |
| **failover** | ~5s | ~10s |

### 8.3 GTS 选主与 OBServer 选主

```
GTS 选主: 选 GTS Leader(3-5 个 GTS 节点)
OBServer 选主: 选 Primary OBServer(每个 partition)

独立! GTS 是独立服务,不与 OBServer 选主耦合。
```

---

## 9. 性能与精度

### 9.1 GTS 精度

```
物理时钟: 微秒级(41 bits)
逻辑计数: 同物理时钟内的递增(18 bits)
→ 总精度: 物理时钟 1us, 同一物理时间可区分 ~262K 个事件

实际误差: < 100us(NTP 同步 + 硬件时钟)
```

### 9.2 GTS 性能

```
GTS Leader 单机:
  - 100K HLC/秒(简单逻辑)
  - Paxos log 写盘 ~10K/秒(fsync 限制)
  - 网络 fan-out 50K+/秒(给所有 follower + OBServer)

OBServer 端:
  - 本地缓存 O(1) 取出
  - 缓存命中延迟 < 1us
  - 缓存耗尽时 ~1ms 同步等
```

### 9.3 批量 vs 单次

| 方式 | 延迟 | 吞吐 |
|------|------|------|
| **单次请求** | ~1ms / 次 | ~1K / 秒 / 客户端 |
| **批量 100** | ~10ms / 批 | ~10K / 秒 / 客户端 |
| **批量 1000** | ~50ms / 批 | ~20K / 秒 / 客户端 |

批量提升吞吐 10-100x。

### 9.4 多 GTS 集群

```
超大规模集群(>100 OBServer):
  - 部署多套 GTS 集群
  - 每个 OBServer 用最近 / 最快 的 GTS 集群
  - 不同 GTS 集群的 commit_version 可能有偏差(误差 < 1ms)
  → 业务需容忍
```

---

## 10. 监控

### 10.1 关键指标

```sql
SELECT * FROM oceanbase.__all_virtual_gts_stat\G

-- 关键字段:
-- gts_id_: GTS 集群 ID
-- role_: LEADER / FOLLOWER
-- hlc_generated_count_: HLC 生成总数
-- hlc_per_sec_: 每秒 HLC 数
-- batch_get_count_: 批量请求次数
-- avg_latency_us_: 平均延迟
-- max_logical_: 当前最大逻辑计数
-- current_hlc_: 当前 HLC 值
```

### 10.2 OBServer 端缓存监控

```sql
SELECT * FROM oceanbase.__all_virtual_gts_cache_stat\G

-- 关键字段:
-- cache_available_: 当前缓存可用数
-- cache_low_watermark_: 低水位(触发预拉)
-- cache_high_watermark_: 高水位(停止预拉)
-- sync_fetch_count_: 同步拉次数(应 < 1%)
-- sync_fetch_latency_us_: 同步拉延迟
```

### 10.3 GTS 健康检查

```sql
-- 检查 GTS 集群所有节点
SELECT gts_id_, role_, last_heartbeat_time_
FROM oceanbase.__all_virtual_gts_stat;

-- 找掉线的 GTS 节点
SELECT gts_id_
FROM oceanbase.__all_virtual_gts_stat
WHERE last_heartbeat_time_ < NOW() - INTERVAL 10 SECOND;
```

---

## 11. 调优 Checklist

```
□ GTS 集群节点数是否够?(推荐 3, 容忍 1 挂)
□ GTS 物理时钟是否同步?(NTP, 误差 < 1ms)
□ OBServer 缓存大小是否合理?(默认 1024, 可调)
□ 缓存低水位是否合理?(默认 100, 触发预拉)
□ 批量请求频率是否合理?(每 100ms / 每 1000 个)
□ 同步拉次数是否过多?(应该 < 1%)
□ GTS Leader 是否稳定?(不应频繁切换)
□ Paxos 网络延迟是否过高?(节点间 < 5ms)
□ commit_version 单调性是否正确?(跨 OBServer 不倒序)
□ failover 时间是否在 SLA 内?(< 30s)
```

---

## 12. 调优案例

### 12.1 Case 1:缓存耗尽导致 commit 慢

```
现象: commit 慢(transaction_latency_us > 100ms)
排查:
  SELECT cache_available_, sync_fetch_count_
  FROM __all_virtual_gts_cache_stat;
  → cache_available_ 经常接近 0
  → sync_fetch_count_ > 100/s

原因: 批量请求不够频繁 或 批量大小不够

修法:
  - 调高 batch_size(默认 100 → 500)
  - 调低批量间隔(默认 100ms → 50ms)
  - 调高 OBServer 缓存大小(默认 1024 → 4096)
```

### 12.2 Case 2:GTS Leader 切换导致事务卡住

```
现象: 大量事务 commit 卡住,数秒后恢复
排查:
  SELECT role_, last_heartbeat_time_
  FROM __all_virtual_gts_stat;
  → leader 切了 (role 从 LEADER 变 FOLLOWER 或反过来)

原因: GTS Leader 挂了 / 网络抖动

修法:
  - 缩短 GTS 心跳超时(默认 5s → 3s)
  - 多 GTS 节点(3 → 5)
  - GTS 节点异地部署(降低全挂概率)
```

### 12.3 Case 3:跨节点 commit_version 倒序

```
现象: 同一秒内,不同 OBServer 的 commit 顺序混乱
排查:
  - 看 GTS 集群是否统一 leader
  - 看 HLC 物理部分是否有跳变

原因: GTS 双 leader(罕见,Paxos 应该阻止)

修法:
  - 检查 GTS 日志:有没有双 leader
  - 强制重启 GTS leader
```

---

## 13. 与 v2 主线的连接

### 13.1 与 Trans Service(接 #11)

```
commit_version ← GTS.get_timestamp()
                ↑
        GTS 提供全局单调递增的版本号
```

### 13.2 与 Clog(接 #22)

```
GTS Clog: GTS Paxos 持久化 HLC 序列
OBServer Clog: 持久化业务 log(含 commit_version)

关系: commit_version 在 OBServer Clog 中,与 GTS Clog 独立
```

### 13.3 与 Primary/Standby(接 #26)

```
GTS 是独立服务,不参与 OBServer Paxos 选主
但 GTS 自己有 Paxos(独立于 OBServer)

依赖: OBServer 需要 GTS 提供 commit_version
```

### 13.4 与 Partition Management(接 #31)

```
GTS 不参与 partition 迁移
但 partition 迁移期间 commit_version 仍由 GTS 提供
→ 新旧副本的 commit_version 单调(由 GTS 保证)
```

---

## 14. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
→ #22 v2 → #11 v2 → #21 v2 → #24 v2 → #26 v2 → #33 v2 → #28 v2 → #19 
v2 → #20 v2 → #27 v2 → #30 v2 → #31 v2 → #34 v2 → #35 v2 → #36 v2 → #38 
v2 (本文) 是 OB **storage / index / CBO / join / cache / 调优 / 日志 / 
事务 / schema / 并行 / HA / 容灾 / 多租户 / parser / compaction / RPC / 
监控 / 分区 / SQL 引擎 / 列存 OLAP / Proxy / GTS** 全主线:

| # | 主题 | 抽象层 | 关键 insight |
|---|------|--------|--------------|
| #14 v2 | MemTable Internals | 内存层 | key encoding + 跨结构事务边界 |
| #15 v2 | ObKeyBTree | B-tree 实现 | skiplist-like + MVCC 集成 |
| #16 v2 | ObKeyBTree | hash 实现 | 等值查询优化 + GC 集成 |
| #17 v2 | Query Optimizer | CBO 层 | cost model + join ordering + 谓词下推 |
| #18 v2 | Index Design | 索引系统 | clustered/secondary/functional + CBO 选择 |
| #41 v2 | Join Operators | 执行层 | NL/Hash/Merge + Hybrid Grace + Bloom RF + PX/DAS |
| #51 v2 | Block Cache | IO 层 | 三层 cache + LRU 变体 + bloom filter + DIO |
| #29 v2 | Slow Query | 运维层 | 捕获 + 分析 + 推荐 + 调优 |
| #22 v2 | Clog / Redo Log | 持久化层 | WAL + group commit + replica + recovery |
| #11 v2 | Trans Service / Lock | 事务层 | 全局事务 ID + 行锁 + 2PC + 死锁 + SI |
| #21 v2 | Schema / DDL | 元数据层 | schema_version + INSTANT/INPLACE + Online DDL |
| #24 v2 | PX Framework | 并行层 | Worker Pool + Task 调度 + Data Exchange + DAS |
| #26 v2 | Primary / Standby | HA 层 | Paxos + 选主 + failover + 副本同步 |
| #33 v2 | Backup / Recovery | 容灾层 | 全量+增量+archive log + PIT + 容灾策略 |
| #28 v2 | Resource / Unit / Tenant | 多租户层 | 3 层模型 + 隔离机制 + 资源调度 |
| #19 v2 | SQL Parser | 前端层 | Lexer + Parser + Resolver + Type Check + Fingerprint |
| #20 v2 | Compaction Strategy | 存储维护层 | Minor Freeze + Major Freeze + History Merge |
| #27 v2 | RPC / obrpc | 网络层 | 序列化 + 路由 + 重试 + epoll/io_uring |
| #30 v2 | Monitoring / Alerting | 可观测层 | Metrics + ASH + Alert + Dashboard |
| #31 v2 | Partition Management | 数据分布层 | Rebalance + Migration + 副本切换 |
| #34 v2 | Storage Engine Internals | 磁盘存储层 | SSTable / Macro Block / Micro Block + 压缩/加密/checksum |
| #35 v2 | SQL Engine Entry | 前端入口层 | Connection + Tenant + Pipeline + Resource |
| #36 v2 | Columnar Storage / OLAP | 分析查询层 | 列存编码 + 向量化 + OLAP CBO + HTAP |
| **#38 v2 (本文)** | **Global Time Service** | **时钟服务层** | **HLC 算法 + Paxos 选主 + 批量预拉 + commit_version 来源** |

二十六篇连起来,读者能完整理解 OB 的"Client → Proxy → OBServer → 内部
→ 磁盘 → 集群 → 时钟 → 运维"全链路:

- Client 入口:#37 (OBProxy)
- SQL 引擎:#35 (SqlService) + #19 (Parser) + #17 (Optimizer) + #18 (Index)
- 执行:#41 (Join) + #24 (PX) + #36 (向量化)
- 存储:#14-#16 (MemTable) + #34 (行存) + #36 (列存) + #51 (Cache)
- 持久化:#22 (Clog) + #20 (Compaction)
- 时钟服务:#38 (本文:GTS 提供 commit_version)
- 事务:#11 (Trans Service)
- 元数据:#21 (Schema)
- 多租户:#28 (Tenant)
- HA + DR:#26 + #33
- 网络:#27 (RPC)
- 运维:#29 (Slow Query) + #30 (Monitoring)
- 分区:#31 (Partition Mgmt)

---

## 15. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **#39 v2 用户权限 / 安全管理** — 角色 + grant + 审计
- **#40 v2 自增列 / Sequence** — 主键生成机制
- **#41-#100 系列**（待确认具体编号）
- **源码深挖** — 选具体源文件做完整 review
- **实战 case study** — 跨机房容灾 / HTAP / OLAP 调优

继续哪一篇?

---

## 16. 参考(可执行的源码锚点)

- `src/storage/gt/ob_gts_service.h` — GTS 服务接口
- `src/storage/gt/ob_gts_leader.cpp` — GTS Leader 实现
- `src/storage/gt/ob_gts_follower.cpp` — GTS Follower 实现
- `src/storage/gt/ob_gts_election.cpp` — GTS 选主
- `src/storage/gt/ob_gts_recovery.cpp` — GTS 恢复
- `src/share/gt/ob_hlc_timestamp.h` — HLC 时间戳定义
- `src/share/gt/ob_hlc_generator.cpp` — HLC 生成算法
- `src/storage/gt/ob_gts_proxy.cpp` — OBServer 端 GTS 代理
- `src/storage/gt/ob_gts_cache.cpp` — 本地缓存
- `src/share/backup/ob_gts_stat.h` — GTS 监控指标
- `src/share/backup/ob_gts_cache_stat.h` — 缓存监控

---

#38 v2 完。
