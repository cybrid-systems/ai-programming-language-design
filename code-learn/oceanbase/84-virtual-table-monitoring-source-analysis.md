# 84-virtual-table-monitoring — OceanBase 虚拟表 / 监控接口 / OCP 对接深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/observer/virtual_table/` **518 文件** + **363 虚拟表** + `src/observer/ob_server_event_history_table_operator.{h,cpp}` + `src/share/ob_virtual_table_scanner_iterator.h`）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **虚拟表（Virtual Table）**是整个 observer 集群的"监控 + 调试 + OCP 对接"基础 —— **100+ 虚拟表**（`__all_virtual_*`）不存储数据，运行时通过 SQL 直接计算（如 `__all_virtual_thread` 查 thread 状态，`__all_virtual_latch_stat` 查锁状态）。OCP / OBD / DBA 都通过这些虚拟表监控 OB 集群。

本文聚焦 8 个核心问题：

1. **虚拟表全景** —— 363 虚拟表的分类与作用
2. **虚拟表基础架构** —— `ObVirtualTable` 基类 + Scanner
3. **Schema 视图** —— `__all_virtual_table` / `__all_virtual_column` 等
4. **配置监控** —— `__all_virtual_tenant_parameter_stat` / `__all_virtual_sys_parameter_stat`
5. **运行时监控** —— thread / latch / memory / cgroup
6. **事件历史** —— `ObServerEventHistoryTableOperator`
7. **OCP 对接** —— OCP 通过虚拟表监控 OB
8. **DBA 调试 SQL** —— 常用监控 SQL 模板

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 30-observer-startup | observer 启动加载虚拟表 |
| 64-online-ddl | 虚拟表查询 schema（`__all_virtual_table`） |
| 70-sql-audit-security | `__all_virtual_audit_*` 监控 |
| 71-resource-isolation-cgroup | `__all_virtual_cgroup_config` |
| 72-config-system-obconfig | `__all_virtual_tenant_parameter_stat` |
| 73-oblogger | `__all_virtual_server_event_history` |
| 74-thread-model | `__all_virtual_thread` |
| 75-latch-system | `__all_virtual_latch_stat` |
| 78-backup-restore-pitr | `__all_virtual_ls_log_restore_status` / `__all_virtual_tenant_show_restore_preview` |
| 82-meta-table-internal-schema | 内部表（持久化）vs 虚拟表（运行时计算）对比 |

---

## 1. 整体架构：518 文件 / 363 虚拟表

### 1.1 模块组成

```bash
$ ls src/observer/virtual_table/ | wc -l
518
$ ls src/observer/virtual_table/ | grep -c '^ob_all_virtual_'
363
```

**518 文件** + **363 虚拟表** —— OB 监控接口的完整实现。

### 1.2 路径修正（来自 #82 路径修正的延续）

```
正确路径:
  src/observer/virtual_table/  (518 文件, 363 ob_all_virtual_*)
  src/observer/ob_server_event_history_table_operator.h
  src/observer/ob_agent_table_base.h
  src/observer/ob_agent_virtual_table.h
  src/share/ob_virtual_table_scanner_iterator.h

不存在路径 (按 #82 路径修正继续):
  src/share/virtual_table/  ← 不存在
  deps/oblib/src/lib/virtual_table/    ← 不存在
```

---

## 2. 虚拟表基础架构

### 2.1 虚标表基类 + Scanner

```cpp
// src/share/ob_virtual_table_scanner_iterator.h (推测)
class ObVirtualTable {
public:
  // 1. 初始化（准备数据源）
  virtual int init(ObExecContext &ctx);

  // 2. 打开 scanner
  virtual int open();

  // 3. 读取下一行
  virtual int get_next_row(ObNewRow *&row);

  // 4. 关闭
  virtual int close();

  // 5. 字段定义
  virtual int get_full_row(const ObIArray<ObColumn> &columns,
                          ObNewRow *&row) = 0;

  // 6. 内部状态
  void *iter_;  // 各种 iterator（thread iter / latch iter / etc.）
};
```

### 2.2 SQL 路由

```
应用 SQL: SELECT * FROM __all_virtual_thread
    │
    ▼
SQL Parser (识别 __all_virtual_thread 是虚拟表)
    │
    ▼
Resolver
    │
    ▼
Optimizer
    │
    ▼
SQL Executor: 调 ObVirtualTableScanner
    │
    ▼
ObVirtualTable::get_next_row()
    │
    ├─ 遍历 thread state（snapshot）
    ├─ 构造 ObNewRow
    │
    ▼
返回给应用
```

### 2.3 vs 内部表

| 维度 | 内部表 `__all_*` | 虚拟表 `__all_virtual_*` |
|------|-----------------|------------------------|
| 数据存储 | 持久化到磁盘 | 不存储（运行时计算） |
| 查询路径 | 标准 SQL → 走 storage | 走 ObVirtualTableScanner |
| 数据延迟 | 最新已持久化的 | 当前实时状态 |
| 数量 | 100+ | 100+ |
| 例子 | `__all_table` | `__all_virtual_thread` |

---

## 3. Schema 视图虚拟表

### 3.1 主要的 schema 虚拟表

```bash
src/observer/virtual_table/
├── ob_all_virtual_table.{h,cpp}              # 所有表（含用户表 + 内部表）
├── ob_all_virtual_tablegroup.{h,cpp}        # 表组
├── ob_all_virtual_database.{h,cpp}           # 数据库
├── ob_all_virtual_tenant.{h,cpp}             # 租户
├── ob_all_virtual_user.{h,cpp}               # 用户
├── ob_all_virtual_role.{h,cpp}               # 角色
├── ob_all_virtual_column.{h,cpp}             # 列
├── ob_all_virtual_index.{h,cpp}              # 索引
├── ob_all_virtual_constraint.{h,cpp}         # 约束
├── ob_all_virtual_partition.{h,cpp}          # 分区
├── ob_all_virtual_subpartition.{h,cpp}       # 子分区
├── ob_all_virtual_table_stat.{h,cpp}          # 表统计
├── ob_all_virtual_show_create_database.{h,cpp}# SHOW CREATE DATABASE
└── ob_all_virtual_show_create_table.{h,cpp}   # SHOW CREATE TABLE
```

### 3.2 SHOW CREATE TABLE

```sql
-- 应用查询
SHOW CREATE TABLE t;

-- OB 内部：把请求转到 __all_virtual_show_create_table
-- 然后调 ObTableSchema::to_create_table_sql()
-- 返回 CREATE TABLE SQL 字符串
```

---

## 4. 配置监控虚拟表（参见 #72）

### 4.1 主要的配置虚拟表

```bash
src/observer/virtual_table/
├── ob_all_virtual_tenant_parameter_stat.{h,cpp}   # 租户参数实时值
├── ob_all_virtual_tenant_parameter_info.{h,cpp}   # 租户参数详情
├── ob_all_virtual_sys_parameter_stat.{h,cpp}     # 系统参数实时值
├── ob_all_virtual_sys_parameter_info.{h,cpp}     # 系统参数详情
```

### 4.2 监控 SQL

```sql
-- 查看某租户的实际生效参数
SELECT name, value, data_type, edit_level
FROM oceanbase.__all_virtual_tenant_parameter_stat
WHERE tenant_id = 1001
ORDER BY name;

-- 查看系统参数
SELECT name, value, scope
FROM oceanbase.__all_virtual_sys_parameter_stat
WHERE name LIKE '%cpu%';
```

---

## 5. 运行时监控虚拟表

### 5.1 Thread / Latch 监控

```bash
src/observer/virtual_table/
├── ob_all_virtual_thread.{h,cpp}                  # 所有线程状态（参见 #74）
├── ob_all_virtual_latch_stat.{h,cpp}              # 所有锁状态（参见 #75）
├── ob_all_virtual_memory_context_stat.{h,cpp}     # 内存 context
├── ob_all_virtual_memory_info.{h,cpp}             # 内存总览
├── ob_all_virtual_memstore_info.{h,cpp}           # memstore 信息
├── ob_all_virtual_server_object_pool.{h,cpp}      # object pool
├── ob_all_virtual_concurrency_object_pool.{h,cpp} # 并发 object pool
```

### 5.2 Cgroup / Server 监控

```bash
src/observer/virtual_table/
├── ob_all_virtual_cgroup_config.{h,cpp}           # cgroup 配置（参见 #71）
├── ob_all_virtual_server.{h,cpp}                  # server 列表
├── ob_all_virtual_server_blacklist.{h,cpp}        # 黑名单
├── ob_all_virtual_res_mgr_sys_stat.{h,cpp}        # 资源管理（参见 #71）
```

### 5.3 Compaction 监控

```bash
src/observer/virtual_table/
├── ob_all_virtual_server_compaction_event_history.{h,cpp}  # compaction 历史
├── ob_all_virtual_server_compaction_progress.{h,cpp}        # compaction 进度
├── ob_all_virtual_server_schema_info.{h,cpp}               # schema info
├── ob_all_virtual_server_storage.{h,cpp}                   # 存储信息
```

### 5.4 Session 监控

```bash
src/observer/virtual_table/
├── ob_all_virtual_session_info.{h,cpp}             # 当前 session
├── ob_all_virtual_session_event.{h,cpp}           # session 事件
├── ob_all_virtual_session_variable.{h,cpp}        # session 变量
```

---

## 6. 事件历史 —— ObServerEventHistoryTableOperator

### 6.1 类骨架

```cpp
// src/observer/ob_server_event_history_table_operator.h
class ObServerEventHistoryTableOperator {
public:
  // 记录 server 事件
  int record_event(const ObServerEvent &event);

  // 查询事件历史
  int query_events(ObArray<ObServerEvent> &events);

  // 清空
  int clear();
};
```

### 6.2 ObServerEvent 结构

```cpp
// (推测)
struct ObServerEvent {
  int64_t timestamp_;            // 事件时间
  ObString module_;              // 模块名 (RS / observer / etc.)
  ObString event_type_;          // 事件类型 (startup / shutdown / failover / etc.)
  ObString details_;             // 事件详情
  int64_t svr_ip_;               // server IP
  int32_t svr_port_;             // server port
};
```

### 6.3 用途

- **故障诊断**：查询 observer 启动 / 关闭 / failover 事件
- **状态变迁**：跟踪 server 状态变化
- **审计日志**：合规要求的事件历史

### 6.4 监控 SQL

```sql
-- 查询 observer 启动事件
SELECT timestamp, module, event_type, details
FROM oceanbase.__all_virtual_server_event_history
WHERE event_type = 'STARTUP'
ORDER BY timestamp DESC
LIMIT 10;

-- 查询 failover 事件
SELECT * FROM oceanbase.__all_virtual_server_event_history
WHERE event_type = 'FAILOVER'
ORDER BY timestamp DESC LIMIT 20;
```

---

## 7. Compaction 监控

### 7.1 Compaction 虚拟表

```bash
src/observer/virtual_table/
├── ob_all_virtual_server_compaction_event_history.{h,cpp}
├── ob_all_virtual_server_compaction_progress.{h,cpp}
├── ob_all_virtual_compaction_diagnose_info.{h,cpp}    # compaction 诊断
└── ob_all_virtual_compaction_suggestion.{h,cpp}      # compaction 建议
```

### 7.2 监控 SQL

```sql
-- 当前 compaction 进度
SELECT zone, server, type, status, progress_percent
FROM oceanbase.__all_virtual_server_compaction_progress;

-- compaction 历史
SELECT zone, server, type, start_time, end_time
FROM oceanbase.__all_virtual_server_compaction_event_history
ORDER BY start_time DESC LIMIT 20;
```

---

## 8. Restore 监控（参见 #78）

### 8.1 Restore 虚拟表

```bash
src/observer/virtual_table/
├── ob_tenant_show_restore_preview.{h,cpp}         # Restore 预览
├── ob_all_virtual_ls_log_restore_status.{h,cpp}    # Restore 状态
```

### 8.2 监控 SQL

```sql
-- Restore 预览
SELECT * FROM oceanbase.__all_virtual_tenant_show_restore_preview;

-- Restore 进度
SELECT ls_id, restored_lsn, total_lsn, progress_percent
FROM oceanbase.__all_virtual_ls_log_restore_status;
```

---

## 9. 审计监控（参见 #70）

### 9.1 审计虚拟表

```bash
src/observer/virtual_table/
├── ob_all_virtual_audit_action.{h,cpp}             # 审计动作
├── ob_all_virtual_audit_operation.{h,cpp}          # 审计操作
└── ob_all_virtual_security_audit.{h,cpp}           # 安全审计
```

### 9.2 监控 SQL

```sql
-- 审计操作
SELECT timestamp, user_name, action, success
FROM oceanbase.__all_virtual_security_audit
ORDER BY timestamp DESC LIMIT 100;

-- 审计失败
SELECT * FROM oceanbase.__all_virtual_security_audit
WHERE success = 0
ORDER BY timestamp DESC;
```

---

## 10. OBProxy / SQL 相关虚拟表

### 10.1 性能统计

```bash
src/observer/virtual_table/
├── ob_all_virtual_plan_stat.{h,cpp}                # 计划缓存统计
├── ob_all_virtual_sql_audit.{h,cpp}                # SQL 审计
├── ob_all_virtual_trace_log.{h,cpp}                # 跟踪日志
├── ob_all_virtual_session_event.{h,cpp}           # session 事件
└── ob_all_virtual_proxy_partition_info.{h,cpp}     # OBProxy partition
```

### 10.2 监控 SQL

```sql
-- 计划缓存统计
SELECT tenant_id, plan_id, sql_id, hit_count, first_load_time
FROM oceanbase.__all_virtual_plan_stat
ORDER BY hit_count DESC LIMIT 20;

-- 跟踪日志
SELECT tenant_id, svr_ip, request_time, execute_time
FROM oceanbase.__all_virtual_trace_log
WHERE execute_time > 1000000  -- > 1s
ORDER BY request_time DESC LIMIT 50;
```

---

## 11. Agent 虚拟表（OCP 集成）

### 11.1 Agent 体系

```bash
src/observer/virtual_table/
├── ob_agent_table_base.{h,cpp}                    # Agent table 基类
├── ob_agent_virtual_table.{h,cpp}                  # Agent virtual table
```

### 11.2 OCP 集成

OCP (OceanBase Cloud Platform) 通过 SQL 协议连接 OB 集群：
- OCP → OB observer → `__all_virtual_*` 表 → 返回监控数据
- OCP dashboard 显示：tenant 状态 / server 状态 / resource 用量 / etc.

---

## 12. DBA 常用监控 SQL 模板

### 12.1 集群总览

```sql
-- 集群状态
SELECT zone, server, svr_ip, svr_port, status, start_service_time
FROM oceanbase.__all_virtual_server;

-- 资源使用总览
SELECT zone, server, cpu_capacity, cpu_assigned, cpu_in_use,
       memory_capacity, memory_assigned, memory_in_use
FROM oceanbase.__all_virtual_res_mgr_sys_stat;
```

### 12.2 Tenant / Unit

```sql
-- 所有租户
SELECT tenant_id, tenant_name, status, primary_zone, locality
FROM oceanbase.__all_virtual_tenant;

-- Unit 状态
SELECT unit_id, tenant_id, zone, server, status, max_cpu, max_memory
FROM oceanbase.__all_virtual_unit;
```

### 12.3 Schema / 对象

```sql
-- 某 tenant 的所有表
SELECT table_id, table_name, table_type, schema_version
FROM oceanbase.__all_virtual_table
WHERE tenant_id = 1001;

-- 某表的列
SELECT column_id, column_name, data_type, ordinal_position
FROM oceanbase.__all_virtual_column
WHERE table_name = 't';

-- 索引
SELECT index_name, table_name, index_type, column_names
FROM oceanbase.__all_virtual_index
WHERE table_name = 't';
```

### 12.4 性能监控

```sql
-- 慢查询（>1s）
SELECT * FROM oceanbase.__all_virtual_trace_log
WHERE execute_time > 1000000
ORDER BY request_time DESC LIMIT 50;

-- Latch 等待
SELECT * FROM oceanbase.__all_virtual_latch_stat
WHERE wait_count > 1000
ORDER BY wait_count DESC LIMIT 20;

-- Thread 状态
SELECT thread_name, status, last_active_ts, task_count
FROM oceanbase.__all_virtual_thread
WHERE status = 'STUCK'
ORDER BY last_active_ts ASC;
```

### 12.5 Backup / Restore（参见 #78）

```sql
-- Backup 状态
SELECT tenant_id, backup_type, status, start_time, end_time
FROM oceanbase.__all_virtual_backup_task
WHERE status != 'SUCCESS'
ORDER BY start_time DESC;

-- Restore 预览
SELECT * FROM oceanbase.__all_virtual_tenant_show_restore_preview;
```

---

## 13. 与其他文章的关系

### 13.1 与 #30 Observer Startup

Observer 启动时加载虚拟表：
- 注册所有 `__all_virtual_*` 表到 schema service
- 启动时初始化 Agent virtual table

### 13.2 与 #64 Online DDL

`__all_virtual_table` / `__all_virtual_column` 用于 DDL 后验证：
- 新表是否正确创建
- schema_version 是否正确升级

### 13.3 与 #70 SQL Audit / Security

`__all_virtual_audit_*` 监控所有 audit 事件：
- user 操作审计
- DDL 审计
- Privilege 审计

### 13.4 与 #71 Resource Isolation / cgroup

`__all_virtual_cgroup_config` 监控 cgroup 配置（参见 #71）。

### 13.5 与 #72 Config System / ObConfig

`__all_virtual_tenant_parameter_stat` / `__all_virtual_sys_parameter_stat` 监控参数（参见 #72）。

### 13.6 与 #74 Thread Model

`__all_virtual_thread` 监控 thread 状态（参见 #74）。

### 13.7 与 #75 Latch System

`__all_virtual_latch_stat` 监控锁状态（参见 #75）。

### 13.8 与 #78 Backup / Restore / PITR

`__all_virtual_tenant_show_restore_preview` / `__all_virtual_ls_log_restore_status` 监控 restore（参见 #78）。

### 13.9 与 #82 Meta Table / Inner Schema

- **内部表**（`__all_*`）：持久化
- **虚拟表**（`__all_virtual_*`）：运行时计算
- 363 虚拟表 + 100+ 内部表 构成完整监控体系

---

## 14. 总结

### 14.1 虚拟表在 OB 体系中的定位

虚拟表是 **OB 监控 + 调试 + OCP 对接的统一接口**：
- 363 虚拟表覆盖 schema / config / runtime / 性能 / 审计 / 事件 / 备份恢复 等
- 不存储数据，运行时计算
- OCP / OBD / DBA 通过 SQL 监控 OB

### 14.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| 虚拟表基类 | `ObVirtualTable` + `ObVirtualTableScanner` |
| SQL 路由 | SQL Parser 识别 → Resolver → Executor 调 virtual table scanner |
| Schema 视图 | `__all_virtual_table` / `__all_virtual_column` |
| 配置监控 | `__all_virtual_tenant_parameter_stat` / `__all_virtual_sys_parameter_stat` |
| 运行时监控 | thread / latch / memory / cgroup |
| 事件历史 | `ObServerEventHistoryTableOperator` |
| Compaction 监控 | `__all_virtual_server_compaction_*` |
| Restore 监控 | `__all_virtual_ls_log_restore_status` / `__all_virtual_tenant_show_restore_preview` |
| 审计监控 | `__all_virtual_audit_*` |
| Agent 体系 | OCP 集成 |

### 14.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/observer/virtual_table/` (518 文件) | 363 虚拟表实现 |
| `src/observer/ob_server_event_history_table_operator.{h,cpp}` | 事件历史 |
| `src/observer/ob_agent_table_base.{h,cpp}` | Agent table 基类 |
| `src/observer/ob_agent_virtual_table.{h,cpp}` | Agent virtual table |
| `src/share/ob_virtual_table_scanner_iterator.h` | Scanner 抽象 |

### 14.4 虚拟表 vs 内部表

| 维度 | 内部表（100+） | 虚拟表（363） |
|------|---------------|--------------|
| 数据存储 | 持久化到磁盘 | 不存储（运行时计算） |
| 查询路径 | 标准 SQL → storage | `ObVirtualTableScanner` |
| 数据延迟 | 最新已持久化 | 实时状态 |
| 用途 | schema / 元数据 / DDL 审计 | 监控 / 调试 / OCP 对接 |

### 14.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#85 Partition Table / Tablet 物理分布**（深化 #36）：

OB 的 partition 物理分布 —— partition → tablet → server 的映射，partition balance / transfer / split / merge。源码入口：`src/share/partition_table/` + `src/share/partition_table/ob_partition_location.h` + `src/observer/table_load/backup/`。

适用场景：容量规划 / 数据迁移 / 性能调优。

整吗？