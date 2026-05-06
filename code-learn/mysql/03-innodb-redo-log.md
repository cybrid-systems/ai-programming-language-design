# 03-innodb-redo-log — InnoDB Redo Log：WAL 与 Crash Recovery

> 基于 MySQL 8.4 主线源码
> 使用 doom-lsp（clangd LSP）进行符号定位
> 分析日期：2026-05-06 | 源码路径：`~/code/mysql`

---

## 0. 概述

Redo Log 是 InnoDB **WAL（Write-Ahead Logging）** 机制的核心。所有页面修改必须先写 Redo Log 再写数据文件，保证事务的持久性（Durability）和崩溃恢复（Crash Recovery）的正确性。

核心设计：

```
事务提交
  │
  ├── mtr_t::commit() -> 写 redo record 到 log buffer
  ├── log_write_up_to() -> log writer 线程写入 OS buffer
  ├── fsync() -> log flusher 线程刷到磁盘
  └── 事务标记 COMMITTED
```

**WAL 原则**：数据页可以晚于日志写磁盘，但日志必须在事务提交前落盘。

---

## 1. 核心数据结构

### 1.1 log_t — 全局日志系统

```cpp
// storage/innobase/include/log0sys.h:77 — doom-lsp 确认
struct alignas(ut::INNODB_CACHE_LINE_SIZE) log_t {
  /** Current sn value. Used to reserve space in the redo log,
  and used to acquire an exclusive access to the log buffer.
  Represents number of data bytes that have ever been reserved. */
  alignas(ut::INNODB_CACHE_LINE_SIZE) atomic_sn_t sn;

  /** Aligned log buffer. */
  alignas(ut::INNODB_CACHE_LINE_SIZE)
      ut::aligned_array_pointer<byte, LOG_BUFFER_ALIGNMENT> buf;

  /** Size of the log buffer in number of data bytes */
  atomic_sn_t buf_size_sn;

  /** Latest LSN (last modified LSN + meta) */
  lsn_t lsn;

  /** LSN up to which we have written to OS */
  lsn_t write_lsn;

  /** LSN up to which we have flushed to disk */
  lsn_t flushed_to_disk_lsn;

  /** Recent written buffer */
  lsn_t recent_written;

  /** Recent closed buffer */
  lsn_t recent_closed;

  /** Log file header/file info */
  Log_files_capacity *files_capacity;
  Log_files_dict *files_dict;
};
```

### 1.2 核心类型

```cpp
// storage/innobase/include/log0types.h:63 — doom-lsp 确认
typedef uint64_t lsn_t;   // Log Sequence Number

// 日志块大小
#define OS_FILE_LOG_BLOCK_SIZE 512

// LSN 与字节偏移的转换
// lsn_t → 日志文件中的字节偏移
```

`lsn_t` 是 64 位无符号整数，单调递增。它对应的是写入 redo log 的累计字节数（不含块头块尾的元数据字节）。

### 1.3 Redo Log 文件布局

```
+---------------------+
| Log file 1 (ib_logfile0) |
| [header][block][block]...|
+---------------------+
| Log file 2 (ib_logfile1) |
| [header][block][block]...|
+---------------------+
|   ...                 |
+---------------------+

每个 log block (512 bytes):
+-------+------------------+-------+
| hdr   |   redo records   |  trl  |
| 12B   |   492B max      |  4B   |
+-------+------------------+-------+
```

---

## 2. 写入路径 — mtr → log buffer

### 2.1 Mini-Transaction 记录 Redo

所有页面修改通过 `mlog_write_*` 函数记录：

```cpp
// storage/innobase/include/mtr0log.h:69 — doom-lsp 确认
void mlog_write_ulint(
    byte *ptr,       // 页面内的写入位置
    ulint val,       // 要写的值
    mlog_id_t type,  // MLOG_1BYTE/MLOG_2BYTES/MLOG_4BYTES
    mtr_t *mtr);     // mini-transaction

void mlog_write_string(
    byte *ptr,
    const byte *str,
    ulint len,
    mtr_t *mtr);

void mlog_write_initial_log_record(
    const byte *ptr,
    mlog_id_t type,
    mtr_t *mtr);
```

### 2.2 mtr_t::commit — 写入 Log Buffer

```cpp
// storage/innobase/mtr/mtr0mtr.cc:662 — doom-lsp 确认
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

`cmd.execute()` 的完整路径：
1. 获取 `sn` 锁（预留 log buffer 空间）
2. 将 redo record 拷贝到 `log_t::buf`
3. 更新 `log_t::lsn`
4. 释放 `sn` 锁
5. 将脏页加入 Buffer Pool 的 `flush_list`（按 `oldest_modification` LSN 排序）

### 2.3 写入路径流程

```
mtr_commit()
  │
  └── cmd.execute()
        │
        ├── log_buffer_reserve() → 预留 LSN 空间
        │   ├── atomic_fetch_add(log.sn, len)
        │   └── 如果 buffer 满 → log_writer 线程触发写盘
        │
        ├── mtr_write_log_t() → 拷贝 redo record 到 buffer
        │
        ├── log_buffer_close() → 释放 sn 锁
        │
        └── mtr_t::Command::add_dirtied_pages()
            └── buf_flush_add_for_write()
                └── 脏页加入 buf_pool->flush_list
```

---

## 3. 写出线程 — Log Writer & Log Flusher

InnoDB 使用三个独立的后台线程将 redo log 从 buffer 刷到磁盘：

```
log_t 中的 LSN 飞地：
┌─────────────────────────────────────────────┐
│                                             │
│  lsn (最新)       ← 用户线程写入位置         │
│   │                                          │
│  recent_closed     ← log_writer 已处理上限    │
│   │                                          │
│  write_lsn         ← 已写入 OS buffer         │
│   │                                          │
│  flushed_to_disk_lsn ← 已 fsync 到磁盘       │
│                                             │
└─────────────────────────────────────────────┘
```

### 3.1 Log Writer 线程

将 log buffer 中未写出部分写入到 OS buffer（`write()` 系统调用）：

```
log_writer_thread()
  │
  ├── 等待：有新的 redo record 或超时
  ├── log_write_up_to(log, lsn, false)
  │   ├── 计算需要写入的范围 (recent_closed → write_lsn)
  │   ├── pwrite() 写入日志文件
  │   └── 更新 write_lsn
  └── 通知 log_flusher 线程
```

### 3.2 Log Flusher 线程

将 OS buffer 中的日志通过 `fsync()` 刷到磁盘：

```
log_flusher_thread()
  │
  ├── 等待：write_lsn > flushed_to_disk_lsn
  ├── fsync() 日志文件
  ├── 更新 flushed_to_disk_lsn
  └── 唤醒等待事务提交完成的用户线程
```

### 3.3 log_write_up_to — 等待日志刷盘

```cpp
// storage/innobase/log/log0write.cc:1055 — doom-lsp 确认
Wait_stats log_write_up_to(log_t &log, lsn_t end_lsn, bool flush_to_disk) {
  // flush_to_disk=true → 等待 fsync 完成
  // flush_to_disk=false → 只需写入 OS buffer

  if (flush_to_disk) {
    // 等待 flushed_to_disk_lsn >= end_lsn
    log_wait_for_write(log, end_lsn, true);
  } else {
    // 等待 write_lsn >= end_lsn
    log_wait_for_write(log, end_lsn, false);
  }
}
```

---

## 4. 崩溃恢复 — recv_recovery_from_checkpoint_start

启动时，InnoDB 通过 Redo Log 恢复未写入数据文件的修改：

```cpp
// storage/innobase/log/log0recv.cc:3766 — doom-lsp 确认
dberr_t recv_recovery_from_checkpoint_start(log_t &log, lsn_t flush_lsn) {
  recv_recovery_on = true;

  // 1. 找到最新的 checkpoint
  Log_checkpoint_location checkpoint;
  if (!recv_find_max_checkpoint(log, checkpoint)) {
    return DB_ERROR;
  }

  log.last_checkpoint_lsn.store(checkpoint.m_checkpoint_lsn);

  // 2. 从 checkpoint 位置开始扫描日志
  // ...
}
```

恢复过程的三步：

```
崩溃恢复
  │
  ├── Step 1: recv_recovery_from_checkpoint_start()
  │   ├── recv_find_max_checkpoint() → 扫描日志文件找最新 checkpoint
  │   ├── recv_scan_log() → 从 checkpoint_lsn 扫描所有 redo record
  │   │   ├── 识别每条 redo record 涉及的 page_id
  │   │   ├── 根据 page_id 分区（recv_sys->addr_hash）
  │   │   └── 记录 redo record 在哈希表中
  │   └── 结束扫描 → 开始应用 redo
  │
  ├── Step 2: 应用 redo record
  │   ├── recv_apply_hashed_log_recs()
  │   ├── 按 page_id 逐一重放修改
  │   └── 重用 Buffer Pool 进行页面恢复
  │
  └── Step 3: recv_recovery_from_checkpoint_finish()
      ├── 清理恢复阶段的数据结构
      └── 记录新的 checkpoint
```

恢复期间，InnoDB 使用 `recv_sys` 全局结构管理恢复状态：

```cpp
// storage/innobase/log/log0recv.cc:97 — doom-lsp 确认
recv_sys_t *recv_sys = nullptr;
volatile bool recv_recovery_on;  // 是否在恢复阶段
```

---

## 5. Checkpoint — 减少恢复时间

Checkpoint 的目的是缩短崩溃恢复时间。它确保 checkpoint LSN 之前的所有脏页已经刷到磁盘，恢复时只需重放 checkpoint 之后的 redo。

```
时间轴：
  │         checkpoint        崩溃
  ▼──────────────▼─────────────▼──────────
              │               │
              └── 已刷盘 ────┘  ← 不需要恢复
                              │
                              └── 需要 redo 恢复
```

```cpp
// storage/innobase/log/log0chkp.cc:132 — doom-lsp 确认
static void log_checkpoint(log_t &log) {
  // 1. 确定新的 checkpoint_lsn
  //    → flush_list 中 oldest_modification 最小的脏页的 LSN
  //
  // 2. 确保所有 checkpoint_lsn 之前的脏页已刷盘
  //    → 等待 buf_flush_sync_lsn > checkpoint_lsn
  //
  // 3. 写入 checkpoint 到日志文件头
  //    → 记录 checkpoint_lsn
}
```

### 5.1 为什么 Checkpoint 重要？

如果没有 checkpoint：
- 恢复时需要扫描全部 redo log
- 长时间运行的系统可能有几百 GB 的 redo log
- 恢复需要数小时

有了 checkpoint：
- 只需从最新 checkpoint 开始恢复
- 恢复时间通常只有几秒到几分钟

---

## 6. 事务提交与 Redo Log

```
用户线程：COMMIT
  │
  ├── 1. 事务标记 PREPARED（两阶段提交）
  │
  ├── 2. log_write_up_to(log, trx->commit_lsn, true)
  │   ├── 等待 flush_to_disk_lsn >= trx->commit_lsn
  │   └── ← fsync 完成，redo log 已落盘
  │
  ├── 3. 事务标记 COMMITTED
  │
  └── 4. 响应客户端：COMMIT OK
```

**关键语义**：`log_write_up_to` 的 `flush_to_disk=true` 参数保证 `fsync` 完成后才返回。崩溃后，MySQL 通过 redo log 可以恢复所有已提交事务的修改。

---

## 7. Redo 记录格式

每条 redo record 的格式：

```
+--------+--------+----------+--------+--------+--------+----------+
| type   | space  | page_no  | body   | ...    | end    |           |
| 1 byte | 4 byte | 4 byte   | N bytes|        | (implied by mtr) |
+--------+--------+----------+--------+--------+--------+----------+
```

- `type`：操作类型（`MLOG_1BYTE`、`MLOG_2BYTES`、`MLOG_4BYTES`、`MLOG_8BYTES`、`MLOG_STRING` 等）
- `space`：表空间 ID
- `page_no`：页面号
- `body`：页面内的偏移 + 写入的值

```cpp
// storage/innobase/include/mtr0log.h:93 — doom-lsp 确认
// mlog_write_initial_log_record() 写入 type + space + page_no
// mlog_catenate_ulint() 写入页面内偏移
// mlog_catenate_string() 写入实际数据
```

---

## 8. 关键函数索引

| 函数 | 文件 | 行号 | 作用 |
|------|------|------|------|
| `mtr_t::commit` | `mtr0mtr.cc` | 662 | mtr 提交，写 redo record |
| `mlog_write_ulint` | `mtr0log.h` | 69 | 记录整数修改 |
| `mlog_write_string` | `mtr0log.h` | 82 | 记录字符串修改 |
| `log_write_up_to` | `log0write.cc` | 1055 | 等待日志写入/刷盘 |
| `log_checkpoint` | `log0chkp.cc` | 132 | 创建 checkpoint |
| `recv_recovery_from_checkpoint_start` | `log0recv.cc` | 3766 | 崩溃恢复入口 |
| `recv_recovery_from_checkpoint_finish` | `log0recv.cc` | 3950 | 恢复完成 |
| `recv_find_max_checkpoint` | `log0recv.cc` | — | 扫描最新的 checkpoint |
| `log_t` | `log0sys.h` | 77 | 日志系统结构 |

---

## 9. 数据流总结

```
用户线程修改页面
  │
  ├── mtr_start()
  ├── mlog_write_ulint() → 记录 redo record 到 mtr 私有 buffer
  ├── mtr_commit() → cmd.execute()
  │   ├── log_buffer_reserve() → 在 log_t.buf 中预留空间
  │   ├── memcpy(redo record → log_t.buf)
  │   └── buf_flush_add_for_write() → 加入 flush_list
  │
  ├── 事务提交
  │   └── log_write_up_to(commit_lsn, flush_to_disk=true)
  │       ├── log_writer: pwrite(logfile_buf) → write_lsn 推进
  │       └── log_flusher: fsync(logfile) → flushed_to_disk_lsn 推进
  │
  └── 崩溃恢复时：
      ├── recv_find_max_checkpoint() → 找到最新 checkpoint
      ├── recv_scan_log() → 扫描 redo record
      └── recv_apply_hashed_log_recs() → 重放修改
```

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-06 | MySQL 8.4 | 源码路径：`~/code/mysql`*
