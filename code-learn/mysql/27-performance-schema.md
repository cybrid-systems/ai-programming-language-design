# 27. MySQL Performance Schema

> 本文分析 MySQL Performance Schema 的结构化设计，包括事件收集层、摘要统计、内存管理、线程级追踪和配置接口。核心文件：`storage/perfschema/`。

---

## 1. 概述

Performance Schema (PFS) 是 MySQL 内置的性能监控框架。它通过在关键路径插入检测点，收集等待事件、语句事件、阶段事件和内存使用等细粒度信息。PFS 基于**预分配内存缓冲区**实现，不涉及系统表 I/O，对 OLTP 性能影响极小。

| 层次 | 说明 |
|------|------|
| 消费者（Consumer） | `setup_consumers` 控制是否收集事件 |
| 仪器（Instrument） | `setup_instruments` 控制哪些检测点启用 |
| 摘要（Summary） | 按 thread/account/user/host/file/table 等维度聚合 |
| 实例（Instance） | wait/statement/stage 的当前实例表 |

---

## 2. 核心对象结构

PFS 使用以下核心类层次：

```
PFS_thread            — 线程级事件上下文
PFS_account           — 账户级统计（pfs_account.h:67）
PFS_user              — 用户级统计（pfs_user.h）
PFS_host              — 主机级统计（pfs_host.h）
PFS_events_waits      — 等待事件记录
PFS_statement         — 语句事件记录
PFS_table_share       — 表共享信息
PFS_digest            — 语句摘要（归一化 SQL）
```

### 2.1 `PFS_account`

```cpp
// pfs_account.h:67
struct PFS_ALIGNED PFS_account : PFS_connection_slice {
  PFS_thread *m_threads;        // 该 account 下的线程列表
  // 等待事件摘要
  PFS_events_waits_summary *m_events_waits_summary;
  // 语句事件摘要
  PFS_events_statements_summary *m_events_statements_summary;
};
```

### 2.2 缓冲容器

```cpp
// pfs_buffer_container.h:87
template <typename T, size_t N, typename U>
class PFS_buffer_default_array {
  T *m_array[N];                // 固定大小数组
  size_t m_size;                // 已用元素数
};

// pfs_buffer_container.h:231
class PFS_buffer_scalable_container {
  // 支持动态增长的分区容器（按 64 分区）
};
```

---

## 3. 事件收集路径

### 3.1 等待事件

```
THD 执行 SQL → 触发检测点
  → pfs_start_waits_v1()          # 构造等待事件
  → 执行加锁/IO 操作
  → pfs_end_waits_v1()            # 结束等待，记录耗时
  → 写入 events_waits_current 环形缓冲区
  → 更新 PFS_events_waits_summary_by_thread_by_event_name
```

### 3.2 语句事件

```
dispatch_command()
  → thd->set_query(query_text)       # 设置当前查询
  → pfs_start_statement_vc()         # 开始语句事件
  → 执行 SQL（JOIN / 写入 / 返回结果）
  → pfs_end_statement_vc()           # 结束语句事件
  → 写入 events_statements_current
  → 更新 PFS_events_statements_summary_by_digest
```

### 3.3 阶段事件

```
pfs_start_statement_vc() 之后：
  → thd->enter_stage(stage_name)
  → pfs_start_stage_v1()
  → thd->exit_stage()
  → pfs_end_stage_v1()
```

---

## 4. 语句摘要

```cpp
// digest.h — PFS_digest
class PFS_digest {
  // MD5 归一化的 SQL 摘要
  // 合并参数化后的"模板"SQL

  ulonglong m_count;            // 执行次数
  ulonglong m_total_latency;    // 总延迟
  ulonglong m_lock_time;        // 锁时间
  ulonglong m_rows_sent;        // 发送行数
  ulonglong m_rows_examined;    // 扫描行数
};
```

语句摘要通过 `events_statements_summary_by_digest` 表查看：

```sql
SELECT DIGEST_TEXT, COUNT_STAR, SUM_TIMER_WAIT
FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_TIMER_WAIT DESC LIMIT 10;
```

---

## 5. PFS 配置接口

```sql
-- 启用等待事件收集
UPDATE setup_consumers SET ENABLED='YES'
WHERE NAME='events_waits_current';

-- 启用锁等待检测
UPDATE setup_instruments SET ENABLED='YES'
WHERE NAME LIKE 'wait/synch/mutex/innodb/%';

-- 设置事件历史表行数
SET GLOBAL performance_schema_events_waits_history_long_size = 10000;
```

| 配置变量 | 默认值 | 说明 |
|----------|--------|------|
| `performance_schema` | ON | 是否启用 PFS |
| `performance_schema_max_thread_instances` | 自动 | 最大线程监控数 |
| `performance_schema_max_statement_classes` | 222 | 最大语句类数量 |
| `performance_schema_events_waits_history_size` | 10 | 每个线程的历史事件数 |
| `performance_schema_events_waits_history_long_size` | 10000 | 全局历史表大小 |

---

## 6. 内存使用

PFS 内存预先分配（启动时确定），运行时不会动态扩容：

| 维度 | 内存 |
|------|------|
| Thread 实例 | `max_thread_instances × sizeof(PFS_thread)` |
| 等待事件历史 | `history_size × max_thread_instances × sizeof(PFS_events_waits)` |
| 摘要统计 | `max_digest_instances × sizeof(PFS_digest)` |

---

## 7. 总结

1. **零系统表开销**：预分配内存缓冲区，运行时不涉及任何 I/O。
2. **消费者/仪器分离**：`setup_consumers` 控制事件是否记录，`setup_instruments` 控制检测点粒度。
3. **环形缓冲区**：`events_waits_current` 循环覆盖，确保不会耗尽内存。
4. **多维度摘要**：支持 thread / account / user / host / digest 多维聚合，便于性能分析。
5. **归一化摘要**：`PFS_digest` 的 MD5 摘要去除了字面量和参数，聚合"相似"查询。

### 源码引用汇总

| 文件 | 行号 | 关键内容 |
|------|------|----------|
| `pfs_account.h` | 67 | `struct PFS_account` |
| `pfs_buffer_container.h` | 87 | `class PFS_buffer_default_array` |
| `pfs_buffer_container.h` | 231 | `class PFS_buffer_scalable_container` |
