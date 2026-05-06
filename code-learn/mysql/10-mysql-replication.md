# 10-mysql-replication — MySQL 复制：Binlog 与 Group Commit

## 0. 概述

MySQL 的复制（Replication）是整个高可用体系（主从同步、PITR、读写分离、灾备）的基石。其核心机制围绕三个关键组件展开：

1. **Binlog（二进制日志）** — 记录所有数据变更的持久化日志
2. **复制线程** — 主库 Dump Thread → 从库 I/O Thread → 从库 SQL Thread
3. **Group Commit** — 将多个事务的 binlog 写入吞吐合并，大幅提升性能

Binlog 格式经历了 STATEMENT → ROW → MIXED 的演进，当前推荐使用 ROW 格式。从 5.6 开始引入 GTID 和 MTS（多线程复制），5.7 引入逻辑时钟并行复制，8.0 持续优化并行度。

本文基于 MySQL 8.4 源码（`~/code/mysql/sql/`）全面分析 binlog 的写入路径、group commit 的三阶段设计、主从复制的线程架构以及崩溃安全机制。

---

## 1. Binlog 核心结构

### 1.1 文件格式

Binlog 文件的物理格式非常规整：

```
+-------------------+------------------+
| Magic Number      |  4 bytes         |
| (0xfe62696e)      |                  |
+-------------------+------------------+
| Format Description|  可变长度        |
| Event             |                  |
+-------------------+------------------+
| Event 1           |  可变长度        |
+-------------------+------------------+
| ...               |                  |
+-------------------+------------------+
| Rotate Event      |  可选            |
+-------------------+------------------+
```

Magic Number 定义在头文件中：

```c
// log_event.h:240
/* 4 bytes which all binlogs should begin with */
#define BINLOG_MAGIC "\xfe\x62\x69\x6e"
#define BINLOG_MAGIC_SIZE 4
```

每个事件的通用头（common header）结构如下：

```c
// log_event.h:615-626
/**
    This has the following form:

    +---------+---------+---------+------------+-----------+-------+
    |timestamp|type code|server_id|event_length|end_log_pos|flags  |
    |4 bytes  |1 byte   |4 bytes  |4 bytes     |4 bytes    |2 bytes|
    +---------+---------+---------+------------+-----------+-------+

    @param buf Memory buffer to write to. This must be at least
    LOG_EVENT_HEADER_LEN bytes long.
*/
uint32 write_header_to_memory(uchar *buf);
```

### 1.2 Format_description_event

Binlog 文件的第二个事件是 `Format_description_log_event`（FD）。它包含 binlog 版本号、服务器版本、各事件类型的 post-header 长度数组等信息，是解析后续所有事件的元数据。

```c
// log_event.h:1531
class Format_description_log_event
    : public mysql::binlog::event::Format_description_event,
      public Log_event {
 public:
  std::atomic<int32> atomic_usage_counter{0};

  Format_description_log_event();
  Format_description_log_event(
      const char *buf,
      const mysql::binlog::event::Format_description_event *description_event);
  bool write(Basic_ostream *ostream) override;

  size_t get_data_size() override {
    return mysql::binlog::event::Binary_log_event::
        FORMAT_DESCRIPTION_HEADER_LEN;
  }
```

FD 的 `get_data_size()` 返回固定值 `FORMAT_DESCRIPTION_HEADER_LEN`。注意 `atomic_usage_counter` — 在 MTS（多线程复制）环境中，SQL 线程和 Worker 线程共享 FD 事件，通过引用计数管理生命周期。

### 1.3 Query_event

`Query_log_event` 记录 STATEMENT 格式的 SQL 或特殊事件（如 `BEGIN`、`COMMIT`、DDL）。

```c
// log_event.h:1292
class Query_log_event : public virtual mysql::binlog::event::Query_event,
                        public Log_event {
 protected:
  mysql::binlog::event::Log_event_header::Byte *data_buf;

 public:
  my_thread_id slave_proxy_id;
  bool has_ddl_committed;

  Query_log_event(THD *thd_arg, const char *query_arg, size_t query_length,
                  bool using_trans, bool immediate, bool suppress_use,
                  int error, bool ignore_command = false);

  uint8 get_mts_dbs(Mts_db_names *arg, Rpl_filter *rpl_filter) override {
    if (mts_accessed_dbs == OVER_MAX_DBS_IN_EVENT_MTS) {
      mts_accessed_db_names[0][0] = 0;
    } else {
      for (uchar i = 0; i < mts_accessed_dbs; i++) {
        const char *db_name = mts_accessed_db_names[i];
        if (!rpl_filter->is_rewrite_empty() && !strcmp(get_db(), db_name)) {
          size_t dummy_len;
          const char *db_filtered =
              rpl_filter->get_rewrite_db(db_name, &dummy_len);
          if (strcmp(db_name, db_filtered)) db_name = db_filtered;
        }
        arg->name[i] = db_name;
      }
    }
    return arg->num = mts_accessed_dbs;
  }
```

`get_mts_dbs()` 返回该查询访问的数据库列表。这是 MTS 并行度计算的关键 — 如果两个事务访问不同的数据库，它们可以被并行执行。

### 1.4 Rows_event

`Rows_log_event` 是 ROW 格式复制的核心，记录了行级别的增删改。它是个抽象基类，由三个子类实现具体操作：

```c
// log_event.h:2759-2781
/**
 Common base class for all row-containing log events.

        Binary_log_event
               ^
               |
               |
         Rows_event  Log_event
                \       /
          <<vir>>\     /
                  \   /
              Rows_log_event
*/
class Rows_log_event : public virtual mysql::binlog::event::Rows_event,
                       public Log_event {
 public:
  typedef uint16 flag_set;

  enum row_lookup_mode {
    ROW_LOOKUP_UNDEFINED = 0,
    ROW_LOOKUP_NOT_NEEDED = 1,
    ROW_LOOKUP_INDEX_SCAN = 2,
    ROW_LOOKUP_TABLE_SCAN = 3,
    ROW_LOOKUP_HASH_SCAN = 4
  };

  enum enum_error {
    ERR_OPEN_FAILURE = -1,
    ERR_OK = 0,
    ERR_TABLE_LIMIT_EXCEEDED = 1,
    ERR_OUT_OF_MEM = 2,
    ERR_BAD_TABLE_DEF = 3,
    ERR_RBR_TO_SBR = 4
  };

  void set_flags(flag_set flags_arg) { m_flags |= flags_arg; }
  void clear_flags(flag_set flags_arg) { m_flags &= ~flags_arg; }
  flag_set get_flags(flag_set flags_arg) const { return m_flags & flags_arg; }
```

三个子类：

```c
// log_event.h:3325
class Write_rows_log_event : public Rows_log_event,
                             public Write_event { /* ... */ };

// log_event.h:3414
class Update_rows_log_event : public Rows_log_event,
                              public Update_event { /* ... */ };

// log_event.h:3534
class Delete_rows_log_event : public Rows_log_event,
                              public Delete_event { /* ... */ };
```

### 1.5 Xid_event & Rotate_event

`Xid_log_event` 标记事务的结束，记录 XID 用于两阶段提交：

```c
// log_event.h:1777
class Xid_log_event : public mysql::binlog::event::Xid_event,
                      public Xid_apply_log_event {
 public:
  Xid_log_event(THD *thd_arg, my_xid x)
      : mysql::binlog::event::Xid_event(x),
        Xid_apply_log_event(thd_arg, header(), footer()) {
    common_header->set_is_valid(true);
  }

  size_t get_data_size() override { return sizeof(xid); }
  bool write(Basic_ostream *ostream) override;
```

`Rotate_log_event` 记录 binlog 文件的切换：

```c
// log_event.h:2034
class Rotate_log_event : public mysql::binlog::event::Rotate_event,
                         public Log_event {
 public:
  Rotate_log_event(const char *new_log_ident_arg, size_t ident_len_arg,
                   ulonglong pos_arg, uint flags);

  size_t get_data_size() override {
    return ident_len +
           mysql::binlog::event::Binary_log_event::ROTATE_HEADER_LEN;
  }
```

---

## 2. Binlog 写入路径

### 2.1 MYSQL_BIN_LOG 类

写入 binlog 的核心类是 `MYSQL_BIN_LOG`，它继承自 `TC_LOG`：

```c
// binlog.h:107
class MYSQL_BIN_LOG : public TC_LOG {
 public:
  class Binlog_ofile;

 private:
  enum enum_log_state { LOG_OPENED, LOG_CLOSED, LOG_TO_BE_OPENED };

  mysql_mutex_t LOCK_log;
  char *name;
  char log_file_name[FN_REFLEN];
  Binlog_ofile *m_binlog_file;

  std::atomic<my_off_t> atomic_binlog_end_pos;
  ulonglong bytes_written;

  Binlog_index_monitor m_binlog_index_monitor;
  ulong max_size;

  uint *sync_period_ptr;
  uint sync_counter;
```

这个类管理着 binlog 文件的生命周期、文件写入、同步、索引以及 group commit 的所有状态。关键互斥锁包括：
- `LOCK_log` — 保护 binlog 文件写入
- `LOCK_sync` — 保护 fsync 阶段
- `LOCK_commit` — 保护存储引擎提交流程
- `LOCK_after_commit` — 保护 after_commit 钩子

### 2.2 binlog_commit() — 写入入口

当 `ha_commit_trans()` 最终调用 `TC_LOG::commit()` 时，进入 `MYSQL_BIN_LOG::commit()`：

```c
// binlog.cc:7107
TC_LOG::enum_result MYSQL_BIN_LOG::commit(THD *thd, bool all) {
  DBUG_TRACE;
  Transaction_ctx *trn_ctx = thd->get_transaction();
  my_xid xid = trn_ctx->xid_state()->get_xid()->get_my_xid();
  bool stmt_stuff_logged = false;
  bool trx_stuff_logged = false;
  bool skip_commit = is_loggable_xa_prepare(thd);

  binlog_cache_mngr *cache_mngr = thd_get_cache_mngr(thd);

  if (is_current_stmt_binlog_enabled_and_caches_empty(thd)) {
    thd->enable_low_level_commit_ordering();
  }

  if (cache_mngr == nullptr) {
    if (!skip_commit && trx_coordinator::commit_in_engines(thd, all))
      return RESULT_ABORTED;
    return RESULT_SUCCESS;
  }

  if (!cache_mngr->stmt_cache.is_binlog_empty()) {
    trn_ctx->store_commit_parent(
        m_dependency_tracker.get_max_committed_timestamp());
    if (cache_mngr->stmt_cache.finalize(thd)) return RESULT_ABORTED;
    stmt_stuff_logged = true;
  }
```

`commit()` 的核心职责：
1. 从 `binlog_cache_mngr` 获取事务和语句的缓存
2. 关闭缓存（`finalize`）
3. 如果事务为空，直接 `commit_in_engines` 跳过 binlog
4. 最终调用 `ordered_commit()` 进入 group commit

静态注册函数是将 `binlog_commit` 挂载到 `handlerton` 上的：

```c
// binlog.cc:2606
static int binlog_commit(handlerton *, THD *, bool) {
  DBUG_TRACE;
  /*
    Nothing to do (any more) on commit.
   */
  return 0;
}
```

这个函数本身是空操作 — 真正的提交逻辑在 `ordered_commit()` 中完成。

### 2.3 write_transaction() — 写入 GTID 和事件数据

在进入 group commit 之前，每个线程的 binlog 缓存数据已经准备好了。`write_transaction()` 负责将 GTID 头 + 实际事务数据写入写入器：

```c
// binlog.cc:1636
bool MYSQL_BIN_LOG::write_transaction(THD *thd, binlog_cache_data *cache_data,
                                      Binlog_event_writer *writer,
                                      bool parallelization_barrier) {
  DBUG_TRACE;

  int64 sequence_number, last_committed;
  /* Generate logical timestamps for MTS */
  m_dependency_tracker.get_dependency(thd, parallelization_barrier,
                                      sequence_number, last_committed);

  thd->get_transaction()->last_committed = SEQ_UNINIT;

  ulonglong immediate_commit_timestamp = my_micro_time();
  ulonglong original_commit_timestamp =
      thd->variables.original_commit_timestamp;

  if (original_commit_timestamp == UNDEFINED_COMMIT_TIMESTAMP) {
    if (thd->slave_thread || thd->is_binlog_applier()) {
      original_commit_timestamp = 0;
    } else {
      original_commit_timestamp = immediate_commit_timestamp;
    }
  }

  Gtid_log_event gtid_event(
      thd, cache_data->is_trx_cache(), last_committed, sequence_number,
      cache_data->may_have_sbr_stmts(), original_commit_timestamp,
      immediate_commit_timestamp, trx_original_server_version,
      trx_immediate_server_version);

  // Set the transaction length, based on cache info
  gtid_event.set_trx_length_by_cache_size(cache_data->get_byte_position(),
                                          writer->is_checksum_enabled(),
                                          cache_data->get_event_counter());

  bool ret = gtid_event.write(writer);
  if (ret) goto end;

  /* Write the transaction data */
  ret = mysql_bin_log.write_cache(thd, cache_data, writer);
```

这里涉及几个关键操作：
- `m_dependency_tracker.get_dependency()` — 为逻辑时钟（Logical Clock）生成 `sequence_number` 和 `last_committed`
- `Gtid_log_event` 携带 GTID、时间戳、依赖信息
- `write_cache()` 将实际的事务数据（BEGIN、Rows、XID 等事件）写入文件

### 2.4 write_cache() — 将缓存刷到文件

```c
// binlog.cc:6657
bool MYSQL_BIN_LOG::write_cache(THD *thd, binlog_cache_data *cache_data,
                                Binlog_event_writer *writer) {
  DBUG_TRACE;

  Binlog_cache_storage *const cache = cache_data->get_cache();
  mysql_mutex_assert_owner(&LOCK_log);
  assert(is_open());

  if (likely(is_open())) {
    if (!cache->is_empty()) {
      if (do_write_cache(cache, writer)) goto err;
    }
    update_thd_next_event_pos(thd);
  }
  return false;

err:
  thd->commit_error = THD::CE_FLUSH_ERROR;
  return true;
}
```

`do_write_cache()` 将 `IO_CACHE` 中的事件数据直接拷贝到 binlog 文件流中。此处通过 `LOCK_log` 保证写操作的互斥。

---

## 3. Group Commit（binlog_group_commit）

Group Commit 是 MySQL binlog 写入性能的核心优化。它将多个并发提交的事务合并成一批处理，减少 fsync 调用的次数。

### 3.1 三阶段架构

`ordered_commit()` 是 group commit 的总控函数，分为三个阶段：

```c
// binlog.cc:7886
int MYSQL_BIN_LOG::ordered_commit(THD *thd, bool all, bool skip_commit) {
  DBUG_TRACE;
  int flush_error = 0, sync_error = 0;
  my_off_t total_bytes = 0;

  thd->rpl_thd_ctx.binlog_group_commit_ctx().assign_ticket();

  init_thd_variables(thd, all, skip_commit);

  /*
    Stage #0: ensure slave threads commit order
  */
  if (Commit_order_manager::wait_for_its_turn_before_flush_stage(thd) ||
      ending_trans(thd, all) ||
      Commit_order_manager::get_rollback_status(thd)) {
    if (Commit_order_manager::wait(thd)) {
      return thd->commit_error;
    }
  }

  /*
    Stage #1: flushing transactions to binary log
  */
  if (change_stage(thd, Commit_stage_manager::BINLOG_FLUSH_STAGE, thd, nullptr,
                   &LOCK_log)) {
    return finish_commit(thd);
  }

  THD *wait_queue = nullptr, *final_queue = nullptr;
  ...
  flush_error = process_flush_stage_queue(&total_bytes, &wait_queue);

  if (flush_error == 0 && total_bytes > 0)
    flush_error = flush_cache_to_file(&flush_end_pos);
```

**Stage 0 — Commit Order（只对 MTS 副本）：** 保证并行复制的 Worker 线程按 relay log 中的顺序进入 group commit。

**Stage 1 — FLUSH：** 将本批所有线程的 binlog 缓存写入 binlog 文件的 page cache。Leader 线程处理整个队列：

```c
// binlog.cc:7502
THD *MYSQL_BIN_LOG::fetch_and_process_flush_stage_queue(
    const bool check_and_skip_flush_logs) {
  Commit_stage_manager::get_instance().lock_queue(
      Commit_stage_manager::BINLOG_FLUSH_STAGE);

  THD *first_seen =
      Commit_stage_manager::get_instance().fetch_queue_skip_acquire_lock(
          Commit_stage_manager::BINLOG_FLUSH_STAGE);

  THD *commit_order_thd =
      Commit_stage_manager::get_instance().fetch_queue_skip_acquire_lock(
          Commit_stage_manager::COMMIT_ORDER_FLUSH_STAGE);

  Commit_stage_manager::get_instance().unlock_queue(
      Commit_stage_manager::BINLOG_FLUSH_STAGE);

  if (!check_and_skip_flush_logs ||
      (check_and_skip_flush_logs && commit_order_thd != nullptr)) {
    ha_flush_logs(true);
  }

  Commit_stage_manager::get_instance()
      .process_final_stage_for_ordered_commit_group(commit_order_thd);
  return first_seen;
}
```

`ha_flush_logs(true)` 确保 InnoDB 的 redo log 中所有事务的 prepare 记录已经刷盘 — 这是 binlog 与 InnoDB 两阶段提交的关键步骤。

`process_flush_stage_queue()` 遍历 flush 队列中的每个 THD，依次调用 `flush_thread_caches()` 将其缓存写入 binlog：

```c
// binlog.cc:7502 (continued)
int MYSQL_BIN_LOG::process_flush_stage_queue(my_off_t *total_bytes_var,
                                             THD **out_queue_var) {
  THD *first_seen = fetch_and_process_flush_stage_queue();
  assign_automatic_gtids_to_flush_group(first_seen);

  for (THD *head = first_seen; head; head = head->next_to_commit) {
    Thd_backup_and_restore switch_thd(current_thd, head);
    const auto [error, flushed_bytes] = flush_thread_caches(head);
    total_bytes += flushed_bytes;
    if (flush_error == 1) flush_error = error;
  }

  *out_queue_var = first_seen;
  *total_bytes_var = total_bytes;
  return flush_error;
}
```

**Stage 2 — SYNC：** 执行 `fsync()` 将 binlog 文件刷到磁盘：

```c
// binlog.cc:8006
  if (change_stage(thd, Commit_stage_manager::SYNC_STAGE, wait_queue, &LOCK_log,
                   &LOCK_sync)) {
    return finish_commit(thd);
  }

  /*
    Wait for delay before sync if configured
  */
  if (!flush_error && (sync_counter + 1 >= get_sync_period()))
    Commit_stage_manager::get_instance().wait_count_or_timeout(
        opt_binlog_group_commit_sync_no_delay_count,
        opt_binlog_group_commit_sync_delay, Commit_stage_manager::SYNC_STAGE);

  final_queue = Commit_stage_manager::get_instance().fetch_queue_acquire_lock(
      Commit_stage_manager::SYNC_STAGE);

  if (flush_error == 0 && total_bytes > 0) {
    std::pair<bool, bool> result = sync_binlog_file(false);
    sync_error = result.first;
  }
```

`sync_binlog_file()` 的源码：

```c
// binlog.cc:7691
std::pair<bool, bool> MYSQL_BIN_LOG::sync_binlog_file(bool force) {
  bool synced = false;
  unsigned int sync_period = get_sync_period();
  if (force || (sync_period && ++sync_counter >= sync_period)) {
    sync_counter = 0;

    if (DBUG_EVALUATE_IF("simulate_error_during_sync_binlog_file", 1,
                         m_binlog_file->is_open() && m_binlog_file->sync())) {
      THD *thd = current_thd;
      thd->commit_error = THD::CE_SYNC_ERROR;
      return std::make_pair(true, synced);
    }
    synced = true;
  }
  return std::make_pair(false, synced);
}
```

`sync_period` 对应 `sync_binlog` 系统变量。当 `sync_binlog=1` 时每个 group commit 都做 fsync；`sync_binlog=N` 时每 N 个 group commit 做一次。

**Stage 3 — COMMIT：** 调用存储引擎的 commit 提交事务：

```c
// binlog.cc:8076
  if ((opt_binlog_order_commits || Clone_handler::need_commit_order()) &&
      (sync_error == 0 || binlog_error_action != ABORT_SERVER)) {
    if (change_stage(thd, Commit_stage_manager::COMMIT_STAGE, final_queue,
                     leave_mutex_before_commit_stage, &LOCK_commit)) {
      return finish_commit(thd);
    }

    THD *commit_queue =
        Commit_stage_manager::get_instance().fetch_queue_acquire_lock(
            Commit_stage_manager::COMMIT_STAGE);

    if (flush_error == 0 && sync_error == 0)
      sync_error = call_after_sync_hook(commit_queue);

    process_commit_stage_queue(thd, commit_queue);
```

### 3.2 process_commit_stage_queue — 批量提交

Leader 线程在这里遍历 commit 队列，为每个线程调用 `finish_transaction_in_engines()`：

```c
// binlog.cc:7546
void MYSQL_BIN_LOG::process_commit_stage_queue(THD *thd, THD *first) {
  mysql_mutex_assert_owner(&LOCK_commit);

  for (THD *head = first; head; head = head->next_to_commit) {
    if (head->get_transaction()->sequence_number != SEQ_UNINIT) {
      mysql_mutex_lock(&LOCK_replica_trans_dep_tracker);
      m_dependency_tracker.update_max_committed(head);
      mysql_mutex_unlock(&LOCK_replica_trans_dep_tracker);
    }

    assert(head->commit_error != THD::CE_COMMIT_ERROR);
    Thd_backup_and_restore switch_thd(thd, head);
    bool all = head->get_transaction()->m_flags.real_commit;
    ::finish_transaction_in_engines(head, all, false);
  }

  /* Update GTID executed set in one batch */
  gtid_state->update_commit_group(first);

  for (THD *head = first; head; head = head->next_to_commit) {
    Thd_backup_and_restore switch_thd(thd, head);
    auto all = head->get_transaction()->m_flags.real_commit;
    trx_coordinator::set_prepared_in_tc_in_engines(head, all);

    if (head->get_transaction()->m_flags.xid_written) dec_prep_xids(head);
  }
}
```

关键设计点：
- `update_max_committed()` — 更新逻辑时钟的 `max_committed_timestamp`，让后续事务计算依赖
- `update_commit_group()` — 批量提交 GTID 状态，减少 `gtid_executed` 上的操作
- `dec_prep_xids()` — 递减 prepared XID 计数器，解除可能的死锁

### 3.3 Commit_stage_manager — 队列管理

`Commit_stage_manager` 维护了多个队列——每个 stage 一个：

```c
// rpl_commit_stage_manager.h:41
class Commit_stage_manager {
 public:
  class Mutex_queue {
    friend class Commit_stage_manager;
   public:
    Mutex_queue() : m_first(nullptr), m_last(&m_first), m_size(0) {}
    void init(mysql_mutex_t *lock) { m_lock = lock; }

    bool append(THD *first);
    THD *fetch_and_empty_acquire_lock();
    THD *fetch_and_empty_skip_acquire_lock();
    std::pair<bool, THD *> pop_front();
    inline int32 get_size() { return m_size.load(); }

   private:
    THD *m_first;
    THD **m_last;
    std::atomic<int32> m_size;
    mysql_mutex_t *m_lock;
  };

  enum StageID {
    BINLOG_FLUSH_STAGE,
    SYNC_STAGE,
    COMMIT_STAGE,
    AFTER_COMMIT_STAGE,
    COMMIT_ORDER_FLUSH_STAGE,
    STAGE_COUNTER
  };
```

Stage 队列的设计体现了 Leader-Follower 模式：
1. 第一个切入的线程成为 Leader，处理整批事务
2. 后续线程成为 Follower，在条件变量上等待
3. Leader 处理完后 `signal_done()` 唤醒 Follower

### 3.4 change_stage() — 阶段转换

```c
// binlog.cc:7647
bool MYSQL_BIN_LOG::change_stage(THD *thd,
                                 Commit_stage_manager::StageID stage,
                                 THD *queue, mysql_mutex_t *leave_mutex,
                                 mysql_mutex_t *enter_mutex) {
  DBUG_TRACE;
  assert(0 <= stage && stage < Commit_stage_manager::STAGE_COUNTER);
  assert(enter_mutex);
  assert(queue);

  if (!Commit_stage_manager::get_instance().enroll_for(
          stage, queue, leave_mutex, enter_mutex)) {
    return true;  // thread became follower
  }
  return false;  // thread is leader, continues to next stage
}
```

`enroll_for()` 的语义：
- 将队列中的线程注册到下一个 stage 的排队区
- 如果当前队列为空，调用线程成为该 stage 的 Leader（返回 false）
- 如果队列非空，调用线程成为 Follower，等待 Leader 处理完（返回 true）

---

## 4. 主从复制

### 4.1 Dump Thread: Binlog_sender

主库的 Dump Thread 由 `Binlog_sender` 类实现。当从库发送 `COM_BINLOG_DUMP` 或者 `COM_BINLOG_DUMP_GTID` 命令时，主库启动一个 dump 线程，调用 `Binlog_sender::run()`：

```c
// rpl_binlog_sender.h:48
/**
  The major logic of dump thread is implemented in this class. It sends
  required binlog events to clients according to their requests.
*/
class Binlog_sender {
  typedef Basic_binlog_file_reader<Binlog_ifile, Binlog_event_data_istream,
                                   Binlog_event_object_istream, Event_allocator>
      File_reader;

 public:
  Binlog_sender(THD *thd, const char *start_file, my_off_t start_pos,
                Gtid_set *exclude_gtids, uint32 flag);
  void run();
```

`run()` 的主循环：

```c
// rpl_binlog_sender.cc:386
void Binlog_sender::run() {
  DBUG_TRACE;
  init();

  File_reader reader(opt_source_verify_checksum, max_event_size);
  my_off_t start_pos = m_start_pos;
  const char *log_file = m_linfo.log_file_name;

  while (!has_error() && !m_thd->killed) {
    /* Send fake rotate event if needed */
    if (unlikely(fake_rotate_event(log_file, start_pos))) break;

    if (reader.open(log_file)) {
      set_fatal_error(log_read_error_msg(reader.get_error_type()));
      break;
    }

    THD_STAGE_INFO(m_thd, stage_sending_binlog_event_to_replica);
    if (send_binlog(reader, start_pos)) break;

    set_last_file(log_file);

    /* Switch to next binlog file */
    mysql_bin_log.lock_index();
    int error = mysql_bin_log.find_next_log(&m_linfo, false);
    mysql_bin_log.unlock_index();

    start_pos = BIN_LOG_HEADER_SIZE;
    reader.close();
  }

  cleanup();
}
```

Dump 线程的工作流程：
1. 从指定的 binlog 文件开始读取
2. 发送 fake Rotate 事件（如果需要）
3. 调用 `send_binlog()` 逐事件发送
4. 当前文件读完，找下一个 binlog 文件
5. 如果是最新的文件且从库请求持续同步，等待新的 binlog 更新

### 4.2 I/O Thread — 接收 relay log

从库的 I/O 线程由 `handle_slave_io()` 函数启动：

```c
// rpl_replica.cc:5281
extern "C" void *handle_slave_io(void *arg) {
  THD *thd{nullptr};
  Master_info *mi = (Master_info *)arg;
  Relay_log_info *rli = mi->rli;
  ...
  thd = new THD;
  mi->info_thd = thd;
  thd->thread_stack = (char *)&thd;

  mi->slave_running = 1;
  if (init_replica_thread(thd, SLAVE_THD_IO)) {
    goto err;
  }

  thd_manager->add_thd(thd);
  mi->abort_slave = false;

connect_init:
  /* Connect to master and request binlog dump */
  if (RUN_HOOK(binlog_relay_io, thread_start, (thd, mi))) {
    goto err;
  }

  retry_count = 0;
  if (!(mi->mysql = mysql = mysql_init(nullptr))) {
    goto err;
  }
```

I/O 线程的职责：
1. 连接到主库
2. 发送 `COM_BINLOG_DUMP` 或 `COM_BINLOG_DUMP_GTID`
3. 接收主库发送的 binlog 事件
4. 将事件写入 relay log 文件
5. 更新 `Master_info` 中的位置信息

### 4.3 SQL Thread — 应用 relay log

从库的 SQL 线程由 `handle_slave_sql()` 函数启动。核心循环在 `exec_relay_log_event()`：

```c
// rpl_replica.cc:6904
extern "C" void *handle_slave_sql(void *arg) {
  THD *thd;
  Relay_log_info *rli = ((Master_info *)arg)->rli;
  ...
  rli->slave_running = 1;
  rli->current_mts_submode = new Mts_submode_logical_clock();

  if (opt_replica_preserve_commit_order && !rli->is_parallel_exec() &&
      rli->opt_replica_parallel_workers > 1)
    commit_order_mngr =
        new Commit_order_manager(rli->opt_replica_parallel_workers);
```

`exec_relay_log_event()` 负责读取并应用单个事件：

```c
// rpl_replica.cc:4855
static int exec_relay_log_event(THD *thd, Relay_log_info *rli,
                                Rpl_applier_reader *applier_reader,
                                Log_event *in) {
  DBUG_TRACE;

  mysql_mutex_lock(&rli->data_lock);
  Log_event *ev = in;

  /* MTS checkpoint before dispatching */
  bool force = rli->rli_checkpoint_seqno >= rli->checkpoint_group;
  if (force || rli->is_time_for_mta_checkpoint()) {
    mysql_mutex_unlock(&rli->data_lock);
    if (mta_checkpoint_routine(rli, force)) {
      delete ev;
      return 1;
    }
    mysql_mutex_lock(&rli->data_lock);
  }

  if (ev) {
    /* Update last_master_timestamp for seconds_behind_master */
    if ((!rli->is_parallel_exec() || rli->last_master_timestamp == 0) &&
        !(ev->is_artificial_event() || ev->is_relay_log_event() ||
          ev->get_type_code() == FORMAT_DESCRIPTION_EVENT ||
          ev->server_id == 0)) {
      rli->last_master_timestamp =
          ev->common_header->when.tv_sec + (time_t)ev->exec_time;
    }

    /* Apply the event */
    exec_res = apply_event_and_update_pos(ptr_ev, thd, rli);
```

### 4.4 apply_event_and_update_pos

这是单线程复制下的核心执行函数：

```c
// rpl_replica.cc:4433
static enum enum_slave_apply_event_and_update_pos_retval
apply_event_and_update_pos(Log_event **ptr_ev, THD *thd, Relay_log_info *rli) {
  DBUG_TRACE;
  int exec_res;

  if ((*ptr_ev)->is_mts_parallel_exec() &&
      rli->is_parallel_exec() &&
      rli->replica_parallel_workers > 0) {
    /*
      For MTS: coordinator passes the event to a worker thread
    */
    return SLAVE_APPLY_EVENT_AND_UPDATE_POS_OK;
  }

  exec_res = (*ptr_ev)->apply_event(rli);

  if (exec_res == 0) {
    exec_res = (*ptr_ev)->update_pos(rli);
  }
```

当 MTS 启用时，事件不在此处执行，而是被 Coordinator 分发到 Worker 线程。在单线程模式下，直接调用 `apply_event()` → `update_pos()`。

---

## 5. Parallel Replication (MTS)

### 5.1 Slave_worker 类

MTS 中的 Worker 线程由 `Slave_worker` 类管理，它继承自 `Relay_log_info`：

```c
// rpl_rli_pdb.h:468
class Slave_worker : public Relay_log_info {
 public:
  Slave_worker(Relay_log_info *rli, ...);

  Slave_jobs_queue jobs;    // assignment queue containing events to execute
  mysql_mutex_t jobs_lock;
  mysql_cond_t jobs_cond;
  Relay_log_info *c_rli;    // pointer to Coordinator's rli

  ulong id;
  ulong transactions_handled;
  volatile ulong last_group_done_index;
  std::atomic<int> curr_jobs;

  volatile bool relay_log_change_notified;
  volatile bool checkpoint_notified;
  volatile bool master_log_change_notified;
  bool fd_change_notified;
```

每个 Worker 都有一个 `jobs` 队列，Coordinator 将事件分配到 Worker 的队列中。

### 5.2 Coordinator 调度

Coordinator 是 SQL 线程在 MTS 模式下的角色。它不是直接应用事件，而是将事件调度给各个 Worker。调度逻辑在 `slave_worker_exec_job_group()` 中：

```c
// rpl_rli_pdb.cc:1961
int slave_worker_exec_job_group(Slave_worker *worker, Relay_log_info *rli) {
  struct slave_job_item item = {nullptr, 0, {'\0'}, false};
  THD *thd = worker->info_thd;
  bool seen_gtid = false;
  bool after_gtid = true;
  bool seen_begin = false;
  int error = 0;
  Log_event *ev = nullptr;

  job_item = pop_jobs_item(worker, job_item);
  ...
  while (true) {
    ev = job_item->data;

    worker_curr_ev.set_current_event(ev);

    /* Classify transaction type */
    if (seen_gtid && after_gtid) {
      if (ev->get_type_code() == QUERY_EVENT) {
        auto *query_event = dynamic_cast<Query_log_event const *>(ev);
        if (strncmp(query_event->query, STRING_WITH_LEN("BEGIN"), 5) != 0) {
          worker_metrics.set_transaction_type(DDL);
        } else {
          worker_metrics.set_transaction_type(DML);
        }
      }
      after_gtid = false;
    }

    if (is_any_gtid_event(ev)) {
      seen_gtid = true;
      Gtid_log_event *gtid_ev = dynamic_cast<Gtid_log_event *>(ev);
      transaction_size = gtid_ev->get_trx_length();
    }
```

### 5.3 逻辑时钟并行（MTS Logical Clock）

MySQL 5.7+ 使用逻辑时钟（Logical Clock）来识别可以并行执行的事务。关键概念：
- `sequence_number` — 事务提交的顺序编号
- `last_committed` — 该事务依赖的最后一个已提交事务编号

在 `write_transaction()` 中：

```c
// binlog.cc:1648
  int64 sequence_number, last_committed;
  /* Generate logical timestamps for MTS */
  m_dependency_tracker.get_dependency(thd, parallelization_barrier,
                                      sequence_number, last_committed);
```

如果两个事务的 `last_committed < sequence_number` 并且没有重叠的数据库访问，它们就可以在从库上并行应用。

---

## 6. 半同步复制

### 6.1 架构

MySQL 5.5 引入的半同步复制（Semisynchronous Replication）插件，位于 `plugin/semisync/` 目录下。核心类是：

```c
// plugin/semisync/semisync_source.h:567
class ReplSemiSyncSource : public ReplSemiSyncBase {
 private:
  /* Active transaction list */
  ActiveTranx m_active_tranx;

  /* Whether semi-sync is enabled */
  bool m_enabled;

 public:
  bool commitTrx(const char *log_file, my_off_t log_pos);
  bool setExportAck(THD *thd);
  bool reportReply(THD *thd, const char *log_file, my_off_t log_pos);
```

```c
// plugin/semisync/semisync_replica.h:34
class ReplSemiSyncReplica : public ReplSemiSyncBase {
 public:
  bool m_enabled;

  int slaveReadSemiSyncAck(THD *thd);
```

半同步的工作原理：
1. 主库提交事务时，在 `after_sync` 阶段等待至少一个从库的 ACK
2. 从库在 I/O 线程收到事件后，回复 ACK 给主库
3. 如果在超时时间内未收到 ACK，主库退化为异步复制

### 6.2 ACK 机制

主库的 ACK 接收由 `semisync_source_ack_receiver` 管理：

```c
// plugin/semisync/semisync_source_ack_receiver.h
class Ack_receiver {
  /* Listen for ACK messages from replicas */
  void run();
```

从库的 ACK 发送：

```c
// plugin/semisync/semisync_replica.cc
int ReplSemiSyncReplica::slaveReadSemiSyncAck(THD *thd) {
  /* Send ACK to master with current received position */
```

半同步的核心 trade-off：用性能换取 `0` 数据丢失。主库事务提交延迟（latency）至少增加一个 RTT，但确保至少一个从库已经收到 binlog。

---

## 7. 崩溃安全

### 7.1 sync_binlog 与 innodb_flush_log_at_trx_commit

MySQL 的崩溃安全取决于两组配置的配合：

- **`sync_binlog=1`**：每个 group commit 都调用 `fsync()` 刷 binlog 到磁盘
- **`innodb_flush_log_at_trx_commit=1`**：每个事务提交都刷 InnoDB redo log 到磁盘

两者都设为 1 时，才能保证 binlog 和 InnoDB 数据的一致性。

```c
// binlog.cc:7691
std::pair<bool, bool> MYSQL_BIN_LOG::sync_binlog_file(bool force) {
  unsigned int sync_period = get_sync_period();  // sync_binlog value
  if (force || (sync_period && ++sync_counter >= sync_period)) {
    sync_counter = 0;
    if (m_binlog_file->is_open() && m_binlog_file->sync()) {
      thd->commit_error = THD::CE_SYNC_ERROR;
      return std::make_pair(true, synced);
    }
    synced = true;
  }
  return std::make_pair(false, synced);
}
```

### 7.2 Binlog 与 InnoDB 的两阶段提交

MySQL 采用两阶段提交（Two-Phase Commit，2PC）来保证 binlog 和 InnoDB 的一致性：

```
Phase 1 — Prepare:
  InnoDB 将事务标记为 prepared，写入 redo log
  redo log 刷盘

Phase 2 — Commit (via ordered_commit):
  Stage 1 (FLUSH):  将事务的 binlog 写入内存
  Stage 2 (SYNC):   binlog fsync 到磁盘
  Stage 3 (COMMIT): InnoDB 将事务标记为 committed
```

在 `fetch_and_process_flush_stage_queue()` 中，`ha_flush_logs(true)` 确保了所有 prepare 状态的 InnoDB 事务已经刷盘：

```c
// binlog.cc:7502
  if (!check_and_skip_flush_logs ||
      (check_and_skip_flush_logs && commit_order_thd != nullptr)) {
    ha_flush_logs(true);
  }
```

崩溃恢复的过程：
1. 扫描最后一个 binlog 文件，找到最后一个完整的轮次（group commit batch）
2. 所有在 binlog 中有完整事务（GTID + Xid）的 InnoDB 事务，在恢复时提交
3. 所有在 InnoDB 中 prepared 但 binlog 中不完整的，恢复时回滚

这就是 binlog 与 InnoDB 一致性的保证：**binlog 是权威（source of truth）**，恢复时以 binlog 中的记录为准。

### 7.3 prepared XID 计数器

MySQL 维护一个 `m_atomic_prep_xids` 计数器，用于跟踪有多少事务在 InnoDB 中已 prepare 但尚未在 binlog 中提交：

```c
// binlog.h:202
  mysql_cond_t m_prep_xids_cond;
  std::atomic<int32> m_atomic_prep_xids{0};

  void inc_prep_xids(THD *thd);
  void dec_prep_xids(THD *thd);
  int32 get_prep_xids() { return m_atomic_prep_xids; }
  void wait_for_prep_xids();
```

在 `process_commit_stage_queue()` 中，每个完成提交的事务通过 `dec_prep_xids()` 递减计数器：

```c
// binlog.cc:7597
    if (head->get_transaction()->m_flags.xid_written) dec_prep_xids(head);
```

当计数器归零时，所有 prepare 的事务都已安全地记录到了 binlog 中。

---

## 8. 关键函数索引

以下是本文引用和讲解的 MySQL 8.4 源码关键函数及类：

| 文件 | 行号 | 符号 | 说明 |
|------|------|------|------|
| `sql/binlog.h` | 107 | `class MYSQL_BIN_LOG` | Binlog 主控类 |
| `sql/binlog.h` | 202 | `m_atomic_prep_xids` | Prepared XID 计数器 |
| `sql/binlog.h` | 240 | `BINLOG_MAGIC` | Binlog 文件魔数 `\xfe\x62\x69\x6e` |
| `sql/binlog.cc` | 2606 | `binlog_commit()` | handlerton 注册的提交函数（空操作） |
| `sql/binlog.cc` | 7107 | `MYSQL_BIN_LOG::commit()` | 提交入口，准备缓存并调 ordered_commit |
| `sql/binlog.cc` | 7886 | `MYSQL_BIN_LOG::ordered_commit()` | Group commit 三阶段总控 |
| `sql/binlog.cc` | 7502 | `fetch_and_process_flush_stage_queue()` | 获取并预处理 flush 队列 |
| `sql/binlog.cc` | 7484 | `process_flush_stage_queue()` | 刷写整个 flush 队列中的缓存到 binlog |
| `sql/binlog.cc` | 7691 | `sync_binlog_file()` | 执行 fsync |
| `sql/binlog.cc` | 7546 | `process_commit_stage_queue()` | 批量调用存储引擎提交 |
| `sql/binlog.cc` | 7638 | `process_after_commit_stage_queue()` | 执行 after_commit 钩子 |
| `sql/binlog.cc` | 7647 | `change_stage()` | 阶段切换，决定 Leader/Follower |
| `sql/binlog.cc` | 6657 | `MYSQL_BIN_LOG::write_cache()` | 将缓存中的事件写入 binlog 文件 |
| `sql/binlog.cc` | 1636 | `MYSQL_BIN_LOG::write_transaction()` | 写入 GTID 头 + 事务数据 |
| `sql/rpl_commit_stage_manager.h` | 41 | `class Commit_stage_manager` | Group commit 阶段管理器 |
| `sql/rpl_commit_stage_manager.h` | 51 | `enum StageID` | 阶段编号（FLUSH/SYNC/COMMIT/AFTER_COMMIT） |
| `sql/log_event.h` | 615 | `Log_event::write_header_to_memory()` | 事件公共头布局 |
| `sql/log_event.h` | 1292 | `class Query_log_event` | STATEMENT 格式事件 |
| `sql/log_event.h` | 1531 | `class Format_description_log_event` | Binlog 格式描述事件 |
| `sql/log_event.h` | 1777 | `class Xid_log_event` | XID 提交事件 |
| `sql/log_event.h` | 2034 | `class Rotate_log_event` | Binlog 切换事件 |
| `sql/log_event.h` | 2781 | `class Rows_log_event` | ROW 格式行操作事件基类 |
| `sql/log_event.h` | 3325 | `class Write_rows_log_event` | 插入行事件 |
| `sql/log_event.h` | 3414 | `class Update_rows_log_event` | 更新行事件 |
| `sql/log_event.h` | 3534 | `class Delete_rows_log_event` | 删除行事件 |
| `sql/rpl_binlog_sender.h` | 48 | `class Binlog_sender` | 主库 Dump 线程实现类 |
| `sql/rpl_binlog_sender.cc` | 386 | `Binlog_sender::run()` | Dump 线程主循环 |
| `sql/rpl_replica.cc` | 5281 | `handle_slave_io()` | 从库 I/O 线程入口 |
| `sql/rpl_replica.cc` | 6904 | `handle_slave_sql()` | 从库 SQL 线程入口 |
| `sql/rpl_replica.cc` | 4855 | `exec_relay_log_event()` | 执行单个 relay log 事件 |
| `sql/rpl_replica.cc` | 4433 | `apply_event_and_update_pos()` | 应用事件并更新位置 |
| `sql/rpl_rli_pdb.h` | 468 | `class Slave_worker` | MTS Worker 线程类 |
| `sql/rpl_rli_pdb.cc` | 1961 | `slave_worker_exec_job_group()` | Worker 执行事件组 |
| `plugin/semisync/semisync_source.h` | 567 | `class ReplSemiSyncSource` | 半同步主库端实现 |
| `plugin/semisync/semisync_replica.h` | 34 | `class ReplSemiSyncReplica` | 半同步从库端实现 |

---

## 结语

MySQL 的复制引擎经过多年演进，已经是一个非常精密的分布式一致性系统。其核心架构 - binlog + group commit + 多线程复制 - 平衡了数据安全、性能和可用性三个维度。

理解 binlog 的写入路径和 group commit 的三阶段架构，不仅能帮助诊断复制延迟等问题，也是理解 MySQL 整体崩溃恢复和一致性保证的关键。随着 Group Replication（基于 Paxos）的发展，MySQL 正在向更强一致性的方向演进，但 binlog 和复制作为最成熟、最广泛使用的方案，仍将是 MySQL 生态的基石。
