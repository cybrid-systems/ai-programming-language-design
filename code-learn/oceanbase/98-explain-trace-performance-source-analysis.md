# 98-explain-trace — OceanBase Explain / 慢查询 / SQL Trace / 性能分析深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码（`src/sql/monitor/` **27 文件** + `src/observer/virtual_table/` 多个 explain/trace 类 + `src/sql/executor/` 多个执行类）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **Explain / 慢查询 / SQL Trace / 性能分析** 体系是整个 observer 集群"SQL 可观测性"的核心 —— 把每条 SQL 的执行细节（计划 / 性能 / 错误）记录下来，供 DBA / OCP / 慢查询分析。OB 5.x 的性能分析建立在 `ObPhyPlanMonitorInfo` + `ObExecStat` + `ObMonitorInfoManager` + `ObSecurityAudit` 之上，是 OB 自研的 SQL 监控框架。

本文聚焦 8 个核心问题：

1. **性能分析全景** —— 27+ 文件
2. **ObPhyPlanMonitorInfo** —— plan 监控核心
3. **ObExecStat / ObExecStatCollector** —— 执行统计
4. **ObPhyPlanExecInfo** —— plan 执行信息
5. **ObPhyOperatorMonitorInfo** —— 算子监控
6. **ObMonitorInfoManager** —— 监控信息管理
7. **ObSecurityAudit** —— 安全审计
8. **EXPLAIN / 慢查询 / Trace 虚拟表**

### 与前面文章的关系

| 文章 | 关联点 |
|------|--------|
| 17 / 95 Query Optimizer | 优化器生成 plan + 监控 |
| 18 / 94 Index System | 索引使用统计（monitor） |
| 22 Plan Cache | Plan Cache 监控（参见 #96） |
| 29 Slow Query | 慢查询分析（参见 #29） |
| 60 Profiling | Profiling（参见 #60） |
| 70 SQL Audit | 审计（参见 #70） |
| 84 Virtual Table | 监控虚拟表（参见 #84） |
| 95 Query Optimizer CBO | Optimizer 监控 |

---

## 1. 整体架构：性能分析 5 层

### 1.1 模块组成（27 文件）

```bash
$ ls src/sql/monitor/ | wc -l
27

# SQL 监控
src/sql/monitor/
├── ob_audit_action_type.h                    # 审计 action 类型
├── ob_exec_stat.h                            # 执行统计基类
├── ob_exec_stat_collector.{h,cpp}             # 执行统计收集器
├── ob_i_collect_value.h                      # collect value 接口
├── ob_monitor_info_elimination_task.{h,cpp}  # 监控信息淘汰任务
├── ob_monitor_info_manager.{h,cpp}           # 监控信息管理
├── ob_phy_operator_monitor_info.{h,cpp}       # 算子监控信息
├── ob_phy_operator_stats.{h,cpp}              # 算子统计
├── ob_phy_plan_exec_info.{h,cpp}              # plan 执行信息
├── ob_phy_plan_monitor_info.{h,cpp}           # plan 监控信息
├── ob_plan_info_manager.{h,cpp}               # plan info 管理
├── ob_security_audit.h                       # 安全审计
├── ob_security_audit_utils.h                 # 审计工具
├── ob_security_audit_utils_os.cpp             # 审计工具 OS 实现
├── ob_sql_plan.h                              # SQL plan
├── ob_sql_plan.cpp                            # SQL plan 实现
└── # ... 10+ 其他

# Plan Cache explain
src/sql/plan_cache/ob_plan_cache_plan_explain.{h,cpp}  # plan cache plan explain

# Executor 相关
src/sql/executor/ob_cmd_executor.{h,cpp}        # 命令执行
src/sql/executor/ob_cmd_executor.h
src/sql/executor/ob_direct_receive_op.{h,cpp}  # direct receive op
src/sql/executor/ob_direct_receive_op.h
src/sql/executor/ob_direct_transmit_op.{h,cpp}  # direct transmit op
src/sql/executor/ob_direct_transmit_op.h
src/sql/executor/ob_execute_result.{h,cpp}     # execute result
src/sql/executor/ob_execute_result.h
src/sql/executor/ob_execution_id.{h,cpp}        # execution id

# Virtual Table explain / trace
src/observer/virtual_table/
├── ob_all_virtual_tracepoint_info.{h,cpp}    # tracepoint info
├── ob_all_virtual_tracepoint_info.h
├── ob_plan_cache_plan_explain.{h,cpp}         # plan cache plan explain
├── ob_plan_cache_plan_explain.h
├── ob_virtual_show_trace.{h,cpp}               # show trace
└── ob_virtual_show_trace.h

# Diagnosis / Explain Stmt
src/share/diagnosis/ob_sql_plan_monitor_node_list.h  # 诊断
src/sql/resolver/ddl/ob_explain_stmt.h            # EXPLAIN stmt
src/sql/resolver/ddl/ob_explain_resolver.h      # EXPLAIN resolver
src/sql/optimizer/ob_explain_log_plan.{h,cpp}    # EXPLAIN log plan
src/sql/optimizer/ob_explain_note.h              # EXPLAIN note
```

### 1.2 5 层架构

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: EXPLAIN (用户接口)                                      │
│  - EXPLAIN SELECT ... 解析                                       │
│  - ObExplainStmt → ObExplainResolver → ObExplainLogPlan        │
│  - 输出执行计划给用户                                            │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: 监控信息 (Monitor Info)                                  │
│  - ObPhyPlanMonitorInfo (执行监控)                              │
│  - ObPhyPlanExecInfo (执行信息)                                  │
│  - ObPhyOperatorMonitorInfo (算子监控)                            │
│  - ObPhyOperatorStats (算子统计)                                  │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: 执行统计 (Exec Stat)                                    │
│  - ObExecStat (执行统计基类)                                    │
│  - ObExecStatCollector (收集器)                                  │
│  - 收集 rows / affected_rows / time 等                          │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 4: 监控管理 (Monitor Manager)                             │
│  - ObMonitorInfoManager (监控信息管理)                          │
│  - ObMonitorInfoEliminationTask (淘汰任务)                      │
│  - ObPlanInfoManager (plan info 管理)                            │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 5: 审计 + 持久化                                            │
│  - ObSecurityAudit (安全审计)                                     │
│  - ObAuditActionType (审计 action 类型)                          │
│  - 持久化到 __all_virtual_* 等虚拟表（参见 #84）                │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. ObPhyPlanMonitorInfo —— plan 监控核心

### 2.1 类骨架（实读自 `ob_phy_plan_monitor_info.h`）

```cpp
// src/sql/monitor/ob_phy_plan_monitor_info.h
namespace oceanbase {
namespace sql {

class ObPhyPlanMonitorInfo final {
public:
  OB_UNIS_VERSION(1);
public:
  const static int OPERATOR_LOCAL_COUNT = 8;
  explicit ObPhyPlanMonitorInfo(common::ObConcurrentFIFOAllocator &allocator);
  virtual void destroy() {
    reset();
    allocator_.free(this);
  }
  void reset() {
    operator_infos_.reset();
  }

  int add_operator_info(const ObPhyOperatorMonitorInfo &info);
  int64_t get_operator_count() { return operator_infos_.count(); }
  int set_plan_exec_record(const ObExecRecord &exec_record);
  int set_plan_exec_timestamp(const ObExecTimestamp &exec_timestamp);
  int get_operator_info(int64_t op_id, ObPhyOperatorMonitorInfo &info) const;
  int get_operator_info_by_index(int64_t index, ObPhyOperatorMonitorInfo *&info);
  int get_plan_info(ObPhyPlanExecInfo *&info) {
    info = &plan_info_;
    return common::OB_SUCCESS;
  }
  int set_trace(const common::ObTraceEventRecorder &trace) {
    return exec_trace_.assign(trace);
  }
  const common::ObTraceEventRecorder &get_trace() const { return exec_trace_; }
  int64_t to_string(char *buf, int64_t buf_len) const {
    int64_t pos = 0;
    J_OBJ_START();
    // ... 序列化
  }
  // ...
};
}  // namespace sql
}  // namespace oceanbase
```

### 2.2 关键常量

`OPERATOR_LOCAL_COUNT = 8` —— 每个 plan 默认最多 8 个算子的监控信息（ObArray 初始大小）。

### 2.3 ObTraceEventRecorder 集成

`set_trace` / `get_trace` API 集成 `ObTraceEventRecorder`：
- 参见 #60 OB Profiling 中的 trace event recorder
- plan 监控 + trace event 双重采集

### 2.4 OB_UNIS_VERSION(1) 序列化

`OB_UNIS_VERSION(1)` macro 表明 plan 监控信息支持跨进程序列化（参见 #54 serialization-framework）。

---

## 3. ObExecStat / ObExecStatCollector —— 执行统计

### 3.1 ObExecStat 基类

```cpp
// src/sql/monitor/ob_exec_stat.h
class ObExecStat {
public:
  // 统计字段
  int64_t rows_;
  int64_t affected_rows_;
  int64_t logical_reads_;
  int64_t physical_reads_;
  int64_t exec_us_;
  int64_t plan_gen_us_;
  int64_t exec_type_;  // SELECT / INSERT / UPDATE / DELETE

  // 序列化
  OB_UNIS_VERSION(1);
};
```

### 3.2 ObExecStatCollector

```cpp
// src/sql/monitor/ob_exec_stat_collector.{h,cpp}
class ObExecStatCollector {
public:
  // 收集 per-SQL 执行统计
  int collect(const ObExecContext &ctx, ObExecStat &stat);

  // 收集 rows / affected_rows / time 等
  int collect_rows(int64_t rows);
  int collect_affected_rows(int64_t affected);
  int collect_exec_time(int64_t us);
};
```

### 3.3 关键指标

| 指标 | 含义 |
|------|------|
| `rows_` | SELECT 返回行数 |
| `affected_rows_` | INSERT/UPDATE/DELETE 影响行数 |
| `logical_reads_` | 逻辑读次数 |
| `physical_reads_` | 物理读次数 |
| `exec_us_` | 执行耗时（微秒） |
| `plan_gen_us_` | plan 生成耗时 |
| `exec_type_` | SQL 类型 |

---

## 4. ObPhyPlanExecInfo —— plan 执行信息

### 4.1 类骨架

```cpp
// src/sql/monitor/ob_phy_plan_exec_info.h
class ObPhyPlanExecInfo {
public:
  // plan 执行时间戳
  int64_t start_time_;     // 执行开始时间
  int64_t end_time_;       // 执行结束时间

  // 执行结果
  int64_t affected_rows_;
  int64_t exec_us_;
  int64_t plan_gen_us_;
  int64_t get_plan_time_us_;

  // 执行记录
  ObExecRecord exec_record_;
  ObExecTimestamp exec_timestamp_;

  OB_UNIS_VERSION(1);
};
```

### 4.2 与 ObPhyPlanMonitorInfo 的关系

- `ObPhyPlanExecInfo` —— 单 plan 的执行信息
- `ObPhyPlanMonitorInfo` —— 包含多个 `ObPhyOperatorMonitorInfo`（operator 级）+ `ObPhyPlanExecInfo`（plan 级）

---

## 5. ObPhyOperatorMonitorInfo —— 算子监控

### 5.1 类骨架

```cpp
// src/sql/monitor/ob_phy_operator_monitor_info.{h,cpp}
class ObPhyOperatorMonitorInfo {
public:
  // 算子标识
  int64_t op_id_;          // 算子 ID
  ObString op_name_;        // 算子名（TableScan / IndexScan / HashJoin 等）

  // 算子统计
  int64_t rows_;            // 处理行数
  int64_t cost_us_;         // 算子耗时
  int64_t memory_bytes_;    // 算子使用内存

  // 子算子 / 上游算子
  int64_t parent_op_id_;
  int64_t first_child_op_id_;

  OB_UNIS_VERSION(1);
};
```

### 5.2 ObPhyOperatorStats

```cpp
// src/sql/monitor/ob_phy_operator_stats.{h,cpp}
class ObPhyOperatorStats {
  // 算子统计聚合
  // - 总耗时
  // - 内存峰值
  // - 输出行数
};
```

---

## 6. ObMonitorInfoManager —— 监控信息管理

### 6.1 类骨架

```cpp
// src/sql/monitor/ob_monitor_info_manager.{h,cpp}
class ObMonitorInfoManager {
public:
  // 注册 monitor info
  int register_monitor_info(const ObPhyPlanMonitorInfo &info);

  // 注销
  int unregister_monitor_info(int64_t plan_id);

  // 获取
  int get_monitor_info(int64_t plan_id, ObPhyPlanMonitorInfo *&info);

  // 淘汰（LRU）
  int evict_lru(int64_t target_size);
};
```

### 6.2 ObPlanInfoManager

```cpp
// src/sql/monitor/ob_plan_info_manager.{h,cpp}
class ObPlanInfoManager {
  // plan info 管理
  // - 存储 plan 监控信息
  // - 跨 observer 共享（参见 #65 Standby）
};
```

### 6.3 ObMonitorInfoEliminationTask

```cpp
// src/sql/monitor/ob_monitor_info_elimination_task.{h,cpp}
class ObMonitorInfoEliminationTask {
  // 监控信息淘汰任务
  // - LRU 淘汰
  // - 内存上限触发
  // - 时间老化
};
```

---

## 7. ObSecurityAudit —— 安全审计（参见 #70）

### 7.1 类骨架

```cpp
// src/sql/monitor/ob_security_audit.h
class ObSecurityAudit {
  // 安全审计
  // - record_event (记录审计事件)
  // - query_events (查询审计)
  // - flush (持久化)
};
```

### 7.2 ObAuditActionType

```cpp
// src/sql/monitor/ob_audit_action_type.h
enum ObAuditActionType {
  AUDIT_LOGIN = 0,
  AUDIT_LOGOUT,
  AUDIT_DDL,
  AUDIT_DML,
  AUDIT_QUERY,
  AUDIT_GRANT,
  AUDIT_REVOKE,
  // ...
};
```

### 7.3 与 #70 的关系

参见 #70-sql-audit-security：审计是 #70 的核心 topic。`src/sql/monitor/` 中的 `ob_security_audit.h` 是 #70 路径下散落位置的另一个入口。

---

## 8. EXPLAIN / 慢查询 / Trace 虚拟表

### 8.1 关键虚拟表

```bash
src/observer/virtual_table/
├── ob_all_virtual_tracepoint_info.{h,cpp}    # tracepoint info
├── ob_all_virtual_tracepoint_info.h
├── ob_plan_cache_plan_explain.{h,cpp}         # plan cache plan explain
├── ob_plan_cache_plan_explain.h
├── ob_virtual_show_trace.{h,cpp}               # show trace
└── ob_virtual_show_trace.h
```

### 8.2 关键 SQL

```sql
-- EXPLAIN 查询
EXPLAIN SELECT * FROM t WHERE id = 1;

-- EXPLAIN PLAN FOR
EXPLAIN PLAN FOR SELECT * FROM t WHERE id = 1;

-- SHOW TRACE
SHOW TRACE;
```

### 8.3 监控 SQL

```sql
-- 查看慢查询
SELECT * FROM oceanbase.__all_virtual_tracepoint_info
WHERE type = 'slow_query';

-- 查看 plan cache 命中
SELECT * FROM oceanbase.__all_plan_cache_plan_explain;
```

---

## 9. ObSqlPlan —— SQL plan 结构

### 9.1 类骨架

```cpp
// src/sql/monitor/ob_sql_plan.{h,cpp}
class ObSqlPlan {
  // SQL plan 结构
  // - plan_id
  // - plan_text
  // - plan_hash
  // - plan_type
  // - plan_time
  // - execution_stats
  // ...
};
```

### 9.2 应用

`ObSqlPlan` 是 EXPLAIN 输出的基础数据结构：
- `EXPLAIN SELECT ...` → 生成 `ObSqlPlan`
- 通过虚拟表 `ob_all_virtual_sql_plan` 输出给应用

---

## 10. 与其他文章的关系

### 10.1 与 #17 / #95 Query Optimizer

优化器生成 plan + 监控（参见 #95）：
- 优化器输出 ObPhyPlanMonitorInfo
- 通过 ObMonitorInfoManager 收集统计

### 10.2 与 #22 / #96 Plan Cache

Plan Cache（参见 #96）的 plan 监控：
- `ob_plan_cache_plan_explain.h` 解释 plan cache 中的 plan
- `ob_all_plan_cache_stat.h`（参见 #96）监控 cache 命中

### 10.3 与 #29 Slow Query

慢查询分析（参见 #29）：
- `__all_virtual_tracepoint_info.h` 慢查询监控
- ObExecStatCollector 收集执行时间

### 10.4 与 #60 Profiling

Profiling（参见 #60）：
- ObTraceEventRecorder 与 ObPhyPlanMonitorInfo.set_trace 集成
- plan 监控 + trace event 双重采集

### 10.5 与 #70 SQL Audit

审计（参见 #70）：
- `src/sql/monitor/ob_security_audit.h` 散落位置
- ObAuditActionType 枚举定义

### 10.6 与 #84 Virtual Table

监控虚拟表（参见 #84）：
- `__all_virtual_sql_plan`
- `__all_virtual_tracepoint_info`
- `ob_plan_cache_plan_explain`
- `ob_virtual_show_trace`

---

## 11. 总结

### 11.1 性能分析在 OB 体系中的定位

性能分析是 **OB SQL 可观测性的核心**：
- 27 个 monitor 文件
- 5 层架构（EXPLAIN → Monitor Info → Exec Stat → Monitor Manager → Audit + 持久化）
- 与 Plan Cache / Optimizer / Schema 深度集成

### 11.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| Plan 监控核心 | `ObPhyPlanMonitorInfo`（实读，含 `OPERATOR_LOCAL_COUNT = 8`） |
| Plan 执行信息 | `ObPhyPlanExecInfo`（start_time / end_time / affected_rows / exec_us） |
| 算子监控 | `ObPhyOperatorMonitorInfo`（op_id / op_name / rows / cost_us / memory_bytes） |
| 算子统计 | `ObPhyOperatorStats`（聚合统计） |
| 执行统计 | `ObExecStat`（rows / affected_rows / logical_reads / physical_reads / exec_us / plan_gen_us / exec_type） |
| 执行统计收集 | `ObExecStatCollector` |
| 监控管理 | `ObMonitorInfoManager`（register / unregister / get / evict_lru） |
| Plan info 管理 | `ObPlanInfoManager` |
| 监控淘汰 | `ObMonitorInfoEliminationTask` |
| 审计 | `ObSecurityAudit`（参见 #70） |
| 审计 action 类型 | `ObAuditActionType`（AUDIT_LOGIN / LOGOUT / DDL / DML / QUERY / GRANT / REVOKE） |
| SQL plan 结构 | `ObSqlPlan`（plan_id / plan_text / plan_hash / plan_type / plan_time / execution_stats） |
| Trace event | `ObTraceEventRecorder`（与 `ObPhyPlanMonitorInfo.set_trace` 集成） |

### 11.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/sql/monitor/` (27 文件) | SQL 监控主目录 |
| `src/sql/monitor/ob_phy_plan_monitor_info.{h,cpp}` | plan 监控核心（实读） |
| `src/sql/monitor/ob_phy_plan_exec_info.{h,cpp}` | plan 执行信息 |
| `src/sql/monitor/ob_phy_operator_monitor_info.{h,cpp}` | 算子监控 |
| `src/sql/monitor/ob_phy_operator_stats.{h,cpp}` | 算子统计 |
| `src/sql/monitor/ob_exec_stat.h` | 执行统计基类 |
| `src/sql/monitor/ob_exec_stat_collector.{h,cpp}` | 执行统计收集器 |
| `src/sql/monitor/ob_monitor_info_manager.{h,cpp}` | 监控信息管理 |
| `src/sql/monitor/ob_plan_info_manager.{h,cpp}` | plan info 管理 |
| `src/sql/monitor/ob_monitor_info_elimination_task.{h,cpp}` | 监控淘汰任务 |
| `src/sql/monitor/ob_audit_action_type.h` | 审计 action 类型 |
| `src/sql/monitor/ob_security_audit.h` | 安全审计（参见 #70） |
| `src/sql/monitor/ob_security_audit_utils.h` | 审计工具 |
| `src/sql/monitor/ob_sql_plan.h` | SQL plan 结构 |
| `src/observer/virtual_table/ob_all_virtual_tracepoint_info.{h,cpp}` | tracepoint info 虚拟表 |
| `src/observer/virtual_table/ob_plan_cache_plan_explain.{h,cpp}` | plan cache plan explain 虚拟表 |
| `src/observer/virtual_table/ob_virtual_show_trace.{h,cpp}` | show trace 虚拟表 |
| `src/sql/optimizer/ob_explain_log_plan.{h,cpp}` | EXPLAIN log plan |
| `src/sql/optimizer/ob_explain_note.h` | EXPLAIN note |
| `src/sql/resolver/ddl/ob_explain_stmt.h` | EXPLAIN stmt |
| `src/sql/resolver/ddl/ob_explain_resolver.h` | EXPLAIN resolver |
| `src/sql/executor/ob_cmd_executor.{h,cpp}` | 命令执行 |
| `src/sql/executor/ob_direct_receive_op.{h,cpp}` | direct receive op |
| `src/sql/executor/ob_direct_transmit_op.{h,cpp}` | direct transmit op |
| `src/sql/executor/ob_execute_result.{h,cpp}` | execute result |
| `src/sql/executor/ob_execution_id.{h,cpp}` | execution id |
| `src/sql/plan_cache/ob_plan_cache_plan_explain.{h,cpp}` | plan cache plan explain |
| `src/share/diagnosis/ob_sql_plan_monitor_node_list.h` | 诊断 |

### 11.4 5 层架构

| 层级 | 元素 | 角色 |
|------|------|------|
| L1 | EXPLAIN | 用户接口 + ObExplainStmt + ObExplainLogPlan |
| L2 | 监控信息 | `ObPhyPlanMonitorInfo` + `ObPhyPlanExecInfo` + `ObPhyOperatorMonitorInfo` |
| L3 | 执行统计 | `ObExecStat` + `ObExecStatCollector` |
| L4 | 监控管理 | `ObMonitorInfoManager` + `ObPlanInfoManager` + `ObMonitorInfoEliminationTask` |
| L5 | 审计 + 持久化 | `ObSecurityAudit` + 虚拟表持久化 |

### 11.5 关键指标

| 指标 | 含义 |
|------|------|
| `rows_` | SELECT 返回行数 |
| `affected_rows_` | INSERT/UPDATE/DELETE 影响行数 |
| `logical_reads_` | 逻辑读次数 |
| `physical_reads_` | 物理读次数 |
| `exec_us_` | 执行耗时（微秒） |
| `plan_gen_us_` | plan 生成耗时 |
| `cost_us_` | 算子耗时 |
| `memory_bytes_` | 算子使用内存 |

### 11.6 推荐下一步

按之前梳理的顺序，下一篇应该是 **#99 SQL 改写 / 视图改写 / 子查询优化**：

OB 的 SQL 改写体系 —— 视图改写（View Merge）、子查询优化（IN / EXISTS Semi Join）、谓词下推、聚合下推。源码入口：`src/sql/rewrite/`（107 文件，已在 #95 探过）+ `src/sql/optimizer/ob_log_plan.h` + `src/share/schema/ob_view_schema.h`（推测）。

适用场景：SQL 优化 / 改写规则 / 性能提升。

整吗？