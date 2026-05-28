# 27. MySQL Performance Schema — 源码分析

> 本文分析 MySQL Performance Schema 的实现，包括采集器架构、消费者模型、内存表存储、仪表化（instrumentation）点和配置机制。核心源文件：`sql/pfs/` 目录下的全部文件。

---

## 0. 概述

Performance Schema（P_S）是 MySQL 内部的一个**事件采集框架**，零成本（插入检查为零——仅当启用时才采集）、低侵入性地监控 MySQL 服务器内部行为。它提供了语句级别、阶段级别、等待级别、事务级别和内存使用级别的监控数据。

### P_S 架构

```
MySQL 服务器代码
    │
    ├── Instrumentation Points（仪表化点）
    │   ├── PFS_register_*()      ← 注册事件类型
    │   ├── PFS_start_*()         ← 开始采集事件
    │   └── PFS_end_*()           ← 结束采集事件
    │
    ▼
Performance Schema 引擎
    │
    ├── Events 缓冲区（内存环形缓冲）
    ├── Consumers（消费者过滤/汇总）
    └── Summary 表（聚合数据）
```

---

## 1. 仪表化点（Instrumentation）

Performance Schema 在 MySQL 代码中插入宏调用点：

```cpp
// sql/pfs/pfs_instr.h
/* 语句级别 */
#define PFS_START_STMT(type, thd)        \
  if (pfs_enabled) {                     \
    pfs_start_statement_vc(type, thd);   \
  }

#define PFS_END_STMT(thd)                \
  if (pfs_enabled) {                     \
    pfs_end_statement_vc(thd);           \
  }

/* 等待级别 */
#define PFS_START_WAIT(class, thd)       \
  pfs_start_wait_vc(class, thd);

#define PFS_END_WAIT(thd)                \
  pfs_end_wait_vc(thd);
```

### 关键仪表化点位置

| 事件类型 | 插入的代码位置 |
|---------|---------------|
| `statement/sql/select` | `sql/sql_select.cc — execute_select()` |
| `statement/sql/insert` | `sql/sql_insert.cc — mysql_insert()` |
| `wait/sync/mutex/sql/LOCK_open` | `sql/mysqld.cc — thr_lock.c` |
| `wait/io/file/innodb/innodb_data_file` | `fil0fil.cc — fil_io()` |
| `memory/sql/THD::main_mem_root` | `sql/mysqld.cc — thd_init()` |
| `stage/sql/Sending data` | `sql/sql_select.cc — send_data()` |

---

## 2. 消费者模型

消费者决定什么数据被记录：

```cpp
// sql/pfs/pfs_consumer.h
struct PFS_consumer {
  /* 是否启用此消费者 */
  bool m_enabled;

  /* 过滤器：哪些事件类型通过 */
  PFS_filter *m_filter;

  /* 写入目标（内存表或摘要表）*/
  PFS_sink *m_sink;
};

/* 预定义的消费者 */
PFS_consumer events_statements_current;   /* 当前语句事件表 */
PFS_consumer events_statements_history;    /* 语句历史表（环形缓冲，10条/线程）*/
PFS_consumer events_statements_summary;    /* 语句摘要表 */
PFS_consumer events_waits_current;         /* 当前等待事件表 */
PFS_consumer events_waits_history;         /* 等待历史表 */
PFS_consumer memory_summary;               /* 内存摘要表 */
```

每个事件的完整流程：

```
Instrumentation point
    → if (consumer enabled) → create PFS_event
    → push to events_*_current (环形缓冲)
    → if (history consumer) → push to events_*_history
    → if (summary consumer) → update summary table
    → if (digest consumer) → update digest table
```

---

## 3. 内存表存储

P_S 使用特殊的内存表引擎（`PFS_TABLE`），所有数据存储在内存中：

```cpp
// sql/pfs/pfs_engine.h
class PFS_engine_table : public handler {
 public:
  /* P_S 表不持久化 */
  int rnd_init(bool scan) override;
  int rnd_next(uchar *buf) override;
  int rnd_pos(uchar *buf, uchar *pos) override;

  /* 写入操作 — 对 P_S 表 UPDATE/DELETE 的特殊含义 */
  /* UPDATE = 清空计数器（重置）*/
  /* DELETE = 清空事件缓冲区 */
  int ha_delete_row(const uchar *buf) override;
  int ha_update_row(const uchar *old_data,
                    uchar *new_data) override;
};
```

**P_S 表的特殊行为**：

```sql
-- 重置所有语句计数器
UPDATE performance_schema.events_statements_summary_by_digest
  SET COUNT_STAR = 0;

-- 清空历史事件
DELETE FROM performance_schema.events_statements_history;

-- 启用/禁用消费者
UPDATE performance_schema.setup_consumers
  SET ENABLED = 'YES'
  WHERE NAME = 'events_statements_history';
```

---

## 4. 配置管理

```sql
-- 查看所有仪表化点
SELECT * FROM performance_schema.setup_instruments;

-- 查看所有消费者
SELECT * FROM performance_schema.setup_consumers;

-- 查看当前线程设置
SELECT * FROM performance_schema.threads;

-- 动态启用/禁用
CALL sys.ps_setup_enable_instrument('statement');
CALL sys.ps_setup_disable_instrument('statement');
CALL sys.ps_setup_enable_consumer('events_statements_history');
```

---

## 5. 内存占用控制

```cpp
// sql/pfs/pfs_defaults.h

/* 环形缓冲区大小配置 */
ulong performance_schema_events_waits_history_size = 10;    /* 每线程 */
ulong performance_schema_events_stages_history_size = 10;
ulong performance_schema_events_statements_history_size = 10;

/* 最大仪表化对象数 */
ulong performance_schema_max_mutex_classes = 300;
ulong performance_schema_max_rwlock_classes = 300;
ulong performance_schema_max_table_handles = 1000;
ulong performance_schema_max_file_handles = 1000;

/* 线程类 */
ulong performance_schema_max_thread_classes = 100;
ulong performance_schema_max_thread_instances = 1000;
```

**内存占用估算**：

```
每个事件记录（PFS_events_statements）约 200 字节
events_statements_history_size = 10 条/线程
100 个线程 → 100 × 10 × 200 = 200KB

所有 P_S 组件合计（默认配置）：
~100-200MB 内存（取决于 performance_schema_max_* 参数）
```

---

## 6. 与 sys schema 集成

MySQL 的 `sys` schema 提供了一系列方便查询 Performance Schema 的视图：

```sql
-- 按 Digest（SQL 模板）统计语句延迟
SELECT * FROM sys.statement_analysis;
-- 等价于：
SELECT DIGEST, COUNT_STAR, AVG_TIMER_WAIT/1000000000 as avg_ms
FROM performance_schema.events_statements_summary_by_digest;

-- 查看锁等待
SELECT * FROM sys.innodb_lock_waits;

-- 查看 IO 热点
SELECT * FROM sys.io_global_by_file_by_bytes;
```

---

## 7. 源码索引

| 函数/结构 | 文件 | 关键作用 |
|-----------|------|---------|
| `PFS_start_statement_vc()` | `sql/pfs/pfs_events.cc` | 启动语句事件采集 |
| `PFS_end_statement_vc()` | `sql/pfs/pfs_events.cc` | 结束语句事件采集 |
| `PFS_start_wait_vc()` | `sql/pfs/pfs_events_wait.cc` | 启动等待事件采集 |
| `PFS_end_wait_vc()` | `sql/pfs/pfs_events_wait.cc` | 结束等待事件采集 |
| `PFS_engine_table` | `sql/pfs/pfs_engine.h` | P_S 内存表引擎 |
| `setup_instruments` | `sql/pfs/pfs_instr.cc` | 仪表化点配置 |
| `setup_consumers` | `sql/pfs/pfs_consumer.cc` | 消费者配置 |
