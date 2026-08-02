# #31 v2 — Partition Management / Rebalance / Migration (分区管理 完整实读)

> 接续 #26 v2 Primary / Standby / Failover + #28 v2 Resource / Unit / Tenant +
> #24 v2 PX Framework:前面讲了"主备怎么切、租户怎么隔离、并行怎么调度"。本文
> 聚焦 **"数据怎么从一个 OBServer 搬到另一个、负载怎么均衡"** ——OB 的分区管
> 理与 rebalance。

---

## 0. 全文导读

OB Partition Management 三层:

```
Partition 定义      →  partition key + partition function + partition count
Rebalance           →  load-based + zone-aware 自动均衡
Migration           →  source → target 数据搬迁
```

本文按"Partition 概念 → Rebalance 策略 → Migration 流程 → 副本切换 → 监
控调优"展开。

---

## 1. Partition 概念

### 1.1 Partition Key

```sql
-- 创建分区表
CREATE TABLE orders (
  id INT,
  user_id INT,
  create_time TIMESTAMP,
  PRIMARY KEY (id)
) PARTITION BY HASH(user_id) PARTITIONS 16;
```

OB 的 partition key 决定数据分布:
- **HASH 分区**: `partition_id = hash(partition_key) % N`
- **RANGE 分区**: 按 partition_key 范围划分
- **KEY 分区**: MySQL 风格,KH hash

### 1.2 Partition 函数

```cpp
// src/share/partition/ob_partition_func.h:50
class ObPartitionFunc {
public:
  virtual int64_t eval(const ObObj &key) = 0;
};

// HASH 实现
class ObHashPartitionFunc : public ObPartitionFunc {
public:
  int64_t eval(const ObObj &key) override {
    return key.hash() % partition_count_;
  }
};

// RANGE 实现
class ObRangePartitionFunc : public ObPartitionFunc {
public:
  int64_t eval(const ObObj &key) override {
    // 二分找 key 在哪个 range
    return find_range(key, partition_ranges_);
  }
};
```

### 1.3 Partition 元数据

```cpp
// src/share/schema/ob_partition_schema.h:80
class ObPartitionSchema {
public:
  uint64_t partition_id_;           // 全局唯一
  common::ObString partition_name_;
  ObPartitionFunc *part_func_;
  // partition 所在的副本
  common::ObSEArray<ObReplicaLocation, 3> replicas_;
};

struct ObReplicaLocation {
  ObAddr server_;        // 副本所在 OBServer
  int64_t role_;         // PRIMARY / STANDBY
  int64_t replica_id_;   // 副本 ID
  int64_t log_id_;       // 最新 log id
};
```

### 1.4 Tablet 与 Partition 关系

```
partition 1
  ├── tablet 1.1 (zone 1 的副本) ← ObTabletHandle
  ├── tablet 1.2 (zone 2 的副本)
  └── tablet 1.3 (zone 3 的副本)

partition 2
  ├── tablet 2.1
  ├── tablet 2.2
  └── tablet 2.3
```

每个 partition 有 1~N 个 tablet(取决于副本数)。

---

## 2. Rebalance 策略

### 2.1 Rebalance 触发

```sql
-- 自动触发(后台)
-- 默认:心跳检测 + 负载检测

-- 手动触发
ALTER SYSTEM REBALANCE ZONE 'z1';
ALTER SYSTEM REBALANCE TENANT tenant1;
ALTER SYSTEM REBALANCE PARTITION p1;
```

### 2.2 触发条件

```cpp
// src/rootserver/ob_rebalance_service.cpp:80
class ObRebalanceService {
public:
  // 周期性检查
  void check_rebalance() {
    // 1. 各 OBServer 负载差异 > 阈值(默认 20%)
    if (server_load_imbalance_() > 0.2) trigger_rebalance();
    // 2. 某些 partition 数据过大(> 100GB)
    if (any_partition_too_large()) trigger_rebalance();
    // 3. 某些 OBServer 资源耗尽
    if (any_server_overloaded()) trigger_rebalance();
  }
};
```

### 2.3 负载计算

```cpp
// src/rootserver/ob_load_calculator.cpp:50
struct ObServerLoad {
  double cpu_usage_;         // CPU 使用率
  double memory_usage_;      // 内存使用率
  double disk_usage_;        // 磁盘使用率
  double iops_usage_;        // IOPS 使用率
  double bandwidth_usage_;   // 网络带宽使用率
  int64_t partition_count_;  // partition 数
  int64_t tablet_count_;     // tablet 数

  double composite_score() {
    // 加权综合得分
    return 0.3 * cpu_usage_ + 0.3 * memory_usage_ +
           0.2 * iops_usage_ + 0.1 * disk_usage_ +
           0.1 * bandwidth_usage_;
  }
};
```

### 2.4 Zone 感知

```cpp
// Rebalance 保持副本在指定 zone 内(跨 zone 不移动)
class ObZoneAwareRebalance {
public:
  // 1. 副本必须在指定的 zone list 内
  // 2. 同 partition 的副本必须在不同 zone
  // 3. Rebalance 不破坏副本分布约束
};
```

---

## 3. Migration 流程

### 3.1 整体流程

```
1. RS 决策:选 source + target
2. 通知 source:开始迁移 partition P
3. 通知 target:接收 partition P
4. 双写阶段:source 写一份到 target
5. 快照 + 同步:source 拍快照 + 同步增量
6. 切流量:target 接管,source 停止
7. 清理 source:删除数据
8. 完成
```

### 3.2 实现细节

```cpp
// src/storage/ob_partition_migrator.cpp:80
class ObPartitionMigrator {
public:
  int migrate_partition(const ObPartitionDesc &src, const ObAddr &target) {
    // 1. 准备阶段
    src.freeze_for_migration();   // 冻结写入
    // 2. 快照阶段:source 拍 SSTable 快照
    auto snapshot = src.snapshot();
    // 3. 传输阶段:RPC 把 SSTable 发到 target
    rpc_->send(target, OB_PARTITION_MIGRATE, snapshot);
    // 4. 增量同步:持续拉 source 的 log
    while (src.has_pending_logs()) {
      auto logs = src.fetch_pending_logs();
      rpc_->send(target, OB_PARTITION_MIGRATE_LOG, logs);
    }
    // 5. 等 target 应用到 log_id_ 追上
    wait_target_synced();
    // 6. 切换:target 接管 primary
    target.promote_to_primary();
    src.demote_to_standby();
    // 7. 清理 source
    src.remove_data();
    return OB_SUCCESS;
  }
};
```

### 3.3 快照 + 增量同步

```cpp
// src/storage/ob_migration_snapshot.cpp:50
// 快照 = SSTable 全集(只读视图)
class ObMigrationSnapshot {
public:
  // 1. 拿所有 SSTable 的硬链接
  // 2. 不复制数据,只引用(快)
  // 3. 增量 log:从 snapshot 时点开始
  int64_t snapshot_log_id_;  // snapshot 时的 log id
};
```

### 3.4 切换原子性

```
切换阶段:
  1. 冻结 target 写入
  2. target apply 到 source 的最新 log id
  3. 切换 root_table:source P → target P
  4. 通知 OBProxy:更新路由
  5. 解冻 target
  6. 失败回滚:source 仍可用
```

切换是 **原子** —— 要么 source 接管,要么 target 接管。

---

## 4. 副本切换(Promotion)

### 4.1 触发场景

```
1. 主动迁移(运维发起)
2. Rebalance 自动调度
3. 故障切换(主挂,接 #26)
```

### 4.2 Promotion 流程

```cpp
// src/storage/ob_partition_promoter.cpp:80
class ObPartitionPromoter {
public:
  int promote_to_primary(const ObTabletHandle &tablet) {
    // 1. 校验:tablet 数据最新(比当前 primary 新)
    if (tablet.log_id_ < current_primary_log_id_) {
      return OB_ERR_NOT_LATEST;
    }
    // 2. 角色切换
    tablet.role_ = REPLICA_ROLE_PRIMARY;
    // 3. 通知 RS:更新 root_table
    rs_client_->update_root_table(tablet.partition_id_, tablet.server_);
    // 4. 通知 OBProxy:新主在哪
    obproxy_->update_route(tablet.partition_id_, tablet.server_);
    // 5. 启动接受写服务
    tablet.enable_write_service();
    return OB_SUCCESS;
  }
};
```

### 4.3 Demotion 流程

```cpp
int demote_to_standby(const ObTabletHandle &tablet) {
  // 1. 拒绝新写入
  tablet.disable_write_service();
  // 2. 等待活跃事务结束
  tablet.wait_active_trans_done();
  // 3. 角色切换
  tablet.role_ = REPLICA_ROLE_STANDBY;
  // 4. 通知 RS
  rs_client_->update_role(tablet.partition_id_, tablet.server_, STANDBY);
  return OB_SUCCESS;
}
```

---

## 5. 迁移期间的事务一致性

### 5.1 迁移期间的双写

```cpp
// src/storage/transaction/ob_migration_tx.cpp:50
// 迁移期间,source 和 target 都接受写(双写)
class ObMigrationDualWrite {
public:
  int on_write(const ObWriteOp &op) {
    // 1. 写 source(原主)
    src_tablet_.write(op);
    // 2. 同时写 target(新主)
    target_tablet_.write(op);
    // 3. 等两边都 commit
    return OB_SUCCESS;
  }
};
```

### 5.2 锁的考虑

```
迁移期间:
  - 旧主:继续持有事务
  - 新主:接收新事务
  - 协调:由 RS 保证不冲突
```

### 5.3 失败回滚

```
迁移失败场景:
  1. snapshot 失败 → 直接退出(source 仍可用)
  2. RPC 传输失败 → retry,直到成功 or 超时
  3. target apply 失败 → 回滚 source(target 仍 standby)
  4. 切换时 panic → RS 检测 + 强制回滚到 source
```

---

## 6. Rebalance 算法

### 6.1 贪心算法

```cpp
// src/rootserver/ob_greedy_rebalancer.cpp:80
class ObGreedyRebalancer {
public:
  // 1. 计算当前负载
  ObLoadMap current_load = compute_current_load();
  // 2. 找最重的 server 和最轻的 server
  ObAddr heaviest = find_heaviest(current_load);
  ObAddr lightest = find_lightest(current_load);
  // 3. 从 heaviest 搬一个 partition 到 lightest
  while (current_load[heaviest] - current_load[lightest] > threshold_) {
    auto partition = pick_partition_to_move(heaviest, lightest);
    migrate(partition, heaviest, lightest);
    current_load = recompute(current_load);
  }
};
```

### 6.2 Zone-aware Greedy

```cpp
// 不能跨 zone 移动(副本分布约束)
// 只在 zone 内做平衡
class ObZoneAwareRebalancer {
public:
  // 1. 对每个 zone 分别做平衡
  for (auto &zone : zones_) {
    balance_within_zone(zone);
  }
};
```

### 6.3 多约束 Rebalance

```
约束:
  - 副本数 = N
  - 同 partition 的副本在不同 zone
  - 同 zone 内 partition 数量均衡
  - 不移动正在 compact / 迁移中的 partition
```

### 6.4 影响最小化

```cpp
// 选迁移时机:业务低峰期
int ObRebalanceScheduler::pick_rebalance_time() {
  // 1. 统计历史负载曲线
  // 2. 选负载 < 30% 的时段
  // 3. 默认凌晨 2-6 点
};
```

---

## 7. 监控与调优

### 7.1 关键指标

```sql
SELECT * FROM oceanbase.__all_virtual_partition_migration_stat\G

-- 关键字段:
-- partition_id_: 哪个 partition 在迁
-- src_server_: source
-- dst_server_: target
-- status_: PENDING / DOING / DONE / FAILED
-- progress_: 0-100%
-- migrated_size_bytes_: 已迁移字节
-- elapsed_time_us_: 耗时
```

### 7.2 集群负载

```sql
SELECT * FROM oceanbase.__all_virtual_server_load\G

-- 关键字段:
-- svr_ip_, svr_port_: 哪个 OBServer
-- cpu_used_, memory_used_, disk_used_
-- partition_count_, tablet_count_
-- composite_score_: 综合负载得分
```

### 7.3 Rebalance 历史

```sql
SELECT * FROM oceanbase.__all_virtual_rebalance_history\G

-- 关键字段:
-- start_time_, end_time_: 何时发生
-- type_: AUTO / MANUAL
-- moved_partition_count_: 搬了多少 partition
-- trigger_: LOAD_IMBALANCE / OVERLOAD / MANUAL
```

### 7.4 调优参数

```sql
-- Rebalance 阈值
ALTER SYSTEM SET rebalance_threshold = '0.2';  -- 负载差异 20% 触发

-- 并发迁移数
ALTER SYSTEM SET max_migration_concurrent = '4';

-- 迁移限速
ALTER SYSTEM SET migration_rate_limit = '100MB/s';

-- Rebalance 时间窗
ALTER SYSTEM SET rebalance_window = '02:00:00-06:00:00';
```

---

## 8. 迁移的代价与影响

### 8.1 业务影响

| 阶段 | 业务影响 |
|------|----------|
| snapshot | 短暂 freeze(几秒) |
| 传输 | 双倍 IO(读 source + 写 target) |
| 增量同步 | 持续(几秒到几小时) |
| 切换 | < 1s(原子切换) |
| 清理 | 后台异步 |

### 8.2 网络流量

```
1 TB 数据迁移(快照) ~ 几小时 @ 100MB/s
增量同步 ~ 每秒几 MB(取决于写压力)
```

### 8.3 何时不该 Rebalance

```
- 业务高峰(IO 已经被占)
- compact / backup 期间
- failover 期间
- 大事务运行期间
```

---

## 9. 与 v2 主线的连接

### 9.1 与 #26 Primary / Standby

迁移本质上是**完整的副本切换** —— source → target 的角色转换。

### 9.2 与 #28 Tenant

每个 tenant 独立的 partition list,Rebalance 按 tenant 分别调度。

### 9.3 与 #22 Clog

迁移的增量同步是**Clog 流复制** —— 接 #22。

### 9.4 与 #11 Trans Service

迁移期间的 lock + 事务协调接 #11。

### 9.5 与 #27 RPC

迁移过程大量 RPC 调用(snapshot + 增量 log + 切换通知)—— 接 #27。

---

## 10. 调优 Checklist

```
□ Rebalance 阈值是否合理?(默认 20%,可调)
□ 迁移并发数是否合理?(默认 4,避免抢业务 IO)
□ 迁移限速是否合理?(默认 100MB/s)
□ 是否避开业务高峰?(rebalance_window 配置)
□ 监控:迁移进度 + 失败告警
□ 失败回滚机制是否生效?
□ Zone 内 partition 数量是否均衡?
□ Rebalance 期间业务延迟是否在 SLA 内?
□ 演练:迁移是否定期演练?
```

---

## 11. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
→ #22 v2 → #11 v2 → #21 v2 → #24 v2 → #26 v2 → #33 v2 → #28 v2 → #19 
v2 → #20 v2 → #27 v2 → #30 v2 → **#31 v2 (本文)** 是 OB **storage / 
index / CBO / join / cache / 调优 / 日志 / 事务 / schema / 并行 / HA / 容
灾 / 多租户 / parser / compaction / RPC / 监控 / 分区** 全主线:

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
| **#31 v2 (本文)** | **Partition Management** | **数据分布层** | **Rebalance + Migration + 副本切换** |

二十篇连起来,读者能完整理解 OB 的"单机 → 集群 → 分布式"全链路:

- 单机内部:#14-#24 (storage/index/optimizer/join/PX)
- 持久层:#22 (Clog) + #20 (Compaction)
- 事务层:#11 (Trans Service)
- 元数据:#21 (Schema)
- 多租户:#28 (Tenant)
- HA + DR:#26 + #33
- 网络:#27 (RPC)
- 运维:#29 (Slow Query) + #30 (监控告警)
- 数据分布:#31 (本文)

---

## 12. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **Storage Engine Internals** — SSTable / macro_block / micro_block 深入(接 #51)
- **SQL Engine Entry** — 接收 / 派发 / 路由(接 #19 + #24)
- **#32-#40 / #42-#100 系列**（待确认具体编号）

继续哪一篇?

---

## 13. 参考(可执行的源码锚点)

- `src/share/partition/ob_partition_func.h` — Partition 函数
- `src/share/schema/ob_partition_schema.h` — Partition 元数据
- `src/rootserver/ob_rebalance_service.cpp` — Rebalance 服务
- `src/rootserver/ob_load_calculator.cpp` — 负载计算
- `src/rootserver/ob_greedy_rebalancer.cpp` — 贪心 Rebalance
- `src/storage/ob_partition_migrator.cpp` — Migration 实现
- `src/storage/ob_migration_snapshot.cpp` — Snapshot
- `src/storage/ob_partition_promoter.cpp` — Promotion
- `src/storage/transaction/ob_migration_tx.cpp` — 迁移期间事务
- `src/share/backup/ob_partition_migration_stat.h` — 监控指标
- `src/share/backup/ob_server_load.h` — Server 负载
- `src/share/backup/ob_rebalance_history.h` — Rebalance 历史

---

#31 v2 完。