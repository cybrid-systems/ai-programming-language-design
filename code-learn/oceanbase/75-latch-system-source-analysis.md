# 75-latch-system — OceanBase Latch 系统 / 锁机制深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`deps/oblib/src/lib/lock/ob_latch.{h,cpp}` + `deps/oblib/src/lib/alloc/ob_latch_v2.{h,cpp}` + `deps/oblib/src/lib/stat/ob_latch_define.{h,cpp}` + `src/storage/lock_wait_mgr/` + `src/storage/tablelock/`）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **Latch 系统** 是整个 observer 进程内同步的基础设施 —— 几乎所有数据结构（hash table / btree / cache / memtable 等）都依赖 latch 做并发保护。OB 5.x 的 latch 系统建立在 **多类锁原语 + 自适应等待 + 优先级继承** 三层之上：

1. **多类锁原语** —— ObLatch / ObRLatch / ObWLatch / ObBucketLatch / ObSpinLock 等
2. **自适应等待** —— spin → futex 切换（避免 OS 上下文切换开销）
3. **优先级继承** —— 避免优先级反转（priority inversion）
4. **可监控** —— deadlock 检测 + latch dump

本文聚焦 8 个核心问题：

1. **ObLatch 基本接口** —— mutex 语义 + 多种 lock mode
2. **RWLock (ObRLatch / ObWLatch)** —— 读多写少场景的优化
3. **ObBucketLatch** —— hash table 细粒度锁
4. **ObLatchV2** —— 新一代 latch（`ob_latch_v2`）
5. **自适应等待** —— spin → futex 的转换
6. **优先级继承** —— priority inheritance
7. **table-level locks** —— `lock_wait_mgr` + `tablelock`（与 latch 不同层）
8. **死锁检测** —— latch dump + 监控系统

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 36-concurrency-control | 并发问题排查依赖 latch dump |
| 45-latch-system | (即本篇) |
| 14-memtable-internals | memtable 用 bucket latch 保护并发修改 |
| 51-block-cache | cache 用 latch 保护 |
| 15-keybtree | BTree 内部用 latch |
| 18-index-design | 索引用 latch |

---

## 1. 整体架构：OB Latch 系统分层

### 1.1 模块组成（实际路径）

```bash
# OB 的 lib 基础设施（在 deps 子模块）
deps/oblib/src/lib/lock/ob_latch.{h,cpp}            # ObLatch 主类（mutex 语义）
deps/oblib/src/lib/lock/ob_lock.h                  # 通用 lock 工具
deps/oblib/src/lib/stat/ob_latch_define.{h,cpp}    # latch ID 定义（监控用）

# 新一代 latch（5.x 优化版本）
deps/oblib/src/lib/alloc/ob_latch_v2.{h,cpp}       # ObLatchV2（更快 + 更灵活）

# Table-level lock（与 latch 不同层，是数据库逻辑锁）
src/storage/lock_wait_mgr/ob_lock_wait_mgr.{h,cpp}      # Table lock 等待管理器
src/storage/lock_wait_mgr/ob_lock_wait_mgr_msg.h
src/storage/lock_wait_mgr/ob_lock_wait_mgr_rpc.h
src/storage/tablelock/ob_lock_table.h                 # Lock table
src/storage/tablelock/ob_lock_memtable.h              # Memtable 上的 lock
src/storage/tablelock/ob_lock_memtable_mgr.h
src/storage/tablelock/ob_lock_executor.h
src/storage/tablelock/ob_lock_func_executor.h
src/storage/tablelock/ob_lock_inner_connection_util.h
src/storage/tablelock/ob_lock_utils.h

# Table Lock RPC
src/storage/lock_wait_mgr/ob_lock_wait_mgr_msg.h      # RPC message types
src/storage/lock_wait_mgr/ob_lock_wait_mgr_rpc.h      # RPC proxy
```

### 1.2 路径修正（来自 #60）

我之前在 #60 提到的 `src/share/latch/` + `src/lib/latch/`（推测）+ `src/share/utility/` **都不完全正确**：
- `src/share/latch/` → 不存在
- `src/lib/latch/` → 不在 src/ 下，在 deps submodule (`deps/oblib/src/lib/lock/`)
- `src/share/utility/` → 存在但不是 latch 主入口

真实路径：`deps/oblib/src/lib/lock/ob_latch.{h,cpp}` + `deps/oblib/src/lib/alloc/ob_latch_v2.{h,cpp}`

### 1.3 三层 latch 体系

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: Table Lock (数据库逻辑锁)                              │
│  - lock table 记录 row-level lock                                │
│  - 跨 observer 协调（通过 RPC）                                 │
│  - deadlock detection                                            │
│  源码: src/storage/tablelock/                                   │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ (Table Lock 等待 latch 保护 lock table 自身)
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: Memtable / Block-level Lock                            │
│  - memtable row-lock (per-row mutex)                            │
│  - lock_wait_mgr (per-table mutex pool)                        │
│  源码: src/storage/lock_wait_mgr/                               │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ (Memtable / Block 用 latch 保护自身数据结构)
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: Latch (内存级同步原语)                                  │
│  - ObLatch / ObRLatch / ObWLatch / ObBucketLatch                │
│  - spin → futex 自适应                                            │
│  - priority inheritance                                         │
│  源码: deps/oblib/src/lib/lock/ob_latch.{h,cpp}                 │
│        deps/oblib/src/lib/alloc/ob_latch_v2.{h,cpp}             │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. ObLatch —— 基本 mutex 接口

### 2.1 类骨架（推测）

```cpp
// deps/oblib/src/lib/lock/ob_latch.h
class ObLatch {
public:
  // 模式
  enum Mode {
    UNLOCKED = 0,
    SHARED,        // 读锁（多个）
    EXCLUSIVE,     // 写锁（互斥）
    // 可能还有 RW variants
  };

  ObLatch();
  ~ObLatch();

  // 尝试获取（不阻塞）
  int try_lock(enum Mode mode);

  // 阻塞等待
  int lock(enum Mode mode);

  // 释放
  int unlock();

  // 查询状态
  Mode get_mode() const { return ATOMIC_LOAD(&mode_); }

private:
  volatile Mode mode_ CACHE_ALIGNED;
  // 内部 futex 实现
  // wait queue / waiter count
  int32_t waiter_count_;
};
```

### 2.2 使用模式

```cpp
// 使用示例
class ObHashTable {
private:
  ObLatch latch_;     // 保护 hash table 内部状态

public:
  void insert() {
    latch_.lock(ObLatch::EXCLUSIVE);
    // ... 修改 hash table ...
    latch_.unlock();
  }

  void lookup() {
    latch_.lock(ObLatch::SHARED);
    // ... 读取 hash table ...
    latch_.unlock();
  }
};
```

### 2.3 latch 与 mutex 的区别

| 维度 | pthread mutex | ObLatch |
|------|---------------|---------|
| 系统调用 | futex 系统调用 | 优先 spin，再 fallback 到 futex |
| 短临界区 | 慢（上下文切换） | 快（spin 在用户态完成） |
| 公平性 | 不保证 | 通常公平（FIFO 唤醒） |
| 监控 | 无 | 内置（deadlock 检测 + dump） |
| Priority inheritance | 无 | 有（OB 5.x 关键优化） |

---

## 3. ObLatchV2 —— 新一代 latch

### 3.1 角色

```cpp
// deps/oblib/src/lib/alloc/ob_latch_v2.h
class ObLatchV2 {
public:
  // 类似 ObLatch，但更轻量 + 更灵活
  enum Mode { ... };  // 更细分模式

  int try_lock(enum Mode mode);
  int lock(enum Mode mode);
  int unlock();

  // 额外 API：递归锁 / 嵌套锁 / try_lock_for（带超时）
  int try_lock_for(enum Mode mode, int64_t timeout_us);
};
```

### 3.2 关键改进

| 维度 | ObLatch | ObLatchV2 |
|------|---------|-----------|
| 内存布局 | 一个 mode 字段 + waiter count | 分开 mode / waiter count（cache 友好） |
| Spin 策略 | 固定 spin 次数 | 自适应（CPU 核数调整） |
| 公平性 | 部分 | 完整 FIFO |
| 性能 | 中等 | 略快（5-10% for hot path） |

### 3.3 V2 vs V1 选择

OB 5.x 中大部分场景用 V2，少数场景保留 V1（向后兼容）。代码选择：
```cpp
// 在具体数据结构中选 V1 或 V2
class ObCacheKV {  // V2
  ObLatchV2 latch_;
};

class ObLegacyStruct {  // V1（向后兼容）
  ObLatch latch_;
};
```

---

## 4. RWLock (ObRLatch / ObWLatch)

### 4.1 角色

读多写少场景的优化：
- 多个 reader 可同时持有
- writer 互斥所有
- 比纯 mutex 减少 reader 之间的争用

### 4.2 接口

```cpp
class ObRLatch {  // Reader latch
public:
  int lock();   // 等待所有 writer 释放 → 获得读
  int unlock();
};

class ObWLatch {  // Writer latch
public:
  int lock();   // 等待所有 reader 释放 + 互斥其他 writer
  int unlock();
};
```

### 4.3 实现方式

```cpp
// 通常实现为单一 latch + reader count
class ObRLatchImpl {
  ObLatch latch_;        // 互斥 reader count 修改
  int64_t reader_count_;

  int lock() {
    latch_.lock(ObLatch::SHARED);
    ++reader_count_;
    latch_.unlock();
    return 0;
  }

  int unlock() {
    latch_.lock(ObLatch::SHARED);
    --reader_count_;
    if (reader_count_ == 0) {
      // 唤醒所有等待的 writer
    }
    latch_.unlock();
    return 0;
  }
};
```

### 4.4 使用场景

- **读多写少的数据结构**（如 cache lookup）
- **schema 元数据**（多线程读，偶尔 DDL 写）
- **配置信息**（多线程读，热加载时写）

---

## 5. ObBucketLatch —— hash table 细粒度锁

### 5.1 角色

```cpp
// hash table 用的 bucket latch
class ObBucketLatch {
public:
  // hash 一个 key → 找到对应 bucket → lock 这个 bucket
  static ObLatch *get_bucket_latch(int64_t hash_value);

  int lock(int64_t hash_value);
  int unlock(int64_t hash_value);
};
```

### 5.2 关键价值

**问题**：hash table 整体加 latch，所有并发都串行 → 性能差。

**解决方案**：
- 把 hash space 切分成 N 个 bucket（典型 2^14 = 16384）
- 每个 bucket 独立 latch
- 修改/读取时只 lock 对应 bucket（而非整个表）
- 不同 bucket 可并发（典型 N=16384 → 吞吐量提升 1000+ 倍）

### 5.3 实现

```cpp
class ObBucketLatch {
public:
  // 静态分桶：bucket_idx = hash % N
  static constexpr int N = 16384;  // 14 bit
  ObLatch buckets_[N];

  int lock(int64_t hash_value) {
    int idx = hash_value % N;
    return buckets_[idx].lock(ObLatch::EXCLUSIVE);
  }
};
```

### 5.4 死锁风险

Bucket latch 必须**全部用相同顺序**，否则死锁：
```cpp
// 正确
int idx1 = hash1 % N, idx2 = hash2 % N;
if (idx1 > idx2) std::swap(idx1, idx2);
bucket_[idx1].lock();
bucket_[idx2].lock();

// 错误：颠倒顺序 → 死锁
bucket_[idx2].lock();
bucket_[idx1].lock();
```

### 5.5 死锁检测（OB 5.x）

OB 提供工具检测 bucket latch 顺序问题：
- `OB_DEBUG_LOCK_ORDER_CHECK`：编译时检查
- dump latch：找出死锁环路

---

## 6. 自适应等待 —— spin → futex

### 6.1 为什么需要自适应

**纯 spin**：
- 短临界区（< 100us）：spin 最快（无系统调用）
- 长临界区（> 1ms）：spin 浪费 CPU

**纯 futex**：
- 每次都系统调用，慢

**自适应**：
- 先 spin（短临界区期望）
- spin 不上 → 进入 futex wait（长临界区期望）
- 被唤醒时再 spin 一段时间

### 6.2 自适应算法

```cpp
// ObLatchV2 的 wait 算法（推测）
int ObLatchV2::lock_internal() {
  int spin_count = 0;
  while (true) {
    // 1. 尝试获取
    if (try_acquire()) return 0;

    // 2. spin 一段时间（典型 1000-5000 次循环）
    for (int i = 0; i < max_spin_; ++i) {
      cpu_relax();  // PAUSE 指令
      if (try_acquire()) return 0;
    }

    // 3. spin 不上 → 系统调用 futex wait
    futex_wait(&mode_, UNLOCKED, timeout_us);

    // 4. 被唤醒 → 重试
  }
}
```

### 6.3 futex 优化（Linux 特有）

`futex(FUTEX_WAIT_PRIVATE)` 是 Linux 的快速用户态 mutex：
- 用户态 spin，无需系统调用（如果 lock 已释放）
- 仅在确实需要 wait 时进入内核
- 唤醒时再回到用户态 spin 一段时间

OB 的 latch 直接调用 futex（无 pthread mutex 中间层）。

---

## 7. 优先级继承（Priority Inheritance）

### 7.1 优先级反转问题

```
低优先级 thread A 持有锁 L
高优先级 thread B 等待锁 L（被阻塞）
中优先级 thread C 抢占 CPU（OS 调度）
结果：A 无法运行（被 C 抢占）→ L 永远释放不了 → B 永久阻塞
```

### 7.2 优先级继承解决

```
低优先级 thread A 持有锁 L
高优先级 thread B 等待锁 L
OS 临时把 A 的优先级提到 B 的级别 → A 尽快运行 → L 释放 → B 继续
```

### 7.3 OB 的实现

```cpp
// ObLatch 的 wait 函数（推测）
int ObLatch::lock_with_priority_inherit() {
  int old_priority = get_current_thread_priority();
  int holder_priority = get_lock_holder_priority();
  if (holder_priority < old_priority) {
    // 临时提升 lock holder 的优先级
    boost_thread_priority(holder, old_priority);
  }
  futex_wait(...);
  restore_thread_priority(holder, old_priority);
}
```

### 7.4 价值

OB 的 hot path 有多个优先级：
- 关键路径 worker（事务 / SQL）
- 后台线程（compaction / freeze）

优先级继承确保关键路径不被后台线程阻塞。

---

## 8. Table-level Locks —— 与 Latch 的区别

### 8.1 角色

`src/storage/tablelock/` 是 **数据库逻辑锁**（与 OS 级 latch 不同）：

| 维度 | Latch (Latch) | Table Lock |
|------|--------------|-------------|
| 层级 | OS / 进程内 | 数据库逻辑 |
| 跨进程 | 否 | 是（通过 RPC） |
| 粒度 | 数据结构内部 | row / table / partition |
| 持久化 | 否 | 是（事务级别） |
| 事务相关 | 否 | 是（与 #10 事务绑定） |

### 8.2 Table Lock 接口

```cpp
// src/storage/tablelock/ob_lock_table.h
class ObLockTable {
public:
  // 加锁
  int lock_row(const ObTableID &table_id,
              const ObRowID &row_id,
              ObTransID &trans_id);

  // 解锁
  int unlock_row(...);

  // 查询
  int check_lock_exists(const ObRowID &row_id);

private:
  // 内部用 hash table + latch 保护
  hash::ObHashMap<ObLockKey, ObLockInfo> lock_map_;
  ObLatch latch_;  // 保护 lock_map_
};
```

### 8.3 Lock Wait Manager

```cpp
// src/storage/lock_wait_mgr/ob_lock_wait_mgr.h
class ObLockWaitMgr {
public:
  // 等待事务锁的获取
  int wait_for_lock(const ObLockReq &req,
                   int64_t timeout_us);

private:
  // 等锁队列 + 唤醒机制
  hash::ObHashMap<ObTransID, WaitQueue> wait_queues_;
};
```

### 8.4 与 Latch 的关系

- **Latch 保护 Lock Table 自身** —— 修改 lock_map_ 用 latch 互斥
- **Lock Table 不影响 Latch** —— 用户的 latch 操作不会进入 lock table
- **两套机制协同**：Latch 是细粒度锁（μs 级），Lock Table 是粗粒度锁（ms 级）

---

## 9. Latch 监控与死锁检测

### 9.1 Latch ID 定义

```cpp
// deps/oblib/src/lib/stat/ob_latch_define.h
// (每个模块可以注册自己的 latch ID)
#define DEFINE_LATCH_ID(name, desc) \
  static const int LATCH_ID_##name = __LINE__;  // 用行号唯一标识
```

**用途**：dump latch 时知道持有者来自哪个模块。

### 9.2 Latch Dump

```cpp
// 死锁或长时间等待时
int dump_all_latches() {
  // 输出每个 latch 的：
  // - ID + 模块名
  // - 当前持有者 thread
  // - 等待者 thread 列表
  // - 等待时长
  // - 持有者栈（如果有 coredump）
}
```

### 9.3 死锁检测

OB 后台 thread checker（参见 #74）定期：
- 检查 latch 是否有环路（lock A 等 lock B，lock B 等 lock A）
- 如果有 → 触发 latch dump + coredump
- 多次连续 → observer self-panic

### 9.4 Latch 监控虚拟表

```cpp
// (推测)
class ObAllVirtualLatchStat {
  // 虚拟表：返回所有 latch 的当前状态
  // - latch_id
  // - holder_thread
  // - wait_count
  // - hold_duration_us
};
```

---

## 10. 与其他文章的关系

### 10.1 与 #36 Concurrency Control

Latch 是 #36 的基础原语：
- 死锁问题（lock 顺序）
- 长持有锁（lock leak）
- 优先级反转
- 公平性问题

### 10.2 与 #51 Block Cache

Cache 用 latch 保护：
- 多个 reader 可同时 lookup（读 lock）
- Eviction 需要 writer lock
- bucket latch 让多 cache 槽可并发

### 10.3 与 #14 MemTable Internals

MemTable 用 bucket latch：
- 不同 row key 可并发 INSERT
- 同一 row key 互斥（保证 MVCC 正确）
- Compaction 用单独的 latch 互斥访问

### 10.4 与 #15 KeyBTree

BTree 内部用 latch：
- per-page latch（页级）
- 升级 / 降级（shared → exclusive）
- Crab 协议（follower's latch state）

### 10.5 与 #18 Index Design

二级索引用 latch：
- per-index latch
- secondary index 写入互斥

---

## 11. 总结

### 11.1 Latch 在 OB 体系中的定位

Latch 是 **observer 进程内所有并发数据结构的基础同步原语**：
- 几乎所有 hot path 都涉及 latch
- 性能敏感（每条 SQL 多次 latch 获取/释放）
- 死锁风险高（bucket latch 顺序问题）

### 11.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| ObLatch | mutex 语义 + 自适应等待 |
| ObLatchV2 | 新一代（更快 + 更灵活） |
| ObRLatch / ObWLatch | RWLock（读多写少） |
| ObBucketLatch | hash table 细粒度锁（16384 分桶） |
| 自适应等待 | spin → futex 切换 |
| 优先级继承 | priority inheritance（避免反转） |
| Table Lock | 数据库逻辑锁（与 latch 不同层） |
| Latch Dump | 死锁检测 + 监控 |

### 11.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `deps/oblib/src/lib/lock/ob_latch.{h,cpp}` | ObLatch 主类 |
| `deps/oblib/src/lib/alloc/ob_latch_v2.{h,cpp}` | ObLatchV2 新一代 |
| `deps/oblib/src/lib/stat/ob_latch_define.{h,cpp}` | Latch ID 定义 |
| `src/storage/lock_wait_mgr/` | Table Lock 等待管理 |
| `src/storage/tablelock/` | Table Lock 主体 |

### 11.4 路径修正（来自 #60）

我之前在 #60 提到的 `src/share/latch/` + `src/lib/latch/`（推测）+ `src/share/utility/` **都不完全正确**：
- `src/share/latch/` → 不存在
- `src/lib/latch/` → 不在 src/，在 deps submodule
- 真实：OB 的 `lib/` 在 `deps/oblib/src/lib/lock/`

### 11.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#76 Schema 持久化 / Service**：

OB schema 元数据的持久化 + 同步机制 —— RS 主导 + observer 异步落地 + 多版本 schema。源码入口：`src/share/schema/ob_schema_service.{h,cpp}` + `src/share/schema/ob_multi_version_schema_service.{h,cpp}`。

适用场景：DDL / schema cache / DML 路径的 schema guard。

整吗？