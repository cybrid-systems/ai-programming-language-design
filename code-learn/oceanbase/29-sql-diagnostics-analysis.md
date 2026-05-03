# 29 — SQL 诊断 — Plan Monitor、SQL Audit、性能分析

> 基于 OceanBase CE 主线源码
> 分析范围：`src/sql/monitor/` + `src/share/diagnosis/` + `src/observer/virtual_table/`
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

SQL 诊断基础设施是 OceanBase 可观测性的核心。它回答一个数据库运维人员最关心的问题：

> **这条 SQL 为什么慢？**

整个诊断体系从三个层面回答了这个问题：

1. **Plan Monitor（算子级监控）** — 每个物理算子执行了多久、处理了多少行、花了多少内存
2. **SQL Audit（请求级审计）** — 每条 SQL 从网络接收到执行结束的完整时间线、资源消耗、等待事件
3. **SQL Stat（累积统计）** — 同类 SQL 的历史平均值，用于趋势分析和异常检测

这三者不是分层关系，而是**不同粒度的正交观测**：

```
                SQL 执行生命周期
  ┌─────────────────────────────────────────────────────┐
  │                                                       │
  │  ┌──────────────────────────────────────────┐         │
  │  │           SQL Audit (请求级)              │         │
  │  │  时间线: net→queue→decode→get_plan→exec   │         │
  │  └──────────────────────────────────────────┘         │
  │          │                                            │
  │          ▼                                            │
  │  ┌──────────────────────────────────────────┐         │
  │  │    Plan Monitor (算子级)                  │         │
  │  │  每个算子: open→get_next_row→close         │         │
  │  │  TABLE SCAN: 40ms, 1000 rows             │         │
  │  │  HASH JOIN: 120ms, 500 rows out          │         │
  │  └──────────────────────────────────────────┘         │
  │          │                                            │
  │          ▼                                            │
  │  ┌──────────────────────────────────────────┐         │
  │  │   SQL Stat (累积统计)                     │         │
  │  │  avg_elapsed_time, executions, rpc ...   │         │
  │  └──────────────────────────────────────────┘         │
  │                                                       │
  └─────────────────────────────────────────────────────┘
```

### 源码组织结构

```
src/sql/monitor/
├── ob_phy_plan_monitor_info.h/cpp       ← 执行计划监控信息（顶层容器）
├── ob_phy_operator_monitor_info.h        ← 算子监控信息定义（指标枚举 + 存储）
├── ob_phy_operator_stats.h/cpp           ← 算子统计累加器（跨执行汇总）
├── ob_phy_plan_exec_info.h               ← 执行计划执行记录
├── ob_exec_stat.h                        ← ObExecRecord / ObAuditRecordData 核心结构
├── ob_exec_stat_collector.h/cpp          ← 监控信息收集 & 分发
├── ob_sql_stat_record.h                  ← SQL 统计记录（累积 + 快照）
├── ob_sql_stat_manager.h/cpp             ← SQL 统计管理器（内存限制 + 淘汰）
├── ob_monitor_info_manager.h/cpp         ← Plan Monitor 信息管理器（FIFO 队列）
├── ob_monitor_info_elimination_task.h    ← 监控信息淘汰定时任务
├── ob_i_collect_value.h                  ← 可收集值接口

src/share/diagnosis/
├── ob_sql_plan_monitor_node_list.h/cpp   ← Plan Monitor Node 列表（实时节点）
├── ob_sql_monitor_statname.h             ← 监控统计名称定义
├── ob_runtime_profile.h/cpp              ← 运行时 Profiling 框架

src/observer/virtual_table/
├── ob_gv_sql_audit.h/cpp                 ← gv$sql_audit 虚拟表实现
├── ob_virtual_sql_plan_monitor.h/cpp     ← v$sql_plan_monitor / gv$plan_monitor 虚拟表
```

---

## 1. 核心数据结构

诊断体系的核心数据结构分布在三个层面，承载不同粒度的观测信息。

### 1.1 ObExecRecord — 执行级统计事件记录

**文件**: `src/sql/monitor/ob_exec_stat.h` — 行 17-101

`ObExecRecord` 是诊断体系中最底层的统计记录。它通过宏 `EVENT_INFO` 定义了 26 种可观测事件，每种事件都有 `_start_` / `_end_` 快照和累计值三字段：

```cpp
struct ObExecRecord
{
  // 执行期间的最大等待事件
  common::ObWaitEventDesc max_wait_event_;

#define EVENT_INFO(def, name) \
  int64_t name##_start_; \
  int64_t name##_end_;  \
  int64_t name##_;
#include "ob_exec_stat.h"  // ← 宏展开 26 个事件
#undef EVENT_INFO

  // 记录起始快照: 从 ObDiagnosticInfo 读取当前值
  void record_start() { RECORD(start); }
  // 记录结束快照: 从 ObDiagnosticInfo 读取当前值
  void record_end()   { RECORD(end); }
  // 更新累计值: _delta = _end - _start
  void update_stat();
};
```

关键事件列表（`ob_exec_stat.h` 行 4-29）：

| 事件 | 含义 |
|------|------|
| `IO_READ_COUNT` | 物理 IO 读取次数 |
| `USER_IO_TIME` | 用户 IO 等待时间 |
| `ROW_CACHE_HIT` | 行缓存命中数 |
| `BLOCK_CACHE_HIT` | 块缓存命中数 |
| `BLOOM_FILTER_FILTS` | Bloom Filter 过滤行数 |
| `MEMSTORE_READ_ROW_COUNT` | MemTable 读取行数 |
| `SSSTORE_READ_ROW_COUNT` | SSTable 读取行数 |
| `DATA_BLOCK_READ_CNT` | 数据块读取数 |
| `BLOCKSCAN_BLOCK_CNT` | 块扫描读取块数 |
| `PUSHDOWN_STORAGE_FILTER_ROW_CNT` | 存储层下推过滤行数 |

### 1.2 ObExecTimestamp — 执行时间线

**文件**: `src/sql/monitor/ob_exec_stat.h` — 行 148-185

记录一条 SQL 请求从发出到结束的完整时间戳链：

```
rpc_send_ts → receive_ts → enter_queue_ts → run_ts
  → before_process_ts → single_process_ts → process_executor_ts
  → executor_end_ts
```

每个重试周期，`queue_t_`、`decode_t_`、`get_plan_t_` 等会累计（`update_stage_time()` 行 175-183）。

### 1.3 ObAuditRecordData — SQL Audit 记录

**文件**: `src/sql/monitor/ob_exec_stat.h` — 行 242-355

这是 `gv$sql_audit` 虚拟表的数据来源。它组合了 `ObExecTimestamp` 时间线、`ObExecRecord` 统计事件、以及业务元数据：

```cpp
struct ObAuditRecordData {
  int16_t seq_;                        // PDU 序号
  int status_;                         // 错误码
  common::ObCurTraceId::TraceId trace_id_;
  int64_t request_id_;                 // 自增请求 ID
  uint64_t session_id_;
  uint64_t qc_id_;                     // PX 查询协调器 ID
  int64_t dfo_id_;                     // PX DFO ID
  int64_t sqc_id_;                     // PX SQC ID
  int64_t tenant_id_;
  int64_t effective_tenant_id_;
  char *tenant_name_;
  int64_t user_id_;
  char *user_name_;
  char sql_id_[common::OB_MAX_SQL_ID_LENGTH + 1];
  char *sql_;                          // SQL 文本
  int64_t plan_id_;
  int64_t affected_rows_;
  int64_t return_rows_;
  int64_t partition_cnt_;
  ObPhyPlanType plan_type_;
  bool is_executor_rpc_;
  bool is_inner_sql_;
  bool is_hit_plan_cache_;
  int64_t request_memory_used_;
  ObExecTimestamp exec_timestamp_;      // 时间线
  ObExecRecord exec_record_;            // 统计事件
  // ... 更多字段
};
```

### 1.4 ObPhyPlanMonitorInfo — 执行计划监控信息容器

**文件**: `src/sql/monitor/ob_phy_plan_monitor_info.h` — 行 25-92

每个执行计划实例有一个 `ObPhyPlanMonitorInfo`，它包含：

- **`request_id_`** — 关联到请求的唯一 ID
- **`plan_id_`** — 执行计划 ID
- **`operator_infos_`** — 算子监控信息数组（`ObSEArray<ObPhyOperatorMonitorInfo, 8>`）
- **`plan_info_`** — 执行计划级执行记录（`ObPhyPlanExecInfo`）
- **`exec_trace_`** — 执行期间的 Trace 事件

```cpp
class ObPhyPlanMonitorInfo final {
  int add_operator_info(const ObPhyOperatorMonitorInfo &info);
  int64_t get_operator_count();
  int set_plan_exec_record(const ObExecRecord &exec_record);
  int set_plan_exec_timestamp(const ObExecTimestamp &exec_timestamp);
  int get_operator_info(int64_t op_id, ObPhyOperatorMonitorInfo &info);
};
```

### 1.5 ObPhyOperatorMonitorInfo — 算子监控信息

**文件**: `src/sql/monitor/ob_phy_operator_monitor_info.h` — 行 54-86

每个算子实例（如 TABLE SCAN、HASH JOIN）对应一个 `ObPhyOperatorMonitorInfo`。它使用 `info_array_`（`uint64_t` 数组）存储 10 种预定义指标：

```cpp
// 算子监控指标枚举（行 41-47）
enum ObOperatorMonitorInfoIds {
  OPEN_TIME,           // open() 耗时
  FIRST_ROW_TIME,      // 第一行输出时间
  LAST_ROW_TIME,       // 最后一行输出时间
  CLOSE_TIME,          // close() 耗时
  RESCAN_TIMES,        // 重扫描次数
  INPUT_ROW_COUNT,     // 输入行数
  OUTPUT_ROW_COUNT,    // 输出行数
  MEMORY_USED,         // 内存使用
  DISK_READ_COUNT,     // 磁盘读取次数
  MONITOR_INFO_END,    // 哨兵
};

class ObPhyOperatorMonitorInfo : public ObIValue {
  void set_value(ObOperatorMonitorInfoIds index, int64_t value);
  void get_value(ObOperatorMonitorInfoIds index, int64_t &value);
  void increase_value(ObOperatorMonitorInfoIds index);
  // ...
private:
  int64_t op_id_;
  int64_t job_id_;    // 分布式执行时的 Job ID
  int64_t task_id_;   // 分布式执行时的 Task ID
  ObPhyOperatorType op_type_;
  uint64_t info_array_[OB_MAX_INFORMATION_COUNT]; // 10 个指标
};
```

### 1.6 ObMonitorNode — Plan Monitor 实时节点

**文件**: `src/share/diagnosis/ob_sql_plan_monitor_node_list.h` — 行 67-162

`ObMonitorNode` 是 v$sql_plan_monitor 虚拟表的核心条目，为每个算子提供更丰富的实时统计：

```cpp
class ObMonitorNode {
  int64_t op_id_;
  int64_t plan_depth_;
  int64_t output_batches_;      // Batch 执行模式输出批次数
  int64_t skipped_rows_count_;  // Batch 模式跳过行数
  ObPhyOperatorType op_type_;

  // 计时信息
  int64_t open_time_;
  int64_t first_row_time_;
  int64_t last_row_time_;
  int64_t close_time_;
  int64_t rescan_times_;
  int64_t output_row_count_;

  uint64_t db_time_;      // RDTSC CPU 周期 (含指令 + IO)
  uint64_t block_time_;   // RDTSC 等待周期 (网络、IO 等)

  // 算子特有信息 (最多 10 个自定义 K-V)
  int64_t otherstat_1_value_ ~ otherstat_10_value_;
  int16_t otherstat_1_id_  ~ otherstat_10_id_;

  // Workarea 信息
  int64_t workarea_mem_;
  int64_t workarea_max_mem_;
  int64_t workarea_tempseg_;
  int64_t workarea_max_tempseg_;

  char sql_id_[common::OB_MAX_SQL_ID_LENGTH + 1];
  uint64_t plan_hash_value_;
  ObProfile *profile_;         // 运行时 Profiling 数据
};
```

### 1.7 ObExecutingSqlStatRecord / ObExecutedSqlStatRecord — 累积 SQL 统计

**文件**: `src/sql/monitor/ob_sql_stat_record.h`

统计记录使用 `start_` / `end_` 差值模式，每次 SQL 执行时记录起始快照，结束时记录结束快照，然后 delta 累加到全局 `ObExecutedSqlStatRecord`：

```
ObExecutingSqlStatRecord          ObExecutedSqlStatRecord
┌─────────────────────┐           ┌─────────────────────┐
│ elapsed_time_start_ │           │ elapsed_time_total_  │ ← 累加 delta
│ elapsed_time_end_   │──delta──→│ elapsed_time_last_   │ ← 上一次快照值
│ cpu_time_start_     │           │ executions_total_    │ ← 执行次数
│ cpu_time_end_       │──delta──→│ avg_elapsed_time_    │ ← 平均耗时
│ disk_reads_start_   │           └─────────────────────┘
│ ...                 │
└─────────────────────┘
```

---

## 2. 监控信息收集路径

一条 SQL 的执行过程和诊断信息的收集是交织进行的：

```
  ┌──────────┐     ┌─────────────┐     ┌─────────────┐     ┌────────────┐
  │  请求到达  │────→│  ObExecStat │────→│  SQL 执行    │────→│  执行结束   │
  │          │     │  Utils     │     │            │     │            │
  └──────────┘     └─────────────┘     └─────────────┘     └────────────┘
       │                │                    │                   │
       │       记录时间戳              算子执行中             最终记录
       │       receive_ts         记录算子统计           写入 SQL Audit
       │       enter_queue_ts     更新 ExecRecord      清理 Plan Monitor
       │       run_ts             增加 output_rows      累积 SQL Stat
       ▼       ...                 ...                   ▼
  ┌──────────────────────────────────────────────────────────────┐
  │                    执行上下文 (ExecContext)                     │
  │  ┌────────────────────────────────────────────┐               │
  │  │  ObAuditRecordData audit_record_           │ ← 审计记录     │
  │  │  ObPhyPlanMonitorInfo *monitor_info_       │ ← Plan Monitor│
  │  │  ObExecStatCollector stat_collector_       │ ← 统计收集     │
  │  │  ObExecutingSqlStatRecord sql_stat_        │ ← SQL 累积统计 │
  │  └────────────────────────────────────────────┘               │
  └──────────────────────────────────────────────────────────────┘
```

### 2.1 时间戳记录

**文件**: `src/sql/monitor/ob_exec_stat_collector.h` — `ObExecStatUtils::record_exec_timestamp()` (行 88-116)

在 RPC 请求处理的各个阶段，`ObExecStatUtils::record_exec_timestamp()` 被调用。它从 RPC 请求的 `process` 对象中提取时间戳：

```cpp
template <class T>
OB_INLINE static void record_exec_timestamp(const T &process,
    bool is_first, ObExecTimestamp &exec_timestamp, bool async_resp_used = false)
{
  exec_timestamp.rpc_send_ts_ = process.get_send_timestamp();
  exec_timestamp.receive_ts_ = process.get_receive_timestamp();
  exec_timestamp.enter_queue_ts_ = process.get_enqueue_timestamp();
  exec_timestamp.run_ts_ = process.get_run_timestamp();
  exec_timestamp.before_process_ts_ = process.get_process_timestamp();
  exec_timestamp.single_process_ts_ = process.get_single_process_timestamp();
  exec_timestamp.process_executor_ts_ = process.get_exec_start_timestamp();
  exec_timestamp.executor_end_ts_ = process.get_exec_end_timestamp();

  if (is_first) {
    // 首次执行才记录网络耗时
    exec_timestamp.net_t_ = receive_ts_ - rpc_send_ts_;
    exec_timestamp.net_wait_t_ = enter_queue_ts_ - receive_ts_;
  }
}
```

### 2.2 算子统计收集

**文件**: `src/sql/monitor/ob_exec_stat_collector.h/cpp`

`ObExecStatCollector` 是**序列化缓冲区**。算子在执行过程中调用 `collect_monitor_info()` 或 `collect_plan_monitor_info()`，将算子统计序列化到 `extend_buf_[10240]` 中：

```cpp
// ob_exec_stat_collector.cpp 行 61-96
int ObExecStatCollector::collect_monitor_info(uint64_t job_id,
    uint64_t task_id, ObPhyOperatorMonitorInfo &op_info)
{
  op_info.set_job_id(job_id);
  op_info.set_task_id(task_id);
  add_stat<ObPhyOperatorMonitorInfo>(&op_info);  // 序列化到缓冲区
}
```

在 DFO（分布式执行）场景下，执行调度器在 RPC 响应中带回这个缓冲区，然后在还原端调用 `ObExecStatDispatch::dispatch()` 反序列化并注册到 `ObPhyPlanMonitorInfo` 和算子统计：

```cpp
// ob_exec_stat_collector.cpp 行 103-144
int ObExecStatDispatch::dispatch(bool need_add_monitor,
    ObPhyPlanMonitorInfo *monitor_info, bool need_update_plan, ObPhysicalPlan *plan)
{
  while (OB_SUCC(ret) && OB_SUCC(get_next_type(type))) {
    switch (type) {
      case PLAN_MONITOR_INFO: {
        ObPhyOperatorMonitorInfo op_info;
        get_value<ObPhyOperatorMonitorInfo>(&op_info);
        if (need_add_monitor) {
          monitor_info->add_operator_info(op_info);  // 注册到 Plan Monitor
        }
        if (need_update_plan) {
          plan->op_stats_.add_op_stat(op_info);      // 累加到算子统计
        }
        break;
      }
    }
  }
}
```

### 2.3 ExecRecord 快照

**文件**: `src/sql/monitor/ob_exec_stat.h` — `RECORD` 宏 (行 59-83)

在算子的关键路径上会调用 `record_start()` / `record_end()`，从线程本地的 `ObDiagnosticInfo`（诊断信息管理器）中读取 26 种统计事件的当前值：

```cpp
#define RECORD(se) do {
  ObDiagnosticInfo *diag = ObLocalDiagnosticInfo::get();
  if (NULL != diag) {
    ObStatEventAddStatArray &arr = diag->get_add_stat_stats();
    io_read_count_##se##_ = EVENT_STAT_GET(arr, ObStatEventIds::IO_READ_COUNT);
    block_cache_hit_##se##_ = EVENT_STAT_GET(arr, ObStatEventIds::BLOCK_CACHE_HIT);
    // ... 26 个事件
  }
} while(0);
```

### 2.4 SQL Audit 写入

SQL 执行结束时，`ObAuditRecordData` 中的数据会经过 `ObMySQLRequestManager` 注册到 `ObMySQLGlobalRequestManager` 的**环形队列**中。这个队列就是 `gv$sql_audit` 虚拟表的数据源。

写入路径：

```
算子执行结束
     │
     ▼
ObExecContext::store_audit_record()
     │
     ▼
ObMySQLRequestManager::add_request_record()
     │  (将 ObAuditRecordData 拷贝到环形缓冲区)
     ▼
ObRaQueue (环形队列) ← 内存中的审计记录
     │
     ▼
(gv$sql_audit 虚拟表查询时从这里读取)
```

### 2.5 Plan Monitor Node 提交

**文件**: `src/share/diagnosis/ob_sql_plan_monitor_node_list.h` — `ObPlanMonitorNodeList` (行 168-227)

Plan Monitor 的实时节点通过 `ObPlanMonitorNodeList::submit_node()` 提交到环形队列 `ObRaQueue`，同时注册到 HashMap `node_map_` 中用于快速查找。

```
算子执行 → 更新 ObMonitorNode 字段
     │
     ▼
ObPlanMonitorNodeList::submit_node(node)
     │  ├── alloc_mem() 从 FIFO Allocator 分配内存
     │  ├── queue_.push() 写入环形队列
     │  └── register_monitor_node() 注册到 HashMap
     │
     ▼
ObSqlPlanMonitorRecycleTask (定时回收)
     │  └── recycle_old() 淘汰过期记录
```

---

## 3. 虚拟表查询路径

用户通过 SQL 查询诊断信息的完整路径。

### 3.1 gv$sql_audit

**文件**: `src/observer/virtual_table/ob_gv_sql_audit.h/cpp`

```sql
SELECT /*+READ_CONSISTENCY(WEAK)*/ *
FROM gv$sql_audit
WHERE tenant_id = 1002
ORDER BY elapsed_time DESC
LIMIT 10;
```

虚拟表类 `ObGvSqlAudit`（行 42-236）继承自 `ObVirtualTableScannerIterator`。查询流程：

```
查询 → ObGvSqlAudit::inner_open()
  → 解析 WHERE 条件（server_ip, server_port, tenant_id, request_id）
  → 定位到目标 Observer 节点的 ObMySQLRequestManager
  → 获取环形队列的起止索引 (start_id_ ~ end_id_)
  → ObGvSqlAudit::inner_get_next_row()
     → 循环读取 cur_id_ 递增
     → cur_mysql_req_mgr_->get(cur_id_, cur_record_)
     → fill_cells() 将 ObAuditRecordData 的字段填充到行
     → 返回一行

  → 输出字段（枚举在 ob_gv_sql_audit.h 行 69-194）：
    SVR_IP, SVR_PORT, TENANT_ID, REQUEST_ID, TRACE_ID,
    CLIENT_IP, CLIENT_PORT, USER_NAME, DB_NAME, SQL_ID,
    QUERY_SQL, PLAN_ID, PLAN_TYPE,
    AFFECTED_ROWS, RETURN_ROWS, RET_CODE,
    QC_ID, DFO_ID, SQC_ID, WORKER_ID,
    IS_INNER_SQL, IS_HIT_PLAN, IS_EXECUTOR_RPC,
    REQUEST_TIMESTAMP, ELAPSED_TIME, NET_TIME, QUEUE_TIME,
    DECODE_TIME, GET_PLAN_TIME, EXECUTE_TIME,
    APPLICATION_WAIT_TIME, CONCURRENCY_WAIT_TIME, USER_IO_WAIT_TIME,
    SCHEDULE_TIME, ROW_CACHE_HIT, BLOCK_CACHE_HIT, DISK_READS,
    MEMSTORE_READ_ROW_COUNT, SSSTORE_READ_ROW_COUNT,
    DATA_BLOCK_READ_CNT, DATA_BLOCK_CACHE_HIT,
    PARAMS_VALUE, TRANS_ID, SNAPSHOT_VERSION, ...
```

`fill_cells()`（行 61）将 `ObAuditRecordData` 的每个字段映射到虚拟表的列。`ObGvSqlAudit` 支持索引扫描模式（`use_index_scan`/`is_index_scan`，行 54-55）来加速基于 `(tenant_id, request_id)` 的查询。

### 3.2 v$sql_plan_monitor / gv$plan_monitor

**文件**: `src/observer/virtual_table/ob_virtual_sql_plan_monitor.h/cpp`

```sql
SELECT *
FROM v$sql_plan_monitor
WHERE tenant_id = 1002 AND request_id = 123
ORDER BY plan_line_id;
```

虚拟表类 `ObVirtualSqlPlanMonitor`（行 37-155）的查询流程：

```
查询 → ObVirtualSqlPlanMonitor::inner_open()
  → 解析 WHERE 条件
  → 定位到目标 Observer 节点的 ObPlanMonitorNodeList
  → 遍历环形队列中的 ObMonitorNode 记录

 → ObVirtualSqlPlanMonitor::inner_get_next_row()
    → switch_tenant_monitor_node_list() 切换到当前租户的 NodeList
    → convert_node_to_row() 将 ObMonitorNode 填充到行
    → report_rt_monitor_node() 首次解析 Profile（RAW_PROFILE 字段）

  → 输出字段（枚举在 ob_virtual_sql_plan_monitor.h 行 70-117）：
    SVR_IP, SVR_PORT, TENANT_ID, REQUEST_ID, TRACE_ID,
    FIRST_REFRESH_TIME, LAST_REFRESH_TIME,
    FIRST_CHANGE_TIME, LAST_CHANGE_TIME,
    OTHERSTAT_1_ID ~ OTHERSTAT_10_ID,
    OTHERSTAT_1_VALUE ~ OTHERSTAT_10_VALUE,
    THREAD_ID, PLAN_OPERATION, STARTS,
    OUTPUT_ROWS, PLAN_LINE_ID, PLAN_DEPTH,
    OUTPUT_BATCHES, SKIPPED_ROWS_COUNT,
    DB_TIME, USER_IO_WAIT_TIME,
    WORKAREA_MEM, WORKAREA_MAX_MEM,
    WORKAREA_TEMPSEG, WORKAREA_MAX_TEMPSEG,
    SQL_ID, PLAN_HASH_VALUE, RAW_PROFILE
```

`convert_node_to_row()` 是整个诊断体系中字段映射最密集的函数之一，将 `ObMonitorNode` 的三十多个字段映射到虚拟表的列。

### 3.3 分布式查询串联

当用户查询 `gv$`（全局视图）时，OceanBase 使用 **Virtual Table 代理机制**：

```
用户 OBS
  │
  │  SELECT * FROM gv$sql_audit
  │  WHERE tenant_id = 1002
  ▼
ObGvSqlAudit（本地节点）
  │
  │  set_ip() / set_addr() — 设置要查询的目标节点
  ▼
ObMCTSLink / ObDirectLink — 发起到远程 Observer 的 RPC
  │
  ▼
远程 Observer 上的 ObGvSqlAudit
  │  读取本地的 ObMySQLRequestManager
  │  返回结果
```

**关键设计点**：虚拟表的 `inner_open()` 在开启扫描时，会通过 `extract_tenant_ids()`（行 62）从 WHERE 条件中提取 tenant_id，然后通过 `obrpc::ObRpcProxy` 串联到所有相关节点，最终在多个节点上并行执行 `inner_get_next_row()`。

---

## 4. 诊断数据流全景

```
                      SQL 请求从客户端到达
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│              ObMPQuery / ObMPHandle (协议层)                     │
│  ObExecStatUtils::record_exec_timestamp() — 记录网络时间戳      │
│  创建 ObExecContext                                             │
└─────────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                  SQL 执行引擎                                     │
│                                                                 │
│  ┌──────────────────────────────────────────────────────┐       │
│  │  执行计划打开 (plan root open)                        │       │
│  │  → 创建 ObPhyPlanMonitorInfo                          │       │
│  │  → 注册到 ObMonitorInfoManager                        │       │
│  │  → 每个算子创建 ObMonitorNode                          │       │
│  │  → 记录 open_time_                                    │       │
│  └──────────────────────────────────────────────────────┘       │
│                                                                 │
│  ┌──────────────────────────────────────────────────────┐       │
│  │  算子逐行执行 (get_next_row loop)                    │       │
│  │  → 每行更新 input_row_count_ / output_row_count_     │       │
│  │  → 更新 first_row_time_ (第一行)                      │       │
│  │  → 更新 last_row_time_ (每行)                         │       │
│  │  → 更新 ObExecRecord 快照 (cache hit, IO count, ...) │       │
│  │  → 更新 workarea_mem_ (内存算子)                      │       │
│  │  → 更新 otherstat_ (算子特有统计)                     │       │
│  │  → 计算 db_time_ / block_time_ (RDTSC)                │       │
│  └──────────────────────────────────────────────────────┘       │
│                                                                 │
│  ┌──────────────────────────────────────────────────────┐       │
│  │  执行计划关闭 (plan root close)                       │       │
│  │  → 记录 close_time_                                  │       │
│  │  → ObExecStatCollector::collect_plan_monitor_info()   │       │
│  │  → 序列化所有算子统计到缓冲区                        │       │
│  │  → 写入 ObAuditRecordData                             │       │
│  └──────────────────────────────────────────────────────┘       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                             │
         ┌───────────────────┼──────────────────────┐
         ▼                   ▼                      ▼
┌─────────────────┐ ┌──────────────┐ ┌──────────────────────┐
│ SQL Audit 写入   │ │ Plan Monitor  │ │ SQL Stat 累积         │
│                 │ │ 节点提交       │ │                      │
│ add_request_    │ │ submit_node() │ │ sum_stat_value()     │
│ record()        │ │               │ │ → 累加到              │
│ → ObRaQueue     │ │ → ObRaQueue  │ │   ObExecutedSqlStat   │
│ → 内存环形队列   │ │ → node_map_  │ │   Record              │
└─────────────────┘ └──────────────┘ └──────────────────────┘
         │                   │                   │
         ▼                   ▼                   ▼
┌─────────────────┐ ┌──────────────┐ ┌──────────────────────┐
│ 用户查询         │ │ 用户查询      │ │ 用户查询              │
│ gv$sql_audit    │ │ v$sql_plan_  │ │ __all_virtual_sql_   │
│ → ObGvSqlAudit │ │ monitor      │ │ stat                 │
│ → fill_cells   │ │ → convert_   │ │ → ObSqlStatManager   │
│ → 逐行返回      │ │   node_to_   │ │ → foreach_sql_stat_  │
│                │ │   row        │ │   record()            │
│                │ │ → 逐行返回    │ │ → 逐行返回            │
└─────────────────┘ └──────────────┘ └──────────────────────┘
```

### 4.1 PX 分布式执行流的诊断

在 PX（并行执行）场景下，诊断信息的流向略有不同：

```
QC (Query Coordinator)
  │
  │  DFO 分发给 SQC → Worker
  │
  ├── Worker 1 执行算子
  │   │  → 本地收集 ObPhyOperatorMonitorInfo
  │   │  → 序列化到 ObExecStatCollector::extend_buf_
  │   │  → RPC 响应带回 QC
  │   ▼
  ├── Worker 2 执行算子
  │   │  → 同上
  │
  │  QC 收到所有 Worker 响应
  │  → ObExecStatDispatch::dispatch() 反序列化
  │  → register_monitor_node() 注册到 QC 的 NodeList
  │  → 合并所有 Worker 统计到 Plan Monitor
  ▼
  用户查询 gv$plan_monitor 看到完整信息
```

---

## 5. 内存管理 & 淘汰策略

诊断信息本质上是**内存中的临时数据**。OceanBase 需要控制其内存开销，防止诊断信息反噬生产性能。

### 5.1 SQL Audit 的环形队列

`ObMySQLGlobalRequestManager` 使用 `ObRaQueue`（Ring-Array Queue）存储审计记录。

- **固定容量**: 每个租户可配置
- **淘汰方式**: 新记录插入时，如果队列已满，自动覆盖最旧的记录
- **无锁设计**: `ObRaQueue` 使用 CAS 操作实现无锁生产和消费

### 5.2 SQL Stat 的内存管理和淘汰

**文件**: `src/sql/monitor/ob_sql_stat_manager.h` — 行 110-198

`ObSqlStatManager` 管理 `ObExecutedSqlStatRecord` 的 HashMap（`ObSqlStatInfoHashMap`）。它有三种内存水位：

```cpp
class ObSqlStatManager {
  constexpr static int64_t MEMORY_LIMIT_DEFAULT = 1;       // 内存限制比例 (占租户内存的 1%)
  constexpr static int64_t MEMORY_EVICT_HIGH_DEFAULT = 80; // 高水位 80%
  constexpr static int64_t MEMORY_EVICT_LOW_DEFAULT = 30;  // 低水位 30%
  // ...
};
```

淘汰流程：

```
check_if_need_evict()
  │  检查已用内存是否超过 MEMORY_LIMIT x MEMORY_EVICT_HIGH
  │  如果超过 → 计算需要释放的数量
  ▼
do_evict()
  │  ObSqlStatEvictOp — 遍历所有 SQL 统计记录
  │  → 找到最近活跃时间最旧的记录
  │  → 批量删除直到内存降到低水位
  │  → 释放对应的内存和 LinkHashNode
```

`ObSqlStatTask`（行 28-31）是一个定时任务，每隔 60 秒自动执行淘汰检查：

```cpp
class ObSqlStatTask : public common::ObTimerTask {
  virtual void runTimerTask() override;
  constexpr static int64_t REFRESH_INTERVAL = 1 * 60 * 1000L * 1000L; // 60s
};
```

### 5.3 Plan Monitor 的内存管理

**文件**: `src/share/diagnosis/ob_sql_plan_monitor_node_list.h` — 行 145-227

`ObPlanMonitorNodeList` 的淘汰策略：

- **Page Size**: `MONITOR_NODE_PAGE_SIZE = 128KB`
- **回收阈值**: `recycle_threshold_` — 队列长度超过此值开始回收
- **批次释放**: `batch_release_` — 每次回收一批记录
- **Profile 回收**: `profile_recycle_threshold_` — RAW_PROFILE 内存达到阈值开始回收

`ObSqlPlanMonitorRecycleTask`（行 164-175）是定时回收任务：

```cpp
class ObSqlPlanMonitorRecycleTask : public common::ObTimerTask {
  void runTimerTask() {
    if (node_list_->get_size_used() > node_list_->recycle_threshold_) {
      node_list_->recycle_old(node_list_->batch_release_);
    }
  }
};
```

---

## 6. 设计决策

### 6.1 为什么需要 SQL Audit + Plan Monitor 两套体系？

| 维度 | SQL Audit (gv$sql_audit) | Plan Monitor (v$plan_monitor) |
|------|--------------------------|-------------------------------|
| 粒度 | 请求级（一行 = 一条 SQL） | 算子级（一行 = 一个算子） |
| 字段数 | ~80 个字段 | ~40 个字段 |
| 数据量 | 一个 SQL → 一行 | 一个 SQL → 多个算子行 |
| 时间信息 | 端到端时间线 (net→queue→exec) | 算子内部时间 (open→first→close) |
| IO 统计 | 汇总值 | 无（通过 OtherStat 间接报告） |
| 等待事件 | 详细 wait event 信息 | 无 |
| 唯一标识 | request_id | request_id + plan_line_id |
| 保留时间 | 环形队列覆盖 (通常秒级) | 环形队列覆盖 (通常秒级) |

**决策逻辑**：
- **SQL Audit** 适用于"全量快照"场景：快速找到慢 SQL，定位哪个阶段的耗时最长（网络？排队？解析？执行？）
- **Plan Monitor** 适用于"根因定位"场景：已知慢 SQL 后，进一步分析哪个算子消耗了最多时间

两者互补。通常 DBA 的使用路径是：

```
发现慢查询 → 查 gv$sql_audit 找到 ELAPSED_TIME 最大的 SQL
  → 记录 request_id
  → 查 gv$plan_monitor WHERE request_id = ?
  → 找到最耗时的算子 (如 HASH JOIN 的 db_time 最大)
  → 分析算子统计细节，决定如何优化 SQL
```

### 6.2 为什么不用异步日志？

所有诊断信息都存储在**内存环形队列**中而不是持久化到磁盘：

- **性能**：异步日志写入会增加 IO 开销，环形队列是无锁内存操作
- **覆盖语义**：重要的慢查询自然会在队列中保留更久（快的查询产生的行很快被覆盖）
- **开启成本**：SQL Audit 默认开启，无额外配置。如果写入磁盘，默认开启会对所有 Observer 节点造成持续的 IO 负载

代价是**查询实时诊断信息有时限性**：队列通常只能保存数秒钟到数分钟的历史记录（取决于 QPS 和队列大小）。

### 6.3 诊断信息的性能开销

监控信息的收集主要在三个层面产生开销：

| 操作 | 开销类型 | 规模 |
|------|----------|------|
| `ObExecRecord::record_start/end` | 从线程本地 `ObDiagnosticInfo` 读取 26 个计数器 | 纳秒级 |
| `ObPhyOperatorMonitorInfo::set_value` | 写一个 `uint64_t` 数组 | ~1ns |
| `ObExecStatCollector::collect_monitor_info` | 序列化到缓冲区 + 拷贝 | ~100ns |
| `ObMonitorNode` 字段更新 | 字段赋值 | ~1ns 每个字段 |
| `ObPlanMonitorNodeList::submit_node` | 分配内存 + 环形队列 push + HashMap 插入 | ~1μs |
| `ObMySQLRequestManager::add_request_record` | 拷贝 `ObAuditRecordData` (~2KB) 到环形队列 | ~2μs |

OceanBase 的设计原则是：**监控信息收集本身不应成为性能瓶颈**。所有开销都在微秒级，对毫秒级的 SQL 执行来说几乎是零成本。

### 6.4 虚拟表设计模式

诊断虚拟表（`ObGvSqlAudit`、`ObVirtualSqlPlanMonitor`）遵循统一的设计模式：

```
class ObVTable : public ObVirtualTableScannerIterator {
  // 扫描模式
  bool use_index_scan();       // 是否使用索引扫描
  bool is_index_scan();        // 当前是否正在索引扫描
  
  // 多节点支持
  void set_addr(ObAddr addr);  // 设置目标节点
  void set_ip();               // 设置 IP 字符串
  
  // 列过滤
  bool enable_pd_filter();     // 是否启用谓词下推过滤
  bool fill_full_columns();    // 是否填充所有列
  
  // 租户过滤
  int extract_tenant_ids();    // 从 WHERE 条件提取 tenant_id
  int extract_request_ids();   // 从 WHERE 条件提取 request_id
};
```

这个模式的关键设计点：

1. **谓词下推**：`use_index_scan()` 和 `enable_pd_filter()` 让虚拟表在扫描阶段就能跳过不符合条件的记录，避免全量扫描大幅消耗内存带宽
2. **多租户隔离**：`extract_tenant_ids()` 确保 sys 租户可以看所有租户的数据，普通租户只能看自己的
3. **转发透明**：`set_addr()`/`set_ip()` 让虚拟表可以转发到远程节点，实现 `gv$` 的分布式查询

---

## 7. 源码索引

### 7.1 核心数据结构

| 文件 | 关键类/结构体 | 行号 | 说明 |
|------|-------------|------|------|
| `src/sql/monitor/ob_exec_stat.h` | `ObExecRecord` | 17-101 | 执行级 26 种统计事件记录 |
| `src/sql/monitor/ob_exec_stat.h` | `ObExecTimestamp` | 148-185 | 请求时间线（9 个时间戳） |
| `src/sql/monitor/ob_exec_stat.h` | `ObAuditRecordData` | 242-355 | SQL Audit 审计记录（80+ 字段） |
| `src/sql/monitor/ob_phy_plan_monitor_info.h` | `ObPhyPlanMonitorInfo` | 25-92 | Plan Monitor 顶层容器 |
| `src/sql/monitor/ob_phy_operator_monitor_info.h` | `ObPhyOperatorMonitorInfo` | 54-86 | 算子监控信息（10 个指标） |
| `src/sql/monitor/ob_phy_operator_stats.h` | `ObPhyOperatorStats` | 41-67 | 算子统计跨执行累加器 |
| `src/sql/monitor/ob_sql_stat_record.h` | `ObExecutingSqlStatRecord` | 72-156 | 单次执行的 SQL 统计 |
| `src/sql/monitor/ob_sql_stat_record.h` | `ObExecutedSqlStatRecord` | 162-300 | 累积 SQL 统计（26 个 total） |
| `src/share/diagnosis/ob_sql_plan_monitor_node_list.h` | `ObMonitorNode` | 67-162 | Plan Monitor 实时节点结构 |
| `src/share/diagnosis/ob_sql_plan_monitor_node_list.h` | `ObPlanMonitorNodeList` | 168-227 | Plan Monitor 节点列表 |

### 7.2 监控信息收集

| 文件 | 关键类/函数 | 行号 | 说明 |
|------|------------|------|------|
| `src/sql/monitor/ob_exec_stat_collector.h` | `ObExecStatCollector` | 36-59 | 算子统计序列化收集器 |
| `src/sql/monitor/ob_exec_stat_collector.h` | `ObExecStatDispatch` | 62-80 | 算子统计反序列化分发器 |
| `src/sql/monitor/ob_exec_stat_collector.h` | `ObExecStatUtils::record_exec_timestamp()` | 88-116 | 记录时间戳 |
| `src/sql/monitor/ob_exec_stat_collector.cpp` | `collect_plan_monitor_info()` | 61-96 | collect 实现 |
| `src/sql/monitor/ob_exec_stat_collector.cpp` | `ObExecStatDispatch::dispatch()` | 103-144 | dispatch 实现 |
| `src/sql/monitor/ob_phy_plan_monitor_info.cpp` | `add_operator_info()` | 26-28 | 添加算子信息 |
| `src/sql/monitor/ob_phy_plan_monitor_info.cpp` | `set_plan_exec_record()` | 56-58 | 设置执行记录 |

### 7.3 虚拟表实现

| 文件 | 关键类 | 行号 | 说明 |
|------|--------|------|------|
| `src/observer/virtual_table/ob_gv_sql_audit.h` | `ObGvSqlAudit` | 42-236 | `gv$sql_audit` 虚拟表 |
| `src/observer/virtual_table/ob_gv_sql_audit.h` | SQL Audit 列枚举 | 69-194 | 全部 80+ 列定义 |
| `src/observer/virtual_table/ob_virtual_sql_plan_monitor.h` | `ObVirtualSqlPlanMonitor` | 37-155 | `v$sql_plan_monitor` 虚拟表 |
| `src/observer/virtual_table/ob_virtual_sql_plan_monitor.h` | Plan Monitor 列枚举 | 70-117 | 全部 40+ 列定义 |

### 7.4 管理 & 淘汰

| 文件 | 关键类 | 行号 | 说明 |
|------|--------|------|------|
| `src/sql/monitor/ob_sql_stat_manager.h` | `ObSqlStatManager` | 110-198 | SQL 统计管理器 |
| `src/sql/monitor/ob_sql_stat_manager.h` | `ObSqlStatEvictOp` | 190-198 | 统计淘汰算子 |
| `src/sql/monitor/ob_sql_stat_manager.h` | `ObSqlStatTask` | 28-31 | 定时淘汰任务（60s 间隔） |
| `src/sql/monitor/ob_monitor_info_manager.h` | `ObMonitorInfoManager` | 61-98 | Plan Monitor 信息管理器 |
| `src/share/diagnosis/ob_sql_plan_monitor_node_list.h` | `ObSqlPlanMonitorRecycleTask` | 164-175 | Plan Monitor 回收任务 |

---

## 8. 常见问题分析

### 问题 1: 如何找到最慢的 SQL？

```sql
SELECT request_id, tenant_id, user_name, sql_id,
       query_sql, elapsed_time, queue_time, execute_time,
       get_plan_time, row_cache_hit, block_cache_hit,
       memstore_read_row_count, ssstore_read_row_count
FROM gv$sql_audit
WHERE tenant_id = 1002
ORDER BY elapsed_time DESC
LIMIT 20;
```

### 问题 2: 已知慢 SQL 的 request_id = 123，如何定位瓶颈算子？

```sql
SELECT *
FROM gv$plan_monitor
WHERE tenant_id = 1002 AND request_id = 123
ORDER BY db_time DESC;
```

`db_time` 最大的算子就是最耗时的算子。结合 `PLAN_OPERATION` 字段可以判断是该 TABLE SCAN 慢，还是 JOIN 慢。

### 问题 3: 如何判断是网络还是排队的问题？

gv$sql_audit 的 `NET_TIME`, `QUEUE_TIME`, `DECODE_TIME`, `EXECUTE_TIME` 字段：

- `NET_TIME` 大 → 客户端到 OB 的网络延迟
- `QUEUE_TIME` 大 → 工作线程池排队
- `DECODE_TIME` 大 → SQL 解析耗时
- `GET_PLAN_TIME` 大 → 走硬解析或 plan cache miss
- `EXECUTE_TIME` 大 → 真正执行慢（需要进一步查 plan_monitor）

---

*本文基于 OceanBase CE 主线源码分析，doom-lsp 用于符号解析和结构确认。所有行号以源码对应 commit 为准。*
