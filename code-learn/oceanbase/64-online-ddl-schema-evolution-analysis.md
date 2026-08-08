# 64-online-ddl — OceanBase Online DDL / Schema Evolution 深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（src/share/schema/ + src/sql/engine/ + src/observer/）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

Online DDL 是数据库系统的"老大难"问题。MySQL 8.0 引入了 INSTANT 算法大幅缩短 ADD COLUMN 的执行时间，PostgreSQL 通过 catalog 版本号实现 schema 并发切换。OceanBase 的 Online DDL 是 **RS 主导 + observer 异步落地的多版本 schema 切换机制**，既要保证 DML 不阻塞，又要保证跨 observer 一致性，还要兼容 MySQL 协议语义（DEFAULT value / NULL / INDEX）。

本文聚焦 5 个核心问题：

1. **schema 在 OB 中是怎么表示的？** —— `ObTableSchema` + `ObColumnSchemaV2` + `ObSchemaCache`
2. **schema 升级是怎么被触发的？** —— `ALTER TABLE` SQL → DDL executor → RS → observer 落地
3. **observer 怎么异步刷新 schema？** —— `ObServerSchemaTask` + `ObRefreshSchemaInfo`
4. **加列时旧数据怎么处理？** —— compat filling / DEFAULT value 不重写历史
5. **长事务 / DML 与 DDL 如何共存？** —— schema_version + 多版本 schema guard

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 09-sql-executor | Online DDL 由 DAS 协调，DML 通过 DAS 读 schema |
| 10-ob-transaction | 事务开启时绑定 schema_version，事务期间 schema 升级不影响当前事务 |
| 27-rootserver | RS 是 schema 元数据的唯一源，observer 从 RS 拉取 |
| 30-observer-startup | observer 启动时从 RS 拉取 initial schema cache |
| 31-dml-path | DML 的 INSERT/UPDATE/DELETE 走 schema guard 取最新列定义 |
| 32-expression-engine | DEFAULT 表达式由 expression engine 求值 |
| 36-concurrency-control | schema_version 是事务可见性判断的一部分 |
| 41-join-operators | JOIN 多表时各表的 schema 版本可能不同 |

---

## 1. Online DDL 整体流程

### 1.1 五阶段流程

```
阶段 1: SQL 解析
    应用 → OBProxy → observer SQL 层
    "ALTER TABLE t ADD COLUMN c INT DEFAULT 0"
    ↓
    ObAlterTableStmt 解析 → ObAlterTableArg

阶段 2: DDL 校验
    observer 校验 (权限 / 兼容性 / 列约束)
    ↓
    通过 → 生成 ObTableSchema 新版本 (schema_version+1)

阶段 3: RS 持久化
    observer → RS: submit DDL task
    RS 校验 → 写 __all_ddl_operation / __all_table / __all_column 等内部表
    RS → observer: DDL task accepted, task_id

阶段 4: 异步落地
    observer 后台线程 (ObServerSchemaUpdater) 周期性 poll RS
    RS → observer: broadcast schema_version+1 到所有 observer
    每个 observer 的每个 LS 刷新 schema cache

阶段 5: 生效
    DML 走 schema guard 时看到新版本 → 使用新 schema
    旧事务继续用旧版本 (直到 commit)
```

### 1.2 关键设计原则

| 原则 | 实现 |
|------|------|
| DDL 不阻塞 DML | observer 多版本 schema guard |
| 跨 observer 一致 | RS 主导 + async broadcast |
| 失败可回滚 | DDL task retry / rollback 机制 |
| 不重写历史数据 | compat filling / INSTANT 算法 |

---

## 2. ObTableSchema —— 表级结构定义

### 2.1 文件与规模

```bash
$ wc -l src/share/schema/ob_table_schema.h
3523 src/share/schema/ob_table_schema.h
```

`ob_table_schema.h` 是 OB 中**最长的 schema 头文件之一**（仅次于 `ob_schema_struct.h` 的 10229 行），包含：

- `ObTableSchema` 类（完整表定义）
- `ObMergeSchema` 接口（虚拟方法集合）
- `ObTableMode` / `ObMvMode` / `ObHeapTableMode` 等表模式
- 各类辅助结构（column array、index array、constraint array）

### 2.2 ObMergeSchema 接口

```cpp
// src/share/schema/ob_table_schema.h:687-687
// add virtual function in ObMergeSchema, should edit ObStorageSchema & ObTableSchema

class ObMergeSchema
{
public:
  virtual ~ObMergeSchema() {}
  virtual bool is_valid() const = 0;

  // 基本属性
  virtual inline uint64_t get_tenant_id() const { return OB_INVALID_ID; }
  virtual inline int64_t get_tablet_size() const { return INVAID_RET; }
  virtual inline int64_t get_rowkey_column_num() const { return INVAID_RET; }
  virtual inline int64_t get_column_count() const { return INVAID_RET; }
  virtual inline int64_t get_schema_version() const { return INVAID_RET; }

  // 物理属性
  virtual inline int64_t get_pctfree() const { return INVAID_RET; }
  virtual inline uint64_t get_master_key_id() const { return OB_INVALID_ID; }
  virtual inline bool is_use_bloomfilter() const { return false; }
  virtual inline bool get_enable_macro_block_bloom_filter() const { return false; }
  virtual inline int64_t get_micro_block_format_version() const {
    return storage::ObMicroBlockFormatVersionHelper::DEFAULT_VERSION;
  }

  // 表类型
  virtual inline bool is_primary_aux_vp_table() const { return false; }
  virtual inline bool is_primary_vp_table() const { return false; }
  virtual inline bool is_aux_vp_table() const { return false; }
  virtual inline bool is_column_info_simplified() const { return false; }
  virtual inline bool is_storage_index_table() const = 0;
  virtual inline bool is_global_index_table() const = 0;

  // 压缩 / 加密
  virtual inline int64_t get_block_size() const { return INVAID_RET;}
  virtual inline const common::ObString &get_encrypt_key() const { return EMPTY_STRING; }
  virtual inline const char *get_encrypt_key_str() const = 0;
  virtual inline int64_t get_encrypt_key_len() const { return INVAID_RET; }
  virtual int get_encryption_id(int64_t &encrypt_id) const = 0;
  virtual const common::ObString &get_encryption_str() const = 0;
  virtual bool need_encrypt() const = 0;

  // 行存类型
  virtual inline common::ObRowStoreType get_row_store_type() const { return common::MAX_ROW_STORE; }
  virtual inline common::ObRowStoreType get_minor_row_store_type() const { return common::MAX_ROW_STORE; }
  virtual inline const char *get_compress_func_name() const {
    return all_compressor_name[ObCompressorType::NONE_COMPRESSOR];
  }
  virtual inline common::ObCompressorType get_compressor_type() const {
    return ObCompressorType::NONE_COMPRESSOR;
  }

  // 渐进合并
  virtual inline int64_t get_progressive_merge_round() const { return INVAID_RET; }
  virtual inline int64_t get_progressive_merge_num() const { return INVAID_RET; }
  // ... 50+ virtual methods total
};
```

**设计价值**：`ObMergeSchema` 是 `ObStorageSchema`（存储层只读视图） 和 `ObTableSchema`（SQL 层可写完整定义） 的共同父接口。这种 **读写分层** 让存储层只关心它需要的子集（schema_version + column_id + 数据类型），不需要关心 SQL 层特有的字段（如 DEFAULT 表达式、COMMENT）。

### 2.3 ObTableSchema 完整定义

```cpp
// src/share/schema/ob_table_schema.h
class ObTableSchema : public ObSchema, public ObMergeSchema
{
  // ...
  // 列定义
  ObColumnSchemaV2 column_array_;         // 表所有列
  ObIndexSchemaArray index_array_;        // 二级索引
  ObConstraintArray constraint_array_;    // 约束 (PK/UK/FK/CHECK)
  ObPartitionOption partition_option_;    // 分区定义

  // 物理属性
  int64_t schema_version_;               // schema 版本号 (核心)
  int64_t table_id_;
  uint64_t tenant_id_;
  int64_t tablet_size_;
  int64_t pctfree_;
  // ...

  // 时间戳
  int64_t create_time_;
  int64_t modify_time_;
};
```

`schema_version_` 是 Online DDL 的核心标识符 —— 每次 DDL 自增 1，observer 用它做版本对比 + 多版本并发。

---

## 3. ObColumnSchemaV2 —— 列定义与 compat flags

### 3.1 类骨架

```cpp
// src/share/schema/ob_column_schema.h:41
class ObColumnSchemaV2 : public ObSchema
{
public:
  // ─── 元数据 ───
  uint64_t tenant_id_;
  uint64_t table_id_;
  uint64_t column_id_;
  ObString column_name_;
  common::ObObjMeta meta_type_;          // 数据类型 + collation
  common::ObAccuracy accuracy_;          // length/precision/scale

  // ─── 约束 ───
  bool is_nullable_;
  bool is_zero_fill_;
  bool is_autoincrement_;
  bool is_hidden_;
  bool is_on_update_current_timestamp_;
  // ... bit flags via column_flags_

  // ─── 默认值 ───
  common::ObObj orig_default_value_;     // 原 default value (兼容旧版本)
  common::ObObj cur_default_value_;      // 当前 default value (DEFAULT expr v2)

  // ─── 时间戳 ───
  int64_t schema_version_;
  int64_t create_time_;
  int64_t modify_time_;

  // ─── 其他 ───
  int64_t rowkey_position_;
  int64_t index_position_;
  common::ObOrderType order_in_rowkey_;
  uint32_t srs_id_;
  uint64_t srs_info_;                    // srid + geo_type packed
  // ...
};
```

### 3.2 compat flags —— bit field 设计

`ObColumnSchemaV2` 把所有 "是否是某类型列" 状态压缩到一个 bit field `column_flags_`：

```cpp
// src/share/schema/ob_column_schema.h
// (典型定义形式 —— 实际 enum 定义在同文件)

enum ObColumnFlag {
  DEFAULT_IDENTITY_COLUMN_FLAG     = 1 << 0,
  DEFAULT_ON_NULL_IDENTITY_COLUMN_FLAG = 1 << 1,
  DEFAULT_EXPR_V2_COLUMN_FLAG      = 1 << 2,
  // ...
};

inline bool is_default_identity_column() const {
  return column_flags_ & DEFAULT_IDENTITY_COLUMN_FLAG;
}
inline bool is_default_on_null_identity_column() const {
  return column_flags_ & DEFAULT_ON_NULL_IDENTITY_COLUMN_FLAG;
}
inline bool is_default_expr_v2_column() const {
  return column_flags_ & DEFAULT_EXPR_V2_COLUMN_FLAG;
}
inline bool is_identity_column() const {
  return is_always_identity_column()
      || is_default_identity_column()
      || is_default_on_null_identity_column();
}
```

**为什么用 bit field 而不是多个 bool 成员？**
1. **内存紧凑** —— 列数万的宽表，bool 数组会浪费 cache line；bit field 节省数倍内存
2. **原子操作** —— 一个 uint32_t 可以一次 CAS，多 bool 需要多次
3. **可序列化** —— bit field 直接序列化到内部表 / RPC 协议

### 3.3 用户可见性判断 —— is_user_visible_column

```cpp
// src/share/schema/ob_column_schema.h:363
inline bool is_user_visible_column() const {
  return !(is_hidden() || is_invisible_column());
}
```

**OB 的列可见性设计**：
- **hidden 列**（`is_hidden` = true）：不暴露给用户的列（如 UDT 的 hidden 字段、clustering key 内部列）
- **invisible 列**（`is_invisible_column`）：MySQL 8.0 兼容概念，列存在但默认 SELECT * 不返回（用户需要显式指定列名）
- **用户可见列**：两者都不是

OB 用 `is_user_visible_column()` 统一判断，所有 SQL 层 / OBProxy 层 / 虚拟表层都用这个判断。

### 3.4 Hidden PK 与 UDT Hidden 列

```cpp
// src/share/schema/ob_column_schema.h:354
inline static bool is_hidden_pk_column_id(const uint64_t column_id);
// 354 → 是 hidden 主键（heap table 自动加的）

// src/share/schema/ob_column_schema.h:359
inline bool is_hidden_clustering_key_column() const {
  return ::oceanbase::share::schema::is_heap_table_clustering_key_column(column_flags_) && is_hidden();
}
// 359 → heap table 的 clustering key 是 hidden 的

// src/share/schema/ob_column_schema.h:211
inline bool is_udt_hidden_column() const {
  return get_udt_set_id() > 0 && is_hidden();
}
// 211 → UDT 内部的 hidden 字段（不会暴露给用户查询）
```

这三种 hidden 列场景体现了 OB 的 schema 设计深度：
- **Hidden PK**：heap table（无 PK 表）自动加一个 hidden PK
- **Clustering Key**：heap table 物理上按某个 key 聚簇（与 PK 不同），hidden 化避免用户混淆
- **UDT Hidden**：user-defined type 内部字段

### 3.5 DEFAULT value 与 DEFAULT EXPR v2

```cpp
// src/share/schema/ob_column_schema.h:127
inline int set_cur_default_value(const common::ObObj default_value,
                                  bool is_default_expr_v2) {
  add_or_del_column_flag(DEFAULT_EXPR_V2_COLUMN_FLAG, is_default_expr_v2);
  return deep_copy_obj(default_value, cur_default_value_);
}
```

**DEFAULT value 的兼容设计**：
- `orig_default_value_`：原版 default value（仅常量）
- `cur_default_value_`：当前 default value（可能是 DEFAULT expr，如 `DEFAULT (NOW())`）
- `DEFAULT_EXPR_V2_COLUMN_FLAG`：标记是否用了 v2 特性

这是典型的 **在线 schema 演进**：当 OB 从"只支持常量 DEFAULT"升级到"支持 DEFAULT expr"时，旧数据用 orig，新数据用 cur，通过 flag 区分。这避免了"重建表" 来支持新特性。

### 3.6 修改列类型的 flag 操作

```cpp
// ob_column_schema.h 内部（典型的）
inline void add_column_flag(uint32_t flag) {
  column_flags_ |= flag;
}
inline void del_column_flag(uint32_t flag) {
  column_flags_ &= ~flag;
}
inline void add_or_del_column_flag(uint32_t flag, bool set) {
  if (set) add_column_flag(flag);
  else del_column_flag(flag);
}
```

修改列属性（identity / default expr / 可见性）都是通过 bit flag 操作 —— 一次原子修改，不会破坏其他属性。

---

## 4. Schema 版本管理 —— SchemaCacheKey + 多版本

### 4.1 ObSchemaCacheKey —— 缓存的 key

```cpp
// src/share/schema/ob_schema_cache.h
class ObSchemaCacheKey : public common::ObIKVCacheKey
{
public:
  ObSchemaCacheKey();
  ObSchemaCacheKey(const ObSchemaType schema_type,
                   const uint64_t tenant_id,
                   const uint64_t schema_id,
                   const uint64_t schema_version);
  // ...
  TO_STRING_KV(K_(schema_type),
               K_(tenant_id),
               K_(schema_id),
               K_(schema_version));

  ObSchemaType schema_type_;
  uint64_t tenant_id_;
  uint64_t schema_id_;
  uint64_t schema_version_;
};
```

**四元组 cache key**：
- `schema_type_`：TABLE / DATABASE / TENANT / USER / OUTLINE 等
- `tenant_id_`：多租户隔离
- `schema_id_`：具体表 / DB / tenant 的 ID
- `schema_version_`：版本号（核心）

每个 `(schema_type, tenant_id, schema_id, schema_version)` 唯一标识一个 schema 版本，缓存在 OB 的 KV cache (`ObKVStoreCache`) 中。

### 4.2 多版本 schema 并存

Online DDL 期间，**同一张表可能有多个 schema_version 共存**：

```
版本 1 (旧, schema_version=100)
    - 列: id INT, name VARCHAR(64)
版本 2 (新, schema_version=101)
    - 列: id INT, name VARCHAR(64), age INT DEFAULT 0
```

**多版本的作用**：
1. 旧事务持有 schema_version=100 → 用旧 schema 解析
2. 新事务持有 schema_version=101 → 用新 schema 解析
3. 同一 LS 内可能同时存在多个版本（不同事务）

### 4.3 Schema 缓存层级

OB 的 schema 缓存是**多层**的：

```
┌─────────────────────────────────────────────────┐
│ L1: per-thread / per-tx schema guard            │  ← 最高频访问
│   (ObSchemaGetterGuard, per-query 临时)         │
└─────────────────────────────────────────────────┘
                          │
                          ▼ miss
┌─────────────────────────────────────────────────┐
│ L2: per-observer in-memory schema cache         │  ← 中频
│   (ObSchemaMgr, hash 索引)                       │
└─────────────────────────────────────────────────┘
                          │
                          ▼ miss
┌─────────────────────────────────────────────────┐
│ L3: ObKVStoreCache (进程级 KV cache)             │  ← 中低频
│   (进程重启可恢复, 共享内存)                     │
└─────────────────────────────────────────────────┘
                          │
                          ▼ miss
┌─────────────────────────────────────────────────┐
│ L4: 内部表 (__all_table / __all_column 等)      │  ← 最低频
│   (OB 自身的元数据存储)                          │
└─────────────────────────────────────────────────┘
```

每层缓存都按 `(schema_type, tenant_id, schema_id, schema_version)` 索引。

---

## 5. Online DDL 协议 —— DDL Executor + Server Schema Updater

### 5.1 ObDDLExecutorUtil —— DDL 入口与等待

```cpp
// src/sql/engine/cmd/ob_ddl_executor_util.h
class ObDDLExecutorUtil final
{
public:
  static int wait_ddl_finish(
      const uint64_t tenant_id,
      const int64_t task_id,
      const bool ddl_need_retry_at_executor,
      ObSQLSessionInfo *session,
      obrpc::ObCommonRpcProxy *common_rpc_proxy,
      const bool is_support_cancel = true,
      const int64_t wait_timeout_us = common::OB_MAX_USER_SPECIFIED_TIMEOUT);

  static int wait_ddl_retry_task_finish(
      const uint64_t tenant_id,
      const int64_t task_id,
      ObSQLSessionInfo &session,
      obrpc::ObCommonRpcProxy *common_rpc_proxy,
      int64_t &affected_rows);

  static int wait_build_index_finish(
      const uint64_t tenant_id,
      const int64_t task_id,
      bool &is_finish);

  static int handle_session_exception(ObSQLSessionInfo &session);
  static int cancel_ddl_task(
      const int64_t tenant_id,
      obrpc::ObCommonRpcProxy *common_rpc_proxy);

  template<class ARG, class RES>
  static int execute_pcreate_table(obrpc::ObCommonRpcProxy &common_rpc_proxy, ...);

private:
  static inline bool is_server_stopped() {
    return observer::ObServer::get_instance().is_stopped();
  }
};
```

**DDL Executor 的核心职责**：
1. `wait_ddl_finish`：发出 DDL RPC 后，循环 poll RS 查 DDL 任务状态（成功 / 失败 / 进行中）
2. `wait_ddl_retry_task_finish`：DDL 失败重试的场景
3. `wait_build_index_finish`：建索引是 DDL 中最慢的一种，独立等待接口
4. `execute_pcreate_table`：并行 CREATE TABLE（PG 兼容语义）
5. `is_server_stopped`：观察 observer 是否在 shutdown，决定要不要继续等 DDL

**为什么需要 `wait_ddl_finish`？**

ALTER TABLE ADD COLUMN 的服务端执行可能耗时很长（特别是建索引），同步 RPC 会阻塞 observer 的工作线程。OB 用 **异步 DDL 协议**：
- 客户端发 ALTER TABLE → observer 立即返回 task_id
- 后台 RS 异步执行
- 客户端发 `wait_ddl_finish(task_id)` → 轮询直到完成

这与 MySQL 的同步 ALTER TABLE 完全不同，OB 的设计对长事务 + 大表更友好。

### 5.2 ObServerSchemaTask —— Observer 端 schema 更新任务

```cpp
// src/observer/ob_server_schema_updater.cpp
class ObServerSchemaTask
{
public:
  // 任务类型
  enum TYPE {
    INVALID = 0,
    REFRESH,         // 同步刷新 (need_process_alone)
    RELEASE,         // 释放 (need_process_alone)
    ASYNC_REFRESH,   // 异步刷新 (按 tenant_id+schema_version 去重)
  };

  ObServerSchemaTask();
  ObServerSchemaTask(TYPE type, bool did_retry);
  ObServerSchemaTask(TYPE type, bool did_retry, const ObRefreshSchemaInfo &schema_info);
  // ...

  // 关键判断
  bool need_process_alone() const {
    return REFRESH == type_ || RELEASE == type_;
  }
  bool is_valid() const { return INVALID != type_; }

  int64_t hash() const {
    uint64_t hash_val = 0;
    hash_val = murmurhash(&type_, sizeof(type_), hash_val);
    if (ASYNC_REFRESH == type_) {
      const uint64_t tenant_id = get_tenant_id();
      const int64_t schema_version = get_schema_version();
      hash_val = murmurhash(&tenant_id, sizeof(tenant_id), hash_val);
      hash_val = murmurhash(&schema_version, sizeof(schema_version), hash_val);
    }
    return static_cast<int64_t>(hash_val);
  }

  bool operator ==(const ObServerSchemaTask &other) const {
    bool bret = (type_ == other.type_);
    if (bret && ASYNC_REFRESH == type_) {
      bret = (get_tenant_id() == other.get_tenant_id())
              && (get_schema_version() == other.get_schema_version());
    }
    return bret;
  }

  bool operator <(const ObServerSchemaTask &other) const {
    // ... (优先级排序)
  }
};
```

**任务类型分类**：

| TYPE | need_process_alone | 行为 |
|------|-------------------|------|
| `INVALID` | - | 无效任务 |
| `REFRESH` | ✅ yes | **同步刷新**：阻塞后续任务，等 schema 完全落地 |
| `RELEASE` | ✅ yes | **释放**：删除旧 schema 版本（保留一定数量做 GC） |
| `ASYNC_REFRESH` | ❌ no | **异步刷新**：按 `(tenant_id, schema_version)` 去重，可合并 |

**为什么 REFRESH/RELEASE 单独处理？**
- REFRESH：观察者刚启动或新建租户，必须先把 schema 拉到本地才能服务请求 —— 阻塞
- RELEASE：删除旧 schema 时如果与其他 REFRESH 冲突可能导致读到不存在版本 —— 阻塞
- ASYNC_REFRESH：日常 schema 增量更新（DDL 后异步推送）—— 可以合并（同一版本多次刷新只做一次）

**hash 与去重**：
- ASYNC_REFRESH 的 hash 包含 `tenant_id + schema_version`
- 这样同一版本的多次刷新任务在任务队列里被去重为单次执行
- 避免重复刷 schema（昂贵操作）

### 5.3 ObRefreshSchemaInfo —— schema 刷新元数据

```cpp
// 实际定义在 src/share/schema/ 配套文件
class ObRefreshSchemaInfo {
public:
  ObRefreshSchemaInfo();
  ~ObRefreshSchemaInfo();
  void reset();

  int assign(const ObRefreshSchemaInfo &other);
  // getters/setters
  void set_tenant_id(uint64_t tenant_id);
  uint64_t get_tenant_id() const;

  void set_schema_version(int64_t version);
  int64_t get_schema_version() const;

  // 同步点 (用于协调多 observer)
  void set_sync_timestamp(int64_t ts);
  int64_t get_sync_timestamp() const;

private:
  uint64_t tenant_id_;
  int64_t schema_version_;
  int64_t sync_timestamp_;     // 全局一致时间戳
};
```

`sync_timestamp_` 是关键 —— 它是 RS 写入新 schema 版本时的全局时间戳，所有 observer 都按这个时间戳判断"是否应该刷这个版本"。这避免了 observer 间的版本差异。

### 5.4 异步刷新流程图

```
RS broadcast new schema_version=N+1
    │
    ▼
ObServerSchemaUpdater::on_broadcast()  (observer 收到 RS 推送)
    │
    ├─ 构造 ObServerSchemaTask(ASYNC_REFRESH, tenant_id, schema_version=N+1)
    │
    ▼
TaskQueue::push(task)  (后台任务队列)
    │
    ▼
Worker thread
    │
    ├─ hash(task) → 用于去重
    ├─ 检查任务队列是否已有同 (tenant_id, schema_version) 的任务
    │    └─ 有 → 跳过（去重）
    │    └─ 没有 → 继续
    │
    ├─ 调用 ObMultiVersionSchemaService::refresh_schema(tenant_id, version=N+1)
    │    └─ 从 RS 拉取完整 schema (列、索引、约束)
    │    └─ 写入 ObSchemaCache (L3 KV cache)
    │    └─ 通知各 LS 刷新 schema guard
    │
    ▼
完成
```

---

## 6. 加列兼容机制 —— compat filling / DEFAULT value

### 6.1 核心问题

```
原始 schema (version=N):
  CREATE TABLE t (id INT, name VARCHAR(64));

ALTER TABLE t ADD COLUMN age INT DEFAULT 0;
新 schema (version=N+1):
  CREATE TABLE t (id INT, name VARCHAR(64), age INT DEFAULT 0);

问题:
  历史数据 (version=N 写入的) 没有 age 列
  读出来时 age 应该是 0 (DEFAULT)
  不能重写所有历史数据 → 必须 compat filling
```

### 6.2 Compat filling 的实现

OB 在读路径做 compat filling：

```
DML: SELECT * FROM t
    │
    ▼
SchemaGuard (用 transaction 的 schema_version)
    │
    ▼
ObStorageReader
    │
    ├─ 读取历史 row 数据 (memtable / SSTable, 旧 schema)
    │
    ▼
CompatFiller (按当前 schema_version 重新填充)
    │
    ├─ 新加列有 DEFAULT → 填充 DEFAULT 值
    ├─ 新加列无 DEFAULT 且 nullable → 填充 NULL
    ├─ 新加列无 DEFAULT 且 NOT NULL → 报错 (DDL 设计错误)
    │
    ▼
完整 row 返回给应用
```

**关键点**：compat filling 在 **读路径** 完成，不在写路径（写新数据直接写新列）。这就是 OB 的"INSTANT DDL"算法 —— 加列只改 schema 元数据，不重写历史数据。

### 6.3 列类型变更的兼容

```
ALTER TABLE t MODIFY COLUMN name VARCHAR(128);  (从 64 扩到 128)

历史数据: name 是 VARCHAR(64) 编码
新数据:   name 是 VARCHAR(128) 编码

兼容方式:
  - 读取时按当前 schema_version 解码
  - 如果列变长（64→128），旧数据扩展没问题
  - 如果列变短（128→64），旧数据需要 TRUNCATE（可能数据丢失）
```

OB 对列类型变更的限制比 MySQL 严格（MySQL 在某些场景下会做 silent truncation）。OB 通常要求 **重写表数据** 来做不兼容的类型变更。

### 6.4 INSTANT DDL vs INPLACE DDL

| 操作 | OB 算法 | MySQL 算法 |
|------|---------|-----------|
| ADD COLUMN (末尾, 无默认值) | INSTANT | INSTANT (8.0+) |
| ADD COLUMN (中间, 有 DEFAULT) | INPLACE (rewrite 部分) | INSTANT |
| ADD INDEX | INPLACE (异步构建) | INPLACE |
| DROP COLUMN | INSTANT (compaction 时回收) | INSTANT (8.0+) |
| MODIFY COLUMN (扩长) | INSTANT (compat filling) | INSTANT (部分场景) |
| MODIFY COLUMN (类型变) | COPY (重写表) | COPY (重写表) |
| RENAME TABLE | INSTANT | INSTANT |

OB 在 INSTANT 算法的覆盖范围与 MySQL 8.0 接近，但**严格的语义校验**（默认值必须、NOT NULL 约束不能违反）。

---

## 7. Schema Refresh 流程 —— per-LS Schema Guard

### 7.1 ObSchemaGetterGuard

```cpp
// src/share/schema/ob_schema_getter_guard.h
class ObSchemaGetterGuard {
public:
  ObSchemaGetterGuard();
  ~ObSchemaGetterGuard();

  // 取表的 schema (返回最新版本)
  int get_table_schema(const uint64_t table_id,
                       const ObTableSchema *&table_schema);

  // 取数据库 schema
  int get_database_schema(const uint64_t db_id,
                          const ObDatabaseSchema *&db_schema);

  // 取租户 schema
  int get_tenant_info(const uint64_t tenant_id,
                      const ObTenantInfo *&tenant_info);

  // 检查列是否存在
  bool is_column_exists(const uint64_t table_id,
                        const ObString &column_name);
};
```

每个事务 / 每个查询都创建一个 `ObSchemaGetterGuard`，持锁访问 schema cache。guard 自动管理版本号与缓存查找。

### 7.2 LS 维度的 schema 缓存

每个 LogStream 维护自己的 schema 版本（独立于 observer 整体 schema 版本）：

```
observer
  ├─ sys tenant LS (元数据)
  ├─ user_tenant_1 LS-1 (业务数据, schema_version=100)
  ├─ user_tenant_1 LS-2 (业务数据, schema_version=100)
  └─ user_tenant_2 LS-1 (业务数据, schema_version=101, 刚做完 DDL)
```

LS-1/LS-2 是同一张表的两个副本（不同 zone），都持有 schema_version=100。user_tenant_2 是另一张表，schema_version=101。

**Online DDL 流程**：
1. RS 把 user_tenant_2 升到 version=101
2. observer 收到 broadcast
3. user_tenant_2 的所有 LS 异步刷 schema cache
4. user_tenant_1 不受影响（仍是 version=100）

---

## 8. Sub-schema Context —— UDT / Enum / Collection

### 8.1 ObSubSchemaCtx 用途

```cpp
// src/sql/engine/ob_subschema_ctx.h
enum ObSubSchemaType {
  OB_SUBSCHEMA_UDT_TYPE = 0,
  OB_SUBSCHEMA_ENUM_SET_TYPE = 1,
  OB_SUBSCHEMA_COLLECTION_TYPE = 2,
  OB_SUBSCHEMA_MAX_TYPE
};

class ObSubSchemaValue
{
OB_UNIS_VERSION(1);
public:
  ObSubSchemaValue() : type_(OB_SUBSCHEMA_MAX_TYPE), signature_(0), value_(NULL),
                       allocator_(NULL) {}
  int deep_copy_value(const void *src_value, ObIAllocator &allocator);
  static bool is_valid_type(ObSubSchemaType type) {
    return type >= OB_SUBSCHEMA_UDT_TYPE && type < OB_SUBSCHEMA_MAX_TYPE;
  }
  inline bool is_valid() const { return is_valid_type(type_); }
  // ...
public:
  ObSubSchemaType type_;     // UDT/ENUM_SET/COLLECTION
  uint64_t signature_;       // 类型签名 (versioned)
  void *value_;              // 类型定义数据
  common::ObIAllocator *allocator_;
};
```

**Sub-schema 是 schema 的子模块**：
- **UDT**（User-Defined Type）：用户自定义类型（结构体）
- **ENUM_SET**：枚举 / 集合类型
- **COLLECTION**：嵌套集合类型（ARRAY / MULTISET）

每个 sub-schema 有自己的 `signature_`（类型签名），用于：
- 缓存去重（同一签名复用）
- Online DDL 时识别"类型是否变了"（签名变了 → invalidate）

### 8.2 Sub-schema 在 schema 演进中的作用

```
CREATE TABLE t (
  id INT,
  status ENUM('active', 'inactive')   -- ENUM 类型 v1, signature=0x123
);

ALTER TABLE t MODIFY status ENUM('active', 'inactive', 'pending');  -- 加枚举值

ENUM 类型 v2, signature=0x456  -- signature 变了

ObSubSchemaValue::signature_ 比对:
  v1 sig (0x123) != v2 sig (0x456)
  → 需要刷 sub-schema cache
  → 旧事务用 v1 → 写入 v1 的枚举值
  → 新事务用 v2 → 写入 v2 的枚举值
  → 兼容（旧值不会消失，只是新值可选）
```

---

## 9. 长事务 / DML during DDL 的并发语义

### 9.1 事务级 schema 隔离

```
时间线:
  t0: DML begin (tx1)
      schema_version=100
  t1: DDL "ADD COLUMN" 完成
      新 schema_version=101
  t2: tx1 还在执行
  t3: DML begin (tx2)
      schema_version=101 (新)
  t4: tx1 commit
```

**核心约束**：
- tx1 持有 schema_version=100，看到旧 schema（没有新列）
- tx2 持有 schema_version=101，看到新 schema（有新列）
- tx1 的 commit 走 **旧 schema 路径**，不影响 DDL 后状态

### 9.2 SchemaGuard 的事务隔离

```cpp
// src/sql/session/ob_sql_session_info.h (大致)
class ObSQLSessionInfo {
  // ...
  int64_t schema_version_;  // 事务开始时的 schema_version
  ObSchemaGetterGuard guard_;

  // 事务内查询 schema 都走 guard
  // guard 在事务开始时锁定 schema_version
  // 即使外部 schema 升级，事务内仍用旧版本
};
```

### 9.3 DML 的 schema guard 调用链

```
DML (INSERT/UPDATE/DELETE/SELECT)
    │
    ▼
ObSQLSessionInfo::get_schema_guard()
    │
    ▼
ObSchemaGetterGuard (持有 schema_version)
    │
    ├─ 通过 schema cache 取最新满足 schema_version 的 schema
    │
    ▼
DAS 层使用 schema 解析 SQL
    │
    ▼
Storage 层按 schema 读写
```

---

## 10. 失败与重试

### 10.1 ObDDLExecutorUtil 中的 retry

```cpp
static int wait_ddl_finish(
    const uint64_t tenant_id,
    const int64_t task_id,
    const bool ddl_need_retry_at_executor,  // ← 关键参数
    ObSQLSessionInfo *session,
    obrpc::ObCommonRpcProxy *common_rpc_proxy,
    ...);

static int wait_ddl_retry_task_finish(
    const uint64_t tenant_id,
    const int64_t task_id,
    ObSQLSessionInfo &session,
    obrpc::ObCommonRpcProxy *common_rpc_proxy,
    int64_t &affected_rows);
```

**两级 retry**：
- `wait_ddl_finish`：DDL 在执行中的失败（如网络抖动），由 observer 端重试
- `wait_ddl_retry_task_finish`：DDL 已经失败需要重试整个任务（重大错误）

### 10.2 Server 端 retry

```cpp
// ob_server_schema_updater.cpp
ObServerSchemaTask::ObServerSchemaTask(TYPE type, bool did_retry)
  : type_(type), did_retry_(did_retry), schema_info_() {}

// did_retry_ 标记这个 task 是否是重试任务
// 避免无限 retry (failed retry → another retry → ...)
```

---

## 11. 总结

### 11.1 Online DDL 在 OB 5.x 的关键设计

| 设计点 | 实现 |
|--------|------|
| schema 表示 | `ObTableSchema` + `ObColumnSchemaV2` + bit flag compat |
| schema 版本 | `schema_version_` 自增 + 4 元组 cache key |
| DDL 入口 | SQL 层解析 → ObDDLExecutorUtil → wait_ddl_finish |
| RS 主导 | `ObServerSchemaTask::ASYNC_REFRESH` 异步去重刷新 |
| observer 落地 | `ObMultiVersionSchemaService::refresh_schema` |
| 多版本共存 | per-LS schema guard + per-tx schema_version |
| INSTANT DDL | compat filling 读路径填充 + 元数据变更 |
| Sub-schema | `ObSubSchemaValue` 用于 UDT/ENUM/COLLECTION |

### 11.2 关键技术点回顾

1. **bit flag compat 设计** —— column_flags_ 紧凑表示所有列属性
2. **DEFAULT value 双版本** —— orig_default_value + cur_default_value
3. **hidden 列分类** —— hidden PK / clustering key / UDT hidden
4. **schema cache 4 级** —— L1 guard / L2 mgr / L3 KV / L4 内部表
5. **ASYNC_REFRESH 去重** —— (tenant_id, schema_version) hash
6. **need_process_alone** —— REFRESH/RELEASE 单独处理（不能合并）
7. **per-tx schema_version** —— 事务开始时锁定，DDL 不影响进行中事务
8. **compat filling 读路径** —— INSTANT DDL 不重写历史

### 11.3 与其他文章的对接

- #09 SQL executor：DDL 经过 DAS 协调
- #10 分布式事务：schema_version 是事务隔离的一部分
- #27 RootServer：RS 是 schema 唯一源
- #30 observer startup：启动时拉 initial schema
- #31 DML path：DML 走 schema guard 取列定义
- #36 concurrency control：多版本 schema 是 MVCC 的一部分

### 11.4 推荐下一步

按之前梳理的顺序，下一篇应该是 **#65 Standby cluster / Active-Standby**：

OB 4.x/5.x 的 Standby 模式是除 PALF 多副本之外的另一条 HA 主线 —— 物理备库、日志回放、读一致性、switchover 流程。源码入口：`src/observer/standby/` + `src/logservice/restoreservice/`（与 #62 cdcservice 的 archive iterator 共用）+ `src/storage/` 的 standby-aware 路径。

源码全部在 OB 主仓内，能写 file:line 级。