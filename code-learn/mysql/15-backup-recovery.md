# 15-backup-recovery — MySQL 备份与恢复

## 0. 概述

MySQL 的备份与恢复体系围绕两个核心日志展开：**redo log**（物理重做日志）和 **binlog**（逻辑二进制日志）。前者保障事务持久性（crash-safe），后者支撑时间点恢复（PITR）与主从复制。

- **冷备**：直接拷贝数据文件，要求数据库关闭或 FLUSH TABLES WITH READ LOCK
- **逻辑备份**：通过 `mysqldump` 将数据导出为 SQL 语句，可重新执行重建数据库
- **物理备份**：如 XtraBackup，直接拷贝 ibd 文件并跟踪 redo log 实现一致性

恢复的核心流程：

```
[Full Backup] → [Restore to MySQL] → [Apply Redo Log (crash recovery)] → [Apply Binlog (PITR)]
                                  ↑                              ↑
                        InnoDB 自动执行                    mysqlbinlog 手动执行
```

本文从源码层面剖析这三个关键环节：**Crash Recovery**（`log0recv.cc`）、**mysqldump** 逻辑备份、**binlog 恢复（PITR）**。

---

## 1. Crash Recovery 源码路径 (log0recv.cc)

InnoDB 的 crash recovery 是一个严格分阶段的流程。入口在 `recv_recovery_from_checkpoint_start()`，结束于 `recv_recovery_from_checkpoint_finish()`。

### 1.1 整体调用链

在 `srv0start.cc` 中，`srv_start()` 函数在初始化 buffer pool、AIO 子系统后，调用 crash recovery：

```cpp
// srv0start.cc:1764
err = recv_recovery_from_checkpoint_start(*log_sys, flushed_lsn);
if (err != DB_SUCCESS) {
  return srv_init_abort(err);
}
// ...
// srv0start.cc:1816
auto *dict_metadata = recv_recovery_from_checkpoint_finish(false);
```

`flushed_lsn` 来自系统表空间头部的 `FIL_PAGE_FILE_FLUSH_LSN` 字段，表示上次正常关机时的 fsync 位置。

### 1.2 recv_sys_t — 恢复系统的核心数据结构

```cpp
// log0recv.h:375
struct recv_sys_t {
  using Pages =
      std::unordered_map<page_no_t, recv_addr_t *, std::hash<page_no_t>,
                         std::equal_to<page_no_t>>;

  struct Space {
    explicit Space(mem_heap_t *heap) : m_heap(heap), m_pages() {}
    mem_heap_t *m_heap;
    Pages m_pages;           // 该表空间中需要恢复的 page
  };

  using Spaces = std::unordered_map<space_id_t, Space,
                       std::hash<space_id_t>, std::equal_to<space_id_t>>;

  // log0recv.h:506
  /** Number of unique unprocessed page ids */
  ut::Todo_counter n_pages_to_recover;

  /** Buffer for parsing redo log records */
  byte *buf;
  size_t buf_len;
  ulint len;

  lsn_t parse_start_lsn;    // 实际开始解析的 LSN
  lsn_t checkpoint_lsn;     // 从 checkpoint 读取的 LSN
  lsn_t scanned_lsn;        // 已扫描到的 LSN

  /** == true when applying log records to pages is allowed */
  bool apply_log_recs;

  // ... more fields
};
```

全局变量 `recv_sys` 在 `recv_sys_create()` 中分配：

```cpp
// log0recv.cc:308
void recv_sys_create() {
  if (recv_sys != nullptr) {
    return;
  }
  recv_sys = static_cast<recv_sys_t *>(
      ut::zalloc_withkey(UT_NEW_THIS_FILE_PSI_KEY, sizeof(*recv_sys)));
  mutex_create(LATCH_ID_RECV_SYS, &recv_sys->mutex);
  mutex_create(LATCH_ID_RECV_WRITER, &recv_sys->writer_mutex);
  recv_sys->spaces = nullptr;
}
```

### 1.3 recv_recovery_from_checkpoint_start() — 恢复入口

这是 crash recovery 的主入口。它负责找到最新的 checkpoint，从 checkpoint LSN 开始扫描 redo log。

```cpp
// log0recv.cc:3766
dberr_t recv_recovery_from_checkpoint_start(log_t &log, lsn_t flush_lsn) {
  if (srv_force_recovery >= SRV_FORCE_NO_LOG_REDO) {
    ib::info(ER_IB_MSG_728);
    ut_a(log.sn == 0);
    ut_a(srv_read_only_mode);
    return DB_SUCCESS;       // 跳过 redo 重做
  }

  recv_recovery_on = true;
  ut_a(log.m_format == Log_format::CURRENT);

  /* Step 1: 找到最新的 checkpoint */
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

  /* 保存 checkpoint LSN */
  log.last_checkpoint_lsn.store(checkpoint.m_checkpoint_lsn);

  /* Step 2: 读取 checkpoint header */
  Log_checkpoint_header checkpoint_header;
  auto checkpoint_file_handle =
      checkpoint_file->open(Log_file_access_mode::READ_ONLY);
  dberr_t err = log_checkpoint_header_read(
      checkpoint_file_handle,
      checkpoint.m_checkpoint_header_no, checkpoint_header);
  checkpoint_file_handle.close();

  const lsn_t checkpoint_lsn = checkpoint.m_checkpoint_lsn;

  /* Step 3: 检查是否需要 recovery */
  if (checkpoint_lsn != flush_lsn) {
    if (!recv_needed_recovery) {
      ib::info(ER_IB_MSG_RECOVERY_IS_NEEDED,
               ulonglong{flush_lsn}, ulonglong{checkpoint_lsn});
      recv_init_crash_recovery();      // 初始化双写缓冲恢复
    }
  }

  /* Step 4: 开始扫描 redo log */
  err = recv_recovery_begin(log, checkpoint_lsn);
  if (err != DB_SUCCESS) return err;

  // ... 验证 scanner LSNs、启动 log writer

  log.recovered_lsn = recovered_lsn;

  err = log_start(log, checkpoint_lsn, recovered_lsn, false);
  if (err != DB_SUCCESS) return err;

  return DB_SUCCESS;
}
```

### 1.4 recv_find_max_checkpoint() — 找最新 checkpoint

InnoDB 在每个 redo log 文件中写入两个 checkpoint header（HEADER_1 和 HEADER_2），取其中 `m_checkpoint_lsn` 最大的那个。

```cpp
// log0recv.cc:933
[[nodiscard]] static bool recv_find_max_checkpoint(
    log_t &, Log_file_handle &file_handle,
    Log_checkpoint_location &checkpoint) {
  bool found = false;
  checkpoint = {};

  for (auto checkpoint_header_no : {Log_checkpoint_header_no::HEADER_1,
                                    Log_checkpoint_header_no::HEADER_2}) {
    Log_checkpoint_header checkpoint_header;
    const dberr_t err = log_checkpoint_header_read(
        file_handle, checkpoint_header_no, checkpoint_header);
    if (err != DB_SUCCESS) {
      ut_a(err == DB_CORRUPTION);
      continue;
    }

    const lsn_t checkpoint_lsn = checkpoint_header.m_checkpoint_lsn;
    if (checkpoint_lsn == 0) continue;

    if (!found || checkpoint_lsn > checkpoint.m_checkpoint_lsn) {
      ut_a(checkpoint_lsn >= LOG_START_LSN);
      found = true;
      checkpoint.m_checkpoint_file_id = file_handle.file_id();
      checkpoint.m_checkpoint_header_no = checkpoint_header_no;
      checkpoint.m_checkpoint_lsn = checkpoint_lsn;
    }
  }
  return found;
}
```

跨所有 redo log 文件遍历的版本：

```cpp
// log0recv.cc:973
static bool recv_find_max_checkpoint(log_t &log,
                                     Log_checkpoint_location &checkpoint) {
  bool found = false;
  checkpoint = {};

  log_files_for_each(log.m_files, [&](const Log_file &file) {
    auto file_handle = file.open(Log_file_access_mode::READ_ONLY);
    Log_checkpoint_location checkpoint_in_file;

    if (!recv_find_max_checkpoint(log, file_handle, checkpoint_in_file))
      return;

    // 验证 checkpoint_lsn 落在文件范围内
    if (!file.contains(checkpoint_in_file.m_checkpoint_lsn)) {
      ib::error(ER_IB_MSG_RECOVERY_CHECKPOINT_OUTSIDE_LOG_FILE,
                ulonglong{checkpoint_in_file.m_checkpoint_lsn},
                file_handle.file_path().c_str(),
                ulonglong{file.m_start_lsn}, ulonglong{file.m_end_lsn});
      return;
    }

    if (!found || checkpoint_in_file.m_checkpoint_lsn >
                   checkpoint.m_checkpoint_lsn) {
      found = true;
      checkpoint = checkpoint_in_file;
    }
  });
  return found;
}
```

### 1.5 recv_scan_log_recs() — 扫描 redo log

扫描从 checkpoint LSN 对齐后的 block 边界开始，逐 block 校验 header 和 checksum。

```cpp
// log0recv.cc:3289
static bool recv_scan_log_recs(log_t &log,
                               size_t max_memory, const byte *buf, size_t len,
                               lsn_t start_lsn, lsn_t *read_upto_lsn) {
  const byte *log_block = buf;
  lsn_t scanned_lsn = start_lsn;
  bool finished = false;
  bool more_data = false;

  ut_ad(start_lsn % OS_FILE_LOG_BLOCK_SIZE == 0);

  do {
    ut_ad(!finished);

    Log_data_block_header block_header;
    log_data_block_header_deserialize(log_block, block_header);

    const uint32_t expected_hdr_no =
        log_block_convert_lsn_to_hdr_no(scanned_lsn);

    /* 校验 block header 序号 */
    if (block_header.m_hdr_no != expected_hdr_no) {
      finished = true;
      break;    // 不完整写入 → 截断
    }

    /* 校验 checksum */
    if (!log_block_checksum_is_ok(log_block)) {
      uint32_t checksum1 = log_block_get_checksum(log_block);
      uint32_t checksum2 = log_block_calc_checksum(log_block);
      ib::error(ER_IB_MSG_720,
                ulong{block_header.m_hdr_no}, ulonglong{scanned_lsn},
                ulong{checksum1}, ulong{checksum2});
      finished = true;
      break;
    }

    const auto data_len = block_header.m_data_len;

    /* 找到第一个有效 redo record 组 */
    if (!recv_sys->parse_start_lsn &&
        block_header.m_first_rec_group > 0) {
      recv_sys->parse_start_lsn =
          scanned_lsn + block_header.m_first_rec_group;
      recv_sys->scanned_lsn = recv_sys->parse_start_lsn;
      recv_sys->recovered_lsn = recv_sys->parse_start_lsn;
    }

    scanned_lsn += data_len;

    // ... 将数据添加到解析缓冲区，触发 recv_parse_log_recs()
    more_data = recv_sys_add_to_parsing_buf(log_block, scanned_lsn)
                || more_data;
    recv_sys->scanned_lsn = scanned_lsn;

    if (data_len < OS_FILE_LOG_BLOCK_SIZE) {
      finished = true;    // 最后一个不完整的 block
      break;
    }
    log_block += OS_FILE_LOG_BLOCK_SIZE;
  } while (log_block < buf + len);

  *read_upto_lsn = scanned_lsn;

  /* 解析已缓冲的记录，如果占用了太多内存则立即 apply */
  recv_parse_log_recs();

  if (recv_heap_used() > max_memory) {
    recv_apply_hashed_log_recs(log);    // 批量刷出
  }

  return finished;
}
```

关键设计：`recv_scan_log_recs()` 被循环调用，每次扫描一个 SCAN_SIZE（通常 64KB）的日志块。当解析缓冲区的 redo 记录超过 `max_memory`（`delta_hashmap_max_mem`）时，立即调用 `recv_apply_hashed_log_recs()` 写入到数据页，然后清空哈希表。

### 1.6 recv_apply_hashed_log_recs() — 应用 redo

这是实际的 redo 重做阶段。遍历 `recv_sys->spaces` 哈希表中的所有 space→pages 映射，将记录的 redo 变更应用到对应的数据页。

```cpp
// log0recv.cc:1173
void recv_apply_hashed_log_recs(log_t &log) {
  mutex_enter(&recv_sys->mutex);
  ut_a(!srv_read_only_mode);

  recv_sys->apply_log_recs = true;

  const auto batch_size = recv_sys->n_pages_to_recover.value();
  ib::info(ER_IB_MSG_707, ulonglong{batch_size});

  for (const auto &space : *recv_sys->spaces) {
    bool dropped = false;

    if (space.first != TRX_SYS_SPACE) {
      dberr_t err = fil_tablespace_open_for_recovery(space.first);
      if (err == DB_CORRUPTION) {
        mutex_exit(&recv_sys->mutex);
        ib::fatal(UT_LOCATION_HERE,
                  ER_IB_ERR_CORRUPT_TABLESPACE_UNRECOVERABLE, space.first);
      } else if (err != DB_SUCCESS) {
        ut_a_eq(err, DB_FAIL);
        dropped = true;    // 表空间已被 DROP
      }
    }

    for (auto pages : space.second.m_pages) {
      ut_ad(pages.second->space == space.first);

      if (dropped) {
        pages.second->state = RECV_DISCARDED;
        one_less_page_to_recover();
      } else {
        recv_apply_log_rec(pages.second);    // 实际应用
      }

      ++applied;
      // ... 进度报告
    }
  }

  /* 等待所有 page 处理完毕 */
  mutex_exit(&recv_sys->mutex);
  recv_sys->n_pages_to_recover.await_zero();
  mutex_enter(&recv_sys->mutex);

  /* 刷脏页到磁盘，清空 buffer pool */
  buf_flush_await_no_flushing(nullptr, BUF_FLUSH_LRU);
  buf_pool_wait_for_no_pending_io();
  recv_sys->flush_type = BUF_FLUSH_LIST;
  os_event_set(recv_sys->flush_start);
  os_event_wait(recv_sys->flush_end);
  buf_pool_invalidate();

  recv_sys_empty_hash();
  ib::info(ER_IB_MSG_710);
}
```

每个 page 的 redo 应用通过 `recv_apply_log_rec()` 完成：

```cpp
// log0recv.cc:1118
static void recv_apply_log_rec(recv_addr_t *recv_addr) {
  ut_ad(mutex_own(&recv_sys->mutex));
  ut_a(recv_addr->state != RECV_DISCARDED);

  const page_id_t page_id(recv_addr->space, recv_addr->page_no);
  const page_size_t page_size =
      fil_space_get_page_size(recv_addr->space, &found);

  if (recv_addr->state == RECV_NOT_PROCESSED) {
    mutex_exit(&recv_sys->mutex);

    if (buf_page_peek(page_id)) {
      // page 已在 buffer pool → 直接 redo
      mtr_t mtr;
      mtr_start(&mtr);
      buf_block_t *block =
          buf_page_get(page_id, page_size, RW_X_LATCH,
                       UT_LOCATION_HERE, &mtr);
      recv_recover_page(false, block);
      mtr_commit(&mtr);
    } else {
      // page 不在 BP → 读取到 BP 再 redo
      recv_read_in_area(page_id, page_size);
    }

    mutex_enter(&recv_sys->mutex);
  }
}
```

### 1.7 recv_recovery_from_checkpoint_finish() — 恢复完成

等待 recv_writer 线程结束，释放资源，返回 `MetadataRecover`（DDL 元数据恢复信息）。

```cpp
// log0recv.cc:3950
MetadataRecover *recv_recovery_from_checkpoint_finish(bool aborting) {
  mutex_enter(&recv_sys->writer_mutex);

  /* 恢复 dblwr 状态 */
  if (recv_sys->is_meb_db) dblwr::g_mode = recv_sys->dblwr_state;

  recv_recovery_on = false;

  buf_flush_await_no_flushing(nullptr, BUF_FLUSH_LRU);
  mutex_exit(&recv_sys->writer_mutex);

  /* 等待 recv_writer 线程退出 */
  while (recv_writer_is_active()) {
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }

  MetadataRecover *metadata{};
  if (!aborting) {
    std::swap(metadata, recv_sys->metadata_recover);
  }

  recv_sys_free();

  if (!aborting) {
    /* 验证关键系统页面类型 */
    verify_page_type({IBUF_SPACE_ID, FSP_IBUF_HEADER_PAGE_NO},
                     FIL_PAGE_TYPE_SYS);
    verify_page_type({TRX_SYS_SPACE, TRX_SYS_PAGE_NO},
                     FIL_PAGE_TYPE_TRX_SYS);
  }

  return metadata;
}
```

### 1.8 关键辅助函数

**recv_init_crash_recovery()** — 初始化 crash recovery（双写缓冲恢复 + recv_writer 线程）：

```cpp
// log0recv.cc:3744
static void recv_init_crash_recovery() {
  ut_ad(!srv_read_only_mode);
  ut_a(!recv_needed_recovery);

  recv_needed_recovery = true;

  ib::info(ER_IB_MSG_726);
  recv_sys->dblwr->recover();       // 恢复 doublewrite buffer

  if (srv_force_recovery < SRV_FORCE_NO_LOG_REDO) {
    srv_threads.m_recv_writer =
        os_thread_create(recv_writer_thread_key, 0, recv_writer_thread);
    srv_threads.m_recv_writer.start();
  }
}
```

**recv_parse_log_recs()** — 从解析缓冲区中逐个解析 redo record：

```cpp
// log0recv.cc:3135
static void recv_parse_log_recs() {
  ut_ad(recv_sys->parse_start_lsn != 0);

  for (;;) {
    const byte *ptr = recv_sys->buf + recv_sys->recovered_offset;
    const byte *end_ptr = recv_sys->buf + recv_sys->len;

    if (ptr == end_ptr) return;

    bool single_rec;

    switch (*ptr) {
      case MLOG_DUMMY_RECORD:
        single_rec = true;
        break;
      default:
        single_rec = !!(*ptr & MLOG_SINGLE_REC_FLAG);
    }

    if (single_rec) {
      if (recv_single_rec(ptr, end_ptr)) return;
    } else {
      if (recv_multi_rec(ptr, end_ptr)) return;
    }
  }
}
```

**recv_sys_add_to_parsing_buf()** — 将 log block 中的新数据拷贝到解析缓冲区：

```cpp
// log0recv.cc:3177
static bool recv_sys_add_to_parsing_buf(const byte *log_block,
                                        lsn_t scanned_lsn) {
  if (!recv_sys->parse_start_lsn) return false;

  ulint more_len;
  ulint data_len = log_block_get_data_len(log_block);

  if (recv_sys->parse_start_lsn >= scanned_lsn) return false;
  if (recv_sys->scanned_lsn >= scanned_lsn) return false;

  more_len = (ulint)(scanned_lsn - recv_sys->scanned_lsn);
  if (more_len == 0) return false;

  ut_ad(data_len >= more_len);
  ulint start_offset = data_len - more_len;
  if (start_offset < LOG_BLOCK_HDR_SIZE)
      start_offset = LOG_BLOCK_HDR_SIZE;
  ulint end_offset = data_len;
  if (end_offset > OS_FILE_LOG_BLOCK_SIZE - LOG_BLOCK_TRL_SIZE)
      end_offset = OS_FILE_LOG_BLOCK_SIZE - LOG_BLOCK_TRL_SIZE;

  if (start_offset < end_offset) {
    memcpy(recv_sys->buf + recv_sys->len,
           log_block + start_offset,
           end_offset - start_offset);
    recv_sys->len += end_offset - start_offset;
  }
  return true;
}
```

### 1.9 log_t 中的 checkpoint 相关字段

```cpp
// log0sys.h:701
struct alignas(ut::INNODB_CACHE_LINE_SIZE) log_t {
  // ...
  /** Latest checkpoint lsn. Protected by checkpointer_mutex + writer_mutex */
  atomic_lsn_t last_checkpoint_lsn;

  /** Next checkpoint header to use (alternates HEADER_1/HEADER_2) */
  Log_checkpoint_header_no next_checkpoint_header_no;

  /** Event signaled when last_checkpoint_lsn is advanced */
  os_event_t next_checkpoint_event;

  /** Redo log consumer responsible for protecting records >= last_checkpoint */
  Log_checkpoint_consumer m_checkpoint_consumer{*this};

  /** Up to this lsn, data has been written to disk (fsync not required) */
  atomic_lsn_t write_lsn;

  /** Current sn value — number of data bytes reserved in log buffer */
  atomic_sn_t sn;

  /** Recovered LSN after crash recovery */
  lsn_t recovered_lsn;
};
```

### 1.10 os0file.cc — 底层的文件 I/O

持久化层面的文件读写操作：

```cpp
// os0file.cc:4958
[[nodiscard]] static ssize_t os_file_pwrite(
    IORequest &type, os_file_t file,
    const byte *buf, ulint n, os_offset_t offset,
    dberr_t *err, const file::Block *e_block) {
  ++os_n_file_writes;
  os_n_pending_writes.fetch_add(1);

  ssize_t n_bytes = os_file_io(type, file, (void *)buf, n, offset,
                               err, e_block);

  os_n_pending_writes.fetch_sub(1);
  return (n_bytes);
}

// os0file.cc:5046
[[nodiscard]] static ssize_t os_file_pread(
    IORequest &type, os_file_t file,
    void *buf, ulint n, os_offset_t offset, dberr_t *err) {
  ++os_n_file_reads;
  os_n_pending_reads.fetch_add(1);

  ssize_t n_bytes = os_file_io(type, file, buf, n, offset, err, nullptr);

  os_n_pending_reads.fetch_sub(1);
  return (n_bytes);
}
```

```cpp
// os0file.cc:5514
dberr_t os_file_read_func(IORequest &type, const char *file_name,
                          os_file_t file, void *buf,
                          os_offset_t offset, ulint n) {
  ut_ad(type.is_read());
  return os_file_read_page(type, file_name, file, buf, offset,
                           n, nullptr, true);
}
```

---

## 2. mysqldump 逻辑备份

### 2.1 源码入口

mysqldump 的入口在 `main()` 函数（`mysqldump.cc:6645`）。它解析参数后按如下流程执行：

```cpp
// mysqldump.cc:6645
int main(int argc, char **argv) {
  // 1. 解析参数
  exit_code = get_options(&argc, &argv);
  if (exit_code) { free_resources(); exit(exit_code); }

  // 2. 建立连接
  if (connect_to_db(current_host, current_user)) { ... }

  // 3. 可选：FLUSH TABLES WITH READ LOCK
  if (opt_lock_all_tables || opt_source_data || ...) {
    if (do_flush_tables_read_lock(mysql)) goto err;
  }

  // 4. 可选：FLUSH LOGS (binlog 轮转)
  if (opt_lock_all_tables || opt_source_data || ...) {
    if (flush_logs || opt_delete_source_logs) {
      mysql_query(mysql, "FLUSH /*!40101 LOCAL */ LOGS");
    }
  }

  // 5. 启动 single-transaction
  if (opt_single_transaction && start_transaction(mysql)) goto err;

  // 6. 导出所有数据库
  if (opt_alldbs) {
    if (!opt_alltspcs && !opt_notspcs) dump_all_tablespaces();
    dump_all_databases();
  } else {
    // 逐个导出指定数据库
    ...
  }

  // 7. 清理
  ...
}
```

### 2.2 一致性快照：--single-transaction 的原理

`--single-transaction` 使用 `REPEATABLE READ` 隔离级别 + `START TRANSACTION WITH CONSISTENT SNAPSHOT` 获取一致性的 MVCC 快照。

```cpp
// mysqldump.cc:5779
static int start_transaction(MYSQL *mysql_con) {
  verbose_msg("-- Starting transaction...\n");

  if (mysql_get_server_version(mysql_con) < 40100 && opt_source_data) {
    // 旧版本不支持
  }

  return (
      mysql_query_with_error_report(mysql_con, nullptr,
          "SET SESSION TRANSACTION ISOLATION "
          "LEVEL REPEATABLE READ") ||
      mysql_query_with_error_report(mysql_con, nullptr,
          "START TRANSACTION "
          "/*!40100 WITH CONSISTENT SNAPSHOT */"));
}
```

关键点：`WITH CONSISTENT SNAPSHOT` 在 InnoDB 中创建一个 MVCC read view，此后所有读取操作（`SELECT * FROM t`）都看到该时间点的数据，dump 过程中其他事务的 DML 不会被看到。

### 2.3 表结构 + 数据导出流程

`dump_all_databases()` 调用 `dump_all_tables_in_db()` 遍历数据库：

```cpp
// mysqldump.cc:4947
static int dump_all_databases() {
  MYSQL_ROW row;
  MYSQL_RES *tableres;
  int result = 0;

  if (mysql_query_with_error_report(mysql, &tableres, "SHOW DATABASES"))
    return 1;

  while ((row = mysql_fetch_row(tableres))) {
    // 跳过 information_schema, performance_schema, sys
    if (dump_all_tables_in_db(row[0])) result = 1;
  }
  mysql_free_result(tableres);
  return result;
}
```

`dump_all_tables_in_db()` 是单个数据库的核心导出函数：

```cpp
// mysqldump.cc:5153
static int dump_all_tables_in_db(char *database) {
  char *table;
  uint numrows;
  char table_buff[NAME_LEN * 2 + 3];

  // 可选：LOCK TABLES (非 --single-transaction 时)
  if (lock_tables) {
    DYNAMIC_STRING query;
    init_dynamic_string_checked(&query, "LOCK TABLES ", 256);
    for (numrows = 0; (table = getTableName(1));) {
      dynstr_append_checked(&query,
          quote_name(table, table_buff, true));
      dynstr_append_checked(&query, " READ /*!32311 LOCAL */,");
    }
    if (numrows)
      mysql_real_query(mysql, query.str, (ulong)(query.length - 1));
    dynstr_free(&query);
  }

  // 可选：FLUSH LOGS
  if (flush_logs) {
    mysql_query(mysql, "FLUSH /*!40101 LOCAL */ LOGS");
  }

  // single-transaction 下设置 savepoint
  if (opt_single_transaction && mysql_get_server_version(mysql) >= 50500) {
    mysql_query_with_error_report(mysql, nullptr, "SAVEPOINT sp");
  }

  // 循环导出每个表
  while ((table = getTableName(0))) {
    dump_table(table, database);         // 导出表数据

    // 导出触发器
    if (opt_dump_triggers && mysql_get_server_version(mysql) >= 50009) {
      dump_triggers_for_table(table, database);
    }

    // 单事务下回滚到 savepoint，释放元数据锁
    if (opt_single_transaction && mysql_get_server_version(mysql) >= 50500) {
      mysql_query_with_error_report(mysql, nullptr, "ROLLBACK TO sp");
    }
  }
}
```

`dump_table()` 是单表数据导出的核心实现：

```cpp
// mysqldump.cc:4154
static void dump_table(char *table, char *db) {
  char buf[240], table_buff[NAME_LEN + 3];
  DYNAMIC_STRING query_string;
  ulong rownr, row_break;
  uint num_fields;
  MYSQL_RES *res;
  MYSQL_FIELD *field;
  MYSQL_ROW row;

  // Step 1: 获取表结构 (CREATE TABLE)
  num_fields = get_table_structure(table, db, table_type, &ignore_flag,
                                   real_columns, &column_list);

  // Step 2: 跳过 VIEW、跳过 no-data 选项
  if (strcmp(table_type, "VIEW") == 0) return;
  if (opt_no_data) {
    verbose_msg("-- Skipping dump data for table '%s'", table);
    return;
  }

  // Step 3: 使用 SELECT ... INTO OUTFILE (--tab 模式)
  if (path) {
    dynstr_append_checked(&query_string,
        "SELECT /*!40001 SQL_NO_CACHE */ ");
    dynstr_append_checked(&query_string, "*");
    dynstr_append_checked(&query_string, " INTO OUTFILE '");
    dynstr_append_checked(&query_string, filename);
    dynstr_append_checked(&query_string, "'");
    // ... FIELDS TERMINATED BY / LINES TERMINATED BY
    dynstr_append_checked(&query_string, " FROM ");
    dynstr_append_checked(&query_string, result_table);

    mysql_real_query(mysql, query_string.str,
                     (ulong)query_string.length);

  } else {
    // Step 4: 默认模式 — SELECT + 逐行输出 INSERT
    dynstr_append_checked(&query_string,
        "SELECT /*!40001 SQL_NO_CACHE */ ");
    dynstr_append_checked(&query_string, "*");
    dynstr_append_checked(&query_string, " FROM ");
    dynstr_append_checked(&query_string, result_table);

    mysql_query_with_error_report(mysql, nullptr, query_string.str);

    if (quick)
      res = mysql_use_result(mysql);    // 不缓存结果集，逐行读取
    else
      res = mysql_store_result(mysql);  // 一次加载全部结果集

    // 逐行输出 INSERT 语句
    while ((row = mysql_fetch_row(res))) {
      // 构建 INSERT INTO ... VALUES (...)
      fprintf(md_result_file, "INSERT INTO %s VALUES (", opt_quoted_table);
      for (j = 0; j < num_fields; j++) {
        if (row[j] == nullptr) {
          fputs("NULL", md_result_file);
        } else {
          // 转义并输出值
          ...
        }
      }
      fputs(");\n", md_result_file);
    }
  }
}
```

`get_table_structure()` 负责输出 CREATE TABLE、列统计、分区信息等：

```cpp
// mysqldump.cc:3149
static uint get_table_structure(const char *table, char *db,
                                char *table_type, char *ignore_flag,
                                bool *real_columns,
                                std::string *column_list) {
  // SHOW CREATE TABLE
  if (mysql_query_with_error_report(mysql, &show_create_res,
        "SHOW CREATE TABLE ...")) { ... }

  // 输出 DROP TABLE IF EXISTS
  if (opt_drop_table)
    fprintf(sql_file, "/*!40000 DROP TABLE IF EXISTS %s*/;\n", ...);

  // 输出 CREATE TABLE
  fprintf(sql_file, "%s;\n", create_str);

  // 可选：SHOW COLUMNS 获取列信息
  if (opt_complete_insert || opt_columns || ...) {
    // 构建列名列表
  }

  // 分区信息 (SHOW CREATE TABLE 已包含)
  // ...
  return num_fields;
}
```

### 2.4 dump_all_databases 的执行路径

```cpp
// mysqldump.cc:4947 （完整函数已贴于 2.3）
```

`dump_all_databases` → `dump_all_tables_in_db` → `dump_table` → `get_table_structure` + `SELECT` + row iteration。

如果指定了 `--all-databases`，还会在最后 dump views：

```cpp
// mysqldump.cc:4997
if (seen_views) {
  if (mysql_query(mysql, "SHOW DATABASES") || !(tableres = mysql_store_result(mysql))) { ... }
  while ((row = mysql_fetch_row(tableres))) {
    if (dump_all_views_in_db(row[0])) result = 1;
  }
  mysql_free_result(tableres);
}
```

---

## 3. XtraBackup 物理备份原理

虽然 XtraBackup 是独立的 Percona 工具，但其核心原理直接依赖于 InnoDB 的 redo log 机制：

### 3.1 redo log 复制

XtraBackup 启动时记录当前 LSN，然后在后台启动 redo log 复制线程（`log0recv.cc:97` 中的 `recv_sys` 全局变量在 XtraBackup 环境下也会使用）。它持续读取最新的 redo log block，保存到 `xtrabackup_logfile`。

在 InnoDB 源码层面，XtraBackup 使用 `meb_scan_log_seg()` 函数扫描 redo log：

```cpp
// log0recv.cc:1373
void meb_scan_log_seg(byte *buf, size_t buf_len,
                      lsn_t *scanned_lsn,
                      uint32_t *scanned_epoch_no,
                      uint32_t *block_no,
                      size_t *n_bytes_scanned,
                      bool *has_encrypted_log) {
  *n_bytes_scanned = 0;
  *has_encrypted_log = false;

  for (auto log_block = buf; log_block < buf + buf_len;
       log_block += OS_FILE_LOG_BLOCK_SIZE) {
    Log_data_block_header block_header;
    log_data_block_header_deserialize(log_block, block_header);
    uint32_t no = block_header.m_hdr_no;

    bool is_encrypted = log_block_get_encrypt_bit(log_block);
    if (is_encrypted) { *has_encrypted_log = true; return; }

    if (no != log_block_convert_lsn_to_hdr_no(*scanned_lsn) ||
        !log_block_checksum_is_ok(log_block)) {
      // 不完整或损坏的 block
      log_block += OS_FILE_LOG_BLOCK_SIZE;
      break;
    }

    const auto data_len = block_header.m_data_len;
    *scanned_epoch_no = block_header.m_epoch_no;
    *scanned_lsn += data_len;
    *n_bytes_scanned += OS_FILE_LOG_BLOCK_SIZE;
  }
}
```

### 3.2 备份期间的 LSN 追踪

XtraBackup 的数据拷贝阶段使用 `recv_sys->checkpoint_lsn` 和 `recv_sys->scanned_lsn` 跟踪：

```cpp
// log0recv.cc:97
recv_sys_t *recv_sys = nullptr;

// log0recv.cc:154
/** true when recv_init_crash_recovery() has been called. */
bool recv_needed_recovery;

// log0recv.cc:159
/** true if buf_page_is_corrupted() should check if the log sequence
    number (FIL_PAGE_LSN) is in the future. */
bool recv_lsn_checks_on;
```

XtraBackup 完成数据文件拷贝后，停止 redo log 复制，此时 `xtrabackup_logfile` 中包含了从备份启动到结束期间所有的 redo log 记录。

### 3.3 prepare 阶段：应用 redo log

`--prepare` 阶段的核心是 `meb_scan_log_recs()`（即 `recv_scan_log_recs` 的 MEB 版本）：

```cpp
// log0recv.cc:3289 (条件编译 UNIV_HOTBACKUP)
#ifdef UNIV_HOTBACKUP
bool meb_scan_log_recs(
#else  /* !UNIV_HOTBACKUP */
static bool recv_scan_log_recs(
#endif /* !UNIV_HOTBACKUP */
    log_t &log, size_t max_memory, const byte *buf, size_t len,
    lsn_t start_lsn, lsn_t *read_upto_lsn) {
  // ... 与 recv_scan_log_recs 相同的逻辑
  // 扫描 redo log block，解析并记录到哈希表
}
```

prepare 阶段调用 `recv_apply_hashed_log_recs()` 将 redo 应用到 ibd 文件：

```cpp
// log0recv.cc:1173 (条件编译)
#ifndef UNIV_HOTBACKUP
void recv_apply_hashed_log_recs(log_t &log) {
#else  /* !UNIV_HOTBACKUP */
void meb_apply_hashed_log_recs() {
  // 相同的核心逻辑
#endif /* !UNIV_HOTBACKUP */
```

之后调用 `recv_recovery_from_checkpoint_finish()` 清理恢复资源。

---

## 4. PITR (Point-In-Time Recovery)

### 4.1 binlog 在恢复中的作用

PITR 的核心是 **full backup + binlog apply**。binlog 包含所有已提交事务的变更，恢复时从备份的 binlog 位置开始，重放到目标时间点。

binlog 结构的核心类是 `MYSQL_BIN_LOG`：

```cpp
// binlog.h:107
class MYSQL_BIN_LOG : public TC_LOG {
public:
  MYSQL_BIN_LOG(uint64 *sync_period);
  virtual ~MYSQL_BIN_LOG();

  bool open(const char *log_name, ...);
  int flush_and_sync(bool async);
  bool write(THD *thd, bool clear_damaged);
  // ...
};
```

全局 binlog 实例：

```cpp
// binlog.cc:190
MYSQL_BIN_LOG mysql_bin_log(&sync_binlog_period);
```

### 4.2 服务器启动时的 binlog 恢复

MySQL 启动时，`MYSQL_BIN_LOG::open_binlog()` 检查最后一个 binlog 文件是否正常关闭：

```cpp
// binlog.cc:6881
int MYSQL_BIN_LOG::open_binlog(const char *opt_name) {
  Log_info log_info;
  int error = 1;

  // 启发式恢复模式
  if (using_heuristic_recover()) {
    open_binlog(opt_name, nullptr, max_binlog_size, false,
                true, true, nullptr);
    cleanup();
    return 1;
  }

  // 找到 binlog 索引中的最后一个文件
  if ((error = find_log_pos(&log_info, NullS, true))) { ... }

  do {
    strmake(log_name, log_info.log_file_name, sizeof(log_name) - 1);
  } while (!(error = find_next_log(&log_info, true)));

  // 打开最后一个 binlog 文件
  Binlog_file_reader binlog_file_reader(opt_source_verify_checksum);
  if (binlog_file_reader.open(log_name)) { ... }

  // 检查 binlog 是否标记为 in-use（非正常关闭 = crash）
  if (!read_binlog_in_use_flag(binlog_file_reader)) {
    // 正常关闭：只需执行 ha_recover
    error = ha_recover();
    return error;
  }

  // 非正常关闭：执行 Binlog_recovery
  binlog::Binlog_recovery bl_recovery{binlog_file_reader};
  bl_recovery.recover();

  my_off_t valid_pos = bl_recovery.get_valid_pos();

  if (bl_recovery.is_binlog_malformed()) { ... return 1; }

  // 截断到最后一个有效事务
  if (valid_pos > 0) {
    truncate_update_log_file(log_name, valid_pos, binlog_size, true);
  }

  return 0;
}
```

`Binlog_recovery` 类收集所有已写入 binlog 的事务 XID，将其传递给存储引擎的 `ha_recover()`：

```cpp
// binlog/recovery.h:40
class Binlog_recovery : public Log_sanitizer {
 public:
  Binlog_recovery(Binlog_file_reader &binlog_file_reader);
  ~Binlog_recovery() override = default;

  /** 执行恢复：收集 XID，协调 2PC */
  void recover();

  /** 返回最后一个有效位置 */
  my_off_t get_valid_pos() const;

  /** binlog 是否损坏 */
  bool is_binlog_malformed() const;

  /** 引擎恢复是否失败 */
  bool has_engine_recovery_failed() const;
};
```

### 4.3 mysqlbinlog 工具源码路径

`mysqlbinlog` 客户端读取 binlog 文件并输出 SQL 事件。其入口在 `client/mysqlbinlog.cc`。

核心循环：`dump_local_log_entries()` 逐事件读取并输出：

```cpp
// mysqlbinlog.cc:3046
static Exit_status dump_local_log_entries(
    PRINT_EVENT_INFO *print_event_info, const char *logname) {

  Mysqlbinlog_file_reader mysqlbinlog_file_reader(
      opt_verify_binlog_checksum, max_event_size);

  // 打开 binlog 文件
  Format_description_log_event *fdle = nullptr;
  if (mysqlbinlog_file_reader.open(logname, start_position, &fdle)) {
    error("%s", mysqlbinlog_file_reader.get_error_str());
    return ERROR_STOP;
  }

  // 处理第一个 Format_description_log_event
  if (fdle != nullptr) {
    process_event(print_event_info, fdle,
                  mysqlbinlog_file_reader.event_start_pos(), logname);
  }

  for (;;) {
    Log_event *ev = mysqlbinlog_file_reader.read_event_object();
    if (ev == nullptr) {
      auto error_type = mysqlbinlog_file_reader.get_error_type();
      if (error_type == Binlog_read_error::READ_EOF)
        return OK_CONTINUE;
      // ...
    }

    // 处理事件（执行过滤、转换、输出）
    Exit_status ret = process_event(print_event_info, ev, ...);
    if (ret != OK_CONTINUE) return ret;
  }
}
```

`process_event()` 根据事件类型输出对应的 SQL 或控制命令。对于 `QUERY_EVENT`（BEGIN/COMMIT/DDL）：

```cpp
// mysqlbinlog.cc:1488
fprintf(result_file, "COMMIT /* added by mysqlbinlog */%s\n",
        print_event_info->delimiter);
```

对于 `ROTATE_EVENT`（binlog 轮转），支持 `--to-last-log` 自动切换：

```cpp
// mysqlbinlog.cc:2807
// next binlog file (fake rotate) picked by mysqlbinlog --to-last-log
```

PITR 完整流程的伪代码：

```
1. 恢复完整备份
   → MySQL 启动时自动执行 crash recovery（redo log 重做）

2. 确定需要重放的 binlog 区间
   binlog_position = backup_position  (FLUSH LOGS 记录的位置)
   target_time    = '2024-01-15 10:30:00'

3. 使用 mysqlbinlog 提取并重放
   mysqlbinlog --start-position=<pos> --stop-datetime=<target> \
     binlog.000001 binlog.000002 ... | mysql -u root
```

### 4.4 binlog 写入与 2PC

MySQL 的 binlog 使用两阶段提交（2PC）与 InnoDB 保持一致性：

```cpp
// binlog.cc:182
bool opt_binlog_order_commits = true;

// binlog.cc:1482
binlog_hton->commit = binlog_commit;

// binlog.cc:1486
binlog_hton->recover = binlog_dummy_recover;
```

`binlog_dummy_recover` 是一个空恢复函数——实际恢复由 `ha_recover()` 和 `Binlog_recovery` 完成：

```cpp
// binlog.cc:1346
static int binlog_dummy_recover(handlerton *, XA_recover_txn *, uint) {
  return 0;
}
```

事务写入 binlog 的核心逻辑在 `MYSQL_BIN_LOG::write_transaction()`：

```cpp
// binlog.cc:1636
bool MYSQL_BIN_LOG::write_transaction(THD *thd,
                                      binlog_cache_data *cache_data,
                                      ...) {
  int64 sequence_number, last_committed;

  // 计算组提交的 sequence_number 和 last_committed
  thd->get_transaction()->last_committed = SEQ_UNINIT;

  // 记录提交时间戳
  ulonglong immediate_commit_timestamp = my_micro_time();

  // 写入 binlog cache 到文件
  int error = cache_data->write(thd, this, &bytes_written);
  if (unlikely(error)) return true;

  // flush + sync (由组提交协调)
  ...
}
```

`write_event()` 将单个事件写入 binlog 文件：

```cpp
// binlog.cc:666
int MYSQL_BIN_LOG::write_event(Log_event *event) {
  DBUG_TRACE;
  // 序列化 event 到 binlog ofile
  return m_binlog_file.write(event);
}
```

---

## 5. 关键函数索引

| 函数 | 文件 | 行号 | 作用 |
|------|------|------|------|
| `recv_recovery_from_checkpoint_start()` | `log0recv.cc` | 3766 | crash recovery 入口 |
| `recv_find_max_checkpoint()` | `log0recv.cc` | 933/973 | 在 redo log 文件中扫描最新 checkpoint |
| `recv_scan_log_recs()` | `log0recv.cc` | 3289 | 逐 block 扫描 redo log |
| `recv_parse_log_recs()` | `log0recv.cc` | 3135 | 解析 redo log 记录 |
| `recv_apply_hashed_log_recs()` | `log0recv.cc` | 1173 | 将缓存的 redo 记录应用到 page |
| `recv_apply_log_rec()` | `log0recv.cc` | 1118 | 单 page 的 redo 应用 |
| `recv_recovery_from_checkpoint_finish()` | `log0recv.cc` | 3950 | 恢复完成，释放资源 |
| `recv_init_crash_recovery()` | `log0recv.cc` | 3744 | 初始化 crash recovery |
| `recv_sys_create()` | `log0recv.cc` | 308 | 创建 recv_sys |
| `recv_sys_add_to_parsing_buf()` | `log0recv.cc` | 3177 | 将 log block 数据加入解析缓冲区 |
| `recv_sys_empty_hash()` | `log0recv.cc` | 579 | 清空已应用 redo 的哈希表 |
| `recv_sys_resize_buf()` | `log0recv.cc` | 340 | 扩展解析缓冲区 |
| `meb_scan_log_seg()` | `log0recv.cc` | 1373 | XtraBackup redo 扫描 |
| `log_t` (struct) | `log0sys.h` | 126 | 全局 redo log 系统结构体 |
| `last_checkpoint_lsn` | `log0sys.h` | 701 | log_t 中的 checkpoint LSN 字段 |
| `recv_sys_t` (struct) | `log0recv.h` | 375 | 恢复系统状态结构体 |
| `srv_start()` | `srv0start.cc` | 1330 | InnoDB 启动入口 |
| `os_file_pwrite()` | `os0file.cc` | 4958 | 同步定长写 |
| `os_file_pread()` | `os0file.cc` | 5046 | 同步定长读 |
| `os_file_read_func()` | `os0file.cc` | 5514 | 文件读函数 |
| `os_file_write_func()` | `os0file.cc` | 5679 | 文件写函数 |
| `main()` (mysqldump) | `mysqldump.cc` | 6645 | mysqldump 主函数 |
| `start_transaction()` | `mysqldump.cc` | 5779 | 启动 --single-transaction 一致性快照 |
| `dump_all_databases()` | `mysqldump.cc` | 4947 | 导出所有数据库 |
| `dump_all_tables_in_db()` | `mysqldump.cc` | 5153 | 导出单个数据库 |
| `dump_table()` | `mysqldump.cc` | 4154 | 导出单表数据 |
| `get_table_structure()` | `mysqldump.cc` | 3149 | 导出表结构 (CREATE TABLE) |
| `MYSQL_BIN_LOG::open_binlog()` | `binlog.cc` | 6881 | 打开并恢复 binlog |
| `MYSQL_BIN_LOG::write_transaction()` | `binlog.cc` | 1636 | 事务写入 binlog |
| `MYSQL_BIN_LOG::write_event()` | `binlog.cc` | 666 | 单事件写入 binlog |
| `Binlog_recovery::recover()` | `binlog/recovery.cc` | — | binlog crash 恢复 |
| `binlog_dummy_recover()` | `binlog.cc` | 1346 | binlog hton 空恢复 |
| `dump_local_log_entries()` | `mysqlbinlog.cc` | 3046 | mysqlbinlog 事件读取循环 |
| `end_binlog()` | `mysqlbinlog.cc` | 1217 | mysqlbinlog 关闭逻辑 |

---

## 总结

MySQL 的备份与恢复体系以 InnoDB 的 **redo log** 和 MySQL Server 层的 **binlog** 为两大支柱。

**Crash Recovery**（`log0recv.cc`）是全自动的：`srv_start()` → 查找最新 checkpoint → 从 checkpoint LSN 扫描 redo log → 解析 → 批量应用到数据页 → 释放恢复资源。这一过程对用户完全透明。

**mysqldump** 作为逻辑备份工具，通过 `--single-transaction` 的 REPEATABLE READ + MVCC 快照实现一致性，源码中的 `dump_all_databases()` → `dump_all_tables_in_db()` → `dump_table()` 调用链清晰地展示了从 SHOW DATABASES 到逐行输出 INSERT 的完整流程。

**PITR** 依赖 binlog 的持久性和 `mysqlbinlog` 的事件重放能力。binlog 使用两阶段提交与 InnoDB 协调，`Binlog_recovery` 类在服务器启动时自动修复崩溃的 binlog 文件。

三者构成了 MySQL 从崩溃中自动恢复、以全量备份为基础、以 binlog 实现任意时间点恢复的完整保障体系。
