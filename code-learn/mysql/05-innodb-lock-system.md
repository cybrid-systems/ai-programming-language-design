# 05-innodb-lock-system — InnoDB 锁系统：行锁、Gap 锁、Next-Key、死锁检测

## 0. 概述

InnoDB 的锁系统（lock-sys）是事务并发的核心基础设施。与操作系统级别的 mutex/latch 不同，InnoDB 的锁（lock）是**高级并发控制原语**——它们由事务持有、可排队等待、可死锁检测、最终随事务提交/回滚释放。

### 0.1 Lock vs Latch

| 维度 | Lock（锁） | Latch（闩锁） |
|------|-----------|---------------|
| 保护对象 | 表、行、谓词（逻辑资源） | 内存数据结构（Buffer Pool page, B-tree node） |
| 持有者 | 事务（trx_t） | 线程（OS thread） |
| 死锁检测 | 有（wait-for graph 分析） | 无（需代码规避） |
| 持续时间 | 到事务结束（两阶段锁） | 临界区结束即释放 |
| 回滚 | 可死锁回滚 | 无此概念 |

InnoDB 也有自己的 mutex 实现（`ib_mutex_t`），但 latch 更常用 `rw_lock_t`（读写锁）。Lock-sys 使用 `Lock_mutex`（即 `ib_mutex_t`）保护内部队列，使用 `locksys::Latches` 分片保护锁队列。

### 0.2 InnoDB 锁类型

InnoDB 实现三种逻辑锁类型：
1. **行锁（Record Lock）**：锁住索引记录本身
2. **表锁（Table Lock）**：锁住整张表（意向锁 + DDL 锁）
3. **谓词锁（Predicate Lock）**：用于空间索引（GIS）

对应的 `lock_t::type()` 通过 `type_mode & LOCK_TYPE_MASK` 区分：
- `LOCK_REC（32）` — 行锁
- `LOCK_TABLE（16）` — 表锁
- `LOCK_PREDICATE（8192）` / `LOCK_PRDT_PAGE（16384）` — 谓词锁

### 0.3 锁算法

- **Record Lock**：仅锁记录本身（`LOCK_REC_NOT_GAP`）
- **Gap Lock**：锁记录前的间隙（`LOCK_GAP`），防止幻读
- **Next-Key Lock**：Record Lock + Gap Lock 的组合（`LOCK_ORDINARY = 0`），即默认的行锁模式
- **Insert Intention Lock**：插入前在间隙设置的等待锁（`LOCK_INSERT_INTENTION`）

```c
// lock0lock.h:87-99
/** Lock modes and types */
constexpr uint32_t LOCK_MODE_MASK = 0xF;
constexpr uint32_t LOCK_TABLE = 16;    // table lock
constexpr uint32_t LOCK_REC = 32;      // record lock
constexpr uint32_t LOCK_TYPE_MASK = 0xF0UL;
constexpr uint32_t LOCK_WAIT = 256;    // waiting flag
constexpr uint32_t LOCK_ORDINARY = 0;  // next-key lock (no extra bits)
constexpr uint32_t LOCK_GAP = 512;     // gap lock
constexpr uint32_t LOCK_REC_NOT_GAP = 1024;   // record-only lock
constexpr uint32_t LOCK_INSERT_INTENTION = 2048; // insert intention
constexpr uint32_t LOCK_PREDICATE = 8192;   // predicate lock
constexpr uint32_t LOCK_PRDT_PAGE = 16384;  // predicate page lock
```

---

## 1. 核心数据结构

### 1.1 lock_t — 通用锁结构

`lock_t` 是 `ib_lock_t` 的别名，是所有锁对象的通用结构体。它包含事务指针、索引指针、type_mode 位域，以及一个联合体（表锁或行锁）。

```c
// lock0types.h:43-52 (forward declaration)
#define lock_t ib_lock_t
#include "trx0types.h"
struct lock_t;
struct lock_sys_t;
struct lock_table_t;
```

```c
// lock0priv.h:127-208 — lock_t 完整定义
struct alignas(8 /* For efficient Bitmap::find_set */) lock_t {
  /** transaction owning the lock */
  trx_t *trx;
  /** list of the locks of the transaction */
  UT_LIST_NODE_T(lock_t) trx_locks;
  /** Index for a record lock */
  dict_index_t *index;
  /** Hash chain node for a record lock */
  lock_t *hash;
  union {
    lock_table_t tab_lock;      /** Table lock */
    lock_rec_t rec_lock;        /** Record lock */
  };
  uint32_t type_mode;   /* The lock type and mode bit flags */
  // ... methods: is_record_lock(), is_predicate(), is_waiting(),
  //     is_gap(), is_record_not_gap(), is_next_key_lock(),
  //     is_insert_intention(), includes_supremum(), mode(), type()
};
```

关键成员方法：
- `type()` — 从 `type_mode` 提取 `LOCK_REC` / `LOCK_TABLE`
- `mode()` — 提取 `LOCK_MODE_MASK`（LOCK_IS, LOCK_IX 等）
- `is_waiting()` — 检查 `LOCK_WAIT` 位
- `is_gap()` — 检查 `LOCK_GAP` 位
- `is_next_key_lock()` — `LOCK_ORDINARY`（非 GAP 非 REC_NOT_GAP 的 S/X 锁）

```c
// lock0priv.h:173-176
bool is_next_key_lock() const {
  return is_record_lock() && lock_mode_is_next_key_lock(type_mode);
}
```

`lock_mode_is_next_key_lock()` 定义在 `lock0priv.h:113-119`：

```c
// lock0priv.h:113-119
static inline bool lock_mode_is_next_key_lock(ulint mode) {
  static_assert(LOCK_ORDINARY == 0, "LOCK_ORDINARY must be 0 (no flags)");
  mode &= ~(LOCK_WAIT | LOCK_REC);
  return (mode & ~(LOCK_MODE_MASK)) == LOCK_ORDINARY;
}
```

### 1.2 lock_rec_t — 行锁结构

```c
// lock0priv.h:84-101
struct lock_rec_t {
  /** The id of the page on which records referenced by this lock's bitmap
  are located. */
  page_id_t page_id;
  /** number of bits in the lock bitmap; Must be divisible by 8.
  NOTE: the lock bitmap is placed immediately after the lock struct */
  uint32_t n_bits;

  std::ostream &print(std::ostream &out) const;
};
```

行锁使用**位图（bitmap）**来标识同一页上哪些 heap_no 被锁。位图紧跟在 `lock_t` 结构体之后：

```c
// lock0priv.h:198-200
Bitset<const byte> bitset() const {
  ut_ad(is_record_lock());
  const byte *bitmap = (const byte *)&this[1];  // bitmap after lock struct
  ut_ad(rec_lock.n_bits % 8 == 0);
  return {bitmap, rec_lock.n_bits / 8};
}
```

Bitmap 的每个 bit 对应 `PAGE_HEAP_NO_SUPREMUM` 索引——这意味着一个 `lock_t` 对象可以同时锁定同一页上的多条记录。`lock_rec_set_nth_bit()` 和 `lock_rec_get_nth_bit()` 用于操作位图。

### 1.3 lock_table_t — 表锁结构

```c
// lock0priv.h:54-65
struct lock_table_t {
  dict_table_t *table;  /* database table in dictionary cache */
  UT_LIST_NODE_T(lock_t) locks;  /* list of locks on the same table */
  std::ostream &print(std::ostream &out) const;
};
```

表锁通过 `UT_LIST_NODE_T` 嵌入在 `dict_table_t::locks` 双向链表中。`TableLockGetNode` 仿函数提供获取节点的方法：

```c
// lock0priv.h:227-231
struct TableLockGetNode {
  static const ut_list_node<lock_t> &get_node(const lock_t &lock) {
    return lock.tab_lock.locks;
  }
};
```

### 1.4 lock_sys_t — 全局锁系统

全局单例 `lock_sys` 统筹所有锁资源：

```c
// lock0lock.h:1069-1107
struct lock_sys_t {
  /** The latches protecting queues of record and table locks */
  locksys::Latches latches;

  /** The hash table of the record (LOCK_REC) locks */
  Locks_hashtable rec_hash;
  /** The hash table of predicate (LOCK_PREDICATE) locks */
  Locks_hashtable prdt_hash;
  /** The hash table of the predicate page (LOCK_PRDT_PAGE) locks */
  Locks_hashtable prdt_page_hash;

  /** number of calls to lock_sys_resize() so far */
  uint32_t n_resizes;

  /** The mutex protecting wait-related fields */
  Lock_mutex wait_mutex;
  /** Array of user threads suspended while waiting for locks */
  srv_slot_t *waiting_threads;
  /** The highest slot ever used in the waiting_threads array */
  srv_slot_t *last_slot;
  /** true if rollback of all recovered transactions is complete */
  bool rollback_complete;
  /** Max lock wait time observed */
  std::chrono::steady_clock::duration n_lock_max_wait_time;
  /** Event for lock wait monitor thread */
  os_event_t timeout_event;
};

extern lock_sys_t *lock_sys;  // lock0lock.h:1130
```

`lock_sys_t` 包含三个哈希表，分别存放不同类型的记录锁。初始化在 `lock_sys_create()` 中完成：

```c
// lock0lock.cc:305-334
void lock_sys_create(ulint n_cells) {
  lock_sys = ut::new_withkey<lock_sys_t>(UT_NEW_THIS_FILE_PSI_KEY, n_cells);
  lock_sys->n_resizes = 0;
  lock_sys->rollback_complete = false;
  mutex_create(LATCH_ID_LOCK_SYS_WAIT, &lock_sys->wait_mutex);
  lock_sys->waiting_threads = (srv_slot_t *)ut::zalloc_withkey(
      UT_NEW_THIS_FILE_PSI_KEY, srv_max_n_threads * sizeof(srv_slot_t));
  lock_sys->last_slot = lock_sys->waiting_threads;
  lock_sys->n_lock_max_wait_time = {};
  lock_sys->timeout_event = os_event_create("lock_wait_timeout");
}
```

### 1.5 lock_mode 枚举

```c
// lock0types.h:55-69
enum lock_mode {
  LOCK_IS = 0,          /* intention shared */
  LOCK_IX,              /* intention exclusive */
  LOCK_S,               /* shared */
  LOCK_X,               /* exclusive */
  LOCK_AUTO_INC,        /* locks the auto-inc counter of a table */
  LOCK_NONE,            /* used elsewhere to note consistent read */
  LOCK_NUM = LOCK_NONE, /* number of lock modes */
  LOCK_NONE_UNSET = 255
};
```

### 1.6 Locks_hashtable — 锁的哈希组织

`Locks_hashtable` 是一个支持按页快速查找的哈希容器，它使用 `hash_table_t` 实现，并提供 `find_on_page()`、`find_on_block()`、`find_on_record()` 等模板方法：

```c
// lock0lock.h:966-1015
struct Locks_hashtable {
  using Cells_in_use = ut::Sharded_bitset<locksys::Latches::SHARDS_COUNT>;
  Locks_hashtable(size_t n_cells);
  void append(lock_t *lock, uint64_t hash_value);
  void prepend(lock_t *lock, uint64_t hash_value);
  void erase(lock_t *lock, uint64_t hash_value);
  void move_to_front(lock_t *lock, uint64_t hash_value);
  void resize(size_t n_cells);
  template <typename F> lock_t *find_in_cell(size_t cell_id, F &&f);
  template <typename F> lock_t *find_on_page(page_id_t page_id, F &&f);
  template <typename F> lock_t *find_on_record(const struct RecID &rec_id, F &&f);
  // ...
};
```

`find_on_record()` 的实现遍历哈希链，通过 `RecID::matches()` 过滤：

```c
// lock0priv.h:1023-1028
template <typename F>
lock_t *Locks_hashtable::find_on_record(const struct RecID &rec_id, F &&f) {
  return find_in_cell(hash_calc_cell_id(rec_id.hash_value(), ht.get()),
                      [&](lock_t *lock) {
                        return rec_id.matches(lock) && std::forward<F>(f)(lock);
                      });
}
```

---

## 2. 锁模式与兼容性矩阵

### 2.1 五种基本锁模式

| 模式 | 名称 | 典型用途 |
|------|------|---------|
| LOCK_IS | 意向共享锁 | SELECT ... LOCK IN SHARE MODE（表级意向） |
| LOCK_IX | 意向独占锁 | SELECT ... FOR UPDATE / UPDATE / DELETE（表级意向） |
| LOCK_S | 共享锁 | 普通行锁读 |
| LOCK_X | 独占锁 | 行更新/删除 |
| LOCK_AUTO_INC | 自增锁 | INSERT 时的自增值保护 |

### 2.2 兼容性矩阵

```c
// lock0priv.h:291-295
static const byte lock_compatibility_matrix[5][5] = {
    /**         IS     IX       S     X       AI */
    /* IS */ {true, true, true, false, true},
    /* IX */ {true, true, false, false, true},
    /* S  */ {true, false, true, false, false},
    /* X  */ {false, false, false, false, false},
    /* AI */ {true, true, false, false, false}};
```

兼容性检查函数：

```c
// lock0priv.h:355-357
static inline ulint lock_mode_compatible(enum lock_mode mode1,
                                         enum lock_mode mode2) {
  return (ulint)lock_compatibility_matrix[mode1][mode2];
}
```

**强于或等于关系**用于判断一个模式是否包含了另一个模式的权限：

```c
// lock0priv.h:300-310
static const byte lock_strength_matrix[5][5] = {
    /**         IS     IX       S     X       AI */
    /* IS */ {true, false, false, false, false},
    /* IX */ {true, true, false, false, false},
    /* S  */ {true, false, true, false, false},
    /* X  */ {true, true, true, true, true},
    /* AI */ {false, false, false, false, true}};
```

从矩阵可以得出关键结论：
- LOCK_S 与 LOCK_IX **不兼容**——如果你在读行，别人不能修改表结构
- LOCK_X 与任何非 AI 锁**都不兼容**
- LOCK_IS/LOCK_IX 意向锁之间**完全兼容**——多个事务可以同时持有意向锁
- AI 锁与 IS/IX 兼容，但与 S/X 冲突

### 2.3 type_mode 位域编码

`type_mode` 是一个 32 位无符号整数，通过位操作提取不同的信息：

```c
// lock0lock.h:87-99
constexpr uint32_t LOCK_MODE_MASK = 0xF;           // bits 0-3: lock mode
// LOCK_TABLE = 16 (bit 4)
// LOCK_REC = 32 (bit 5)
constexpr uint32_t LOCK_TYPE_MASK = 0xF0UL;         // bits 4-7: lock type
constexpr uint32_t LOCK_WAIT = 256;                  // bit 8: waiting flag
constexpr uint32_t LOCK_GAP = 512;                   // bit 9: gap flag
constexpr uint32_t LOCK_REC_NOT_GAP = 1024;          // bit 10: no gap
constexpr uint32_t LOCK_INSERT_INTENTION = 2048;     // bit 11: insert intention
constexpr uint32_t LOCK_PREDICATE = 8192;            // bit 13: predicate
constexpr uint32_t LOCK_PRDT_PAGE = 16384;           // bit 14: predicate page
```

`type_mode` 的典型组合：

```
LOCK_X | LOCK_ORDINARY (0)           = 4  → Next-Key X 锁（默认行锁）
LOCK_S | LOCK_ORDINARY (0)           = 2  → Next-Key S 锁
LOCK_X | LOCK_GAP                    = 4 | 512  → Gap X 锁
LOCK_X | LOCK_REC_NOT_GAP           = 4 | 1024 → Record X 锁
LOCK_X | LOCK_GAP | LOCK_INSERT_INTENTION = 4 | 512 | 2048 → Insert Intention 锁
LOCK_S | LOCK_REC_NOT_GAP           = 2 | 1024 → Record S 锁（READ COMMITTED）
```

`lock_t::type_mode_string()` 用于调试输出：

```c
// lock0priv.h:234-252
inline std::string lock_t::type_mode_string() const {
  std::ostringstream sout;
  sout << type_string();
  sout << " | " << lock_mode_string(mode());
  if (is_record_not_gap()) sout << " | LOCK_REC_NOT_GAP";
  if (is_waiting()) sout << " | LOCK_WAIT";
  if (is_gap()) sout << " | LOCK_GAP";
  if (is_insert_intention()) sout << " | LOCK_INSERT_INTENTION";
  return (sout.str());
}
```

---

## 3. 行锁加锁路径

### 3.1 lock_rec_lock() — 行锁入口

`lock_rec_lock()` 是行锁加锁的核心入口。它先尝试快路径 `lock_rec_lock_fast()`；快路径失败（有其他事务的锁）则走慢路径 `lock_rec_lock_slow()`。

```c
// lock0lock.cc:1864-1898
static dberr_t lock_rec_lock(bool impl, select_mode sel_mode, ulint mode,
                             const buf_block_t *block, ulint heap_no,
                             dict_index_t *index, que_thr_t *thr) {
  ut_ad(locksys::owns_page_shard(block->get_page_id()));
  ut_ad(!srv_read_only_mode);
  ut_ad((LOCK_MODE_MASK & mode) != LOCK_S ||
        lock_table_has(thr_get_trx(thr), index->table, LOCK_IS));
  ut_ad((LOCK_MODE_MASK & mode) != LOCK_X ||
        lock_table_has(thr_get_trx(thr), index->table, LOCK_IX));
  ut_ad((LOCK_MODE_MASK & mode) == LOCK_S || (LOCK_MODE_MASK & mode) == LOCK_X);
  ut_ad(mode - (LOCK_MODE_MASK & mode) == LOCK_GAP ||
        mode - (LOCK_MODE_MASK & mode) == LOCK_REC_NOT_GAP ||
        mode - (LOCK_MODE_MASK & mode) == 0);
  ut_ad(!impl || ((mode & LOCK_REC_NOT_GAP) == LOCK_REC_NOT_GAP));

  /* Try a simplified and faster subroutine for the most common cases */
  switch (lock_rec_lock_fast(impl, mode, block, heap_no, index, thr)) {
    case LOCK_REC_SUCCESS:       return (DB_SUCCESS);
    case LOCK_REC_SUCCESS_CREATED: return (DB_SUCCESS_LOCKED_REC);
    case LOCK_REC_FAIL:
      return (lock_rec_lock_slow(impl, sel_mode, mode, block, heap_no, index, thr));
    default: ut_error;
  }
}
```

关键点：入参 `impl=true` 时，若不需要等待，则不创建显式锁（隐式锁优化——通过 trx_id 实现的轻量级锁）。`impl` 仅在请求 `LOCK_REC_NOT_GAP` 的 X 锁时有效。

### 3.2 lock_rec_lock_fast() — 快路径

快路径处理最常见的情况：页上没有锁、或页上只有当前事务自己的兼容锁：

```c
// lock0lock.cc:1617-1690
static inline lock_rec_req_status lock_rec_lock_fast(
    bool impl, ulint mode,
    const buf_block_t *block, ulint heap_no,
    dict_index_t *index, que_thr_t *thr) {
  ut_ad(locksys::owns_page_shard(block->get_page_id()));

  lock_t *lock = nullptr;
  lock_t *other_lock =
      lock_sys->rec_hash.find_on_block(block, [&](lock_t *seen) {
        if (lock != nullptr) return true;
        lock = seen;
        return false;
      });

  trx_t *trx = thr_get_trx(thr);
  lock_rec_req_status status = LOCK_REC_SUCCESS;

  if (lock == nullptr) {
    /* No locks at all on this page */
    if (!impl) {
      RecLock rec_lock(index, block, heap_no, mode);
      trx_mutex_enter(trx);
      rec_lock.create(trx);
      trx_mutex_exit(trx);
      status = LOCK_REC_SUCCESS_CREATED;
    }
  } else {
    trx_mutex_enter(trx);
    if (other_lock != nullptr || lock->trx != trx ||
        lock->type_mode != (mode | LOCK_REC) ||
        lock_rec_get_n_bits(lock) <= heap_no) {
      status = LOCK_REC_FAIL;  // Can't fast-path
    } else if (!impl) {
      if (!lock_rec_get_nth_bit(lock, heap_no)) {
        lock_rec_set_nth_bit(lock, heap_no);
        status = LOCK_REC_SUCCESS_CREATED;
      }
    }
    trx_mutex_exit(trx);
  }
  return (status);
}
```

快路径的三个场景：
1. **页上无锁** → 创建新锁（`RecLock::create`）
2. **页上只有本事务的锁且 type_mode 匹配** → 直接在 bitmap 中设位
3. **否则** → 返回 `LOCK_REC_FAIL`，交由慢路径处理

### 3.3 lock_rec_lock_slow() — 慢路径

慢路径处理有冲突的场景。它先检查当前事务是否已有足够强的锁（通过 `lock_rec_has_expl`），再检查其他事务的冲突锁（`lock_rec_other_has_conflicting`）。

```c
// lock0lock.cc:1749-1862
static dberr_t lock_rec_lock_slow(bool impl, select_mode sel_mode, ulint mode,
                                  const buf_block_t *block, ulint heap_no,
                                  dict_index_t *index, que_thr_t *thr) {
  ut_ad(locksys::owns_page_shard(block->get_page_id()));
  trx_t *trx = thr_get_trx(thr);

  /* Optimization: if we need a Next-Key Lock and we already have
  a Record Lock, we can split the request into just a GAP Lock */
  auto checked_mode =
      (heap_no != PAGE_HEAP_NO_SUPREMUM && lock_mode_is_next_key_lock(mode))
          ? mode | LOCK_REC_NOT_GAP
          : mode;

  const auto *held_lock = lock_rec_has_expl(checked_mode, block, heap_no, trx);

  if (held_lock != nullptr) {
    if (checked_mode == mode) {
      return (DB_SUCCESS);  // Already have sufficient lock
    }
    /* Need Next-Key Lock but have only Record Lock — add GAP */
    ut_ad(!impl);
    lock_reuse_for_next_key_lock(held_lock, mode, block, heap_no, index, trx);
    return (DB_SUCCESS);
  }

  const auto conflicting =
      lock_rec_other_has_conflicting(mode, block, heap_no, trx);

  if (conflicting.wait_for != nullptr) {
    switch (sel_mode) {
      case SELECT_SKIP_LOCKED: return (DB_SKIP_LOCKED);
      case SELECT_NOWAIT:      return (DB_LOCK_NOWAIT);
      case SELECT_ORDINARY:
        RecLock rec_lock(thr, index, block, heap_no, mode);
        trx_mutex_enter(trx);
        dberr_t err = rec_lock.add_to_waitq(conflicting.wait_for);
        trx_mutex_exit(trx);
        return (err);
    }
  }

  /* No conflict — create explicit lock */
  if (!impl || conflicting.bypassed) {
    lock_rec_add_to_queue(LOCK_REC | mode, block, heap_no, index, trx);
    return (DB_SUCCESS_LOCKED_REC);
  }
  return (DB_SUCCESS);
}
```

### 3.4 lock_rec_enqueue() — 入队逻辑

`lock_rec_add_to_queue()` 是底层的锁入队函数。它先尝试在相同 page 上查找已有的、属于同一事务的兼容锁来复用 bitmap，否则创建新锁：

```c
// lock0lock.cc:1507-1576
static void lock_rec_add_to_queue(ulint type_mode, const buf_block_t *block,
                                  const ulint heap_no, dict_index_t *index,
                                  trx_t *trx,
                                  const bool we_own_trx_mutex = false) {
  ut_ad(locksys::owns_page_shard(block->get_page_id()));

  type_mode |= LOCK_REC;

  /* For supremum, reset gap bits — supremum locks are always gap-type */
  if (heap_no == PAGE_HEAP_NO_SUPREMUM) {
    ut_ad(!(type_mode & LOCK_REC_NOT_GAP));
    type_mode &= ~(LOCK_GAP | LOCK_REC_NOT_GAP);
  }

  if (!(type_mode & LOCK_WAIT)) {
    /* Look for an existing lock to reuse */
    bool found_waiter_before_lock = false;
    lock_t *lock =
        lock_hash_get(type_mode).find_on_block(block, [&](lock_t *lock) {
          if (lock->trx == trx && lock->type_mode == type_mode &&
              heap_no < lock_rec_get_n_bits(lock)) return true;
          if (lock->is_waiting()) found_waiter_before_lock = true;
          return false;
        });

    if (lock != nullptr) {
      if (!lock_rec_get_nth_bit(lock, heap_no)) {
        lock_rec_set_nth_bit(lock, heap_no);
        if (found_waiter_before_lock) {
          lock_rec_move_granted_to_front(lock, RecID{lock, heap_no});
        }
      }
      return;
    }
  }

  /* No existing lock found — create new one */
  RecLock rec_lock(index, block, heap_no, type_mode);
  if (!we_own_trx_mutex) trx_mutex_enter(trx);
  rec_lock.create(trx);
  if (!we_own_trx_mutex) trx_mutex_exit(trx);
}
```

`RecLock::create()` 分配锁结构并加入哈希表和事务锁列表：

```c
// lock0lock.cc:1287-1326
lock_t *RecLock::create(trx_t *trx, const lock_prdt_t *prdt) {
  ut_ad(locksys::owns_page_shard(m_rec_id.get_page_id()));
  ut_ad(trx_mutex_own(trx));

  lock_t *lock = lock_alloc(trx, m_index, m_mode, m_rec_id, m_size);
  if (prdt != nullptr && (m_mode & LOCK_PREDICATE)) {
    lock_prdt_set_prdt(lock, prdt);
  }
  lock_add(lock);
  return (lock);
}
```

### 3.5 lock_clust_rec_read_check_and_lock() — 聚簇索引行锁

该函数是聚簇索引读操作的加锁入口。它首先将隐式锁转换为显式锁（如果需要），然后调用 `lock_rec_lock()`：

```c
// lock0lock.cc:5495-5540
dberr_t lock_clust_rec_read_check_and_lock(
    const lock_duration_t duration, const buf_block_t *block, const rec_t *rec,
    dict_index_t *index, const ulint *offsets, const select_mode sel_mode,
    const lock_mode mode, const ulint gap_mode, que_thr_t *thr) {
  ulint heap_no;
  ut_ad(index->is_clustered());
  ut_ad(page_rec_is_user_rec(rec) || page_rec_is_supremum(rec));

  if (srv_read_only_mode || index->table->is_temporary()) {
    return (DB_SUCCESS);
  }

  heap_no = page_rec_get_heap_no(rec);

  if (heap_no != PAGE_HEAP_NO_SUPREMUM) {
    lock_rec_convert_impl_to_expl(block, rec, index, offsets);
  }

  {
    locksys::Shard_latch_guard guard{UT_LOCATION_HERE, block->get_page_id()};

    if (duration == lock_duration_t::AT_LEAST_STATEMENT) {
      lock_protect_locks_till_statement_end(thr);
    }

    ut_ad(mode != LOCK_X ||
          lock_table_has(thr_get_trx(thr), index->table, LOCK_IX));
    ut_ad(mode != LOCK_S ||
          lock_table_has(thr_get_trx(thr), index->table, LOCK_IS));

    err = lock_rec_lock(false, sel_mode, mode | gap_mode, block, heap_no,
                        index, thr);
    MONITOR_INC(MONITOR_NUM_RECLOCK_REQ);
  }

  ut_ad(err == DB_SUCCESS || err == DB_SUCCESS_LOCKED_REC ||
        err == DB_LOCK_WAIT || err == DB_DEADLOCK || err == DB_SKIP_LOCKED ||
        err == DB_LOCK_NOWAIT);
  return (err);
}
```

### 3.6 lock_sec_rec_read_check_and_lock() — 二级索引行锁

二级索引的加锁路径与聚簇索引类似，但省略了隐式锁转换（二级索引通过事务 ID 字段判断）：

```c
// lock0lock.cc:5446-5487
dberr_t lock_sec_rec_read_check_and_lock(
    const lock_duration_t duration, const buf_block_t *block, const rec_t *rec,
    dict_index_t *index, const ulint *offsets, const select_mode sel_mode,
    const lock_mode mode, const ulint gap_mode, que_thr_t *thr) {
  ut_ad(!index->is_clustered());
  ut_ad(!dict_index_is_online_ddl(index));
  ut_ad(mode == LOCK_X || mode == LOCK_S);

  if (srv_read_only_mode || index->table->is_temporary()) {
    return (DB_SUCCESS);
  }

  heap_no = page_rec_get_heap_no(rec);

  if (!page_rec_is_supremum(rec)) {
    lock_rec_convert_impl_to_expl(block, rec, index, offsets);
  }

  {
    locksys::Shard_latch_guard guard{UT_LOCATION_HERE, block->get_page_id()};
    if (duration == lock_duration_t::AT_LEAST_STATEMENT) {
      lock_protect_locks_till_statement_end(thr);
    }
    ut_ad(mode != LOCK_X ||
          lock_table_has(thr_get_trx(thr), index->table, LOCK_IX));
    ut_ad(mode != LOCK_S ||
          lock_table_has(thr_get_trx(thr), index->table, LOCK_IS));

    err = lock_rec_lock(false, sel_mode, mode | gap_mode, block, heap_no,
                        index, thr);
    MONITOR_INC(MONITOR_NUM_RECLOCK_REQ);
  }
  return (err);
}
```

---

## 4. 表锁加锁路径

### 4.1 lock_table() — 表锁入口

```c
// lock0lock.cc:3534-3620
dberr_t lock_table(ulint flags, dict_table_t *table, lock_mode mode,
                   que_thr_t *thr) {
  trx_t *trx = thr_get_trx(thr);
  dberr_t err;
  const lock_t *wait_for;

  if ((flags & BTR_NO_LOCKING_FLAG) || srv_read_only_mode ||
      table->is_temporary()) {
    return (DB_SUCCESS);
  }

  /* Check if trx already has equal or stronger lock */
  if (lock_table_has(trx, table, mode)) {
    ut_ad(lock_table_has(trx, table, mode));
    return (DB_SUCCESS);
  }

  if ((mode == LOCK_IX || mode == LOCK_X) && !trx->read_only &&
      trx->rsegs.m_redo.rseg == nullptr) {
    trx_set_rw_mode(trx);
  }

  locksys::Shard_latch_guard table_latch_guard{UT_LOCATION_HERE, *table};

  wait_for = lock_table_other_has_incompatible(trx, LOCK_WAIT, table, mode);

  trx_mutex_enter(trx);

  if (wait_for != nullptr) {
    err = lock_table_enqueue_waiting(mode | flags, table, thr, wait_for);
  } else {
    lock_table_create(table, mode | flags, trx);
    err = DB_SUCCESS;
  }

  trx_mutex_exit(trx);
  ut_ad(err == DB_SUCCESS || err == DB_LOCK_WAIT || err == DB_DEADLOCK);
  return (err);
}
```

### 4.2 lock_table_for_trx() — 事务表锁

`lock_table_for_trx()` 是外面 SQL 层（LOCK TABLES）调用的接口：

```c
// lock0lock.cc:3764-3790
dberr_t lock_table_for_trx(dict_table_t *table, trx_t *trx,
                           enum lock_mode mode) {
  dberr_t err;
  que_thr_t *thr;

  thr = trx->mysql_thd ? thd_get_ha_data(trx->mysql_thd, ha_thd_innodb())
                       : nullptr;

  /* If thr is not NULL, we may call lock_table with proper BTR_NO_LOCKING_FLAG
  handling */
  if (thr != nullptr) {
    err = lock_table(0, table, mode, thr);
  } else {
    /* We have no query thread, so have to handle locking directly. */
    err = lock_table(0, table, mode, nullptr);
  }

  return (err);
}
```

### 4.3 lock_table_create() — 表锁创建

内联函数，分配并初始化表锁结构：

```c
// lock0lock.cc:3246-3307
static inline lock_t *lock_table_create(
    dict_table_t *table,     /* table to lock */
    ulint mode,              /* lock mode */
    trx_t *trx)              /* transaction */
{
  lock_t *lock = lock_alloc_from_heap(trx->lock.lock_heap, 0);

  lock->trx = trx;
  lock->index = nullptr;
  lock->hash = nullptr;
  lock->type_mode = (mode | LOCK_TABLE);
  lock->tab_lock.table = table;

  /* Add to trx's list and table's list */
  UT_LIST_ADD_FIRST(trx->lock.trx_locks, lock);
  UT_LIST_ADD_FIRST(table->locks, lock);

  /* Update count_by_mode for fast compatibility checks */
  table->count_by_mode[mode & LOCK_MODE_MASK]++;

  /* Set wait state if needed */
  if (mode & LOCK_WAIT) {
    lock_set_lock_and_trx_wait(lock);
  }

  return (lock);
}
```

### 4.4 意向锁 (IS/IX) 的自动加锁

行锁加锁路径中，`lock_rec_lock()` 断言事务已持有对应的意向表锁：

```c
// lock0lock.cc:1871-1872
ut_ad((LOCK_MODE_MASK & mode) != LOCK_S ||
      lock_table_has(thr_get_trx(thr), index->table, LOCK_IS));
ut_ad((LOCK_MODE_MASK & mode) != LOCK_X ||
      lock_table_has(thr_get_trx(thr), index->table, LOCK_IX));
```

如果事务还没有意向锁，上层调用（如 `sel_set_rec_lock`）会在加行锁前先调用 `lock_table(0, table, LOCK_IX, thr)`。

---

## 5. Gap Lock 与 Next-Key Lock

### 5.1 Gap Lock 的作用（防止幻读）

Gap Lock 锁住记录之间的间隙，防止其他事务在此间隙插入新记录。在 `REPEATABLE READ` 级别，InnoDB 使用 Gap Lock + Next-Key Lock 防止幻读。

Gap Lock 的核心规则（见 `lock0priv.h` 注释）：
- **不同事务可以持冲突的 Gap Lock** — Gap 锁之间不互斥
- **Gap Lock 只阻止插入**，不阻止对已有记录的修改
- **Supremum 记录上的锁总是 Gap 类型**（即使未设 LOCK_GAP 位）

Gap 锁的冲突检查在 `rec_lock_check_conflict()` 中：

```c
// lock0lock.cc:554-649
static inline Conflict rec_lock_check_conflict(const trx_t *trx,
                                               ulint type_mode,
                                               const lock_t *lock2,
                                               bool lock_is_on_supremum,
                                               Trx_locks_cache &trx_locks_cache)
{
  if (trx == lock2->trx ||
      lock_mode_compatible(static_cast<lock_mode>(LOCK_MODE_MASK & type_mode),
                           lock_get_mode(lock2))) {
    return Conflict::NO_CONFLICT;
  }

  /* Gap type locks without LOCK_INSERT_INTENTION flag do not need to wait */
  if ((lock_is_on_supremum || (type_mode & LOCK_GAP)) &&
      !(type_mode & LOCK_INSERT_INTENTION)) {
    return Conflict::NO_CONFLICT;
  }

  /* Record lock does not need to wait for a gap type lock */
  if (!(type_mode & LOCK_INSERT_INTENTION) && lock_rec_get_gap(lock2)) {
    return Conflict::NO_CONFLICT;
  }

  /* Lock on gap does not need to wait for LOCK_REC_NOT_GAP */
  if ((type_mode & LOCK_GAP) && lock_rec_get_rec_not_gap(lock2)) {
    return Conflict::NO_CONFLICT;
  }

  /* No lock needs to wait for insert intention locks */
  if (lock_rec_get_insert_intention(lock2)) {
    return Conflict::NO_CONFLICT;
  }

  /* ... remaining conflict checks ... */
  return Conflict::HAS_TO_WAIT;
}
```

关键结论：**Gap Lock 从不阻塞另一个 Gap Lock**。Gap Lock 只阻塞 Insert Intention Lock。

### 5.2 Next-Key = Record Lock + Gap Lock

Next-Key Lock 实际上是**Record Lock + Gap Lock 的组合语义**。当一个事务持有 Next-Key Lock 时，它既锁住了记录本身（防止修改），也锁住了记录前的间隙（防止插入）。

`lock_reuse_for_next_key_lock()` 演示了这种"分解"思想——如果事务已经持有 Record Lock，只需额外加一个 Gap Lock 即可组成 Next-Key Lock：

```c
// lock0lock.cc:1695-1747
static void lock_reuse_for_next_key_lock(const lock_t *held_lock, ulint mode,
                                         const buf_block_t *block,
                                         ulint heap_no, dict_index_t *index,
                                         trx_t *trx) {
  ut_ad(mode == LOCK_S || mode == LOCK_X);
  ut_ad(lock_mode_is_next_key_lock(mode));

  if (!held_lock->is_record_not_gap()) {
    ut_ad(held_lock->is_next_key_lock());
    return;  // Already a Next-Key Lock
  }

  /* We have a Record Lock granted, so we only need a GAP Lock */
  mode |= LOCK_GAP;

  /* Check if already have a GAP lock */
  if (lock_rec_has_expl(mode, block, heap_no, trx) == nullptr) {
    lock_rec_add_to_queue(LOCK_REC | mode, block, heap_no, index, trx);
  }
}
```

### 5.3 在 REPEATABLE READ 级别下的加锁规则

对于 `WHERE id = ?` 的条件查询（唯一索引），在 REPEATABLE READ 下：
- 如果记录存在：加 `LOCK_X | LOCK_REC_NOT_GAP`（仅锁记录）
- 如果记录不存在：加 `LOCK_X | LOCK_GAP`（锁间隙，阻止幻读）

对于范围查询（`WHERE id > ?`）：
- 扫描到的每条记录加 Next-Key Lock
- 最后一条扫描记录后的 Supremum 加 Gap Lock

### 5.4 唯一索引上的临键锁降级

在唯一索引上，如果搜索条件精确匹配（等值查询且唯一键），InnoDB 降级 Next-Key Lock 为 Record Lock（仅锁记录）。这是因为唯一索引的等值查询确定最多匹配一条记录，不会产生幻读。

降级逻辑发生在上层调用，通过传递 `LOCK_REC_NOT_GAP` 而非 `LOCK_ORDINARY` 实现。例如 `row_sel_set_rec_lock()` 针对唯一索引的等值查找会传递 `LOCK_REC_NOT_GAP`。

---

## 6. 锁释放与事务结束

### 6.1 lock_trx_release_locks() — 释放所有锁

事务提交或回滚时，`lock_trx_release_locks()` 释放该事务持有的所有锁：

```c
// lock0lock.cc:5890-5980
void lock_trx_release_locks(trx_t *trx) {
  DEBUG_SYNC_C("before_lock_trx_release_locks");

  trx_mutex_enter(trx);
  check_trx_state(trx);
  ut_ad(trx_state_eq(trx, TRX_STATE_COMMITTED_IN_MEMORY));
  ut_ad(!trx->in_rw_trx_list);

  /* Wait for implicit-to-explicit conversions to finish */
  if (trx_is_referenced(trx)) {
    while (trx_is_referenced(trx)) {
      trx_mutex_exit(trx);
      ut_delay(ut::random_from_interval_fast(0, srv_spin_wait_delay));
      trx_mutex_enter(trx);
    }
  }

  ut_ad(!trx_is_referenced(trx));
  trx_mutex_exit(trx);

  /* Release all locks in a loop */
  while (!locksys::try_release_all_locks(trx)) {
    std::this_thread::yield();
  }

  /* Clean up the lock heap */
  trx_mutex_enter(trx);
  trx->lock.n_rec_locks.store(0);
  ut_a(UT_LIST_GET_LEN(trx->lock.trx_locks) == 0);
  ut_a(ib_vector_is_empty(trx->lock.autoinc_locks));
  mem_heap_empty(trx->lock.lock_heap);
  trx_mutex_exit(trx);
}
```

`try_release_all_locks()` 逐一释放所有锁，对每个锁都通过 `try_relatch_trx_and_shard_and_do()` 模式处理——先获取 trx mutex，提取锁、确定 shard、释放 trx mutex、获取 shard latch、再获取 trx mutex 验证锁仍然有效，最后执行释放：

```c
// lock0lock.cc:4298-4336 (inside locksys namespace)
[[nodiscard]] static bool try_release_all_locks(trx_t *trx) {
  if (UT_LIST_GET_LEN(trx->lock.trx_locks) == 0) return true;

  Global_shared_latch_guard shared_latch_guard{UT_LOCATION_HERE};
  trx_mutex_enter(trx);
  ut_ad(trx->lock.wait_lock == nullptr);

  while ((lock = UT_LIST_GET_LAST(trx->lock.trx_locks)) != nullptr) {
    try_relatch_trx_and_shard_and_do(lock, [=]() {
      if (lock_get_type_low(lock) == LOCK_REC) {
        lock_rec_dequeue_from_page(lock);
      } else {
        lock_table_dequeue(lock);
      }
    });
    if (shared_latch_guard.is_x_blocked_by_us()) {
      trx_mutex_exit(trx);
      return false;  // Someone wants exclusive latch — retry
    }
  }
  trx_mutex_exit(trx);
  return true;
}
```

### 6.2 lock_trx_release_read_locks() — 释放读锁

在 READ COMMITTED 隔离级别下，语句结束时需要释放读锁（Gap Lock 和 Record S Lock）。XA PREPARE 阶段也会调用此函数：

```c
// lock0lock.cc:4089-4097
void lock_trx_release_read_locks(trx_t *trx, bool only_gap) {
  ut_ad(trx_can_be_handled_by_current_thread(trx));

  const size_t MAX_FAILURES = 5;

  for (size_t failures = 0; failures < MAX_FAILURES; ++failures) {
    if (locksys::try_release_read_locks_in_s_mode(trx, only_gap)) {
      return;
    }
    std::this_thread::yield();
  }

  while (!locksys::try_release_read_locks_in_x_mode(trx, only_gap)) {
    std::this_thread::yield();
  }
}
```

先尝试 shared mode（性能更好），如果被阻塞则尝试 exclusive mode。

### 6.3 两阶段锁协议

InnoDB 遵循**两阶段锁协议（2PL）**：
1. **扩展阶段**：事务执行过程中不断地获取锁
2. **收缩阶段**：事务提交或回滚时释放所有锁

锁**不是在每条语句结束时**释放（READ COMMITTED 级别的读锁除外）。这就是为什么长事务会持有大量锁，导致并发下降。

`lock_on_statement_end()` 在每条语句结束后调用，只在 READ COMMITTED 以下级别释放读锁：

```c
// lock0lock.h:264
void lock_on_statement_end(trx_t *trx);
```

---

## 7. 锁等待与死锁检测

### 7.1 lock_wait_suspend_thread() — 挂起等待线程

当事务无法立即获得锁时，`RecLock::add_to_waitq()` 设置等待状态，然后 `lock_wait_suspend_thread()` 挂起当前线程：

```c
// lock0wait.cc:206-344
void lock_wait_suspend_thread(que_thr_t *thr) {
  trx_t *trx = thr_get_trx(thr);
  const auto lock_wait_timeout = trx_lock_wait_timeout_get(trx);

  lock_wait_mutex_enter();
  trx_mutex_enter(trx);

  trx->error_state = DB_SUCCESS;

  if (thr->state == QUE_THR_RUNNING) {
    /* Lock already granted or deadlock victim */
    if (trx->lock.was_chosen_as_deadlock_victim) {
      trx->error_state = DB_DEADLOCK;
      trx->lock.was_chosen_as_deadlock_victim = false;
      ut_d(trx->lock.in_rollback = true);
    }
    lock_wait_mutex_exit();
    trx_mutex_exit(trx);
    return;
  }

  ut_ad(!thr->is_active);
  slot = lock_wait_table_reserve_slot(thr, lock_wait_timeout);

  lock_wait_mutex_exit();

  auto lock_type = trx->lock.wait_lock_type;
  trx_mutex_exit(trx);

  /* Release dict lock if held */
  ulint had_dict_lock = trx->dict_operation_lock_mode;
  // ... handle dict lock release ...

  thd_wait_begin(trx->mysql_thd, lock_type == LOCK_REC ? THD_WAIT_ROW_LOCK
                                                       : THD_WAIT_TABLE_LOCK);

  os_event_wait(slot->event);  // ← 线程在此睡眠

  thd_wait_end(trx->mysql_thd);

  // ... reacquire dict lock if needed ...

  lock_wait_table_release_slot(slot);

  // ... update lock wait stats ...

  if (trx->error_state == DB_DEADLOCK) {
    ut_d(trx->lock.in_rollback = true);
    return;
  }
  if (trx->error_state == DB_LOCK_WAIT_TIMEOUT) {
    MONITOR_INC(MONITOR_TIMEOUT);
  }
  if (trx_is_interrupted(trx)) {
    trx->error_state = DB_INTERRUPTED;
  }
}
```

### 7.2 等待超时机制

锁等待超时检测由 `lock_wait_timeout_thread()` 线程定期执行：

```c
// lock0wait.cc:1432-1458
void lock_wait_timeout_thread() {
  int64_t sig_count = 0;
  os_event_t event = lock_sys->timeout_event;

  auto last_checked_for_timeouts_at = std::chrono::steady_clock::now();

  do {
    auto current_time = std::chrono::steady_clock::now();
    if (std::chrono::seconds(1) <=
        current_time - last_checked_for_timeouts_at) {
      last_checked_for_timeouts_at = current_time;
      lock_wait_check_slots_for_timeouts();
    }

    lock_wait_update_schedule_and_check_for_deadlocks();

    /* Wake up every second (at worst) */
    os_event_wait_time_low(event, std::chrono::seconds{1}, sig_count);
    sig_count = os_event_reset(event);
  } while (srv_shutdown_state.load() < SRV_SHUTDOWN_CLEANUP);
}
```

`lock_wait_check_slots_for_timeouts()` 遍历 `waiting_threads` 数组，对每个超时的 slot 调用 `lock_wait_check_and_cancel()`：

```c
// lock0wait.cc:541-552
static void lock_wait_check_slots_for_timeouts() {
  ut_ad(!lock_wait_mutex_own());
  lock_wait_mutex_enter();

  for (auto slot = lock_sys->waiting_threads; slot < lock_sys->last_slot;
       ++slot) {
    if (slot->in_use) {
      lock_wait_check_and_cancel(slot);
    }
  }
  lock_wait_mutex_exit();
}
```

### 7.3 死锁检测：lock_wait_build_wait_for_graph()

死锁检测的核心是构建等待图（wait-for graph）并寻找环。`lock_wait_timeout_thread()` 定期调用 `lock_wait_update_schedule_and_check_for_deadlocks()`，后者调用 `lock_wait_snapshot_waiting_threads()` 抓取快照，然后构建等待图：

```c
// lock0wait.cc:650-660
static void lock_wait_build_wait_for_graph(
    ut::vector<waiting_trx_info_t> &infos, ut::vector<int> &outgoing) {
  ut_ad(infos.size() < std::numeric_limits<uint>::max());
  const auto n = static_cast<uint>(infos.size());
  outgoing.clear();
  outgoing.resize(n, -1);

  /* Sort infos by ::trx, use lower_bound to find index of ::wait_for,
  which gives O(nlgn) complexity */
  // ... build wait-for graph ...
}
```

死锁检测使用 CATS（Contention-Aware Lock Scheduling）算法的加权调度：

```c
// lock0wait.cc:1390-1420 (lock_wait_update_schedule_and_check_for_deadlocks)
static void lock_wait_update_schedule_and_check_for_deadlocks() {
  ut::vector<waiting_trx_info_t> infos;
  ut::vector<int> outgoing;
  ut::vector<trx_schedule_weight_t> new_weights;

  auto table_reservations = lock_wait_snapshot_waiting_threads(infos);
  lock_wait_build_wait_for_graph(infos, outgoing);

  lock_wait_compute_and_publish_weights_except_cycles(infos, table_reservations,
                                                      outgoing, new_weights);

  if (innobase_deadlock_detect) {
    lock_wait_find_and_handle_deadlocks(infos, outgoing, new_weights);
  }
}
```

### 7.4 死锁回滚：lock_wait_rollback_deadlock_victim()

检测到死锁后，选择受害者并回滚：

```c
// lock0wait.cc:692-705
static void lock_wait_rollback_deadlock_victim(trx_t *chosen_victim) {
  ut_ad(!trx_mutex_own(chosen_victim));
  ut_ad(locksys::owns_exclusive_global_latch());

  trx_mutex_enter(chosen_victim);
  chosen_victim->lock.was_chosen_as_deadlock_victim = true;
  ut_a(chosen_victim->lock.wait_lock != nullptr);
  ut_a(chosen_victim->lock.que_state == TRX_QUE_LOCK_WAIT);

  lock_cancel_waiting_and_release(chosen_victim);
  trx_mutex_exit(chosen_victim);
}
```

受害者选择策略（`lock_wait_find_and_handle_deadlocks`）：
1. 找出死锁环中的所有事务
2. 选择 `reservation_no` 最大（最新加入环）的事务为受害者
3. 如果平局，倾向于回滚 `lock_wait_order_for_choosing_victim()` 中排在后面的

### 7.5 innodb_lock_wait_timeout 与 innodb_deadlock_detect

```c
// lock0lock.h:41
extern bool innobase_deadlock_detect;
```

系统变量控制：
- `innodb_deadlock_detect=ON`（默认）：`lock_wait_find_and_handle_deadlocks()` 每次调度时都会运行
- `innodb_deadlock_detect=OFF`：跳过死锁检测，事务等待直到 `innodb_lock_wait_timeout` 超时

`innodb_lock_wait_timeout` 默认 50 秒，在 `lock_wait_table_reserve_slot()` 时设置到 slot：

```c
// lock0wait.cc:206-210
slot = lock_wait_table_reserve_slot(thr, lock_wait_timeout);
```

超时检测在 `lock_wait_check_and_cancel()` 中进行——如果 `slot->wait_timeout` 耗尽，设置 `trx->error_state = DB_LOCK_WAIT_TIMEOUT` 并唤醒事务。

---

## 8. Predicate Lock

### 8.1 谓词锁用于空间索引

空间索引（R-Tree）使用谓词锁（Predicate Lock）而不是 Gap Lock 来保护范围。这是必要的，因为空间数据没有自然的序关系，Gap Lock 无法适用。

谓词锁通过两个独立的哈希表维护：

```c
// lock0lock.h:1082-1083
/** The hash table of predicate (LOCK_PREDICATE) locks */
Locks_hashtable prdt_hash;
/** The hash table of the predicate page (LOCK_PRDT_PAGE) locks */
Locks_hashtable prdt_page_hash;
```

### 8.2 谓词锁的位图特殊处理

谓词锁的 bitmap 只有 1 个 bit，因为锁总是在 `PAGE_HEAP_NO_INFIMUM`：

```c
// lock0priv.h:578-586
static size_t lock_size(ulint mode) {
  if (mode & LOCK_PREDICATE) {
    const ulint align = UNIV_WORD_SIZE - 1;
    n_bytes = (1 + sizeof(lock_prdt_t) + align) & ~align;
    ut_ad(n_bytes == sizeof(lock_prdt_t) + UNIV_WORD_SIZE);
  } else {
    n_bytes = 1;
  }
  return (n_bytes);
}
```

---

## 9. 锁监控

### 9.1 SHOW ENGINE INNODB STATUS 中的锁信息

`lock_print_info_all_transactions()` 输出所有事务的锁信息。它使用 `All_locks_iterator` 遍历所有锁队列：

```c
// lock0lock.cc:4765 (inside lock_print_info_all_transactions)
for (auto lock : trx->lock.trx_locks) {
  if (lock_get_type_low(lock) == LOCK_TABLE) {
    lock_table_print(file, lock);
  } else {
    lock_rec_print(file, lock);
  }
}
```

### 9.2 information_schema 中的锁表

`lock_trx_print_wait_and_mvcc_state()` 输出事务的等待和 MVCC 状态：

```c
// lock0lock.h:1149
void lock_trx_print_wait_and_mvcc_state(FILE *file, const trx_t *trx);
```

`All_locks_iterator` 的 `iterate_over_next_batch()` 遍历所有锁，分阶段进行：
1. `TABLE_LOCKS` — 遍历所有表的表锁队列
2. `PRDT_PAGE_LOCKS` — 遍历 `prdt_page_hash`
3. `PRDT_LOCKS` — 遍历 `prdt_hash`
4. `REC_LOCKS` — 遍历 `rec_hash`

```c
// lock0iter.cc:110-150
bool All_locks_iterator::iterate_over_next_batch(
    const std::function<void(const lock_t &lock)> &f) {
  bool found_at_least_one_lock = false;
  auto report_lock = [&found_at_least_one_lock, &f](const lock_t &lock) {
    f(lock);
    found_at_least_one_lock = true;
  };

  while (!found_at_least_one_lock && m_stage != stage_t::DONE) {
    switch (m_stage) {
      case stage_t::TABLE_LOCKS:
        is_stage_finished = !iterate_over_current_table(report_lock);
        break;
      case stage_t::PRDT_PAGE_LOCKS:
        is_stage_finished =
            !iterate_over_current_cell(lock_sys->prdt_page_hash, report_lock);
        break;
      case stage_t::PRDT_LOCKS:
        is_stage_finished =
            !iterate_over_current_cell(lock_sys->prdt_hash, report_lock);
        break;
      case stage_t::REC_LOCKS:
        is_stage_finished =
            !iterate_over_current_cell(lock_sys->rec_hash, report_lock);
        break;
      // ...
    }
    if (is_stage_finished) {
      m_stage = static_cast<stage_t>(to_int(m_stage) + 1);
      m_bucket_id = 0;
    }
  }
  return m_stage == stage_t::DONE;
}
```

### 9.3 lock_sys_t 中的统计数据

```c
// lock0lock.h:1103
/** Max lock wait time observed, for innodb_row_lock_time_max reporting. */
std::chrono::steady_clock::duration n_lock_max_wait_time;
```

在 `lock_wait_suspend_thread()` 中更新：

```c
// lock0wait.cc:324-330
if (diff_time > lock_sys->n_lock_max_wait_time) {
  lock_sys->n_lock_max_wait_time = diff_time;
}
thd_set_lock_wait_time(trx->mysql_thd, diff_time);
```

---

## 10. 完整数据流

### 10.1 SELECT ... FOR UPDATE 的加锁路径

```
SELECT ... FOR UPDATE
  → row_search_mvcc()
    → sel_set_rec_lock()
      → lock_table(0, table, LOCK_IX, thr)        // 表级 IX
      → lock_clust_rec_read_check_and_lock()       // 聚簇索引行锁
        → lock_rec_convert_impl_to_expl()          // 隐式→显式
        → lock_rec_lock(false, SELECT_ORDINARY,
                         LOCK_X|gap_mode, ...)     // 加行 X 锁
          → lock_rec_lock_fast()
            → (失败) lock_rec_lock_slow()
              → lock_rec_other_has_conflicting()   // 检查冲突
              → RecLock::add_to_waitq()            // 等待或加锁
```

`lock_clust_rec_read_check_and_lock()` 和 `lock_sec_rec_read_check_and_lock()` 都是在获取 shard latch 后调用 `lock_rec_lock()`：

```c
// lock0lock.cc:5519-5532
{
  locksys::Shard_latch_guard guard{UT_LOCATION_HERE, block->get_page_id()};

  if (duration == lock_duration_t::AT_LEAST_STATEMENT) {
    lock_protect_locks_till_statement_end(thr);
  }

  ut_ad(mode != LOCK_X ||
        lock_table_has(thr_get_trx(thr), index->table, LOCK_IX));
  ut_ad(mode != LOCK_S ||
        lock_table_has(thr_get_trx(thr), index->table, LOCK_IS));

  err = lock_rec_lock(false, sel_mode, mode | gap_mode, block, heap_no,
                      index, thr);
  MONITOR_INC(MONITOR_NUM_RECLOCK_REQ);
}
```

### 10.2 UPDATE 的加锁路径

```
UPDATE
  → row_upd_step()
    → row_upd_clust_rec() / row_upd_sec_rec()
      → lock_clust_rec_modify_check_and_lock()    // 聚簇索引
        → lock_rec_convert_impl_to_expl()
        → lock_rec_lock(true, SELECT_ORDINARY,
                         LOCK_X|LOCK_REC_NOT_GAP, ...)
      → lock_sec_rec_modify_check_and_lock()       // 二级索引
        → lock_rec_convert_impl_to_expl()
        → lock_rec_lock(true, SELECT_ORDINARY,
                         LOCK_X|LOCK_REC_NOT_GAP, ...)
```

修改操作加的是 `LOCK_X | LOCK_REC_NOT_GAP`（仅锁住记录本身，不锁间隙——因为修改的是已有记录，不是插入）。但在扫描阶段，`SELECT ... FOR UPDATE` 仍然使用 Next-Key Lock。

### 10.3 INSERT 的隐式锁

INSERT 是 InnoDB 中效率最高的加锁操作——它**不创建显式锁对象**，而是利用聚簇索引记录中的 `DB_TRX_ID` 字段作为**隐式锁**：

```c
// lock0priv.h:284-285
// An implicit x-lock on a clustered index record is indicated by
// the record's DB_TRX_ID showing an active transaction.
```

```c
// lock0lock.cc:236-271
bool lock_clust_rec_cons_read_sees(
    const rec_t *rec, dict_index_t *index,
    const ulint *offsets, ReadView *view) {
  trx_id_t trx_id = lock_clust_rec_some_has_impl(rec, index, offsets);
  if (trx_id == 0) return true;    // No implicit lock
  return (read_view_sees_trx_id(view, trx_id));  // Check MVCC visibility
}
```

隐式锁在下列情况下被转换为显式锁：
1. **其他事务请求冲突锁时**（`lock_rec_convert_impl_to_expl()`）
2. **B-tree 操作需要移动记录时**（split/merge）

```c
// lock0lock.cc:5433-5443
void lock_rec_convert_impl_to_expl(const buf_block_t *block, const rec_t *rec,
                                   dict_index_t *index, const ulint *offsets) {
  trx_t *trx;
  if (index->is_clustered()) {
    trx_id_t trx_id = lock_clust_rec_some_has_impl(rec, index, offsets);
    trx = trx_rw_is_active(trx_id, true);
  } else {
    trx = lock_sec_rec_some_has_impl(rec, index, offsets);
  }
  if (trx != nullptr) {
    lock_rec_convert_impl_to_expl_for_trx(block, rec, index, offsets, trx, heap_no);
  }
}
```

INSERT 只有一种情况需要显式锁：**插入前检查 gap 冲突**。`lock_rec_insert_check_and_lock()` 在插入前检查下一个记录是否有冲突锁：

```c
// lock0lock.cc:5125-5190
dberr_t lock_rec_insert_check_and_lock(
    ulint flags, const rec_t *rec, buf_block_t *block,
    dict_index_t *index, que_thr_t *thr, mtr_t *mtr, bool *inherit) {
  ut_ad(lock_table_has(trx, index->table, LOCK_IX));

  if (!lock_rec_has_any(lock_sys->rec_hash, block->get_page_id(), heap_no)) {
    *inherit = false;
  } else {
    *inherit = true;

    const ulint type_mode = LOCK_X | LOCK_GAP | LOCK_INSERT_INTENTION;

    const auto conflicting =
        lock_rec_other_has_conflicting(type_mode, block, heap_no, trx);

    ut_a(!conflicting.bypassed);

    if (conflicting.wait_for != nullptr) {
      RecLock rec_lock(thr, index, block, heap_no, type_mode);
      trx_mutex_enter(trx);
      err = rec_lock.add_to_waitq(conflicting.wait_for);
      trx_mutex_exit(trx);
    }
  }
  return (err);
}
```

### 10.4 锁升级与降级

**降级场景**（在 READ COMMITTED 级别下）：
- 语句结束后释放 Gap Lock（不再需要防止幻读），通过 `lock_trx_release_read_locks(trx, true)` 仅释放 Gap 锁
- 唯一索引等值查询降级 Next-Key Lock 为 Record Lock

**锁分裂**（在 `lock_rec_lock_slow` 中）：
- 当需要 Next-Key Lock 但已持有 Record Lock，只需添加 Gap Lock
- 当需要 Next-Key Lock 但无法立即获得，先检查是否已有兼容的 Record Lock

**锁继承**（在 B-tree split/merge 时）：
- `lock_update_split_right()` — 右分裂时移动锁
- `lock_update_merge_right()` — 右合并时移动锁
- `lock_update_insert()` — 插入时继承 Gap Lock
- `lock_update_delete()` — 删除时将锁转移到后继记录

```c
// lock0lock.h:214-226
void lock_update_split_right(const buf_block_t *right_block,
                             const buf_block_t *left_block);
void lock_update_merge_right(const buf_block_t *right_block,
                             const rec_t *orig_succ,
                             const buf_block_t *left_block);
void lock_update_insert(const buf_block_t *block, const rec_t *rec);
void lock_update_delete(const buf_block_t *block, const rec_t *rec);
```

---

## 11. 关键函数索引

| 函数 | 文件:行 | 作用 |
|------|---------|------|
| `lock_rec_lock()` | `lock0lock.cc:1864` | 行锁入口，分配快/慢路径 |
| `lock_rec_lock_fast()` | `lock0lock.cc:1617` | 行锁快路径（无冲突场景） |
| `lock_rec_lock_slow()` | `lock0lock.cc:1749` | 行锁慢路径（冲突检查+等待） |
| `lock_rec_add_to_queue()` | `lock0lock.cc:1507` | 底层锁入队 |
| `rec_lock_check_conflict()` | `lock0lock.cc:554` | 冲突检测核心逻辑 |
| `lock_has_to_wait()` | `lock0lock.cc:681` | 判断 lock1 是否需要等 lock2 |
| `lock_clust_rec_read_check_and_lock()` | `lock0lock.cc:5495` | 聚簇索引读加锁 |
| `lock_sec_rec_read_check_and_lock()` | `lock0lock.cc:5446` | 二级索引读加锁 |
| `lock_clust_rec_modify_check_and_lock()` | `lock0lock.h:237` | 聚簇索引修改加锁 |
| `lock_sec_rec_modify_check_and_lock()` | `lock0lock.h:248` | 二级索引修改加锁 |
| `lock_rec_insert_check_and_lock()` | `lock0lock.cc:5125` | 插入前检查间隙锁 |
| `lock_rec_convert_impl_to_expl()` | `lock0lock.cc:5433` | 隐式→显式锁转换 |
| `lock_table()` | `lock0lock.cc:3534` | 表锁入口 |
| `lock_table_for_trx()` | `lock0lock.cc:3764` | 事务表锁（DDL） |
| `lock_table_create()` | `lock0lock.cc:3246` | 创建表锁对象 |
| `lock_trx_release_locks()` | `lock0lock.cc:5890` | 事务结束时释放所有锁 |
| `lock_trx_release_read_locks()` | `lock0lock.cc:4089` | 释放读锁（RC隔离级别） |
| `lock_grant()` | `lock0lock.cc:1930` | 授予等待的锁并唤醒事务 |
| `RecLock::add_to_waitq()` | `lock0lock.cc:1445` | 加入等待队列 |
| `RecLock::create()` | `lock0lock.cc:1287` | 创建行锁对象 |
| `lock_reuse_for_next_key_lock()` | `lock0lock.cc:1695` | Next-Key 锁重用优化 |
| `lock_wait_suspend_thread()` | `lock0wait.cc:206` | 挂起等待线程 |
| `lock_wait_timeout_thread()` | `lock0wait.cc:1432` | 超时+死锁检测线程 |
| `lock_wait_check_slots_for_timeouts()` | `lock0wait.cc:541` | 超时扫描 |
| `lock_wait_build_wait_for_graph()` | `lock0wait.cc:650` | 构建等待图 |
| `lock_wait_rollback_deadlock_victim()` | `lock0wait.cc:692` | 回滚死锁受害者 |
| `lock_wait_update_schedule_and_check_for_deadlocks()` | `lock0wait.cc:1390` | 更新权重并检测死锁 |
| `lock_wait_compute_initial_weights()` | `lock0wait.cc:581` | CATS 权重初始化 |
| `lock_wait_accumulate_weights()` | `lock0wait.cc:892` | CATS 权重累加 |
| `lock_is_waiting()` | `lock0lock.cc:478` | 检查锁是否在等待 |
| `lock_rec_find_set_bit()` | `lock0lock.cc:691` | 查找 bitmap 中的第一个设置位 |
| `locksys::find_blockers()` | `lock0iter.cc:68` | 找到等待锁的所有阻塞者 |
| `All_locks_iterator::iterate_over_next_batch()` | `lock0iter.cc:110` | 遍历所有锁队列 |
| `lock_sys_create()` | `lock0lock.cc:305` | 初始化锁系统 |
| `lock_sys_resize()` | `lock0lock.cc:342` | 重设哈希表大小 |
| `lock_mode_compatible()` | `lock0priv.h:355` | 锁模式兼容性检查 |
| `lock_mode_stronger_or_eq()` | `lock0priv.h:362` | 锁模式强度检查 |

---

*本文基于 MySQL 8.4/9.0 源码分析，涵盖了 InnoDB 锁系统的核心数据结构、锁算法、加锁路径、冲突检测、死锁检测等机制。深入理解这些内容有助于解决死锁问题、优化并发性能以及进行 MySQL 内核开发。*
