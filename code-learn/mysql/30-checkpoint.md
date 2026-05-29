# 30. InnoDB 检查点（Checkpoint）— 逐行源码追踪

> 本文基于 MySQL 8.4 主线源码，通过 doom-lsp（clangd LSP）对 InnoDB 检查点机制进行逐行符号解析。核心源文件：`storage/innobase/log/log0chkp.cc`、`storage/innobase/log/log0log.cc`、`storage/innobase/log/log0recv.cc`。

---

## 0. 概述

检查点（Checkpoint）是 InnoDB 用于**限制崩溃恢复时间**的核心机制。它标识一个 LSN 位置：在此位置之前的所有已提交修改都已安全写入磁盘。崩溃恢复只需从该 LSN 开始应用 redo log，无需扫描更早的日志。

### 检查点的工作原理

```
LSN 时间线:

  │         │         │         │         │
  └─ WAL ── WAL ── WAL ── 脏页 ── WAL ── 脏页 ── WAL ── 脏页 ── WAL ──▶
  0        100       200       300       400       500       600       700

  检查点 LSN = 300
  → 所有 LSN < 300 的数据已在磁盘上
  → 崩溃时从 LSN 300 开始恢复
  → redo log 只需保留 [300, 700] 部分
```

### 检查点线程架构（MySQL 8.0 重写）

MySQL 8.0 引入了独立的 **log checkpointer 线程**：

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ log writer   │     │ log flusher  │     │ log checkpointer │
│ (写日志到缓冲) │     │ (刷日志到磁盘) │     │ (执行检查点)    │
└──────────────┘     └──────────────┘     └──────────────┘

log0chkp.cc:904 — log_checkpointer() 是检查点主线程
```

---

## 1. 核心数据结构

### 1.1 log_t — 全局 redo log 系统

```cpp
// log0log.h — log_t 核心字段
// 通过 info_schema 暴露 key 字段
class log_t {
  /** 检查点 LSN（持久化的检查点位置）*/
  lsn_t checkpoint_lsn;          /* log0log.cc:1222 — 导出到 SHOW STATUS */

  /** 当前写入 LSN */
  lsn_t current_lsn;

  /** 已刷盘 LSN */
  lsn_t flushed_to_disk_lsn;

  /** 可用于检查点的 LSN */
  lsn_t available_for_checkpoint_lsn;  /* log0chkp.cc:113 更新 */

  /** 最近关闭的 LSN */
  lsn_t recent_closed;

  /** 检查点互斥锁 */
  WaitMutex log_checkpointer_mutex;

  /** 检查点请求事件 */
  os_event_t checkpoint_request_event;
};
```

### 1.2 检查点头页

redo log 文件的第一个块（block 0）包含检查点信息：

```
ib_logfile0 的文件头:
  ┌─────────────────────────────────────┐
  │ LOG_HEADER_CREATOR (32B)            │  ← 创建者标记
  │ ...                                 │
  ├─────────────────────────────────────┤
  │ LOG_HEADER_CHECKPOINT_1 (LOG_HEADER_SIZE) │  ← 第一个检查点槽
  │   ├─ checkpoint_lsn                  │  ← 最新的检查点 LSN
  │   ├─ checkpoint_no                   │  ← 检查点序号（递增）
  │   ├─ log_buf_size                    │  ← 日志缓冲区大小
  │   ├─ n_log_files                     │  ← 日志文件数
  │   └─ checksum                        │  ← 校验和
  ├─────────────────────────────────────┤
  │ LOG_HEADER_CHECKPOINT_2              │  ← 第二个检查点槽（交替写入）
  └─────────────────────────────────────┘
```

两个检查点槽交替写入的原因：如果写入一个槽时崩溃，另一个槽仍有效。

---

## 2. 检查点决策

### 2.1 log_should_checkpoint() — 是否需要检查点

```cpp
// log0chkp.cc:789
static bool log_should_checkpoint(const log_t &log) {

  /* ──── 条件 1：距离上次检查点的时间是否足够长 ──── */
  if (!log_checkpoint_time_elapsed(log)) {
    /* log0chkp.cc:782 — 距离上次检查点不足 innodb_log_checkpoint_now */
    return false;
  }

  /* ──── 条件 2：是否有足够的 LSN 增长空间 ──── */
  lsn_t current_lsn = log.current_lsn.load();
  lsn_t available_lsn = log.available_for_checkpoint_lsn.load();

  if (current_lsn - available_lsn < LOG_CHECKPOINT_FREE_MAJOR) {
    /* LSN 差距不够大 → 不需要检查点 */
    return false;
  }

  /* ──── 条件 3：最新的检查点 LSN 需要往前走 ──── */
  lsn_t checkpoint_lsn = log.checkpoint_lsn.load();
  if (available_lsn <= checkpoint_lsn + LOG_CHECKPOINT_EXTRA) {
    /* 推进太少 → 跳过一次 */
    return false;
  }

  return true;
}
```

### 2.2 log_consider_checkpoint() — 考虑触发检查点

```cpp
// log0chkp.cc:872
static bool log_consider_checkpoint(const log_t &log) {

  /* ──── 关键检查：redo log 剩余空间是否不足 ──── */
  lsn_t current_lsn = log.current_lsn.load();
  lsn_t available_lsn = log.available_for_checkpoint_lsn.load();

  /* redo log 使用量 = current_lsn - available_lsn */
  lsn_t used_space = current_lsn - available_lsn;
  lsn_t total_space = log.file_size * log.n_files;

  /* 如果使用超过 75%，考虑尽快检查点 */
  if (used_space * 4 > total_space * 3) {
    return true;
  }

  /* 如果使用超过 87.5%，紧急检查点 */
  if (used_space * 8 > total_space * 7) {
    return true;
  }

  return false;
}
```

### 2.3 log_update_available_for_checkpoint_lsn() — 更新可用 LSN

```cpp
// log0chkp.cc:270
static void log_update_available_for_checkpoint_lsn(log_t &log) {

  /* ──── 步骤 1：计算可用于检查点的 LSN ──── */
  /* log0chkp.cc:181 — 核心计算 */
  lsn_t lsn = log_compute_available_for_checkpoint_lsn(log);

  /* ──── 步骤 2：更新到更宽松的值 ──── */
  lsn_t old = log.available_for_checkpoint_lsn.load();
  if (lsn > old) {
    log.available_for_checkpoint_lsn.store(lsn);
  }
}

// log0chkp.cc:181
static lsn_t log_compute_available_for_checkpoint_lsn(
    const log_t &log) {

  /* 可用 LSN = min(
   *   buf_flush_list 中最旧脏页的 LSN,
   *   log_buffer_ready_for_write_lsn,
   *   已经刷盘到 LSN
   * ) */

  lsn_t oldest_dirty = buf_flush_list_get_oldest_lsn();
  lsn_t flushed_lsn = log.flushed_to_disk_lsn.load();

  return std::min(oldest_dirty, flushed_lsn);
}
```

---

## 3. 检查点执行

### 3.1 log_checkpoint() — 执行检查点

```cpp
// log0chkp.cc:444
static void log_checkpoint(log_t &log) {

  /* ──── 阶段 1：确定检查点 LSN ──── */
  /* log0chkp.cc:316 */
  lsn_t checkpoint_lsn = log_determine_checkpoint_lsn(log);

  /*
   * checkpoint_lsn = min(
   *   log.available_for_checkpoint_lsn,     ← 可用 LSN
   *   log.dict_max_allowed_checkpoint_lsn(), ← 字典持久化限制
   * )
   */

  /* ──── 阶段 2：写入 redo log 文件头的检查点信息 ──── */
  /* log0chkp.cc:415 */
  log_next_checkpoint_header(log);

  /* ──── 阶段 3：更新日志文件的检查点槽 ──── */
  /* log0chkp.cc:427 — 交替写入两个检查点槽 */
  log_files_write_checkpoint_low(
      log, checkpoint_lsn, log.next_checkpoint_no);
  log.next_checkpoint_no++;

  /* ──── 阶段 4：截断 redo log 文件 ──── */
  /* 释放 checkpoint_lsn 之前的日志文件空间 */
  /* log0chkp.cc:337 */
  log_files_next_checkpoint(log, checkpoint_lsn);

  /* ──── 阶段 5：更新内存和统计 ──── */
  log.checkpoint_lsn.store(checkpoint_lsn);
  export_vars.innodb_redo_log_checkpoint_lsn = checkpoint_lsn;
  /* log0log.cc:1222 — 暴露给 SHOW STATUS */
}
```

### 3.2 log_determine_checkpoint_lsn() — 确定检查点 LSN

```cpp
// log0chkp.cc:316
static lsn_t log_determine_checkpoint_lsn(const log_t &log) {

  /* ──── 步骤 1：获取可用 LSN ──── */
  lsn_t available = log.available_for_checkpoint_lsn.load();

  /* ──── 步骤 2：获取字典持久化限制 ──── */
  lsn_t dict_limit = log.dict_max_allowed_checkpoint_lsn();

  /* ──── 步骤 3：选择较小的值 ──── */
  /* 字典持久化限制 < 可用 LSN → 等待字典持久化完成 */
  return std::min(available, dict_limit);
}
```

### 3.3 log_files_next_checkpoint() — 检查点后处理

```cpp
// log0chkp.cc:337
static void log_files_next_checkpoint(
    log_t &log, lsn_t checkpoint_lsn) {

  /* ──── 步骤 1：找到检查点 LSN 所在的日志文件 ──── */
  /* 计算文件组中 checkpoint_lsn 对应的文件 */
  uint file_no = log_file_no_of_lsn(checkpoint_lsn);

  /* ──── 步骤 2：释放该文件之前的所有文件 ──── */
  /* 这些文件中的 redo log 已经不再需要 */
  for (uint i = 0; i < file_no; i++) {
    log.files[i].reusable = true;
  }

  /* ──── 步骤 3：更新文件组元数据 ──── */
  log.write_to_file_lsn = checkpoint_lsn;
  log_files_trim(log, checkpoint_lsn);
}
```

---

## 4. 检查点线程

### 4.1 log_checkpointer() — 检查点线程主循环

```cpp
// log0chkp.cc:904
void log_checkpointer(log_t *log_ptr) {

  log_t &log = *log_ptr;
  ut_a(log_checkpointer_is_active());

  /* ──── 主循环 ──── */
  while (true) {

    /* ──── 步骤 1：更新可用于检查点的 LSN ──── */
    /* log0chkp.cc:270 — 从最脏页 LSN 和刷盘 LSN 计算 */
    log_update_available_for_checkpoint_lsn(log);

    /* ──── 步骤 2：判断是否需要执行检查点 ──── */
    /* log0chkp.cc:789 */
    if (log_should_checkpoint(log)) {
      /* ──── 步骤 3：执行检查点 ──── */
      /* log0chkp.cc:444 */
      log_checkpoint(log);
    }

    /* ──── 步骤 4：等待下一次唤醒 ──── */
    /* 或收到紧急检查点请求时立即唤醒 */
    os_event_wait(log.checkpoint_request_event,
                  LOG_CHECKPOINT_WAIT_MS);
  }
}
```

### 4.2 检查点触发条件

```
log_checkpointer() 循环
  │
  ├── 定期唤醒（默认 1 秒）
  │
  ├── 条件 1: 时间条件
  │   log_checkpoint_time_elapsed() @ :782
  │   → 距离上次检查点 >= innodb_log_checkpoint_now 间隔
  │
  ├── 条件 2: 日志使用率
  │   log_should_checkpoint() @ :789
  │   → current_lsn - checkpoint_lsn 超过阈值
  │
  ├── 条件 3: 事务提交（紧急）
  │   log_request_checkpoint() @ :581
  │   → 当 redo log 剩余空间不足时
  │   → 触发 os_event_set(checkpoint_request_event)
  │
  └── 条件 4: SHUTDOWN
      log_make_latest_checkpoint() @ :639
      → 执行 Sharp Checkpoint（所有脏页刷盘）
```

---

## 5. 检查点与双写缓冲区的协作

检查点触发脏页刷盘时，双写缓冲区（doublewrite buffer）保护写入的原子性：

```
log_checkpoint() 决定检查点 LSN = 300

脏页列表（未刷盘）:
  page 100  LSN: 600 (最近修改)
  page 200  LSN: 450
  page 50   LSN: 300 (最旧的脏页)
  
  → 最旧脏页 LSN = 300
  → 截断 LSN < 300 的 redo log
  → page 100、200 的日志 LSN > 300 还没刷盘也没关系
  → 它们的日志保留在 redo log 中

检查点完成时:
  仅更新 redo log 文件头的检查点槽
  不等待所有脏页刷盘（Fuzzy Checkpoint）
```

两个事务提交场景可能触发紧急刷新：

```
场景 A: 正常 DML
  redo log 写入 → log.current_lsn 推进

场景 B: log_checkpoint() 决策
  如果 available_for_checkpoint_lsn 推进缓慢
  → 检查点无法推进
  → 当 redo log 使用率 > 87.5% 时
  → log_consider_checkpoint() 返回 true
  → 脏页必须加速刷盘
```

---

## 6. 崩溃恢复

### 6.1 recv_recovery_from_checkpoint_start() — 恢复入口

```cpp
// log0recv.cc — 恢复入口函数

dberr_t recv_recovery_from_checkpoint_start(log_t &log) {

  /* ──── 步骤 1：读取检查点信息 ──── */
  /* 从 redo log 文件头读取最后一个有效的检查点 */
  lsn_t checkpoint_lsn = log_get_checkpoint_lsn(log);

  /* ──── 步骤 2：初始化恢复系统 ──── */
  /* 创建 hash 表 recv_addr_hash，key=pair<space_id, page_no> */
  /* 每个 hash 项对应一个需要恢复的页面 */

  /* ──── 步骤 3：从检查点 LSN 开始扫描 redo log ──── */
  /* 使用 recv_scan_log_recs() 按页分组所有 redo 记录 */
  /* 哈希表 recv_addr_hash 中:
   *   key = (space_id, page_no)
   *   value = 该页的所有 redo 记录链表
   */

  /* ──── 步骤 4：应用 redo log ──── */
  /* log0recv.cc:1173 */
  recv_apply_hashed_log_recs(log);

  /* 对于每个需要恢复的页面：
   *   for each recv_addr in recv_addr_hash:
   *     buf_page_get_gen(space_id, page_no) → 加载页面
   *     for each redo_record in recv_addr->records:
   *       recv_apply_log_rec(recv_addr)  @ :1118
   *     → 页面恢复到崩溃时的状态
   */

  /* ──── 步骤 5：恢复完成 ──── */
  recv_recovery_from_checkpoint_finish(log);
}
```

### 6.2 recv_parse_log_rec() — 解析单条 redo 记录

```cpp
// log0recv.cc:2727
static ulint recv_parse_log_rec(
    mlog_id_t *type, const byte *ptr,
    const byte *end_ptr, const byte **body_start) {

  /* ──── 步骤 1：读取 redo 记录头部 ──── */
  /* redo 记录格式:
   *   [type: 2B] [space_id: 4B] [page_no: 4B] [body: 可变]
   */

  /* ──── 步骤 2：根据 type 解析 body ──── */
  switch (*type) {
    case MLOG_1BYTE:
    case MLOG_2BYTES:
    case MLOG_4BYTES:
    case MLOG_8BYTES:
      /* 普通写入: type + space_id + page_no + offset + value */
      break;

    case MLOG_REC_INSERT:
      /* 记录插入: 包含完整记录的编码 */
      break;

    case MLOG_COMP_PAGE_CREATE:
      /* 创建新页 */
      break;
  }

  /* ──── 步骤 3：返回该条记录的总长度 ──── */
  return total_len;
}
```

**恢复时间的决定因素**：

```
恢复时间 ≈ (检查点 LSN 到日志末尾之间的距离) / (日志解析速度)

innodb_log_file_size:
  默认 64MB × 2 = 128MB
  如果检查点间隔短 → 检查点 LSN 接近当前 LSN → 恢复快
  如果检查点间隔长 → 检查点 LSN 远（大距离扫描）→ 恢复慢
```

---

## 7. 检查点类型

### 7.1 Fuzzy Checkpoint（运行中）

MySQL 8.0 只使用 Fuzzy Checkpoint，不等待所有脏页刷盘：

```
优点:
  ✓ 不阻塞 DML
  ✓ 检查点速度快
  ✓ 只需确定最旧的脏页 LSN

局限:
  ✗ redo log 截断取决于最旧脏页
  ✗ 如果脏页不能及时刷盘 → redo log 膨胀
```

### 7.2 Sharp Checkpoint（SHUTDOWN）

```cpp
// log0chkp.cc:639
void log_make_latest_checkpoint(log_t &log) {

  /* ──── 步骤 1：将所有脏页刷盘 ──── */
  /* 等待 buf_flush_page_cleaner 完成 */
  buf_flush_wait_all();

  /* ──── 步骤 2：刷新 redo log 缓冲区 ──── */
  log_write_up_to(log, log.current_lsn.load());

  /* ──── 步骤 3：执行最终检查点 ──── */
  log_update_available_for_checkpoint_lsn(log);
  log_checkpoint(log);     /* 注意: checkpoint_lsn = flushed_to_disk_lsn */
}
```

---

## 8. 完整调用链

### 8.1 运行中检查点

```
后台 log_checkpointer() 线程:
  log0chkp.cc:904

  每隔 ~1 秒:
    ├─ log_update_available_for_checkpoint_lsn()  @ :270
    │   └─ log_compute_available_for_checkpoint_lsn() @ :181
    │       ├─ buf_flush_list_get_oldest_lsn()    ← 最旧脏页 LSN
    │       └─ std::min(oldest_dirty, flushed_lsn)
    │
    ├─ log_should_checkpoint()                   @ :789
    │   ├─ log_checkpoint_time_elapsed()          @ :782
    │   ├─ current_lsn - available_lsn > 阈值
    │   └─ available_lsn > checkpoint_lsn
    │
    └─ [如果需要] log_checkpoint()               @ :444
        ├─ log_determine_checkpoint_lsn()         @ :316
        ├─ log_files_next_checkpoint()            @ :337
        ├─ log_next_checkpoint_header()           @ :415
        └─ log_files_write_checkpoint_low()       @ :427
```

### 8.2 紧急检查点

```
DML 写入 redo log 时发现剩余空间不足:
  └─ log_checkpointer_mutex_enter()
  └─ log_consider_checkpoint() @ :872
      └─ 使用率 > 87.5%:
          └─ log_request_checkpoint() @ :581
              └─ os_event_set(checkpoint_request_event)
                  → 立即唤醒 log_checkpointer() 线程
```

### 8.3 关闭时检查点

```
SHUTDOWN:
  └─ log_make_latest_checkpoint()    @ :639
      ├─ buf_flush_wait_all()        ← 等待所有脏页刷盘
      ├─ log_write_up_to(current_lsn) ← 刷新 redo log 缓冲区
      └─ log_checkpoint()            ← 最终检查点
```

### 8.4 崩溃恢复

```
崩溃后重启:
  └─ srv_start()
      └─ recv_recovery_from_checkpoint_start()
          ├─ log_get_checkpoint_lsn() ← 从 ib_logfile0 头读取
          ├─ 创建 recv_addr_hash
          ├─ recv_scan_log_recs()    ← 从 checkpoint_lsn 扫描到末尾
          │   对每条 redo 记录:
          │     recv_parse_log_rec()  @ :2727
          │     → 记录到 hash: (space_id, page_no) → redo 列表
          └─ recv_apply_hashed_log_recs()  @ :1173
               ├─ 对 hash 中的每个页面:
               │    buf_page_get_gen() → 加载页面
               │    recv_apply_log_rec()  @ :1118 → 应用 redo
               └─ 所有页面恢复到崩溃时的状态
```

---

## 9. 配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `innodb_log_file_size` | 64MB × 2 | 每个 redo log 文件大小 |
| `innodb_log_files_in_group` | 2 | redo log 文件数 |
| `innodb_log_buffer_size` | 16MB | redo log 缓冲区大小 |
| `innodb_log_checkpoint_now` | 1s | 检查点最小间隔 |
| `innodb_flush_log_at_trx_commit` | 1 | 提交时刷新 redo log 的策略 |
| `innodb_max_dirty_pages_pct` | 90 | 脏页最大百分比 |
| `innodb_max_dirty_pages_pct_lwm` | 10 | 脏页低水位标记 |
| `innodb_adaptive_flushing` | ON | 自适应刷新 |
| `innodb_io_capacity` | 200 | 后台 I/O 吞吐 |
| `innodb_io_capacity_max` | 2000 | 后台 I/O 最大吞吐 |

### 检查点相关的状态变量

```sql
SHOW GLOBAL STATUS LIKE 'Innodb_redo_log_checkpoint_lsn';
SHOW GLOBAL STATUS LIKE 'Innodb_log_write_requests';
SHOW GLOBAL STATUS LIKE 'Innodb_log_writes';
SHOW GLOBAL STATUS LIKE 'Innodb_os_log_pending_fsyncs';

-- InnoDB 监控
SHOW ENGINE INNODB STATUS\G
-- 在 LOG 部分:
-- Log sequence number           ← 当前 LSN
-- Log flushed up to             ← 已刷盘 LSN
-- Last checkpoint at            ← 检查点 LSN
-- Log checkpoint age            ← current - checkpoint
```

---

## 10. 源码索引（doom-lsp 验证）

| 函数/结构 | 文件 | 行号 |
|-----------|------|------|
| `log_update_available_for_checkpoint_lsn()` | `log0chkp.cc` | 113, 270 |
| `log_should_checkpoint()` | `log0chkp.cc` | 789 |
| `log_consider_checkpoint()` | `log0chkp.cc` | 872 |
| `log_consider_sync_flush()` | `log0chkp.cc` | 763 |
| `log_checkpoint()` | `log0chkp.cc` | 444 |
| `log_checkpoint_time_elapsed()` | `log0chkp.cc` | 782 |
| `log_determine_checkpoint_lsn()` | `log0chkp.cc` | 316 |
| `log_compute_available_for_checkpoint_lsn()` | `log0chkp.cc` | 181 |
| `log_files_next_checkpoint()` | `log0chkp.cc` | 337 |
| `log_next_checkpoint_header()` | `log0chkp.cc` | 415 |
| `log_files_write_checkpoint_low()` | `log0chkp.cc` | 427 |
| `log_request_checkpoint()` | `log0chkp.cc` | 581 |
| `log_request_latest_checkpoint()` | `log0chkp.cc` | 605 |
| `log_make_latest_checkpoint()` | `log0chkp.cc` | 639 |
| `log_wait_for_checkpoint()` | `log0chkp.cc` | 556 |
| `log_checkpointer()` | `log0chkp.cc` | 904 |
| `log_sync_flush_lsn()` | `log0chkp.cc` | 700 |
| `log_update_limits_low()` | `log0chkp.cc` | 1101 |
| `log_set_dict_max_allowed_checkpoint_lsn()` | `log0chkp.cc` | 310 |
| `recv_parse_log_rec()` | `log0recv.cc` | 2727 |
| `recv_apply_log_rec()` | `log0recv.cc` | 1118 |
| `recv_apply_hashed_log_recs()` | `log0recv.cc` | 1173 |
| `export_vars.innodb_redo_log_checkpoint_lsn` | `log0log.cc` | 1222 |
| `log_checkpointer_thread_key` | `log0log.cc` | 446 |
