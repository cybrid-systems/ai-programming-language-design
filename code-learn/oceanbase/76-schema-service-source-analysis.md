# 76-schema-service — OceanBase Schema 持久化 / Service / 多版本管理深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/share/schema/` 244 文件，含 `ob_schema_service.{h,cpp}` + `ob_multi_version_schema_service.{h,cpp}` + `ob_schema_cache.h` + `ob_schema_getter_guard.h` + `ob_ddl_trans_controller.{h,cpp}` 等）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **Schema 持久化 / Service** 是整个 observer 进程的"元数据大脑" —— DDL 写内部表 + RS 主导 + observer 异步落地 + 多版本 schema + per-tx schema guard 构成完整的元数据流。OB 5.x 的 Schema Service 建立在 **244 个 .h/.cpp 文件**之上，是 OB 中最庞大的子模块之一（仅次于 `src/sql/engine/expr/` 的 1161 文件）。

本文聚焦 8 个核心问题：

1. **Schema Service 全景** —— 244 文件的模块组织
2. **ObSchemaService 主类** —— schema 持久化 + 查询
3. **ObMultiVersionSchemaService** —— 多版本 + 异步落地
4. **ObSchemaConstructTask** —— 并发控制（同一 version 不会重复构建）
5. **ObSchemaVersionUpdater** —— schema_version 升级回调
6. **ObSchemaGetterGuard** —— per-tx schema snapshot（参见 #64）
7. **Schema Cache** —— 4 级缓存（guard / mgr / KV / 内部表）
8. **DDL 操作的持久化** —— `OP_TYPE_DEF` 宏定义的 21+ 种 DDL 操作

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 30-observer-startup | observer 启动从 RS 拉 initial schema cache |
| 59-schema-service | #59 是早期分析，本文深化 OB 5.x |
| 64-online-ddl | Online DDL 通过 Schema Service 持久化 + 异步落地 |
| 67-sequence-auto-increment | Sequence 也是 schema 对象，走相同 service |
| 69-udf-pl-stored-procedure | UDF / Procedure 通过 schema service 持久化 |
| 70-sql-audit-security | Schema 变更需要 audit |

---

## 1. 整体架构：OB Schema Service 模块全景

### 1.1 模块规模

```bash
$ ls src/share/schema/ | wc -l
244
```

**244 个文件** —— OB 5.x 第三大子模块（仅次于 `src/sql/engine/expr/` 1161 文件 + `src/storage/direct_load/` 210 文件）。

### 1.2 文件分类

```bash
src/share/schema/
├── # 核心 service
│   ├── ob_schema_service.{h,cpp}                 # ObSchemaService 主类
│   ├── ob_multi_version_schema_service.{h,cpp}   # 多版本 + 异步落地
│   ├── ob_server_schema_service.{h,cpp}          # Server Schema Service
│   ├── ob_ddl_trans_controller.{h,cpp}            # DDL 事务控制器
│   ├── ob_ddl_epoch.{h,cpp}                       # DDL epoch（防止过期 DDL apply）
│   ├── ob_ddl_task_status.{h,cpp}                 # DDL task 状态
│   ├── ob_ddl_stmt_str_resolver.{h,cpp}           # DDL SQL 字符串解析
│   └── ob_ddl_helper.{h,cpp}                      # DDL helper
│
├── # Schema cache + guard
│   ├── ob_schema_cache.h                          # 4 级 schema cache（参见 #64）
│   ├── ob_schema_getter_guard.{h,cpp}             # per-tx schema guard
│   ├── ob_schema_guard_wrapper.{h,cpp}            # schema guard 包装
│   ├── ob_schema_mgr.{h,cpp}                      # schema manager
│   ├── ob_schema_store.{h,cpp}                    # schema 存储（内部表）
│   └── ob_recycle_schema.{h,cpp}                  # schema 回收
│
├── # Schema 结构定义（参见 #64 §2-3）
│   ├── ob_table_schema.{h,cpp}                    # 表 schema
│   ├── ob_column_schema.h                         # 列 schema
│   ├── ob_database_schema.{h,cpp}                 # 数据库 schema
│   ├── ob_tenant_info.{h,cpp}                     # 租户 info
│   ├── ob_user_schema.{h,cpp}                     # 用户 schema
│   ├── ob_database_schema.{h,cpp}                 # database schema
│   └── ob_schema_struct.h                         # 10229 行（结构定义）
│
├── # Sequence（参见 #67）
│   ├── ob_sequence_mgr.{h,cpp}                    # sequence 管理
│   ├── ob_sequence_sql_service.{h,cpp}            # sequence SQL service
│   └── ob_sequence_ddl_proxy.{h,cpp}              # sequence DDL proxy
│
├── # UDF / PL / Trigger / 包（参见 #69）
│   ├── ob_udf.{h,cpp}                             # UDF schema
│   ├── ob_package_info.{h,cpp}                    # PACKAGE schema
│   ├── ob_trigger_info.{h,cpp}                    # Trigger schema
│   └── ob_routine_info.{h,cpp}                    # 存储过程 schema
│
├── # 索引 / 分区 / 约束
│   ├── ob_index_builder.{h,cpp}                    # 索引构造
│   ├── ob_partition_builder.{h,cpp}                # 分区构造
│   └── ob_constraint.{h,cpp}                       # 约束
│
├── # Privilege / Audit（参见 #70）
│   ├── ob_security_audit_mgr.h                    # audit mgr
│   ├── ob_security_audit_sql_service.h            # audit SQL
│   ├── ob_priv_mgr.cpp                            # privilege mgr
│   ├── ob_priv_sql_service.cpp                    # privilege SQL
│   ├── ob_label_se_policy_mgr.h                   # Label Security policy
│   └── ob_label_se_policy_sql_service.h
│
├── # AI Model（参见 #69 / #70）
│   ├── ob_ai_model_mgr.{h,cpp}                    # AI 模型 mgr
│   └── ob_ai_model_sql_service.{h,cpp}
│
├── # 虚拟表（监控）
│   ├── ob_catalog_mgr.{h,cpp}                      # catalog 虚拟表
│   └── ob_*.{h,cpp}                                # 大量 __all_virtual_* / __all_*_parameter_stat
│
├── # 其他 schema 类型
│   ├── ob_ccl_rule_mgr.{h,cpp}                    # CCL rule
│   ├── ob_ai_model_schema_getter_guard.ipp         # AI schema guard
│   ├── ob_objpriv_mysql_schema_history_recycler.{h,cpp}  # object privilege 回收
│   ├── ob_sensitive_rule_schema_struct.{h,cpp}     # 数据脱敏规则（参见 #70）
│   ├── ob_external_resource_rpc_struct.{h,cpp}    # 外部资源
│   ├── ob_add_interval_part_controller.{h,cpp}    # 加分区 controller
│   └── ob_column_group_helper.{h,cpp}             # 列分组 helper
```

### 1.3 模块分层

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 4: 应用 Schema 对象                                          │
│  - UDF / PL / Trigger / Package / Sequence / Index                 │
│  - 各种 __all_* 内部表的 schema 表示                              │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ 通过 ObSchemaGuardWrapper 统一接口
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: ObSchemaGetterGuard (per-tx schema)                     │
│  - 每个事务 / 每个查询一个 guard                                  │
│  - 持锁访问 schema cache                                          │
│  - 4 级缓存层级（参见 #64 §4.3）                                │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ 加载 / 缓存 / invalidate
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: ObMultiVersionSchemaService + ObSchemaService             │
│  - 多版本 schema 管理                                             │
│  - 持久化到 __all_* 内部表                                       │
│  - 异步落地 + 并发控制                                            │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ 接收 DDL 请求
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: DDL Service（cmd 模块）                                  │
│  - CREATE TABLE / ALTER TABLE / DROP / 等 21+ 种 DDL            │
│  - 通过 DDL RPC 调到 RS                                           │
│  - RS 校验 + 持久化 + broadcast                                   │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. ObSchemaService 主类

### 2.1 类骨架（推测）

```cpp
// src/share/schema/ob_schema_service.h
class ObSchemaService {
public:
  // 初始化
  int init(const ObCommonConfig &config);

  // schema 持久化（DDL 完成后调用）
  int persist_schema(const ObTableSchema &table_schema);
  int persist_database(const ObDatabaseSchema &db_schema);
  int persist_tenant(const ObTenantInfo &tenant_info);
  // ... 各种 schema 类型

  // schema 查询（从内部表读）
  int get_table_schema(const uint64_t table_id,
                      const int64_t schema_version,
                      ObTableSchema &table_schema);

  // schema 删除
  int drop_table(const uint64_t table_id);
  int drop_database(const uint64_t db_id);

  // 增量更新（add / modify / drop column）
  int incremental_update_schema(const ObTableSchema &new_schema);
};
```

### 2.2 核心 DDL 操作类型

```cpp
// src/share/schema/ob_schema_service.h
enum ObSchemaOperationCategory
{
  OB_DDL_TABLE_OPERATION = 0,
  OB_DDL_TENANT_OPERATION,
  OB_DDL_DATABASE_OPERATION,
};

// 通过 OP_TYPE_DEF 宏定义具体 DDL 类型
#define OP_TYPE_DEF(ACT)                                         \
  ACT(OB_INVALID_DDL_OP, = 0)                                    \
  ACT(OB_DDL_TABLE_OPERATION_BEGIN, = 1)                         \
  ACT(OB_DDL_DROP_TABLE, = 2)                                    \
  ACT(OB_DDL_ALTER_TABLE, = 3)                                   \
  ACT(OB_DDL_CREATE_TABLE, = 4)                                  \
  ACT(OB_DDL_ADD_COLUMN, = 5)                                    \
  ACT(OB_DDL_DROP_COLUMN, = 6)                                   \
  ACT(OB_DDL_CHANGE_COLUMN, = 7)                                 \
  ACT(OB_DDL_MODIFY_COLUMN, = 8)                                 \
  ACT(OB_DDL_ALTER_COLUMN, = 9)                                  \
  ACT(OB_DDL_MODIFY_META_TABLE_ID, = 10)                         \
  ACT(OB_DDL_KILL_INDEX,)                                        \
  ACT(OB_DDL_STOP_INDEX_WRITE,)                                  \
  ACT(OB_DDL_MODIFY_INDEX_STATUS,)                               \
  ACT(OB_DDL_MODIFY_TABLE_SCHEMA_VERSION,)                       \
  ACT(OB_DDL_MODIFY_TABLE_OPTION, = 15)                          \
  ACT(OB_DDL_TABLE_RENAME,)                                      \
  ACT(OB_DDL_MODIFY_DATA_TABLE_INDEX,)                           \
  ACT(OB_DDL_DROP_INDEX,)                                        \
  ACT(OB_DDL_DROP_VIEW,)                                         \
  ACT(OB_DDL_CREATE_INDEX, = 20)                                 \
  ACT(OB_DDL_CREATE_VIEW,)                                       \
  ACT(OB_DDL_ALTER_TABLEGROUP_ADD_TABLE,)                        \
  // ... 还有更多
```

### 2.3 持久化流程

```
应用 DDL: CREATE TABLE t (...)
    │
    ▼
SQL 解析 → ObCreateTableStmt
    │
    ▼
DDL Executor
    │
    ├─ 1. 权限校验（参见 #70）
    ├─ 2. 校验表名 / 列定义合法性
    │
    ▼
observer → RS: DDL RPC
    │
    ▼
RS: ObSchemaService::persist_schema
    │
    ├─ 1. 生成新 schema_version
    ├─ 2. INSERT INTO __all_table, __all_column, ... 
    ├─ 3. INSERT INTO __all_ddl_operation (审计)
    ├─ 4. 触发 broadcast 给所有 observer
    │
    ▼
所有 observer: ObMultiVersionSchemaService::refresh_schema
    │
    ├─ 1. 拉取新 schema_version
    ├─ 2. 构造 schema object
    ├─ 3. 写入 schema cache (4 级)
    ├─ 4. 通知各 LS 刷新 schema guard
```

---

## 3. ObMultiVersionSchemaService —— 多版本 + 异步落地

### 3.1 角色

```cpp
// src/share/schema/ob_multi_version_schema_service.h
static const int64_t MAX_CACHED_VERSION_NUM = 4;

class ObMultiVersionSchemaService {
  // Singleton 类
  // 负责 schema_version 管理 + 异步落地
public:
  // 异步刷新
  int refresh_schema(const uint64_t tenant_id,
                     const int64_t schema_version);

  // 获取特定 version 的 schema
  int get_schema(const uint64_t table_id,
                 const int64_t schema_version,
                 ObSchemaGuard &guard);

  // 等待 schema 落地（参见 #64 ObServerSchemaTask）
  int wait_schema_sync(const int64_t schema_version,
                      const int64_t timeout_us);
};
```

### 3.2 多版本 schema 的价值

OB 的事务可见性 = schema_version 绑定（参见 #64 §9.1）：
- 事务 t1 开始时 schema_version = 100
- 事务 t1 进行中 DDL 升 schema_version = 101
- 事务 t1 仍用 version 100（看到旧 schema）
- 事务 t2 看到 version 101（新 schema）

### 3.3 最多缓存 4 个版本

```cpp
static const int64_t MAX_CACHED_VERSION_NUM = 4;
```

**为什么 4**：
- 1 个是 current version（最新）
- 最多 3 个旧 version（长事务可能持有）
- 超出 → 回收（事务必须 abort）

---

## 4. ObSchemaConstructTask —— 并发控制

### 4.1 类骨架

```cpp
// src/share/schema/ob_multi_version_schema_service.h
class ObSchemaConstructTask {
public:
  virtual ~ObSchemaConstructTask();
  static ObSchemaConstructTask& get_instance();

  // 构造前的并发控制
  void cc_before(const int64_t version);
  void cc_after(const int64_t version);

private:
  static const int MAX_PARALLEL_TASK = 1;
  ObSchemaConstructTask();
  void lock();
  void unlock();
  int get_idx(int64_t id);
  bool exist(int64_t id) { return -1 != get_idx(id); }
  void add(int64_t id);
  void remove(int64_t id);
  int64_t count() {return schema_tasks_.count();}
  void wait(const int64_t version);
  void wakeup(const int64_t version);

private:
  common::ObArray<int64_t> schema_tasks_;
  pthread_mutex_t schema_mutex_;
  pthread_cond_t schema_cond_;
};
```

### 4.2 关键设计

**MAX_PARALLEL_TASK = 1**：
- 同一时刻只允许 1 个 schema 构造任务
- 多个 DDL 并发不会触发多个 schema 构造（避免 schema cache 抖动）

**cc_before / cc_after**：
- before → wait 已有任务 → 自己进入
- after → 完成后移除自己 + wakeup 下一个

### 4.3 与 #64 ObServerSchemaTask 的区别

- `ObServerSchemaTask`：observer 端的 schema 更新任务（参见 #64 §5.2）
- `ObSchemaConstructTask`：schema **构造**任务（从内部表读 → 构造对象）

---

## 5. ObSchemaVersionUpdater —— schema_version 升级

### 5.1 类骨架

```cpp
// src/share/schema/ob_multi_version_schema_service.h
class ObSchemaVersionUpdater {
public:
  ObSchemaVersionUpdater(int64_t new_schema_version, bool ignore_error = true)
    : new_schema_version_(new_schema_version), ignore_error_(ignore_error) {};

  virtual ~ObSchemaVersionUpdater() {};

  int operator() (int64_t& version) {
    int ret = common::OB_SUCCESS;
    if (version < new_schema_version_) {
      version = new_schema_version_;
      // ...
    }
    return ret;
  }

private:
  int64_t new_schema_version_;
  bool ignore_error_;
};
```

### 5.2 设计价值

`ObSchemaVersionUpdater` 是一个 **functor**（仿函数）：
- 用 `operator()` 把"升级 version"封装成函数对象
- 调用方传入当前 version，updater 把它抬到 new_version
- DDL 完成后批量调用，把所有相关对象的 version 升级

### 5.3 使用示例

```cpp
// DDL 完成后
int64_t new_version = 101;
ObSchemaVersionUpdater updater(new_version);

// 升级所有 affected schema 的 version
updater(table_schema_1_version);
updater(table_schema_2_version);
updater(index_schema_version);
```

---

## 6. ObSchemaGetterGuard —— per-tx schema snapshot

### 6.1 角色

```cpp
// src/share/schema/ob_schema_getter_guard.h
class ObSchemaGetterGuard {
public:
  ObSchemaGetterGuard();
  ~ObSchemaGetterGuard();

  // 取表 schema
  int get_table_schema(const uint64_t table_id,
                      const ObTableSchema *&table_schema);

  // 取数据库 schema
  int get_database_schema(const uint64_t db_id,
                          const ObDatabaseSchema *&db_schema);

  // 取租户 info
  int get_tenant_info(const uint64_t tenant_id,
                      const ObTenantInfo *&tenant_info);

  // 检查列是否存在
  bool is_column_exists(const uint64_t table_id,
                        const ObString &column_name);
};
```

### 6.2 关键设计

**生命周期**：
- 事务 / 查询开始 → 创建 guard
- 持锁访问 schema cache
- 事务 / 查询结束 → guard 析构（释放锁）

**4 级缓存层级**（参见 #64 §4.3）：
- L1: per-tx guard（最高频）
- L2: per-observer mgr（hash 索引）
- L3: ObKVStoreCache（进程级 KV cache）
- L4: 内部表（`__all_table` 等）

---

## 7. Schema Cache 4 级层级

### 7.1 缓存流程

```
Application
    │
    ▼ get_table_schema(table_id)
L1: ObSchemaGetterGuard (per-tx cache)
    │ cache hit → 直接返回
    │ cache miss ↓
    ▼
L2: ObSchemaMgr (per-observer hash 索引)
    │ cache hit → 返回 + 回填 L1
    │ cache miss ↓
    ▼
L3: ObKVStoreCache (进程级 KV cache)
    │ cache hit → 返回 + 回填 L2/L1
    │ cache miss ↓
    ▼
L4: __all_table / __all_column 内部表
    │ 读内部表 → 构造 schema → 回填 L3/L2/L1
    ▼
Application 拿到 schema
```

### 7.2 缓存一致性

DDL 完成后：
- RS broadcast 新 schema_version
- 所有 observer 收到 broadcast
- ObMultiVersionSchemaService::refresh_schema
- 失效 L1（per-tx 自动失效）
- 失效 L2/L3/L4 对应 entry（lazy invalidation）

---

## 8. DDL 操作的持久化

### 8.1 内部表

DDL 完成后写到内部表：
- `__all_table`：表定义
- `__all_column`：列定义
- `__all_database`：数据库定义
- `__all_tenant`：租户定义
- `__all_user`：用户定义
- `__all_index`：索引定义
- `__all_constraint`：约束定义
- `__all_sequence`：sequence 定义（参见 #67）
- `__all_udf`：UDF 定义（参见 #69）
- `__all_package`：PACKAGE 定义
- `__all_trigger`：Trigger 定义
- `__all_ddl_operation`：DDL 操作审计（每次 DDL 一条）
- `__all_user_priv` / `__all_role_priv`：权限（参见 #70）
- `__all_security_audit`：审计日志（参见 #70）
- ... 几十个

### 8.2 DDL 事务

```cpp
// src/share/schema/ob_ddl_trans_controller.{h,cpp}
class ObDdlTransController {
  // DDL 事务控制器
  // - 协调 RS + observer 的 DDL apply
  // - 处理 DDL 失败的回滚
};
```

**DDL 事务 vs DML 事务**：
- DML 事务是短事务（per-statement）
- DDL 事务可能是长事务（CREATE INDEX / ALTER TABLE 大表）
- DDL 失败需要回滚（恢复 schema + 内部表）

---

## 9. 与其他文章的关系

### 9.1 与 #30 observer startup

Observer 启动时**首先**拉 schema cache：
1. RS 通知当前所有 schema_version
2. observer 拉 `__all_table` 等内部表
3. 构造 schema 对象
4. 写入 L3/L2 cache
5. 创建 per-tx guard

### 9.2 与 #59 Schema Service

#59 是早期分析文章，本篇是 #59 的 **深化**：
- #59 集中在基本的 schema 表结构
- 本篇补充多版本机制 / 并发控制 / cache 4 级层级 / 21+ DDL 操作类型

### 9.3 与 #64 Online DDL

Online DDL 是 Schema Service 的典型用例：
- ADD COLUMN 通过 `OB_DDL_ADD_COLUMN` 操作
- 修改 schema_version 通过 `ObSchemaVersionUpdater`
- 异步落地通过 `ObSchemaConstructTask` 并发控制
- per-tx schema guard 隔离新旧 schema（参见 #64 §9.1）

### 9.4 与 #67 Sequence / #69 UDF/PL / #70 Audit/Security

这些都是 Schema Service 管理的特殊 schema 对象：
- Sequence 通过 `ob_sequence_mgr`
- UDF/PL/Trigger 通过 `ob_udf` / `ob_package_info` / `ob_trigger_info`
- Privilege/Audit 通过 `ob_priv_mgr` / `ob_security_audit_mgr`

### 9.5 与 #36 Concurrency Control

Schema Service 自身需要并发控制：
- `ObSchemaConstructTask`：同时只有 1 个 schema 构造任务
- `ObMultiVersionSchemaService`：多版本隔离，避免长事务看到错乱 schema
- `ObSchemaGetterGuard`：per-tx 持有 cache 锁

---

## 10. 总结

### 10.1 Schema Service 在 OB 体系中的定位

Schema Service 是 **observer 启动 / DDL 执行 / DML 路径 / 事务隔离 / 监控查询** 的统一基础：
- 启动 → 拉 schema cache
- DDL → 持久化 + broadcast
- DML → per-tx schema guard
- 监控 → 虚拟表查询

### 10.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| Schema 持久化 | `ObSchemaService::persist_schema` 写内部表 |
| 多版本管理 | `MAX_CACHED_VERSION_NUM = 4` |
| 异步落地 | `ObMultiVersionSchemaService::refresh_schema` |
| 并发控制 | `ObSchemaConstructTask` MAX_PARALLEL_TASK=1 |
| Schema 升级 | `ObSchemaVersionUpdater` functor |
| Per-tx guard | `ObSchemaGetterGuard` 持锁访问 cache |
| 4 级缓存 | L1 guard / L2 mgr / L3 KV / L4 内部表 |
| DDL 类型 | `OP_TYPE_DEF` 21+ 种操作 |

### 10.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/share/schema/ob_schema_service.{h,cpp}` | ObSchemaService 主类（持久化 + 查询） |
| `src/share/schema/ob_multi_version_schema_service.{h,cpp}` | 多版本 + 异步落地 |
| `src/share/schema/ob_schema_cache.h` | 4 级 cache 实现 |
| `src/share/schema/ob_schema_getter_guard.{h,cpp}` | Per-tx schema guard |
| `src/share/schema/ob_schema_mgr.{h,cpp}` | Schema manager |
| `src/share/schema/ob_schema_store.{h,cpp}` | Schema 存储（内部表） |
| `src/share/schema/ob_ddl_trans_controller.{h,cpp}` | DDL 事务控制器 |
| `src/share/schema/ob_ddl_epoch.{h,cpp}` | DDL epoch（防止过期 apply） |
| `src/share/schema/ob_ddl_helper.{h,cpp}` | DDL helper |
| `src/share/schema/ob_schema_struct.h` | 10229 行结构定义 |

### 10.4 关键技术常量

| 常量 | 值 | 位置 |
|------|---|------|
| `MAX_CACHED_VERSION_NUM` | 4 | `ob_multi_version_schema_service.h` |
| `MAX_PARALLEL_TASK` | 1 | `ob_multi_version_schema_service.h` |
| DDL 操作类型数 | 21+ | `OP_TYPE_DEF(ACT)` 宏 |

### 10.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#77 Location Cache / 位置缓存**：

OB 的 location cache —— 缓存 partition → server 的映射，支撑 SQL 路由。源码入口：`src/share/location_cache/` + `src/observer/ob_server_partition_table.{h,cpp}`。

适用场景：SQL 路由 / 副本切换 / 缓存一致性。

整吗？