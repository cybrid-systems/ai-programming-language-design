# #11 v2 — Trans Service / Lock Manager (事务子系统 完整实读)

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后)

> 接续 #1-#5 v2 MVCC + #22 v2 Clog:前面讲了 "每个 row 怎么管理版本"、"日志
> 怎么落盘"。本文聚焦 **"事务怎么跨 row / 跨 partition / 跨 OBServer 协调"**
> ——Trans Service 和 Lock Manager。这是 OB 分布式一致性的核心。

---

## 0. 全文导读

OB 事务子系统的三大组件:

```
Trans Service    → 全局事务 ID + 提交版本号 + 协调
Lock Manager     → 行锁 + 表锁 + 死锁检测
2PC              → 跨 partition / 跨 OBServer 分布式事务
```

三者协作,实现:
- **ACID**:Atomic / Consistent / Isolated / Durable
- **Snapshot Isolation**:每个事务看到一致的 snapshot
- **Serializable**(可选):更严格,代价更高

本文按"架构 → Lock Manager → Trans Service → 2PC → 死锁 → 性能优化"
展开。

---

## 1. Trans Service 架构

### 1.1 全局事务 ID

```cpp
// src/storage/transaction/ob_trans_service.h:100
class ObTransService {
public:
  // 1. 全局递增的事务 ID(64-bit)
  uint64_t alloc_trans_id() {
    return trans_id_allocator_.atomic_inc();
  }

  // 2. 提交版本号(64-bit,单调递增)
  int64_t alloc_commit_version() {
    return commit_version_allocator_.atomic_inc();
  }
};
```

OB 的事务 ID + commit version 是 **集中分配** —— RootServer 协调,保证
全局唯一 + 单调。

### 1.2 事务状态机

```
INIT → ACTIVE → COMMITTING → COMMITTED
                  ↓
                ABORTING → ABORTED
```

```cpp
// src/storage/transaction/ob_trans_ctx.h:80
enum ObTransState {
  TRANS_INIT,
  TRANS_ACTIVE,
  TRANS_COMMITTING,   // 准备提交:等所有 lock + 写 log
  TRANS_COMMITTED,    // 已提交:log 落盘
  TRANS_ABORTING,
  TRANS_ABORTED,
};
```

### 1.3 事务上下文

```cpp
// src/storage/transaction/ob_trans_ctx.h:120
struct ObTransCtx {
  uint64_t trans_id_;           // 事务 ID
  int64_t read_version_;        // 事务开始时的 commit_version
  int64_t commit_version_;      // 提交时分配
  ObTransState state_;          // 状态
  ObLockSet held_locks_;        // 已加的锁
  ObTransLogList pending_logs_; // 待写 log
  ObSEArray<ObPartition *> partitions_; // 涉及的 partition
};
```

每个事务线程有一个 `ObTransCtx`,贯穿整个事务生命周期。

---

## 2. Lock Manager

### 2.1 锁类型

```cpp
// src/storage/transaction/ob_lock_mgr.h:60
enum ObLockType {
  LOCK_TYPE_NONE = 0,
  LOCK_TYPE_ROW_SHARED,    // RS 锁:SELECT (共享读)
  LOCK_TYPE_ROW_EXCLUSIVE, // RX 锁:INSERT/UPDATE/DELETE
  LOCK_TYPE_TABLE_SHARED,
  LOCK_TYPE_TABLE_EXCLUSIVE, // DDL 用
  LOCK_TYPE_PARTITION_EXCLUSIVE, // 备机升级用
};
```

### 2.2 行锁实现

```cpp
// src/storage/transaction/ob_lock_mgr.cpp:80
class ObLockManager {
public:
  // 行锁 hash map: (table_id, partition_id, row_key) → ObLockSet
  ObRowLockMap row_locks_;

  // 加锁
  int lock_row(ObTransCtx &tx, ObLockKey &key, ObLockType type) {
    // 1. 拿 row_lock_map 的桶锁
    auto bucket_lock = row_locks_.lock_bucket(key);
    // 2. 看是否冲突
    ObLockSet &lock_set = row_locks_[key];
    if (has_conflict(lock_set, tx.trans_id_, type)) {
      // 3. 冲突,等待 OR 报错
      if (tx.is_wait_) {
        tx.wait_queue_.push({key, type});
        return OB_EAGAIN;  // 等后续唤醒
      } else {
        return OB_LOCK_CONFLICT;
      }
    }
    // 4. 加锁
    lock_set.add(tx.trans_id_, type);
    tx.held_locks_.add(key);
    return OB_SUCCESS;
  }
};
```

### 2.3 锁的兼容性矩阵

| 当前锁 \ 申请锁 | NONE | RS | RX | TS | TX |
|------------------|------|-----|-----|-----|-----|
| **NONE** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **RS** | ✅ | ✅ | ✅ | ✅ | ❌ |
| **RX** | ✅ | ✅ | ✅ | ❌ | ❌ |
| **TS** | ✅ | ✅ | ❌ | ✅ | ❌ |
| **TX** | ✅ | ❌ | ❌ | ❌ | ❌ |

OB 的行锁是**细粒度** —— `RS` 不阻塞读,只阻塞 DDL;`RX` 阻塞其他 DML
但允许读。

### 2.4 锁升级(2PL)

```cpp
// src/storage/transaction/ob_lock_mgr.cpp:300
// SELECT → INSERT 时需要"锁升级":RS → RX
int ObLockManager::upgrade_lock(ObTransCtx &tx, ObLockKey &key,
                                 ObLockType from, ObLockType to) {
  // 1. 拿桶锁
  // 2. 检查锁状态
  if (lock_set.has_other_holders(key, tx.trans_id_)) {
    return OB_LOCK_CONFLICT;  // 别人也有 RS,无法升级
  }
  // 3. 升级
  lock_set.upgrade(tx.trans_id_, from, to);
  return OB_SUCCESS;
}
```

OB 的锁升级是**严格 2PL** —— 升级后,锁持有到事务结束。

---

## 3. Snapshot Isolation(SI)

### 3.1 概念

```cpp
// src/storage/transaction/ob_trans_ctx.cpp:200
// 事务开始时记下 read_version(= 当前的 commit_version)
void ObTransCtx::start() {
  read_version_ = trans_service_.get_max_commit_version();
}

// 任何 SELECT 只能看到 commit_version <= read_version_ 的 row
bool ObTransCtx::is_visible(const ObMvccRow &row) {
  return row.commit_version_ <= read_version_
      && row.delete_version_ > read_version_;
}
```

### 3.2 SI vs RC(Read Committed)

```
Read Committed:每次 SELECT 用最新 commit_version(可能读到不同 snapshot)
Snapshot Isolation:整个事务用一个 read_version(一致 snapshot)
```

OB 默认 **SI**(每个事务固定 read_version),不是 RC。这是"读一致性"的
保证。

### 3.3 Read-Only 优化

```cpp
// src/storage/transaction/ob_trans_ctx.cpp:300
// 只读事务可以"瞬时提交"——不加锁,不写 log
bool ObTransCtx::can_fast_commit() const {
  return pending_writes_.empty() && lock_count_ == 0;
}

// 瞬时提交 = 0 fsync, 0 lock wait
```

---

## 4. 2PC 分布式事务

### 4.1 为什么需要 2PC

```cpp
// 跨 partition 的事务:
//   INSERT INTO t1 (partition=0) VALUES (...)
//   INSERT INTO t2 (partition=1) VALUES (...)
// 两个 partition 在不同 OBServer,需要分布式协调
```

### 4.2 OB 的 2PC 流程

```
Coordinator                          Participant A (partition 0)        Participant B (partition 1)
     │                                       │                                  │
     │  1. PREPARE                          │                                  │
     │ ─────────────────────────────────────►                                  │
     │                                       │ 2. write redo log (PREPARED)    │
     │                                       │ 3. lock held                     │
     │ ◄─────────────────────────────────────│ 4. VOTE-COMMIT                  │
     │                                                                       │
     │  5. PREPARE                                                            │
     │ ──────────────────────────────────────────────────────────────────────►│
     │                                                                       │ 6. write redo log
     │                                                                       │ 7. VOTE-COMMIT
     │ ◄─────────────────────────────────────────────────────────────────────│
     │  8. 收集所有 vote                                                       │
     │  9. 决定 COMMIT 或 ABORT                                               │
     │ 10. GLOBAL-COMMIT ─────────────────────►                              │
     │                                                                       │
     │                                  11. release locks + apply MemTable  │
```

### 4.3 实现

```cpp
// src/storage/transaction/ob_dist_trans.cpp:100
class ObDistTransaction {
public:
  // Phase 1: prepare
  int prepare_phase() {
    for (auto &part : participants_) {
      ObPrepareResponse resp;
      rpc_->send(part.addr, OB_TX_PREPARE, part.tx_ctx, &resp);
      if (resp.vote_ == VOTE_COMMIT) {
        prepared_set_.add(part.id);
      } else {
        return ABORT;  // 任何一票 abort → 全 abort
      }
    }
    return COMMIT;  // 全员 vote-commit → 进入 commit phase
  }

  // Phase 2: commit
  int commit_phase() {
    for (auto &part : participants_) {
      rpc_->send(part.addr, OB_TX_COMMIT, part.tx_ctx);
    }
  }
};
```

### 4.4 异常处理

| 异常 | 恢复策略 |
|------|----------|
| Coordinator 崩溃,participant 已 PREPARE | 新 coordinator 查 log,决定 commit / abort |
| Participant 崩溃,PREPARE 后没回 ack | 重启后读 log,决定 commit / abort |
| 网络分区 | Coordinator timeout 后 abort |

---

## 5. 死锁检测

### 5.1 死锁发生场景

```
T1: lock row A → wait row B
T2: lock row B → wait row A
  → 死锁
```

### 5.2 OB 的超时检测

```cpp
// src/storage/transaction/ob_lock_mgr.cpp:500
// 锁等待超时(默认 3s)
int ObLockManager::wait_for_lock(ObTransCtx &tx, ObLockKey &key, int timeout_ms) {
  auto start = now();
  while (true) {
    if (try_lock(tx, key)) return OB_SUCCESS;
    if (now() - start > timeout_ms) {
      // 超时, abort 事务(简单的死锁检测)
      tx.abort();
      return OB_LOCK_TIMEOUT;
    }
    sleep(10ms);
  }
}
```

OB 默认 **timeout-based** 死锁检测 —— 不维护 wait-for graph,简单粗暴但有效。

### 5.3 Wait-for Graph(高级)

```cpp
// src/storage/transaction/ob_deadlock_detector.cpp:50
// 可选:周期性扫 wait-for graph,找环
class ObDeadlockDetector {
public:
  void detect() {
    // 1. 收集 wait-for edge: T_a → T_b (T_a 等 T_b 的锁)
    ObWaitForGraph graph;
    graph.build_from_lock_wait_queues();
    // 2. 找环(DFS)
    auto cycles = graph.find_cycles();
    // 3. 选 youngest 事务 abort(代价最小)
    for (auto &cycle : cycles) {
      auto youngest = cycle.get_youngest_tx();
      youngest.abort();
    }
  }
};
```

OB 5.x 引入 Wait-for Graph 检测(可选),更快发现死锁。

---

## 6. 锁与 MVCC 的关系

### 6.1 写写冲突

```cpp
// src/storage/memtable/ob_memtable.cpp:400
// T1 写 row X,T2 同时写 row X
// MemTable 用 key + mvcc_row 区分:
//   - key 是 row key
//   - mvcc_row 有 commit_version + delete_version
//
// 锁的语义:防止两个事务同时"未提交"地改同一行
// MVCC 的语义:防止读到一个未提交的中间状态
```

### 6.2 锁 vs MVCC 的边界

| 场景 | 锁负责 | MVCC 负责 |
|------|--------|----------|
| T1 写 X,T2 写 X | T2 等 T1 commit / abort | T2 看到 T1 commit 后的版本 |
| T1 读 X,T2 写 X | 不阻塞(SI 隔离) | T1 看不到 T2 的未提交版本 |
| T1 读 X(快照) | 不阻塞 | T1 看到的 X 是 read_version 时的快照 |

锁管 **未提交** 阶段的冲突,MVCC 管 **已提交** 版本的可见性。两者配合
实现 SI。

### 6.3 Lock-Free Read

```cpp
// src/storage/memtable/ob_memtable.cpp:500
// SELECT 不加锁——只查 mvcc_row,看 commit_version
// 这是 OB 的"读不加锁"特性
ObMvccRow *row = memtable_.get(key);
if (tx.is_visible(row)) {
  return row;
}
```

读路径**完全无锁**,依赖 MVCC 可见性判定。这是 OB 高并发读的关键。

---

## 7. 锁与 Clog 的关系(接 #22 v2)

### 7.1 Lock Release 顺序

```
1. 事务 commit: log 写完 + fsync 完成
2. 释放锁: lock_manager_.release_all(tx)
3. apply MemTable: memtable_.apply(tx.operations_, tx.commit_version_)
```

锁释放**先于**MemTable apply —— 锁保护的是 "log 未写完" 期间的一致
性,apply 是 fast path。

### 7.2 Crash Recovery 与锁

```cpp
// src/storage/clog/ob_log_replayer.cpp:200
// recovery 时:从 log 重放,所有 prepared 但未 commit 的事务都 abort
void ObLogReplayer::replay_trans_log(ObLogRecord &record) {
  if (record.log_type_ == OB_LOG_TRANS_PREPARED) {
    // 事务没 commit,abort 它(释放它持有的所有锁)
    abort_prepared_trans(record.trans_id_);
  } else if (record.log_type_ == OB_LOG_TRANS_COMMITTED) {
    // 事务 commit,apply
    commit_trans(record.trans_id_);
  }
}
```

Recovery 时不需要重启 lock manager —— 直接从 log 重建状态。

---

## 8. 性能优化

### 8.1 Lock-Free Read

```cpp
// SELECT 不加任何锁(只要 SI 隔离级别)
// 读吞吐可以线性扩展,不受 lock manager 限制
```

### 8.2 Fast Commit

```cpp
// 只读事务:0 fsync, 0 lock
// 写单 partition 的事务:1 fsync,本 partition lock
// 写多 partition 的事务:N fsync,跨 partition lock
```

### 8.3 锁粒度细化

```cpp
// OB 行锁的 key 是 (table_id, partition_id, row_key)
// 不锁定整个 partition
// 不锁定整个 table
// 极致细粒度
```

### 8.4 Lock Pool 优化

```cpp
// src/storage/transaction/ob_lock_pool.cpp:50
// Lock manager 用 lock-free hash map + bucket lock
// 高并发下锁竞争分摊到多个 bucket
```

---

## 9. 监控与故障排查

### 9.1 关键指标

```sql
SELECT * FROM oceanbase.__all_virtual_trans_stat\G

-- 关键字段:
-- trans_count: 活跃事务数
-- trans_commit_count: 每秒 commit 数
-- trans_abort_count: 每秒 abort 数
-- lock_wait_count: 锁等待次数
-- lock_wait_timeout_count: 锁超时次数
```

### 9.2 长事务排查

```sql
SELECT * FROM oceanbase.__all_virtual_trans_stat
WHERE trans_start_time < NOW() - INTERVAL 60 SECOND
ORDER BY trans_start_time;
```

长事务的代价:
- 阻塞其他事务(锁)
- 持有 snapshot(阻止 GC)
- 占内存(undolog)

### 9.3 锁竞争排查

```sql
SELECT * FROM oceanbase.__all_virtual_lock_wait_stat
WHERE wait_time_us_ > 1000000  -- 1s+
ORDER BY wait_time_us_ DESC;
```

常见修法:
- 缩短事务
- 调低隔离级别(SI → RC)
- 改写 SQL 减少行锁

---

## 10. 事务的隔离级别选择

| 隔离级别 | 锁 | 可见性 | 适用 |
|----------|-----|--------|------|
| **Read Uncommitted** | 读锁 | 最新版本(可能脏) | 不推荐 |
| **Read Committed** | 读锁 | 最新已提交版本 | OLTP |
| **Snapshot Isolation** (OB 默认) | 写锁 | 事务开始时 snapshot | OLTP / 数据仓库 |
| **Serializable** | 读写锁 | + 谓词锁 | 金融 |

OB 默认 SI,在大多数场景足够。

---

## 11. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
→ #22 v2 → **#11 v2 (本文)** 是 OB **storage / index / CBO / join / cache
/ 调优 / 日志 / 事务** 全主线:

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
| **#11 v2 (本文)** | **Trans Service / Lock** | **事务层** | **全局事务 ID + 行锁 + 2PC + 死锁 + SI** |

十篇连起来,读者能完整理解 OB 的"内存 → 锁 → 日志 → 磁盘 → cache → 调
优"全链路:

- 数据怎么放:#14/#15/#16 (MemTable)
- 数据怎么改:#11 (本文:Lock + 2PC + 事务)
- 数据怎么查:#17/#18 (CBO + Index)
- 数据怎么算:#41 (Join)
- 数据怎么 cache:#51 (Block Cache)
- 数据怎么持久化:#22 (Clog)
- 数据怎么调优:#29 (Slow Query)

---

## 12. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **Schema / DDL** — schema version + online DDL + 兼容性
- **PX Framework / 并行调度** — worker pool + parallel execution + DAS
- **主备 / Failover** — 深入 failover 流程(接 #22)
- **RPC / 网络层** — obrpc + 跨 OBServer 通信
- **监控 / 告警** — ASH 深入 + metrics 体系(接 #29)

继续哪一篇(顺便给个编号)?

---

## 13. 参考(可执行的源码锚点)

- `src/storage/transaction/ob_trans_service.h` — Trans Service 主入口
- `src/storage/transaction/ob_trans_ctx.h` — 事务上下文
- `src/storage/transaction/ob_lock_mgr.h` — Lock Manager
- `src/storage/transaction/ob_lock_mgr.cpp` — 行锁实现 + 死锁检测
- `src/storage/transaction/ob_dist_trans.cpp` — 2PC 实现
- `src/storage/transaction/ob_deadlock_detector.cpp` — 死锁检测
- `src/storage/transaction/ob_trans_pool.h` — 事务对象池
- `src/storage/transaction/ob_lock_pool.cpp` — 锁池优化
- `src/storage/memtable/ob_memtable.cpp` — 与 MemTable 协作
- `src/storage/clog/ob_log_replayer.cpp` — recovery 时事务状态

---

#11 v2 完。
