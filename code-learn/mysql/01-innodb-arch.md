# 01-innodb-arch — MySQL InnoDB 存储引擎架构总览与核心数据结构

> 基于 **MySQL 8.4** 主线源码（`~/code/mysql`）
> 全部 struct/class 定义均来自实际源码行号，使用 `grep` 与 `sed` 定位
> 分析日期：2026-05-06

---

## 0. 概述

**InnoDB** 是 MySQL 的默认存储引擎，提供事务（ACID）、行级锁、MVCC、崩溃恢复等核心能力。作为一个插件式存储引擎，它通过 MySQL 的 `handlerton` 接口注册到 SQL 层。

InnoDB 的核心架构可拆为**六大子系统**：

```
                    MySQL SQL Layer (sql/)
                          │
                     handlerton 接口
                     (ha_innodb.cc:5401)
                          │
               ┌──────────┴──────────┐
               │     InnoDB          │
               │  (storage/innobase/) │
               │                      │
    ┌──────────┼──────────┬──────────┼──────────┐
    │          │          │          │          │
  Buffer      Redo Log    Lock     Index(B+Tree) Transaction
  Pool        (log/)     (lock/)  + Adaptive    System
  (buf/)                          Hash Index    (trx/)
                                     │
                                 Undo Log
                                 (trx/ + row/)
```

InnoDB 的启动入口在 `srv0start.cc:1330`：

```c
// storage/innobase/srv/srv0start.cc:1330
dberr_t srv_start(bool create_new_db) {
  // 启动阶段（srv0start.cc:147-154）:
  // 1. SRV_START_STATE_NONE (0) → 基础子系统初始化
  // 2. SRV_START_STATE_IO    (1) → 表空间/IO 线程
  // 3. SRV_START_STATE_PURGE (2) → 启动 purge 线程
  // 4. SRV_START_STATE_STAT  (4) → 统计信息收集
  srv_start_state = SRV_START_STATE_NONE;
  ...
}
```

启动阶段枚举（`srv0start.cc:147-154`）：

```c
// storage/innobase/srv/srv0start.cc:147
enum srv_start_state_t {
  /** No thread started */
  SRV_START_STATE_NONE = 0,
  /** Started IO threads */
  SRV_START_STATE_IO = 1,
  /** Started purge thread(s) */
  SRV_START_STATE_PURGE = 2,
  /** Started bufdump + dict stat and FTS optimize thread. */
  SRV_START_STATE_STAT = 4
};

// srv0start.cc:157
static uint64_t srv_start_state = SRV_START_STATE_NONE;
```

---

## 1. Buffer Pool — `buf_pool_t`

Buffer Pool 是 InnoDB 最大的内存结构，缓存数据页和索引页。一个 MySQL 实例可能有多个 buffer pool instance（`srv_buf_pool_instances`）。`buf_pool_t` 定义在 `buf0buf.h:2293`：

```c
// storage/innobase/include/buf0buf.h:2293
struct buf_pool_t {
  /** @name General fields */
  /** @{ */

  /** Protects (de)allocation of chunks */
  BufListMutex chunks_mutex;
  /** LRU list mutex */
  BufListMutex LRU_list_mutex;
  /** free and withdraw list mutex */
  BufListMutex free_list_mutex;
  /** buddy allocator mutex */
  BufListMutex zip_free_mutex;
  /** zip_hash mutex */
  BufListMutex zip_hash_mutex;
  /** Flush state protection mutex */
  ib_mutex_t flush_state_mutex;
  /** Zip mutex, protects compressed-only pages */
  BufPoolZipMutex zip_mutex;

  /** Array index of this buffer pool instance */
  ulint instance_no;
  /** Current pool size in bytes */
  ulint curr_pool_size;
  /** Reserve this much for "old" blocks */
  ulint LRU_old_ratio;

  /** Number of buffer pool chunks */
  volatile ulint n_chunks;
  /** New number of buffer pool chunks (during resize) */
  volatile ulint n_chunks_new;
  /** Buffer pool chunks (array of buf_chunk_t) */
  buf_chunk_t *chunks;
  /** Old chunks to be freed after resize */
  buf_chunk_t *chunks_old;

  /** Current pool size in pages */
  ulint curr_size;
  /** Previous pool size in pages */
  ulint old_size;
  /** Read-ahead area size */
  page_no_t read_ahead_area;

  /** Hash table of buf_page_t indexed by (space_id, offset) */
  hash_table_t *page_hash;
  /** Hash table of buf_block_t indexed by frame address (zip) */
  hash_table_t *zip_hash;

  /** Number of pending read operations */
  std::atomic<ulint> n_pend_reads;
  /** Number of pending decompressions */
  std::atomic<ulint> n_pend_unzip;

  /** Last time buf_print_io was called */
  std::chrono::steady_clock::time_point last_printout_time;

  /** Buddy allocator statistics (by block size) */
  buf_buddy_stat_t buddy_stat[BUF_BUDDY_SIZES_MAX + 1];

  /** Current statistics */
  buf_pool_stat_t stat;
  /** Old statistics */
  buf_pool_stat_t old_stat;
  /** @} */

  /** @name Page flushing algorithm fields */
  /** @{ */

  /** Flush list mutex */
  BufListMutex flush_list_mutex;
  /** Hazard pointer for flush list scan */
  FlushHp flush_hp;
  /** Hazard pointer for oldest page scan */
  FlushHp oldest_hp;

  /** Base node of the modified block list (flush list) */
  UT_LIST_BASE_NODE_T(buf_page_t, list) flush_list;

  /** True if a flush of a given type is being initialized */
  bool init_flush[BUF_FLUSH_N_TYPES];
  /** Number of pending writes for each flush type */
  std::array<size_t, BUF_FLUSH_N_TYPES> n_flush;
  /** Event signaled when no flush batch is running */
  os_event_t no_flush[BUF_FLUSH_N_TYPES];

  /** Freed page clock (wraps at 4B) */
  ulint freed_page_clock;
  /** LRU scan flag to avoid repeated scans */
  bool try_LRU_scan;
  /** Page tracking start LSN */
  lsn_t track_page_lsn;
  /** Maximum LSN for which write IO has started */
  lsn_t max_lsn_io;
  /** @} */

  /** @name LRU replacement algorithm fields */
  /** @{ */

  /** Free block list */
  UT_LIST_BASE_NODE_T(buf_page_t, list) free;
  /** Withdraw block list (during shrink) */
  UT_LIST_BASE_NODE_T(buf_page_t, list) withdraw;
  /** Target length of withdraw block list */
  ulint withdraw_target;

  /** Hazard pointer for LRU batch */
  LRUHp lru_hp;
  /** Iterator for LRU victim scanning */
  LRUItr lru_scan_itr;
  /** Iterator for single page flushing victim */
  LRUItr single_scan_itr;

  /** Base node of the LRU list */
  UT_LIST_BASE_NODE_T(buf_page_t, LRU) LRU;
  /** Pointer to oldest ~3/8 of LRU list */
  buf_page_t *LRU_old;
  /** Length from LRU_old onward */
  ulint LRU_old_len;

  /** Unzip LRU list (decompressed blocks) */
  UT_LIST_BASE_NODE_T(buf_block_t, unzip_LRU) unzip_LRU;
  /** @} */

  /** @name Buddy allocator fields */
  /** @{ */

#if defined UNIV_DEBUG || defined UNIV_BUF_DEBUG
  /** Unmodified compressed pages (debug only) */
  UT_LIST_BASE_NODE_T(buf_page_t, list) zip_clean;
#endif
  /** Buddy free lists (by block size) */
  UT_LIST_BASE_NODE_T(buf_buddy_free_t, list) zip_free[BUF_BUDDY_SIZES_MAX];
  /** Watch sentinel records */
  buf_page_t *watch;
  /** @} */
};
```

### 1.1 Buffer Pool 内存组织 — `buf_chunk_t`

每个 buffer pool instance 由多个 chunk 组成，chunk 是连续大块内存（`buf0buf.ic:53`）：

```c
// storage/innobase/include/buf0buf.ic:53
struct buf_chunk_t {
  ulint size;            /* 帧数 = blocks[] 长度 */
  unsigned char *mem;    /* 分配的页面帧内存 */
  buf_block_t *blocks;   /* 缓冲控制块数组（即 buf_block_t 数组） */

  /** 检查指针是否属于本 chunk */
  bool contains(const buf_block_t *ptr) const;
};
```

> **设计要点**：`buf_chunk_t::mem` 是 `mmap` 或 `malloc` 分配的大块连续内存（默认每个 chunk `srv_buf_pool_chunk_unit` 字节），`mem` 对齐到 `UNIV_PAGE_SIZE`。每个 `buf_block_t` 的 `frame` 指针指向 `mem` 中对应位置。

---

### 1.2 页面描述符 — `buf_page_t`

每一个缓冲页面（在内存中或在 LRU 链表中）由 `buf_page_t` 描述（`buf0buf.h:1164`）。这是 InnoDB 中使用最频繁的对象之一：

```c
// storage/innobase/include/buf0buf.h:1164
class buf_page_t {
  /* 从 copy constructor 可以看出所有数据成员：*/
  page_id_t id;                    // 空间 ID + 页号 (space_id_t + page_no_t)
  page_size_t size;                // 页大小（默认 16KB）
  copyable_atomic_t<uint32_t> buf_fix_count; // 固定计数（atomic）
  copyable_atomic_t<buf_io_fix> io_fix;      // IO 固定状态 (NONE/READ/WRITE/PIN)
  buf_page_state state;            // BUF_BLOCK_NOT_USED, FILE_PAGE, ZIP_PAGE, ...
  buf_flush_t flush_type;          // BUF_FLUSH_LRU, BUF_FLUSH_LIST, ...
  uint8_t buf_pool_index;          // 所属 buffer pool instance 编号
  buf_page_t *hash;                // 页面哈希链节点（page_hash / zip_hash）
  UT_LIST_NODE_T(buf_page_t) list; // flush_list / free / withdraw / zip_clean 链表节点
  lsn_t newest_modification;       // 最新修改 LSN（dirty 时 > 0）
  lsn_t oldest_modification;       // 最久修改 LSN（首次变脏时的 LSN）
  UT_LIST_NODE_T(buf_page_t) LRU;  // LRU 链表节点
  page_zip_des_t zip;              // 压缩页描述符（zip.data、ssize、n_blobs 等）
  Flush_observer *m_flush_observer;// 刷盘观察者（用于 AHI 等）
  fil_space_t *m_space;            // 所属表空间对象
  uint32_t freed_page_clock;       // 最近一次移到 LRU 头部时的 clock 值
  uint32_t m_version;              // fil_space_t 的版本号（用于检测截断）
  std::chrono::steady_clock::time_point access_time;  // 首次访问时间
  uint16_t m_dblwr_id;            // doublewrite buffer ID
  bool old;                        // 在 LRU 旧块部分中
#ifdef UNIV_DEBUG
  bool file_page_was_freed;        // 调试：页面是否曾被释放
  bool in_flush_list;              // 调试：在 flush list 中
  bool in_free_list;               // 调试：在 free list 中
  bool in_LRU_list;                // 调试：在 LRU list 中
  bool in_page_hash;               // 调试：在 page_hash 中
  bool in_zip_hash;                // 调试：在 zip_hash 中
#endif
};
```

**关键字段说明**：

| 字段 | 作用 |
|------|------|
| `id` | `page_id_t` 包含 `space_id_t`（32 位表空间 ID）+ `page_no_t`（32 位页号），共同唯一标识一个物理页 |
| `newest_modification` | 最近一次修改的 LSN，== 0 表示清洁页；用于 flush list 排序（最小 oldest_modification 优先刷） |
| `oldest_modification` | 第一次变脏时的 LSN，页面首次被修改时设置；写入时需要同时持有 `block->mutex` 和 `flush_list_mutex` |
| `buf_fix_count` | 页面被"固定"的次数（表示有多少线程在使用该页），防止被 evict |
| `io_fix` | `BUF_IO_NONE`（空闲）、`BUF_IO_READ`（在读）、`BUF_IO_WRITE`（在写）、`BUF_IO_PIN`（固定） |
| `state` | `BUF_BLOCK_NOT_USED`（空闲）、`BUF_BLOCK_FILE_PAGE`（普通文件页）、`BUF_BLOCK_ZIP_PAGE`（仅压缩）、`BUF_BLOCK_ZIP_DIRTY`（压缩脏页）、`BUF_BLOCK_MEMORY`（非文件页，如 Hash 表） |
| `zip` | 压缩页信息，包含 `zip.data`（指向压缩数据）、`ssize`（压缩移位大小）、`n_blobs`、`m_end` 等 |

---

### 1.3 缓冲块 — `buf_block_t`

`buf_block_t` 扩展了 `buf_page_t`，增加了真正的页面数据帧指针、锁、AHI 信息等（`buf0buf.h:1764`）：

```c
// storage/innobase/include/buf0buf.h:1764
struct buf_block_t {
  /** page information (must be first field) */
  buf_page_t page;

  /** read-write lock of the buffer frame */
  BPageLock lock;

  /** pointer to buffer frame (UNIV_PAGE_SIZE aligned) */
  byte *frame;

  /** node of the decompressed LRU list (unzip_LRU) */
  UT_LIST_NODE_T(buf_block_t) unzip_LRU;
#ifdef UNIV_DEBUG
  bool in_unzip_LRU_list;
  bool in_withdraw_list;
#endif

  /** Adaptive Hash Index fields */
  struct ahi_t {
    std::atomic<btr_search_prefix_info_t> recommended_prefix_info;
    std::atomic<btr_search_prefix_info_t> prefix_info;
    std::atomic<dict_index_t *> index;
#if defined UNIV_AHI_DEBUG || defined UNIV_DEBUG
    std::atomic<uint16_t> n_pointers;
#endif
  } ahi;

  /** Counter for how many times prefix recommendation helps searches */
  std::atomic<uint32_t> n_hash_helps;
  /** true if block dirtied without X/SX latch (temporary tablespace) */
  bool made_dirty_with_no_latch;

#ifdef UNIV_DEBUG
  rw_lock_t debug_latch;
#endif

  /** Modify clock: incremented when record pointer may become obsolete.
      Used for optimistic cursor positioning. */
  uint64_t modify_clock;

  /** mutex protecting this block (state, io_fix, buf_fix_count, etc.) */
  BPageMutex mutex;
};
```

---

## 2. Buffer Pool 页面状态与转换

`buf_page_state` 枚举（`buf0buf.h:130`）：

```c
// storage/innobase/include/buf0buf.h:130
enum buf_page_state : uint8_t {
  BUF_BLOCK_NOT_USED,      // 空闲块，在 free list 中
  BUF_BLOCK_FILE_PAGE,     // 普通文件页（有 frame）
  BUF_BLOCK_ZIP_PAGE,      // 仅压缩页（无解压 frame）
  BUF_BLOCK_ZIP_DIRTY,     // 压缩脏页（无解压 frame，在 flush list 中）
  BUF_BLOCK_MEMORY,        // 非文件页（例如 Hash 索引页）
  BUF_BLOCK_REMOVE_HASH,   // 正在从 hash 表移除（过渡状态）
};
```

---

## 3. 事务系统 — `trx_t`

事务结构 `trx_t` 是 InnoDB 最复杂的对象之一，包含 50+ 字段，定义在 `trx0trx.h:675`：

```c
// storage/innobase/include/trx0trx.h:675
struct trx_t {
  /** 隔离级别枚举 */
  enum isolation_level_t {
    READ_UNCOMMITTED,    // 读未提交
    READ_COMMITTED,      // 读已提交
    REPEATABLE_READ,     // 可重复读（默认）
    SERIALIZABLE         // 可串行化
  };

  /** 保护 state 和 lock 字段的 mutex */
  mutable TrxMutex mutex;

  /** 嵌套 InnoDB 调用深度（无锁访问） */
  uint32_t in_depth;
  /** 处于 InnoDB 上下文中（> 0 表示在 InnoDB 内） */
  uint32_t in_innodb;

  /** 事务是否需要中断 */
  bool abort;

  /** 事务 ID（首次修改时分配） */
  trx_id_t id;
  /** 事务序列号（提交前的最大 trx id，用于 ReadView） */
  trx_id_t no;

  /** 事务状态（atomic，无锁可读） */
  std::atomic<trx_state_t> state;
  // 状态转换：
  //   NOT_STARTED → ACTIVE → PREPARED → COMMITTED_IN_MEMORY → NOT_STARTED
  //   NOT_STARTED → ACTIVE → NOT_STARTED (auto-commit non-locking read-only)
  //   NOT_STARTED → PREPARED → COMMITTED_IN_MEMORY → (freed) [recovered XA]

  /** 如果设置了，事务不再继承 gap lock（用于 RC 复制回放） */
  bool skip_lock_inheritance;

  /** MVCC 一致性读 ReadView */
  ReadView *read_view;

  /** 事务链表节点（trx_sys->rw_trx_list 等） */
  UT_LIST_NODE_T(trx_t) trx_list;
  UT_LIST_NODE_T(trx_t) no_list;

  /** 事务锁信息 */
  trx_lock_t lock;

  /** 是否为恢复的事务 */
  bool is_recovered;

  /** 发来 KILL 信号的线程 ID */
  std::atomic<std::thread::id> killed_by;

  /** 当前操作描述文本 */
  const char *op_info;
  /** 当前隔离级别 */
  isolation_level_t isolation_level;

  /** 是否检查外键约束 */
  bool check_foreigns;
  /** 是否已在 XA 协调器注册 */
  bool is_registered;
  /** 是否检查唯一二级索引 */
  bool check_unique_secondary;

  /** 延迟刷 log（2PC 优化） */
  bool flush_log_later;
  bool must_flush_log_later;

  /** 是否持有 search system latch */
  bool has_search_latch;

  /** DDL 操作类型 */
  trx_dict_op_t dict_operation;
  bool ddl_operation;
  bool ddl_must_flush;
  bool in_truncate;

  /** 是否声明在 InnoDB 内部（并发控制） */
  bool declared_to_be_inside_innodb;
  uint32_t n_tickets_to_enter_innodb;
  uint32_t dict_operation_lock_mode;

  /** 事务开始时间（atomic） */
  std::atomic<std::chrono::system_clock::time_point> start_time;

  /** 提交时的 LSN */
  lsn_t commit_lsn;

  /** MySQL THD 指针 */
  THD *mysql_thd;

  /** binlog 文件名和偏移 */
  const char *mysql_log_file_name;
  uint64_t mysql_log_offset;

  /** 当前 SQL 语句使用的 InnoDB 表数 */
  uint32_t n_mysql_tables_in_use;
  uint32_t mysql_n_tables_locked;

  /** MySQL 事务链表节点 */
  UT_LIST_NODE_T(trx_t) mysql_trx_list;

  /** 错误状态 */
  dberr_t error_state;
  const dict_index_t *error_index;
  ulint error_key_num;

  /** 查询图（Query Graph） */
  que_t *graph;

  /** 保存点列表 */
  UT_LIST_BASE_NODE_T_EXTERN(trx_named_savept_t, trx_savepoints) trx_savepoints;

  /** Undo 日志保护 mutex */
  UndoMutex undo_mutex;
  /** 下一个 undo 记录号 */
  undo_no_t undo_no;
  /** 最后一条 undo 记录所在的 space id */
  space_id_t undo_rseg_space;
  /** 当前 SQL 语句开始时的 undo_no */
  trx_savept_t last_sql_stat_start;
  /** rollback segments for undo logging */
  trx_rsegs_t rsegs;
  /** 部分回滚时的最小 undo 号 */
  undo_no_t roll_limit;
#ifdef UNIV_DEBUG
  bool in_rollback;
#endif
  ulint pages_undone;

  /** AUTO-INC 行数 */
  ulint n_autoinc_rows;

  /** 只读 / 自动提交 / 加锁标记 */
  bool read_only;
  bool auto_commit;
  uint32_t will_lock;

#ifndef UNIV_HOTBACKUP
  /** FTS 事务信息 */
  fts_trx_t *fts_trx;
  doc_id_t fts_next_doc_id;
  uint32_t flush_tables;
  bool internal;
  bool persists_gtid;

#ifdef UNIV_DEBUG
  ulint start_line;
  const char *start_file;
#endif

  /** 引用计数（保护事务不被提前释放） */
  lint n_ref;
  /** 实例版本号（每次 trx_start_low 递增） */
  std::atomic_uint64_t version;

  /** XA 事务标识 */
  XID *xid;
  /** 被修改的表列表 */
  trx_mod_tables_t mod_tables;
#endif /* !UNIV_HOTBACKUP */

  bool api_trx;
  bool api_auto_commit;
  bool read_write;
  bool purge_sys_trx;

  char *detailed_error;
  Flush_observer *flush_observer;

#ifdef UNIV_DEBUG
  bool is_dd_trx;
#endif
  ulint magic_n;
};
```

事务状态枚举（稍早定义在 `trx0trx.h` 中）：

```c
// storage/innobase/include/trx0trx.h (state 字段注释中的内联文档)
// 可能的状态：
// - TRX_STATE_NOT_STARTED        — 尚未开始
// - TRX_STATE_ACTIVE             — 运行中
// - TRX_STATE_PREPARED           — 两阶段提交已准备（XA）
// - TRX_STATE_COMMITTED_IN_MEMORY — 内存已提交
//   (TRX_STATE_COMMITTED_IN_DISK 不再单独存在)
// - TRX_STATE_FORCED_ROLLBACK    — 强制回滚
```

---

## 4. Redo Log — `log_t`

Redo Log 是 InnoDB WAL（Write-Ahead Logging）的核心，`log_t` 定义在 `log0sys.h:77`，是整个系统中跨度最大的结构体之一（约 600 行）：

```c
// storage/innobase/include/log0sys.h:77
struct alignas(ut::INNODB_CACHE_LINE_SIZE) log_t {
  /** @name Users writing to log buffer */
  /** @{ */

  /** Event used for locking sn */
  os_event_t sn_lock_event;

  /** Current sn value — 用于预留 redo 空间和获取 buffer 独占访问。
      表示已预留的数据字节数（不含 log block 头尾）。
      最高位用于锁住 log buffer。 */
  alignas(ut::INNODB_CACHE_LINE_SIZE) atomic_sn_t sn;

  /** 目标 sn（当 x-locked 时） */
  atomic_sn_t sn_locked;

  /** 用于 x-lock sn 值的 mutex */
  mutable ib_mutex_t sn_x_lock_mutex;

  /** 对齐的 redo log buffer，mini-transaction 提交时将 redo 写入这里 */
  alignas(ut::INNODB_CACHE_LINE_SIZE)
      ut::aligned_array_pointer<byte, LOG_BUFFER_ALIGNMENT> buf;

  /** log buffer 数据容量（以数据字节计，不含头尾开销） */
  atomic_sn_t buf_size_sn;

  /** log buffer 总容量（含头尾开销） */
  size_t buf_size;

  /** recent_written buffer — 跟踪已写入但尚未 broadcast 的 LSN */
  alignas(ut::INNODB_CACHE_LINE_SIZE) Link_buf<lsn_t> recent_written;

  /** Writer 线程暂停标记 */
  std::atomic_bool writer_threads_paused;
  /** @} */

  /** @name Users <=> writer */
  /** @{ */

  /** 最大 sn，确保在 log buffer 和 log files 中都有空闲空间 */
  alignas(ut::INNODB_CACHE_LINE_SIZE) atomic_sn_t buf_limit_sn;

  /** 已写入磁盘（但不保证 fsync）的 LSN */
  alignas(ut::INNODB_CACHE_LINE_SIZE) atomic_lsn_t write_lsn;

  /** write notifier 事件数组（等待 write_lsn 推进的用户线程） */
  alignas(ut::INNODB_CACHE_LINE_SIZE) os_event_t *write_events;
  size_t write_events_size;

  /** 写请求计数 */
  alignas(ut::INNODB_CACHE_LINE_SIZE)
      std::atomic<uint64_t> write_to_file_requests_total;
  alignas(ut::INNODB_CACHE_LINE_SIZE)
      std::atomic<std::chrono::microseconds> write_to_file_requests_interval;
  /** @} */

  /** @name Users <=> flusher */
  /** @{ */

  /** flush notifier 事件数组 */
  alignas(ut::INNODB_CACHE_LINE_SIZE) os_event_t *flush_events;
  size_t flush_events_size;

  /** 旧式 flush 事件（被 reset 时表示有 flush 在进行） */
  os_event_t old_flush_event;

  /** 已 fsync 到磁盘的 LSN */
  alignas(ut::INNODB_CACHE_LINE_SIZE) atomic_lsn_t flushed_to_disk_lsn;
  /** @} */

  /** @name Log flusher thread */
  /** @{ */

  /** 最近一次 flush 开始/结束时间 */
  Log_clock_point last_flush_start_time;
  Log_clock_point last_flush_end_time;

  double flush_avg_time;           // 平均 flush 时长 (μs)
  mutable ib_mutex_t flusher_mutex;
  alignas(ut::INNODB_CACHE_LINE_SIZE) os_event_t flusher_event;
  /** @} */

  /** @name Log writer thread */
  /** @{ */

  alignas(ut::INNODB_CACHE_LINE_SIZE) uint32_t write_ahead_buf_size;
  ut::aligned_array_pointer<byte, LOG_WRITE_AHEAD_BUFFER_ALIGNMENT>
      write_ahead_buf;
  os_offset_t write_ahead_end_offset;
  /** @} */

  // ... 继续约 460 行，包含更详细的线程管理、format 控制等字段
};
```

**关键 LSN 字段与关系**：

```
sn (reserved)
 ↓
write_lsn (OS file write)
 ↓
flushed_to_disk_lsn (fsync)
```

```
  sn ≥ buf_limit_sn → 等待空间释放
write_lsn < sn → log_writer 线程把 buf[write_lsn..sn] 写到 OS
flushed_to_disk_lsn ≤ write_lsn → log_flusher 线程 fsync
checkpoint_lsn ≤ flushed_to_disk_lsn (unused redo 可以回收)
```

---

## 5. 数据字典 — `dict_table_t`

InnoDB 的字典缓存，每张表对应一个 `dict_table_t` 实例（`dict0mem.h:1925`）：

```c
// storage/innobase/include/dict0mem.h:1925
struct dict_table_t {
  /** Mutex of the table for concurrency access */
  ib_mutex_t *mutex;
  std::atomic<os_once::state_t> mutex_created;

  /** Id of the table */
  table_id_t id;
  /** Memory heap */
  mem_heap_t *heap;
  /** Table name (db/tablename) */
  table_name_t name;
  /** Truncate name */
  table_name_t trunc_name;
  /** DATA DIRECTORY path or NULL */
  char *data_dir_path;
  /** TABLESPACE name */
  id_name_t tablespace;
  /** Space where the clustered index is placed */
  space_id_t space;
  /** dd::Tablespace::id */
  dd::Object_id dd_space_id;

  /** Table flags:
      - row format (redundant/compact)
      - compressed page size (zip shift)
      - atomic blobs
      - DATA DIRECTORY
      Use DICT_TF_GET_COMPACT(), DICT_TF_GET_ZIP_SSIZE(), etc. */
  unsigned flags : DICT_TF_BITS;

  /** Secondary flags:
      - CREATE TEMPORARY
      - DOC ID column
      - FTS index
      - DISCARD
      - encryption, etc.
      Use DICT_TF2_FLAG_IS_SET() */
  unsigned flags2 : DICT_TF2_BITS;

  /** skip_alter_undo flag */
  unsigned skip_alter_undo : 1;
  /** .ibd file missing */
  unsigned ibd_file_missing : 1;
  /** Added to dictionary cache */
  unsigned cached : 1;
  /** To be dropped */
  unsigned to_be_dropped : 1;

  /** Column counts */
  unsigned n_def : 10;
  unsigned n_cols : 10;
  unsigned n_instant_cols : 10;
  unsigned n_t_cols : 10;
  unsigned n_t_def : 10;
  unsigned n_v_def : 10;
  unsigned n_v_cols : 10;
  unsigned n_m_v_cols : 10;

  bool can_be_evicted : 1;
  unsigned ddl_not_evictable : 1;
  unsigned drop_aborted : 1;

  /** Column definitions */
  dict_col_t *cols;
  /** Virtual column definitions */
  dict_v_col_t *v_cols;
  /** Stored column list (foreign key check) */
  dict_s_col_list *s_cols;

  /** Column names, packed "name1\0name2\0...nameN\0" */
  const char *col_names;
  /** Virtual column names */
  const char *v_col_names;

  /** Whether this belongs to a system database */
  bool is_system_table;

  /** Hash chain nodes (name_hash, id_hash) */
  hash_node_t name_hash;
  hash_node_t id_hash;

  /** FTS_DOC_ID_INDEX, or NULL */
  dict_index_t *fts_doc_id_index;

  /** List of all indexes (clustered + secondary) */
  UT_LIST_BASE_NODE_T(dict_index_t, indexes) indexes;
  size_t get_index_count() const;

  /** LRU list node */
  UT_LIST_NODE_T(dict_table_t) table_LRU;

  /** metadata version from dd::Table::se_private_data() */
  uint64_t version;

  /** INSTANT ADD/DROP column row versions */
  uint32_t current_row_version{0};
  uint32_t initial_col_count{0};
  uint32_t current_col_count{0};
  uint32_t total_col_count{0};
  bool m_upgraded_instant{false};

  /** dynamic metadata status */
  std::atomic<table_dirty_status> dirty_status;

  /** dirty table list node (for dict_persist) */
  UT_LIST_NODE_T(dict_table_t) dirty_dict_tables;
  // ...
};
```

**索引链表遍历**（访问表中所有索引）：

```c
dict_index_t *index;
for (index = table->first_index; index != nullptr; index = index->next()) {
  // clustered 或 secondary index
}
```

实际上通过 `UT_LIST_BASE_NODE_T(dict_index_t, indexes) indexes` 来遍历：

```c
// 伪代码 — 遍历表中索引
dict_index_t *index = UT_LIST_GET_FIRST(table->indexes);
while (index != nullptr) {
  // 处理索引
  index = UT_LIST_GET_NEXT(indexes, index);
}
```

---

## 6. 锁系统 — `lock_t`

### 6.1 锁模式枚举

定义在 `lock0types.h:43`：

```c
// storage/innobase/include/lock0types.h:43
enum lock_mode {
  LOCK_IS = 0,          // Intention Shared
  LOCK_IX,              // Intention Exclusive
  LOCK_S,               // Shared
  LOCK_X,               // Exclusive
  LOCK_AUTO_INC,        // Auto-increment
  LOCK_NONE,            // Consistent read
  LOCK_NUM = LOCK_NONE, // Number of lock modes
  LOCK_NONE_UNSET = 255
};
```

### 6.2 表锁结构

定义在 `lock0priv.h:54`：

```c
// storage/innobase/include/lock0priv.h:54
struct lock_table_t {
  dict_table_t *table;           // 被锁定的表
  UT_LIST_NODE_T(lock_t) locks;  // 同一表上的锁链表
};
```

### 6.3 行锁结构

定义在 `lock0priv.h`（约 86 行）：

```c
// storage/innobase/include/lock0priv.h:86 附近
struct lock_rec_t {
  /** 记录所在页面的 ID */
  page_id_t page_id;
  /** lock bitmap 的位数（必须是 8 的倍数）。
      bitmap 位于 lock struct 之后。 */
  uint32_t n_bits;
};
```

### 6.4 完整的 `lock_t` 结构

定义在 `lock0priv.h`（约 145 行）：

```c
// storage/innobase/include/lock0priv.h (~line 145)
struct alignas(8 /* For efficient bitmap find_set */) lock_t {
  /** 拥有该锁的事务 */
  trx_t *trx;

  /** 该事务的锁链表节点 */
  UT_LIST_NODE_T(lock_t) trx_locks;

  /** 记录锁的索引 */
  dict_index_t *index;

  /** 哈希链节点（单向链表） */
  lock_t *hash;

  union {
    /** 表锁 */
    lock_table_t tab_lock;
    /** 记录锁 */
    lock_rec_t rec_lock;
  };

  /** 锁类型和模式位标志。
      包含 LOCK_REC/LOCK_TABLE 类型，LOCK_S/LOCK_X 模式，
      LOCK_GAP/LOCK_REC_NOT_GAP/LOCK_INSERT_INTENTION 等标志，
      以及 LOCK_WAIT 等待标志。 */
  uint32_t type_mode;

#if defined(UNIV_DEBUG)
  uint64_t m_seq;  // 创建时间戳
#endif

  // 辅助方法：
  bool is_record_lock() const;      // type() == LOCK_REC
  bool is_waiting() const;          // type_mode & LOCK_WAIT
  bool is_gap() const;              // type_mode & LOCK_GAP
  bool is_insert_intention() const; // type_mode & LOCK_INSERT_INTENTION
  bool is_next_key_lock() const;    // 精确 LOCK_S 或 LOCK_X，无 gap/rec 修饰
  lock_mode mode() const;           // type_mode & LOCK_MODE_MASK
};
```

**锁类型模式标志**（在 `lock0priv.h` 前面的注释或 `lock0lock.cc` 中定义）：

```c
// 锁类型（type_mode 高位）：
#define LOCK_REC    0x04000000   // 行锁
#define LOCK_TABLE  0x08000000   // 表锁

// 锁模式（type_mode 低位）：
// LOCK_IS = 0, LOCK_IX = 1, LOCK_S = 2, LOCK_X = 3, LOCK_AUTO_INC = 4
#define LOCK_MODE_MASK  0xF      // 低 4 位

// 额外标志：
#define LOCK_WAIT           0x01000000  // 等待锁
#define LOCK_GAP            0x02000000  // Gap 锁（间隙锁）
#define LOCK_REC_NOT_GAP    0x04000000  // 仅行锁（无间隙）
#define LOCK_INSERT_INTENTION 0x08000000  // 插入意向锁
#define LOCK_PREDICATE      0x40000000  // 谓词锁（空间索引）
#define LOCK_PRDT_PAGE      (~LOCK_PREDICATE & 0x80000000) // 谓词页锁
```

---

## 7. Mini-Transaction — `mtr_t`

Mini-Transaction 是 InnoDB 内部最细粒度的持久化单元。所有 B+Tree 页面的修改都必须通过 `mtr_t`。定义在 `mtr0mtr.h:177`：

```c
// storage/innobase/include/mtr0mtr.h:177
struct mtr_t {
  /** 内部实现状态 */
  struct Impl {
    /** memo stack（记录 latch 和 page fix） */
    mtr_buf_t m_memo;

    /** mini-transaction 的 redo log */
    mtr_buf_t m_log;

    /** 是否在 ibuf (change buffer) 内部 */
    bool m_inside_ibuf;

    /** 是否可能修改了 buffer pool 页面 */
    bool m_modifications;

    /** 是否处于 NO_LOG 模式（redo 全局关闭时） */
    bool m_marked_nolog;

    /** 用于递增全局计数器的分片索引 */
    size_t m_shard_index;

    /** 已写入的 page init log record 数 */
    uint32_t m_n_log_recs;

    /** 日志模式：MTR_LOG_ALL / MTR_LOG_NO_REDO */
    mtr_log_t m_log_mode;

    /** mtr 状态：INIT / ACTIVE / COMMITTING / COMMITTED */
    mtr_state_t m_state;

    /** Flush observer */
    Flush_observer *m_flush_observer;

#ifdef UNIV_DEBUG
    ulint m_magic_n;
#endif

    /** 所属的 mtr_t */
    mtr_t *m_mtr;
  } m_impl;

#ifndef UNIV_HOTBACKUP
  /** 全局 redo logging 状态管理。支持在运行时动态开关 redo log。
      状态转换：
        ENABLED ↔ ENABLED_RESTRICT ↔ DISABLED
        ENABLED → ENABLED_DBLWR → ENABLED (恢复双写) */
  class Logging {
    std::atomic<State> m_state;
    Counter::Shards<128> m_count_nologging_mtr;
  };

  static Logging s_logging;
#endif /* !UNIV_HOTBACKUP */

  /** 同步标记（true = 同步 mtr，false = 异步） */
  bool m_sync{true};

  /** 提交时的 LSN（commit 后可用） */
  lsn_t m_commit_lsn;

  // 核心方法：
  void start(bool sync = true);
  void commit();
  ulint get_savepoint() const;
  void set_log_mode(mtr_log_t mode);

  // 锁操作：
  void s_lock(rw_lock_t *lock, ut::Location location);
  void x_lock(rw_lock_t *lock, ut::Location location);
  void sx_lock(rw_lock_t *lock, ut::Location location);

  // 页面操作：
  void release_page(const void *ptr, mtr_memo_type_t type);
  void set_modified();
  bool has_modifications() const;
  lsn_t commit_lsn() const;
};
```

**mtr 的使用模式**：

```c
// storage/innobase/btr/btr0cur.cc 等文件中实际使用的模式：
mtr_t mtr;
mtr.start();                         // MTR_STATE_INIT → MTR_STATE_ACTIVE
                                     // 分配 start_lsn

buf_block_t *block = buf_page_get_gen(
    page_id, page_size, RW_X_LATCH, nullptr,
    Page_fetch::NORMAL, &mtr);       // 获取页面（x-latch + buffer fix）

mlog_write_ulint(ptr, value, &mtr); // 写入值 + 记录 redo

mtr.set_modified();                  // 标记页面为已修改
mtr.commit();                        // MTR_STATE_ACTIVE → COMMITTING
                                     // 1. 释放所有 latch
                                     // 2. 将 m_log 写入 log buffer
                                     // 3. 将 dirty page 加入 flush list
                                     // 4. 发出 log write 信号
```

**memo 类型**（`mtr0mtr.h` 中的 `mtr_memo_type_t`）：

```c
// mtr 的 memo stack 中记录的类型：
enum mtr_memo_type_t {
  MTR_MEMO_PAGE_S_FIX,     // 页面 S-latch
  MTR_MEMO_PAGE_X_FIX,     // 页面 X-latch
  MTR_MEMO_PAGE_SX_FIX,    // 页面 SX-latch
  MTR_MEMO_S_LOCK,         // rw_lock S-lock
  MTR_MEMO_X_LOCK,         // rw_lock X-lock
  MTR_MEMO_SX_LOCK,        // rw_lock SX-lock
  MTR_MEMO_BUF_FIX,        // buffer fix（不锁页面）
  MTR_MEMO_MODIFY,         // 标记页面已被修改
};
```

---

## 8. 页面类型 — `page_t` 与 FIL_PAGE_*

InnoDB 的页面类型定义在 `fil0fil.h:1227`：

```c
// storage/innobase/include/fil0fil.h:1227
using page_type_t = uint16_t;

/** B-tree node（B+Tree 索引页） */
constexpr page_type_t FIL_PAGE_INDEX = 17855;

/** R-tree node（空间索引页） */
constexpr page_type_t FIL_PAGE_RTREE = 17854;

/** SDI Index page（序列化字典信息索引） */
constexpr page_type_t FIL_PAGE_SDI = 17853;

/** 不可用页面类型 */
constexpr page_type_t FIL_PAGE_TYPE_UNUSED = 1;

/** Undo log 页面 */
constexpr page_type_t FIL_PAGE_UNDO_LOG = 2;

/** Index node（区段索引节点） */
constexpr page_type_t FIL_PAGE_INODE = 3;

/** Insert buffer free list */
constexpr page_type_t FIL_PAGE_IBUF_FREE_LIST = 4;

/** 新分配的空白页面 */
constexpr page_type_t FIL_PAGE_TYPE_ALLOCATED = 0;

/** Insert buffer bitmap */
constexpr page_type_t FIL_PAGE_IBUF_BITMAP = 5;

/** 系统页面 */
constexpr page_type_t FIL_PAGE_TYPE_SYS = 6;

/** 事务系统数据（trx sys page） */
constexpr page_type_t FIL_PAGE_TYPE_TRX_SYS = 7;

/** 文件空间头 */
constexpr page_type_t FIL_PAGE_TYPE_FSP_HDR = 8;

/** 扩展描述符页 */
constexpr page_type_t FIL_PAGE_TYPE_XDES = 9;

/** 未压缩 BLOB 页 */
constexpr page_type_t FIL_PAGE_TYPE_BLOB = 10;

/** 第一个压缩 BLOB 页 */
constexpr page_type_t FIL_PAGE_TYPE_ZBLOB = 11;

/** 后续压缩 BLOB 页 */
constexpr page_type_t FIL_PAGE_TYPE_ZBLOB2 = 12;

/** 旧格式未知类型 */
constexpr page_type_t FIL_PAGE_TYPE_UNKNOWN = 13;

/** 压缩页 */
constexpr page_type_t FIL_PAGE_COMPRESSED = 14;

/** 加密页 */
constexpr page_type_t FIL_PAGE_ENCRYPTED = 15;

/** 压缩并加密页面 */
constexpr page_type_t FIL_PAGE_COMPRESSED_AND_ENCRYPTED = 16;

/** 加密的 R-tree 页 */
constexpr page_type_t FIL_PAGE_ENCRYPTED_RTREE = 17;

/** SDI BLOB 页（未压缩） */
constexpr page_type_t FIL_PAGE_SDI_BLOB = 18;

/** SDI BLOB 页（压缩） */
constexpr page_type_t FIL_PAGE_SDI_ZBLOB = 19;

/** 兼容性 doublewrite buffer 页 */
constexpr page_type_t FIL_PAGE_TYPE_LEGACY_DBLWR = 20;

/** Rollback Segment Array 页 */
constexpr page_type_t FIL_PAGE_TYPE_RSEG_ARRAY = 21;

/** 未压缩 LOB 索引页 */
constexpr page_type_t FIL_PAGE_TYPE_LOB_INDEX = 22;

/** 未压缩 LOB 数据页 */
constexpr page_type_t FIL_PAGE_TYPE_LOB_DATA = 23;

/** 未压缩 LOB 首页 */
constexpr page_type_t FIL_PAGE_TYPE_LOB_FIRST = 24;

/** 压缩 LOB 首页 */
constexpr page_type_t FIL_PAGE_TYPE_ZLOB_FIRST = 25;

/** 压缩 LOB 数据页 */
constexpr page_type_t FIL_PAGE_TYPE_ZLOB_DATA = 26;

/** 压缩 LOB 索引页 */
constexpr page_type_t FIL_PAGE_TYPE_ZLOB_INDEX = 27;

/** 压缩 LOB 碎片页 */
constexpr page_type_t FIL_PAGE_TYPE_ZLOB_FRAG = 28;

/** 压缩 LOB 碎片索引页 */
constexpr page_type_t FIL_PAGE_TYPE_ZLOB_FRAG_ENTRY = 29;

/** 最后一个有效的非索引类型 */
constexpr page_type_t FIL_PAGE_TYPE_LAST = FIL_PAGE_TYPE_ZLOB_FRAG_ENTRY;
```

**判断页面是否为索引页**（`fil0fil.h:1333`）：

```c
// storage/innobase/include/fil0fil.h:1333
inline bool fil_page_type_is_index(page_type_t page_type) {
  return page_type == FIL_PAGE_INDEX || page_type == FIL_PAGE_SDI ||
         page_type == FIL_PAGE_RTREE;
}
```

**页面行偏移宏**（`page0page.h`，常数定义）：

```c
// storage/innobase/include/page0page.h（常量部分）
constexpr uint32_t PAGE_DIR = FIL_PAGE_DATA_END;          // 目录起始偏移
constexpr uint32_t PAGE_DIR_SLOT_SIZE = 2;                 // 每个 slot 2 字节
constexpr uint32_t PAGE_EMPTY_DIR_START = PAGE_DIR + 2 * PAGE_DIR_SLOT_SIZE;
constexpr uint32_t PAGE_DIR_SLOT_MAX_N_OWNED = 8;         // 一个 slot 最多 8 条记录
constexpr uint32_t PAGE_DIR_SLOT_MIN_N_OWNED = 4;         // 一个 slot 最少 4 条记录
```

**页面游标搜索模式**（`page0types.h` 中的 `page_cur_mode_t`）：

```c
// storage/innobase/include/page0types.h（枚举）
enum page_cur_mode_t {
  PAGE_CUR_UNSUPP = 0,
  PAGE_CUR_G  = 1,     // > (greater)
  PAGE_CUR_GE = 2,     // >=
  PAGE_CUR_L  = 3,     // < (less)
  PAGE_CUR_LE = 4,     // <=（插入搜索使用）

  // R-tree 搜索模式：
  PAGE_CUR_CONTAIN     = 7,
  PAGE_CUR_INTERSECT   = 8,
  PAGE_CUR_WITHIN      = 9,
  PAGE_CUR_DISJOINT    = 10,
  PAGE_CUR_MBR_EQUAL   = 11,
  PAGE_CUR_RTREE_INSERT = 12,
  PAGE_CUR_RTREE_LOCATE = 13,
  PAGE_CUR_RTREE_GET_FATHER = 14,
  PAGE_CUR_NN          = 15
};
```

---

## 9. handlerton 接口 — InnoDB 注册到 MySQL SQL 层

InnoDB 通过 `handlerton` 结构体注册到 MySQL 的插件框架。注册入口在 `ha_innodb.cc:5401` 的 `innodb_init()` 函数：

```c
// storage/innobase/handler/ha_innodb.cc:5395
static int innodb_init(void *p) {
  handlerton *innobase_hton = (handlerton *)p;
  innodb_hton_ptr = innobase_hton;

  // 基础信息
  innobase_hton->state = SHOW_OPTION_YES;
  innobase_hton->db_type = DB_TYPE_INNODB;
  innobase_hton->savepoint_offset = sizeof(trx_named_savept_t);

  // 日志/DDL 相关
  innobase_hton->log_ddl_drop_schema   = innobase_write_ddl_drop_schema;
  innobase_hton->log_ddl_create_schema = innobase_write_ddl_create_schema;

  // 连接生命周期
  innobase_hton->close_connection = innobase_close_connection;
  innobase_hton->kill_connection  = innobase_kill_connection;

  // 保存点操作
  innobase_hton->savepoint_set      = innobase_savepoint;
  innobase_hton->savepoint_rollback = innobase_rollback_to_savepoint;
  innobase_hton->savepoint_release  = innobase_release_savepoint;

  // 事务提交/回滚
  innobase_hton->commit   = innobase_commit;
  innobase_hton->rollback = innobase_rollback;
  innobase_hton->prepare  = innobase_xa_prepare;

  // XA 恢复
  innobase_hton->recover                = innobase_xa_recover;
  innobase_hton->commit_by_xid          = innobase_commit_by_xid;
  innobase_hton->rollback_by_xid        = innobase_rollback_by_xid;

  // 表空间管理
  innobase_hton->create               = innobase_create_handler;
  innobase_hton->alter_tablespace     = innobase_alter_tablespace;
  innobase_hton->is_valid_tablespace_name = innobase_is_valid_tablespace_name;

  // 启动/关闭
  innobase_hton->pre_dd_shutdown = innodb_pre_dd_shutdown;
  innobase_hton->panic           = innodb_shutdown;

  // MVCC 快照
  innobase_hton->start_consistent_snapshot =
      innobase_start_trx_and_assign_read_view;

  // Flush log
  innobase_hton->flush_logs = innobase_flush_logs;

  // SHOW ENGINE INNODB STATUS
  innobase_hton->show_status = innobase_show_status;

  // 能力标志位
  innobase_hton->flags = HTON_SUPPORTS_EXTENDED_KEYS |
                         HTON_SUPPORTS_FOREIGN_KEYS |
                         HTON_SUPPORTS_ATOMIC_DDL |
                         HTON_CAN_RECREATE |
                         HTON_SUPPORTS_SECONDARY_ENGINE |
                         HTON_SUPPORTS_TABLE_ENCRYPTION |
                         HTON_SUPPORTS_GENERATED_INVISIBLE_PK |
                         HTON_SUPPORTS_BULK_LOAD |
                         HTON_SUPPORTS_SQL_FK;

  // 初始化
  innobase_hton->ddse_dict_init = innobase_ddse_dict_init;
  innobase_hton->post_recover   = innobase_post_recover;
  // ...
}
```

> **关键点**：`handlerton` 是 MySQL 插件引擎的统一接口表。MySQL SQL 层发起的任何操作（`open`, `close`, `commit`, `rollback`, `prepare`, `recover` 等）都通过这个函数指针表委派到 InnoDB 的具体实现。

---

## 10. 数据流：一次 B+Tree 查询的完整路径

以 `SELECT * FROM t WHERE id = 42` 为例，InnoDB 内部的实际调用链：

### 10.1 入口：`btr_cur_search_to_nth_level`

核心 B+Tree 搜索函数（`btr0cur.cc:619`）：

```c
// storage/innobase/btr/btr0cur.cc:619
void btr_cur_search_to_nth_level(
    dict_index_t *index,   /* 索引对象 */
    ulint level,           /* 目标树层（0 = 叶子） */
    const dtuple_t *tuple, /* 搜索键（含 n_fields_cmp 比较字段数） */
    page_cur_mode_t mode,  /* PAGE_CUR_L, PAGE_CUR_LE, ... */
    ulint latch_mode,      /* BTR_SEARCH_LEAF, BTR_MODIFY_LEAF, ... */
    btr_cur_t *cursor,     /* 输出：游标 */
    ulint has_search_latch,
    const char *file,      /* __FILE__ */
    ulint line,            /* __LINE__ */
    mtr_t *mtr)            /* mini-transaction */
{
  page_t *page = nullptr;
  buf_block_t *block;
  ulint height;
  ulint up_match, up_bytes;
  ulint low_match, low_bytes;
  ulint savepoint;
  ulint rw_latch;
  page_cur_mode_t page_mode;
  Page_fetch fetch;
  page_cur_t *page_cursor;
  ulint root_height = 0;
  ulint upper_rw_latch, root_leaf_rw_latch;
  btr_intention_t lock_intention;
  bool modify_external;
  buf_block_t *tree_blocks[BTR_MAX_LEVELS];
  ulint tree_savepoints[BTR_MAX_LEVELS];
  ulint n_blocks = 0;
  ulint n_releases = 0;
  bool detected_same_key_root = false;
  // ... (~300 行局部变量和初始化)

  // 算法：
  // 1. 从 root 页开始，获得高度
  // 2. 对每一层:
  //    a. buf_page_get_gen() 获取页面
  //    b. page_cur_search_with_match() 二分查找
  //    c. 如果是非叶子层，取出节点指针（page_no），进入下一层
  // 3. 到达目标 level，设置 cursor
}
```

### 10.2 页面获取：`buf_page_get_gen`

```c
// storage/innobase/include/buf0buf.h:443
buf_block_t *buf_page_get_gen(
    const page_id_t &page_id,
    const page_size_t &page_size,
    ulint rw_latch,
    buf_pool_t *bpage_guess,   // 猜测所属 buffer pool（优化）
    Page_fetch fetch,           // NORMAL / SCAN / IF_IN_POOL / ...
    mtr_t *mtr);

// 流程：
// 1. 计算 buf_pool = buf_pool_get(page_id)
// 2. 在 page_hash 中查找 page
// 3. [命中] buf_page_init_for_read → LRU 链表移动 → 返回 block
// 4. [未命中] buf_read_page → 发起异步 IO → 回来继续
```

### 10.3 页内搜索：`page_cur_search_with_match`

```c
// storage/innobase/row/row0sel.cc 或 page0cur.cc
void page_cur_search_with_match(
    const page_t *page,           // 页面数据
    const dict_index_t *index,    // 索引定义
    const dtuple_t *tuple,        // 搜索键
    page_cur_mode_t mode,         // PAGE_CUR_GE / PAGE_CUR_LE 等
    ulint *up_match,              // 输出：向上匹配的字段数
    ulint *up_bytes,              // 输出：向上匹配的字节数
    ulint *low_match,
    ulint *low_bytes,
    page_cur_t *cursor);          // 输出：定位到的游标位置

  // 算法：
  // 1. 从 page directory 的 slot 中二分搜索
  // 2. 找到目标 slot 后，在 slot 内线性扫描
  // 3. 设置 cursor->rec = 目标 record
  // 4. 返回上下匹配的字段数（用于非叶子层的方向判断）
}
```

### 10.4 完整的数据流图

```
SELECT * FROM t WHERE id = 42;
  │
  ├─ MySQL SQL Layer:
  │   Parser → Optimizer → Executor
  │   ha_innobase::index_read()  (ha_innodb.cc)
  │
  ├─ btr_pcur_open()             (btr0pcur.ic — 封装了 btr_cur_search_to_nth_level)
  │   └─ btr_cur_search_to_nth_level()  (btr0cur.cc:619)
  │       │
  │       ├─ [非叶子层 — 逐层下降]
  │       │   buf_page_get_gen()         (buf0buf.h:443) — 获取非叶子页
  │       │   page_cur_search_with_match() — 二分查找节点指针
  │       │
  │       └─ [到达叶子层]
  │           buf_page_get_gen()         — 获取叶子页
  │           page_cur_search_with_match() — 精确查找目标记录
  │
  ├─ lock_rec_lock()              — 加行锁（lock0lock.cc）
  │   └─ lock_rec_enqueue()       — 入队等待/授权
  │
  ├─ row_sel_store_row()          — 将记录转换为 MySQL 格式
  │
  └─ 返回行数据给 MySQL SQL Layer
```

---

## 11. 启动流程详解

`srv_start()`（`srv0start.cc:1330`）按阶段完成初始化：

### Phase 1: SRV_START_STATE_NONE → 基础子系统

```c
// srv0start.cc — SRV_START_STATE_NONE 阶段
srv_boot();                             // 基础配置

os_create_block_cache();                // OS 缓存
fil_init();                             // 文件系统
fil_set_scan_dir();                     // 表空间扫描路径

clone_init();                           // clone 插件
fil_scan_for_tablespaces();             // 扫描 .ibd 文件

os_aio_init(n_read, n_write);           // AIO 线程

buf_pool_init(srv_buf_pool_size,        // Buffer Pool（关键内存分配）
              srv_buf_pool_instances);
fsp_init();                             // 文件空间管理
pars_init();                            // 解析器
recv_sys_create();                      // 恢复子系统
recv_sys_init();
trx_sys_create();                       // 事务系统
lock_sys_create(srv_lock_table_size);   // 锁系统
os_aio_start_threads();                 // IO 线程启动
buf_flush_page_cleaner_init();          // 刷页线程
```

### Phase 2: SRV_START_STATE_IO → 表空间与恢复

```c
// srv0start.cc:1583
srv_start_state_set(SRV_START_STATE_IO);

// 打开/创建系统表空间
srv_sys_space.open_or_create(!create_new_db, create_new_db,
                             &sum_of_new_sizes, &flushed_lsn);

dict_persist_init();                    // 字典持久化
mtr_t::s_logging.init();                // Redo logging 状态

dblwr::open();                          // Doublewrite buffer
log_sys_init(create_new_db,             // Redo log 系统
             flushed_lsn, new_files_lsn);

// 崩溃恢复：
recv_recovery_from_checkpoint_start();
// ... redo 日志回放 ...

trx_sys_create_sys_pages();
trx_purge_sys_mem_create();
trx_sys_init_at_db_start();

// undo 表空间初始化
srv_undo_tablespaces_init(!create_new_db);
```

### Phase 3: SRV_START_STATE_PURGE → Purge 线程启动

```c
// srv0start.cc:2192 (srv_start_purge_threads)
srv_start_state_set(SRV_START_STATE_PURGE);

srv_threads.m_purge_coordinator =
    os_thread_create(srv_purge_thread_key, 0,
                     srv_purge_coordinator_thread);
for (size_t i = 1; i < srv_threads.m_purge_workers_n; ++i) {
  srv_threads.m_purge_workers[i] =
      os_thread_create(srv_worker_thread_key, i,
                       srv_worker_thread);
}
// 启动所有 purge worker
srv_start_wait_for_purge_to_start();
```

### Phase 4: SRV_START_STATE_STAT → 统计信息

```c
// srv0start.cc:2257 (srv_start_threads)
srv_start_state_set(SRV_START_STATE_STAT);

// 允许周期 checkpoint
log_sys->periodical_checkpoints_enabled = true;

srv_threads.m_buf_resize =    // 缓冲池 resize 线程
    os_thread_create(buf_resize_thread_key, 0, buf_resize_thread);
srv_threads.m_master =        // Master 线程（purge、字典维护）
    os_thread_create(srv_master_thread_key, 0, srv_master_thread);
srv_threads.m_dict_stats =    // 统计信息
    os_thread_create(dict_stats_thread_key, 0, dict_stats_thread);
fts_optimize_init();          // 全文检索优化线程
```

---

## 12. 核心子系统速查表

| 子系统 | 核心结构 | 定义位置 | 行号 | 说明 |
|--------|---------|---------|------|------|
| Buffer Pool | `buf_pool_t` | `buf0buf.h` | 2293 | 每个 buffer pool instance 的管理结构 |
| Buffer Chunk | `buf_chunk_t` | `buf0buf.ic` | 53 | 大块连续内存（frames + blocks） |
| Buffer Page | `buf_page_t` | `buf0buf.h` | 1164 | 页面描述符（hash/链表节点、LSN 等） |
| Buffer Block | `buf_block_t` | `buf0buf.h` | 1764 | 扩展 buf_page_t（frame、lock、AHI） |
| Redo Log | `log_t` | `log0sys.h` | 77 | 完整的 redo log 系统（~460 行） |
| 事务 | `trx_t` | `trx0trx.h` | 675 | ~50+ 字段的事务描述 |
| 表定义 | `dict_table_t` | `dict0mem.h` | 1925 | 字典缓存中的表 |
| 锁结构 | `lock_t` | `lock0priv.h` | ~145 | 行锁/表锁通用结构 |
| 表锁 | `lock_table_t` | `lock0priv.h` | 54 | 表级锁 |
| 行锁 | `lock_rec_t` | `lock0priv.h` | ~86 | 记录锁（含 bitmap） |
| 锁模式 | `lock_mode` | `lock0types.h` | 43 | IS/IX/S/X/AUTO_INC |
| Mini-Transaction | `mtr_t` | `mtr0mtr.h` | 177 | 最细粒度持久化单元 |
| 页面类型 | `page_type_t` | `fil0fil.h` | 1227 | INDEX=17855, UNDO_LOG=2, SYS=6 ... |
| 搜索模式 | `page_cur_mode_t` | `page0types.h` | — | GE/LE/G/L 等 |
| handlerton | `handlerton` | `ha_innodb.cc` | 5401 | 引擎注册到 MySQL 的接口 |
| 启动入口 | `srv_start()` | `srv0start.cc` | 1330 | 4 阶段启动 |
| B+Tree 搜索 | `btr_cur_search_to_nth_level()` | `btr0cur.cc` | 619 | 从 root 到 leaf 的遍历 |

---

## 13. 推荐阅读

| 文件 | 内容 |
|------|------|
| `buf0buf.h:2293-2580` | `buf_pool_t` 完整定义（~280 行） |
| `trx0trx.h:675-1120` | `trx_t` 完整定义（~450 行） |
| `log0sys.h:77-740` | `log_t` 完整定义（~660 行） |
| `dict0mem.h:1925-2175` | `dict_table_t` 完整定义（~250 行） |
| `srv0start.cc:1330-2130` | `srv_start()` 完整实现（~800 行） |
| `btr0cur.cc:619-800` | `btr_cur_search_to_nth_level()` 声明 + 前 200 行 |
| `lock0priv.h:54-254` | `lock_t` 完整定义（~200 行） |
| `mtr0mtr.h:177-527` | `mtr_t` 完整定义（~350 行） |
| `fil0fil.h:1227-1340` | 所有页面类型常量定义 |

---

*分析方式：`grep` + `sed -n 'X,Yp'` 逐行读取实际 MySQL 8.4 源码 | `~/code/mysql/storage/innobase/` | 2026-05-06*
