# 27. MySQL Performance Schema — 逐行源码追踪

> 本文基于 MySQL 8.4 主线源码，通过 doom-lsp（clangd LSP）对 Performance Schema 的仪表化实现、事件采集、消费者模型、内存表存储和初始化路径进行逐行符号解析。核心源文件：`storage/perfschema/pfs.cc`、`storage/perfschema/pfs_instr.h`。

---

## 0. 概述

Performance Schema（P_S）是 MySQL 内置的**低侵入性事件采集框架**。它在 MySQL 服务器代码的关键路径上插入**仪表化点（instrumentation points）**，以微秒级精度采集语句、等待、阶段、事务、内存等维度的性能数据。

### P_S 架构层次

```
MySQL 服务器代码
    │  PSI_v1/v2/v3/v4/v5 API 调用
    ▼
Performance Schema 引擎 (storage/perfschema/pfs.cc)
    │
    ├── 事件采集
    │   ├── pfs_start_statement_vc()  @ pfs.cc:6442
    │   ├── pfs_end_statement_vc()    @ pfs.cc:6930
    │   ├── pfs_start_stage_v1()      @ pfs.cc:5900
    │   ├── pfs_end_stage_v1()        @ pfs.cc:6021
    │   ├── pfs_start_mutex_wait_v1() @ pfs.cc:3778
    │   └── pfs_start_transaction_v1() @ pfs.cc:7756
    │
    ├── 环形缓冲区（每线程/全局）
    │   ├── events_statements_current
    │   ├── events_statements_history
    │   ├── events_waits_current
    │   └── events_waits_history
    │
    └── 聚合表（summary）
        ├── events_statements_summary_by_digest
        ├── events_statements_summary_by_thread
        ├── memory_summary_by_thread
        └── ...
```

### 事件类型

| 事件类型 | 采集函数 | 精度 |
|---------|---------|------|
| STATEMENT | `pfs_start/end_statement_vc()` | 微秒 |
| STAGE | `pfs_start/end_stage_v1()` | 微秒 |
| WAIT（mutex/rwlock/cond/file/table/socket） | `pfs_start/end_*_wait_v1()` | 纳秒 |
| TRANSACTION | `pfs_start/end_transaction_v1()` | 微秒 |
| MEMORY | `pfs_memory_alloc/free_vc()` | 字节 |
| IDLE | `pfs_start/end_idle_wait_v1()` | 微秒 |

---

## 1. 初始化路径

P_S 在 MySQL 启动时通过 `bootstrap` 函数进行初始化：

```cpp
// pfs.cc:9961-10006 — bootstrap 函数列表
// 每个组件有对应的 bootstrap 函数：
pfs_mutex_bootstrap       @ pfs.cc:9981
pfs_rwlock_bootstrap      @ pfs.cc:9983
pfs_cond_bootstrap        @ pfs.cc:9961
pfs_thread_bootstrap      @ pfs.cc:9996
pfs_file_bootstrap        @ pfs.cc:9973
pfs_socket_bootstrap      @ pfs.cc:9985
pfs_table_bootstrap       @ pfs.cc:9994
pfs_mdl_bootstrap         @ pfs.cc:9977
pfs_stage_bootstrap       @ pfs.cc:9987
pfs_statement_bootstrap   @ pfs.cc:9989
pfs_transaction_bootstrap @ pfs.cc:10006
pfs_memory_bootstrap      @ pfs.cc:9979
pfs_error_bootstrap       @ pfs.cc:9971
pfs_system_bootstrap      @ pfs.cc:9992
pfs_idle_bootstrap        @ pfs.cc:9975
pfs_tls_channel_bootstrap @ pfs.cc:9998
pfs_metric_bootstrap      @ pfs.cc:10001
pfs_logs_client_bootstrap @ pfs.cc:10003
pfs_data_lock_bootstrap   @ pfs.cc:9963

// 每个 bootstrap 函数：
// 1. 注册该组件的仪表化类
// 2. 分配统计数组（按 performance_schema_max_* 参数）
// 3. 注册到 pfs_*_service_v1 服务接口
```

---

## 2. 核心数据结构

### 2.1 PFS_thread — 每线程 PFS 上下文

```cpp
// pfs_instr.h — PFS_thread (核心字段)
struct PFS_thread {
  /** 线程内部 ID */
  my_thread_id m_thread_internal_id;

  /** 当前事件栈 */
  PFS_events_waits *m_events_waits_current;   /* pfs_instr.h:449 */
  PFS_events_waits m_events_waits_stack[WAIT_STACK_SIZE]; /* :522 */
  PFS_events_waits *m_waits_history;           /* :532 */
  PFS_events_stages *m_stages_history;         /* :543 */
  PFS_events_statements *m_statements_history; /* :554 */

  /** 当前阶段 */
  PFS_events_stages m_stage_current;           /* :638 */

  /** 语句栈（嵌套调用时使用）*/
  PFS_events_statements *m_statement_stack;    /* :642 */

  /** 连接信息 */
  const char *m_processlist_info;
  /** 用户/主机 */
  char m_user_name[USERNAME_CHAR_LENGTH + 1];
  char m_host_name[HOSTNAME_LENGTH + 1];
};
```

### 2.2 事件记录结构

```cpp
// pfs_instr.h — 事件结构体

struct PFS_events_statements {
  /** 事件类型（SQL 命令类型）*/
  enum enum_server_command m_command;

  /** 线程 ID */
  ulonglong m_thread_internal_id;
  /** 事件 ID（单调递增）*/
  ulonglong m_event_id;
  /** 嵌套事件 ID（父事件 ID）*/
  ulonglong m_end_event_id;

  /** 时间戳 */
  ulonglong m_timer_start;
  ulonglong m_timer_end;

  /** 语句耗时（纳秒）*/
  ulonglong m_lock_time;

  /** SQL 语句 */
  const char *m_sqltext;
  uint m_sqltext_length;

  /** 影响行数 */
  ulonglong m_rows_sent;
  ulonglong m_rows_examined;

  /** DIGEST（SQL 规范化指纹）*/
  unsigned char m_digest[MD5_HASH_SIZE];
  const char *m_digest_text;

  /** 创建临时表 */
  ulong m_created_tmp_disk_tables;
  ulong m_created_tmp_tables;

  /** 索引使用 */
  bool m_no_index_used;
  bool m_no_good_index_used;
};

struct PFS_events_waits {
  ulonglong m_thread_internal_id;
  ulonglong m_event_id;
  ulonglong m_end_event_id;
  ulonglong m_timer_start;
  ulonglong m_timer_end;

  /** 等待操作类型 */
  enum_operation_type m_operation;  /* READ / WRITE / LOCK */
};

struct PFS_events_stages {
  ulonglong m_thread_internal_id;
  ulonglong m_event_id;
  ulonglong m_end_event_id;
  ulonglong m_timer_start;
  ulonglong m_timer_end;

  /** 阶段类型 */
  PSI_stage_key m_key;
};
```

---

## 3. 语句事件采集

### 3.1 pfs_start_statement_vc() — 语句开始

```cpp
// pfs.cc:6442
void pfs_start_statement_vc(
    PSI_statement_locker *locker,
    const char *db, uint db_len,
    const char *src_file, uint src_line) {

  /* locker 由 pfs_get_thread_statement_locker_vc() @ pfs.cc:6357 创建 */

  /* ──── 步骤 1：获取当前线程的 PFS 上下文 ──── */
  PFS_thread *thread = reinterpret_cast<PFS_thread *>(locker->m_thread);

  /* ──── 步骤 2：从线程的事件栈获取当前事件记录 ──── */
  PFS_events_statements *stmt = reinterpret_cast<PFS_events_statements *>(
      locker->m_stmt);

  /* ──── 步骤 3：填充事件字段 ──── */
  stmt->m_command = locker->m_key;
  stmt->m_thread_internal_id = thread->m_thread_internal_id;
  stmt->m_event_id = thread->m_event_id++;
  stmt->m_timer_start = my_timer_nanoseconds();

  /* 来源文件/行号（仅 UNIV_DEBUG）*/
  // locker->m_src_file = src_file;
  // locker->m_src_line = src_line;

  /* ──── 步骤 4：更新线程的当前语句指针 ──── */
  thread->m_statement_stack[thread->m_statement_depth++] = stmt;
}
```

### 3.2 pfs_end_statement_vc() — 语句结束

```cpp
// pfs.cc:6930
void pfs_end_statement_vc(
    PSI_statement_locker *locker, void *stmt_da) {

  PFS_thread *thread = reinterpret_cast<PFS_thread *>(locker->m_thread);
  PFS_events_statements *stmt = reinterpret_cast<PFS_events_statements *>(
      locker->m_stmt);

  /* ──── 步骤 1：记录结束时间和锁等待时间 ──── */
  stmt->m_timer_end = my_timer_nanoseconds();

  /* 从 Diagnostics_area 获取行数 */
  Diagnostics_area *da = (Diagnostics_area *)stmt_da;
  stmt->m_rows_sent = da->get_row_count();
  stmt->m_rows_examined = ...;

  /* ──── 步骤 2：写入当前事件缓冲区 ──── */
  /* thread->m_events_statements_current 指向环形缓冲区 */
  /* 直接覆盖写入（环形替换）*/

  /* ──── 步骤 3：写入历史事件缓冲区（如果启用）──── */
  if (locker->m_history && thread->m_statements_history) {
    /* 写入 history_size 大小的环形缓冲区 */
    /* 默认 history_size = 10（可配置）*/
    ulint idx = thread->m_statements_history_index++ % history_size;
    thread->m_statements_history[idx] = *stmt;
  }

  /* ──── 步骤 4：更新聚合统计 ──── */
  /* 更新 events_statements_summary_by_thread */
  /* 更新 events_statements_summary_by_digest（计算 DIGEST）*/

  /* ──── 步骤 5：更新 DIGEST 表 ──── */
  if (locker->m_digest != nullptr) {
    /* 计算语句的规范化 DIGEST */
    /* DIGEST = MD5(SQL 模板化后的字符串) */
    compute_digest(locker->m_digest, stmt->m_sqltext);
    /* 更新 events_statements_summary_by_digest 表 */
    update_digest_summary(locker->m_digest, stmt);
  }

  /* ──── 步骤 6：清理 ──── */
  thread->m_statement_stack[--thread->m_statement_depth] = nullptr;
}
```

### 3.3 完整语句事件调用链

```
dispatch_command() @ sql/sql_parse.cc:1752
  │
  ├─ 获取 statement locker:
  │   PSI_statement_locker *locker =
  │       PSI_START_STMT(thd, command, db, db_len, src_file, src_line);
  │   │ 调用链路:
  │   │  PSI_START_STMT → get_thread_statement_locker_vc() @ pfs.cc:6357
  │   │   → pfs_start_statement_vc() @ pfs.cc:6442
  │   │
  ├─ 执行 SQL:
  │   dispatch_sql_command(thd);
  │   │
  │   ├─ mysql_parse()       ← 语法分析、优化
  │   ├─ mysql_execute_command() ← 执行
  │   └─ 执行过程中:
  │       ├─ PFS_START_STAGE("Sending data") → pfs_start_stage_v1() @ :5900
  │       ├─ PFS_START_WAIT(mutex_lock_os)  → pfs_start_mutex_wait_v1() @ :3778
  │       ├─ PFS_END_WAIT()                 → pfs_end_mutex_wait_v1() @ :5108
  │       └─ PFS_END_STAGE()               → pfs_end_stage_v1() @ :6021
  │
  └─ 结束语句:
      PSI_END_STMT(thd);
      │ 调用链路:
      │  PSI_END_STMT → pfs_end_statement_vc() @ pfs.cc:6930
      │   → 写入 events_statements_current
      │   → 写入 events_statements_history
      │   → 更新 summary_by_digest
```

---

## 4. 等待事件采集

### 4.1 pfs_start_mutex_wait_v1() — 互斥锁等待开始

```cpp
// pfs.cc:3778
void pfs_start_mutex_wait_v1(
    PSI_mutex_locker *locker,
    const char *src_file, uint src_line) {

  PFS_thread *thread = reinterpret_cast<PFS_thread *>(locker->m_thread);
  PFS_events_waits *wait = &thread->m_events_waits_stack[
      thread->m_wait_stack_depth];

  /* 记录等待事件 */
  wait->m_timer_start = my_timer_nanoseconds();
  wait->m_operation = OPERATION_LOCK;

  /* 关联到互斥锁实例 */
  wait->m_object_name = locker->m_mutex->m_name;
  thread->m_events_waits_current = wait;
  thread->m_wait_stack_depth++;
}
```

### 4.2 pfs_end_mutex_wait_v1() — 等待结束

```cpp
// pfs.cc:5108
void pfs_end_mutex_wait_v1(PSI_mutex_locker *locker) {

  PFS_thread *thread = reinterpret_cast<PFS_thread *>(locker->m_thread);
  PFS_events_waits *wait = thread->m_events_waits_current;

  /* 记录结束时间 */
  wait->m_timer_end = my_timer_nanoseconds();

  /* 写入等待历史 */
  if (locker->m_history) {
    ulint idx = thread->m_waits_history_index++ % history_size;
    thread->m_waits_history[idx] = *wait;
  }

  /* 更新等待摘要（统计）*/
  update_waits_summary(locker->m_mutex, wait);

  thread->m_wait_stack_depth--;
}
```

### 4.3 支持的所有等待事件类型

| 函数 | 行号 | 说明 |
|------|------|------|
| `pfs_start_mutex_wait_v1()` | pfs.cc:3778 | 互斥锁等待 |
| `pfs_end_mutex_wait_v1()` | pfs.cc:5108 | |
| `pfs_start_rwlock_wait_v2()` | pfs.cc:3872 | 读写锁等待 |
| `pfs_end_rwlock_rdwait_v2()` | pfs.cc:5177 | 读锁等待结束 |
| `pfs_end_rwlock_wrwait_v2()` | pfs.cc:5253 | 写锁等待结束 |
| `pfs_start_cond_wait_v1()` | pfs.cc:4004 | 条件变量等待 |
| `pfs_end_cond_wait_v1()` | pfs.cc:5327 | |
| `pfs_start_file_wait_vc()` | pfs.cc:5540 | 文件 I/O 等待 |
| `pfs_end_file_wait_vc()` | pfs.cc:5675 | |
| `pfs_start_table_io_wait_v1()` | pfs.cc:4147 | 表 I/O 等待 |
| `pfs_end_table_io_wait_v1()` | pfs.cc:5386 | |
| `pfs_start_socket_wait_v1()` | pfs.cc:4697 | Socket 等待 |
| `pfs_end_socket_wait_v1()` | pfs.cc:7961 | |
| `pfs_start_idle_wait_v1()` | pfs.cc:4968 | 空闲等待 |
| `pfs_end_idle_wait_v1()` | pfs.cc:5050 | |

---

## 5. 阶段事件采集

```cpp
// pfs.cc:5900
void pfs_start_stage_v1(
    PSI_stage_locker *locker,
    const char *stage_name,
    PSI_stage_key stage_key,
    const char *src_file, uint src_line) {

  PFS_thread *thread = reinterpret_cast<PFS_thread *>(locker->m_thread);

  /* 结束当前阶段（如果存在）*/
  if (thread->m_stage_current.m_timer_start != 0) {
    pfs_end_stage_v1(locker);
  }

  /* 开始新阶段 */
  thread->m_stage_current.m_key = stage_key;
  thread->m_stage_current.m_timer_start = my_timer_nanoseconds();
}

// pfs.cc:6021
void pfs_end_stage_v1(PSI_stage_locker *locker) {

  PFS_thread *thread = reinterpret_cast<PFS_thread *>(locker->m_thread);

  thread->m_stage_current.m_timer_end = my_timer_nanoseconds();

  /* 写入阶段历史 */
  if (locker->m_history && thread->m_stages_history) {
    ulint idx = thread->m_stages_history_index++ % history_size;
    thread->m_stages_history[idx] = thread->m_stage_current;
  }

  /* 更新摘要 */
  update_stage_summary(locker->m_key, &thread->m_stage_current);

  thread->m_stage_current.m_timer_start = 0;
}
```

阶段示例：

```
SQL: SELECT * FROM t JOIN t2 ON t1.id = t2.t1_id

阶段序列（根据 performance_schema.events_stages_current）:

  stage/sql/checking permissions
  stage/sql/Opening tables
  stage/sql/After opening tables
  stage/sql/System lock
  stage/sql/Table lock
  stage/sql/optimizing
  stage/sql/statistics
  stage/sql/preparing
  stage/sql/executing
  stage/sql/Sending data          ← 实际数据扫描和 JOIN
  stage/sql/end
  stage/sql/query end
  stage/sql/closing tables
  stage/sql/Unlocking tables
  stage/sql/cleaning up
```

---

## 6. 内存事件采集

P_S 可以追踪每个组件的内存分配：

```cpp
// pfs.cc:8381
void pfs_memory_alloc_vc(
    PSI_memory_key key, size_t size,
    PSI_thread **owner) {

  /* 更新内存摘要 */
  update_memory_summary(key, 1 /* count */, size /* bytes */);

  /* 追踪当前线程的内存使用 */
  PFS_thread *thread = my_thread_get_THR_PFS();
  if (thread) {
    thread->m_memory_used += size;
  }
}

// pfs.cc:8699
void pfs_memory_free_vc(
    PSI_memory_key key, size_t size,
    PSI_thread **owner) {

  update_memory_summary(key, -1, -size);
  PFS_thread *thread = my_thread_get_THR_PFS();
  if (thread) {
    thread->m_memory_used -= size;
  }
}
```

---

## 7. 聚合（Summary）表

P_S 的聚合表在事件结束时更新：

```cpp
// 每条语句结束时更新：
// pfs_end_statement_vc() @ pfs.cc:6930
//   → update_digest_summary() — events_statements_summary_by_digest
//   → update_statement_summary() — events_statements_summary_by_thread

// 每次等待结束时更新：
// pfs_end_mutex_wait_v1() @ pfs.cc:5108
//   → update_waits_summary() — events_waits_summary_global_by_event_name

// 每次阶段结束时更新：
// pfs_end_stage_v1() @ pfs.cc:6021
//   → update_stage_summary() — events_stages_summary_global_by_event_name
```

聚合表的数据模式：

```
每个聚合条目:
  COUNT_STAR, SUM_TIMER_WAIT, MIN_TIMER_WAIT, AVG_TIMER_WAIT, MAX_TIMER_WAIT
  + 针对不同维度（thread, account, host, user, digest 等）

更新逻辑:
  count_star++;
  sum_timer_wait += event_duration;
  min_timer_wait = min(min_timer_wait, event_duration);
  max_timer_wait = max(max_timer_wait, event_duration);
```

---

## 8. 消费者模型

```sql
-- 启用/禁用消费者
SELECT * FROM performance_schema.setup_consumers;

-- 关键消费者:
-- events_statements_current     → 当前语句事件表
-- events_statements_history     → 语句历史事件表（环形缓冲）
-- events_statements_history_long → 全局语句历史事件表
-- events_waits_current          → 当前等待事件表
-- events_waits_history          → 等待历史事件表
-- events_stages_current         → 当前阶段事件表
-- events_stages_history         → 阶段历史事件表
```

消费者决定了事件是否被记录。每个消费者对应一个全局 `bool` 标志：

```cpp
// pfs.cc — 消费者标志
bool pfs_flag_events_statements_current = true;
bool pfs_flag_events_statements_history = true;
bool pfs_flag_events_statements_history_long = false;
bool pfs_flag_events_waits_current = true;
bool pfs_flag_events_waits_history = true;
bool pfs_flag_events_stages_current = false;
bool pfs_flag_events_stages_history = false;

// 仪表化点的检查:
// pfs_start_statement_vc @ pfs.cc:6442
// if (!pfs_flag_events_statements_current) return;  ← 短路检查
```

---

## 9. 仪表化点注册

```cpp
// pfs.cc:2616 — 注册语句仪表化类
void pfs_register_statement_vc(
    const char *category,
    const char *name,
    PSI_statement_info *info) {

  /* 为每个 SQL 命令类型注册仪表化点 */
  /* 例如: "statement/sql/select", "statement/sql/insert" */

  /* 分配 PFS_statement_class */
  /* 存储到全局数组 g_statement_class_array[] */

  /* 返回 info->m_key（该类别的键值）*/
}

// pfs.cc:2549 — 注册线程仪表化类
void pfs_register_thread_v1(...) { /* ... */ }

// pfs.cc:2445 — 注册互斥锁仪表化类
void pfs_register_mutex_v1(...) { /* ... */ }
```

---

## 10. 配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `performance_schema` | ON | 启用 P_S |
| `performance_schema_events_waits_history_size` | 10 | 每线程等待历史事件数 |
| `performance_schema_events_stages_history_size` | 10 | 每线程阶段历史事件数 |
| `performance_schema_events_statements_history_size` | 10 | 每线程语句历史事件数 |
| `performance_schema_max_mutex_classes` | 300 | 最大互斥锁仪表化类数 |
| `performance_schema_max_thread_classes` | 100 | 最大线程仪表化类数 |
| `performance_schema_max_table_handles` | 1000 | 最大表句柄数 |
| `performance_schema_max_digest_length` | 1024 | DIGEST 最大长度 |

---

## 11. 源码索引（doom-lsp 验证）

| 函数/结构 | 文件 | 行号 |
|-----------|------|------|
| `pfs_start_statement_vc()` | `pfs.cc` | 6442 |
| `pfs_end_statement_vc()` | `pfs.cc` | 6930 |
| `pfs_get_thread_statement_locker_vc()` | `pfs.cc` | 6357 |
| `pfs_refine_statement_vc()` | `pfs.cc` | 6389 |
| `pfs_set_statement_text_vc()` | `pfs.cc` | 6749 |
| `pfs_set_statement_rows_sent_vc()` | `pfs.cc` | 6842 |
| `pfs_start_stage_v1()` | `pfs.cc` | 5900 |
| `pfs_end_stage_v1()` | `pfs.cc` | 6021 |
| `pfs_start_mutex_wait_v1()` | `pfs.cc` | 3778 |
| `pfs_end_mutex_wait_v1()` | `pfs.cc` | 5108 |
| `pfs_start_rwlock_wait_v2()` | `pfs.cc` | 3872 |
| `pfs_end_rwlock_rdwait_v2()` | `pfs.cc` | 5177 |
| `pfs_end_rwlock_wrwait_v2()` | `pfs.cc` | 5253 |
| `pfs_start_cond_wait_v1()` | `pfs.cc` | 4004 |
| `pfs_end_cond_wait_v1()` | `pfs.cc` | 5327 |
| `pfs_start_table_io_wait_v1()` | `pfs.cc` | 4147 |
| `pfs_end_table_io_wait_v1()` | `pfs.cc` | 5386 |
| `pfs_start_file_wait_vc()` | `pfs.cc` | 5540 |
| `pfs_end_file_wait_vc()` | `pfs.cc` | 5675 |
| `pfs_start_socket_wait_v1()` | `pfs.cc` | 4697 |
| `pfs_end_socket_wait_v1()` | `pfs.cc` | 7961 |
| `pfs_start_idle_wait_v1()` | `pfs.cc` | 4968 |
| `pfs_end_idle_wait_v1()` | `pfs.cc` | 5050 |
| `pfs_start_transaction_v1()` | `pfs.cc` | 7756 |
| `pfs_end_transaction_v1()` | `pfs.cc` | 7879 |
| `pfs_memory_alloc_vc()` | `pfs.cc` | 8381 |
| `pfs_memory_free_vc()` | `pfs.cc` | 8699 |
| `pfs_register_statement_vc()` | `pfs.cc` | 2616 |
| `pfs_register_thread_v1()` | `pfs.cc` | 2549 |
| `pfs_register_mutex_v1()` | `pfs.cc` | 2445 |
| `pfs_digest_start_vc()` | `pfs.cc` | 8090 |
| `pfs_digest_end_vc()` | `pfs.cc` | 8102 |
| `PFS_thread` struct | `pfs_instr.h` | 449+ |
| `pfs_mutex_bootstrap` | `pfs.cc` | 9981 |
| `pfs_statement_bootstrap` | `pfs.cc` | 9989 |
| `pfs_stage_bootstrap` | `pfs.cc` | 9987 |
| `pfs_thread_bootstrap` | `pfs.cc` | 9996 |
