# 22-plan-cache — 执行计划缓存与 SQL Plan Management

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

经过前面 21 篇文章的积累，我们已经深入分析了 OceanBase 的完整技术栈——从存储引擎（MVCC、Memtable、SSTable、LS Tree）到 SQL 执行引擎（DAS 层、优化器、PX 并行执行）再到分布式运维（分区迁移、备份恢复）。

现在分析 SQL 执行引擎的另一个关键子系统——**Plan Cache（执行计划缓存）**。

### Plan Cache 的定位

SQL 从接收到执行要经历 **解析（Parse）→ 优化（Optimize）→ 执行（Execute）** 三个阶段。其中优化阶段（生成执行计划）是整个过程中最耗 CPU 的部分——优化器需要做查询变换、计算各种访问路径的成本、选择连接顺序等。Plan Cache 的核心目标就是**缓存已生成的执行计划，避免对相同 SQL 重复优化**。

```
SQL 客户端
    │
    ▼
  ┌──────────┐      ┌──────────────┐      ┌──────────────┐
  │  Parser  │ ──►  │  Optimizer   │ ──►  │   Executor   │
  └──────────┘      └──────┬───────┘      └──────────────┘
                           │                     ▲
                           ▼                     │
                     ┌──────────┐                │
                     │Plan Cache│────────────────┘
                     └──────────┘    缓存命中，跳过优化
```

**核心性能数据**：在 OLTP 场景下，Plan Cache 命中率通常 > 99%。一次计划优化可能消耗数毫秒到数百毫秒的 CPU，而 Plan Cache 查找仅需微秒级。

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 17-query-optimizer | 优化器生成执行计划，Plan Cache 缓存优化结果 |
| 09-sql-executor | DAS 层需要从缓存中获取执行计划 |
| 21-px-execution | PX 执行计划同样通过 Plan Cache 获取 |

### 代码位置

```
src/sql/plan_cache/      -- Plan Cache 核心
src/sql/spm/             -- SPM (SQL Plan Management)
```

---

## 1. 整体架构

### 1.1 Lib Cache 框架

OceanBase 的 Plan Cache 基于一个通用的 **Lib Cache（Library Cache）框架** 实现。这个框架不仅用于缓存 SQL 执行计划，还用于缓存 PL 对象（存储过程、函数、包）、TableAPI 操作、SPM 基线等。

```
┌──────────────────────────────────────────────────────┐
│                    ObPlanCache                         │
│                                                        │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────┐   │
│  │ 哈希表    │  │ 内存管理  │  │ 淘汰任务 (Timer)   │   │
│  │ Key→Node │  │ HWM/LWM  │  │ 定期检查内存水位   │   │
│  └────┬─────┘  └──────────┘  └────────────────────┘   │
│       │                                                 │
│       ▼                                                 │
│  ┌──────────────────────────────────────┐              │
│  │  CacheNode (ObILibCacheNode)         │              │
│  │  ┌──────────┐  ┌──────────┐         │              │
│  │  │ ObPCVSet │  │ ObSpmSet │  ...    │  ← 命名空间    │
│  │  │ (NS_CRSR)│  │ (NS_SPM) │         │              │
│  │  └────┬─────┘  └──────────┘         │              │
│  │       │                              │              │
│  │       ▼                              │              │
│  │  ┌───────────────────────────┐      │              │
│  │  │ ObILibCacheObject (计划对象) │      │              │
│  │  │ ObPhysicalPlan             │      │              │
│  │  │ ObPlanBaselineItem (SPM)   │      │              │
│  │  └───────────────────────────┘      │              │
│  └──────────────────────────────────────┘              │
│                                                        │
│  ┌──────────────────────────────────────┐              │
│  │ ObLCObjectManager (全局对象管理器)    │              │
│  │ 哈希表: obj_id → ObILibCacheObject   │              │
│  └──────────────────────────────────────┘              │
└──────────────────────────────────────────────────────┘
```

### 1.2 命名空间系统

不同的缓存对象类型通过 **命名空间（Namespace）** 区分。每个命名空间有自己的 Key 类型、Node 类型和 Object 类型。

`src/sql/plan_cache/ob_lib_cache_register.h` 第 39-49 行采用了 X-Macro 注册所有命名空间：

```cpp
#define LIB_CACHE_OBJ_DEF(NS_CRSR, "CRSR", ObPlanCacheKey, ObPCVSet, ObPhysicalPlan, ...)
#define LIB_CACHE_OBJ_DEF(NS_PRCR, "PRCR", ObPLObjectKey, ObPLObjectSet, ObPLFunction, ...)
#define LIB_CACHE_OBJ_DEF(NS_SFC, "SFC", ObPLObjectKey, ObPLObjectSet, ObPLFunction, ...)
#define LIB_CACHE_OBJ_DEF(NS_ANON, "ANON", ObPLObjectKey, ObPLObjectSet, ObPLFunction, ...)
#define LIB_CACHE_OBJ_DEF(NS_TRGR, "TRGR", ObPLObjectKey, ObPLObjectSet, ObPLPackage, ...)
#define LIB_CACHE_OBJ_DEF(NS_PKG, "PKG", ObPLObjectKey, ObPLObjectSet, ObPLPackage, ...)
#define LIB_CACHE_OBJ_DEF(NS_TABLEAPI, "TABLEAPI", ObTableApiCacheKey, ObTableApiCacheNode, ...)
#define LIB_CACHE_OBJ_DEF(NS_CALLSTMT, "CALLSTMT", ...)
#ifdef OB_BUILD_SPM
#define LIB_CACHE_OBJ_DEF(NS_SPM, "SPM", ObBaselineKey, ObSpmSet, ObPlanBaselineItem, ...)
#endif
#define LIB_CACHE_OBJ_DEF(NS_KV_SCHEMA, "KV_SCHEMA_INFO", ...)
#define LIB_CACHE_OBJ_DEF(NS_UDF_RESULT_CACHE, "UDF_RESULT_CACHE", ...)
```

**核心命名空间**：

| 命名空间 | 用途 | Key 类型 | Node 类型 | Object 类型 |
|---------|------|---------|-----------|------------|
| `NS_CRSR` | 物理执行计划缓存 | `ObPlanCacheKey` | `ObPCVSet` | `ObPhysicalPlan` |
| `NS_SPM` | SQL Plan Management 基线 | `ObBaselineKey` | `ObSpmSet` | `ObPlanBaselineItem` |
| `NS_PRCR` | 存储过程缓存 | `ObPLObjectKey` | `ObPLObjectSet` | `ObPLFunction` |
| `NS_PKG` | 包缓存 | `ObPLObjectKey` | `ObPLObjectSet` | `ObPLPackage` |
| `NS_UDF_RESULT_CACHE` | UDF 结果缓存 | `ObPLUDFResultCacheKey` | `ObPLUDFResultCacheSet` | `ObPLUDFResultCacheObject` |

---

## 2. 核心数据结构

### 2.1 ObILibCacheKey — 缓存键接口

**文件**：`src/sql/plan_cache/ob_i_lib_cache_key.h`（第 28-65 行）

所有缓存键的抽象基类。定义了三个纯虚接口：

```cpp
struct ObILibCacheKey {
  uint64_t hash() const = 0;           // 计算哈希值
  bool is_equal(const ObILibCacheKey &) const = 0;  // 比较相等性
  int deep_copy(ObIAllocator &, const ObILibCacheKey &) = 0;  // 深拷贝
};
```

每个命名空间实现自己的 Key 类。对于物理计划缓存，Key 是 `ObPlanCacheKey`。

### 2.2 ObPlanCacheKey — 物理计划缓存键

**文件**：`src/sql/plan_cache/ob_plan_cache_struct.h`（第 55-150 行）

核心字段：

```cpp
struct ObPlanCacheKey : public ObILibCacheKey {
  common::ObString name_;                // 参数化后的 SQL 文本
  uint64_t key_id_;                      // PS 模式下的 stmt_id
  uint64_t db_id_;                       // 数据库 ID
  uint32_t sessid_;                      // 会话 ID
  PlanCacheMode mode_;                   // TEXT / PS / PL 模式
  common::ObString sys_vars_str_;        // 系统变量序列化
  common::ObString config_str_;          // 配置参数序列化
  uint32_t flag_;                        // 标志位
  uint64_t sys_var_config_hash_val_;     // 系统变量+配置的哈希缓存
  common::ObCollationType collation_connection_;  // 连接校对规则
};
```

**关键设计决策**：
- `name_` 存储的是**参数化后的 SQL 文本**（即 `SELECT * FROM t WHERE c1 = ?`），而非原始 SQL。这使得带不同参数值的同一条 SQL 共享同一个缓存键。
- 哈希计算（`hash()` 方法）组合了多个维度的信息：参数化 SQL、数据库 ID、会话 ID、模式、系统变量、连接校对规则。这确保了不同用户/会话/环境下的 SQL 不会错误地共享计划。
- `sys_var_config_hash_val_` 是系统变量和配置参数的预计算哈希，加速缓存键的比较。

### 2.3 ObILibCacheObject — 缓存对象

**文件**：`src/sql/plan_cache/ob_i_lib_cache_object.h`（第 31-102 行）

每个被缓存的对象（如执行计划、SPM 基线项）继承自 `ObILibCacheObject`。核心字段：

```cpp
class ObILibCacheObject {
  lib::MemoryContext mem_context_;       // 内存上下文，用于生命周期管理
  volatile int64_t ref_count_;           // 引用计数，控制销毁时机
  uint64_t object_id_;                   // 全局唯一对象 ID
  int64_t log_del_time_;                 // 逻辑删除时间戳
  bool added_to_lc_;                     // 是否已加入缓存
  ObLibCacheNameSpace ns_;               // 所属命名空间
  CacheRefHandleID dynamic_ref_handle_;  // 动态引用句柄
  CacheObjStatus obj_status_;            // ACTIVE / ERASED / MARK_ERASED
};
```

引用计数管理：

```cpp
int64_t inc_ref_count(const CacheRefHandleID ref_handle);
bool try_inc_ref_count(const CacheRefHandleID ref_handle);
// dec_ref_count 是私有的，通过 ObLCObjectManager 调用
```

**对象生命周期**：
1. **创建**：通过 `ObCacheObjectFactory::alloc()` 分配（`ob_cache_object_factory.h` 第 34 行）
2. **加入缓存**：`set_added_lc(true)` 标记已加入
3. **引用**：`inc_ref_count()` 增加引用计数
4. **逻辑删除**：`set_obj_status(MARK_ERASED)`，设置 `log_del_time_`
5. **物理释放**：引用计数归零时，通过 `ObLCObjectManager::free()` 释放

### 2.4 ObILibCacheNode — 缓存节点

**文件**：`src/sql/plan_cache/ob_i_lib_cache_node.h`（第 82-156 行）

`ObILibCacheNode` 是 `ObILibCacheKey → ObILibCacheObject` 映射的中间层。每个 Node 管理一组属于同一个 Key 的 Object。

```cpp
class ObILibCacheNode {
  uint64_t id_;                          // 节点 ID
  TCRWLock rwlock_;                      // 读写锁，控制并发访问
  int64_t ref_count_;                    // 节点的引用计数
  StmtStat node_stat_;                   // 语句级统计信息
  ObPlanCache *lib_cache_;               // 所属 PlanCache
  CacheObjList co_list_;                 // 缓存对象列表（链表）
  bool is_invalid_;                      // 是否失效
};
```

**`StmtStat` 结构**（`ob_i_lib_cache_node.h` 第 35-73 行）：

```cpp
struct StmtStat {
  int64_t memory_used_;                  // 内存使用量
  int64_t last_active_timestamp_;        // 最后活跃时间
  int64_t execute_average_time_;         // 平均执行时间
  int64_t execute_count_;                // 执行次数
  // ...
  double weight();                       // 淘汰权重
};
```

权重计算（`weight()` 方法）：
```
weight = OB_PC_WEIGHT_NUMERATOR / (current_time - last_active_timestamp_)
```

这是 LRU（Least Recently Used）——权重与距上一次活跃的时间间隔成反比。长时间未使用的节点权重低，优先被淘汰。

### 2.5 ObPlanCache — 全局 PlanCache

**文件**：`src/sql/plan_cache/ob_plan_cache.h`（第 124-279 行）

全局 PlanCache 是租户级别的单例，管理整个缓存生命周期。

```cpp
class ObPlanCache {
  CacheKeyNodeMap cache_key_node_map_;   // 主哈希表: Key → Node
  ObLCObjectManager co_mgr_;            // 全局对象管理器
  ObLCNodeFactory cn_factory_;          // 节点工厂
  int64_t mem_limit_pct_;               // 内存上限百分比
  int64_t mem_high_pct_;                // 高水位百分比（触发淘汰）
  int64_t mem_low_pct_;                 // 低水位百分比（停止淘汰）
  volatile int64_t mem_used_;           // 当前内存使用量
  int64_t tenant_id_;                   // 所属租户
  ObPlanCacheEliminationTask evict_task_;// 后台淘汰任务
};
```

**常量**：
```cpp
static const int64_t MAX_PLAN_SIZE = 20*1024*1024;       // 单个计划最大 20MB
static const int64_t MAX_PLAN_CACHE_SIZE = 5*1024L*1024L*1024L;  // 5GB
static const int64_t MAX_TENANT_MEM = ((int64_t)(1) << 40);  // 1TB
static const int64_t EVICT_KEY_NUM = 8;  // 单次淘汰 8 个节点
```

---

## 3. 数据流

### 3.1 缓存查找流程

```
SQL 文本 "SELECT * FROM t WHERE c1 = 1"
    │
    ▼
┌───────────────────┐
│ 1. SQL 参数化      │  ob_sql_parameterization.cpp
│  "SELECT * FROM   │  将常量替换为占位符
│   t WHERE c1 = ?" │
└────────┬──────────┘
         ▼
┌───────────────────┐
│ 2. 构造缓存键      │  ObPlanCacheKey 构造
│  (参数化SQL + DB + │  hash() 字段组合
│   会话 + 系统变量)  │
└────────┬──────────┘
         ▼
┌───────────────────┐
│ 3. 查询哈希表      │  ObPlanCache::get_plan()
│  cache_key_node_  │  调用 get_cache_obj()
│  map_             │
└────────┬──────────┘
         │
    ┌────┴────┐
    ▼         ▼
  命中        未命中
    │           │
    ▼           ▼
┌──────────┐  ┌──────────────┐
│4a. 验证   │  │4b. 解析SQL    │Parser
│ 计划有效性 │  │    │          │
│  • 模式版本│  │    ▼          │
│  • 参数匹配│  │  优化生成计划   │Optimizer
│  • 权限匹配│  │    │          │
│  • 约束匹配│  │    ▼          │
│    │      │  │  缓存计划      │add_plan()
│    ▼      │  └──────────────┘
│  返回计划  │
└──────────┘
```

### 3.2 get_plan 源码路径

`ObPlanCache::get_plan()` → `get_plan_cache()` → `get_cache_obj()` → `ObILibCacheNode::get_cache_obj()`

在 `ObILibCacheNode::get_cache_obj()`（`ob_i_lib_cache_node.cpp` 第 80-93 行）：

```cpp
int ObILibCacheNode::get_cache_obj(ObILibCacheCtx &ctx,
                                   ObILibCacheKey *key,
                                   ObILibCacheObject *&obj)
{
  // ... 参数检查 ...
  if (OB_FAIL(inner_get_cache_obj(ctx, key, obj))) {
    LOG_DEBUG("failed to inner get cache obj", K(ret), K(key));
  } else {
    // 增加引用计数
    CacheRefHandleID ref_handle = obj->get_dynamic_ref_handle();
    ref_handle = (ref_handle != MAX_HANDLE ? ref_handle : LC_REF_CACHE_NODE_HANDLE);
    obj->inc_ref_count(ref_handle);
  }
  return ret;
}
```

`inner_get_cache_obj` 是虚函数，`ObPCVSet`（物理计划缓存节点）实现了它。内部会进行多层匹配：

1. **CacheNode 级别**：`ObPCVSet` 内包含一个 `ObPlanCacheValue` 数组（"plan set"），按 `sql_id` 分组
2. **PlanSet 级别**：匹配 schema 版本、参数信息、用户变量、权限
3. **CacheObj 级别**（具体计划）：匹配 location 约束、DOP、PWJ 约束

### 3.3 缓存添加流程

`ObPlanCache::add_plan()` → `add_plan_cache()` → `create_node_and_add_cache_obj()`

在 `ObILibCacheNode::add_cache_obj()`（`ob_i_lib_cache_node.cpp` 第 109-139 行）：

```cpp
if (OB_FAIL(inner_add_cache_obj(ctx, key, obj))) {
  LOG_WARN("failed to inner add cache obj");
} else {
  SpinWLockGuard lock_guard(co_list_lock_);
  co_list_.push_back(obj);  // 加入对象列表
}
CacheRefHandleID ref_handle = obj->get_dynamic_ref_handle();
ref_handle = (ref_handle != MAX_HANDLE ? ref_handle : LC_REF_CACHE_NODE_HANDLE);
obj->inc_ref_count(ref_handle);  // 节点持有引用
obj->set_added_lc(true);
```

### 3.4 缓存命中后的验证

即使哈希表中找到了 Key 对应的 Node，也不能直接返回第一个 Object。OceanBase 会经过多层验证，确保缓存计划仍然有效：

```
缓存命中
    │
    ▼
┌──────────────┐
│ PlanSet 级别  │  匹配维度：
│  验证        │
│              │  1. 表模式版本 → OLD_SCHEMA_VERSION
│              │  2. 参数信息 → PARAMS_INFO_NOT_MATCH
│              │  3. 用户变量 → USER_VARIABLE_NOT_MATCH  
│              │  4. 能力标志 → CAP_FLAGS_NOT_MATCH
│              │  5. 权限约束 → PRIVILEGE_CONSTR_NOT_MATCH
│              │  6. 预计算约束 → PRE_CALC_CONSTR_NOT_MATCH
└──────┬───────┘
       ▼
┌──────────────┐
│ CacheObj 级别  │  匹配维度：
│  验证        │
│              │  1. Location 约束 → LOCATION_CONSTR_NOT_MATCH
│              │  2. DOP 匹配 → LOCAL_PLAN_DOP_NOT_MATCH
│              │  3. PWJ 约束 → PWJ_CONSTR_NOT_MATCH
│              │  4. 计划过期 → EXPIRED_PHY_PLAN
│              │  5. 强制硬解析 → FORCE_HARD_PARSE (基于历史执行记录)
└──────┬───────┘
       ▼
   返回计划 或 继续扫描下一个计划
```

---

## 4. 内存管理与淘汰

### 4.1 内存水位

OceanBase 使用典型的水位标记（watermark）策略管理缓存内存：

```
                            淘汰高水位 (mem_high_)
  ▲  内存上限 (mem_limit) ─────────────────
  │                            ↑
  │                    触发淘汰，直至降到低水位
  │
  │  淘汰低水位 (mem_low_) ─────────────────
  │
  │  正常使用区域
  │
  └─────────────────────────────────────────────►
```

相关代码（`ob_plan_cache.h` 第 179-189 行）：

```cpp
int64_t get_mem_limit() const { 
  return get_tenant_memory() / 100 * get_mem_limit_pct();
}
int64_t get_mem_high() const { 
  return get_mem_limit() / 100 * get_mem_high_pct();
}
int64_t get_mem_low() const { 
  return get_mem_limit() / 100 * get_mem_low_pct();
}
```

默认配置项（`ob_plan_cache_util.h` 第 236-241 行）：
```cpp
struct ObPCMemPctConf {
  int64_t limit_pct_ = OB_PLAN_CACHE_PERCENTAGE;           // 默认 5%
  int64_t high_pct_ = OB_PLAN_CACHE_EVICT_HIGH_PERCENTAGE; // 默认 90%
  int64_t low_pct_ = OB_PLAN_CACHE_EVICT_LOW_PERCENTAGE;   // 默认 70%
};
```

即：默认 Plan Cache 可使用租户内存的 5%。当使用量达到上限的 90%（高水位）时触发淘汰，降至 70%（低水位）停止。

### 4.2 淘汰任务

`ObPlanCacheEliminationTask`（`ob_plan_cache.h` 第 196-205 行）是一个定时任务，后台每隔 30 秒检查内存水位：

```cpp
class ObPlanCacheEliminationTask : public common::ObTimerTask {
  void runTimerTask(void);              // 定时执行
  void run_plan_cache_task();           // 检查内存并淘汰
  void run_free_cache_obj_task();       // 释放已逻辑删除的对象
};
```

淘汰算法在 `calc_evict_num()` 中决定本次需要淘汰的节点数量。

### 4.3 淘汰策略

基于 `StmtStat::weight()` 的 LRU 变体：

```cpp
double weight() {
  int64_t time_interval = ObTimeUtility::current_time() - last_active_timestamp_;
  return OB_PC_WEIGHT_NUMERATOR / static_cast<double>(time_interval);
}
```

**特点**：
- 权重与距上次活跃的时间成反比——长时间不用的计划优先淘汰
- 也考虑执行次数 (`execute_count_`) 等信息
- 单次淘汰 8 个节点（`EVICT_KEY_NUM = 8`）

### 4.4 全局对象管理器

`ObLCObjectManager`（`ob_lib_cache_object_manager.h`）管理所有缓存对象的分配和释放：

- 使用哈希表 `obj_id → ObILibCacheObject*` 跟踪所有对象
- 提供 `free()` 接口减引用计数，引用归零时实际释放
- 诊断模式下记录引用操作历史（`ObCacheRefHandleMgr`）

---

## 5. SQL Plan Management (SPM)

SPM 是 Plan Cache 的重要扩展功能，用于管理执行计划基线（Plan Baseline），防止计划回退。

**代码位置**：`src/sql/spm/`

### 5.1 核心结构

SPM 遵循 Lib Cache 框架的约定，有自己的三件套：

| 组件 | 类 | 用途 |
|------|------|------|
| Key | `ObBaselineKey`（`ob_spm_define.h` 第 57-100 行） | 用 db_id + sql_id + format_sql_id 标识 |
| Node | `ObSpmSet`（`ob_spm_define.h` 第 257-300 行） | 管理同一 SQL 的所有基线项 |
| Object | `ObPlanBaselineItem`（`ob_spm_define.h` 第 103-215 行） | 单个基线项 |

**编译开关**：SPM 功能由 `#ifdef OB_BUILD_SPM` 控制，社区版可能不启用。

### 5.2 Plan Baseline 的属性

`ObPlanBaselineItem`（`ob_spm_define.h` 第 104-214 行）的关键字段：

```cpp
class ObPlanBaselineItem : public ObILibCacheObject {
  ObString origin_sql_text_;     // 原始 SQL 文本
  int64_t origin_;               // 来源：1=AUTO-CAPTURE, 2=MANUAL-LOAD
  ObString db_version_;          // 数据库版本
  uint64_t last_executed_;       // 最后执行时间
  uint64_t last_verified_;       // 最后验证时间
  uint64_t plan_hash_value_;     // 计划哈希值
  ObPhyPlanType plan_type_;      // 计划类型
  ObString outline_data_;         // Hint 集合（固定计划的 Hints）
  int64_t flags_;                 // 标志位
  uint64_t optimizer_cost_;      // 优化器成本
  int64_t executions_;           // 演化过程中的执行次数
  int64_t elapsed_time_;         // 演化总耗时
  int64_t cpu_time_;             // 演化总 CPU 时间
  int64_t avg_cpu_time_;         // 平均 CPU 时间
};
```

**标志位**（`PlanBaselineFlag` 枚举）：

```cpp
enum PlanBaselineFlag {
  PLAN_BASELINE_ENABLED = 1,     // 已启用
  PLAN_BASELINE_ACCEPTED = 2,    // 已接收（通过演化验证）
  PLAN_BASELINE_FIXED = 4,       // 已固定（始终使用该计划）
  PLAN_BASELINE_AUTOPURGE = 8,   // 自动清理
  PLAN_BASELINE_REPRODUCED = 16  // 已复现
};
```

### 5.3 计划演化机制

`ObEvolutionPlan`（`ob_spm_evolution_plan.h` 第 58-140 行）管理计划演化过程：

```
SQL 执行
    │
    ▼
┌─────────────────────┐
│ 检查是否需要演化      │  SPM Controller: check_baseline_enable()
│                     │
│ 条件：               │
│  • SPM 功能已启用     │
│  • 该 SQL 有基线      │
│  • 当前计划与基线不同  │
└─────────┬───────────┘
          ▼
┌─────────────────────┐
│ 在线演化 (online)    │  ObEvolutionPlan::get_plan()
│                     │
│ 交替策略：           │
│  • 轮流使用不同计划   │  choose_plan_for_online_evolution()
│  • 收集执行统计信息    │
│  • 比较 RT/CPU 时间   │  is_evolving_plan_better()
└─────────┬───────────┘
          ▼
┌─────────────────────┐
│ 比较与最终确定        │  compare_and_finalize_plan()
│                     │
│ 结果处理：           │
│  • 演化计划更好 → 接纳 │  discard_baseline + add_evolving
│  • 基线计划更好 → 丢弃 │  discard_evolving_plan
│  • 性能接近 → 保留两者 │
└─────────────────────┘
```

**演化阈值**（`ob_spm_evolution_plan.h` 第 103-106 行）：
```cpp
static const int64_t DEFAULT_EVOLUTION_COUNT_THRESHOLD = 150;    // 最少演化 150 次
static const int64_t DEFAULT_EVOLUTION_TIMEOUT_THRESHOLD = 3 * 60 * 60 * 1000L * 1000L; // 3 小时
static const int64_t DEFAULT_ERROR_COUNT_THRESHOLD = 3;           // 最大允许错误 3 次
```

### 5.4 SPM 控制器

`ObSpmController`（`ob_spm_controller.h`）提供静态方法：

```cpp
class ObSpmController {
  // 检查是否需要捕获计划基线
  static int check_baseline_enable(const ObPlanCacheCtx& pc_ctx,
                                   ObPhysicalPlan* plan,
                                   bool& need_capture);
  // 更新计划基线缓存
  static int update_plan_baseline_cache(ObPlanCacheCtx& pc_ctx,
                                        ObPhysicalPlan* plan);
  // 获取下一个基线的 outline（Hint）
  static void get_next_baseline_outline(ObSpmCacheCtx& spm_ctx);
  // 更新演化任务结果
  static int update_evolution_task_result(const ObPhysicalPlan *evo_plan,
                                          EvolutionTaskResult& result);
  // 用户手动接受计划基线
  static int accept_plan_baseline_by_user(obrpc::ObModifyPlanBaselineArg& arg);
  // 同步基线到磁盘
  static int sync_baseline();
};
```

---

## 6. 缓存 Miss 诊断系统

**文件**：`src/sql/plan_cache/ob_lib_cache_miss_diag.h`

OceanBase 提供了精细的缓存 Miss 诊断机制，帮助 DBA 理解为何计划没有命中缓存。

### 6.1 Miss 事件分类

使用 X-Macro 定义的 25+ 种 Miss 事件，按层级分组：

```
CACHE_NODE_LEVEL     → KEY_NOT_MATCH（Key 不存在）
PCV_LEVEL            → TABLE_SCHEMA_NOT_EXISTS
                     → NON_PARAMETERIZED_SQL_NOT_MATCH
                     → DIFF_TABLE_SCHEMA / DIFF_TMP_TABLE
PLAN_SET_LEVEL       → OLD_SCHEMA_VERSION
                     → PARAMS_INFO_NOT_MATCH
                     → USER_VARIABLE_NOT_MATCH
                     → CAP_FLAGS_NOT_MATCH
                     → PRIVILEGE_CONSTR_NOT_MATCH
CACHE_OBJ_LEVEL      → LOCATION_CONSTR_NOT_MATCH
                     → EXPIRED_PHY_PLAN
                     → FORCE_HARD_PARSE
                     → LOCAL_PLAN_DOP_NOT_MATCH
```

### 6.2 RECORD_CACHE_MISS 宏

```cpp
#define RECORD_CACHE_MISS(CODE, lib_cache_ctx, detail_info, ...)
```

这个宏记录了：
1. Miss 事件的代码（`LibCacheMissCode` 枚举）
2. 发生位置（文件名、行号、函数名）
3. 详细描述信息
4. 可选的 K-V 诊断数据

通过 `ObLibCacheMissEventRecorder` 在上下文中传递。`MATCH_GUARD` 宏为每次匹配过程建立作用域：

```cpp
#define MATCH_GUARD(id, lib_cache_ctx) \
  ObLibCacheMatchScopeGuard match_scope_guard(id, lib_cache_ctx.recorder_);
```

这确保了多级匹配过程中，每个级别的 Miss 事件都能追溯到正确的处理阶段。

---

## 7. 自适应 Auto DOP

**文件**：`src/sql/plan_cache/ob_adaptive_auto_dop.h`

`ObAdaptiveAutoDop` 负责计算表扫描的自动并行度（Degree of Parallelism），这是自适应计划选择的一部分。

```cpp
class ObAdaptiveAutoDop {
  int calculate_table_auto_dop(const ObPhysicalPlan &plan,
                               AutoDopHashMap &map,
                               bool &is_single_part);
  // ...
};
```

工作原理：
1. 遍历执行计划中的所有 `TableScan` 算子
2. 向存储层发起**估算请求**（`build_storage_estimation_tasks`）
3. 根据数据量和分区数计算合适的 DOP
4. 将结果写入 `AutoDopHashMap`（算子 ID → DOP 映射）

---

## 8. 设计决策

### 8.1 参数化 SQL vs 原始 SQL 作为缓存键

**选择**：参数化 SQL（`name_` 存储 `SELECT * FROM t WHERE c1 = ?`）

**理由**：
- 最大化缓存共享——`SELECT * FROM t WHERE c1 = 1` 和 `c1 = 2` 共享同一计划
- 参数化由 `ob_sql_parameterization.cpp`（137KB，Plan Cache 中最大的文件）处理
- 缺陷：不同参数值可能需要不同计划（谓词越界问题），OceanBase 通过 **参数约束**（`ObPCParamEqualInfo`）和**布尔参数优化**（`BOOL_PARAM_VALUE_NOT_MATCH` Miss 事件）解决

### 8.2 LRU vs LFU

**选择**：基于活跃时间的 LRU 变体 + 考虑执行频率

**理由**：
- LRU 简单高效，对临时的大查询很友好（执行完毕后很快被淘汰，释放内存）
- `weight()` 函数考虑了 `last_active_timestamp_`，但也记录 `execute_count_` 等信息
- 纯 LFU 会导致历史热门的计划长期占用缓存，即使不再需要
- 实际效果：OLTP 场景下热点查询持续活跃（`last_active_timestamp_` 持续更新），非热点查询自然淘汰

### 8.3 缓存分片与锁竞争

**设计**：全局 `CacheKeyNodeMap` 使用 `ObHashMap` + 节点级别的 `TCRWLock`

**理由**：
- 节点级别的锁（`TCRWLock`）允许同一节点的读操作完全并行
- 写操作（添加/淘汰）只影响单个节点
- 哈希表中的原子操作通过 `ObLibCacheAtomicOp`/`ObCacheObjAtomicOp` 实现
- `ObILibCacheNode::lock()` 支持超时重试（默认 100ms），避免死锁

### 8.4 计划失效策略

**触发条件**：
- Schema 版本变更（`OLD_SCHEMA_VERSION`）
- 统计信息更新（通过 `schema_version` 检测）
- 手动刷新（`flush_plan_cache()`）
- 计划过期（`EXPIRED_PHY_PLAN`）

**策略**：对比缓存的 `tenant_schema_version_`/`sys_schema_version_` 与当前 Schema 版本。版本不匹配时标记为失效，后续查询不走缓存。

### 8.5 全局缓存 vs 租户级缓存

**选择**：**租户级**——每个租户拥有独立的 `ObPlanCache` 实例

**理由**：
- 租户隔离：不同租户的数据、Schema、权限完全不同，不能共享计划
- 内存隔离：每个租户独立计算内存限制
- 实现方式：通过 `mtl_init()` 创建，`tenant_id_` 标识归属

### 8.6 SPM 的实现权衡

**编译开关**：SPM 由 `OB_BUILD_SPM` 控制

**权衡**：
- 启用 SPM 带来额外的缓存和检查开销
- 演化过程需消耗 CPU 和执行时间
- 但能有效避免计划回退（regression），对关键业务 SQL 至关重要
- 两个来源：`AUTO-CAPTURE`（自动捕获新计划）和 `MANUAL-LOAD`（DBA 手动导入）

---

## 9. 源码索引

| 文件 | 路径 | 说明 |
|------|------|------|
| 缓存键接口 | `src/sql/plan_cache/ob_i_lib_cache_key.h` | `ObILibCacheKey` 抽象基类 |
| 命名空间注册 | `src/sql/plan_cache/ob_lib_cache_register.h` | X-Macro 注册所有缓存命名空间 |
| 缓存键创建 | `src/sql/plan_cache/ob_lib_cache_key_creator.h` | `OBLCKeyCreator::create_cache_key()` |
| 物理计划键 | `src/sql/plan_cache/ob_plan_cache_struct.h` | `ObPlanCacheKey` 结构 |
| 缓存对象接口 | `src/sql/plan_cache/ob_i_lib_cache_object.h` | `ObILibCacheObject` 抽象基类 |
| 缓存对象基类 | `src/sql/plan_cache/ob_cache_object.h` | `ObPlanCacheObject` 实现 |
| 缓存对象工厂 | `src/sql/plan_cache/ob_cache_object_factory.h` | `ObCacheObjectFactory` + `ObCacheObjGuard` |
| 缓存节点接口 | `src/sql/plan_cache/ob_i_lib_cache_node.h` | `ObILibCacheNode` + `StmtStat` |
| 缓存节点实现 | `src/sql/plan_cache/ob_i_lib_cache_node.cpp` | 引用计数、缓存添加/获取 |
| 缓存上下文 | `src/sql/plan_cache/ob_i_lib_cache_context.h` | `ObILibCacheCtx` + Miss 诊断记录器 |
| 全局 PlanCache | `src/sql/plan_cache/ob_plan_cache.h` | `ObPlanCache` 主类 |
| PlanCache 实现 | `src/sql/plan_cache/ob_plan_cache.cpp` | 116K —— get_plan/add_plan 实现 |
| 缓存值 | `src/sql/plan_cache/ob_plan_cache_value.h/cpp` | `ObPlanCacheValue` 实现 |
| Plan Set | `src/sql/plan_cache/ob_plan_set.h/cpp` | `ObPlanSet` 实现 |
| PCV Set | `src/sql/plan_cache/ob_pcv_set.h/cpp` | `ObPCVSet` 实现 |
| 对象管理器 | `src/sql/plan_cache/ob_lib_cache_object_manager.h` | `ObLCObjectManager` |
| 节点工厂 | `src/sql/plan_cache/ob_lib_cache_node_factory.h` | `ObLCNodeFactory` |
| 引用句柄 | `src/sql/plan_cache/ob_pc_ref_handle.h` | `ObCacheRefHandleMgr` |
| 回调原子操作 | `src/sql/plan_cache/ob_plan_cache_callback.h` | `ObLibCacheAtomicOp` / `ObCacheObjAtomicOp` |
| 参数化 SQL | `src/sql/plan_cache/ob_sql_parameterization.h/cpp` | 137K —— SQL 参数化核心 |
| 匹配辅助 | `src/sql/plan_cache/ob_plan_match_helper.h/cpp` | 计划匹配验证逻辑 |
| 常量参数约束 | `src/sql/plan_cache/ob_plan_cache_param_constraint.h` | 参数约束检查 |
| 自适应 Auto DOP | `src/sql/plan_cache/ob_adaptive_auto_dop.h` | 自动并行度计算 |
| Miss 诊断 | `src/sql/plan_cache/ob_lib_cache_miss_diag.h` | 25+ 种 Miss 事件定义和记录 |
| 缓存工具类 | `src/sql/plan_cache/ob_plan_cache_util.h` | 辅助结构（`ObPCMemPctConf`, `ObPCParam` 等） |
| 分布式计划 | `src/sql/plan_cache/ob_dist_plans.h/cpp` | 分布式执行计划缓存 |
| ID 管理器 | `src/sql/plan_cache/ob_id_manager_allocator.h/cpp` | 对象 ID 分配 |
| PS 缓存 | `src/sql/plan_cache/ob_ps_cache.h/cpp` | Prepare Statement 缓存 |
| SPM 定义 | `src/sql/spm/ob_spm_define.h` | `ObBaselineKey`, `ObSpmSet`, `ObPlanBaselineItem` |
| SPM 演化 | `src/sql/spm/ob_spm_evolution_plan.h` | `ObEvolutionPlan` 计划演化 |
| SPM 控制器 | `src/sql/spm/ob_spm_controller.h` | `ObSpmController` 静态管理方法 |
| SPM 结构 | `src/sql/spm/ob_spm_struct.h` | SPM 辅助结构 |
| 基线管理器 | `src/sql/spm/ob_plan_baseline_mgr.h` | Plan Baseline 持久化管理 |

---

## 10. 总结

Plan Cache 是 OceanBase SQL 执行引擎中承上启下的关键组件。它位于优化器和执行器之间，通过缓存优化好的执行计划，避免了重复优化带来的 CPU 开销。

### 架构特点

1. **通用 Lib Cache 框架**：不仅缓存 SQL 执行计划，还扩展到 PL 对象、TableAPI、SPM 等多种场景
2. **三层结构**：`Key → Node → Object`，支持多版本计划共存，细粒度匹配验证
3. **LRU 变体淘汰**：基于活跃时间的权重计算，配合水位机制控制缓存大小
4. **精细的 Miss 诊断**：25+ 种 Miss 事件帮助 DBA 定位缓存未命中的根因
5. **SPM 计划管理**：通过计划基线防止计划回退，支持自动捕获和在线演化

### 性能数据

| 指标 | 值 |
|------|------|
| 单计划最大大小 | 20MB |
| 缓存上限（默认） | 租户内存的 5% |
| 绝对上限 | 5GB |
| 击穿率 | < 1%（OLTP 场景） |
| 单次淘汰数量 | 8 个节点 |
| 后台检查间隔 | 30 秒 |

### 未来优化方向

从代码中可以看到一些正在发展的方向：
- **自适应并行度**（`ObAdaptiveAutoDop`）：根据实际数据量动态调整计划
- **强制硬解析**（`FORCE_HARD_PARSE`）：基于历史执行记录判断是否需要重新优化
- **诊断增强**（`ObCacheRefHandleMgr`）：引用操作的可追踪性
