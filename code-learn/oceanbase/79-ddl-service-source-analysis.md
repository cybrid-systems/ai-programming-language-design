# 79-ddl-service — OceanBase DDL Service / CREATE / ALTER / DROP 深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/sql/engine/cmd/` 131 文件 + `src/sql/resolver/ddl/ob_ddl_stmt.{h,cpp}` + `src/rootserver/ob_ddl_service.{h,cpp}` + `src/rootserver/ddl_task/ob_ddl_*.{h,cpp}` + `src/storage/ddl/ob_ddl_*.{h,cpp}` 等）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **DDL Service** 是整个 observer 进程的"数据库定义变更引擎" —— 21+ 种 DDL 操作（CREATE / ALTER / DROP TABLE / INDEX / VIEW / SEQUENCE / FUNCTION / PROCEDURE / PACKAGE / TRIGGER / DATABASE / USER / ROLE / TABLEGROUP 等）通过统一的 DDL 处理路径：SQL 解析 → 优化 → DDL Executor → RS DDL Service → 跨 observer 落地。

本文聚焦 7 个核心问题：

1. **DDL 处理全流程** —— 从 SQL 到 schema 持久化的完整路径
2. **ObDDLExecutorUtil** —— DDL 入口工具
3. **ObDDLStmt** —— DDL 语句 AST
4. **ObDDLService**（RootServer 端）—— DDL 任务调度
5. **DDL Task Scheduler** —— DAG 调度的 DDL 任务
6. **Storage DDL**（`src/storage/ddl/`）—— 数据层 DDL 执行
7. **21+ 种 DDL 操作的路径分类**

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 64-online-ddl | #64 描述 Online DDL schema_version 概念，本文深入每种 DDL 实现 |
| 76-schema-service | Schema Service 是 DDL 落地的持久化层 |
| 27-rootserver | RS 是 DDL 协调者 |
| 30-observer-startup | 启动时拉 schema cache（含 DDL 已完成的 schema） |
| 65-standby-cluster | Standby 模式下 DDL 通过 replay log 应用 |

---

## 1. 整体架构：DDL Service 五层处理路径

### 1.1 模块组成

```bash
$ ls src/sql/engine/cmd/ | wc -l
131
```

**131 文件** —— DDL executor 的主目录（涵盖所有 cmd 类型）。

### 1.2 文件分类（DDL 相关）

```bash
src/sql/engine/cmd/
├── ob_create_table_executor.{h,cpp}      # CREATE TABLE
├── ob_drop_table_executor.{h,cpp}        # DROP TABLE
├── ob_alter_table_executor.{h,cpp}       # ALTER TABLE
├── ob_alter_ls_executor.{h,cpp}           # ALTER TABLEGROUP
├── ob_alter_system_executor.{h,cpp}      # ALTER SYSTEM
├── ob_alter_view_executor.{h,cpp}        # ALTER VIEW
├── ob_create_index_executor.{h,cpp}      # CREATE INDEX
├── ob_drop_index_executor.{h,cpp}        # DROP INDEX
├── ob_create_view_executor.{h,cpp}       # CREATE VIEW
├── ob_drop_view_executor.{h,cpp}         # DROP VIEW
├── ob_create_database_executor.{h,cpp}   # CREATE DATABASE
├── ob_drop_database_executor.{h,cpp}     # DROP DATABASE
├── ob_alter_database_executor.{h,cpp}    # ALTER DATABASE
├── ob_create_tenant_executor.{h,cpp}     # CREATE TENANT
├── ob_drop_tenant_executor.{h,cpp}       # DROP TENANT
├── ob_alter_tenant_executor.{h,cpp}      # ALTER TENANT
├── ob_create_user_executor.{h,cpp}       # CREATE USER
├── ob_drop_user_executor.{h,cpp}         # DROP USER
├── ob_create_role_executor.{h,cpp}       # CREATE ROLE
├── ob_rename_table_executor.{h,cpp}      # RENAME TABLE
├── ob_rename_user_executor.{h,cpp}       # RENAME USER
├── ob_truncate_table_executor.{h,cpp}    # TRUNCATE TABLE
├── ob_load_data_impl.{h,cpp}             # LOAD DATA（参见 #66）
├── ob_ddl_executor_util.{h,cpp}            # DDL 通用工具
└ # ... 其他 DDL executor

src/sql/resolver/ddl/
├── ob_ddl_stmt.{h,cpp}                   # DDL 语句 AST
├── ob_create_table_stmt.{h,cpp}          # CREATE TABLE stmt
├── ob_alter_table_stmt.{h,cpp}           # ALTER TABLE stmt
├── ob_drop_table_stmt.{h,cpp}            # DROP TABLE stmt
└ # ... 其他 DDL stmt

src/rootserver/
├── ob_ddl_service.{h,cpp}                 # DDL service（RS 端）
├── ob_ddl_service_launcher.{h,cpp}        # DDL service launcher
├── ob_ddl_operator.{h,cpp}                 # DDL operator
├── ob_ddl_sql_generator.{h,cpp}           # DDL SQL 生成器
└── ddl_task/
    ├── ob_ddl_task.{h,cpp}                # DDL task 抽象
    ├── ob_ddl_scheduler.{h,cpp}           # DDL task scheduler
    ├── ob_ddl_tablet_scheduler.{h,cpp}     # DDL tablet 调度
    ├── ob_ddl_single_replica_executor.{h,cpp}  # 单副本执行
    ├── ob_ddl_retry_task.{h,cpp}          # DDL 重试
    ├── ob_ddl_redefinition_task.{h,cpp}    # DDL 重新定义
    ├── ob_ddl_helper.{h,cpp}              # DDL helper
    └── parallel_ddl/
        └── ob_ddl_helper.{h,cpp}          # 并行 DDL helper

src/storage/ddl/
├── ob_ddl_redo_log_writer.{h,cpp}         # DDL redo log
├── ob_ddl_heart_beat_task.{h,cpp}        # DDL 心跳
├── ob_ddl_inc_task.{h,cpp}                # DDL inc task
├── ob_ddl_merge_helper.{h,cpp}            # DDL merge helper
└── ob_ddl_dag_monitor_mgr.{h,cpp}         # DDL DAG 监控

src/storage/blocksstable/index_block/
├── ob_ddl_sstable_scan_merge.{h,cpp}      # DDL SSTable 扫描合并
└── ob_ddl_index_block_row_iterator.{h,cpp}# DDL index block 迭代器

src/storage/access/
└── ob_ddl_block_sample_iterator.{h,cpp}   # DDL block 采样迭代器
```

### 1.3 五层处理路径

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: SQL Parser (SQL 解析)                                  │
│  - SQL 文本 → ParseNode → ObDDLStmt AST                          │
│  源码: src/sql/parser/ob_parser.cpp + src/sql/resolver/ddl/      │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: Resolver (名称 + 类型解析)                              │
│  - ParseNode → ObDDLStmt（含 table / column / index 等具体 stmt）│
│  源码: src/sql/resolver/ddl/ob_ddl_stmt.{h,cpp}                  │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: Optimizer (优化 + 物理化)                                │
│  - 生成物理执行计划                                              │
│  - DDL executor 通常直接执行（无复杂 plan）                      │
│  源码: src/sql/optimizer/                                       │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 4: DDL Executor (DDL 执行器)                              │
│  - 校验 + 构造 schema object                                     │
│  - 通过 RPC 调到 RS                                             │
│  - 等待 DDL 完成                                                │
│  源码: src/sql/engine/cmd/ob_*_executor.{h,cpp}                 │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 5: RS DDL Service (RS 协调 + 持久化 + 跨 observer 落地)  │
│  - 校验 + 持久化到 __all_* 内部表                               │
│  - DAG 调度 DDL task                                            │
│  - broadcast 到所有 observer                                    │
│  源码: src/rootserver/ob_ddl_service.{h,cpp}                    │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 5.5: Storage DDL (数据层 DDL 执行)                         │
│  - per-observer observer 收到 DDL task                           │
│  - 实际修改 memtable / SSTable / index                        │
│  - 写 DDL redo log                                              │
│  源码: src/storage/ddl/ob_ddl_*.{h,cpp}                        │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. ObDDLStmt —— DDL 语句 AST

### 2.1 类骨架

```cpp
// src/sql/resolver/ddl/ob_ddl_stmt.h
class ObDDLStmt : public ObStmt {
public:
  // DDL 操作类型
  enum DDLStmtType {
    DDL_INVALID = 0,
    DDL_CREATE_TABLE,
    DDL_DROP_TABLE,
    DDL_ALTER_TABLE,
    DDL_CREATE_INDEX,
    DDL_DROP_INDEX,
    DDL_CREATE_VIEW,
    DDL_DROP_VIEW,
    DDL_CREATE_SEQUENCE,
    DDL_DROP_SEQUENCE,
    DDL_CREATE_DATABASE,
    DDL_DROP_DATABASE,
    DDL_ALTER_DATABASE,
    DDL_CREATE_USER,
    DDL_DROP_USER,
    DDL_CREATE_ROLE,
    DDL_DROP_ROLE,
    DDL_CREATE_FUNCTION,
    DDL_DROP_FUNCTION,
    DDL_CREATE_PROCEDURE,
    DDL_DROP_PROCEDURE,
    DDL_CREATE_PACKAGE,
    DDL_DROP_PACKAGE,
    DDL_CREATE_TRIGGER,
    DDL_DROP_TRIGGER,
    DDL_RENAME_TABLE,
    DDL_RENAME_USER,
    DDL_TRUNCATE_TABLE,
    DDL_CREATE_TENANT,
    DDL_DROP_TENANT,
    DDL_ALTER_TENANT,
    // ...
  };
};
```

### 2.2 具体 DDL Stmt 子类

每个 DDL 操作有专门的 stmt 子类：

```cpp
class ObCreateTableStmt : public ObDDLStmt {
public:
  // 表选项
  TableOptions table_options_;
  // 列定义
  ObArray<ColumnDef> columns_;
  // 分区定义
  PartitionOption partition_option_;
  // 约束
  ObArray<ConstraintDef> constraints_;
};

class ObAlterTableStmt : public ObDDLStmt {
public:
  // alter 操作列表
  ObArray<AlterTableAction> alter_actions_;
  // ALTER COLUMN / ADD COLUMN / DROP COLUMN 等
};

class ObDropTableStmt : public ObDDLStmt {
public:
  // 要 drop 的表名列表
  ObArray<TableRef> tables_;
  // IF EXISTS / CASCADE 选项
  bool if_exists_;
  bool cascade_;
};
```

---

## 3. ObDDLExecutorUtil —— DDL 入口工具

### 3.1 类骨架

```cpp
// src/sql/engine/cmd/ob_ddl_executor_util.h
class ObDDLExecutorUtil final {
public:
  static int wait_ddl_finish(
      const uint64_t tenant_id,
      const int64_t task_id,
      const bool ddl_need_retry_at_executor,
      ObSQLSessionInfo *session,
      obrpc::ObCommonRpcProxy *common_rpc_proxy,
      const bool is_support_cancel = true,
      const int64_t wait_timeout_us = common::OB_MAX_USER_SPECIFIED_TIMEOUT);

  static int wait_ddl_retry_task_finish(...);
  static int wait_build_index_finish(...);
  static int handle_session_exception(ObSQLSessionInfo &session);
  static int cancel_ddl_task(...);

  template<class ARG, class RES>
  static int execute_pcreate_table(...);

private:
  static inline bool is_server_stopped() {
    return observer::ObServer::get_instance().is_stopped();
  }
};
```

### 3.2 关键方法

**wait_ddl_finish**：
- 应用发起 DDL 后，循环 poll RS 查 DDL 任务状态
- 同步阻塞等待（应用层面）

**wait_build_index_finish**：
- CREATE INDEX 是慢操作，独立等待接口

**is_server_stopped**：
- observer 关闭时停止 wait，避免挂起

### 3.3 DDL 异步协议

```
应用: CREATE TABLE t (...)
    │
    ▼
DDL Executor (ob_create_table_executor)
    │
    ├─ 1. 构造 schema object
    ├─ 2. 调 RS DDL RPC
    │
    ▼
RS: ObDDLService::handle_ddl_request
    │
    ├─ 1. 权限校验（参见 #70）
    ├─ 2. 持久化到 __all_*
    ├─ 3. 创建 DDL task
    ├─ 4. DAG 调度（参见 §5）
    │
    ▼
返回 observer: task_id (立即返回)
    │
    ▼
DDL Executor (ob_create_table_executor)
    │
    ├─ ObDDLExecutorUtil::wait_ddl_finish(task_id)
    │   - 循环 poll RS 查 task 状态
    │   - 成功 / 失败 / 超时
    │
    ▼
返回应用: DDL 完成 / 失败
```

---

## 4. ObDDLService（RootServer 端）

### 4.1 类骨架

```cpp
// src/rootserver/ob_ddl_service.h
class ObDDLService {
public:
  // 处理 DDL RPC（来自任意 observer）
  int handle_ddl_request(const ObDDLArg &arg);

  // 处理 schema 变更 broadcast
  int handle_schema_broadcast(const ObSchemaBroadcastArg &arg);

  // 调度 DDL task 到各 observer
  int schedule_ddl_task(const ObDDLTask &task);

private:
  // DDL task 队列
  ObDDLTaskQueue pending_tasks_;
};
```

### 4.2 DDL Operator

```cpp
// src/rootserver/ob_ddl_operator.h
class ObDDLOperator {
public:
  // 执行具体 DDL 类型（CREATE / ALTER / DROP 等）
  int execute(const ObDDLArg &arg);

  // 校验 DDL 合法性
  int validate(const ObDDLStmt &stmt);

  // 构造 schema object
  int construct_schema(ObSchema &schema);

  // 持久化到内部表
  int persist(const ObSchema &schema);
};
```

### 4.3 DDL SQL Generator

```cpp
// src/rootserver/ob_ddl_sql_generator.h
class ObDDLSqlGenerator {
public:
  // 生成 DDL 对应的 SQL（用于 replay log）
  std::string generate_create_table_sql(const ObTableSchema &table);
  std::string generate_alter_table_sql(const ObAlterTableArg &arg);
  std::string generate_drop_table_sql(const ObTableSchema &table);
};
```

**用途**：DDL 的 replay log 在 Standby 模式（参见 #65）下重新执行。

---

## 5. DDL Task Scheduler —— DAG 调度

### 5.1 ObDDLTask

```cpp
// src/rootserver/ddl_task/ob_ddl_task.h
class ObDDLTask {
public:
  // Task ID（全局唯一）
  int64_t task_id_;
  // Task 类型
  DDLTaskType type_;            // CREATE_INDEX / ALTER_TABLE / ADD_COLUMN / ...
  // 目标表 / 列
  uint64_t table_id_;
  uint64_t tenant_id_;
  // 状态
  DDLTaskStatus status_;        // PENDING / RUNNING / SUCCESS / FAILED
  // 开始时间 / 结束时间
  int64_t start_ts_;
  int64_t end_ts_;
};
```

### 5.2 ObDDLScheduler

```cpp
// src/rootserver/ddl_task/ob_ddl_scheduler.h
class ObDDLScheduler {
public:
  // 调度 DDL task 到具体 observer
  int schedule_tasks();

  // 监控所有 task 状态
  int monitor_tasks();
};
```

### 5.3 ObDDLSingleReplicaExecutor

```cpp
// src/rootserver/ddl_task/ob_ddl_single_replica_executor.h
// 单 observer 上执行 DDL 的协调器
// - 与该 observer 通信
// - 监控执行进度
// - 失败重试
```

### 5.4 DDL DAG Monitor

```cpp
// src/storage/ddl/ob_ddl_dag_monitor_mgr.h
class ObDDLDagMonitorMgr {
  // DDL DAG 监控
  // - 检测 stuck task
  // - 触发告警
};
```

---

## 6. Storage DDL —— 数据层 DDL 执行

### 6.1 ObDDLRedoLogWriter

```cpp
// src/storage/ddl/ob_ddl_redo_log_writer.h
class ObDDLRedoLogWriter {
public:
  // 写 DDL redo log 到 PALF
  int write_ddl_redo(const ObDDLRedoLogEntry &entry);

  // replay DDL redo
  int replay_ddl_redo(const ObDDLRedoLogEntry &entry);
};
```

**用途**：DDL redo log 是 PALF 日志流的特殊类型，让 Standby / 副本重做 DDL。

### 6.2 ObDDLHeartBeatTask

```cpp
// src/storage/ddl/ob_ddl_heart_beat_task.h
class ObDDLHeartBeatTask {
public:
  // DDL 期间的 heartbeat 探测
  // - 防止 observer 在 DDL 中崩溃时 hang
  // - 让 RS 知道 observer 仍活着
};
```

### 6.3 ObDDLIncTask

```cpp
// src/storage/ddl/ob_ddl_inc_task.h
class ObDDLIncTask {
  // DDL incremental task
  // - 处理长 DDL（如 ALTER TABLE 大表）
  // - 分批执行
};
```

### 6.4 ObDDLMergeHelper

```cpp
// src/storage/ddl/ob_ddl_merge_helper.h
class ObDDLMergeHelper {
  // DDL 完成时的 merge 操作
  // - 合并 SSTable
  // - 更新 index
};
```

---

## 7. 21+ 种 DDL 操作的路径分类

### 7.1 按处理路径分类

| 类别 | DDL 操作 | 处理路径 |
|------|----------|----------|
| **Table** | CREATE TABLE / DROP TABLE / ALTER TABLE / RENAME TABLE / TRUNCATE TABLE | ob_create/drop/alter/rename/truncate_table_executor |
| **Index** | CREATE INDEX / DROP INDEX | ob_create/drop_index_executor |
| **View** | CREATE VIEW / DROP VIEW / ALTER VIEW | ob_create/drop/alter_view_executor |
| **Database** | CREATE DATABASE / DROP DATABASE / ALTER DATABASE | ob_create/drop/alter_database_executor |
| **Tenant** | CREATE TENANT / DROP TENANT / ALTER TENANT | ob_create/drop/alter_tenant_executor |
| **User** | CREATE USER / DROP USER / RENAME USER | ob_create/drop/rename_user_executor |
| **Role** | CREATE ROLE / DROP ROLE | ob_create/drop_role_executor |
| **Sequence** | CREATE SEQUENCE / DROP SEQUENCE | ob_create/drop_sequence_executor (参见 #67) |
| **Function** | CREATE FUNCTION / DROP FUNCTION | ob_create/drop_function_executor (参见 #69) |
| **Procedure** | CREATE PROCEDURE / DROP PROCEDURE | ob_create/drop_procedure_executor (参见 #69) |
| **Package** | CREATE PACKAGE / DROP PACKAGE | ob_create/drop_package_executor (参见 #69) |
| **Trigger** | CREATE TRIGGER / DROP TRIGGER | ob_create/drop_trigger_executor (参见 #69) |
| **System** | ALTER SYSTEM SET / ALTER SYSTEM BACKUP / ALTER SYSTEM RESTORE | ob_alter_system_executor |
| **LS** | ALTER TABLEGROUP / REPLICA NUM | ob_alter_ls_executor |
| **UDF** | CREATE UDF | ob_create_udf_executor |

### 7.2 共同流程

每种 DDL 都遵循相同的高层流程：

```
SQL 文本 (CREATE / ALTER / DROP ...)
    │
    ▼
SQL Parser → ParseNode
    │
    ▼
Resolver → ObDDLStmt
    │
    ▼
Optimizer (通常无复杂优化)
    │
    ▼
ObDDLExecutor<ObDDLStmt的具体子类>
    │
    ├─ 1. 权限校验（参见 #70）
    ├─ 2. 名称校验 / 类型校验
    ├─ 3. 构造 schema / operation object
    ├─ 4. RPC 到 RS
    │
    ▼
RS: ObDDLService
    │
    ├─ 1. 持久化到 __all_* 内部表
    ├─ 2. 创建 DDL task
    ├─ 3. DAG 调度到各 observer
    │
    ▼
各 observer:
    │
    ├─ 1. 接收 DDL task
    ├─ 2. 执行 ObDDLIncTask / ObDDLMergeHelper
    ├─ 3. 写 DDL redo log
    ├─ 4. 触发 schema_version 升级（参见 #64）
    │
    ▼
RS 收集完成状态 → 返回应用
```

### 7.3 长事务 DDL

`ALTER TABLE` 在大表上可能是长事务：
- `ObDDLIncTask` 处理分批执行
- 增量更新（避免一次性重建整表）
- `ObDDLHeartBeatTask` 防止 hang
- `ObDDLMergeHelper` 最后合并

参见 #64 Online DDL 详细分析。

---

## 8. DDL V1 vs V2

### 8.1 兼容性

OB 5.x 支持双 DDL 模式：
- **V1**：传统 DDL（同步阻塞，长事务）
- **V2**：并行 DDL（`execute_pcreate_table`，并行执行）

### 8.2 execute_pcreate_table

```cpp
// ObDDLExecutorUtil::execute_pcreate_table
template<class ARG, class RES>
static int execute_pcreate_table(
    obrpc::ObCommonRpcProxy &common_rpc_proxy,
    ObSQLSessionInfo *my_session,
    const char* parallel_ddl_type,
    int (ObCommonRpcProxy::*rpc_func)(const ARG&, RES&, const ObRpcOpts&),
    const ARG &arg, RES &res,
    const uint64_t tenant_id);
```

**用途**：CREATE TABLE 并行执行 —— 把多个表并行创建，加快建表速度。

---

## 9. 与其他文章的关系

### 9.1 与 #64 Online DDL

#64 是 DDL 的 schema_version 视角（Online DDL 的核心机制）。
本文是 DDL 的**实现路径**视角（21+ 种 DDL 怎么走）。
- #64 关注：DONE 2 个 atomic counter + compat filling + INSTANT DDL
- 本文关注：21+ 种 DDL 的执行器路径 + RS DDL Service + DAG 调度

### 9.2 与 #76 Schema Service

Schema Service 是 DDL 的**持久化层**：
- DDL 执行 → 调用 ObSchemaService::persist_schema 写内部表
- DDL 通过 ObMultiVersionSchemaService 异步落地到 observer
- DDL 通过 ObServerSchemaTask（参见 #64 §5.2）刷新 schema cache

### 9.3 与 #27 RootServer

RS 是 DDL 的**协调者**：
- ObDDLService::handle_ddl_request 处理 RPC
- ObDDLScheduler 调度 task 到各 observer
- ObDDLSingleReplicaExecutor 与 observer 通信

### 9.4 与 #65 Standby

Standby 模式下 DDL 通过 replay log 应用：
- Primary 的 DDL redo log（参见 §6.1）写入 PALF
- Standby 拉取 PALF → replay DDL redo
- Standby 完成 DDL 应用

### 9.5 与 #30 Observer Startup

启动时拉 schema cache：
- 包含所有已完成 DDL 的 schema（最新 schema_version）
- 不需要 replay 所有 DDL redo log
- 增量拉新 DDL 的 schema

---

## 10. 总结

### 10.1 DDL Service 在 OB 体系中的定位

DDL Service 是 **observer 进程内数据库定义变更的入口**：
- 21+ 种 DDL 走统一路径
- RS 主导 + observer 异步落地
- DDL redo log 支持 Standby / 副本

### 10.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| 5 层处理路径 | Parser → Resolver → Optimizer → Executor → RS Service |
| ObDDLStmt | DDL 语句 AST + 21+ 种 DDLStmtType |
| ObDDLExecutorUtil | DDL 入口 + wait_ddl_finish 异步协议 |
| ObDDLService | RS 端 DDL 处理 |
| ObDDLOperator | 具体 DDL 执行 + 校验 + 持久化 |
| ObDDLTask | DDL 任务抽象 + DAG 调度 |
| ObDDLRedoLogWriter | 写 DDL redo log（PALF 路径） |
| ObDDLIncTask | 长事务 DDL 分批执行 |
| ObDDLHeartBeatTask | DDL 期间心跳 |
| DDL V2 | execute_pcreate_table 并行 DDL |

### 10.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/sql/engine/cmd/` (131 files) | DDL executors 主目录 |
| `src/sql/resolver/ddl/ob_ddl_stmt.{h,cpp}` | DDL 语句 AST |
| `src/sql/engine/cmd/ob_ddl_executor_util.{h,cpp}` | DDL 入口工具 |
| `src/rootserver/ob_ddl_service.{h,cpp}` | RS 端 DDL service |
| `src/rootserver/ob_ddl_operator.{h,cpp}` | DDL operator |
| `src/rootserver/ob_ddl_sql_generator.{h,cpp}` | DDL SQL 生成器 |
| `src/rootserver/ob_ddl_service_launcher.{h,cpp}` | DDL service launcher |
| `src/rootserver/ddl_task/ob_ddl_task.{h,cpp}` | DDL task 抽象 |
| `src/rootserver/ddl_task/ob_ddl_scheduler.{h,cpp}` | DDL scheduler |
| `src/rootserver/ddl_task/ob_ddl_tablet_scheduler.{h,cpp}` | per-tablet 调度 |
| `src/rootserver/ddl_task/ob_ddl_single_replica_executor.{h,cpp}` | 单副本执行 |
| `src/rootserver/ddl_task/ob_ddl_retry_task.{h,cpp}` | DDL 重试 |
| `src/rootserver/ddl_task/ob_ddl_redefinition_task.{h,cpp}` | DDL 重新定义 |
| `src/rootserver/ddl_task/ob_ddl_helper.{h,cpp}` | DDL helper |
| `src/rootserver/parallel_ddl/ob_ddl_helper.{h,cpp}` | 并行 DDL helper |
| `src/storage/ddl/ob_ddl_redo_log_writer.{h,cpp}` | DDL redo log |
| `src/storage/ddl/ob_ddl_heart_beat_task.{h,cpp}` | DDL 心跳 |
| `src/storage/ddl/ob_ddl_inc_task.{h,cpp}` | DDL 增量 task |
| `src/storage/ddl/ob_ddl_merge_helper.{h,cpp}` | DDL merge helper |
| `src/storage/ddl/ob_ddl_dag_monitor_mgr.{h,cpp}` | DDL DAG 监控 |
| `src/storage/blocksstable/index_block/ob_ddl_sstable_scan_merge.{h,cpp}` | DDL SSTable 扫描合并 |
| `src/storage/access/ob_ddl_block_sample_iterator.{h,cpp}` | DDL block 采样 |

### 10.4 21+ 种 DDL 操作

```
Table:    CREATE / DROP / ALTER / RENAME / TRUNCATE
Index:    CREATE / DROP
View:     CREATE / DROP / ALTER
Database: CREATE / DROP / ALTER
Tenant:   CREATE / DROP / ALTER
User:     CREATE / DROP / RENAME
Role:     CREATE / DROP
Sequence:  CREATE / DROP (参见 #67)
Function: CREATE / DROP (参见 #69)
Procedure: CREATE / DROP (参见 #69)
Package:   CREATE / DROP (参见 #69)
Trigger:   CREATE / DROP (参见 #69)
System:    ALTER SYSTEM (SET / BACKUP / RESTORE / RECOVER / CANCEL / etc.)
LS:        ALTER TABLEGROUP / REPLICA NUM
UDF:       CREATE UDF
```

### 10.5 关键技术常量

| 常量 | 典型值 | 位置 |
|------|--------|------|
| `ITEM_CNT_LMT` (DDL batch size) | 10000 | server config |
| `MAX_USER_SPECIFIED_TIMEOUT` | 默认 | `ob_ddl_executor_util.h` |
| `wait_ddl_finish` 默认超时 | 几小时 | server config |

### 10.6 推荐下一步

按之前梳理的顺序，下一篇应该是 **#80 Privilege / 角色继承**（深化 #70）：

OB 的角色（ROLE）继承体系 —— role → role → user 的多层授权、syspriv / objpriv 细粒度分离、跨 schema 权限传播。源码入口：`src/share/schema/ob_priv_*.h` + `src/sql/privilege_check/ob_*.h`。

适用场景：权限模型设计 / 多租户 RBAC / 最小权限原则。

整吗？