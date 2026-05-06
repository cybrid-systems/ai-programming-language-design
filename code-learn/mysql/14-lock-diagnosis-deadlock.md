# 14-lock-diagnosis-deadlock — MySQL 锁诊断与死锁分析

## 0. 概述

锁诊断的核心任务是从运行中的 InnoDB 锁系统内部观察到三个关键信息：

1. **哪些锁在等待** — 等待中的 `lock_t` 对象，事务因兼容性冲突未能立即获得授权
2. **持有锁的事务** — 持有与等待锁冲突的已授权锁的 `trx_t`
3. **等待图（Wait-for Graph）** — 由所有等待事务形成的单向图的边，检测其中是否存在环

诊断工具链从高到低分三层：

- `SHOW ENGINE INNODB STATUS` — 调用 `lock_print_info_summary()` + `lock_print_info_all_transactions()`，输出死锁日志、事务列表及锁信息
- `INFORMATION_SCHEMA.INNODB_TRX` / `INNODB_LOCKS` / `INNODB_LOCK_WAITS` — 跨 I_S 虚拟表的关联查询
- 直接访问 `SELECT * FROM performance_schema.data_locks`、`data_lock_waits` — MySQL 8.0 引入的更细粒度的诊断接口

**死锁 vs 锁等待超时**：死锁意味着等待图中存在环，内核通过 `lock_wait_find_and_handle_deadlocks()` 检测环并回滚其中一个事务；锁等待超时则是单个事务等待超过 `innodb_lock_wait_timeout` 秒，由 `lock_wait_check_slots_for_timeouts()` 处理，不会回滚整个事务（仅取消当前语句的锁请求）。

---

## 1. 核心数据结构

### 1.1 lock_sys_t (lock0lock.h:1069) — 全局锁系统

全局唯一的 `lock_sys` 变量是整个锁系统的中枢。其结构定义如下：

```c
// lock0lock.h:1069
struct lock_sys_t {
  /** The latches protecting queues of record and table locks */
  locksys::Latches latches;

  /** The hash table of the record (LOCK_REC) locks, except for predicate
  (LOCK_PREDICATE) and predicate page (LOCK_PRDT_PAGE) locks */
  Locks_hashtable rec_hash;

  /** The hash table of predicate (LOCK_PREDICATE) locks */
  Locks_hashtable prdt_hash;

  /** The hash table of the predicate page (LOCK_PRD_PAGE) locks */
  Locks_hashtable prdt_page_hash;

  lock_sys_t(size_t n_cells)
      : rec_hash{n_cells}, prdt_hash{n_cells}, prdt_page_hash{n_cells} {}

  /** number of calls to lock_sys_resize() so far */
  uint32_t n_resizes;

  /** Padding to avoid false sharing of wait_mutex field */
  char pad2[ut::INNODB_CACHE_LINE_SIZE];

  /** The mutex protecting the next two fields */
  Lock_mutex wait_mutex;

  /** Array of user threads suspended while waiting for locks within InnoDB. */
  srv_slot_t *waiting_threads;

  /** The highest slot ever used in the waiting_threads array. */
  srv_slot_t *last_slot;

  /** true if rollback of all recovered transactions is complete. */
  bool rollback_complete;

  /** Max lock wait time observed. */
  std::chrono::steady_clock::duration n_lock_max_wait_time;

  /** Set to the event created in the lock wait monitor thread. */
  os_event_t timeout_event;
};
// lock0lock.h:1139 — extern declaration
extern lock_sys_t *lock_sys;
```

`rec_hash`、`prdt_hash`、`prdt_page_hash` 三个哈希表分别存储行锁、谓词锁和谓词页锁。`waiting_threads` 数组记录了所有因锁等待而挂起的用户线程，死锁检测和超时检查均依赖此数组。

`locksys::Latches` 是 InnoDB 8.0 引入的分片锁存器（sharded latch）架构，替代了早期版本单一的 `lock_sys->mutex`：

```c
// lock0latches.h:54
class Latches {
 private:
  /** Number of page shards, and also number of table shards. */
  static constexpr size_t SHARDS_COUNT = 512;

  /** A sharded read-write lock for "stop the world" operations. */
  Unique_sharded_rw_lock global_latch;

  Page_shards page_shards;
  Table_shards table_shards;

  friend class Global_exclusive_latch_guard;
  friend class Global_exclusive_try_latch;
  friend class Global_shared_latch_guard;
  friend class Shard_naked_latch_guard;
  // ...
};
// lock0latches.h:214
```

访问一个记录锁队列需要：
1. s-latch 全局锁存器（`global_latch`）
2. 计算目标 page_id 对应的 shard id
3. 加 shard 级 mutex

而死锁检测等需要"停世界"的操作，则通过 x-latch 全局锁存器实现。

### 1.2 lock_t / lock_rec_t / lock_table_t (lock0priv.h:54-84)

`lock_t` 是最核心的锁对象结构，它采用 tagged union 设计：

```c
// lock0priv.h:54
/** A table lock */
struct lock_table_t {
  dict_table_t *table; /*!< database table in dictionary cache */
  UT_LIST_NODE_T(lock_t)
  locks; /*!< list of locks on the same table */
};

// lock0priv.h:73
/** Record lock for a page */
struct lock_rec_t {
  /** The id of the page on which records referenced by this lock's bitmap are
  located. */
  page_id_t page_id;
  /** number of bits in the lock bitmap; must be divisible by 8. */
  uint32_t n_bits;
};

// lock0priv.h:124
/** Lock struct; protected by lock_sys latches */
struct alignas(8 /* For efficient Bitmap::find_set */) lock_t {
  /** transaction owning the lock */
  trx_t *trx;

  /** list of the locks of the transaction */
  UT_LIST_NODE_T(lock_t) trx_locks;

  /** Index for a record lock */
  dict_index_t *index;

  /** Hash chain node for a record lock. */
  lock_t *hash;

  union {
    /** Table lock */
    lock_table_t tab_lock;
    /** Record lock */
    lock_rec_t rec_lock;
  };

#ifdef HAVE_PSI_THREAD_INTERFACE
  /** Performance schema thread that created the lock. */
  ulonglong m_psi_internal_thread_id;
  ulonglong m_psi_event_id;
#endif

  /** The lock type and mode bit flags.
  LOCK_GAP or LOCK_REC_NOT_GAP, LOCK_INSERT_INTENTION, wait flag, ORed */
  uint32_t type_mode;

  // ...methods: is_record_lock(), is_waiting(), is_gap(),
  //             is_insert_intention(), mode(), type(), etc.
};
```

`lock_t` 的 `type_mode` 字段是整个锁系统的核心位域。低 4 位为锁模式（`LOCK_MODE_MASK = 0xF`），5-6 位为类型（表锁/行锁），高位为各种修饰标志：

```c
// lock0lock.h:940
constexpr uint32_t LOCK_MODE_MASK  = 0xF;
constexpr uint32_t LOCK_TABLE       = 16;
constexpr uint32_t LOCK_REC         = 32;
constexpr uint32_t LOCK_TYPE_MASK   = 0xF0UL;
constexpr uint32_t LOCK_WAIT       = 256;
constexpr uint32_t LOCK_ORDINARY    = 0;
constexpr uint32_t LOCK_GAP        = 512;
constexpr uint32_t LOCK_REC_NOT_GAP = 1024;
constexpr uint32_t LOCK_INSERT_INTENTION = 2048;
constexpr uint32_t LOCK_PREDICATE  = 8192;
constexpr uint32_t LOCK_PRDT_PAGE  = 16384;
```

行锁的 bitmap 紧跟在 `lock_t` 之后——`bitset()` 方法返回指向 `lock_t` 末尾的 `Bitset<byte>`，用以标记该锁覆盖了哪些 `heap_no`：

```c
// lock0priv.h:341
Bitset<const byte> bitset() const {
  ut_ad(is_record_lock());
  static_assert(8 <= alignof(lock_t), "...");
  const byte *bitmap = (const byte *)&this[1];
  ut_ad(reinterpret_cast<uintptr_t>(bitmap) % 8 == 0);
  ut_ad(rec_lock.n_bits % 8 == 0);
  return {bitmap, rec_lock.n_bits / 8};
}
```

这一设计非常精巧——一次 malloc 分配 `sizeof(lock_t) + n_bits/8` 字节，lock_t 尾巴直接贴着 bitmap，零额外指针开销。

### 1.3 lock_mode (lock0types.h:55) — 锁模式枚举

```c
// lock0types.h:55
enum lock_mode {
  LOCK_IS = 0,          /* intention shared */
  LOCK_IX,              /* intention exclusive */
  LOCK_S,               /* shared */
  LOCK_X,               /* exclusive */
  LOCK_AUTO_INC,        /* locks the auto-inc counter of a table */
  LOCK_NONE,            /* consistent read */
  LOCK_NUM = LOCK_NONE, /* number of lock modes */
  LOCK_NONE_UNSET = 255
};
```

锁兼容性矩阵存储于 `lock0priv.h` 中：

```c
// lock0priv.h:249
static const byte lock_compatibility_matrix[5][5] = {
    /**         IS     IX       S     X       AI */
    /* IS */ {true, true, true, false, true},
    /* IX */ {true, true, false, false, true},
    /* S  */ {true, false, true, false, false},
    /* X  */ {false, false, false, false, false},
    /* AI */ {true, true, false, false, false}};

// lock0priv.h:263
static const byte lock_strength_matrix[5][5] = {
    /**         IS     IX       S     X       AI */
    /* IS */ {true, false, false, false, false},
    /* IX */ {true, true, false, false, false},
    /* S  */ {true, false, true, false, false},
    /* X  */ {true, true, true, true, true},
    /* AI */ {false, false, false, false, true}};
```

冲突检测的核心函数是 `rec_lock_check_conflict()`，它的返回值有三种可能：

```c
// lock0lock.cc:526
enum class Conflict {
  HAS_TO_WAIT,
  NO_CONFLICT,
  CAN_BYPASS,
};
```

`CAN_BYPASS` 是 MySQL 8.0 引入的新语义——如果当前事务已持有一个锁，恰好阻挡了 `lock2` 的授权，那么当前事务可以"绕过" `lock2` 的等待。这避免了递归等待导致的假死锁。

### 1.4 Locks_hashtable — 锁哈希表结构

```c
// lock0lock.h:990
struct Locks_hashtable {
  using Cells_in_use = ut::Sharded_bitset<locksys::Latches::SHARDS_COUNT>;

  Locks_hashtable(size_t n_cells)
      : ht(ut::make_unique<hash_table_t>(n_cells)),
        cells_in_use(ht->get_n_cells(),
                     ut::make_psi_memory_key(mem_key_lock_sys)) {}

  void append(lock_t *lock, uint64_t hash_value);
  void prepend(lock_t *lock, uint64_t hash_value);
  void erase(lock_t *lock, uint64_t hash_value);
  void move_to_front(lock_t *lock, uint64_t hash_value);
  void resize(size_t n_cells);

  template <typename F>
  lock_t *find_in_cell(size_t cell_id, F &&f);
  template <typename F>
  lock_t *find_on_page(page_id_t page_id, F &&f);
  template <typename F>
  lock_t *find_on_block(const buf_block_t *block, F &&f);
  template <typename F>
  lock_t *find_on_record(const struct RecID &rec_id, F &&f);

 private:
  ut::unique_ptr<hash_table_t> ht;
  Cells_in_use cells_in_use;
};

// lock0priv.h:392
template <typename F>
lock_t *Locks_hashtable::find_in_cell(size_t cell_id, F &&f) {
  lock_t *lock = (lock_t *)hash_get_first(ht.get(), cell_id);
  while (lock != nullptr) {
    ut_ad(locksys::owns_lock_shard(lock));
    lock_t *next = lock->hash;
    if (std::forward<F>(f)(lock)) {
      return lock;
    }
    lock = next;
  }
  return nullptr;
}
```

锁哈希表的每个 cell 是一个单向链表，串连所有哈希到该 cell 的 `lock_t`（通过 `lock->hash` 指针）。查找记录上的锁时，先在 hash 表中定位 cell，然后遍历单向链表，用 `RecID::matches()` 匹配 `space+page_no+heap_no`。

---

## 2. SHOW ENGINE INNODB STATUS 锁信息输出

### 2.1 锁信息的来源代码路径

`SHOW ENGINE INNODB STATUS` 最终调用的是 `srv_printf_innodb_monitor()`，该函数内部调用 `lock_print_info_summary()` 和 `lock_print_info_all_transactions()` 输出锁信息。这两个函数都在 `lock0lock.cc` 中实现。

死锁日志缓存于全局 `FILE *lock_latest_err_file` 中，通过 `lock_deadlock_found` 布尔变量控制是否输出：

```c
// lock0lock.cc:202
static bool lock_deadlock_found = false;

/** Only created if !srv_read_only_mode. I/O operations on this file require
exclusive lock_sys latch */
static FILE *lock_latest_err_file;
```

### 2.2 lock_print_info_summary() — 锁信息输出入口

```c
// lock0lock.cc:4449
void lock_print_info_summary(FILE *file) {
  ut_ad(locksys::owns_exclusive_global_latch());

  if (lock_deadlock_found) {
    fputs(
        "------------------------\n"
        "LATEST DETECTED DEADLOCK\n"
        "------------------------\n",
        file);

    if (!srv_read_only_mode) {
      ut_copy_file(file, lock_latest_err_file);
    }
  }

  fputs(
      "------------\n"
      "TRANSACTIONS\n"
      "------------\n",
      file);

  fprintf(file, "Trx id counter " TRX_ID_FMT "\n",
          trx_sys_get_next_trx_id_or_no());

  fprintf(file,
          "Purge done for trx's n:o < " TRX_ID_FMT " undo n:o < " TRX_ID_FMT
          " state: ",
          purge_sys->iter.trx_no, purge_sys->iter.undo_no);

  // ... purge state printing ...

  fprintf(file, "\n");

  fprintf(file, "History list length " UINT64PF "\n",
          trx_sys->rseg_history_len.load());

#ifdef PRINT_NUM_OF_LOCK_STRUCTS
  fprintf(file, "Total number of lock structs in row lock hash table %zu\n",
          lock_get_n_rec_locks());
#endif
}
```

该函数的调用者需要持有全局排他锁存器（`exclusive global latch`）。它先输出死锁日志（如果 `lock_deadlock_found` 为 true），然后输出事务系统的摘要信息。

### 2.3 lock_print_info_all_transactions()

```c
// lock0lock.cc:4780
void lock_print_info_all_transactions(FILE *file) {
  ut_ad(locksys::owns_exclusive_global_latch());

  fprintf(file, "LIST OF TRANSACTIONS FOR EACH SESSION:\n");

  mutex_enter(&trx_sys->mutex);

  /* First print info on non-active transactions */
  PrintNotStarted print_not_started(file);
  ut_list_map(trx_sys->mysql_trx_list, print_not_started);

  const trx_t *trx;
  TrxListIterator trx_iter;
  const trx_t *prev_trx = nullptr;
  bool load_block = true;
  bool monitor = srv_print_innodb_lock_monitor;

  while ((trx = trx_iter.current()) != nullptr) {
    check_trx_state(trx);

    if (trx != prev_trx) {
      lock_trx_print_wait_and_mvcc_state(file, trx);
      prev_trx = trx;
      load_block = true;
    }

    if (monitor) {
      TrxLockIterator &lock_iter = trx_iter.lock_iter();
      if (!lock_trx_print_locks(file, trx, lock_iter, load_block)) {
        /* A page was read from disk, latches were temporarily released */
        load_block = false;
        continue;
      }
    }

    load_block = true;
    trx_iter.next();
  }

  mutex_exit(&trx_sys->mutex);
}
```

该函数使用 `TrxListIterator` 遍历 `trx_sys->rw_trx_list` 中的读写事务。对每个事务，调用 `lock_trx_print_wait_and_mvcc_state()` 输出等待状态和 MVCC 信息，再通过 `lock_trx_print_locks()` 迭代事务的锁列表。

在输出行锁内容时，如果页面不在 Buffer Pool 中，`lock_rec_fetch_page()` 会**临时释放全局锁存器和 `trx_sys->mutex`**，从磁盘读取页面，然后重新获取——这就是为什么函数需要处理 `load_block` 标志：

```c
// lock0lock.cc:4670
static bool lock_rec_fetch_page(const lock_t *lock) {
  ut_ad(lock_get_type_low(lock) == LOCK_REC);
  const page_id_t page_id = lock->rec_lock.page_id;
  // ...
  locksys::Unsafe_global_latch_manipulator::exclusive_unlatch();
  mutex_exit(&trx_sys->mutex);
  // ... read page from tablespace ...
  locksys::Unsafe_global_latch_manipulator::exclusive_latch(UT_LOCATION_HERE);
  mutex_enter(&trx_sys->mutex);
  return (true);
}
```

### 2.4 如何解析输出：事务列表、锁等待、deadlock 日志

每个事务的等待和 MVCC 状态由 `lock_trx_print_wait_and_mvcc_state()` 输出：

```c
// lock0lock.cc:4640
void lock_trx_print_wait_and_mvcc_state(FILE *file, const trx_t *trx) {
  ut_ad(locksys::owns_exclusive_global_latch());
  fprintf(file, "---");
  trx_print_latched(file, trx, 3000);

  const ReadView *read_view = trx_get_read_view(trx);
  if (read_view != nullptr) {
    read_view->print_limits(file);
  }

  if (trx->lock.que_state == TRX_QUE_LOCK_WAIT) {
    fprintf(file,
            "------- TRX HAS BEEN WAITING %" PRId64
            " SEC FOR THIS LOCK TO BE GRANTED:\n",
            static_cast<int64_t>(
                std::chrono::duration_cast<std::chrono::seconds>(
                    std::chrono::system_clock::now() - trx->lock.wait_started)
                    .count()));

    if (lock_get_type_low(trx->lock.wait_lock) == LOCK_REC) {
      lock_rec_print(file, trx->lock.wait_lock);
    } else {
      lock_table_print(file, trx->lock.wait_lock);
    }
    fprintf(file, "------------------\n");
  }
}
```

`lock_rec_print()` 的完整输出格式如下：

```c
// lock0lock.cc:4353
static void lock_rec_print(FILE *file, const lock_t *lock) {
  ut_a(lock_get_type_low(lock) == LOCK_REC);
  const auto page_id = lock->rec_lock.page_id;
  ut_ad(locksys::owns_page_shard(page_id));

  fprintf(file,
          "RECORD LOCKS space id %lu page no %lu n bits %llu "
          "index %s of table ",
          ulong{page_id.space()}, ulong{page_id.page_no()},
          ulonglong{lock_rec_get_n_bits(lock)}, lock->index->name());
  ut_print_name(file, lock->trx, lock->index->table_name);
  fprintf(file, " trx id " TRX_ID_FMT, trx_get_id_for_print(lock->trx));

  if (lock_get_mode(lock) == LOCK_S) {
    fputs(" lock mode S", file);
  } else if (lock_get_mode(lock) == LOCK_X) {
    fputs(" lock_mode X", file);
  } else {
    ut_error;
  }

  if (lock_rec_get_gap(lock))       fputs(" locks gap before rec", file);
  if (lock_rec_get_rec_not_gap(lock)) fputs(" locks rec but not gap", file);
  if (lock_rec_get_insert_intention(lock)) fputs(" insert intention", file);
  if (lock_get_wait(lock))          fputs(" waiting", file);

  // ... iterate bitmap to print each locked heap_no with record content ...
}
```

`lock_table_print()` 则简单得多：

```c
// lock0lock.cc:4318
static void lock_table_print(FILE *file, const lock_t *lock) {
  ut_a(lock_get_type_low(lock) == LOCK_TABLE);
  fputs("TABLE LOCK table ", file);
  ut_print_name(file, lock->trx, lock->tab_lock.table->name.m_name);
  fprintf(file, " trx id " TRX_ID_FMT, trx_get_id_for_print(lock->trx));

  if (lock_get_mode(lock) == LOCK_S)       fputs(" lock mode S", file);
  else if (lock_get_mode(lock) == LOCK_X)  fputs(" lock mode X", file);
  else if (lock_get_mode(lock) == LOCK_IS) fputs(" lock mode IS", file);
  else if (lock_get_mode(lock) == LOCK_IX) fputs(" lock mode IX", file);
  else if (lock_get_mode(lock) == LOCK_AUTO_INC) fputs(" lock mode AUTO-INC", file);

  if (lock_get_wait(lock)) fputs(" waiting", file);
  putc('\n', file);
}
```

---

## 3. INNODB_TRX / INNODB_LOCKS / INNODB_LOCK_WAITS

### 3.1 trx_i_s_lock_table_fill() — INNODB_LOCKS 信息填充

INFORMATION_SCHEMA 中的 `INNODB_TRX`、`INNODB_LOCKS`（8.0 后废弃，由 `performance_schema.data_locks` 替代）、`INNODB_LOCK_WAITS` 等虚拟表的实现位于 `storage/innobase/handler/i_s.cc`。

`INNODB_TRX` 表的字段定义为：

```c
// i_s.cc:397
static ST_FIELD_INFO innodb_trx_fields_info[] = {
  {"trx_id",                         MY_I_S_MAKE_PTR(TRX_ID_LEN,     MYSQL_TYPE_STRING),  0, 0, "", nullptr},
  {"trx_state",                      MY_I_S_MAKE_PTR(TRX_MAX_STATE_LEN, MYSQL_TYPE_STRING),0, 0, "", nullptr},
  {"trx_started",                    MY_I_S_MAKE_PTR(TRX_ID_LEN,     MYSQL_TYPE_STRING),  0, 0, "", nullptr},
  {"trx_requested_lock_id",          MY_I_S_MAKE_PTR(TRX_ID_LEN,     MYSQL_TYPE_STRING),  0, 0, "", nullptr},
  {"trx_wait_started",               MY_I_S_MAKE_PTR(TRX_ID_LEN,     MYSQL_TYPE_STRING),  0, 0, "", nullptr},
  {"trx_weight",                     MY_I_S_MAKE_PTR(MY_INT32_NUM_DECIMAL_DIGITS, MYSQL_TYPE_LONGLONG), 0, 0, "", nullptr},
  {"trx_mysql_thread_id",            MY_I_S_MAKE_PTR(MY_INT32_NUM_DECIMAL_DIGITS, MYSQL_TYPE_LONGLONG), 0, 0, "", nullptr},
  {"trx_query",                      MY_I_S_MAKE_PTR(TRX_MAX_QUERY_LEN, MYSQL_TYPE_STRING),  0, MY_I_S_MAYBE_NULL, "", nullptr},
  {"trx_operation_state",            MY_I_S_MAKE_PTR(TRX_QUE_STATE_LEN, MYSQL_TYPE_STRING),  0, 0, "", nullptr},
  // ... more fields ...
};
```

通过事务 ID 将三张表关联：`INNODB_TRX.trx_id` → `INNODB_LOCKS.lock_trx_id` → `INNODB_LOCK_WAITS.requested_lock_id / blocking_lock_id`。

### 3.2 各虚拟表的实现和查询路径

`INNODB_TRX` 的填充由 `fill_innodb_trx_from_cache()` 完成，它先构建一个缓存快照（持有 `trx_sys->mutex`），然后遍历所有事务填充字段：

```c
// i_s.cc:568
static int fill_innodb_trx_from_cache(
    i_s_trx_cache_t *cache,
    THD *thd,
    TABLE *table) {
  // ... populates the trx cache ...
  for (auto trx : trx_sys->rw_trx_list) {
    // ... copy trx state information ...
  }
  // ... write to I_S table ...
}
```

`INNODB_LOCKS` 和 `INNODB_LOCK_WAITS` 在 MySQL 8.0 中已废弃，替代方案是 `performance_schema.data_locks` 和 `performance_schema.data_lock_waits`，后者的数据来源为 `All_locks_iterator`：

```c
// lock0iter.cc:67
bool All_locks_iterator::iterate_over_next_batch(
    const std::function<void(const lock_t &lock)> &f) {
  bool found_at_least_one_lock = false;

  auto report_lock = [&found_at_least_one_lock, &f](const lock_t &lock) {
    f(lock);
    found_at_least_one_lock = true;
  };

  while (!found_at_least_one_lock && m_stage != stage_t::DONE) {
    bool is_stage_finished;
    switch (m_stage) {
      case stage_t::NOT_STARTED:
        m_table_ids = dict_get_all_table_ids();
        is_stage_finished = true;
        break;
      case stage_t::TABLE_LOCKS:
        is_stage_finished = !iterate_over_current_table(report_lock);
        break;
      case stage_t::PRDT_PAGE_LOCKS:
        is_stage_finished = !iterate_over_current_cell(
            lock_sys->prdt_page_hash, report_lock);
        break;
      case stage_t::PRDT_LOCKS:
        is_stage_finished = !iterate_over_current_cell(
            lock_sys->prdt_hash, report_lock);
        break;
      case stage_t::REC_LOCKS:
        is_stage_finished = !iterate_over_current_cell(
            lock_sys->rec_hash, report_lock);
        break;
      default: ut_error;
    }
    if (is_stage_finished) {
      m_stage = static_cast<stage_t>(to_int(m_stage) + 1);
      m_bucket_id = 0;
    }
  }
  return m_stage == stage_t::DONE;
}
```

`All_locks_iterator` 依次遍历：表锁 → 谓词页锁 → 谓词锁 → 行锁。每阶段从对应的哈希表中按 cell 逐批取出。为避免长时间持有锁存器，它在每批次之间释放共享锁存器。

---

## 4. 锁等待诊断

### 4.1 lock_wait_suspend_thread() — 线程挂起 (lock0wait.cc:206)

当一个事务请求锁失败（`DB_LOCK_WAIT`）后，最终会调用 `lock_wait_suspend_thread()` 将当前线程挂起：

```c
// lock0wait.cc:206
void lock_wait_suspend_thread(que_thr_t *thr) {
  srv_slot_t *slot;
  trx_t *trx;

  trx = thr_get_trx(thr);

  if (trx->mysql_thd != nullptr) {
    DEBUG_SYNC_C("lock_wait_suspend_thread_enter");
  }

  const auto lock_wait_timeout = trx_lock_wait_timeout_get(trx);

  lock_wait_mutex_enter();
  trx_mutex_enter(trx);

  trx->error_state = DB_SUCCESS;

  if (thr->state == QUE_THR_RUNNING) {
    ut_ad(thr->is_active);
    /* The lock has already been released or this transaction
    was chosen as a deadlock victim: no need to suspend */

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

  // ... release dict_operation_lock if held ...

  thd_wait_begin(trx->mysql_thd, lock_type == LOCK_REC ? THD_WAIT_ROW_LOCK
                                                       : THD_WAIT_TABLE_LOCK);

  os_event_wait(slot->event);   // ← 线程在此睡眠，等待 os_event_set()

  thd_wait_end(trx->mysql_thd);

  // ... reacquire dict_operation_lock ...

  const auto start_time = slot->suspend_time;
  lock_wait_table_release_slot(slot);

  if (thr->lock_state == QUE_THR_LOCK_ROW) {
    const auto diff_time = std::chrono::steady_clock::now() - start_time;

    srv_stats.n_lock_wait_time.add(
        std::chrono::duration_cast<std::chrono::microseconds>(diff_time).count());

    if (diff_time > lock_sys->n_lock_max_wait_time) {
      lock_sys->n_lock_max_wait_time = diff_time;
    }
  }

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

关键步骤说明：
1. 如果 `thr->state` 已经是 `QUE_THR_RUNNING`（说明锁刚好在挂起前被授权），则无需真正挂起，直接返回
2. 否则通过 `lock_wait_table_reserve_slot()` 在 `waiting_threads` 数组中分配一个槽
3. 调用 `os_event_wait(slot->event)` 线程睡眠——这是真正的挂起点
4. 唤醒后释放槽位，统计等待时间，检查唤醒原因（`DEADLOCK`/`TIMEOUT`/`INTERRUPTED`）

`lock_wait_table_reserve_slot()` 的实现如下：

```c
// lock0wait.cc:131
static srv_slot_t *lock_wait_table_reserve_slot(
    que_thr_t *thr,
    std::chrono::steady_clock::duration wait_timeout) {
  srv_slot_t *slot;
  ut_ad(lock_wait_mutex_own());
  ut_ad(trx_mutex_own(thr_get_trx(thr)));

  slot = lock_sys->waiting_threads;

  for (uint32_t i = srv_max_n_threads; i--; ++slot) {
    if (!slot->in_use) {
      slot->reservation_no = lock_wait_table_reservations++;
      slot->in_use = true;
      slot->thr = thr;
      slot->thr->slot = slot;

      if (slot->event == nullptr) {
        slot->event = os_event_create();
        ut_a(slot->event);
      }

      os_event_reset(slot->event);
      slot->suspended = true;
      slot->suspend_time = std::chrono::steady_clock::now();
      slot->wait_timeout = wait_timeout;
      if (thr->lock_state == QUE_THR_LOCK_ROW) {
        srv_stats.n_lock_wait_count.inc();
        srv_stats.n_lock_wait_current_count.inc();
      }

      if (slot == lock_sys->last_slot) {
        ++lock_sys->last_slot;
      }

      lock_wait_request_check_for_cycles();
      return (slot);
    }
  }

  ib::error(ER_IB_MSG_646) << "There appear to be " << srv_max_n_threads
      << " user threads currently waiting inside InnoDB...";
  lock_wait_table_print();
  ut_error;
}
```

### 4.2 lock_wait_check_slots_for_timeouts() — 超时检查

每分钟由 `lock_wait_timeout_thread()` 调用一次，遍历 `waiting_threads` 数组，检查每个挂起线程是否超时或被中断：

```c
// lock0wait.cc:541
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

单个槽的超时判断和取消操作在 `lock_wait_check_and_cancel()` 中：

```c
// lock0wait.cc:475
static void lock_wait_check_and_cancel(const srv_slot_t *slot) {
  const auto wait_time = std::chrono::steady_clock::now() - slot->suspend_time;
  const auto timeout = slot->wait_timeout < std::chrono::seconds{100000000} &&
                       wait_time > slot->wait_timeout;
  trx_t *trx = thr_get_trx(slot->thr);

  if (!trx_is_interrupted(trx) && !timeout) {
    return;
  }

  locksys::run_if_waiting({trx}, [&]() { lock_wait_try_cancel(trx, timeout); });
}
```

### 4.3 等待线程的 CATS 调度 (lock_wait_compute_initial_weights)

MySQL 8.0 引入了 CATS（Contention-Aware Lock Scheduling）调度算法。核心思想：**等待事务的调度权重等于它（传递地）阻塞的其他事务数量**。权重高的事务优先被唤醒。

```c
// lock0wait.cc:607
static void lock_wait_compute_initial_weights(
    const ut::vector<waiting_trx_info_t> &infos,
    const uint64_t table_reservations,
    ut::vector<trx_schedule_weight_t> &new_weights) {
  const size_t n = infos.size();
  const trx_schedule_weight_t WEIGHT_BOOST =
      n == 0 ? 1 : std::min<trx_schedule_weight_t>(n, 1e9 / n);
  new_weights.clear();
  new_weights.resize(n, 1);
  const uint64_t MAX_FAIR_WAIT = 2 * n;
  for (size_t from = 0; from < n; ++from) {
    if (infos[from].reservation_no + MAX_FAIR_WAIT < table_reservations) {
      new_weights[from] = WEIGHT_BOOST;
    }
  }
}
```

等待太久的事务（`reservation_no` 比当前 `table_reservations` 小 2n 以上）会获得 `WEIGHT_BOOST` 权重提升，避免饿死。

权重累积通过拓扑排序完成：

```c
// lock0wait.cc:834
static void lock_wait_accumulate_weights(
    ut::vector<uint> &incoming_count,
    ut::vector<trx_schedule_weight_t> &new_weights,
    const ut::vector<int> &outgoing) {
  ut_a(incoming_count.size() == outgoing.size());
  ut::vector<size_t> ready;
  const size_t n = incoming_count.size();
  for (size_t id = 0; id < n; ++id) {
    if (!incoming_count[id]) {
      ready.push_back(id);
    }
  }

  while (!ready.empty()) {
    size_t id = ready.back();
    ready.pop_back();
    if (outgoing[id] != -1) {
      lock_wait_add_subtree_weight(new_weights, outgoing[id], id);
      if (!--incoming_count[outgoing[id]]) {
        ready.push_back(outgoing[id]);
      }
    }
  }
}
```

这个函数从入度为 0 的节点开始，逐层累加子树的权重到父节点。由于等待图在每个节点最多有一条出边（一个事务只能等待一个锁），因此这种累加是可行的。

### 4.4 典型的锁等待场景源码分析

当线程挂起后，唤醒路径在 `lock_reset_wait_and_release_thread_if_suspended()` 中：

```c
// lock0wait.cc:408
void lock_reset_wait_and_release_thread_if_suspended(lock_t *lock) {
  ut_ad(locksys::owns_lock_shard(lock));
  ut_ad(trx_mutex_own(lock->trx));
  ut_ad(lock->trx->lock.wait_lock == lock);

  lock->trx->lock.blocking_trx.store(nullptr);
  ut_ad(lock->trx_que_state() == TRX_QUE_LOCK_WAIT);

  que_thr_t *thr = que_thr_end_lock_wait(lock->trx);
  lock_reset_lock_and_trx_wait(lock);

  if (thr != nullptr) {
    lock_wait_release_thread_if_suspended(thr);
  }
}
```

`lock_wait_release_thread_if_suspended()` 检查 `thr->slot` 是否仍有效，如果有效则调用 `os_event_set()` 唤醒休眠的线程：

```c
// lock0wait.cc:336
static void lock_wait_release_thread_if_suspended(que_thr_t *thr) {
  auto trx = thr_get_trx(thr);

  ut_ad(trx_mutex_own(trx));
  ut_ad(thr->state == QUE_THR_RUNNING);
  ut_ad(trx->lock.wait_lock == nullptr);

  if (thr->slot != nullptr && thr->slot->in_use && thr->slot->thr == thr) {
    if (trx->lock.was_chosen_as_deadlock_victim) {
      trx->error_state = DB_DEADLOCK;
      trx->lock.was_chosen_as_deadlock_victim = false;
      ut_d(trx->lock.in_rollback = true);
    }

    os_event_set(thr->slot->event);
  }
}
```

---

## 5. 死锁检测

死锁检测由后台线程 `lock_wait_timeout_thread()` 驱动，每秒执行一次完整检测周期。整个流程分为四个步骤。

### 5.1 lock_wait_build_wait_for_graph() — 构建等待图 (lock0wait.cc:650)

```c
// lock0wait.cc:650
static void lock_wait_build_wait_for_graph(
    ut::vector<waiting_trx_info_t> &infos, ut::vector<int> &outgoing) {
  ut_ad(infos.size() < std::numeric_limits<uint>::max());
  const auto n = static_cast<uint>(infos.size());
  outgoing.clear();
  outgoing.resize(n, -1);

  sort(infos.begin(), infos.end());

  waiting_trx_info_t needle{};
  for (uint from = 0; from < n; ++from) {
    needle.trx = infos[from].waits_for;
    auto it = std::lower_bound(infos.begin(), infos.end(), needle);

    if (it == infos.end() || it->trx != needle.trx) {
      continue;
    }
    auto to = it - infos.begin();
    outgoing[from] = static_cast<int>(to);
  }
}
```

输入是 `infos` 数组（每个元素包含 `{trx, waits_for}` 对），输出是 `outgoing` 数组，其中 `outgoing[i]` 表示 `infos[i].trx` 等待的事务在数组中的索引，如果没有在快照中找到则设为 -1。

实现细节：先按 `trx` 指针排序 `infos`，然后用二分查找 `lower_bound` 将每个 `waits_for` 映射到数组下标。这是一个 `O(n log n)` 的构建方法。

### 5.2 lock_deadlock_occur() — 死锁发现

死锁的发现和环检测在 `lock_wait_find_and_handle_deadlocks()` 中完成：

```c
// lock0wait.cc:1087
static void lock_wait_find_and_handle_deadlocks(
    const ut::vector<waiting_trx_info_t> &infos,
    const ut::vector<int> &outgoing,
    ut::vector<trx_schedule_weight_t> &new_weights) {
  ut_ad(infos.size() == new_weights.size());
  ut_ad(infos.size() == outgoing.size());
  const auto n = static_cast<uint>(infos.size());
  ut::vector<uint> cycle_ids;
  ut::vector<uint> colors;
  colors.resize(n, 0);
  uint current_color = 0;

  for (uint start = 0; start < n; ++start) {
    if (colors[start] != 0) continue;
    ++current_color;

    for (int id = start; 0 <= id; id = outgoing[id]) {
      ut_ad(id != outgoing[id]);

      if (colors[id] == 0) {
        colors[id] = current_color;
        continue;
      }

      if (colors[id] == current_color) {
        /* found a candidate cycle! */
        lock_wait_extract_cycle_ids(cycle_ids, id, outgoing);
        if (lock_wait_check_candidate_cycle(cycle_ids, infos, new_weights)) {
          MONITOR_INC(MONITOR_DEADLOCK);
        } else {
          MONITOR_INC(MONITOR_DEADLOCK_FALSE_POSITIVES);
        }
      }
      break;
    }
  }
  MONITOR_INC(MONITOR_DEADLOCK_ROUNDS);
  MONITOR_SET(MONITOR_LOCK_THREADS_WAITING, n);
}
```

算法使用了 DFS + 染色法检测环。每个节点赋予一个 `current_color`，DFS 过程中如果遇到同色节点，说明找到了环。对每个候选环，调用 `lock_wait_check_candidate_cycle()` 做二次确认（验证事务是否仍处于等待状态）。

环的提取很简单：沿着 `outgoing` 链走一圈：

```c
// lock0wait.cc:1059
static void lock_wait_extract_cycle_ids(ut::vector<uint> &cycle_ids,
                                        const uint start,
                                        const ut::vector<int> &outgoing) {
  cycle_ids.clear();
  uint id = start;
  do {
    cycle_ids.push_back(id);
    id = outgoing[id];
  } while (id != start);
}
```

### 5.3 lock_wait_rollback_deadlock_victim() — 回滚受害者 (lock0wait.cc:692)

确认死锁后，需要选择一个事务作为受害者回滚。选择原则：

```c
// lock0wait.cc:940
static trx_t *lock_wait_choose_victim(
    const ut::vector<uint> &cycle_ids,
    const ut::vector<waiting_trx_info_t> &infos) {
  ut_ad(locksys::owns_exclusive_global_latch());
  ut_ad(!cycle_ids.empty());
  trx_t *chosen_victim = nullptr;
  auto sorted_trxs = lock_wait_order_for_choosing_victim(cycle_ids, infos);

  for (auto *trx : sorted_trxs) {
    if (chosen_victim == nullptr) {
      chosen_victim = trx;
      continue;
    }

    if (trx_is_high_priority(chosen_victim) || trx_is_high_priority(trx)) {
      auto victim = trx_arbitrate(trx, chosen_victim);
      if (victim != nullptr) {
        if (victim == trx) chosen_victim = trx;
        else { ut_a(victim == chosen_victim); }
        continue;
      }
    }

    if (trx_weight_ge(chosen_victim, trx)) {
      /* The joining transaction is 'smaller', choose it as the victim */
      chosen_victim = trx;
    }
  }

  ut_a(chosen_victim);
  return chosen_victim;
}
```

受害者选择策略：
1. 高优先级（Group Replication）事务优先保留
2. 否则选择 `trx_weight_ge()` 中"更小"的事务（持有锁更少、undo 更少）
3. 最新加入环的事务（`reservation_no` 最大）在排序中靠后，因此在权重相同时会被选中

确认受害者后执行回滚：

```c
// lock0wait.cc:692
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

### 5.4 死锁日志输出

死锁日志由 `Deadlock_notifier` 类管理：

```c
// lock0lock.cc:6144
void Deadlock_notifier::notify(const ut::vector<const trx_t *> &trxs_on_cycle,
                               const trx_t *victim_trx) {
  ut_ad(locksys::owns_exclusive_global_latch());

  start_print();
  const auto n = trxs_on_cycle.size();
  for (size_t i = 0; i < n; ++i) {
    const trx_t *trx = trxs_on_cycle[i];
    const trx_t *blocked_trx = trxs_on_cycle[0 < i ? i - 1 : n - 1];
    const lock_t *blocking_lock =
        lock_has_to_wait_in_queue(blocked_trx->lock.wait_lock, trx);
    ut_a(blocking_lock);

    print_title(i, "TRANSACTION");
    print(trx, 3000);

    print_title(i, "HOLDS THE LOCK(S)");
    print(blocking_lock);

    print_title(i, "WAITING FOR THIS LOCK TO BE GRANTED");
    print(trx->lock.wait_lock);
  }

  const auto victim_pos = /* find position of victim_trx in trxs_on_cycle */;
  ut::ostringstream buff;
  buff << "*** WE ROLL BACK TRANSACTION (" << (victim_pos + 1) << ")\n";
  print(buff.str().c_str());

  lock_deadlock_found = true;  // ← this is checked by lock_print_info_summary()
}
```

输出格式示例（SHOW ENGINE INNODB STATUS 中出现的 LATEST DETECTED DEADLOCK 部分）：

```
------------------------
LATEST DETECTED DEADLOCK
------------------------
*** (1) TRANSACTION:
TRANSACTION 12345, ACTIVE 10 sec
...
*** (1) HOLDS THE LOCK(S):
TABLE LOCK table `db`.`t` trx id 12345 lock mode IX
...
*** (1) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 5 page no 10 n bits 72 index PRIMARY of table `db`.`t`
 trx id 12345 lock_mode X waiting
...
*** (2) TRANSACTION:
TRANSACTION 12346, ACTIVE 8 sec
...
*** (2) HOLDS THE LOCK(S):
...
*** (2) WAITING FOR THIS LOCK TO BE GRANTED:
...
*** WE ROLL BACK TRANSACTION (2)
```

---

## 6. 常见死锁模式源码分析

### 6.1 AB-BA 死锁：两个事务反向加锁

这是最经典的死锁模式。事务 T1 在记录 A 上持锁，等待记录 B；事务 T2 在记录 B 上持锁，等待记录 A。

在内核层面，这表现为 `lock_wait_build_wait_for_graph()` 在扫描 `outgoing` 数组时发现的长度为 2 的环：

```
infos[0] = {T1, waits_for: T2}
infos[1] = {T2, waits_for: T1}
```

当两个事务刚好对两条不同的记录加了互斥的锁，然后交叉等待对方持有的锁时，`lock_wait_snapshot_waiting_threads()` 会在一次快照中捕获这两个等待事务。

`lock_rec_check_conflict()` 的逻辑决定了冲突的存在：

```c
// lock0lock.cc:594
static inline Conflict rec_lock_check_conflict(const trx_t *trx,
                                               ulint type_mode,
                                               const lock_t *lock2,
                                               bool lock_is_on_supremum,
                                               Trx_locks_cache &trx_locks_cache) {
  // ...
  if (trx == lock2->trx ||
      lock_mode_compatible(static_cast<lock_mode>(LOCK_MODE_MASK & type_mode),
                           lock_get_mode(lock2))) {
    return Conflict::NO_CONFLICT;  // same trx or compatible modes
  }
  // ... gap/rec_not_gap rules ...

  return Conflict::HAS_TO_WAIT;   // ← AB-BA 死锁最终落到这里
}
```

两个事务都持有了 `LOCK_X | LOCK_REC_NOT_GAP` 且目标不同记录，在 `lock_mode_compatible(LOCK_X, LOCK_X)` 返回 `false`（兼容性矩阵中 X 行 X 列为 false），于是形成等待。

### 6.2 行锁升级死锁

这种死锁发生在事务先加 S 锁后尝试升级为 X 锁时。例如 T1 持有记录 A 的 S 锁，T2 也持有记录 A 的 S 锁，两者都试图获取 X 锁。

在 `lock_clust_rec_read_check_and_lock()` 或 `lock_sec_rec_read_check_and_lock()` 中，当 `SELECT ... FOR UPDATE` （请求 X 锁）遇到冲突的 S 锁时，会在锁队列中插入等待的 X 锁请求：

```c
// lock0lock.cc:2234
static const lock_t *lock_has_to_wait_in_queue(const lock_t *wait_lock,
                                               const trx_t *skip_trx) {
  // ... scans lock queue to find the blocking lock ...
  const lock_t *blocking_lock = lock_has_to_wait_in_queue(lock, nullptr);
  // ...
}
```

T1 和 T2 互相持有 S 锁，各自的 X 锁请求都排在对方的 S 锁之后，形成死锁。`lock_has_to_wait_in_queue()` 会找到阻塞的 S 锁。

### 6.3 间隙锁导致的死锁

间隙锁死锁在 RR 隔离级别下很常见。例如 T1 在某个间隙上有 S 锁（gap lock），T2 也想在同一间隙上加 S 锁（gap lock）——这其实是兼容的。真正的死锁发生在间隙锁+插入意向锁的组合中。

在 `rec_lock_check_conflict()` 中，间隙锁的行为受到精心管控：

```c
// lock0lock.cc:574
static inline Conflict rec_lock_check_conflict(...) {
  // ...
  if ((lock_is_on_supremum || (type_mode & LOCK_GAP)) &&
      !(type_mode & LOCK_INSERT_INTENTION)) {
    /* Gap type locks without LOCK_INSERT_INTENTION flag
    do not need to wait for anything. This is because
    different users can have conflicting lock types on gaps. */
    return Conflict::NO_CONFLICT;
  }

  if (!(type_mode & LOCK_INSERT_INTENTION) && lock_rec_get_gap(lock2)) {
    /* Record lock (LOCK_ORDINARY or LOCK_REC_NOT_GAP)
    does not need to wait for a gap type lock */
    return Conflict::NO_CONFLICT;
  }

  if ((type_mode & LOCK_GAP) && lock_rec_get_rec_not_gap(lock2)) {
    /* Lock on gap does not need to wait for a LOCK_REC_NOT_GAP type lock */
    return Conflict::NO_CONFLICT;
  }

  if (lock_rec_get_insert_intention(lock2)) {
    /* No lock request needs to wait for an insert intention lock */
    return Conflict::NO_CONFLICT;
  }

  return Conflict::HAS_TO_WAIT;
}
```

关键的例外是：**纯间隙锁不会阻塞另一个纯间隙锁或 LOCK_REC_NOT_GAP，但可能阻塞插入意向锁**。因此经典的间隙锁死锁模式是：

- T1: `SELECT ... LOCK IN SHARE MODE` → 在记录上加 `LOCK_S | LOCK_GAP`
- T2: `INSERT` → 尝试加 `LOCK_X | LOCK_INSERT_INTENTION`，被 T1 的间隙锁阻塞
- T1: `INSERT` → 尝试加 `LOCK_X | LOCK_INSERT_INTENTION`，被 T2 的 Next-Key 锁阻塞

此时 T1 等待 T2，T2 等待 T1，形成死锁。

### 6.4 外键锁导致的死锁

外键约束会触发隐式的行锁请求。当父表或子表被修改时，InnoDB 会检查外键约束，这可能需要锁住另一张表中的记录。

外键检查在 `row_ins_check_foreign_constraint()` 中触发，它会调用 `lock_clust_rec_read_check_and_lock()` 请求 S 锁。当多个事务交叉修改父子表时，这些隐式锁请求可能导致死锁。

死锁检测对 DD 表和 SDI 表有特殊处理——由于这些表理论上不应出现死锁，`Deadlock_notifier::is_allowed_to_be_on_cycle()` 会对这些表上的死锁进行断言检查，除 `mysql/innodb_table_stats`、`mysql/innodb_index_stats`、`mysql/table_stats`、`mysql/index_stats` 外，其他 DD 表上的死锁在 debug 构建中会被视为断言失败：

```c
// lock0lock.cc:6188
bool Deadlock_notifier::is_allowed_to_be_on_cycle(const lock_t *lock) {
  if (!lock->is_record_lock()) return (true);

  const bool is_dd_or_sdi = (lock->index->table->is_dd_table ||
                             dict_table_is_sdi(lock->index->table->id));
  if (!is_dd_or_sdi) return (true);

  const char *name = lock->index->table->name.m_name;
  return (!strcmp(name, "mysql/innodb_table_stats") ||
          !strcmp(name, "mysql/innodb_index_stats") ||
          !strcmp(name, "mysql/table_stats") ||
          !strcmp(name, "mysql/index_stats"));
}
```

---

## 7. 锁监控计数器

### 7.1 srv0mon.h 中与锁相关的计数器

InnoDB 的 MONITOR 系统在 `srv0mon.h` 中定义了所有可统计的计数器。与锁相关的定义如下：

```c
// srv0mon.h:146-151,167
enum {
  MONITOR_DEADLOCK,               // 实际发生的死锁次数
  MONITOR_DEADLOCK_FALSE_POSITIVES, // 假阳性死锁（检测到时事务已不再等待）
  MONITOR_DEADLOCK_ROUNDS,        // 死锁检测的轮数
  MONITOR_LOCK_THREADS_WAITING,   // 当前等待的线程数
  MONITOR_TIMEOUT,                // 锁超时次数
  MONITOR_LOCKREC_WAIT,           // 行锁等待事件的累计次数
  MONITOR_TABLELOCK_WAIT,         // 表锁等待事件的累计次数
  MONITOR_NUM_RECLOCK_REQ,        // 行锁请求总数
  MONITOR_RECLOCK_RELEASE_ATTEMPTS, // 行锁释放尝试次数
  MONITOR_RECLOCK_GRANT_ATTEMPTS,  // 行锁授权尝试次数
  MONITOR_RECLOCK_CREATED,         // 创建的行锁对象数
  MONITOR_RECLOCK_REMOVED,         // 释放的行锁对象数
  MONITOR_NUM_RECLOCK,             // 当前行锁对象数
  MONITOR_TABLELOCK_CREATED,       // 创建的表锁对象数
  MONITOR_TABLELOCK_REMOVED,       // 释放的表锁对象数
  MONITOR_NUM_TABLELOCK,           // 当前表锁对象数
  MONITOR_OVLD_ROW_LOCK_CURRENT_WAIT, // 当前行锁等待数（overload）
  MONITOR_OVLD_LOCK_WAIT_TIME,     // 锁等待总时间
  MONITOR_OVLD_LOCK_MAX_WAIT_TIME, // 锁等待最大时间
  MONITOR_OVLD_ROW_LOCK_WAIT,      // 行锁等待统计
  MONITOR_OVLD_LOCK_AVG_WAIT_TIME, // 锁等待平均时间
  MONITOR_SCHEDULE_REFRESHES,      // 调度权重刷新次数
};
```

### 7.2 MONITOR_LOCK_DEADLOCKS, MONITOR_LOCK_TIMEOUTS 等

这些计数器的更新点分布在锁系统的各个关键路径中：

- **死锁计数**：在 `lock_wait_find_and_handle_deadlocks()` 中，确认真实死锁后递增 `MONITOR_DEADLOCK`，假阳性递增 `MONITOR_DEADLOCK_FALSE_POSITIVES`：
  ```c
  // lock0wait.cc:1110
  if (lock_wait_check_candidate_cycle(cycle_ids, infos, new_weights)) {
    MONITOR_INC(MONITOR_DEADLOCK);
  } else {
    MONITOR_INC(MONITOR_DEADLOCK_FALSE_POSITIVES);
  }
  ```

- **超时计数**：在 `lock_wait_suspend_thread()` 中，等待结束时检查错误码：
  ```c
  // lock0wait.cc:334
  if (trx->error_state == DB_LOCK_WAIT_TIMEOUT) {
    MONITOR_INC(MONITOR_TIMEOUT);
  }
  ```

- **调度刷新**：在 `lock_wait_compute_and_publish_weights_except_cycles()` 的末尾：
  ```c
  // lock0wait.cc:1206
  MONITOR_INC(MONITOR_SCHEDULE_REFRESHES);
  ```

- **等待线程数**：在 `lock_wait_find_and_handle_deadlocks()` 结束时设置：
  ```c
  // lock0wait.cc:1121
  MONITOR_SET(MONITOR_LOCK_THREADS_WAITING, n);
  ```

- **行锁等待统计**：在 `lock_wait_suspend_thread()` 中通过 `srv_stats.n_lock_wait_current_count` 等变量追踪，同时在 `lock_wait_table_reserve_slot()` 中：
  ```c
  // lock0wait.cc:169
  if (thr->lock_state == QUE_THR_LOCK_ROW) {
    srv_stats.n_lock_wait_count.inc();
    srv_stats.n_lock_wait_current_count.inc();
  }
  ```

这些计数器可通过 `SHOW GLOBAL STATUS LIKE 'Innodb_row_lock%'`、`SHOW GLOBAL STATUS LIKE 'Innodb_deadlocks'` 等查询获取聚合值。

---

## 8. 关键函数索引

以下列出本文引用的所有内核函数及其位置：

| 函数 | 文件 | 行号 | 说明 |
|---|---|---|---|
| `lock_sys_create` | lock0lock.cc | — | 创建全局锁系统 |
| `lock_sys_resize` | lock0lock.h | — | 调整锁哈希表大小 |
| `lock_sys_close` | lock0lock.h | — | 关闭锁系统 |
| `lock_wait_suspend_thread` | lock0wait.cc | 206 | 挂起等待锁的线程 |
| `lock_wait_table_reserve_slot` | lock0wait.cc | 131 | 在 waiting_threads 中分配槽 |
| `lock_wait_table_release_slot` | lock0wait.cc | 58 | 释放槽 |
| `lock_wait_release_thread_if_suspended` | lock0wait.cc | 336 | 通过 os_event_set 唤醒线程 |
| `lock_reset_wait_and_release_thread_if_suspended` | lock0wait.cc | 408 | 安全的唤醒包装函数 |
| `lock_wait_check_slots_for_timeouts` | lock0wait.cc | 541 | 遍历所有槽检查超时 |
| `lock_wait_check_and_cancel` | lock0wait.cc | 475 | 单个槽的超时检查 |
| `lock_wait_try_cancel` | lock0wait.cc | 447 | 取消锁等待请求 |
| `lock_wait_snapshot_waiting_threads` | lock0wait.cc | 581 | 快照当前所有等待事务 |
| `lock_wait_compute_initial_weights` | lock0wait.cc | 607 | CATS 初始权重计算 |
| `lock_wait_accumulate_weights` | lock0wait.cc | 834 | CATS 权重累加 |
| `lock_wait_add_subtree_weight` | lock0wait.cc | 800 | 将子节点权重加至父节点 |
| `lock_wait_build_wait_for_graph` | lock0wait.cc | 650 | 构建等待图 |
| `lock_wait_find_and_handle_deadlocks` | lock0wait.cc | 1087 | 发现并处理死锁 |
| `lock_wait_extract_cycle_ids` | lock0wait.cc | 1059 | 提取环中的事务索引 |
| `lock_wait_check_candidate_cycle` | lock0wait.cc | 978 | 验证候选环是否为真死锁 |
| `lock_wait_trxs_are_still_in_slots` | lock0wait.cc | 1009 | 验证事务仍在槽中 |
| `lock_wait_trxs_are_still_waiting` | lock0wait.cc | 1033 | 验证事务仍处于等待状态 |
| `lock_wait_choose_victim` | lock0wait.cc | 940 | 选择死锁受害者 |
| `lock_wait_order_for_choosing_victim` | lock0wait.cc | 782 | 排序环内事务用于受害者选择 |
| `lock_wait_rollback_deadlock_victim` | lock0wait.cc | 692 | 回滚选中的受害者 |
| `lock_wait_handle_deadlock` | lock0wait.cc | 1140 | 处理已确认的死锁 |
| `lock_wait_timeout_thread` | lock0wait.cc | 1420 | 后台死锁/超时检测线程 |
| `lock_wait_update_schedule_and_check_for_deadlocks` | lock0wait.cc | 1345 | CATS 调度权重更新+死锁检测 |
| `lock_wait_compute_and_publish_weights_except_cycles` | lock0wait.cc | 1200 | 计算并发布非环事务的权重 |
| `lock_wait_update_weights_on_cycle` | lock0wait.cc | 1190 | 更新环上事务的权重 |
| `lock_wait_publish_new_weights` | lock0wait.cc | 902 | 发布新权重到 trx_t |
| `lock_wait_find_latest_pos_on_cycle` | lock0wait.cc | 727 | 查找环中最晚加入的事务 |
| `lock_notify_about_deadlock` | lock0lock.cc | 6272 | 死锁通知入口 |
| `Deadlock_notifier::notify` | lock0lock.cc | 6144 | 生成死锁日志 |
| `Deadlock_notifier::start_print` | lock0lock.cc | 6056 | 重置死锁日志文件 |
| `Deadlock_notifier::print` (trx) | lock0lock.cc | 6086 | 打印事务信息到死锁文件 |
| `Deadlock_notifier::print` (lock) | lock0lock.cc | 6115 | 打印锁信息到死锁文件 |
| `lock_print_info_summary` | lock0lock.cc | 4449 | 输出锁信息摘要 |
| `lock_print_info_all_transactions` | lock0lock.cc | 4780 | 输出所有事务的锁信息 |
| `lock_trx_print_wait_and_mvcc_state` | lock0lock.cc | 4640 | 输出单个事务的等待状态 |
| `lock_trx_print_locks` | lock0lock.cc | 4710 | 输出事务持有的锁 |
| `lock_rec_print` | lock0lock.cc | 4353 | 输出记录锁信息 |
| `lock_table_print` | lock0lock.cc | 4318 | 输出表锁信息 |
| `lock_rec_fetch_page` | lock0lock.cc | 4670 | 从磁盘读取页面用于锁输出 |
| `lock_rec_check_conflict` | lock0lock.cc | 554 | 检查记录锁冲突 |
| `rec_lock_has_to_wait` | lock0lock.cc | 654 | 记录锁是否需等待 |
| `locksys::has_to_wait` | lock0lock.cc | 673 | 通用锁等待检查 |
| `lock_has_to_wait` | lock0lock.cc | 681 | 公开的锁等待检查函数 |
| `lock_mode_compatible` | lock0priv.h | 274 | 锁模式兼容性检查 |
| `lock_mode_stronger_or_eq` | lock0priv.h | 280 | 锁模式强弱比较 |
| `lock_has_to_wait_in_queue` | lock0lock.cc | 2234 | 在锁队列中找阻塞者 |
| `lock_rec_has_to_wait_in_queue` | lock0lock.cc | 1905 | 行锁队列等待检查 |
| `lock_table_has_to_wait_in_queue` | lock0lock.cc | 3658 | 表锁队列等待检查 |
| `RecLock::add_to_waitq` | lock0priv.h | — | 将锁请求加入等待队列 |
| `RecLock::create` | lock0priv.h | — | 创建记录锁对象 |
| `RecLock::lock_alloc` | lock0priv.h | — | 分配记录锁内核空间 |
| `lock_alloc_from_heap` | lock0lock.h | — | 从堆分配锁内存 |
| `lock_trx_release_locks` | lock0lock.h | — | 释放事务所有锁 |
| `lock_cancel_waiting_and_release` | lock0priv.h | — | 取消等待并释放后续锁 |
| `lock_cancel_if_waiting_and_release` | lock0lock.h | — | 条件性取消等待 |
| `locksys::find_blockers` | lock0iter.cc | 143 | 查找等待锁的阻塞者 |
| `locksys::find_on_table` | lock0iter.cc | 167 | 在表锁队列上查找 |
| `All_locks_iterator::iterate_over_next_batch` | lock0iter.cc | 67 | 遍历所有锁（P_S 使用） |
| `lock_request_check_for_cycles` | lock0lock.h | — | 请求死锁检测 |
| `lock_set_timeout_event` | lock0lock.h | — | 设置超时检测事件 |
| `lock_wait_request_check_for_cycles` | lock0wait.cc | 224 | 触发死锁检测 |
| `rec_lock_check_conflict` | lock0lock.cc | 554 | 记录锁冲突判断核心 |
| `lock_wait_mutex_enter` | lock0lock.h | — | 获取等待互斥锁 |
| `lock_wait_mutex_exit` | lock0lock.h | — | 释放等待互斥锁 |
| `lock_deadlock_found` | lock0lock.cc | 202 | 死锁发生标志 |
| `locksys::run_if_waiting` | lock0priv.h | — | 安全地操作还在等待的事务 |
| `locksys::latch_peeked_shard_and_do` | lock0priv.h | — | 在合适分区上执行操作 |
| `Trx_locks_cache::has_granted_blocker` | lock0lock.h | — | 检查事务是否持有阻塞锁 |
| `lock_make_trx_hit_list` | lock0lock.h | — | 生成 HP 事务的回滚列表 |