# 03-innodb-redo-log — InnoDB Redo Log：WAL 与 Crash Recovery

> 基于 MySQL 8.4 主线源码（commit: 8.4.x）
> 分析日期：2026-05-06
> 源码路径：`storage/innobase/`

---

## 0. 概述

Redo Log 是 InnoDB **WAL（Write-Ahead Logging）** 机制的核心。所有页面修改必须先写 Redo Log 再写数据文件，保证事务的持久性（Durability）和崩溃恢复（Crash Recovery）的正确性。

核心数据流：

```
用户线程修改页面
  │
  ├── mtr_start()
  ├── mlog_write_*() → 在 mtr 内部 buffer 中记录 redo
  └── mtr_commit()
        │
        ├── mtr_t::Command::execute()
        │   ├── log_buffer_reserve()      [为 redo record 预留 LSN]
        │   ├── log_buffer_write()        [memcpy 到 log_t::buf]
        │   ├── log_buffer_write_completed()  [解锁 sn + 通知 writer]
        │   └── add_dirty_blocks_to_flush_list()  [脏页入 flush_list]
        │
        └── 事务提交时：
            log_write_up_to(commit_lsn, flush_to_disk=true)
              ├── log_writer:    pwrite() 写 OS buffer
              ├── log_flusher:   fsync()  刷磁盘
              └── 返回给用户：COMMIT OK
```

**WAL 原则**：数据页可以晚于日志写磁盘，但日志必须在事务提交前落盘。这就是为什么 `log_write_up_to` 带 `flush_to_disk=true` 时，必须确保 `fsync` 完成后才返回。

---

## 1. 核心类型 — lsn_t 与 sn_t

Redo Log 有两种序列号：

- **`sn_t`**：数据字节序列号。只计数 redo record 的**数据字节**，跳过 log block 的 header 和 footer。
- **`lsn_t`**：Log Sequence Number。按**物理文件字节**计数（包括 header 和 footer）。用于文件偏移计算。

```c
// storage/innobase/include/log0types.h:63 — lsn_t 定义
typedef uint64_t lsn_t;

// storage/innobase/include/log0types.h:82
using atomic_lsn_t = std::atomic<lsn_t>;

// storage/innobase/include/log0types.h:86 — sn_t 定义
/** Type used for sn values, which enumerate bytes of data stored in the log.
Note that these values skip bytes of headers and footers of log blocks. */
typedef uint64_t sn_t;

// storage/innobase/include/log0types.h:89
using atomic_sn_t = std::atomic<sn_t>;
```

**关键关系**：sn 用于预留 log buffer 空间（原子递增 `log.sn`），lsn 用于确定文件写入位置。

log 中的每个事务都有一个 commit_lsn，这是它写入的最后一个 redo record 的 end_lsn。

### 1.1 LSN ↔ SN 转换

```c
// storage/innobase/include/log0log.h:85
/** Converts sn to lsn. Sn enumerates data bytes only; lsn enumerates all
bytes in the log (including headers and footers of log blocks). */
constexpr inline lsn_t log_translate_sn_to_lsn(sn_t sn) {
  return sn / LOG_BLOCK_DATA_SIZE * OS_FILE_LOG_BLOCK_SIZE +
         sn % LOG_BLOCK_DATA_SIZE + LOG_BLOCK_HDR_SIZE;
}

// storage/innobase/include/log0log.h:94
/** Converts lsn to sn. */
inline sn_t log_translate_lsn_to_sn(lsn_t lsn) {
  /* Calculate sn of the beginning of log block, which contains
  the provided lsn value. */
  const sn_t sn = lsn / OS_FILE_LOG_BLOCK_SIZE * LOG_BLOCK_DATA_SIZE;

  /* Calculate offset for the provided lsn within the log block. */
  const uint32_t diff = lsn % OS_FILE_LOG_BLOCK_SIZE;

  if (diff < LOG_BLOCK_HDR_SIZE) {
    /* lsn points into block header → sn is the start of block */
    return sn;
  }

  if (diff > OS_FILE_LOG_BLOCK_SIZE - LOG_BLOCK_TRL_SIZE) {
    /* lsn points into block footer → sn is start of next block */
    return sn + LOG_BLOCK_DATA_SIZE;
  }

  /* Normal case: skip header bytes */
  return sn + diff - LOG_BLOCK_HDR_SIZE;
}

// storage/innobase/include/log0log.h:127
/** Validates that an lsn points to data bytes (not header/footer). */
inline bool log_is_data_lsn(lsn_t lsn) {
  const uint32_t offset = lsn % OS_FILE_LOG_BLOCK_SIZE;
  return lsn >= LOG_START_LSN && offset >= LOG_BLOCK_HDR_SIZE &&
         offset < OS_FILE_LOG_BLOCK_SIZE - LOG_BLOCK_TRL_SIZE;
}
```

---

## 2. Log Block 格式 — 物理布局

Redo Log 文件由 **512 字节的 log block** 组成。每个 block 有 header、data 和 trailer：

```c
// storage/innobase/include/log0constants.h:167
/** Log file offset constants */
constexpr os_offset_t LOG_CHECKPOINT_1 = OS_FILE_LOG_BLOCK_SIZE;       /* offset: 512 */
constexpr os_offset_t LOG_ENCRYPTION = 2 * OS_FILE_LOG_BLOCK_SIZE;     /* offset: 1024 */
constexpr os_offset_t LOG_CHECKPOINT_2 = 3 * OS_FILE_LOG_BLOCK_SIZE;   /* offset: 1536 */
constexpr os_offset_t LOG_FILE_HDR_SIZE = 4 * OS_FILE_LOG_BLOCK_SIZE;  /* offset: 2048 */

// storage/innobase/include/log0constants.h:297
/** Log block header is 12 bytes */
constexpr uint32_t LOG_BLOCK_HDR_SIZE = 12;

// storage/innobase/include/log0constants.h:306
/** Log block trailer (checksum) is 4 bytes */
constexpr uint32_t LOG_BLOCK_TRL_SIZE = 4;

// storage/innobase/include/log0constants.h:312
/** Data bytes per log block = 512 - 12 - 4 = 496 bytes */
constexpr uint32_t LOG_BLOCK_DATA_SIZE =
    OS_FILE_LOG_BLOCK_SIZE - LOG_BLOCK_HDR_SIZE - LOG_BLOCK_TRL_SIZE;
```

Log block 结构图：

```
Log Block (512 bytes):
┌─────────┬─────────────────────────────────┬──────────┐
│  Header │         Data area               │ Trailer  │
│  12 B   │         496 B max               │   4 B    │
├─────────┼─────────────────────────────────┼──────────┤
│ hdr_no  │ first_rec_group │ epoch_no      │ checksum │
│ (4B)    │ data_len (2B)   │ rec_offset(2B)│ (4B)     │
└─────────┴─────────────────────────────────┴──────────┘
```

Header 中各字段的偏移：

```c
// storage/innobase/include/log0constants.h:232
constexpr uint32_t LOG_BLOCK_HDR_NO = 0;            /* block number (4 bytes) */

// storage/innobase/include/log0constants.h:245  
constexpr uint32_t LOG_BLOCK_HDR_DATA_LEN = 4;       /* data len (2 bytes) + encrypt bit */

// storage/innobase/include/log0constants.h:256
constexpr uint32_t LOG_BLOCK_FIRST_REC_GROUP = 6;    /* first rec group offset (2 bytes) */

// storage/innobase/include/log0constants.h:285
constexpr uint32_t LOG_BLOCK_EPOCH_NO = 8;           /* epoch number (4 bytes) */

// storage/innobase/include/log0constants.h:294
constexpr uint32_t LOG_BLOCK_CHECKSUM = 4;            /* trailer checksum (4 bytes) */
```

### 2.1 Log Block Header 数据结构

```c
// storage/innobase/include/log0types.h:242
/** Meta data stored in header of a log data block. */
struct Log_data_block_header {
  /** Together with m_hdr_no form unique identifier of this block. */
  uint32_t m_epoch_no;

  /** Incremented by 1 for each next log data block (unless wrapped). */
  uint32_t m_hdr_no;

  /** Offset up to which this block has data inside. */
  uint16_t m_data_len;

  /** Offset to the first mtr starting in this block, or 0. */
  uint16_t m_first_rec_group;

  /** Sets m_epoch_no and m_hdr_no from a single lsn */
  void set_lsn(lsn_t lsn);
};
```

### 2.2 关键常量

```c
// storage/innobase/include/log0constants.h:153
/** LSN starts at this value (must be non-zero). */
constexpr lsn_t LOG_START_LSN = 16 * OS_FILE_LOG_BLOCK_SIZE;

// storage/innobase/include/log0constants.h:159
/** Maximum possible lsn value (only 63 bits used for sn). */
constexpr lsn_t LSN_MAX = (1ULL << 63) - 1;

// storage/innobase/include/log0constants.h:163
/** The sn bit used to express locked state. */
constexpr sn_t SN_LOCKED = 1ULL << 63;
```

`SN_LOCKED` 是 sn 的最高位。当 sn 被 x-lock 时，该位被置 1，其他线程的 `fetch_add` 会看到该位并等待。

---

## 3. log_t — 全局日志系统结构

`log_t` 是整个 redo log 系统的单例（全局变量 `log_sys`），包含近 80 个字段，分布在不同的 cache line 上。

```c
// storage/innobase/include/log0sys.h:77
struct alignas(ut::INNODB_CACHE_LINE_SIZE) log_t {
```

### 3.1 用户写入端（Log Buffer）

```c
// storage/innobase/include/log0sys.h:95
  /** Event used for locking sn */
  os_event_t sn_lock_event;

  // storage/innobase/include/log0sys.h:108
  /** Current sn value. Used to reserve space in the redo log.
  Represents number of data bytes that have ever been reserved.
  Bytes of headers and footers of log blocks are not included.
  Its highest bit is used for locking the access to the log buffer. */
  alignas(ut::INNODB_CACHE_LINE_SIZE) atomic_sn_t sn;

  // storage/innobase/include/log0sys.h:111
  /** Intended sn value while x-locked. */
  atomic_sn_t sn_locked;

  // storage/innobase/include/log0sys.h:116
  /** Aligned log buffer. User threads write redo records here,
  and the log_writer thread writes to disk in background. */
  alignas(ut::INNODB_CACHE_LINE_SIZE)
      ut::aligned_array_pointer<byte, LOG_BUFFER_ALIGNMENT> buf;

  // storage/innobase/include/log0sys.h:120
  /** Size of the log buffer in data bytes (excluding headers/footers). */
  atomic_sn_t buf_size_sn;

  // storage/innobase/include/log0sys.h:124
  /** Size of the log buffer in total bytes (including headers/footers). */
  size_t buf_size;

  // storage/innobase/include/log0sys.h:141
  /** The recent written buffer. Used by log_writer to find
  data that user threads have finished writing. */
  alignas(ut::INNODB_CACHE_LINE_SIZE) Link_buf<lsn_t> recent_written;
```

### 3.2 Writer ↔ Flusher 通信

```c
  // storage/innobase/include/log0sys.h:156
  /** Maximum sn up to which there is free space in both the log buffer
  and the log files. Threads need to wait when hitting this limit. */
  alignas(ut::INNODB_CACHE_LINE_SIZE) atomic_sn_t buf_limit_sn;

  // storage/innobase/include/log0sys.h:160
  /** Up to this lsn, data has been written to OS (fsync not required). */
  alignas(ut::INNODB_CACHE_LINE_SIZE) atomic_lsn_t write_lsn;

  // storage/innobase/include/log0sys.h:172
  /** Events for write notification (user threads wait for write_lsn). */
  alignas(ut::INNODB_CACHE_LINE_SIZE) os_event_t *write_events;
  size_t write_events_size;

  // storage/innobase/include/log0sys.h:199
  /** Events for flush notification (user threads wait for flushed_to_disk_lsn). */
  alignas(ut::INNODB_CACHE_LINE_SIZE) os_event_t *flush_events;
  size_t flush_events_size;

  // storage/innobase/include/log0sys.h:209
  /** Up to this lsn, data has been flushed to disk (fsynced). */
  alignas(ut::INNODB_CACHE_LINE_SIZE) atomic_lsn_t flushed_to_disk_lsn;
```

### 3.3 Writer Thread 字段

```c
  // storage/innobase/include/log0sys.h:232
  /** Buffer used for write-ahead (to avoid read-on-write issue). */
  alignas(ut::INNODB_CACHE_LINE_SIZE) uint32_t write_ahead_buf_size;
  ut::aligned_array_pointer<byte, LOG_WRITE_AHEAD_BUFFER_ALIGNMENT>
      write_ahead_buf;

  // storage/innobase/include/log0sys.h:250
  /** Current log file for the log_writer thread. */
  Log_file m_current_file{m_files_ctx, m_encryption_metadata};

  // storage/innobase/include/log0sys.h:268
  /** File handle for m_current_file. Used by both writer and flusher. */
  Log_file_handle m_current_file_handle{m_encryption_metadata};

  // storage/innobase/include/log0sys.h:289
  alignas(ut::INNODB_CACHE_LINE_SIZE) os_event_t writer_event;
```

### 3.4 Flusher Thread 字段

```c
  // storage/innobase/include/log0sys.h:217
  alignas(ut::INNODB_CACHE_LINE_SIZE) Log_clock_point last_flush_start_time;
  Log_clock_point last_flush_end_time;
  double flush_avg_time;
  mutable ib_mutex_t flusher_mutex;
  alignas(ut::INNODB_CACHE_LINE_SIZE) os_event_t flusher_event;
```

### 3.5 Checkpointer 字段与 LSN 边界

```c
  // storage/innobase/include/log0sys.h:414
  /** Maximum lsn available for checkpoint (smallest oldest_modification across flush lists). */
  lsn_t available_for_checkpoint_lsn;

  // storage/innobase/include/log0sys.h:422
  /** Forced checkpoint request (or 0). */
  lsn_t requested_checkpoint_lsn;

  // storage/innobase/include/log0sys.h:450
  /** Maximum lsn up to which there is free space in the redo log. */
  atomic_lsn_t free_check_limit_lsn;

  // storage/innobase/include/log0sys.h:455
  /** Margin for thread concurrency in free space calculation. */
  atomic_sn_t concurrency_margin;

  // storage/innobase/include/log0sys.h:468
  /** Event used by the checkpointer thread to wait. */
  alignas(ut::INNODB_CACHE_LINE_SIZE) os_event_t checkpointer_event;
  mutable ib_mutex_t checkpointer_mutex;

  // storage/innobase/include/log0sys.h:473
  /** Latest checkpoint lsn. */
  atomic_lsn_t last_checkpoint_lsn;

  // storage/innobase/include/log0sys.h:477
  /** Next checkpoint header to use (alternates between HEADER_1 and HEADER_2). */
  Log_checkpoint_header_no next_checkpoint_header_no;
```

### 3.6 文件管理

```c
  // storage/innobase/include/log0sys.h:347
  mutable ib_mutex_t m_files_mutex;
  Log_files_context m_files_ctx;

  // storage/innobase/include/log0sys.h:353
  /** In-memory dictionary of log files. */
  Log_files_dict m_files{m_files_ctx};

  // storage/innobase/include/log0sys.h:356
  size_t m_unused_files_count;

  // storage/innobase/include/log0sys.h:364
  /** Capacity limits for the redo log (innodb_redo_log_capacity). */
  Log_files_capacity m_capacity;
```

### 3.7 恢复字段

```c
  // storage/innobase/include/log0sys.h:394
  /** LSN from which recovery started. */
  lsn_t recovered_lsn;

  // storage/innobase/include/log0sys.h:396
  /** Format of the redo log (e.g., Log_format::CURRENT). */
  Log_format m_format;

  // storage/innobase/include/log0sys.h:403
  /** Recovery scan succeeded up to this lsn. */
  lsn_t m_scanned_lsn;
};
```

### 3.8 LSN 飞地 — 关键边界值

四个关键 LSN 将 log buffer 到磁盘的路径划分清晰：

```
┌─────────────────────────────────────────────────────────┐
│  log_get_lsn() / sn (最新)    ← 用户线程写入位置          │
│       │                                                  │
│  recent_written.tail()  ← log_writer 已处理上限           │
│       │                                                  │
│  log_buffer_ready_for_write_lsn()                        │
│       │  ← 已确认写入完毕（write_link 已添加）            │
│       │                                                  │
│  write_lsn              ← 已通过 pwrite 写入 OS buffer    │
│       │                                                  │
│  flushed_to_disk_lsn    ← 已通过 fsync 刷到磁盘           │
│       │                                                  │
│  last_checkpoint_lsn    ← 已确认所有脏页刷盘             │
│       │                                                  │
│  available_for_checkpoint_lsn ← 最小脏页的 oldest_mod LSN │
└─────────────────────────────────────────────────────────┘
```

---

## 4. 文件格式 — 循环日志

### 4.1 Log_file 结构

```c
// storage/innobase/include/log0types.h:454
/** Meta information about a single log file. */
struct Log_file {
  Log_file(const Log_files_context &files_ctx,
           Encryption_metadata &encryption_metadata);

  /** ID of the file (0 = #ib_redo0, 1 = #ib_redo1, ...). */
  Log_file_id m_id;

  /** True when file is consumed (all data in it is checkpointed). */
  bool m_consumed;

  /** True when file is full and next file exists. */
  bool m_full;

  /** Size in bytes, including LOG_FILE_HDR_SIZE. */
  os_offset_t m_size_in_bytes;

  /** LSN of the first byte in the file (aligned to OS_FILE_LOG_BLOCK_SIZE). */
  lsn_t m_start_lsn;

  /** LSN of the first byte after the file. */
  lsn_t m_end_lsn;

  // storage/innobase/include/log0types.h:514
  /** Checks if a given lsn belongs to this file. */
  bool contains(lsn_t lsn) const {
    return m_start_lsn <= lsn && lsn < m_end_lsn;
  }

  // storage/innobase/include/log0types.h:524
  /** Computes offset from the file start for a given lsn. */
  os_offset_t offset(lsn_t lsn) const {
    lsn_validate();
    ut_a(contains(lsn) || lsn == m_end_lsn);
    return offset(lsn, m_start_lsn);
  }

  // storage/innobase/include/log0types.h:533
  /** Static version: offset for given lsn and file_start_lsn. */
  static os_offset_t offset(lsn_t lsn, lsn_t file_start_lsn) {
    return LOG_FILE_HDR_SIZE + (lsn - file_start_lsn);
  }
};
```

### 4.2 文件布局

MySQL 8.4 使用 `#innodb_redo/` 子目录，文件名为 `#ib_redo0`, `#ib_redo1`, ...：

```
#innodb_redo/
├── #ib_redo0       ← 第一个文件，包含 checkpoint headers
├── #ib_redo1
├── #ib_redo2
└── ...

单个文件布局：
┌───────────────────────────────────┐
│ 文件头 (LOG_FILE_HDR_SIZE = 4KB) │
│  ├── LOG_HEADER_FORMAT     (4B)  │
│  ├── LOG_HEADER_START_LSN (8B)   │
│  ├── LOG_HEADER_CREATOR  (32B)   │
│  └── LOG_HEADER_FLAGS    (4B)    │
├───────────────────────────────────┤
│ Log Block 0: 512B header+data    │
│ Log Block 1: 512B header+data   │
│ ...                              │
│ Log Block N: 512B header+data   │
└───────────────────────────────────┘

第一个文件的特殊区域：
├── offset 0 - 511:   文件头
├── offset 512 - 1023:  LOG_CHECKPOINT_1
├── offset 1024 - 1535: LOG_ENCRYPTION
├── offset 1536 - 2047: LOG_CHECKPOINT_2
└── offset 2048+:        数据块
```

文件头常量：

```c
// storage/innobase/include/log0constants.h:129
constexpr const char *const LOG_DIRECTORY_NAME = "#innodb_redo";
constexpr const char *const LOG_FILE_BASE_NAME = "#ib_redo";
constexpr size_t LOG_N_FILES = 32;                     /* target number of files */
constexpr os_offset_t LOG_FILE_MIN_SIZE = 64 * 1024;   /* 64KB per file */

// storage/innobase/include/log0constants.h:131
constexpr os_offset_t LOG_CAPACITY_MIN = 8 * 1024 * 1024;          /* 8MB */
constexpr os_offset_t LOG_CAPACITY_MAX = 512ull * 1024 * 1024 * 1024; /* 512GB */
constexpr os_offset_t LOG_FILE_MAX_SIZE = LOG_CAPACITY_MAX / LOG_N_FILES;
```

### 4.3 Redo Log 版本

```c
// storage/innobase/include/log0types.h:136
enum class Log_format : uint32_t {
  LEGACY = 0,           /* Unknown format */
  VERSION_5_7_9 = 1,    /* MySQL 5.7.9 */
  VERSION_8_0_1 = 2,    /* Remove MLOG_FILE_NAME, introduce MLOG_FILE_OPEN */
  VERSION_8_0_3 = 3,    /* Allow checkpoint_lsn to point any data byte */
  VERSION_8_0_19 = 4,   /* Expand ulint compressed form */
  VERSION_8_0_28 = 5,   /* Row versioning header */
  VERSION_8_0_30 = 6,   /* innodb_redo_log_capacity, no wrapping */
  CURRENT = VERSION_8_0_30,
};
```

---

## 5. 写入路径 — 从 mtr 到 Log Buffer

### 5.1 mtr_t::commit() 入口

当 mini-transaction 提交时，`mtr_t::commit()` 调用 `Command::execute()` 将 redo record 写入共享 log buffer。

```c
// storage/innobase/mtr/mtr0mtr.cc:662
void mtr_t::commit() {
  ut_ad(is_active());
  m_impl.m_state = MTR_STATE_COMMITTING;

  Command cmd(this);

  if (has_any_log_record() ||
      (has_modifications() && m_impl.m_log_mode == MTR_LOG_NO_REDO)) {
    cmd.execute();       // 将 redo record 写入 log buffer
  } else {
    cmd.release_all();
    cmd.release_resources();
  }
}
```

### 5.2 Command::execute() — 完整的写入流程

```c
// storage/innobase/mtr/mtr0mtr.cc:840
void mtr_t::Command::execute() {
  ut_ad(m_impl->m_log_mode != MTR_LOG_NONE);

#ifndef UNIV_HOTBACKUP
  ulint len = prepare_write();

  if (len > 0) {
    mtr_write_log_t write_log;

    write_log.m_left_to_write = len;

    /* === Step 1: Reserve LSN space in the log buffer === */
    auto handle = log_buffer_reserve(*log_sys, len);

    write_log.m_handle = handle;
    write_log.m_lsn = handle.start_lsn;

    /* === Step 2: Copy each block of the mtr's redo data to log buffer === */
    m_impl->m_log.for_each_block(write_log);

    ut_ad(write_log.m_left_to_write == 0);
    ut_ad(write_log.m_lsn == handle.end_lsn);

    /* === Step 3: Wait until the flush list can accept our dirty pages === */
    buf_flush_list_added->wait_to_add(handle.start_lsn);

    DEBUG_SYNC_C("mtr_redo_before_add_dirty_blocks");

    /* === Step 4: Mark modified pages as dirty with their oldest_mod LSN === */
    add_dirty_blocks_to_flush_list(handle.start_lsn, handle.end_lsn);

    buf_flush_list_added->report_added(handle.start_lsn, handle.end_lsn);

    m_impl->m_mtr->m_commit_lsn = handle.end_lsn;

  } else {
    DEBUG_SYNC_C("mtr_noredo_before_add_dirty_blocks");
    add_dirty_blocks_to_flush_list(0, 0);
  }
#endif /* !UNIV_HOTBACKUP */

  release_all();
  release_resources();
}
```

**关键点**：`execute()` 的四步是原子的（从 log buffer 视角）：
1. `log_buffer_reserve` — 通过原子递增 `log.sn` 预留空间
2. `for_each_block(write_log)` — memcpy redo data 到共享 log buffer
3. `wait_to_add` — 保证 flush_list 操作顺序
4. `add_dirty_blocks_to_flush_list` — 以 `start_lsn` 作为 `oldest_modification` 将脏页加入 `flush_list`

### 5.3 log_buffer_reserve() — 原子预留 LSN

```c
// storage/innobase/log/log0buf.cc:884
Log_handle log_buffer_reserve(log_t &log, size_t len) {
  Log_handle handle;

  srv_stats.log_write_requests.inc();

  ut_ad(srv_shutdown_state_matches([](auto state) {
    return state <= SRV_SHUTDOWN_FLUSH_PHASE ||
           state == SRV_SHUTDOWN_EXIT_THREADS;
  }));

  ut_a(len > 0);

  /* === Reserve space by atomic increment of sn === */
  const sn_t start_sn = log_buffer_s_lock_enter_reserve(log, len);

  /* Ensure that redo log has been initialized properly. */
  ut_a(start_sn > 0);

#ifdef UNIV_DEBUG
  if (!recv_recovery_is_on()) {
    log_background_threads_active_validate(log);
  }
#endif

  /* Headers in redo blocks are not calculated to sn values: */
  const sn_t end_sn = start_sn + len;

  log_sync_point("log_buffer_reserve_before_buf_limit_sn");

  /* === Translate sn to lsn (includes block headers/footers) === */
  handle.start_lsn = log_translate_sn_to_lsn(start_sn);
  handle.end_lsn = log_translate_sn_to_lsn(end_sn);

  /* === If log buffer is full, wait for space === */
  if (unlikely(end_sn > log.buf_limit_sn.load())) {
    log_wait_for_space_after_reserving(log, handle);
  }

  ut_a(log_is_data_lsn(handle.start_lsn));
  ut_a(log_is_data_lsn(handle.end_lsn));

  return handle;
}
```

### 5.4 log_buffer_s_lock_enter_reserve — 原子递增 sn

```c
// storage/innobase/log/log0buf.cc:544
static inline sn_t log_buffer_s_lock_enter_reserve(log_t &log, size_t len) {
#ifdef UNIV_PFS_RWLOCK
  // ... performance schema instrumentation ...
#endif

  /* === THE KEY OPERATION: atomic fetch-add on log.sn ===
     This single atomic operation reserves len bytes of redo space.
     Multiple user threads can do this concurrently — each gets a
     unique sn range without locking against each other. */
  sn_t start_sn = log.sn.fetch_add(len);

  /* If someone else has x-locked sn, wait until unlocked */
  if (UNIV_LIKELY((start_sn & SN_LOCKED) != 0)) {
    start_sn &= ~SN_LOCKED;
    log_buffer_s_lock_wait(log, start_sn);
  }

  ut_d(rw_lock_add_debug_info(log.sn_lock_inst, 0, RW_LOCK_S, UT_LOCATION_HERE));

  return start_sn;
}
```

**关键设计**：多个用户线程可以同时调用 `log.sn.fetch_add(len)`，每个获得一个不重叠的 sn 范围。最高位 `SN_LOCKED` 用于排他操作（如 log buffer resize）。

### 5.5 log_buffer_write() — memcpy 到共享 Buffer

```c
// storage/innobase/log/log0buf.cc:944
lsn_t log_buffer_write(log_t &log, const byte *str, size_t str_len,
                       lsn_t start_lsn) {
  ut_ad(rw_lock_own(log.sn_lock_inst, RW_LOCK_S));

  ut_a(log.buf != nullptr);
  ut_a(log.buf_size > 0);
  ut_a(log.buf_size % OS_FILE_LOG_BLOCK_SIZE == 0);
  ut_a(str_len < log.buf_size_sn.load());

  /* The start_lsn points to a data byte (not a header). */
  ut_a(log_is_data_lsn(start_lsn));

  /* We neither write with holes, nor overwrite any fragments. */
  ut_ad(log.write_lsn.load() <= start_lsn);
  ut_ad(log_buffer_ready_for_write_lsn(log) <= start_lsn);

  const sn_t end_sn = log_translate_lsn_to_sn(start_lsn) + sn_t{str_len};

  byte *buf_end = log.buf + log.buf_size;
  byte *ptr = log.buf + (start_lsn % log.buf_size);
  lsn_t lsn = start_lsn;

  /* Copy log records to the reserved space, walking across
  log block boundaries and wrapping at the end of the buffer. */
  while (true) {
    /* Calculate offset from the beginning of log block. */
    const auto offset = lsn % OS_FILE_LOG_BLOCK_SIZE;

    ut_a(offset >= LOG_BLOCK_HDR_SIZE);
    ut_a(offset < OS_FILE_LOG_BLOCK_SIZE - LOG_BLOCK_TRL_SIZE);

    /* Free data bytes remaining in current log block. */
    const auto left = OS_FILE_LOG_BLOCK_SIZE - LOG_BLOCK_TRL_SIZE - offset;

    size_t len, lsn_diff;

    if (left > str_len) {
      /* There are enough free bytes to finish copying. */
      len = str_len;
      lsn_diff = str_len;
    } else {
      /* Copy up to the end of current block, continue in next. */
      len = left;
      lsn_diff = left + LOG_BLOCK_TRL_SIZE + LOG_BLOCK_HDR_SIZE;
    }

    /* === THE CRITICAL memcpy: copy redo record to shared log buffer === */
    std::memcpy(ptr, str, len);

    ut_a(len <= str_len);
    str_len -= len;
    str += len;
    lsn += lsn_diff;
    ptr += lsn_diff;

    ut_a(log_is_data_lsn(lsn));

    if (ptr >= buf_end) {
      /* Wrap around — next copy starts at buffer beginning. */
      ptr -= log.buf_size;
    }

    if (lsn_diff > left) {
      /* We crossed a log block boundary. Reset first_rec_group
      for the next block; the user will overwrite it if this is
      where the next mtr starts. */
      ut_a((uintptr_t(ptr) % OS_FILE_LOG_BLOCK_SIZE) == LOG_BLOCK_HDR_SIZE);

      log_block_set_first_rec_group(
          reinterpret_cast<byte *>(uintptr_t(ptr) &
                                   ~uintptr_t(LOG_BLOCK_HDR_SIZE)),
          0);

      if (str_len == 0) {
        break;
      }
    } else {
      break;  /* Normal finish. */
    }
  }

  ut_a(log_translate_lsn_to_sn(lsn) == end_sn);
  return lsn;
}
```

### 5.6 log_buffer_write_completed() — 记录完成

写入完成后，用户线程必须调用此函数来添加 recent_written 链接，这允许 log_writer 推进 ready_for_write_lsn。

```c
// storage/innobase/log/log0buf.cc:1084
void log_buffer_write_completed(log_t &log, lsn_t start_lsn, lsn_t end_lsn,
                                bool is_last_block) {
  ut_ad(rw_lock_own(log.sn_lock_inst, RW_LOCK_S));

  ut_a(log_is_data_lsn(start_lsn));
  ut_a(log_is_data_lsn(end_lsn));
  ut_a(end_lsn > start_lsn);

  /* Wait until start_lsn fits in the Link_buf window. */
  uint64_t wait_loops = 0;
  while (!log.recent_written.has_space(start_lsn)) {
    os_event_set(log.writer_event);
    ++wait_loops;
    std::this_thread::sleep_for(std::chrono::microseconds(20));
  }

  /* Memory fence: ensure all writes to log buffer are visible
  to the log_writer thread before we add the link. */
  std::atomic_thread_fence(std::memory_order_release);

  /* If this is the last block, release the s-lock on sn. */
  if (is_last_block) log_buffer_s_lock_exit(log);

  /* === Add the link to recent_written: this tells log_writer
     that data from start_lsn to end_lsn is ready to be written. === */
  log.recent_written.add_link_advance_tail(start_lsn, end_lsn);

  /* If someone is waiting for ready_lsn to advance, wake them. */
  lsn_t ready_lsn = log_buffer_ready_for_write_lsn(log);
  if (log.current_ready_waiting_lsn > 0 &&
      log.current_ready_waiting_lsn <= ready_lsn &&
      !os_event_is_set(log.closer_event) &&
      log_closer_mutex_enter_nowait(log) == 0) {
    if (log.current_ready_waiting_lsn > 0 &&
        log.current_ready_waiting_lsn <= ready_lsn &&
        !os_event_is_set(log.closer_event)) {
      log.current_ready_waiting_lsn = 0;
      os_event_set(log.closer_event);
    }
    log_closer_mutex_exit(log);
  }
}
```

### 5.7 log_buffer_set_first_record_group()

在 mtr 的最后一块 block 中，需要设置 `first_rec_group` 字段，标识当前 mtr 的 redo record 在此 block 中的偏移。

```c
// storage/innobase/log/log0buf.cc:1133
void log_buffer_set_first_record_group(log_t &log, lsn_t rec_group_end_lsn) {
  ut_ad(rw_lock_own(log.sn_lock_inst, RW_LOCK_S));

  const lsn_t last_block_lsn =
      ut_uint64_align_down(rec_group_end_lsn, OS_FILE_LOG_BLOCK_SIZE);

  byte *last_block_ptr = log.buf + (last_block_lsn % log.buf_size);

  /* Current mtr's first_rec_group hasn't been set yet (it's still 0). */
  ut_a(log_block_get_first_rec_group(last_block_ptr) == 0);

  log_block_set_first_rec_group(last_block_ptr,
                                rec_group_end_lsn % OS_FILE_LOG_BLOCK_SIZE);
}
```

---

## 6. 后台写入线程 — Log Writer

`log_writer` 是负责将 log buffer 中的 redo 数据通过 `pwrite()` 写入 OS buffer 的后台线程。

```c
// storage/innobase/log/log0write.cc:2230
void log_writer(log_t *log_ptr) {
  ut_a(log_ptr != nullptr);
  log_t &log = *log_ptr;
  lsn_t ready_lsn = 0;

  ut_d(log.m_writer_thd = create_internal_thd());

  log_writer_mutex_enter(log);

  Log_thread_waiting waiting{log, log.writer_event, srv_log_writer_spin_delay,
                             get_srv_log_writer_timeout()};

  Log_write_to_file_requests_monitor write_to_file_requests_monitor{log};

  for (uint64_t step = 0;; ++step) {
    bool released = false;

    /* === Wait for data to write, or shutdown signal === */
    auto stop_condition = [&ready_lsn, &log, &released,
                           &write_to_file_requests_monitor](bool wait) {
      if (released) {
        log_writer_mutex_enter(log);
        released = false;
      }

      /* === Compute how far the log buffer has been filled by user threads === */
      log_advance_ready_for_write_lsn(log);
      ready_lsn = log_buffer_ready_for_write_lsn(log);

      /* Wake if there's unwritten data or threads should stop. */
      if (log.write_lsn.load() < ready_lsn ||
          log.should_stop_threads.load()) {
        return true;
      }

      if (UNIV_UNLIKELY(
              log.writer_threads_paused.load(std::memory_order_acquire))) {
        return true;
      }

      if (wait) {
        write_to_file_requests_monitor.update();
        log_writer_mutex_exit(log);
        released = true;
      }

      return false;
    };

    const auto wait_stats = waiting.wait(stop_condition);

    MONITOR_INC_WAIT_STATS(MONITOR_LOG_WRITER_, wait_stats);

    /* Handle paused state (e.g. during log buffer resize). */
    if (UNIV_UNLIKELY(
            log.writer_threads_paused.load(std::memory_order_acquire) &&
            !log.should_stop_threads.load())) {
      log_writer_mutex_exit(log);
      os_event_wait(log.writer_threads_resume_event);
      log_writer_mutex_enter(log);
      ready_lsn = log_buffer_ready_for_write_lsn(log);
    }

    /* === DO THE ACTUAL WRITE === */
    if (log.write_lsn.load() < ready_lsn) {
      log_writer_write_buffer(log, ready_lsn);

      if (step % 1024 == 0) {
        write_to_file_requests_monitor.update();
        log_writer_mutex_exit(log);
        std::this_thread::yield();
        log_writer_mutex_enter(log);
      }

    } else if (log.should_stop_threads.load() &&
               log_writer_is_allowed_to_stop(log)) {
      break;
    }
  }

  log_writer_mutex_exit(log);
  ut_d(destroy_internal_thd(log.m_writer_thd));
}
```

### 6.1 log_writer_write_buffer — 核心写盘函数

```c
// storage/innobase/log/log0write.cc:2116
static void log_writer_write_buffer(log_t &log, lsn_t next_write_lsn) {
  ut_ad(log_writer_mutex_own(log));

  /* Realign next_write_lsn to log block boundary for writing. */
  lsn_t write_lsn = log.write_lsn.load();

  /* Compute end_lsn aligned to a full log block boundary. */
  lsn_t end_lsn = ut_uint64_align_up(next_write_lsn, OS_FILE_LOG_BLOCK_SIZE);

  if (end_lsn != next_write_lsn) {
    /* We need to handle the incomplete block specially —
    copy it to write_ahead_buf first to avoid tearing. */

    /* ... copy incomplete block to write_ahead_buf ... */
  }

  while (write_lsn < end_lsn) {
    /* compute file offset from lsn */
    os_offset_t offset = log.m_current_file.offset(write_lsn);

    /* pwrite() the log buffer data to the file */
    dberr_t err = log.m_current_file_handle.write(
        offset,
        OS_FILE_LOG_BLOCK_SIZE,
        log.buf + (write_lsn % log.buf_size));

    if (err != DB_SUCCESS) {
      log_writer_write_failed(log, err);
    }

    write_lsn += OS_FILE_LOG_BLOCK_SIZE;
  }

  /* Update write_lsn to reflect what's been written to OS buffer. */
  log.write_lsn.store(end_lsn);
}
```

---

## 7. 后台刷盘线程 — Log Flusher

```c
// storage/innobase/log/log0write.cc:2495
void log_flusher(log_t *log_ptr) {
  ut_a(log_ptr != nullptr);
  log_t &log = *log_ptr;

  Log_thread_waiting waiting{log, log.flusher_event, srv_log_flusher_spin_delay,
                             get_srv_log_flusher_timeout()};

  log_flusher_mutex_enter(log);

  for (uint64_t step = 0;; ++step) {
    /* On shutdown, let writer finish and then do one last fsync. */
    if (log.should_stop_threads.load()) {
      if (!log_writer_is_active()) {
        break;
      }
    }

    /* Handle paused state. */
    if (UNIV_UNLIKELY(
            log.writer_threads_paused.load(std::memory_order_acquire))) {
      log_flusher_mutex_exit(log);
      os_event_wait(log.writer_threads_resume_event);
      log_flusher_mutex_enter(log);
    }

    bool released = false;

    auto stop_condition = [&log, &released, step](bool wait) {
      if (released) {
        log_flusher_mutex_enter(log);
        released = false;
      }

      log_sync_point("log_flusher_before_should_flush");

      const lsn_t last_flush_lsn = log.flushed_to_disk_lsn.load();

      ut_a(last_flush_lsn <= log.write_lsn.load());

      if (last_flush_lsn < log.write_lsn.load()) {
        /* === There is data to flush. Do the fsync! === */
        log_flush_low(log);

        if (step % 1024 == 0) {
          log_flusher_mutex_exit(log);
          std::this_thread::yield();
          log_flusher_mutex_enter(log);
        }

        return true;
      }

      /* Stop waiting if writer thread is dead. */
      if (log.should_stop_threads.load()) {
        if (!log_writer_is_active()) {
          return true;
        }
      }

      if (UNIV_UNLIKELY(
              log.writer_threads_paused.load(std::memory_order_acquire))) {
        return true;
      }

      if (wait) {
        log_flusher_mutex_exit(log);
        released = true;
      }

      return false;
    };

    if (srv_flush_log_at_trx_commit != 1) {
      /* When trx_commit != 1, user threads don't wake the flusher.
      Use a timeout-based wait to avoid missing flushes. */
      // ... timeout-based wait logic ...
    }

    const auto wait_stats = waiting.wait(stop_condition);
    MONITOR_INC_WAIT_STATS(MONITOR_LOG_FLUSHER_, wait_stats);
  }

  /* Final flush before exit. */
  log_flush_low(log);
  log_flusher_mutex_exit(log);
}
```

`log_flush_low` 调用 `fsync()`：

```c
// log_flush_low internal:
static void log_flush_low(log_t &log) {
  ut_ad(log_flusher_mutex_own(log));

  /* Record flush start time. */
  log.last_flush_start_time = Log_clock::now();

  /* === THE KEY fsync: ensure data hits stable storage === */
  log.m_current_file_handle.fsync();

  /* Update flush end time. */
  log.last_flush_end_time = Log_clock::now();

  /* Advance flushed_to_disk_lsn. */
  log.flushed_to_disk_lsn.store(log.write_lsn.load());

  /* Wake user threads waiting for flush. */
  os_event_set(log.flush_notifier_event);
}
```

---

## 8. log_write_up_to — 等待日志刷盘

用户线程在事务提交时调用 `log_write_up_to(commit_lsn, true)` 来确保 redo log 已落盘。

```c
// storage/innobase/log/log0write.cc:1055
Wait_stats log_write_up_to(log_t &log, lsn_t end_lsn, bool flush_to_disk) {
  ut_a(!srv_read_only_mode);

  /* During recovery, we don't actually flush — pages are being
  replayed from the log. */
  if (recv_recovery_is_on()) {
    return Wait_stats{0};
  }

  /* Update statistics for writer thread scheduling. */
  log.write_to_file_requests_total.store(
      log.write_to_file_requests_total.load(std::memory_order_relaxed) + 1,
      std::memory_order_relaxed);

  ut_a(end_lsn != LSN_MAX);
  ut_a(end_lsn % OS_FILE_LOG_BLOCK_SIZE == 0 ||
       end_lsn % OS_FILE_LOG_BLOCK_SIZE >= LOG_BLOCK_HDR_SIZE);

  Wait_stats wait_stats{0};
  bool interrupted = false;

retry:
  if (log.writer_threads_paused.load(std::memory_order_acquire)) {
    /* Writer threads paused — do the write ourselves. */
    wait_stats +=
        log_self_write_up_to(log, end_lsn, flush_to_disk, &interrupted);

    if (UNIV_UNLIKELY(interrupted)) {
      goto retry;
    }
    return wait_stats;
  }

  /* Writer threads are running — let them do the work. */

  if (flush_to_disk) {
    if (log.flushed_to_disk_lsn.load() >= end_lsn) {
      /* Already flushed — fast path. */
      DEBUG_SYNC_C("log_flushed_by_writer");
      return wait_stats;
    }

    if (srv_flush_log_at_trx_commit != 1) {
      /* Non-default setting: writer doesn't wake flusher,
      so we need to ensure write_lsn >= end_lsn first. */
      if (log.write_lsn.load() < end_lsn) {
        wait_stats += log_wait_for_write(log, end_lsn, &interrupted);
      }
    }

    /* === Wait until flushed_to_disk_lsn reaches end_lsn === */
    wait_stats += log_wait_for_flush(log, end_lsn, &interrupted);

    if (UNIV_UNLIKELY(interrupted)) {
      goto retry;
    }

    DEBUG_SYNC_C("log_flushed_by_writer");
  } else {
    /* Just wait for write (no fsync needed). */
    if (log.write_lsn.load() >= end_lsn) {
      return wait_stats;
    }

    wait_stats += log_wait_for_write(log, end_lsn, &interrupted);

    if (UNIV_UNLIKELY(interrupted)) {
      goto retry;
    }
  }

  return wait_stats;
}
```

### 8.1 等待机制

用户线程在 `log_wait_for_flush` 中通过 `os_event_t` 等待：

```c
// 简化的等待逻辑（log0write.cc:1250-1400）
Wait_stats log_wait_for_flush(log_t &log, lsn_t end_lsn, bool *interrupted) {
  /* Spin-wait first (short fast path). */
  for (uint32_t i = 0; i < srv_n_spin_wait_rounds; i++) {
    if (log.flushed_to_disk_lsn.load() >= end_lsn) {
      return Wait_stats{};
    }
    ut_delay(ut::random_from_interval(0, srv_spin_wait_delay));
  }

  /* Fall back to event-based wait. */
  while (log.flushed_to_disk_lsn.load() < end_lsn) {
    /* Subscribe to flush_events array based on lsn. */
    size_t index = (end_lsn / OS_FILE_LOG_BLOCK_SIZE) % log.flush_events_size;
    auto event = log.flush_events[index];

    os_event_wait(event);
  }

  return Wait_stats{/* wait time */};
}
```

### 8.2 三个 LSN 推进器的协作

```
用户线程:          log_get_lsn() / sn (最新)
                     │
                     │  log.recent_written.add_link(start_lsn, end_lsn)
                     ▼
log_writer:     log_buffer_ready_for_write_lsn()
                     │
                     │  检查 recent_written，推进 ready_lsn
                     │  pwrite() 将数据写入 OS buffer
                     ▼
                write_lsn
                     │
                     │  os_event_set(write_notifier_event)
                     ▼
                write_notifier: 通知用户线程
                     │
                     │  os_event_set(flusher_event)
                     ▼
log_flusher:    flushed_to_disk_lsn
                     │
                     │  fsync() → os_event_set(flush_notifier_event)
                     ▼
                flush_notifier: 通知等待 COMMIT 的用户线程
```

---

## 9. Checkpoint — 控制恢复范围

### 9.1 log_checkpointer 线程

```c
// storage/innobase/log/log0chkp.cc:904
void log_checkpointer(log_t *log_ptr) {
  ut_a(log_ptr != nullptr);
  log_t &log = *log_ptr;

  ut_d(log.m_checkpointer_thd = create_internal_thd());

  static const uint64_t log_busy_checkpoint_interval = 7;
  auto old_activity_count = srv_get_activity_count();
  ulint error = OS_SYNC_TIME_EXCEEDED;

  for (;;) {
    log_checkpointer_mutex_enter(log);

    const auto sig_count = os_event_reset(log.checkpointer_event);
    const lsn_t requested_checkpoint_lsn = log.requested_checkpoint_lsn;

    /* Check system activity for adaptive checkpoint interval. */
    bool system_is_busy = false;
    if (error == OS_SYNC_TIME_EXCEEDED &&
        srv_check_activity(old_activity_count)) {
      old_activity_count = srv_get_activity_count();
      system_is_busy = true;
    }

    if (error != OS_SYNC_TIME_EXCEEDED || !system_is_busy ||
        requested_checkpoint_lsn >
            log.last_checkpoint_lsn.load(std::memory_order_acquire) ||
        log_checkpoint_time_elapsed(log) >=
            log_busy_checkpoint_interval * get_srv_log_checkpoint_every()) {
      /* Consider flushing dirty pages and writing checkpoint. */
      log_consider_sync_flush(log);
      log_consider_checkpoint(log);
    }

    log_checkpointer_mutex_exit(log);

    if (requested_checkpoint_lsn >
        log.last_checkpoint_lsn.load(std::memory_order_relaxed)) {
      error = 0;  /* pending request — retry immediately */
    } else {
      error = os_event_wait_time_low(log.checkpointer_event,
                                     get_srv_log_checkpoint_every(), sig_count);
    }

    /* === Shutdown sequence === */
    if (log.should_stop_threads.load()) {
      ut_ad(!log.writer_threads_paused.load());
      if (!log_flusher_is_active() && !log_writer_is_active()) {
        lsn_t end_lsn = log.write_lsn.load();

        ut_a(end_lsn == log.flushed_to_disk_lsn.load());
        ut_a(end_lsn == log_buffer_ready_for_write_lsn(log));

        if (buf_flush_list_added->smallest_not_added_lsn() == end_lsn) {
          /* All dirty pages have been added to flush lists. */
          break;
        }
      }
    }
  }

  ut_d(destroy_internal_thd(log.m_checkpointer_thd));
}
```

### 9.2 log_consider_checkpoint — 决定是否写 checkpoint

```c
// storage/innobase/log/log0chkp.cc:872
static void log_consider_checkpoint(log_t &log) {
  ut_ad(log_checkpointer_mutex_own(log));

  /* Check all conditions for writing a new checkpoint. */
  if (!log_should_checkpoint(log)) {
    return;
  }

  /* We need to write a checkpoint. First persist dynamic metadata. */
  log_checkpointer_mutex_exit(log);

  if (log_test == nullptr) {
    dict_persist_to_dd_table_buffer();
  }

  log_checkpointer_mutex_enter(log);

  /* Re-check conditions (they may have changed while we released mutex). */
  if (!log_should_checkpoint(log)) {
    return;
  }

  /* === Write the checkpoint === */
  log_checkpoint(log);
}
```

### 9.3 log_checkpoint — 确定 new checkpoint LSN

```c
// storage/innobase/log/log0chkp.cc:123
static void log_checkpoint(log_t &log) {
  ut_ad(log_checkpointer_mutex_own(log));

  // Determine the new checkpoint LSN:
  //   min(oldest_modification across all flush list dirty pages,
  //       buf_flush_list_added->smallest_not_added_lsn(),
  //       oldest_consumer_lsn)

  const lsn_t available_lsn = log.available_for_checkpoint_lsn;
  ut_a(available_lsn >= log.last_checkpoint_lsn.load());

  // Ensure all pages with oldest_modification < available_lsn are flushed.
  buf_flush_sync_lsn(available_lsn);

  // Write the checkpoint header to the log file.
  log_checkpoint_write(log, available_lsn);

  // Update last_checkpoint_lsn.
  log.last_checkpoint_lsn.store(available_lsn);
}
```

Checkpoint 写入的位置是轮换的（`LOG_CHECKPOINT_1` 和 `LOG_CHECKPOINT_2`）：

```c
// log0chkp.cc 中写 checkpoint header
static void log_checkpoint_write(log_t &log, lsn_t checkpoint_lsn) {
  ut_ad(log_checkpointer_mutex_own(log));

  Log_checkpoint_header header;
  header.m_checkpoint_lsn = checkpoint_lsn;

  /* Alternate between HEADER_1 and HEADER_2. */
  auto header_no = log.next_checkpoint_header_no;

  /* Write checkpoint to the log file. */
  log_checkpoint_header_write(log, header_no, header);

  /* Toggle for next time. */
  if (header_no == Log_checkpoint_header_no::HEADER_1) {
    log.next_checkpoint_header_no = Log_checkpoint_header_no::HEADER_2;
  } else {
    log.next_checkpoint_header_no = Log_checkpoint_header_no::HEADER_1;
  }
}
```

---

## 10. 事务提交流程

### 10.1 完整提交流程

```
用户线程: COMMIT
  │
  ├── (1) trx->flush_log_later 或立即提交
  │
  ├── (2) trx_write_serialisation_history()
  │     ├── 将事务日志写入 redo (commit record as redo)
  │     └── 获取 commit_lsn
  │
  ├── (3) log_write_up_to(log, trx->commit_lsn, true)
  │     ├── 等待 flushed_to_disk_lsn >= trx->commit_lsn
  │     ├── → log_writer 将数据 pwrite 到 OS buffer
  │     └── → log_flusher 执行 fsync()
  │
  ├── (4) trx->release_all_latches()
  │
  ├── (5) trx_commit_in_memory()
  │     └── 标记事务为 COMMITTED 状态
  │
  └── (6) 响应客户端: COMMIT OK
```

### 10.2 srv_flush_log_at_trx_commit 的影响

```c
// MySQL 系统参数
srv_flush_log_at_trx_commit:
  1: 每次 COMMIT 都执行 fsync (最安全)
  2: 每次 COMMIT 只写 OS buffer (pwrite)，每秒 fsync
  0: 每秒写 + 每秒 fsync (最不安全)
```

- `=1`：`log_write_up_to(commit_lsn, true)` 等待 fsync
- `=2`：`log_write_up_to(commit_lsn, false)` 只等 pwrite
- `=0`：不调用 `log_write_up_to`，依赖定时器

---

## 11. Crash Recovery — 崩溃恢复

恢复入口函数是 `recv_recovery_from_checkpoint_start()`，分为三步：

### 11.1 恢复入口

```c
// storage/innobase/log/log0recv.cc:3766
dberr_t recv_recovery_from_checkpoint_start(log_t &log, lsn_t flush_lsn) {
  if (srv_force_recovery >= SRV_FORCE_NO_LOG_REDO) {
    ib::info(ER_IB_MSG_728);
    ut_a(log.sn == 0);
    ut_a(srv_read_only_mode);
    return DB_SUCCESS;
  }

  recv_recovery_on = true;
  ut_a(log.m_format == Log_format::CURRENT);

  /* === Step 1: Find the latest checkpoint === */
  Log_checkpoint_location checkpoint;
  if (!recv_find_max_checkpoint(log, checkpoint)) {
    ib::error(ER_IB_MSG_RECOVERY_CHECKPOINT_NOT_FOUND);
    return DB_ERROR;
  }

  const auto checkpoint_file = log.m_files.find(checkpoint.m_checkpoint_lsn);

  if (checkpoint_file == log.m_files.end()) {
    ut_d(ut_error);
    ut_o(return DB_ERROR);
  }

  log.last_checkpoint_lsn.store(checkpoint.m_checkpoint_lsn);

  const auto file_path = log_file_path(log.m_files_ctx, checkpoint_file->m_id);
  ib::info(ER_IB_MSG_LOG_CHECKPOINT_FOUND,
           ulonglong{checkpoint.m_checkpoint_lsn}, file_path.c_str());

  /* Read the checkpoint header to verify. */
  Log_checkpoint_header checkpoint_header;
  auto checkpoint_file_handle =
      checkpoint_file->open(Log_file_access_mode::READ_ONLY);

  if (!checkpoint_file_handle.is_open()) {
    return DB_CANNOT_OPEN_FILE;
  }

  dberr_t err = log_checkpoint_header_read(checkpoint_file_handle,
                                           checkpoint.m_checkpoint_header_no,
                                           checkpoint_header);
  if (err != DB_SUCCESS) {
    return err;
  }

  checkpoint_file_handle.close();

  const lsn_t checkpoint_lsn = checkpoint.m_checkpoint_lsn;
  ut_a(checkpoint_lsn == checkpoint_header.m_checkpoint_lsn);

  /* Determine if recovery is needed by comparing checkpoint_lsn
  with the flush_lsn (the lsn stored in system tablespace header). */
  if (checkpoint_lsn != flush_lsn) {
    if (checkpoint_lsn < flush_lsn) {
      ib::warn(ER_IB_MSG_RECOVERY_CHECKPOINT_FROM_BEFORE_CLEAN_SHUTDOWN,
               ulonglong{checkpoint_lsn}, ulonglong{flush_lsn});
    }

    if (!recv_needed_recovery) {
      ib::info(ER_IB_MSG_RECOVERY_IS_NEEDED, ulonglong{flush_lsn},
               ulonglong{checkpoint_lsn});

      if (srv_read_only_mode) {
        ib::error(ER_IB_MSG_RECOVERY_IN_READ_ONLY);
        return DB_ERROR;
      }

      recv_init_crash_recovery();
    }
  }

  /* === Step 2: Begin scanning redo from checkpoint_lsn === */
  err = recv_recovery_begin(log, checkpoint_lsn);
  if (err != DB_SUCCESS) {
    return err;
  }

  // ... continued scanning and applying ...

  return DB_SUCCESS;
}
```

### 11.2 查找最新 Checkpoint

```c
// storage/innobase/log/log0recv.cc:973
static bool recv_find_max_checkpoint(log_t &log,
                                     Log_checkpoint_location &checkpoint) {
  bool found = false;
  checkpoint = {};

  /* Scan ALL redo log files for checkpoints. */
  log_files_for_each(log.m_files, [&](const Log_file &file) {
    auto file_handle = file.open(Log_file_access_mode::READ_ONLY);
    ut_a(file_handle.is_open());

    Log_checkpoint_location checkpoint_in_file;

    /* Read both checkpoint headers (HEADER_1 and HEADER_2). */
    if (!recv_find_max_checkpoint(log, file_handle, checkpoint_in_file)) {
      return;
    }

    /* Verify checkpoint_lsn is within the file. */
    if (!file.contains(checkpoint_in_file.m_checkpoint_lsn)) {
      const auto file_path = file_handle.file_path();
      ib::error(ER_IB_MSG_RECOVERY_CHECKPOINT_OUTSIDE_LOG_FILE,
                ulonglong{checkpoint_in_file.m_checkpoint_lsn},
                file_path.c_str(), ulonglong{file.m_start_lsn},
                ulonglong{file.m_end_lsn});
      return;
    }

    /* Keep the one with the highest checkpoint_lsn. */
    if (!found ||
        checkpoint_in_file.m_checkpoint_lsn > checkpoint.m_checkpoint_lsn) {
      found = true;
      checkpoint = checkpoint_in_file;
    }
  });

  return found;
}
```

### 11.3 扫描 Redo 记录

```c
// storage/innobase/log/log0recv.cc:3289
static bool recv_scan_log_recs(log_t &log,
                               size_t max_memory, const byte *buf, size_t len,
                               lsn_t start_lsn, lsn_t *read_upto_lsn) {
  const byte *log_block = buf;
  lsn_t scanned_lsn = start_lsn;
  bool finished = false;
  bool more_data = false;

  ut_ad(start_lsn % OS_FILE_LOG_BLOCK_SIZE == 0);
  ut_ad(len % OS_FILE_LOG_BLOCK_SIZE == 0);

  do {
    ut_ad(!finished);

    /* Deserialize the log block header. */
    Log_data_block_header block_header;
    log_data_block_header_deserialize(log_block, block_header);

    /* === Validate block header consistency === */
    const uint32_t expected_hdr_no =
        log_block_convert_lsn_to_hdr_no(scanned_lsn);

    if (block_header.m_hdr_no != expected_hdr_no) {
      /* Garbage or incompletely written block — end of log. */
      finished = true;
      break;
    }

    /* === Validate checksum === */
    if (!log_block_checksum_is_ok(log_block)) {
      uint32_t checksum1 = log_block_get_checksum(log_block);
      uint32_t checksum2 = log_block_calc_checksum(log_block);
      ib::error(ER_IB_MSG_720, ulong{block_header.m_hdr_no},
                ulonglong{scanned_lsn}, ulong{checksum1}, ulong{checksum2});
      finished = true;
      break;
    }

    const auto data_len = block_header.m_data_len;

    /* === Validate epoch number === */
    if (scanned_lsn + data_len > recv_sys->scanned_lsn &&
        recv_sys->scanned_epoch_no > 0 &&
        !log_block_epoch_no_is_valid(block_header.m_epoch_no,
                                     recv_sys->scanned_epoch_no)) {
      finished = true;
      break;
    }

    /* === Find first rec group (parse starting point) === */
    if (!recv_sys->parse_start_lsn && block_header.m_first_rec_group > 0) {
      recv_sys->parse_start_lsn =
          scanned_lsn + block_header.m_first_rec_group;

      ib::info(ER_IB_MSG_1261)
          << "Starting to parse redo log at lsn = " << recv_sys->parse_start_lsn
          << ", whereas checkpoint_lsn = " << recv_sys->checkpoint_lsn;

      /* If parse start is before checkpoint, we need to skip bytes. */
      if (recv_sys->parse_start_lsn < recv_sys->checkpoint_lsn) {
        recv_sys->bytes_to_ignore_before_checkpoint =
            recv_sys->checkpoint_lsn - recv_sys->parse_start_lsn;
      }

      recv_sys->scanned_lsn = recv_sys->parse_start_lsn;
      recv_sys->recovered_lsn = recv_sys->parse_start_lsn;

      recv_track_changes_of_recovered_lsn();
    }

    scanned_lsn += data_len;

    /* === Parse log records and add to parsing buffer === */
    if (scanned_lsn > recv_sys->scanned_lsn) {
      // ... prepare for crash recovery if needed ...
      if (!recv_needed_recovery && scanned_lsn > recv_sys->checkpoint_lsn) {
        if (srv_read_only_mode) { /* ... */ }
        recv_init_crash_recovery();
      }

      /* Parse bytes into recv_sys parsing buffer. */
      more_data =
          recv_sys_add_to_parsing_buf(log_block, scanned_lsn) || more_data;

      recv_sys->scanned_lsn = scanned_lsn;
      recv_sys->scanned_epoch_no = block_header.m_epoch_no;
    }

    if (data_len < OS_FILE_LOG_BLOCK_SIZE) {
      /* Last block in the log — not full means end of log. */
      finished = true;
      break;
    } else {
      log_block += OS_FILE_LOG_BLOCK_SIZE;
    }

  } while (log_block < buf + len);

  *read_upto_lsn = scanned_lsn;

  /* Try to parse more records from the buffer. */
  if (more_data && !recv_sys->found_corrupt_log) {
    recv_parse_log_recs();

#ifndef UNIV_HOTBACKUP
    /* Apply records if we've used too much memory. */
    if (recv_heap_used() > max_memory) {
      recv_apply_hashed_log_recs(log);
    }
#endif /* !UNIV_HOTBACKUP */

    if (recv_sys->recovered_offset > recv_sys->buf_len / 4) {
      recv_reset_buffer();
    }
  }

  return finished;
}
```

### 11.4 应用 Redo 记录到页面

```c
// storage/innobase/log/log0recv.cc:1173
void recv_apply_hashed_log_recs(log_t &log) {
  mutex_enter(&recv_sys->mutex);
  ut_a(!srv_read_only_mode);

  recv_sys->apply_log_recs = true;

  const auto batch_size = recv_sys->n_pages_to_recover.value();

  ib::info(ER_IB_MSG_707, ulonglong{batch_size});

  static const size_t PCT = 10;
  size_t pct = PCT;
  size_t applied = 0;
  auto unit = batch_size / PCT;

  if (unit <= PCT) {
    pct = 100;
    unit = batch_size;
  }

  auto start_time = std::chrono::steady_clock::now();

  /* === Iterate over all tablespaces that have recovery records === */
  for (const auto &space : *recv_sys->spaces) {
    bool dropped = false;

    /* Open tablespace for recovery (may be dropped since the log). */
    if (space.first != TRX_SYS_SPACE) {
      dberr_t err = fil_tablespace_open_for_recovery(space.first);
      if (err == DB_CORRUPTION) {
        mutex_exit(&recv_sys->mutex);
        ib::fatal(UT_LOCATION_HERE, ER_IB_ERR_CORRUPT_TABLESPACE_UNRECOVERABLE,
                  space.first);
      } else if (err != DB_SUCCESS) {
        ut_a_eq(err, DB_FAIL);
        /* Tablespace was dropped. */
        if (fil_tablespace_lookup_for_recovery(space.first)) {
          ut_ad(fsp_is_undo_tablespace(space.first));
        }
        dropped = true;
      }
    }

    /* === Apply each page's redo records === */
    for (auto pages : space.second.m_pages) {
      ut_ad(pages.second->space == space.first);

      if (dropped) {
        pages.second->state = RECV_DISCARDED;
        one_less_page_to_recover();
      } else {
        /* === Apply the redo log record to this page === */
        recv_apply_log_rec(pages.second);
      }

      ++applied;

      /* Print progress every 10% or every printable interval. */
      if (unit == 0 || (applied % unit) == 0) {
        ib::info(ER_IB_MSG_708) << pct << "%";
        pct += PCT;
        start_time = std::chrono::steady_clock::now();
      } else if (std::chrono::steady_clock::now() - start_time >=
                 PRINT_INTERVAL) {
        start_time = std::chrono::steady_clock::now();
        ib::info(ER_IB_MSG_709)
            << std::setprecision(2)
            << ((double)applied * 100) / (double)batch_size << "%";
      }
    }
  }

  /* Wait for all pages to finish processing. */
  mutex_exit(&recv_sys->mutex);
  recv_sys->n_pages_to_recover.await_zero();
  mutex_enter(&recv_sys->mutex);

  /* Flush all recovered pages to disk and invalidate buffer pool. */
  ut_d(log.disable_redo_writes = true);
  mutex_exit(&recv_sys->mutex);

  /* Wait for pending I/O operations before invalidation. */
  buf_pool_wait_for_no_pending_io();

  recv_sys->flush_type = BUF_FLUSH_LIST;
  os_event_set(recv_sys->flush_start);
  os_event_wait(recv_sys->flush_end);

  /* Commit the recovered transaction and invalidate the buffer pool. */
  trx_rollback_rescan();
  trx_recovery_rollback();

  buf_pool_invalidate();

  ut_d(log.disable_redo_writes = false);
}
```

---

## 12. recv_t — 恢复系统状态

```c
// storage/innobase/log/log0recv.cc:97
recv_sys_t *recv_sys = nullptr;
volatile bool recv_recovery_on;  // true during recovery phase
```

`recv_sys` 管理恢复期间的全局状态：

```
recv_sys:
  ├── checkpoint_lsn         — 从哪里开始扫描
  ├── parse_start_lsn        — 第一个解析到的 rec group
  ├── scanned_lsn            — 已经扫描到的 lsn
  ├── recovered_lsn          — 已经恢复到的 lsn
  ├── len / buf_len          — 解析缓冲区
  ├── buf                    — 解析缓冲区内存
  ├── spaces                 — 所有涉及的表空间
  │   └── space → pages[]
  │       └── page → redo records (hash表)
  ├── n_pages_to_recover     — 需要恢复的页面计数
  ├── apply_log_recs         — 是否正在应用记录
  └── flush_start / flush_end — 用于刷脏页的事件
```

---

## 13. Log block 由函数族

写入和读取 log block 字段的辅助函数：

```c
// 写入 block header 字段
void log_block_set_hdr_no(byte *block, uint32_t hdr_no);
void log_block_set_data_len(byte *block, uint16_t len);
void log_block_set_first_rec_group(byte *block, uint16_t offset);
void log_block_set_epoch_no(byte *block, uint32_t epoch_no);
void log_block_set_checksum(byte *block, uint32_t checksum);

// 读取 block header 字段
uint32_t log_block_get_hdr_no(const byte *block);
uint16_t log_block_get_data_len(const byte *block);
uint16_t log_block_get_first_rec_group(const byte *block);
uint32_t log_block_get_epoch_no(const byte *block);

// 计算 hdr_no
uint32_t log_block_convert_lsn_to_hdr_no(lsn_t lsn) {
  return (lsn / OS_FILE_LOG_BLOCK_SIZE) % LOG_BLOCK_MAX_NO;
}
```

---

## 14. 数据流全景图

```
内存中的旅程：
═══════════════════════════════════════════════════

mtr_commit()
  │
  ├── prepare_write() → 将 mtr 的 redo lists 序列化为连续 buffer
  │
  ├── log_buffer_reserve(log_sys, len)
  │   └── log.sn.fetch_add(len)           ← 原子操作，无锁
  │   └── log_translate_sn_to_lsn()       ← 计算 start/end lsn
  │   └── end_sn > buf_limit_sn? 等待     ← 空间不足时等待
  │
  ├── log_buffer_write() → memcpy(...)    ← 写入共享 log buffer
  │   ├── 处理 block 边界穿越
  │   └── 处理 buffer 回绕 (wrap-around)
  │
  ├── log_buffer_set_first_record_group() ← 设置 mtr 的首记录偏移
  │
  ├── log_buffer_write_completed()        ← 添加 recent_written link
  │   └── log.recent_written.add_link()
  │   └── log_buffer_s_lock_exit()        ← 释放 sn 的 s-lock
  │
  └── add_dirty_blocks_to_flush_list()    ← 将脏页按 oldest_mod 排序加入 flush_list

磁盘上的旅程：
═══════════════════════════════════════════════════

log_writer 线程:
  ├── log_advance_ready_for_write_lsn()
  │   └── 扫描 recent_written 推进 ready_lsn
  ├── log_writer_write_buffer()
  │   └── pwrite() 到日志文件             ← 写 OS buffer
  └── update log.write_lsn

log_flusher 线程:
  ├── log_flush_low()
  │   ├── log.m_current_file_handle.fsync()  ← 刷磁盘
  │   └── update log.flushed_to_disk_lsn
  └── notify flush_notifier → 唤醒等待 COMMIT 的用户线程

崩溃恢复：
═══════════════════════════════════════════════════

recv_recovery_from_checkpoint_start():
  ├── recv_find_max_checkpoint()          ← 扫描所有文件找最新 checkpoint
  ├── recv_scan_log_recs()                ← 从 checkpoint 扫描 redo
  │   ├── 验证 block header (hdr_no, epoch_no, checksum)
  │   ├── 解析 rec group 并加入 parsing buffer
  │   └── 超过最大内存时自动 apply
  └── recv_apply_hashed_log_recs()        ← 逐 page 重放 redo record
      ├── 打开 tablespace
      ├── recv_apply_log_rec()            ← 核心：执行 redo record
      └── 刷脏页 + invalidate buffer pool
```

---

## 15. 关键函数索引

| 函数 | 文件 | 行号 | 作用 |
|------|------|------|------|
| `log_t` (struct) | `log0sys.h` | 77 | 全局日志系统结构（~80 字段） |
| `Log_data_block_header` | `log0types.h` | 242 | Log block 头结构 |
| `Log_file` | `log0types.h` | 454 | 单个日志文件元信息 |
| `log_translate_sn_to_lsn` | `log0log.h` | 85 | sn → lsn 转换 |
| `log_translate_lsn_to_sn` | `log0log.h` | 94 | lsn → sn 转换 |
| `log_is_data_lsn` | `log0log.h` | 127 | 验证 lsn 指向数据区 |
| `log_get_lsn` | `log0log.h` | 159 | 获取当前最大 lsn |
| `log_buffer_s_lock_enter_reserve` | `log0buf.cc` | 544 | 原子递增 sn 预留空间 |
| `log_buffer_reserve` | `log0buf.cc` | 884 | 预留 log buffer 空间 |
| `log_buffer_write` | `log0buf.cc` | 944 | memcpy 到 log buffer |
| `log_buffer_write_completed` | `log0buf.cc` | 1084 | 释放 s-lock + 写完成通知 |
| `log_buffer_set_first_record_group` | `log0buf.cc` | 1133 | 设置首 rec group 偏移 |
| `mtr_t::commit` | `mtr0mtr.cc` | 662 | mtr 提交入口 |
| `mtr_t::Command::execute` | `mtr0mtr.cc` | 840 | 完整的 redo 写入执行 |
| `log_write_up_to` | `log0write.cc` | 1055 | 等待日志写入/刷盘 |
| `log_writer` | `log0write.cc` | 2230 | Log writer 线程主循环 |
| `log_writer_write_buffer` | `log0write.cc` | 2116 | pwrite 数据到 OS buffer |
| `log_flusher` | `log0write.cc` | 2495 | Log flusher 线程主循环 |
| `log_flush_low` | `log0write.cc` | 内部 | 执行 fsync |
| `log_checkpointer` | `log0chkp.cc` | 904 | Checkpointer 线程主循环 |
| `log_consider_checkpoint` | `log0chkp.cc` | 872 | 判断是否写 checkpoint |
| `log_checkpoint` | `log0chkp.cc` | 123 | 写入 checkpoint header |
| `recv_find_max_checkpoint` | `log0recv.cc` | 973 | 扫描找最新 checkpoint |
| `recv_scan_log_recs` | `log0recv.cc` | 3289 | 扫描 redo 记录 |
| `recv_apply_hashed_log_recs` | `log0recv.cc` | 1173 | 应用 redo 记录到页面 |
| `recv_recovery_from_checkpoint_start` | `log0recv.cc` | 3766 | 崩溃恢复入口 |
| Log format/block constants | `log0constants.h` | 40+ | 所有 log block 偏移常量 |

---

## 16. 总结

InnoDB Redo Log 的设计精髓：

1. **原子 sn 预留**：`log_buffer_s_lock_enter_reserve` 使用 `log.sn.fetch_add()` 实现无锁并发预留，用户线程之间不需要互斥。

2. **三层写入分离**：用户线程只做 memcpy（极快），log_writer 做 pwrite，log_flusher 做 fsync。每个线程专注于自己的工作，最大化 I/O 吞吐。

3. **Link_buf 机制**：`recent_written` 跟踪哪些 LSN 范围的 redo 数据已经写完，log_writer 不需要锁就能知道哪些数据可以写磁盘。

4. **WAL 原则**：事务提交时必须 `log_write_up_to(commit_lsn, true)` 等待 fsync 完成，确保任何已提交事务的 redo 在磁盘上。

5. **Checkpoint 缩短恢复**：周期性地确定可回收的 LSN 边界（`last_checkpoint_lsn`），崩溃恢复时只需扫描 checkpoint 之后的 redo。

6. **三阶段恢复**：找 checkpoint → 扫描 redo 记录 → 逐页重放。使用哈希表按 page_id 分区，实现随机页面级的并行恢复。

7. **循环文件设计**：MySQL 8.4 引入动态文件创建/回收（基于 `innodb_redo_log_capacity`），取代了 8.0 之前固定大小循环覆盖的方式。

---

*分析工具：MySQL 8.4 主线源码 | 分析日期：2026-05-06 | 源码路径：`storage/innobase/`*
