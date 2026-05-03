# 36-concurrency-control — OceanBase 并发控制框架深度分析：MVCC GC、锁模式、隔离级别

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

OceanBase 的并发控制是一个多层次、多组件的复杂系统。从前 35 篇文章中我们已经覆盖了 MVCC Row（01）、Write Conflict（03）、Conflict Handler（16）等关键模块。本文将这些模块统一到**并发控制框架**的视角下，补充分析剩余的四个核心组件：

1. **ObMultiVersionGarbageCollector** — 多版本垃圾回收。决定哪些旧版本可以被安全回收，在"保留长事务快照"和"及时释放存储空间"之间取得平衡。
2. **ObRowLatch** — 行级自旋锁。MVCC 写操作的最小保护单元，TAS（test-and-set）实现。
3. **ObLockWaitMgr** — 锁等待管理器。分布式环境下管理行锁/表锁/事务锁的等待队列，支持本地唤醒与远程 RPC 唤醒。
4. **ObTableLockService / ObOBJLock** — 表级锁系统。LOCK TABLE 语句的实现，与 Oracle 兼容的 5 种锁模式。

### 架构总览

```
                      ┌──────────────────────────────────────────┐
                      │          SQL / DAS Layer                 │
                      │   (ObDMLService, ObTableScan, ObSQL)    │
                      └────────┬──────────────┬──────────────────┘
                               │               │
                   ┌──────────▼─────┐    ┌────▼───────┐
                   │  Row Conflict  │    │ Table Lock │
                   │   Handler     │    │  Service   │
                   │ (ob_row_      │    │(ob_table_  │
                   │  conflict_    │    │ lock_      │
                   │  handler.cpp) │    │ service.h) │
                   └────────┬─────┘    └────┬────────┘
                            │               │
                   ┌────────▼──────────────▼───┐
                   │      ObLockWaitMgr        │
                   │  (ob_lock_wait_mgr.h)     │
                   │  — 锁等待队列管理         │
                   │  — 本地/远程唤醒          │
                   │  — 死锁检测               │
                   └────────┬──────────────────┘
                            │
              ┌─────────────┼─────────────┐
              ▼             ▼             ▼
       ┌──────────┐ ┌──────────┐ ┌──────────────┐
       │ ObRowLatch│ │ ObMvccRow│ │ ObMultiVersion│
       │(行自旋锁) │ │(版本链表) │ │GarbageCollector│
       └──────────┘ └──────────┘ └──────────────┘
              │              │              │
              ▼              ▼              ▼
       ┌──────────────────────────────────────────┐
       │  Memtable / SSTable (MVCC 数据存储)      │
       │  旧版本                                  │
       │  ┌──────┐ ←─ ┌──────┐ ←─ ┌──────┐      │
       │  │补丁√ │    │补丁√ │    │最新  │      │
       │  └──────┘    └──────┘    └──────┘      │
       └──────────────────────────────────────────┘
                ▲ 可回收（GC）                ▲ 保留
                │                             │
                └── global_reserved_snapshot ─┘
```

**整体协作流程**（以 DML 写操作为例）：

```
1. SQL 层发起写入请求
2. DAS 层调用 ObMemtable::lock / ObMemtable::mvcc_write
3. ObMvccRow::mvcc_write_ 获取 ObRowLatch（行自旋锁）
4. 遍历版本链表，检查写写冲突
5. 若冲突 → ObRowConflictHandler → ObLockWaitMgr 入队等待
6. 若成功写入 → 注册回调（ObITransCallback）
7. 事务提交 → Paxos 日志同步 → 设置 F_COMMITTED
8. ObLockWaitMgr 唤醒等待者
9. ObMultiVersionGarbageCollector 定期扫描，回收不可见的旧版本
```

---

## 1. ObMultiVersionGarbageCollector — 多版本垃圾回收

### 1.1 设计目标

OceanBase 的多版本 GC 源自一个根本矛盾：**事务可以随意延迟，但数据存储不能无限膨胀**。长事务（long-running transaction）需要保留旧的快照版本；若 GC 太激进，长事务的数据可见性被破坏；若 GC 太保守，版本链条过长拖慢查询性能并浪费磁盘。

**三个规则**（来自 `ob_multi_version_garbage_collector.h` L126-131 源码注释的翻译）：

1. **所有不可能再被读取的数据必须尽快回收**
2. **所有可能被读取的数据必须被保留**
3. **保证异常场景下用户可理解的恢复行为**

### 1.2 核心概念：最小活跃事务快照（Min Active Snapshot Version）

GC 的逻辑非常简单：**保留所有活跃事务可能看到的版本**，回收其他版本。核心就是**找到当前系统中所有活动事务的最小快照版本号**，该版本之前的数据（除了最新版本）都是安全的回收目标。

```
时间轴 →
  ───┬──────┬──────┬──────┬──────┬──────┬────▶
     V1     V2     V3     V4     V5     V6
                ↑                          ↑
           Txn A 的快照             Txn B 的快照
          (snapshot=当前时间)    (snapshot=当前时间)
                                         
    └────── 可回收 ──────┘    └────── 不可回收 ──────┘
    （所有事务都看不到）       （可能有事务需要）
```

### 1.3 四种快照类型

```cpp
// ob_multi_version_garbage_collector.h:55-63
enum ObMultiVersionSnapshotType : uint64_t
{
  MIN_SNAPSHOT_TYPE         = 0,
  MIN_UNALLOCATED_GTS       = 1,   // 最小全局时间戳
  MIN_UNALLOCATED_WRS       = 2,   // 最小弱读快照
  MAX_COMMITTED_TXN_VERSION = 3,   // 最大已提交事务版本
  ACTIVE_TXN_SNAPSHOT       = 4,   // 活跃事务快照（最小）
  MAX_SNAPSHOT_TYPE         = 5,
};
```

每个 OBServer 节点在每次 `study()` 中获取四个值的**最小值**：

```cpp
// ob_multi_version_garbage_collector.cpp:307-316
// 从源码注释翻译的四种快照类型的使用场景：
//
// 一个事务只能在一台机器上启动（TxDesc）。如果事务在 report 之前启动：
//   a) 事务已结束 → 不需要考虑
//   b) 事务未结束 → 用 ACTIVE_TXN_SNAPSHOT 跟踪
// 如果事务在 report 之后启动：
//   a) 用 GTS 作为快照 → 用 MIN_UNALLOCATED_GTS
//   b) 用 WRS 作为快照 → 用 MIN_UNALLOCATED_WRS
//   c) 用最大已提交版本 → 用 MAX_COMMITTED_TXN_VERSION
```

### 1.4 GC 的关键周期：study → refresh → reclaim

GC 的运行是一个三阶段循环：

```
(repeat_study)         (repeat_refresh)       (repeat_reclaim)
┌──────────────┐     ┌────────────────┐     ┌─────────────────┐
│ study():     │     │ refresh_():    │     │ reclaim():      │
│ 收集4个快    │ ──▶ │ 回读 inner     │ ──▶ │ 清理过期节点    │
│ 照信息        │     │ table 计算     │     │ (宕机/迁移)     │
│ INSERT 到    │     │ 全局保留版本   │     │ 跳的节点)       │
│ inner table  │     │ 缓存到内存     │     │                 │
└──────────────┘     └────────────────┘     └─────────────────┘
    每 retry(1min)       每 retry(1min)         每 exec(10min)
  或出错时立即执行      或出错时立即执行        或出错时立即执行
```

#### 阶段一：study() — 主动采集

```cpp
// ob_multi_version_garbage_collector.h:144-145
// repeat_study() 会在出错或每 10 分钟执行一次 study()
void repeat_study();

// ob_multi_version_garbage_collector.cpp:281-284
int ObMultiVersionGarbageCollector::study()
{
  share::SCN min_unallocated_GTS;      // 最小 GTS（全局时钟）
  share::SCN min_unallocated_WRS;      // 最小弱读快照
  share::SCN max_committed_txn_version; // 最大已提交版本
  share::SCN min_active_txn_version;   // 最小活跃事务快照

  // ... 分别采集四个值 ...
  study_min_unallocated_GTS(min_unallocated_GTS);
  study_min_unallocated_WRS(min_unallocated_WRS);
  study_max_committed_txn_version(max_committed_txn_version);
  study_min_active_txn_version(min_active_txn_version);

  // report() 将四个值原子性地写入 __all_reserved_snapshot 内表
  report(min_unallocated_GTS, min_unallocated_WRS,
         max_committed_txn_version, min_active_txn_version);
}
```

四个 `study_*_*()` 各自负责一个维度的快照采集：

- **`study_min_unallocated_GTS`** (L351-381)：获取当前 GTS 值，用于基于 GTS 分配快照的事务的重试保障（GTS 还未分配的版本，不会有事务读取）
- **`study_min_unallocated_WRS`** (L383-411)：获取弱读快照最小值，用于弱一致性读（如备机读）的快照保障
- **`study_max_committed_txn_version`** (L413-430)：获取最大已提交版本号，确保 GC 不会回收单 LS 事务可能读取的版本
- **`study_min_active_txn_version`** (L432-446)：遍历所有会话的 `tx_desc.snapshot_version` 和 `query_start_ts`，取最小值

#### 阶段二：refresh_() — 全局聚合

```cpp
// ob_multi_version_garbage_collector.cpp:453-487
int ObMultiVersionGarbageCollector::refresh_()
{
  ObMultiVersionGCSnapshotCalculator collector;

  // 1. 从 inner table 收集所有节点的快照信息
  collect(collector);

  // 2. 检查 GC 状态（是否被磁盘监控禁用）
  decide_gc_status_(collector.get_status());

  // 3. 监控磁盘是否满
  disk_monitor_(collector.is_this_server_disabled());

  // 4. 缓存全局保留快照版本（供其他模块使用）
  decide_reserved_snapshot_version_(
    collector.get_reserved_snapshot_version(),
    collector.get_reserved_snapshot_type());

  return ret;
}
```

核心在 `ObMultiVersionGCSnapshotCalculator`：

```cpp
// ob_multi_version_garbage_collector.cpp:1251-1330
// 计算器遍历所有节点上报的 4 种快照，取全局最小值
int ObMultiVersionGCSnapshotCalculator::operator()(
    const share::SCN snapshot_version,
    const ObMultiVersionSnapshotType snapshot_type,
    const ObMultiVersionGCStatus status,
    const int64_t create_time,
    const ObAddr addr)
{
  // Step1: 记录全局最小的 snapshot_version
  // 如果某个节点的上报值小于当前最小值 → 取较小者
  // 但要忽略太久远的值（超过 2 * RECLAIM_DURATION 的）→ 可能是宕机节点的陈旧值
  
  // Step2: 如果 snapshot_version 比之前的记录更大 → 更新为更大值
  // 这是因为全局保留版本 = 所有节点上报的最小值的最大值（min_of_mins）
  
  // Step3: 累计 GC 状态
}
```

**关键决策**：`global_reserved_snapshot_` 的更新使用严格的**单调递增检查**（`decide_reserved_snapshot_version_` L500-540）。如果新值小于已缓存的值，除非是特定允许情况（如 WRS 禁用单调弱读），否则会被拒绝——这是为了防止宕机节点恢复后上报陈旧的快照版本，导致回收过于激进。

#### 阶段三：reclaim() — 过期清理

```cpp
// ob_multi_version_garbage_collector.cpp:676-752
// reclaim 只由 Sys LS 的 Leader 执行（高可用保障）
int ObMultiVersionGarbageCollector::reclaim()
{
  // 1. 判断是否为 Sys LS Leader
  // 2. 收集需要清理的节点（超过 RECLAIM_DURATION 未更新者）
  // 3. 收集所有上报节点（用于监控断裂）
  // 4. 执行清理和监控
}
```

清理条件（L698-728）：
- 节点超过 `GARBAGE_COLLECT_RECLAIM_DURATION`（默认 30 分钟）未更新快照
- 节点不存在于 `__all_server` 表
- 节点存在但已不存活

### 1.5 自适应退让机制

GC 不是孤立的——它需要感知系统状态并自适应调整：

**磁盘已满 → 禁用 GC**：

```cpp
// ob_multi_version_garbage_collector.cpp:1174-1200
int ObMultiVersionGarbageCollector::is_disk_almost_full_(bool &is_almost_full)
{
  // Case1: IO 设备即将满
  LOCAL_DEVICE_INSTANCE.check_space_full(required_size);
  
  // Case2: SSTable 合并过程中 overflow（5 分钟内出现）
  is_sstable_overflow_();
  
  // → 将 GC 状态写入 inner table 的 status 字段
  // → 所有节点读取到 DISABLED_GC_STATUS 后，is_gc_disabled() 返回 true
  // → 引用该值的模块改用 undo_retention 和 snapshot_gc_ts 作为回退机制
}
```

**长时间无法连接 Inner Table → 放弃 GC 规则**：

```cpp
// ob_multi_version_garbage_collector.cpp:207-217
void ObMultiVersionGarbageCollector::repeat_refresh()
{
  if (is_refresh_fail() ||
      (current_timestamp - last_refresh_timestamp_ > 30 * GARBAGE_COLLECT_RETRY_INTERVAL
       && 0 != last_refresh_timestamp_
       && current_timestamp - last_refresh_timestamp_ > 30 * 1_min)) {
    // 该服务器无法连接到内部表 → 认为该服务器上的多版本数据对所有活跃事务不可达
    // → 放弃 GC 规则，使用 undo_retention 和 snapshot_gc_ts 作为回收保障
    refresh_error_too_long_ = true;
  }
}
```

### 1.6 GC 状态机

```cpp
// ob_multi_version_garbage_collector.h:65-72
enum ObMultiVersionGCStatus : uint64_t
{
  NORMAL_GC_STATUS   = 0,           // 正常
  DISABLED_GC_STATUS = 1 << 0,    // 被禁用（磁盘满或 SSTable overflow）
  INVALID_GC_STATUS  = UINT64_MAX, // 初始状态
};

// 支持位运算组合（按位 OR）
inline ObMultiVersionGCStatus operator|(ObMultiVersionGCStatus a, ObMultiVersionGCStatus b)
{
  return static_cast<ObMultiVersionGCStatus>(static_cast<uint64_t>(a) | static_cast<uint64_t>(b));
}
```

**条件组合**：不同服务器可以上报不同的状态，整体 GC 状态是**所有服务器上报状态的按位或**——只要有一台服务器报告 DISABLED，全局就禁用 GC。

### 1.7 迭代器与可见性：`GetMinActiveSnapshotVersionFunctor`

```cpp
// ob_multi_version_garbage_collector.h:108-115
class GetMinActiveSnapshotVersionFunctor
{
public:
  GetMinActiveSnapshotVersionFunctor()
    : min_active_snapshot_version_(share::SCN::max_scn()) {}
  
  bool operator()(sql::ObSQLSessionMgr::Key key, sql::ObSQLSessionInfo *sess_info)
  {
    // 遍历所有会话，收集每个会话的最小快照版本
    // 对于 RC 隔离级别：使用 session_state 和 query_start_ts
    // 对于 RR/SI 隔离级别：使用 tx_desc.snapshot_version
    // 对于 AC=1 远程执行：必定有 session，从 session 获取
  }
  
  share::SCN get_min_active_snapshot_version()
    { return min_active_snapshot_version_; }
};
```

---

## 2. ObRowLatch — 行级自旋锁

`ObRowLatch` 是 OceanBase MVCC 行保护的最基础锁原语。已在文章 01 中简介，这里深入其实现细节。

### 2.1 代码结构

```cpp
// src/storage/memtable/mvcc/ob_row_latch.h:22-42
#define USE_SIMPLE_ROW_LATCH 1   // ← 编译开关

#if USE_SIMPLE_ROW_LATCH
struct ObRowLatch
{
  ObRowLatch(): locked_(false) {}
  ~ObRowLatch() {}

  // RAII 守卫
  struct Guard {
    Guard(ObRowLatch& host): host_(host) { host.lock(); }
    ~Guard() { host_.unlock(); }
    ObRowLatch& host_;
  };

  bool is_locked() const       { return ATOMIC_LOAD(&locked_); }
  bool try_lock()              { return !ATOMIC_TAS(&locked_, true); }
  void lock()                  { while(!try_lock()) ; }     // 自旋等待
  void unlock()                { ATOMIC_STORE(&locked_, false); }

  bool locked_;  // 8 字节对齐，单 bool 变量
};
#else
// 备选：使用通用 ObLatch（更重，支持读写锁）
struct ObRowLatch
{
  // ...
  bool try_lock() { return OB_SUCCESS == latch_.try_wrlock(ObLatchIds::ROW_CALLBACK_LOCK); }
  void lock()     { (void)latch_.wrlock(ObLatchIds::ROW_CALLBACK_LOCK); }
  void unlock()   { (void)latch_.unlock(); }
  common::ObLatch latch_;
};
#endif

typedef ObRowLatch::Guard ObRowLatchGuard;
```

### 2.2 TAS 实现的效率分析

`ObRowLatch` 的默认实现使用**原子 test-and-set**（`ATOMIC_TAS`），这是最简单的自旋锁：

```cpp
// 展开 ATOMIC_TAS:
// __atomic_test_and_set(&locked_, __ATOMIC_ACQUIRE)
// x86: 编译为 LOCK XCHG 指令（总线锁，性能代价高但简单可靠）
// ARM: 编译为 LDXR/STXR 指令对（独占访问，不会锁总线）

bool try_lock() {
  return !ATOMIC_TAS(&locked_, true);
  // 返回值：true=获取锁成功（locked_ 之前是 false）
  //          false=获取锁失败（locked_ 之前是 true，其他线程持有）
}
```

**为什么不使用读写锁来实现行共享读锁？** 因为 OceanBase 的 MVCC 读写互不阻塞——读操作通过快照版本跨越版本链表，**完全不需要锁**。只有在 `mvcc_write_` 需要插入版本节点时才需要排他锁保护链表操作的原子性。因此简单的 TAS 自旋锁足够。

| 特性 | ObRowLatch（TAS） | 通用 ObLatch | Linux MCS 锁 |
|------|-------------------|-------------|-------------|
| 实现复杂度 | 1 个原子指令 | 多字段 CAS | 队列唤醒 + cache-line |
| 内存占用 | 1 byte | 多个字段 | 每个 waiter 一个节点 |
| 争抢场景 | 极低（写写冲突罕见） | 适合读写混合 | 高争抢（公平） |
| 缓存线影响 | 所有 CPU 旋转同一 cache-line | 同左 | 每个 CPU 各自旋转 |

**设计决策**：行级自旋锁选择最简单的 TAS，是因为任何行级别的高频争抢都意味着应用层的写写冲突，这本身就是需要 SQL 层或用户行为避免的。用最少的代码实现最大带宽的保障。

### 2.3 使用模式

```cpp
// ObMvccRow::mvcc_write_ 中的典型用法（ob_mvcc_row.cpp:808）
int ObMvccRow::mvcc_write_(...)
{
  ObRowLatchGuard guard(latch_);  // ★ RAII：进入时加锁，作用域退出时自动解锁
  // ... 遍历版本链表，检测冲突，插入新节点 ...
  return ret;
  // ★ 函数返回时，Guard 析构 → host_.unlock()
}
```

**RAII 守卫的保证**：即使在异常路径、多重 return 或错误处理中，`ObRowLatchGuard` 的析构函数保证锁被释放——这是 C++ RAII 的基础用法，也是并发安全的第一道防线。

---

## 3. ObLockWaitMgr — 锁等待管理器

`ObLockWaitMgr` 是 OceanBase 分布式事务引擎中管理**等待依赖关系**的核心组件。与 RDBMS 领域经典的"锁管理器"（Lock Manager）不同，`ObLockWaitMgr` 并非管理"锁"本身（锁由 MVCC Row 和 ObObjLock 管理），而是管理**等待节点**的排队、唤醒和死锁检测。

### 3.1 核心职责

```
                  ┌──────────────┐
                  │ 事务/请求    │
                  │ 发现冲突     │
                  └──────┬───────┘
                         │ "我在等行长 R"
                         ▼
               ┌─────────────────┐
               │  ObLockWaitMgr  │
               │                 │
               │ hash_map        │  ← 按行/事务/表锁 hash 组织等待队列
               │ ┌─────┐ ┌─────┐ │
               │ │hash1│ │hash2│ │
               │ ├─────┤ ├─────┤ │
               │ │node1│ │node5│ │
               │ │node2│ └─────┘ │
               │ │node3│         │
               │ └─────┘         │
               │                 │
               │ 定时器：检查超时│
               │  & 会话被杀     │
               └────────┬────────┘
                        │ "锁释放了，唤醒等待者"
                        ▼
                 ┌──────────────┐
                 │  repost()    │
                 │  → 队列重试  │
                 └──────────────┘
```

### 3.2 等待节点类型

`ObLockWaitMgr` 管理三种类型的锁等待，通过 `LockHashHelper` 的 hash 前缀区分：

```cpp
// ob_lock_wait_mgr.h:327-349
class LockHashHelper {
private:
  static const uint64_t TRANS_FLAG      = 1L << 63L;   // 事务等待 (10)
  static const uint64_t TABLE_LOCK_FLAG = 1L << 62L;   // 表锁等待 (01)
  static const uint64_t ROW_FLAG        = 0L;           // 行锁等待 (00)
  static const uint64_t HASH_MASK = ~(TRANS_FLAG | TABLE_LOCK_FLAG);

public:
  // 行锁等待：通过 tablet_id + memtable_key 计算 hash
  static uint64_t hash_rowkey(const ObTabletID &tablet_id, const ObMemtableKey &key);

  // 事务等待：通过事务 ID 计算 hash（用于 is_delayed_cleanout 的等待切换）
  static uint64_t hash_trans(const ObTransID &tx_id);

  // 表锁等待：通过 lock_id（object + id）计算 hash
  static uint64_t hash_lock_id(const ObLockID &lock_id);
};
```

**等待的切换**（`transform_row_lock_to_tx_lock`）：从行锁等待切换到事务锁等待。这是 `is_delayed_cleanout` 场景的需要——当锁持有者的回调已被清理，等待队列从等待行释放切换为等待事务提交。

### 3.3 关键接口和流程

#### 3.3.1 post_lock() — 注册等待

```cpp
// ob_lock_wait_mgr.h:141-162
// 行锁等待注册
int post_lock(const int tmp_ret,
              const share::ObLSID &ls_id,
              const ObTabletID &tablet_id,
              const ObStoreRowkey &row_key,
              const int64_t timeout,
              const bool is_remote_sql,
              const int64_t last_compact_cnt,
              const int64_t total_trans_node_cnt,
              const transaction::ObTransID &tx_id,
              const SessionIDPair sess_id_pair,
              const transaction::ObTransID &holder_tx_id,
              const transaction::ObTxSEQ &conflict_tx_hold_seq,
              ObRowConflictInfo &cflict_info,
              ObFunction<int(bool&, bool&)> &rechecker);

// 表锁等待注册
int post_lock(const int tmp_ret,
              const share::ObLSID &ls_id,
              const ObTabletID &tablet_id,
              const transaction::tablelock::ObLockID &lock_id,
              const int64_t timeout,
              const bool is_remote_sql,
              ...);
```

`post_lock` 首先通过 `rechecker` 函数（或 `check_need_wait` 函数）**重新检查冲突是否仍然存在**。因为在注册等待队列的过程中，锁可能已经被释放了。如果锁已释放，直接返回 `OB_SUCCESS`，无需等待。

#### 3.3.2 setup() / post_process() — 线程本地上下文

```cpp
// ob_lock_wait_mgr.h:110-129
// 预处理：设置线程本地变量和等待 hash
void setup(Node &node, int64_t recv_ts)
{
  node.last_touched_thread_id_ = GETTID();
  node.reset_need_wait();
  node.recv_ts_ = recv_ts;
  get_thread_node() = &node;         // 绑定到线程本地
  get_thread_last_wait_hash_() = node.last_wait_hash_;
  get_thread_last_wait_addr_() = node.get_exec_addr();
  node.last_wait_hash_ = 0;
}

// 后处理：检查是否需要重试
bool post_process(bool need_retry, bool& need_wait);
```

**关键设计**：`setup()` 在请求处理开始时保存线程本地节点和等待 hash；`post_process()` 在请求处理结束时检查是否需要重试。如果请求入了等待队列但被提前唤醒（如超时），`post_process()` 会将 `need_wait` 设为 true，让执行器在重试前等待锁释放。

#### 3.3.3 wakeup() — 唤醒

```cpp
// ob_lock_wait_mgr.h:161-165
void wakeup(const ObTabletID &tablet_id, const Key& key);   // 行释放
void wakeup(const transaction::ObTransID &tx_id);            // 事务提交
void wakeup(const transaction::tablelock::ObLockID &lock_id); // 表锁释放
```

三种 `wakeup` 对应三种 hash 类型。唤醒时：
1. 找到对应 hash 的等待队列头
2. 将队列头的 Node 摘除
3. 调用 `repost()` 将请求重新放入线程工作队列

### 3.4 远程等待（Distributed Lock Wait）

OceanBase 的 `ObLockWaitMgr` 支持**跨节点等待**——当执行节点（execution-side）和锁持有者节点（control-side）不在同一台机器时，通过 RPC 实现远程等待队列：

```
源节点（Source OBServer）              目标节点（Destination OBServer）
┌──────────────────────┐              ┌──────────────────────┐
│ 事务请求执行 SQL     │              │ 锁持有者事务         │
│                      │              │                      │
│ 1. 检测到冲突        │              │                      │
│ 2. 发现持有者在另一  │              │                      │
│    台机器            │              │                      │
│                      │              │                      │
│ ┌────────────────┐   │   RPC 请求   │ ┌────────────────┐   │
│ │ 本地创建        │──┼────────────── ┼▶│ 在队列中创建    │   │
│ │ fake node      │   │              │ │ remote exec    │   │
│ │ (占位符)       │   │              │ │ side node      │   │
│ └────────────────┘   │              │ └────────────────┘   │
│                      │              │                      │
│                      │   RPC 响应   │                      │
│ 3. 等待 lock_release │◀─── ───── ──┼┤                      │
│    通知              │              │ 4. 锁释放时，目标    │
│                      │              │    节点发送 RPC      │
│                      │              │    通知源节点        │
└──────────────────────┘              └──────────────────────┘
```

关键 RPC 接口（`ob_lock_wait_mgr_rpc.h`）：

```cpp
// 源节点 → 目标节点：请将我的等待请求入队
int handle_inform_dst_enqueue_req(const ObLockWaitMgrDstEnqueueMsg &msg,
                                  ObLockWaitMgrRpcResult &result);

// 目标节点 → 源节点：入队完成
int handle_dst_enqueue_resp(const ObLockWaitMgrDstEnqueueRespMsg &msg,
                            ObLockWaitMgrRpcResult &result);

// 目标节点 → 源节点：锁已释放，请重试
int handle_lock_release_req(const ObLockWaitMgrLockReleaseMsg &msg,
                            ObLockWaitMgrRpcResult &result);
```

### 3.5 超时检测

`ObLockWaitMgr` 内部运行一个定时线程（`run1()`），周期性检查所有等待节点：

```cpp
// ob_lock_wait_mgr.h:91-93
static const int64_t WAIT_TIMEOUT_TS       = 1000 * 1000;   // 1s（远程唤醒的额外超时）
static const int64_t CHECK_TIMEOUT_INTERVAL = 100 * 1000;    // 100ms（检查间隔）

// ob_lock_wait_mgr.cpp
void ObLockWaitMgr::run1()
{
  while (!has_set_stop()) {
    // 每 100ms 检查一次
    ObLink* expired = check_timeout();  // 返回超时的节点链表
    
    // 处理超时的节点（释放、通知上层）
    Node* iter = static_cast<Node*>(expired);
    while (iter) {
      repost(iter);       // 放回工作线程，触发重试
      iter = iter->next_;
    }
    
    usleep(CHECK_TIMEOUT_INTERVAL);
  }
}
```

**超时场景**：
- 锁等待超时（`lock_wait_timeout` 系统变量）
- 会话被 kill（`session_killed`）
- 死锁检测触发回滚（deadlock detector 介入）

### 3.6 死锁检测适配

`ObLockWaitMgr` 通过 `register_local_node_to_deadlock_` 和 `register_remote_node_to_deadlock_` 将等待关系注册到 OceanBase 的死锁检测器（`ObDeadLockDetectorAdapter`），形成等待图（Wait-For Graph）：

```
register_local_node_to_deadlock_(self_tx_id, blocked_tx_id, node)
  → "我在等待事务 blocked_tx_id 持有的锁"
  
register_remote_node_to_deadlock_(self_tx_id, node)
  → "我在远程等待一个锁"
```

---

## 4. ObTableLock — 表级锁系统

表级锁是 OceanBase 在 DDL（如 DROP TABLE、TRUNCATE TABLE）和 LOCK TABLE 语句中使用的粗粒度并发控制机制。

### 4.1 锁模式与兼容性矩阵

OceanBase 的表级锁实现了 Oracle 兼容的 5 种锁模式：

```cpp
// ob_table_lock_def.h — DEF_LOCK_MODE 宏展开
enum {
  NO_LOCK           = 0x0,  // 无锁 (N)
  ROW_SHARE         = 0x8,  // 行共享 (RS)
  ROW_EXCLUSIVE     = 0x4,  // 行排他 (RX)
  SHARE             = 0x2,  // 共享锁 (S)
  SHARE_ROW_EXCLUSIVE = 0x6,  // 共享行排他 (SRX)
  EXCLUSIVE         = 0x1,  // 排他锁 (X)
};

// ob_table_lock_common.h:45-51 — 兼容性矩阵
// +---------------------+-----------+---------------+-------+---------------------+-----------+
// |                     | ROW SHARE | ROW EXCLUSIVE | SHARE | SHARE ROW EXCLUSIVE | EXCLUSIVE |
// +---------------------+-----------+---------------+-------+---------------------+-----------+
// | ROW SHARE           | Y         | Y             | Y     | Y                   | ❌        |
// | ROW EXCLUSIVE       | Y         | Y             | ❌    | ❌                  | ❌        |
// | SHARE               | Y         | ❌            | Y     | ❌                  | ❌        |
// | SHARE ROW EXCLUSIVE | Y         | ❌            | ❌    | ❌                  | ❌        |
// | EXCLUSIVE           | ❌        | ❌            | ❌    | ❌                  | ❌        |
// +---------------------+-----------+---------------+-------+---------------------+-----------+

static const unsigned char compatibility_matrix[] = {
  0x0,  /* EXCLUSIVE     : 0000 */
  0xa,  /* SHARE         : 1010 */
  0xc,  /* ROW EXCLUSIVE : 1100 */
  0xe,  /* ROW SHARE     : 1110 */
};
```

### 4.2 锁优先级

```cpp
// ob_table_lock_def.h
enum ObTableLockPriority : int8_t
{
  HIGH1 = 0,   // 最高优先级（DDL 操作）
  HIGH2 = 10,  // 次高优先级
  NORMAL = 20, // 正常优先级（常规 DML）
  LOW = 30,    // 低优先级（后台任务）
};
```

**优先级队列**：`ObObjLockPriorityQueue` 维护按优先级排序的等待队列。每个等待者按其 `ObTableLockPriority` 进入不同的子队列（`high1_list_`, `normal_list_` 等），`generate_first()` 从最高优先级的非空队列中选取第一个任务。

### 4.3 ObOBJLock — 表锁核心实现

```cpp
// ob_obj_lock.h:145-200
class ObOBJLock : public share::ObLightHashLink<ObOBJLock>
{
public:
  ObOBJLock(const ObLockID &lock_id);

  // 尝试获取锁
  int lock(const ObLockParam &param,
           storage::ObStoreCtx &ctx,
           const ObTableLockOp &lock_op,
           const uint64_t lock_mode_cnt_in_same_trans[],
           ObMalloc &allocator,
           ObTxIDSet &conflict_tx_set);

  // 释放锁
  int unlock(const ObTableLockOp &unlock_op,
             const bool is_try_lock,
             const int64_t expired_time,
             ObMalloc &allocator);

  // 检查锁是否可授予（计算兼容性矩阵 + 冲突事务集）
  int check_allow_lock(const ObTableLockOp &lock_op,
                       const uint64_t lock_mode_cnt_in_same_trans[],
                       ObTxIDSet &conflict_tx_set,
                       bool &conflict_with_dml_lock,
                       const int64_t expired_time,
                       ObMalloc &allocator,
                       ...);
};
```

### 4.4 表锁操作类型

```cpp
// ob_table_lock_def.h — DEF_LOCK_OP_TYPE
enum {
  IN_TRANS_DML_LOCK,      // 事务内 DML 锁（INSERT/UPDATE/DELETE）
  OUT_TRANS_LOCK,         // 事务外锁（LOCK TABLE 语句）
  OUT_TRANS_UNLOCK,       // 事务外解锁
  IN_TRANS_COMMON_LOCK,   // 事务内通用锁（SELECT FOR UPDATE）
  TABLET_SPLIT,           // Tablet 分裂场景
};
```

### 4.5 锁定对象类型

```cpp
// ob_table_lock_def.h — DEF_OBJ_TYPE
enum {
  OBJ_TYPE_TABLE,                // 表
  OBJ_TYPE_TABLET,               // 分区
  OBJ_TYPE_COMMON_OBJ,          // 通用对象
  OBJ_TYPE_LS,                   // LogStream
  OBJ_TYPE_TENANT,               // 租户
  OBJ_TYPE_EXTERNAL_TABLE_REFRESH, // 外表刷新
  OBJ_TYPE_ONLINE_DDL_TABLE,    // 在线 DDL 表
  OBJ_TYPE_ONLINE_DDL_TABLET,   // 在线 DDL 分区
  OBJ_TYPE_DATABASE_NAME,       // 数据库
  OBJ_TYPE_OBJECT_NAME,         // 对象名
  OBJ_TYPE_DBMS_LOCK,           // 用户锁（DBMS_LOCK）
  OBJ_TYPE_MATERIALIZED_VIEW,   // 物化视图
  OBJ_TYPE_MYSQL_LOCK_FUNC,     // MySQL LOCK 函数
  OBJ_TYPE_REFRESH_VECTOR_INDEX, // 向量索引刷新
};
```

### 4.6 表锁的分布式实现

表锁在分布式环境中的核心挑战：一个表可能跨多个 Tablet 分布在多个 LogStream 上。`ObTableLockService` 通过以下机制解决：

1. **自动拆分 LockID**：`ObLockIDArray` 将锁请求分解为多个子锁请求（每个受影响的 Tablet 一个）
2. **向所有受影响的 LS 分发**：`ObTableLockCtx` 维护 `touched_ls_` 集合，确保所有 LS 都收到锁请求
3. **RPC 协议**：`ob_table_lock_rpc_struct.h` 定义了表锁的 RPC 消息结构，支持跨节点锁请求

```cpp
// ob_table_lock_service.h
class ObTableLockService final {
  class ObTableLockCtx {
  public:
    int set_tablet_id(const common::ObIArray<common::ObTabletID> &tablet_ids);
    int set_lock_id(const common::ObIArray<ObLockID> &lock_ids);
    int add_touched_ls(const share::ObLSID &lsid);
    // ...
  };
  // ...
};
```

---

## 5. 事务隔离级别与可见性

### 5.1 OceanBase 支持的隔离级别

| 隔离级别 | 实现方式 | 快照分配规则 | 是否支持 |
|---------|---------|-------------|---------|
| Read Committed (RC) | 语句级快照 | 每句执行时取当前 GTS | ✅ 默认级别 |
| Repeatable Read (RR) | 事务级快照 | 事务开始时取一次快照 | ✅ |
| Serializable (可串行化) | 事务级快照 + TSC 检查 | 同 RR，但写操作会检查 TSC | ✅ |

### 5.2 隔离级别对 GC 的影响

`study_min_active_txn_version` 的实现中，隔离级别决定了如何计算活跃事务快照：

```cpp
// ob_multi_version_garbage_collector.cpp 源码注释 (L87-92)
// RC, AC=0 事务：不会在 tx_desc 上记录 snapshot_version
//     → 使用 session_state 和 query_start_ts 作为活跃语句快照
// RR/SI, AC=0 事务：会在 tx_desc 上记录 snapshot_version
//     → 直接使用该值
// AC=1 事务：可能没有 tx_desc，但一定有 session
//     → 从 session 上获取
```

**关键差异**：
- **RC 隔离级别**：每个语句都有不同的快照，GC 必须保留所有正在执行的语句的快照对应的版本。`query_start_ts` 作为近似值。
- **RR 隔离级别**：整个事务使用单一快照，GC 只需保留事务开始时的版本。
- **Serializable**：GC 策略同 RR，但写入时增加了 TSC（Transaction Set Violation）检查——检测当前行的最新版本是否已经超出了事务的快照范围。

### 5.3 隔离级别与快照分配的协作

```
RC 隔离级别：
开始事务（tx_begin）          语句1               语句2               语句3
────┬──────────────────────────┬──────────────────┬──────────────────┬─────▶
    │                          │                  │                  │
    snapshot_version = GTS1     snapshot = GTS2    snapshot = GTS3
    事务开始（但不用）                                                     
    │                          │                  │                  │
                              └─ 每句取 GTS ────┘
                              
RR 隔离级别：
开始事务                      语句1               语句2               语句3
────┬──────────────────────────┬──────────────────┬──────────────────┬─────▶
    │                          │                  │                  │
    snapshot_version = GTS1     ╰── 都用这个 ──╯
    事务开始就取快照                                                    
```

### 5.4 读不等待写的实现

OceanBase MVCC 的核心优势：**读不等待写**。这是通过在 `ObMvccIterator` 中按照快照版本进行可见性判断实现的：

```cpp
// 读取流程（来自文章 01、02 的可见性逻辑）
// 对于给定的 snapshot_version：
//   1. 从 list_head_（最新版本）开始遍历
//   2. 跳过所有 is_aborted() 的节点
//   3. 找到 is_committed() 且 trans_version_ <= snapshot_version 的节点
//   4. 如果 trans_version_ 还没分配 → 可能是并发写入的节点，跳到 prev_
//   5. 返回找到的可见版本的数据

// 关键：写操作的 mvcc_write_ 虽然会加 ObRowLatch 自旋锁，
// 但锁只保护版本链表的原子插入操作，持续时间极短（微秒级）。
// 插入完成后锁立即释放，读操作虽然可能看到中间的 transient 状态
// （节点刚插入还未设置 F_COMMITTED），
// 但可见性检查会跳过该节点，从 prev_ 找到正确的可见版本。
```

**对比传统锁方案**：

| 方案 | 读等待写 | 写等待读 | 快照隔离 |
|------|---------|---------|---------|
| 传统行锁（2PL） | ✅ 必须等 | ✅ 必须等 | ❌ 只能看到已提交 |
| MVCC（OceanBase/InnoDB/PostgreSQL） | ❌ 不等待 | ✅ 写写冲突 | ✅ 每个事务/语句独立快照 |

---

## 6. 并发控制模块协作图

```
                          ┌─────────────────────────────┐
                          │    SQL 执行引擎              │
                          │ ObDMLService / ObSQLExecutor │
                          └─────┬───────────────┬───────┘
                                │               │
                       ┌────────▼───────┐  ┌───▼───────────┐
                       │ ObRowConflict  │  │ ObTableLock   │
                       │ Handler        │  │ Service       │
                       │ (冲突决策)     │  │ (表级锁管理)  │
                       └───┬────────┬───┘  └───┬───────────┘
                           │        │           │
              ┌────────────▼──┐  ┌──▼──────────▼───────┐
              │ ObLockWaitMgr │  │ ObOBJLock           │
              │ (等待队列)    │  │ (表锁实现)          │
              │               │  │                     │
              │ ┌───────────┐ │  │ ObObjLockPriority   │
              │ │Hash Bucket│ │  │ Queue (优先级队列)  │
              │ │ × 16384   │ │  └─────────┬───────────┘
              │ └───────────┘ │            │
              │               │            │
              │ 远程唤醒(RPC) │            │
              └───────┬───────┘            │
                      │                    │
         ┌────────────▼────────────────────▼─────────────┐
         │              ObMemtable / ObLS                │
         │         ┌────────────────────────────┐        │
         │         │  ObMvccRow (版本链表)      │        │
         │         │  ├─ ObRowLatch (行自旋锁)  │        │
         │         │  ├─ ObMvccTransNode[]     │        │
         │         │  └─ ObMvccRowIndex (索引)  │        │
         │         └────────────────────────────┘        │
         └──────────────────────┬────────────────────────┘
                                │
         ┌──────────────────────▼────────────────────────┐
         │         ObMultiVersionGarbageCollector        │
         │  ┌──────────────────────────────────────┐     │
         │  │ 内表 (__all_reserved_snapshot)       │     │
         │  │  ├─ MIN_UNALLOCATED_GTS              │     │
         │  │  ├─ MIN_UNALLOCATED_WRS              │     │
         │  │  ├─ MAX_COMMITTED_TXN_VERSION        │     │
         │  │  └─ ACTIVE_TXN_SNAPSHOT              │     │
         │  └──────────────────────────────────────┘     │
         │  ┌──────────────────────────────────────┐     │
         │  │ 缓存: global_reserved_snapshot_      │     │
         │  │ 供 ObITransCallback 和 Freezer 使用  │     │
         │  └──────────────────────────────────────┘     │
         └──────────────────────────────────────────────┘
```

---

## 7. ObDataValidationService — 数据验证服务

```cpp
// ob_data_validation_service.h:16-22
// ob_data_validation_service.cpp:15-65
class ObDataValidationService
{
public:
  static bool need_delay_resource_recycle(const ObLSID ls_id);
  static void set_delay_resource_recycle(const ObLSID ls_id);
};
```

这个服务是在正确性问题后的**回收延迟保护**。当开启 `_delay_resource_recycle_after_correctness_issue` 开关时，如果某个 LS 设置了延迟回收标志，该 LS 上的资源回收会被推迟，为人工干预或数据校验争取时间。这是 OceanBase 在正确性保证上的一道**安全阀**。

---

## 8. 与前面文章的关系

| 文章 | 组件 | 关联 |
|------|------|------|
| 01 (MVCC Row) | `ObMvccTransNode`, `ObMvccRow` | 版本链表是 MVCC GC 的**操作对象**；`ObRowLatch` 是行级锁 | 
| 02 (Iterator) | `ObMvccIterator` | 可见性判断依赖 `trans_version_`，GC 确保该版本仍然存在 |
| 03 (Write Conflict) | `ObLockWaitMgr` | 本文 3 节深入了 wait queue 的实现和远程等待 |
| 10 (2PC) | `ObPartTransCtx` | 事务提交后触发 `wakeup()`, 回调链完成后续 MVCC GC 可回收 |
| 16 (Conflict Handler) | `ObRowConflictHandler` | 冲突决策后的等待调用 `post_lock()` 进入 `ObLockWaitMgr` |
| 26 (Encoding) | `ObDatumRow`, 编码方式 | MVCC 版本节点的 `buf_[0]` 载荷采用本文描述的编码格式 |
| 35 (Macro Block Lifecycle) | SSTable 宏块生命周期 | SSTable overflow 事件反馈给 GC 禁用回收；GC 回收的旧版本最终被合并为新的宏块 |

---

## 9. 设计决策

### 9.1 MVCC GC 的策略选择：基于最小活跃事务快照

OceanBase 4.0 选择通过**全局最小活跃事务快照**来决定回收边界，而非传统的时间窗口法（如 undo_retention）。

**优点**：
- 理论上可以回收到极限（只要没有活跃事务需要旧版本）
- 自适应：长事务存在时自动延迟回收

**缺点**：
- 依赖全局协调（需要 Inner Table + RPC），单点故障影响
- 实现复杂度高（需要处理 4 种快照类型、异常回退机制）

**异常回退链**：
```
正常: 基于最小活跃事务快照 GC
  ↓ (refresh_error_too_long_)
回退: 基于 undo_retention 和 snapshot_gc_ts 的保守 GC
  ↓ (gc_is_disabled_)
禁用: GC 完全暂停（磁盘满时）
```

### 9.2 表级锁的分布式实现复杂度

OceanBase 的表锁实现与单机数据库有本质不同：
- **跨分区锁定**：一个表可能有数百个分区分布在数十个 LS 上
- **跨节点 RPC**：LOCK TABLE 可能触发跨节点 RPC
- **死锁检测集成**：表锁等待需要注册到分布式死锁检测器
- **日志同步**：表锁操作需要写 Paxos 日志（`IN_TRANS_DML_LOCK` 类型）

这些复杂度体现在 `ObTableLockService` 的 `touched_ls_` 管理和 `ob_table_lock_rpc.h` 的 RPC 协议定义中。

### 9.3 隔离级别与快照分配的关系

OceanBase 的快照分配策略体现了**不强制 RC 使用 RR 的代价**：

- **RC 的语句级快照**使得 GC 不得不跟踪语句开始时间（`query_start_ts`），而不是简单看事务开始时间。但 RC 的好处是写冲突更少（每次读写都看到最新已提交数据）。
- **RR 的事务级快照**让 GC 只需看事务开始快照，但写冲突风险更高（可能 TSC）。

### 9.4 读不等待写的代价

MVCC 的读不等待写虽然提升了读并发，但引入了两个问题：

1. **版本膨胀**：每次写都产生新版本，需要 GC 清理 → 催生了本文分析的 GC 系统
2. **TSC（Transaction Set Violation）**：RR 级别下，如果一个事务读到的行版本和它要写入的行版本不一致，需要回滚事务 → `OB_TRANSACTION_SET_VIOLATION`

---

## 10. 源码文件索引

### 10.1 MultiVersion Garbage Collector

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/storage/concurrency_control/ob_multi_version_garbage_collector.h` | `ObMultiVersionGarbageCollector` | 133 |
| `src/storage/concurrency_control/ob_multi_version_garbage_collector.h` | `ObMultiVersionSnapshotType` enum | 55 |
| `src/storage/concurrency_control/ob_multi_version_garbage_collector.h` | `ObMultiVersionGCStatus` enum | 65 |
| `src/storage/concurrency_control/ob_multi_version_garbage_collector.h` | `ObMultiVersionSnapshotInfo` | 81 |
| `src/storage/concurrency_control/ob_multi_version_garbage_collector.h` | `ObMultiVersionGCSnapshotCalculator` | 100 |
| `src/storage/concurrency_control/ob_multi_version_garbage_collector.h` | `GetMinActiveSnapshotVersionFunctor` | 108 |
| `src/storage/concurrency_control/ob_multi_version_garbage_collector.cpp` | `ObMultiVersionGarbageCollector::study()` | 281 |
| `src/storage/concurrency_control/ob_multi_version_garbage_collector.cpp` | `ObMultiVersionGarbageCollector::study_min_unallocated_GTS()` | 351 |
| `src/storage/concurrency_control/ob_multi_version_garbage_collector.cpp` | `ObMultiVersionGarbageCollector::study_min_active_txn_version()` | 432 |
| `src/storage/concurrency_control/ob_multi_version_garbage_collector.cpp` | `ObMultiVersionGarbageCollector::refresh_()` | 453 |
| `src/storage/concurrency_control/ob_multi_version_garbage_collector.cpp` | `ObMultiVersionGarbageCollector::decide_reserved_snapshot_version_()` | 500 |
| `src/storage/concurrency_control/ob_multi_version_garbage_collector.cpp` | `ObMultiVersionGarbageCollector::report()` | 592 |
| `src/storage/concurrency_control/ob_multi_version_garbage_collector.cpp` | `ObMultiVersionGarbageCollector::collect()` | 651 |
| `src/storage/concurrency_control/ob_multi_version_garbage_collector.cpp` | `ObMultiVersionGarbageCollector::reclaim()` | 777 |
| `src/storage/concurrency_control/ob_multi_version_garbage_collector.cpp` | `ObMultiVersionGarbageCollector::disk_monitor_()` | 1174 |
| `src/storage/concurrency_control/ob_multi_version_garbage_collector.cpp` | `ObMultiVersionGarbageCollector::is_disk_almost_full_()` | 1195 |
| `src/storage/concurrency_control/ob_multi_version_garbage_collector.cpp` | `ObMultiVersionGCSnapshotCalculator::operator()()` | 1251 |

### 10.2 ObRowLatch

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/storage/memtable/mvcc/ob_row_latch.h` | `struct ObRowLatch` | 22 |
| `src/storage/memtable/mvcc/ob_row_latch.h` | `ObRowLatch::Guard` | 31 |
| `src/storage/memtable/mvcc/ob_row_latch.h` | `USE_SIMPLE_ROW_LATCH` | 20 |

### 10.3 Lock Wait Manager

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.h` | `class ObLockWaitMgr` | 85 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.h` | `LockHashHelper` | 327 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.h` | `post_lock()` | 141 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.h` | `wakeup()` | 161 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.h` | `setup()` / `post_process()` | 110 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.h` | `ObNodeSeqGenarator` | 75 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp` | `wait_()` | 1127 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp` | `handle_local_node_()` | 859 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp` | `check_timeout()` | — |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr_rpc.h` | RPC 消息定义 | — |

### 10.4 Table Lock

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/storage/tablelock/ob_table_lock_def.h` | `DEF_LOCK_MODE` / `DEF_LOCK_PRIORITY` | — |
| `src/storage/tablelock/ob_table_lock_common.h` | 兼容性矩阵 | 45 |
| `src/storage/tablelock/ob_obj_lock.h` | `class ObOBJLock` | 145 |
| `src/storage/tablelock/ob_obj_lock.h` | `class ObObjLockPriorityQueue` | 100 |
| `src/storage/tablelock/ob_table_lock_service.h` | `class ObTableLockService` | 56 |
| `src/storage/tablelock/ob_table_lock_service.h` | `ObTableLockCtx` | 70 |

### 10.5 Data Validation Service

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/storage/concurrency_control/ob_data_validation_service.h` | `class ObDataValidationService` | 16 |
| `src/storage/concurrency_control/ob_data_validation_service.cpp` | `need_delay_resource_recycle()` | 15 |
| `src/storage/concurrency_control/ob_data_validation_service.cpp` | `set_delay_resource_recycle()` | 40 |

---

## 11. 下篇预告

并发控制框架的分析为理解 OceanBase 后续的高层组件提供了基础：

- **37-rebalance-scheduler**：负载均衡与调度器（如何利用并发控制信息做智能调度）
- **38-ob-partition-location**：分区位置管理与路由
- **39-ls-scheduler**：LogStream 调度器内部实现

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 代码仓库：OceanBase CE | 分析文件：ob_multi_version_garbage_collector.h/cpp(1685行), ob_row_latch.h(69行), ob_lock_wait_mgr.h(522行), ob_obj_lock.h(593行), ob_table_lock_def.h(90行), ob_data_validation_service.h/cpp(65行)*
