# Schema 与数据字典 — 元数据管理、Schema 版本

> 深度分析 OceanBase Schema 子系统：元数据管理体系、多版本 Schema 架构、线程安全访问模式与 SQL 执行集成

## 目录

1. [Schema 体系结构概览](#1-schema-体系结构概览)
2. [ObSchemaMgr — Schema 管理器的核心设计](#2-obmgr--schema-管理器的核心设计)
3. [Schema 版本管理机制](#3-schema-版本管理机制)
4. [Schema 访问模式与线程安全](#4-schema-访问模式与线程安全)
5. [Schema 与 SQL 执行集成](#5-schema-与-sql-执行集成)
6. [Schema 缓存与刷新策略](#6-schema-缓存与刷新策略)
7. [分布式 Schema 管理](#7-分布式-schema-管理)
8. [设计决策与权衡](#8-设计决策与权衡)
9. [总结](#9-总结)

---

## 1. Schema 体系结构概览

OceanBase 的 Schema 子系统位于 `src/share/schema/` 目录，包含 232 个文件，是整个数据库元数据管理的核心。它定义了数据库对象（表、列、数据库、用户、索引、视图、存储过程等）的结构、存储、访问和版本控制策略。

### 1.1 核心类层次

```
ObServerSchemaService          ← 抽象基类，定义 Schema 服务接口
  └─ ObMultiVersionSchemaService  ← 单例实现，多版本 Schema 服务
       └─ ObSchemaMgrCache        ← Schema 管理器缓存（多版本环形缓冲）
            └─ ObSchemaMgr        ← Schema 管理器，持有所有元数据
                 ├─ ObSimpleTenantSchema    ← 租户简略 Schema
                 ├─ ObSimpleUserSchema      ← 用户简略 Schema
                 ├─ ObSimpleDatabaseSchema  ← 数据库简略 Schema
                 ├─ ObSimpleTableSchemaV2   ← 表简略 Schema（含索引）
                 ├─ ObSimpleTablegroupSchema ← 表组简略 Schema
                 ├─ ObOutlineMgr            ← Outline（执行计划绑定）管理器
                 ├─ ObPrivMgr               ← 权限管理器
                 ├─ ObRoutineMgr            ← 存储过程/函数管理器
                 ├─ ... (多种子管理器)
```

### 1.2 核心文件一览

| 文件 | 行数（约） | 职责 |
|------|-----------|------|
| `ob_schema_mgr.h/cpp` | 1056 / 6191 | Schema 管理器：所有元数据的统一容器 |
| `ob_multi_version_schema_service.h/cpp` | 575 / 大量 | 多版本 Schema 服务：生命周期管理、版本控制 |
| `ob_schema_getter_guard.h` | 1468 | Schema 访问 Guard：RAII 线程安全访问 |
| `ob_schema_mgr_cache.h/cpp` | 172 / 大量 | Schema 管理器环形缓存：引用计数与回收 |
| `ob_schema_cache.h/cpp` | ~340 / 大量 | Schema 对象缓存：KV Cache 模式 |
| `ob_schema_store.h/cpp` | 87 / 大量 | Schema 存储：按租户管理的版本状态 |
| `ob_table_schema.h` | 3427 | 表 Schema 定义 |
| `ob_column_schema.h` | 551 | 列 Schema 定义 |
| `ob_schema_service.h` | 1501 | Schema 服务抽象：DDL 操作枚举与 SQL 实现 |
| `ob_server_schema_service.h` | 1524 | 服务器端 Schema 服务抽象基类 |

---

## 2. ObSchemaMgr — Schema 管理器的核心设计

`ObSchemaMgr` 是整个 Schema 子系统的核心数据容器。它持有某个 Schema 版本下所有元数据的快照。

### 2.1 内部数据结构

```cpp
// ob_schema_mgr.h 第 484-1056 行（类定义、类型定义和第 983 行之后的私有成员）
class ObSchemaMgr
{
  // 核心容器：使用 ObSortedVector 保证有序遍历
  typedef common::ObSortedVector<ObSimpleTenantSchema *> TenantInfos;
  typedef common::ObSortedVector<ObSimpleUserSchema *> UserInfos;
  typedef common::ObSortedVector<ObSimpleDatabaseSchema *> DatabaseInfos;
  typedef common::ObSortedVector<ObSimpleTableSchemaV2 *> TableInfos;

  // 哈希索引：快速 O(1) 查找
  typedef common::hash::ObPointerHashMap<uint64_t, ObSimpleTableSchemaV2 *> TableIdMap;
  typedef common::hash::ObPointerHashMap< ... > TableNameMap;
  typedef common::hash::ObPointerHashMap< ... > IndexNameMap;

private:
  common::ObArenaAllocator local_allocator_;
  common::ObIAllocator &allocator_;
  int64_t schema_version_;           // 此管理器实例对应的 Schema 版本号
  uint64_t tenant_id_;               // 所属租户（OB_INVALID_TENANT_ID 表示全集群）
  bool is_consistent_;               // Schema 一致性标志

  TenantInfos tenant_infos_;         // 租户信息（有序向量）
  UserInfos user_infos_;             // 用户信息
  DatabaseInfos database_infos_;     // 数据库信息
  DatabaseNameMap database_name_map_; // 数据库名 → 数据库 Schema 哈希映射
  TableInfos table_infos_;           // 表信息
  TableInfos index_infos_;           // 索引信息
  TableIdMap table_id_map_;          // 表 ID → 表 Schema 哈希映射
  TableNameMap table_name_map_;      // 表名 → 表 Schema 哈希映射
  IndexNameMap normal_index_name_map_;  // 普通索引名映射
  // ... 30+ 子管理器
};
```

**关键设计特点：**

1. **双索引访问**：每个实体（表、数据库等）同时维护 `ObSortedVector`（有序遍历）和 `ObPointerHashMap`（哈希查找），兼顾范围遍历和点查效率。

2. **子管理器聚合**：`ObOutlineMgr`、`ObPrivMgr`、`ObRoutineMgr` 等作为独立子管理器被聚合，每个子管理器都有自己的内部索引和存储。

3. **Schema 版本化**：每个 `ObSchemaMgr` 实例绑定一个固定的 `schema_version_`，代表某一时刻的快照。

### 2.2 操作接口

```cpp
// ob_schema_mgr.h 第 556-650 行：核心 CRUD 接口

// 租户操作
int add_tenants(const ObIArray<ObSimpleTenantSchema> &tenant_schemas);
int del_tenants(const ObIArray<uint64_t> &tenants);
int get_tenant_schema(const uint64_t tenant_id,
                      const ObSimpleTenantSchema *&tenant_schema) const;

// 表操作
int add_tables(const ObIArray<ObSimpleTableSchemaV2 *> &table_schemas,
               const bool refresh_full_schema = false);
int del_tables(const ObIArray<ObTenantTableId> &tables);
int get_table_schema(const uint64_t tenant_id,
                     const uint64_t table_id,
                     const ObSimpleTableSchemaV2 *&table_schema) const;
int get_table_schema(const uint64_t tenant_id,
                     const uint64_t database_id,
                     const uint64_t session_id,
                     const ObString &table_name,
                     const bool is_index,
                     const ObSimpleTableSchemaV2 *&table_schema,
                     const bool with_hidden_flag = false,
                     const bool is_built_in_index = false) const;

// 深拷贝和赋值
int assign(const ObSchemaMgr &other);    // 浅拷贝（共享子管理器对象）
int deep_copy(const ObSchemaMgr &other); // 深拷贝（完全独立）
```

### 2.3 子管理器架构

`ObSchemaMgr` 通过聚合多种子管理器来管理不同类型的 Schema 对象。每种子管理器独立维护自己的索引：

```
ObSchemaMgr
├── ObOutlineMgr          — 执行计划绑定（Outline）
├── ObPrivMgr             — 用户权限
├── ObSynonymMgr          — 同义词
├── ObPackageMgr          — 包（PL/SQL Package）
├── ObRoutineMgr          — 存储过程/函数
├── ObTriggerMgr          — 触发器
├── ObUDFMgr              — 自定义函数
├── ObUDTMgr              — 自定义类型
├── ObSequenceMgr         — 序列
├── ObLabelSePolicyMgr    — 标签安全策略
├── ObProfileMgr          — 用户配置文件（Profile）
├── ObSAuditMgr           — 安全审计
├── ObSysVariableMgr      — 系统变量
├── ObKeystoreMgr         — 密钥库
├── ObTablespaceMgr       — 表空间
├── ObDbLinkMgr           — 数据库链接
├── ObDirectoryMgr        — 目录对象
├── ObLocationMgr         — 位置信息
├── ObContextMgr          — 应用程序上下文
├── ObRlsPolicyMgr        — 行级安全策略
├── ObCatalogMgr          — 目录（Catalog）
├── ObCCLRuleMgr          — 并发控制规则
└── ObAiModelMgr          — AI 模型元数据
```

这种架构体现了 **单一职责原则** 和 **组合模式**：每个子管理器专注于管理一种 Schema 类型，`ObSchemaMgr` 作为统一容器组合所有子管理器。

### 2.4 add_table 实现分析

以 `add_table` 为例（`ob_schema_mgr.cpp` 第 2754 行），可以看到 Schema 管理器的增量更新模式：

```cpp
int ObSchemaMgr::add_table(const ObSimpleTableSchemaV2 &table_schema,
                           common::ObArrayWrap<int64_t> *cost_array)
{
  // 1. 分配新 Schema 对象
  ObSimpleTableSchemaV2 *new_schema = NULL;
  if (OB_FAIL(alloc_schema(allocator_, table_schema, new_schema))) {
    LOG_WARN("fail to alloc schema", K(ret));
  }

  // 2. 更新主表信息索引
  if (OB_SUCC(ret)) {
    if (OB_FAIL(table_infos_.replace(new_schema, cost_array))) {
      LOG_WARN("fail to replace table info", K(ret));
    }
  }

  // 3. 根据表类型分别加入对应分类索引
  //    - 普通表 → table_infos_
  //    - 索引表 → index_infos_ + index_name_map_
  //    - 向量索引 → vec_index_infos_
  //    - 辅助视图 → aux_vp_infos_
  //    - LOB 元数据 → lob_meta_infos_ / lob_piece_infos_

  // 4. 更新哈希索引
  if (OB_FAIL(ret)) {
  } else if (OB_FAIL(table_id_map_.set_refactored(table_id, new_schema))) {
    LOG_WARN("fail to set id map", K(ret));
  }

  // 5. 处理重命名、隐藏表状态变更等特殊场景
  if (OB_SUCC(ret)) {
    if (OB_FAIL(deal_with_table_rename(...))) { ... }
  }

  // 6. 更新外键和约束索引
  if (OB_SUCC(ret) && new_schema->is_index_table()) {
    // 索引表不涉及外键/约束变化
  } else {
    add_foreign_keys_in_table(...);
    add_constraints_in_table(...);
  }
}
```

关键观察：`add_table` 是 **幂等的可替换操作**（`replace` 而非 `insert`），这意味着多次添加同一个表 ID 的 Schema，后一次会覆盖前一次。这为增量 Schema 刷新奠定了基础。

---

## 3. Schema 版本管理机制

OceanBase 的 Schema 版本管理是理解整个系统的关键。与传统数据库在每个查询中直接查询元数据表不同，OceanBase 采用 **多版本快照** 模式。

### 3.1 多版本架构

`ObMultiVersionSchemaService`（`ob_multi_version_schema_service.h` 第 158 行）是 Schema 版本管理的核心服务：

```cpp
class ObMultiVersionSchemaService : public ObServerSchemaService
{
  // 核心常量
  static const int64_t MAX_CACHED_VERSION_NUM = 4;         // 最大缓存版本数
  static const int64_t MAX_VERSION_COUNT = 64;             // 每个租户最大版本数
  static const int64_t MAX_VERSION_COUNT_FOR_LIBOBLOG = 6; // 日志消费最大版本数

  // 刷新模式
  enum RefreshSchemaMode {
    NORMAL = 0,        // 正常刷新
    FORCE_FALLBACK,    // 强制回退
    FORCE_LAZY         // 延迟刷新
  };

private:
  ObSchemaCache schema_cache_;           // Schema 对象缓存（KV Cache）
  ObSchemaMgrCache schema_mgr_cache_;     // Schema 管理器缓存（环形缓冲）
  ObSchemaFetcher schema_fetcher_;        // Schema 数据获取器
  ObSchemaStoreMap schema_store_map_;     // 按租户管理的 Schema 存储状态
  ObDDLTransController ddl_trans_controller_; // DDL 事务控制器
  ObDDLEpochMgr ddl_epoch_mgr_;           // DDL 纪元管理器
};
```

### 3.2 Schema 存储状态

`ObSchemaStore`（`ob_schema_store.h`）管理每个租户的版本状态：

```cpp
class ObSchemaStore {
  int64_t tenant_id_;
  int64_t refreshed_version_;        // 已刷新的 Schema 版本（本地最新）
  int64_t received_version_;         // 已接收到的广播版本
  int64_t checked_sys_version_;      // 已检查的系统版本
  int64_t baseline_schema_version_;  // 基线 Schema 版本
  int64_t consensus_version_;        // 共识版本（多数派确认）
  ObSchemaMgrCache schema_mgr_cache_;       // 版本化 Schema 管理器缓存
  ObSchemaMgrCache schema_mgr_cache_for_liboblog_;
};
```

**五种版本状态的含义：**

| 版本字段 | 含义 |
|---------|------|
| `refreshed_version_` | 本地已成功构建的 Schema 最新版本。通过 `ATOMIC_LOAD` 读取，保证无锁读 |
| `received_version_` | RootService 广播的 Schema 版本号，表示 "已知有更新" |
| `baseline_schema_version_` | 基线版本，用于增量刷新：只获取大于此版本的变更 |
| `consensus_version_` | 多数派节点已确认的版本，用于保证分布式一致性 |
| `checked_sys_version_` | 最后一次检查系统租户 Schema 的版本 |

### 3.3 Schema 版本生命周期

```
RootService 广播新版本 (received_version_ 更新)
        │
        ▼
OBServer 接收到广播，触发异步刷新
        │
        ▼
Schema Fetcher 从内部表获取增量变更
(schema_version > baseline_schema_version_)
        │
        ▼
构建新的 ObSchemaMgr 快照
(deep_copy + 增量应用变更)
        │
        ▼
新版本放入 ObSchemaMgrCache 环形缓冲
        │
        ▼
更新 refreshed_version_，
Schema 版本对查询可见
        │
        ▼
旧版本逐渐被 GC 回收
（无引用时释放）
```

### 3.4 版本号生成

`gen_new_schema_version` 是版本号的生成接口（`ob_multi_version_schema_service.h` 第 288 行），它保证单调递增的版本号生成，且全局唯一：

```cpp
int gen_new_schema_version(uint64_t tenant_id, int64_t &schema_version);
```

RootService 在完成 DDL 后生成新的版本号，并通过 RPC 广播到所有 OBServer。

### 3.5 `ObSchemaVersionUpdater` — 版本更新器

`ob_multi_version_schema_service.h` 第 78 行定义的 `ObSchemaVersionUpdater` 是一个函数对象，用于原子更新版本号：

```cpp
class ObSchemaVersionUpdater {
public:
  ObSchemaVersionUpdater(int64_t new_schema_version, bool ignore_error = true);
  int operator() (int64_t& version) {
    if (version < new_schema_version_) {
      version = new_schema_version_;  // 仅允许版本号上升
    } else {
      ret = ignore_error_ ? OB_SUCCESS : OB_OLD_SCHEMA_VERSION;
    }
  }
  int operator() (HashMapPair<uint64_t, int64_t> &entry) {
    // 对哈希表版本的批量更新
  }
};
```

---

## 4. Schema 访问模式与线程安全

OceanBase 的 Schema 访问遵循 **读多写少** 的典型模式：大量并发查询只读 Schema，而写 Schema（DDL）相对罕见。为此，系统设计了精妙的无锁读优化。

### 4.1 ObSchemaGetterGuard — RAII 访问守卫

`ObSchemaGetterGuard` 是访问 Schema 的唯一入口（`ob_schema_getter_guard.h` 第 126 行）：

```cpp
class ObSchemaGetterGuard {
  friend class ObMultiVersionSchemaService;

  typedef common::ObSEArray<SchemaObj, DEFAULT_RESERVE_SIZE> SchemaObjs;
  typedef common::ObSEArray<ObSchemaMgrInfo, DEFAULT_RESERVE_SIZE> SchemaMgrInfos;

  enum SchemaGuardType {
    INVALID_SCHEMA_GUARD_TYPE = 0,
    SCHEMA_GUARD = 1,
    TENANT_SCHEMA_GUARD = 2,
    TABLE_SCHEMA_GUARD = 3
  };

public:
  ObSchemaGetterGuard();
  explicit ObSchemaGetterGuard(const ObSchemaMgrItem::Mod mod);
  virtual ~ObSchemaGetterGuard();
};
```

**RAII 模式详解：**

1. **构造时**：从当前最新的 Schema 版本获取 `ObSchemaMgr` 的引用，并增加其引用计数（`ref_cnt_++`）
2. **析构时**：减少引用计数（`ref_cnt_--`），不阻止 GC 但保证使用期间对象存活
3. **使用中**：所有 `get_*` 方法直接通过持有的 `ObSchemaMgr` 指针查询

```cpp
// 典型用法
int ObMultiVersionSchemaService::get_tenant_schema_guard(
    const uint64_t tenant_id,
    ObSchemaGetterGuard &guard, ...)
{
  // 1. 获取当前最新的 SchemaMgr
  // 2. 创建 ObSchemaMgrInfo（包含 ObSchemaMgr* + ObSchemaMgrHandle）
  // 3. ObSchemaMgrHandle 内部增加 ref_cnt_
  // 4. 将 ObSchemaMgrInfo 存入 guard
  ...
}
```

### 4.2 ObSchemaMgrCache — 环形缓冲

`ObSchemaMgrCache`（`ob_schema_mgr_cache.h`）是一个固定大小的环形缓冲，管理 `ObSchemaMgr` 的多版本存储：

```cpp
class ObSchemaMgrCache {
  // 环形缓冲中的槽位
  // 每个 ObSchemaSlot 包含：tenant_id, slot_id, schema_version, ref_cnt, ...
};

struct ObSchemaMgrItem {
  ObSchemaMgr *schema_mgr_;     // Schema 管理器指针
  int64_t ref_cnt_ CACHE_ALIGNED;              // 总引用计数（缓存行对齐避免伪共享）
  int64_t mod_ref_cnt_[MOD_MAX] CACHE_ALIGNED; // 按模块分解的引用计数
};
```

**关键设计：**

- `CACHE_ALIGNED` 修饰：确保 `ref_cnt_` 和 `mod_ref_cnt_` 位于不同缓存行，避免多核 CPU 上的伪共享（False Sharing）
- 引用计数基于不同模块（`MOD_STACK`, `MOD_VTABLE_SCAN_PARAM` 等），便于调试和问题定位

### 4.3 无锁读的实现

读操作路径几乎完全无锁：

1. **获取 Guard**：`get_tenant_schema_guard` 调用从 `schema_mgr_cache_` 中读取最新的 `ObSchemaMgr*`，通过 `ATOMIC_LOAD` 读取版本号
2. **增加引用**：使用原子操作增加 `ref_cnt_`
3. **查询操作**：所有 `get_table_schema`、`get_tenant_schema` 等方法直接读取 `ObSchemaMgr` 内部的 `ObSortedVector` 和 `ObPointerHashMap`，无需加锁

写操作（DDL）则是串行化的：

- 通过 `schema_refresh_mutex_` 保证同一时间只有一个线程执行 Schema 刷新
- `ObSchemaConstructTask`（`ob_multi_version_schema_service.h` 第 52 行）通过条件变量控制并发构建

### 4.4 ObSchemaMgrHandle — 引用计数句柄

```cpp
class ObSchemaMgrHandle {
public:
  ObSchemaMgrHandle();
  explicit ObSchemaMgrHandle(const ObSchemaMgrItem::Mod mod);
  ObSchemaMgrHandle(const ObSchemaMgrHandle &other);

  void reset();
  int set(ObSchemaMgrItem *item);
  ObSchemaMgr *get_schema_mgr() const;

private:
  ObSchemaMgrItem *item_;
  ObSchemaMgrItem::Mod mod_;
};
```

句柄的拷贝构造函数会增加引用计数，析构时减少。这允许在不同线程间安全传递 Schema 管理器的所有权。

### 4.5 模块级引用追踪

`ObSchemaMgrItem::Mod` 枚举定义了 16 种引用模块（`ob_schema_mgr_cache.h` 第 62-83 行）：

```cpp
enum Mod {
  MOD_STACK             = 0,   // 栈上局部变量
  MOD_VTABLE_SCAN_PARAM = 1,   // 虚拟表扫描参数
  MOD_INNER_SQL_RESULT  = 2,   // 内部 SQL 结果
  MOD_LOAD_DATA_IMPL    = 3,   // 数据加载
  MOD_PX_TASK_PROCESSS  = 4,   // PX（并行执行）任务
  MOD_REMOTE_EXE        = 5,   // 远程执行
  MOD_CACHED_GUARD      = 6,   // 缓存的 Guard
  MOD_UNIQ_CHECK        = 7,   // 唯一性检查
  MOD_SSTABLE_SPLIT_CTX = 8,   // SSTable 分裂上下文
  MOD_RELATIVE_TABLE    = 9,   // 关联表
  MOD_VIRTUAL_TABLE     = 10,  // 虚拟表
  MOD_DAS_CTX           = 11,  // DAS 上下文
  MOD_SCHEMA_RECORDER   = 12,  // Schema 记录器
  MOD_SPI_RESULT_SET    = 13,  // SPI 结果集
  MOD_PL_PREPARE_RESULT = 14,  // PL 准备结果
  MOD_PARTITION_BALANCE = 15,  // 分区平衡
  MOD_RS_MAJOR_CHECK    = 16,  // RS 主检查
  MOD_MAX
};
```

这种细粒度追踪使得在 Schema 泄漏时可以快速定位是哪个模块持有引用未释放。

---

## 5. Schema 与 SQL 执行集成

Schema 信息在 SQL 执行的各个阶段被广泛使用。这里分析两个关键集成点。

### 5.1 优化器：代价估算中的 Schema 信息

优化器在代价估算时依赖 Schema 信息来获取表的元数据。`ObTableMetaInfo`（`ob_opt_est_cost_model.h` 第 50 行）封装了优化器需要的表级信息：

```cpp
struct ObTableMetaInfo {
  uint64_t ref_table_id_;
  int64_t schema_version_;           // Schema 版本（用于一致性判断）
  int64_t part_count_;               // 分区数
  int64_t micro_block_size_;         // 微块大小
  int64_t table_column_count_;       // 列数
  int64_t table_rowkey_count_;       // 主键列数
  int64_t table_row_count_;          // 统计信息中的行数
  double average_row_size_;          // 平均行大小
  share::schema::ObTableType table_type_; // 表类型
  bool is_broadcast_table_;          // 是否为广播表
  // ...
};
```

在 `ob_join_order.cpp` 中，代价估算的关键调用：

```cpp
// ob_join_order.cpp 第 18269 行
table_meta_info_.schema_version_ = table_schema->get_schema_version();

// ob_join_order.cpp 第 23180 行
table_meta_range.schema_version_ = index_schema->get_schema_version();
```

`ObOptEstCostModel` 的构造函数（`ob_opt_est_cost_model.h` 第 50 行）初始化时记录了 Schema 版本，后续代价计算依赖这个版本来保证一致性。

`ob_access_path_estimation.cpp` 中，Schema 版本通过 RPC 传输到存储节点：

```cpp
// ob_access_path_estimation.cpp 第 1097 行
task->arg_.schema_version_ = table_meta.schema_version_;

// ob_access_path_estimation.cpp 第 2190 行
arg.schema_version_ = meta.schema_version_;
```

这在分布式环境下至关重要：存储节点根据 Schema 版本判断是否需要重新构建存储格式。

### 5.2 计划缓存：Schema 版本驱动的计划失效

`ObPlanCacheValue` 是计划缓存的核心，其 `PCVSchemaObj` 记录了每条缓存计划依赖的 Schema 信息：

```cpp
// ob_plan_cache_value.h 第 60 行
class PCVSchemaObj {
  uint64_t tenant_id_;
  uint64_t database_id_;
  uint64_t schema_id_;
  int64_t schema_version_;      // 依赖的 Schema 版本
  ObSchemaType schema_type_;     // Schema 类型（表、索引等）
  ObTableType table_type_;       // 表类型
  // ...
};
```

**计划失效流程：**

```
新的 SQL 查询到来
        │
        ▼
从计划缓存中查找匹配计划
        │
        ▼
对比当前 Schema 版本与缓存中记录的版本
        │
        ├── 版本一致 → 计划有效，直接使用
        │
        └── 版本不一致 → 计划失效，重新优化生成新计划
```

`check_value_version_for_get`（`ob_plan_cache_value.h` 第 308 行）和 `lift_tenant_schema_version`（第 295 行）负责版本匹配检查：

```cpp
class ObPlanCacheValue {
  // 提升已缓存计划的 Schema 版本
  int lift_tenant_schema_version(int64_t new_schema_version);

  // 检查缓存值版本是否兼容
  int check_value_version_for_get(
      share::schema::ObSchemaGetterGuard *schema_guard,
      bool &is_valid);
};
```

`ob_pcv_set.cpp` 第 155 行展示了实际的失效检查：

```cpp
// ob_pcv_set.cpp 第 155-193 行
int64_t new_tenant_schema_version = OB_INVALID_VERSION;
// ... 获取当前 Schema 版本 ...
if (OB_FAIL(matched_pcv->lift_tenant_schema_version(new_tenant_schema_version))) {
  // 如果 Schema 版本已变化，提升版本号
} else if (new_tenant_schema_version != OB_INVALID_VERSION) {
  pc_ctx.exec_ctx_.get_physical_plan_ctx()->set_tenant_schema_version(
      new_tenant_schema_version);
}
```

---

## 6. Schema 缓存与刷新策略

### 6.1 两层缓存架构

```
┌─────────────────────────────────────────────────┐
│            ObMultiVersionSchemaService           │
│                                                   │
│  ┌─────────────────┐     ┌──────────────────┐    │
│  │ ObSchemaMgrCache  │     │   ObSchemaCache   │   │
│  │ (Schema 快照缓存) │     │ (Schema 对象缓存) │   │
│  │                   │     │                    │   │
│  │ 环形缓冲，最多    │     │ KV Cache 模式      │   │
│  │ MAX_CACHED_VER=4  │     │ 按(schema_type,   │   │
│  │ 个版本同时存在    │     │  tenant_id, id,   │   │
│  │                   │     │  version) 缓存     │   │
│  └─────────────────┘     └──────────────────┘    │
└─────────────────────────────────────────────────┘
```

**第一层：`ObSchemaMgrCache`**
- 存储完整的 `ObSchemaMgr` 快照
- 环形缓冲，每个租户最多保留 `MAX_CACHED_VERSION_NUM = 4` 个版本
- 使用引用计数（`ObSchemaMgrHandle`）管理生命周期
- 通过 `try_gc_*` 系列函数在无引用时回收旧版本

**第二层：`ObSchemaCache`**
- 存储单个 Schema 对象（如 `ObTableSchema`、`ObColumnSchemaV2`）
- 基于通用的 `ObKVCache`（KV Cache）实现
- 缓存键为 `(schema_type, tenant_id, schema_id, schema_version)`
- 用于快速查找单个 Schema 对象，避免从 Schema 管理器遍历

### 6.2 Schema 刷新流程

`ObMultiVersionSchemaService` 定义了完整的刷新流程：

```cpp
// 主要刷新接口
int refresh_and_add_schema(const ObIArray<uint64_t> &tenant_ids,
                           bool check_bootstrap = false);

int async_refresh_schema(const uint64_t tenant_id,
                         const int64_t schema_version,
                         const ObRefreshSchemaInfo *schema_info = nullptr);

int add_schema(const uint64_t tenant_id, const bool force_add = false);
```

**完整刷新步骤：**

1. **触发**：RootService 广播 DDL 变更，OBServer 调用 `async_refresh_schema`
2. **获取变更**：`ObSchemaFetcher` 从内部表获取增量变更（基于 `baseline_schema_version_`）
3. **构建快照**：从当前最新 `ObSchemaMgr` 做 `deep_copy`，然后增量应用变更
4. **发布**：新快照通过 `publish_schema` 放入 `ObSchemaMgrCache`
5. **消息确认**：更新 `received_version_` 和 `refreshed_version_`

### 6.3 增量 Schema 变更

区别于全量刷新，增量 Schema 变更只获取变动部分：

- DDL 操作在内部表中会记录操作类型（`ObSchemaOperationCategory`）和时间戳
- `ObSchemaFetcher` 根据上次刷新的 `baseline_schema_version_` 获取变更
- 应用变更到 `deep_copy` 的 Schema 管理器副本，而非从头构建

### 6.4 垃圾回收（GC）

OceanBase 使用引用计数驱动 GC，当 Schema 版本被所有 Guard 释放且已有更新版本时，触发回收：

```cpp
int try_gc_tenant_schema_mgr();              // 全租户 GC
int try_gc_tenant_schema_mgr(uint64_t tenant_id); // 特定租户 GC
int try_gc_another_allocator(...);           // 另一个分配器的 GC
int try_gc_current_allocator(...);           // 当前分配器的 GC
```

### 6.5 Schema 一致性保证

`ObSchemaMgr` 的 `is_consistent_` 标志用于检测 Schema 元数据是否一致：

```cpp
// ob_schema_mgr.h 第 535 行
inline bool get_is_consistent() const { return is_consistent_; }

// ob_schema_mgr.cpp
bool ObSchemaMgr::check_schema_meta_consistent();
int ObSchemaMgr::rebuild_schema_meta_if_not_consistent();
int ObSchemaMgr::rebuild_table_hashmap(uint64_t &fk_cnt, uint64_t &cst_cnt);
int ObSchemaMgr::rebuild_db_hashmap();
```

当发现 Schema 元数据不一致时（例如哈希索引与有序向量不同步），系统会触发重建。

---

## 7. 分布式 Schema 管理

### 7.1 RootService 的角色

在分布式环境中，OceanBase 的 RootService 承担 Schema 变更的仲裁者角色：

1. **DDL 协调**：RootService 接收 DDL 请求，协调多节点执行
2. **版本生成**：DDL 完成后生成新的 Schema 版本号
3. **广播通知**：通过 RPC 广播 Schema 版本变更到所有 OBServer
4. **一致性检查**：通过 `consensus_version_` 确保多数派节点已确认新版本

### 7.2 DDL 纪元管理

`ObDDLEpochMgr`（`ob_ddl_epoch.h`/`cpp`）和 `ObDDLTransController`（`ob_ddl_trans_controller.h`/`cpp`）协调分布式 DDL 事务：

```cpp
// ob_multi_version_schema_service.h 成员
ObDDLTransController ddl_trans_controller_;  // DDL 事务状态管理
ObDDLEpochMgr ddl_epoch_mgr_;                // DDL 纪元（用于版本排序）
```

### 7.3 广播机制

```
RootService
    │
    ├── 广播 Schema 版本变更到所有 OBServer
    │
    ▼
OBServer 1          OBServer 2          OBServer 3
    │                   │                   │
    ├── received_version 更新               │
    ├── 异步刷新 Schema                      │
    ├── 更新 refreshed_version              │
    └── 发送确认给 RootService ─────────────┘
```

---

## 8. 设计决策与权衡

### 8.1 为什么选择多版本快照而非实时查询？

| 方案 | 优点 | 缺点 |
|------|------|------|
| **多版本快照**（OceanBase 选择） | 读无锁，高并发，事务隔离好 | 内存开销大，版本回收复杂 |
| **实时查询元数据表** | 内存占用少 | 查询性能差，锁竞争严重 |

OceanBase 的选择更符合 OLTP 场景的需求：**读多写少**，且要求读路径低延迟。

### 8.2 深拷贝 vs 写时复制（Copy-on-Write）

当前 `ObSchemaMgr` 采用 `deep_copy`（全量深拷贝后增量修改），而非写时复制。这种选择：

- **优点**：实现简单，Schema 管理器是独立快照，无需复杂的一致性协议
- **缺点**：每次 DDL 都产生完整的 Schema 管理器副本，内存开销较大

当 `MAX_CACHED_VERSION_NUM = 4` 时，每个租户最多同时持有 4 个完整的 Schema 快照。对于数千张表的大型租户，每次 Schema 变更都可能涉及大量内存操作。

### 8.3 轻量级（Simple） vs 完整（Full）Schema

OceanBase 同时维护两种 Schema 表示：

- **`ObSimpleTableSchemaV2`**：轻量级，用于快速查找和版本比较，不包含列等详细信息
- **`ObTableSchema`**：完整 Schema，包含所有列定义、索引、分区信息等，按需构建

`ObSchemaGetterGuard` 提供两套 API：

```cpp
// 轻量级查询
int get_simple_table_schema(..., const ObSimpleTableSchemaV2 *&table_schema);

// 完整查询（需要时从 ObSchemaCache 或 Schema 管理器构建）
int get_table_schema(..., const ObTableSchema *&table_schema);
```

这种设计减少了频繁操作的开销：查找表 ID、检查版本时使用轻量级对象，只有真正需要列信息时才构建完整对象。

### 8.4 ObSchemaGetterController 的去重构建

`ObSchemaGetterController`（`ob_multi_version_schema_service.h` 第 112 行）确保相同的 Schema 对象不会被并行重复构建：

```cpp
class ObSchemaGetterController {
  int construct_schema_(...);
  int check_and_set_key_(const ObSchemaCacheKey &key, bool &is_set);
  int erase_key_(const ObSchemaCacheKey &key);

  ObThreadCond cond_slot_[COND_SLOT_NUM];       // 256 个条件变量槽
  ObHashSet<ObSchemaCacheKey> constructing_keys_; // 正在构建的 Schema 键集合
  ObSpinLock lock_;                               // 轻量自旋锁
};
```

当多个线程同时请求同一 Schema 对象时，只有一个线程执行构建，其他线程等待构建完成。这种 **串行化构建 + 并行读** 的模式避免了 "惊群效应"。

### 8.5 引用计数模块化的考量

`mod_ref_cnt_[MOD_MAX]` 的设计提供了模块级的内存泄漏追踪能力。泄露的 Schema 引用会导致对应 `ObSchemaMgr` 无法回收，内存持续增长。通过检查各模块的引用计数，运维人员可以快速定位泄漏源头。

---

## 9. 总结

OceanBase 的 Schema 子系统是一个精心设计的元数据管理框架，其核心设计思想可以归纳为：

1. **版本化快照**：Schema 变更是增量演进的，每个版本是一个完整快照
2. **无锁读**：通过引用计数 RAII Guard 实现高效的并发 Schema 读取
3. **两层缓存**：快照级缓存（`ObSchemaMgrCache`）+ 对象级缓存（`ObSchemaCache`）互补
4. **读优化**：轻量级 Schema 用于频繁操作，完整 Schema 按需构建
5. **增量刷新**：基于版本号的增量变更减少 Schema 刷新开销
6. **子管理器组合**：每种 Schema 类型独立管理，通过组合模式聚合
7. **分布式协调**：RootService 仲裁→RPC 广播→异步本地刷新的分布式一致性模型

这些设计使得 OceanBase 能够在支持高并发 OLTP 负载的同时，快速响应 DDL 变更，并保证分布式环境下的 Schema 一致性。

---

*分析基于 OceanBase CE 源码，核心文件位于 `~/code/oceanbase/src/share/schema/`。*
