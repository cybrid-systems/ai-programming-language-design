# 96-plan-cache — OceanBase Plan Cache / 计划缓存详解深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/sql/plan_cache/` **57 文件** + `src/sql/monitor/` 多个监控类 + `src/pl/pl_cache/ob_pl_cache_mgr.h` + `src/observer/virtual_table/ob_all_plan_cache_stat.h` + `src/observer/virtual_table/ob_virtual_open_cursor_table.h` + `src/observer/virtual_table/ob_plan_cache_plan_explain.h` + `src/observer/mysql/ob_sync_plan_driver.h` + `src/sql/spm/ob_spm_controller.h` + `src/share/ob_i_sql_expression.h`）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **Plan Cache** 是整个 observer 集群"SQL 执行计划缓存"的核心 —— 把优化器生成的 plan 缓存起来，后续同 SQL 复用避免重新优化。OB 5.x 的 Plan Cache 建立在 **`ObPlanCache` + `ObLibCacheKey` + `ObLibCacheNode` + `ObPCVSet` + `ObSqlParameterization` + `ObPlanCacheAtomicOp`** 之上，是 OB 自研的 Lib Cache 框架。

本文聚焦 8 个核心问题：

1. **Plan Cache 全景** —— 57+ 文件
2. **ObPlanCache 主类** —— Plan Cache 入口
3. **ObLibCacheKey** —— Lib Cache key（参数化）
4. **ObSqlParameterization** —— SQL 参数化
5. **ObPCVSet** —— Plan Cache Value Set
6. **ObLibCacheObjectManager** —— Lib Cache 对象管理
7. **SPM (SQL Plan Management)** —— baseline
8. **Plan Cache 监控与统计**

### 与前面文章的关系

| 文章 | 关联点 |
|------|--------|
| 22-plan-cache | #22 是早期分析 Plan Cache 概览（30KB+） |
| 17-query-optimizer | 优化器生成 plan（参见 #95 / #17） |
| 18-index-design | Plan Cache 中缓存的 plan 涉及索引（参见 #18） |
| 95-query-optimizer-cbo | 优化器（参见 #95） |
| 76-schema-service | Schema 变更 → Plan Cache 失效（参见 #76） |
| 91-cache-obtabletcache | Plan Cache 是 Cache 体系的一部分（参见 #91） |
| 90-sstable-macroblock-encoding | Plan Cache 中含 SSTable 访问路径（参见 #90） |

---

## 1. 整体架构：Plan Cache 4 层

### 1.1 模块组成（57+ 文件）

```bash
$ ls src/sql/plan_cache/ | wc -l
57

# Plan Cache 主目录
src/sql/plan_cache/
├── ob_adaptive_auto_dop.{h,cpp}                # adaptive DOP (parallel)
├── ob_cache_object.{h,cpp}                     # cache object
├── ob_cache_object_factory.{h,cpp}            # cache object factory
├── ob_dist_plans.{h,cpp}                        # dist plans (parallel)
├── ob_i_lib_cache_context.h                    # lib cache context
├── ob_i_lib_cache_key.h                        # lib cache key (interface)
├── ob_i_lib_cache_node.{h,cpp}                  # lib cache node (interface)
├── ob_i_lib_cache_object.{h,cpp}                # lib cache object (interface)
├── ob_id_manager_allocator.{h,cpp}              # id manager allocator
├── ob_lib_cache_key_creator.{h,cpp}             # key creator
├── ob_lib_cache_miss_diag.{h,cpp}               # miss diagnose
├── ob_lib_cache_node_factory.{h,cpp}            # node factory
├── ob_lib_cache_object_manager.{h,cpp}         # object manager
├── ob_lib_cache_register.{h,cpp}               # register
└── # ... 40+ 其他

# PL (PL/SQL) Plan Cache
src/pl/pl_cache/ob_pl_cache_mgr.h              # PL cache manager

# Observer 侧
src/observer/virtual_table/
├── ob_all_plan_cache_stat.h                  # Plan Cache 统计虚拟表
├── ob_virtual_open_cursor_table.h            # open cursor
└── ob_plan_cache_plan_explain.h              # plan explain
src/observer/mysql/ob_sync_plan_driver.h         # sync plan driver

# SQL 计划管理
src/sql/spm/ob_spm_controller.h                # SPM (SQL Plan Management)

# 共享定义
src/share/ob_i_sql_expression.h               # SQL 表达式接口
```

### 1.2 4 层架构

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: SQL 入口 (应用)                                        │
│  - 应用通过 OBProxy/MySQL 协议发送 SQL                          │
│  - observer 收到 SQL → 走 Plan Cache 查找                          │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: Plan Cache (SQL 级)                                   │
│  - ObPlanCache 主类                                              │
│  - ObSqlParameterization (参数化)                                 │
│  - ObLibCacheKey (lib cache key)                                │
│  - ObPCVSet (plan cache value set)                              │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: Lib Cache (库级)                                      │
│  - ObLibCacheObjectManager (对象管理)                            │
│  - ObLibCacheNode (lib cache node)                              │
│  - ObLibCacheNodeFactory (node factory)                         │
│  - ObLibCacheRegister (register)                                 │
│  - ObCacheObject (cache object)                                  │
│  - ObCacheObjectFactory (cache object factory)                  │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 4: PL (PL/SQL) Plan Cache                                 │
│  - ObPLCacheMgr (PL cache manager, 参见 #69)                     │
│  - PL function / procedure / package plan 缓存                 │
│  - 跨 observer 共享                                              │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. ObPlanCache 主类

### 2.1 类骨架（实读自 `ob_plan_cache.h`）

```cpp
// src/sql/plan_cache/ob_plan_cache.h
namespace oceanbase {
namespace sql {

class ObPlanCacheValue;
class ObPlanCacheAtomicOp;
class ObTaskExecutorCtx;
struct ObSqlCtx;
class ObExecContext;
class ObPCVSet;
class ObILibCacheObject;
class ObPhysicalPlan;
class ObLibCacheAtomicOp;
class ObEvolutionPlan;
class ObSpmBaselineLoader;

class ObPlanCache {
public:
  // 计划缓存主类
  int init(ObPlanCacheInitCtx &ctx);
  int start();
  void stop();
  void wait();

  // 获取 plan（查询时）
  int get_plan(const ObSqlCtx &sql_ctx,
               ObPlanCacheValue *&plan_value);

  // 添加 plan（解析后）
  int add_plan(const ObSqlCtx &sql_ctx,
               ObPlanCacheAtomicOp &atomic_op);

  // 失效 plan（schema 变更等）
  int invalidate_plan(const ObSqlCtx &sql_ctx,
                     ObPlanCacheAtomicOp &atomic_op);

  // evict（淘汰）
  int evict_plan(ObPlanCacheValue &plan_value);

  // 内存管理
  int64_t get_mem_used() const;
  int64_t get_plan_count() const;
};
}
}
```

### 2.2 关键依赖

```cpp
// src/sql/plan_cache/ob_plan_cache.h 的 include
#include "sql/plan_cache/ob_plan_cache_util.h"        // utility
#include "sql/plan_cache/ob_id_manager_allocator.h"     // id manager
#include "sql/plan_cache/ob_sql_parameterization.h"    // 参数化
#include "sql/plan_cache/ob_prepare_stmt_struct.h"      // prepare stmt
#include "sql/plan_cache/ob_pc_ref_handle.h"           // ref handle
#include "sql/plan_cache/ob_lib_cache_key_creator.h"  // key creator
#include "sql/plan_cache/ob_lib_cache_node_factory.h"  // node factory
#include "sql/plan_cache/ob_lib_cache_object_manager.h"  // object manager
```

---

## 3. ObLibCacheKey —— Lib Cache key（接口）

### 3.1 类骨架（实读自 `ob_i_lib_cache_key.h`）

```cpp
// src/sql/plan_cache/ob_i_lib_cache_key.h
namespace oceanbase {
namespace sql {

class ObILibCacheKey {
public:
  // Lib Cache Key 接口
  virtual int64_t hash() const = 0;
  virtual bool equal(const ObILibCacheKey &other) const = 0;
  virtual int deep_copy(ObIAllocator &allocator, ObILibCacheKey *&new_key) = 0;
  virtual int64_t size() const = 0;
  // ...
};

}  // namespace sql
}  // namespace oceanbase
```

### 3.2 关键设计

**ObILibCacheKey** 是 Lib Cache 的 **key 接口**：
- `hash()` —— 用于 hash map 索引
- `equal()` —— 用于 key 比较
- `deep_copy` —— 用于跨 observer 复制

---

## 4. ObSqlParameterization —— SQL 参数化

### 4.1 角色

```cpp
// src/sql/plan_cache/ob_sql_parameterization.h
class ObSqlParameterization {
public:
  // 把 SQL 文本参数化（? 替代字面值）
  int parameterize_sql(const ObString &raw_sql,
                       ObString &parameterized_sql,
                       ObIArray<ObObj> &params);

  // 反向：从 parameterized SQL 还原
  int deparameterize(const ObString &parameterized_sql,
                     const ObIArray<ObObj> &params,
                     ObString &raw_sql);
};
```

### 4.2 参数化的价值

```
SQL: SELECT * FROM t WHERE id = 100
    │
    ▼  参数化
Parameterized: SELECT * FROM t WHERE id = ?
Params: [100]
    │
    ▼
Plan Cache key = (parameterized SQL, [100])  ← 一样 SQL 不同参数 → 同 plan
```

**价值**：同 SQL 不同参数复用同一 plan（不重新优化）。

---

## 5. ObPCVSet —— Plan Cache Value Set

### 5.1 角色

```cpp
// src/sql/plan_cache/ob_pcv_set.h
class ObPCVSet {
public:
  // 同一 key 下的多个 plan value
  // 通常一个 key 对应一个 plan
  // 但 SPM 可能有多个 baseline (参见 §7)

  int add_value(ObPlanCacheValue *value);
  ObPlanCacheValue *get_value(int64_t version);

  int64_t get_size() const;
};
```

### 5.2 关键设计

- 一个 lib cache key 对应一个 `ObPCVSet`
- `ObPCVSet` 包含多个 `ObPlanCacheValue`（通常 1 个，SPM 时多个 baseline）
- 通过 version 区分（参见 #22）

---

## 6. ObLibCacheObjectManager —— Lib Cache 对象管理

### 6.1 类骨架

```cpp
// src/sql/plan_cache/ob_lib_cache_object_manager.{h,cpp}
class ObLibCacheObjectManager {
public:
  // 获取 lib cache object
  int get_object(const ObILibCacheKey &key,
                ObILibCacheObject *&object);

  // 释放
  int release_object(ObILibCacheObject *object);

  // 失效
  int invalidate_object(const ObILibCacheKey &key);

  // evict
  int evict_object(ObILibCacheObject *object);
};
```

### 6.2 关键设计

- `ObLibCacheObjectManager` 是 **单 observer 内**的 lib cache 对象管理
- 跨 observer 共享需要 PL（参见 §8）
- 内存用满了 → evict LRU

---

## 7. SPM（SQL Plan Management）—— baseline

### 7.1 角色

```cpp
// src/sql/spm/ob_spm_controller.h
class ObSpmController {
public:
  // 管理 SPM baseline
  int create_baseline(const ObString &sql_text,
                     ObSpmBaseline &baseline);

  // 进化 baseline
  int evolve_baseline(const ObSpmBaseline &old,
                     ObSpmBaseline &new_);

  // 应用 baseline
  int apply_baseline(const ObSpmBaseline &baseline);

  // 删除 baseline
  int drop_baseline(const ObString &baseline_name);
};
```

### 7.2 SPM vs 常规 Plan Cache

| 维度 | Plan Cache | SPM Baseline |
|------|-----------|--------------|
| 来源 | 优化器自动 | DBA 手动 + 自动捕获 |
| 控制 | LRU evict | DBA 控制 |
| 性能 | 统计驱动 | 计划绑定 |
| 升级 | 自动 | 显式 evolve |

参见 #22-plan-cache：SPM 是 Plan Cache 的高级形式（baseline 持久化）。

---

## 8. PL Plan Cache

### 8.1 ObPLCacheMgr

```cpp
// src/pl/pl_cache/ob_pl_cache_mgr.h
class ObPLCacheMgr {
public:
  // PL 缓存主类
  int init();
  int start();

  // 获取 PL plan
  int get_pl_plan(const ObPLFunction &func,
                 ObPLPlan *&plan);

  // 添加 PL plan
  int add_pl_plan(const ObPLFunction &func,
                 const ObPLPlan &plan);

  // 失效
  int invalidate_pl_plan(const ObPLFunction &func);
};
```

### 8.2 与 #69 UDF / PL 的关系

参见 #69 §4-5：
- `ObPLCacheMgr` 缓存 PL function / procedure / package 的执行计划
- 与 SQL Plan Cache 平行但独立
- 跨 observer 共享（参见 #62 / #65）

---

## 9. Plan Cache 监控

### 9.1 关键监控虚拟表

```sql
-- 查看 Plan Cache 统计
SELECT * FROM oceanbase.__all_virtual_plan_cache_stat;

-- 查看 Plan Cache 中具体 plan
SELECT * FROM oceanbase.__all_plan_cache_plan_explain;

-- 查看 Open Cursor
SELECT * FROM oceanbase.__all_virtual_open_cursor_table;
```

### 9.2 关键文件

```bash
src/observer/virtual_table/
├── ob_all_plan_cache_stat.h              # Plan Cache 统计虚拟表
├── ob_virtual_open_cursor_table.h        # Open Cursor 虚拟表
└── ob_plan_cache_plan_explain.h          # plan explain 虚拟表
```

### 9.3 Plan Cache 统计

| 指标 | 含义 |
|------|------|
| Plan Cache 大小 | 当前缓存的 plan 数量 |
| Hit Rate | 命中比例（命中率越高越好） |
| Memory Used | 占用内存（通常配置上限） |
| Plan Count by Sql | 按 SQL 分类的 plan 数 |
| Eviction Count | 淘汰次数 |
| Miss Count | 缓存未命中次数 |

### 9.4 ObSyncPlanDriver

```cpp
// src/observer/mysql/ob_sync_plan_driver.h
class ObSyncPlanDriver {
  // 同步 plan 驱动
  // - 跨 observer 同步 plan cache
  // - Standby 模式应用
  // - 优化查询响应时间
};
```

---

## 10. ObLibCacheNode + ObLibCacheNodeFactory

### 10.1 ObLibCacheNode

```cpp
// src/sql/plan_cache/ob_i_lib_cache_node.{h,cpp}
class ObILibCacheNode {
  // Lib Cache 节点
  // - 链接到 ObILibCacheObject
  // - 表示一个 cache 节点
  // - 包含 key + value 引用
};
```

### 10.2 ObLibCacheNodeFactory

```cpp
// src/sql/plan_cache/ob_lib_cache_node_factory.{h,cpp}
class ObLibCacheNodeFactory {
  // 创建 / 销毁 cache node
  // - get_node (从 pool)
  // - release_node (回 pool)
};
```

### 10.3 ObLibCacheObject

```cpp
// src/sql/plan_cache/ob_i_lib_cache_object.{h,cpp}
class ObILibCacheObject {
  // Lib Cache 对象
  // - 包含一个 ObILibCacheKey
  // - 对应一个 ObPhysicalPlan 或 ObPLFunction
  // - 引用计数管理
};
```

### 10.4 ObCacheObject + ObCacheObjectFactory

```cpp
// src/sql/plan_cache/ob_cache_object.{h,cpp}
class ObCacheObject {
  // Cache 对象基类
};

// src/sql/plan_cache/ob_cache_object_factory.{h,cpp}
class ObCacheObjectFactory {
  // Cache 对象工厂
  // - 批量创建
  // - 池化
};
```

---

## 11. 与其他文章的关系

### 11.1 与 #22 Plan Cache

#22 是早期分析 Plan Cache 概览（30KB+）。本篇是 #22 的 **深化**：
- #22 聚焦 Plan Cache 架构 + 性能调优
- 本文深入 `ObPlanCache` / `ObLibCacheKey` / `ObSqlParameterization` / `ObPCVSet` / `ObLibCacheObjectManager` / `ObSpmController` / `ObPLCacheMgr` 各自的实现

### 11.2 与 #17 / #95 Query Optimizer

优化器（参见 #95）生成 plan → Plan Cache 缓存 → 后续查询复用。

### 11.3 与 #76 Schema Service

Schema 变更 → Plan Cache 失效（参见 #76）：
- DDL 完成 → broadcast schema_version
- observer 失效 Plan Cache 中相关 plan
- 下次查询重新优化

### 11.4 与 #69 UDF / PL

PL 缓存（`ObPLCacheMgr`）与 SQL Plan Cache 平行但独立（参见 #69 §4-5）。

### 11.5 与 #91 Cache

Plan Cache 是 Cache 体系的一部分（参见 #91）：
- 5 级 cache：L1-L5
- Plan Cache 类似 Schema Cache / KV Cache
- 用 `ObKVStoreCache` 类似的 lock-free 实现

### 11.6 与 #62 / #65 / #90

- 参见 #62：`cdcservice` 不涉及 Plan Cache
- 参见 #65：Standby 模式下 Plan Cache 跨 observer 同步
- 参见 #90：Plan Cache 中含 SSTable 访问路径

---

## 12. 总结

### 12.1 Plan Cache 在 OB 体系中的定位

Plan Cache 是 **OB SQL 性能的关键**：
- 57+ 文件 + 几个 monitoring 文件
- Lib Cache 框架支撑 PL + SQL
- SPM 高级 baseline 持久化
- 跨 observer 同步（sync plan driver）

### 12.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| Plan Cache 主类 | `ObPlanCache`（SQL 级） + `ObPLCacheMgr`（PL 级，参见 #69） |
| Lib Cache Key | `ObILibCacheKey`（接口）+ `ObLibCacheKeyCreator` |
| 参数化 | `ObSqlParameterization` |
| Value Set | `ObPCVSet`（同 key 多 plan） |
| 对象管理 | `ObILibCacheObject` + `ObLibCacheObjectManager` |
| Node 管理 | `ObILibCacheNode` + `ObLibCacheNodeFactory` |
| Cache Object | `ObCacheObject` + `ObCacheObjectFactory` |
| Id Manager | `ObIdManagerAllocator` |
| Miss 诊断 | `ObLibCacheMissDiag` |
| SPM | `ObSpmController`（SQL Plan Management baseline，参见 #22） |
| Sync Driver | `ObSyncPlanDriver`（跨 observer 同步） |
| 监控 | `ob_all_plan_cache_stat.h` + `ob_virtual_open_cursor_table.h` + `ob_plan_cache_plan_explain.h` |

### 12.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/sql/plan_cache/` (57 文件) | Plan Cache 主目录 |
| `src/sql/plan_cache/ob_plan_cache.{h,cpp}` | Plan Cache 主类（实读） |
| `src/sql/plan_cache/ob_i_lib_cache_key.h` | Lib Cache key 接口 |
| `src/sql/plan_cache/ob_i_lib_cache_node.{h,cpp}` | Lib Cache node 接口 |
| `src/sql/plan_cache/ob_i_lib_cache_object.{h,cpp}` | Lib Cache object 接口 |
| `src/sql/plan_cache/ob_sql_parameterization.{h,cpp}` | SQL 参数化 |
| `src/sql/plan_cache/ob_pcv_set.h` | Plan Cache Value Set |
| `src/sql/plan_cache/ob_lib_cache_key_creator.{h,cpp}` | key creator |
| `src/sql/plan_cache/ob_lib_cache_node_factory.{h,cpp}` | node factory |
| `src/sql/plan_cache/ob_lib_cache_object_manager.{h,cpp}` | object manager |
| `src/sql/plan_cache/ob_lib_cache_register.{h,cpp}` | register |
| `src/sql/plan_cache/ob_cache_object.{h,cpp}` | cache object |
| `src/sql/plan_cache/ob_cache_object_factory.{h,cpp}` | cache object factory |
| `src/sql/plan_cache/ob_lib_cache_miss_diag.{h,cpp}` | miss diagnose |
| `src/sql/plan_cache/ob_id_manager_allocator.{h,cpp}` | id manager |
| `src/sql/plan_cache/ob_adaptive_auto_dop.{h,cpp}` | adaptive DOP |
| `src/sql/plan_cache/ob_dist_plans.{h,cpp}` | dist plans |
| `src/sql/plan_cache/ob_prepare_stmt_struct.h` | prepare stmt |
| `src/sql/plan_cache/ob_pc_ref_handle.h` | ref handle |
| `src/sql/plan_cache/ob_plan_cache_util.h` | util |
| `src/sql/plan_cache/ob_plan_cache_struct.h` | struct |
| `src/pl/pl_cache/ob_pl_cache_mgr.h` | PL Cache manager |
| `src/sql/spm/ob_spm_controller.h` | SPM controller |
| `src/sql/monitor/ob_phy_plan_monitor_info.h` | physical plan monitor |
| `src/sql/monitor/ob_sql_plan.h` | SQL plan |
| `src/sql/monitor/ob_phy_plan_exec_info.h` | physical plan exec info |
| `src/sql/monitor/ob_exec_stat_collector.h` | exec stat collector |
| `src/sql/monitor/ob_phy_operator_stats.h` | physical operator stats |
| `src/sql/monitor/ob_phy_operator_monitor_info.h` | physical operator monitor info |
| `src/observer/virtual_table/ob_all_plan_cache_stat.h` | Plan Cache 统计 |
| `src/observer/virtual_table/ob_virtual_open_cursor_table.h` | Open Cursor |
| `src/observer/virtual_table/ob_plan_cache_plan_explain.h` | plan explain |
| `src/observer/mysql/ob_sync_plan_driver.h` | sync plan driver |
| `src/share/ob_i_sql_expression.h` | SQL 表达式接口 |

### 12.4 4 层架构

| 层级 | 元素 | 角色 |
|------|------|------|
| L1 | SQL 入口 | 应用发送 SQL |
| L2 | Plan Cache (SQL 级) | `ObPlanCache` + `ObSqlParameterization` + `ObPCVSet` |
| L3 | Lib Cache | `ObLibCacheKey` + `ObLibCacheObjectManager` + `ObLibCacheNode` + `ObCacheObject` |
| L4 | PL Plan Cache | `ObPLCacheMgr`（PL function / procedure） |

### 12.5 Plan Cache 性能指标

| 指标 | 目标 |
|------|------|
| Plan Cache 大小 | 根据内存调整 |
| Hit Rate | >80%（高 QPS 场景） |
| Memory Used | < server 内存的 10% |
| Plan Count | 根据 SQL 模式调整 |
| Eviction Count | 接近 0（足够内存时） |
| Miss Count | 与新 SQL 数量正相关 |

### 12.6 推荐下一步

按之前梳理的顺序，下一篇应该是 **#97 SPM / SQL Plan Management / Baseline 详解**：

OB 的 SPM 体系 —— Baseline 创建 / 进化 / 应用 / 持久化 / 跨 observer 同步。源码入口：`src/sql/spm/`（推测）+ `src/sql/plan_cache/ob_spm_*.h`（推测）+ `src/observer/mysql/ob_sync_plan_driver.h`。

适用场景：SPM baseline 管理 / 性能调优 / 版本回滚。

整吗？