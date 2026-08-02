# 95-query-optimizer — OceanBase 查询优化器 / 优化器 / CBO / 代价估算深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码（`src/sql/optimizer/` **184 文件** + `src/sql/rewrite/` **107 文件** + `src/share/stat/` 多个 opt_stat 类 + `src/sql/monitor/` 多个监控类 + `src/sql/optimizer/ob_optimizer.h` + `src/sql/ob_sql.h` + `src/sql/optimizer/ob_sharding_info.h`）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **查询优化器**是整个 observer 集群"SQL → 执行计划"的核心 —— 把用户的 SQL 文本转化为高效的执行计划（Logical Plan → Physical Plan → Executor）。OB 5.x 的优化器建立在 `ObOptimizer` + `ObLogPlan` + `ObPhyPlan` + 多个访问路径估计 + 改写规则之上，是 OB 自研的 CBO（Cost-Based Optimizer）。

本文聚焦 8 个核心问题：

1. **优化器全景** —— 184 + 107 文件
2. **ObOptimizer** —— 优化器主类
3. **ObLogPlan / ObPhyPlan** —— 逻辑 / 物理计划
4. **ObJoinOrder** —— 连接顺序优化
5. **ObAccessPathEstimation** —— 访问路径代价估算
6. **ObPredicateDeduce / ObQueryRange** —— 谓词下推 + range 优化
7. **ObOptimizerStatistics** —— CBO 统计信息
8. **ObTransformRule** —— 改写规则

### 与前面文章的关系

| 文章 | 关联点 |
|------|--------|
| 17-query-optimizer | #17 是早期分析优化器概览（30KB+） |
| 18-index-design | 索引选择是优化器核心（参见 #18） |
| 22-plan-cache | plan cache 缓存已生成的 plan（参见 #22） |
| 41-join-operators | join operator 是 plan 的执行节点（参见 #41） |
| 42-sort-window | sort / window operator |
| 94-index-system | 索引系统（优化器选择的对象，参见 #94） |
| 90-sstable-macroblock-encoding | 访问路径的物理载体（参见 #90） |

---

## 1. 整体架构：优化器 5 层

### 1.1 模块组成（291 文件）

```bash
$ ls src/sql/optimizer/ | wc -l
184
$ ls src/sql/rewrite/ | wc -l
107

# 优化器主目录
src/sql/optimizer/
├── ob_access_path_estimation.{h,cpp}    # 访问路径代价估算
├── ob_conflict_detector.{h,cpp}          # 冲突检测
├── ob_del_upd_log_plan.{h,cpp}           # delete/update log plan
├── ob_delete_log_plan.{h,cpp}            # delete log plan
├── ob_direct_load_optimizer_ctx.{h,cpp}  # direct load optimizer ctx
├── ob_dynamic_sampling.{h,cpp}           # 动态采样
├── ob_explain_log_plan.{h,cpp}           # explain log plan
├── ob_explain_note.h                     # explain note
├── ob_fd_item.{h,cpp}                     # functional dependency item
├── ob_help_log_plan.{h,cpp}              # help log plan
├── ob_index_info_cache.{h,cpp}           # index info cache
├── ob_insert_all_log_plan.{h,cpp}        # insert all log plan
├── ob_insert_log_plan.{h,cpp}            # insert log plan
├── ob_join_order.{h,cpp}                 # 连接顺序优化
├── ob_join_order_enum.{h,cpp}            # 连接顺序 enum
└── # ... 170+ 其他

# 改写规则
src/sql/rewrite/
├── ob_equal_analysis.{h,cpp}             # equal analysis
├── ob_expand_aggregate_utils.{h,cpp}     # expand aggregate utils
├── ob_expr_range_converter.{h,cpp}       # expression range converter
├── ob_key_part.{h,cpp}                   # key part
├── ob_predicate_deduce.{h,cpp}           # predicate deduce
├── ob_query_range.{h,cpp}                # query range
├── ob_query_range_define.{h,cpp}         # query range define
├── ob_query_range_provider.h             # query range provider
├── ob_range_generator.{h,cpp}            # range generator
├── ob_range_graph_generator.{h,cpp}      # range graph generator
└── # ... 100+ 其他

# 统计信息
src/share/stat/
├── ob_stat_define.{h,cpp}                # stat define
├── ob_stats_estimator.{h,cpp}            # stats estimator
├── ob_stat_item.{h,cpp}                   # stat item
├── ob_opt_stat_manager.{h,cpp}            # optimizer stat manager
├── ob_opt_stat_gather_stat.{h,cpp}        # gather stat
├── ob_opt_stat_sql_service.{h,cpp}        # SQL service
├── ob_opt_stat_monitor_manager.{h,cpp}    # monitor manager
├── ob_opt_stat_service.{h,cpp}            # service
└── ob_dbms_stats_preferences.h           # DBMS stats preferences
```

**291 文件** —— 优化器 + 改写 = OB SQL 层的核心。

### 1.2 5 层架构

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: SQL 解析 (Parser)                                       │
│  - SQL 文本 → ParseNode                                          │
│  - 参见 #23-sql-parser                                          │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: Resolver (参见 #23)                                    │
│  - 名称 + 类型解析                                                │
│  - Schema Guard (参见 #64)                                       │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: ObLogPlan (逻辑计划)                                    │
│  - 改写 + 谓词下推 (ObTransformRule + ObPredicateDeduce)        │
│  - logical operator tree (ObLogicalOperator)                    │
│  - 25+ 种 log plan (select / insert / update / delete / join)    │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 4: ObOptimizer (CBO)                                       │
│  - 连接顺序优化 (ObJoinOrder)                                   │
│  - 访问路径选择 (ObAccessPathEstimation)                        │
│  - 代价估算 (ObOptimizerStatistics + ObStatsEstimator)          │
│  - 物理化 (log plan → physical plan)                           │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 5: ObPhyPlan (物理计划) + Executor                         │
│  - 25+ 种 physical operator                                     │
│  - 执行算子 (参见 #41-#43)                                      │
│  - 物理 plan monitor                                             │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. ObOptimizer 主类

### 2.1 类骨架（实读自 `ob_optimizer.h`）

```cpp
// src/sql/optimizer/ob_optimizer.h
namespace oceanbase {
namespace sql {

class ObDMLStmt;
class ObSelectStmt;
class ObDelUpdStmt;
class ObLogPlan;
class ObOptimizerContext;
class ObRawExpr;
class ObLogicalOperator;
class ObColumnRefRawExpr;

enum TraverseOp {
  ALLOC_EXPR = 0,           // 表达式分配（top-down + bottom-up）
  PROJECT_PRUNING,         // project pruning（移除不必要列）
  // ... 其他遍历操作
};

class ObOptimizer {
public:
  // 主入口
  int optimize(const ObDMLStmt &stmt, ObOptimizerContext &ctx);

  // logical plan → physical plan
  int generate_physical_plan(ObLogPlan &log_plan);

  // 表达式分配
  int alloc_expr(ObLogicalOperator &op, TraverseOp op);
};
}
}
```

### 2.2 关键设计

**TraverseOp 枚举** —— 优化器遍历计划树时的操作类型：
- `ALLOC_EXPR` —— 表达式分配（top-down 确定需求，bottom-up 产出能力）
- `PROJECT_PRUNING` —— project pruning（移除不必要列）

**Top-Down + Bottom-Up 双过程**：
- Top-Down：每个 operator 把需要的 expression 放入 request list → 传给子 operator
- 到达 leaf operator（表扫描）→ 产出所有 column item
- Bottom-Up：每个 operator 检查能产出哪些未产出的 expression
- 最后在 root operator 检查所有需求是否都产出

---

## 3. ObLogPlan / ObPhyPlan —— 逻辑 / 物理计划

### 3.1 ObLogPlan 详解

25+ 种 log plan 类（参见 `src/sql/optimizer/`）：

| Plan 类 | 用途 |
|--------|------|
| `ObSelectLogPlan` | SELECT |
| `ObInsertLogPlan` | INSERT |
| `ObUpdateLogPlan` | UPDATE |
| `ObDeleteLogPlan` | DELETE |
| `ObDelUpdLogPlan` | DELETE/UPDATE |
| `ObInsertAllLogPlan` | INSERT ALL |
| `ObExplainLogPlan` | EXPLAIN |
| `ObHelpLogPlan` | HELP |
| ... 17+ 其他 | ... |

### 3.2 ObPhyPlan 详解

参见 #41-#43：
- physical operator tree
- ObTableScan / ObIndexScan / ObNestedLoopJoin / ObHashJoin / ObMergeJoin / ObSort / ObWindow 等
- ObExecContext 携带执行状态

### 3.3 Logical → Physical 转化

```
ObLogPlan (logical operator tree)
    │
    ▼
ObOptimizer::generate_physical_plan
    │
    ├─ 1. log operator → physical operator
    │   - ObSelectLogPlan → ObPhyPlan + ObTableScanOperator 等
    │
    ├─ 2. 优化（参见 §4 / §5 / §6）
    │
    └─ 3. output ObPhyPlan
```

---

## 4. ObJoinOrder —— 连接顺序优化

### 4.1 类骨架

```cpp
// src/sql/optimizer/ob_join_order.{h,cpp}
class ObJoinOrder {
public:
  // 计算最优连接顺序
  int compute_optimal_order(ObLogPlan &log_plan,
                            ObJoinOrderInfo &best_order);

  // 枚举所有 join 顺序
  int enumerate_orders();

  // 评估每个顺序的 cost
  int evaluate_cost(ObJoinOrderInfo &order);

  // 剪枝（剪掉明显差的顺序）
  int prune();
};
```

### 4.2 连接顺序优化算法

```
N 张表连接 → N! 种顺序
    │
    ├─ 1. 动态规划（DP）
    │   - 对每对相邻表计算 cost
    │   - 选择 cost 最小的合并
    │
    ├─ 2. 启发式剪枝
    │   - Greedy join ordering（贪心）
    │   - 避免笛卡尔积
    │
    └─ 3. 选择最优
```

### 4.3 ObJoinOrderEnum

```cpp
// src/sql/optimizer/ob_join_order_enum.{h,cpp}
class ObJoinOrderEnum {
  // 枚举所有可能的 join order
  // 配合 cost model 评估
  // 选择 cost 最小的
};
```

---

## 5. ObAccessPathEstimation —— 访问路径代价估算

### 5.1 类骨架

```cpp
// src/sql/optimizer/ob_access_path_estimation.{h,cpp}
class ObAccessPathEstimation {
public:
  // 估算全表扫描 cost
  int estimate_table_scan(ObLogPlan &plan, ObCostInfo &cost);

  // 估算索引扫描 cost
  int estimate_index_scan(ObLogPlan &plan, ObIndexPath &path, ObCostInfo &cost);

  // 估算 hash join cost
  int estimate_hash_join(ObLogPlan &plan, ObJoinPath &path, ObCostInfo &cost);

  // 估算 nested loop join cost
  int estimate_nl_join(ObLogPlan &plan, ObJoinPath &path, ObCostInfo &cost);

  // 估算 merge join cost
  int estimate_merge_join(ObLogPlan &plan, ObJoinPath &path, ObCostInfo &cost);
};
```

### 5.2 Cost 计算公式

```
Total Cost = I/O Cost + CPU Cost + Network Cost
         = pages * 1.0 + tuples * 0.01 + ...

其中:
  I/O Cost = sequential_io * pages + random_io * pages
  CPU Cost = tuple_process_cost * tuples
```

### 5.3 代价模型参数

```cpp
// (推测, server config)
DEF_DOUBLE(seq_io_cost, 1.0, "sequential I/O cost");
DEF_DOUBLE(rand_io_cost, 4.0, "random I/O cost");
DEF_DOUBLE(cpu_tuple_cost, 0.01, "CPU tuple cost");
DEF_DOUBLE(mem_cmp_cost, 0.02, "memory comparison cost");
```

---

## 6. 谓词下推 / Range 优化

### 6.1 ObPredicateDeduce

```cpp
// src/sql/rewrite/ob_predicate_deduce.{h,cpp}
class ObPredicateDeduce {
public:
  // 从 SQL 谓词推导可下推的等值 / range 条件
  int deduce_predicate(const ObRawExpr &where_clause,
                       ObRangeConds &range_conds,
                       ObEquiConds &equi_conds);

  // 推导 select list 中的可计算列
  int deduce_select_list(const ObSelectStmt &stmt);
};
```

### 6.2 谓词下推的价值

```
SELECT * FROM t WHERE id = 100 AND name = 'foo';
    │
    ▼
优化器分析：
    - id = 100 → 可下推到 PK 索引（range scan）
    - name = 'foo' → 可下推到 idx_name（二级索引）
    │
    ▼
优化结果：
    - 选最优索引（PK 或 idx_name）
    - 谓词下推到 table scan
    - 不返回所有 row 后再 filter
```

### 6.3 ObQueryRange

```cpp
// src/sql/rewrite/ob_query_range.{h,cpp}
class ObQueryRange {
  // Query Range 优化
  // - 把 WHERE 条件转化为 range scan 的范围
  // - 支持等值 / 范围 / IN / BETWEEN / LIKE 前缀
};
```

### 6.4 ObExprRangeConverter

```cpp
// src/sql/rewrite/ob_expr_range_converter.{h,cpp}
class ObExprRangeConverter {
  // 把 ObRawExpr 转换为 range 表达式
  // 支持复杂表达式（如 col + 1 BETWEEN 1 AND 100）
};
```

### 6.5 ObEqualAnalysis

```cpp
// src/sql/rewrite/ob_equal_analysis.{h,cpp}
class ObEqualAnalysis {
  // 等值分析
  // - 推导传递闭包（a=b 且 b=c → a=c）
  // - 推导可下推的等值条件
  // - 推导 join 的等值条件
};
```

---

## 7. ObOptimizerStatistics —— CBO 统计信息

### 7.1 类骨架

```cpp
// src/share/stat/ob_stats_estimator.{h,cpp}
class ObStatsEstimator {
public:
  // 估算表的行数
  int estimate_row_count(const share::ObTableId &table_id,
                         int64_t &row_count);

  // 估算列 distinct count
  int estimate_distinct_count(const share::ObTableId &table_id,
                               const share::ObColumnId &col_id,
                               int64_t &distinct_count);

  // 估算列 min/max
  int estimate_min_max(const share::ObTableId &table_id,
                       const share::ObColumnId &col_id,
                       ObObj &min_val, ObObj &max_val);

  // 估算列 null count
  int estimate_null_count(const share::ObTableId &table_id,
                          const share::ObColumnId &col_id,
                          int64_t &null_count);
};
```

### 7.2 统计信息收集

```cpp
// src/share/stat/ob_opt_stat_manager.{h,cpp}
class ObOptStatManager {
  // OPT_STAT_MANAGER
  // 协调各 observer 的统计信息收集
  // 调度 ANALYZE TABLE 任务
};
```

### 7.3 统计信息虚拟表

```sql
-- 查看统计信息
SELECT * FROM oceanbase.DBA_TAB_STATISTICS;
SELECT * FROM oceanbase.DBA_TAB_COL_STATISTICS;
SELECT * FROM oceanbase.DBA_TAB_HISTOGRAMS;
```

### 7.4 ObDbmsStatsPreferences

```cpp
// src/share/stat/ob_dbms_stats_preferences.h
class ObDbmsStatsPreferences {
  // DBMS_STATS 偏好设置
  // - 自动收集策略
  // - 采样率
  // - 直方图桶数
  // - 失效时间
};
```

### 7.5 ObOptStatGatherStat

```cpp
// src/share/stat/ob_opt_stat_gather_stat.{h,cpp}
class ObOptStatGatherStat {
  // 收集统计信息
  // - 触发 ANALYZE TABLE
  // - 调用 stats estimator
  // - 写回内部表
};
```

### 7.6 ObOptStatSqlService

```cpp
// src/share/stat/ob_opt_stat_sql_service.{h,cpp}
class ObOptStatSqlService {
  // 统计信息 SQL 服务
  // 处理 DBMS_STATS 包级调用
};
```

### 7.7 ObOptStatMonitorManager

```cpp
// src/share/stat/ob_opt_stat_monitor_manager.{h,cpp}
class ObOptStatMonitorManager {
  // 监控统计信息
  // - 过期检测
  // - 自动 ANALYZE
  // - 异常告警
};
```

### 7.8 ObOptStatService

```cpp
// src/share/stat/ob_opt_stat_service.{h,cpp}
class ObOptStatService {
  // 统计信息 service
  // - 高层 API
  // - DBMS_STATS 包
  // - ANALYZE TABLE
};
```

---

## 8. 改写规则（ObTransformRule）

### 8.1 类骨架

```cpp
// src/sql/rewrite/ob_transform_rule.{h,cpp}
class ObTransformRule {
public:
  // 改写单条规则
  int transform(ObLogPlan &log_plan);

  // 应用所有改写规则
  int apply_all_rules(ObLogPlan &log_plan);
};
```

### 8.2 改写规则类型

| 规则 | 目的 | 例子 |
|------|------|------|
| **子查询展开** | 消除子查询（IN / EXISTS） | `WHERE id IN (SELECT id FROM t)` → `WHERE EXISTS (SELECT ...)` |
| **谓词下推** | 推 filter 到 join 之前 | 见 #6 |
| **常量折叠** | 简化常量表达式 | `1 + 1` → `2` |
| **Outer Join 转 Inner Join** | 简化 join | `WHERE a.id = b.id` 强制转 inner |
| **IN 转 Semi Join** | 优化 IN | `WHERE id IN (1,2,3)` → semi join |
| **Exists 转 Semi Join** | 优化 EXISTS | 同上 |
| **Group By 下推** | 提前聚合 | 见 #41 |
| **Distinct 转 Group By** | 优化 DISTINCT | `SELECT DISTINCT col` → `SELECT col GROUP BY col` |
| **Join Reorder** | 优化 join 顺序 | 见 #4 |

### 8.3 改写实现

```cpp
// (推测, src/sql/rewrite/ob_transform_rule.cpp)
// 改写规则按顺序应用
int ObTransformRule::apply_all_rules(ObLogPlan &log_plan) {
  // 1. 子查询展开
  transform_subquery(log_plan);
  // 2. 谓词下推
  transform_predicate_pushdown(log_plan);
  // 3. 常量折叠
  transform_constant_folding(log_plan);
  // 4. Outer Join → Inner Join
  transform_outer_to_inner(log_plan);
  // 5. IN / Exists → Semi Join
  transform_semi_join(log_plan);
  // 6. Distinct → Group By
  transform_distinct(log_plan);
  // 7. Group By 下推
  transform_groupby_pushdown(log_plan);
  // ... 几十种改写
  return 0;
}
```

---

## 9. 关键监控与统计类

```bash
src/sql/monitor/
├── ob_phy_plan_monitor_info.h    # physical plan monitor info
├── ob_exec_stat_collector.h      # exec stat collector
├── ob_sql_plan.h                  # SQL plan
└── ob_phy_plan_exec_info.h      # physical plan exec info

src/observer/virtual_table/
└── ob_virtual_sql_monitor.h      # virtual SQL monitor

src/sql/optimizer/ob_sharding_info.h     # sharding info

src/sql/ob_sql.h                           # OB SQL 主类
```

---

## 10. 与其他文章的关系

### 10.1 与 #17 Query Optimizer

#17 是早期分析优化器概览（30KB+）。本篇是 #17 的 **深化**：
- #17 聚焦优化器架构
- 本文深入 `ObOptimizer` / `ObLogPlan` / `ObPhyPlan` / `ObJoinOrder` / `ObAccessPathEstimation` / `ObPredicateDeduce` / `ObOptimizerStatistics` / `ObTransformRule` 各自的实现

### 10.2 与 #18 Index Design

优化器选择最优索引（参见 #18）。本篇是 **优化器** 视角，#18 是 **索引** 视角。

### 10.3 与 #22 Plan Cache

Plan cache 缓存已生成的 plan（参见 #22）。优化器生成 plan → plan cache 缓存 → 后续查询复用。

### 10.4 与 #41-#43 Join / Sort / Window Operators

优化器生成 plan → physical operator（参见 #41-#43）→ Executor 执行。

### 10.5 与 #94 Index System

优化器选择索引（参见 #94 §4 ObIndexSSTableEstimator / ObIndexBuilder / ObAccessPathEstimation）。

### 10.6 与 #90 SSTable

访问路径的物理载体（参见 #90）：
- ObAccessPathEstimation 选 table scan vs index scan
- SSTable 是 table scan 的物理目标

---

## 11. 总结

### 11.1 查询优化器在 OB 体系中的定位

优化器是 **OB SQL → 执行计划的核心**：
- 5 层架构（Parser → Resolver → LogPlan → Optimizer → PhyPlan）
- 184 + 107 = 291 文件
- CBO（基于代价）+ Rule（基于规则）混合优化
- 完整统计信息 + 改写规则

### 11.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| 优化器主类 | `ObOptimizer` + `TraverseOp`（ALLOC_EXPR + PROJECT_PRUNING） |
| 逻辑计划 | `ObLogPlan`（25+ 种：select / insert / update / delete / join） |
| 物理计划 | `ObPhyPlan`（25+ 种 physical operator） |
| 连接顺序 | `ObJoinOrder` + `ObJoinOrderEnum`（DP + 启发式剪枝） |
| 访问路径估算 | `ObAccessPathEstimation`（I/O Cost + CPU Cost） |
| 谓词下推 | `ObPredicateDeduce` + `ObQueryRange` + `ObExprRangeConverter` + `ObEqualAnalysis` |
| 改写规则 | `ObTransformRule`（子查询展开 + 谓词下推 + 常量折叠 + outer → inner + IN → semi 等） |
| 统计信息 | `ObStatsEstimator` + `ObOptStatManager` + `ObDbmsStatsPreferences` |
| 动态采样 | `ObDynamicSampling` |
| 冲突检测 | `ObConflictDetector` |
| 索引信息缓存 | `ObIndexInfoCache` |

### 11.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/sql/optimizer/` (184 文件) | 优化器主目录 |
| `src/sql/optimizer/ob_optimizer.h` | 优化器主类（含 `TraverseOp` enum） |
| `src/sql/optimizer/ob_access_path_estimation.{h,cpp}` | 访问路径估算 |
| `src/sql/optimizer/ob_conflict_detector.{h,cpp}` | 冲突检测 |
| `src/sql/optimizer/ob_del_upd_log_plan.{h,cpp}` | delete/update log plan |
| `src/sql/optimizer/ob_delete_log_plan.{h,cpp}` | delete log plan |
| `src/sql/optimizer/ob_direct_load_optimizer_ctx.{h,cpp}` | direct load ctx |
| `src/sql/optimizer/ob_dynamic_sampling.{h,cpp}` | 动态采样 |
| `src/sql/optimizer/ob_explain_log_plan.{h,cpp}` | explain log plan |
| `src/sql/optimizer/ob_explain_note.h` | explain note |
| `src/sql/optimizer/ob_fd_item.{h,cpp}` | functional dependency |
| `src/sql/optimizer/ob_help_log_plan.{h,cpp}` | help log plan |
| `src/sql/optimizer/ob_index_info_cache.{h,cpp}` | index info cache |
| `src/sql/optimizer/ob_insert_all_log_plan.{h,cpp}` | insert all log plan |
| `src/sql/optimizer/ob_insert_log_plan.{h,cpp}` | insert log plan |
| `src/sql/optimizer/ob_join_order.{h,cpp}` | 连接顺序优化 |
| `src/sql/optimizer/ob_join_order_enum.{h,cpp}` | 连接顺序 enum |
| `src/sql/rewrite/` (107 文件) | 改写规则 |
| `src/sql/rewrite/ob_transform_rule.{h,cpp}` | 改写规则主类 |
| `src/sql/rewrite/ob_equal_analysis.{h,cpp}` | 等值分析 |
| `src/sql/rewrite/ob_expand_aggregate_utils.{h,cpp}` | expand aggregate |
| `src/sql/rewrite/ob_expr_range_converter.{h,cpp}` | expr range |
| `src/sql/rewrite/ob_key_part.{h,cpp}` | key part |
| `src/sql/rewrite/ob_predicate_deduce.{h,cpp}` | 谓词推导 |
| `src/sql/rewrite/ob_query_range.{h,cpp}` | query range |
| `src/sql/rewrite/ob_query_range_define.{h,cpp}` | query range define |
| `src/sql/rewrite/ob_query_range_provider.h` | query range provider |
| `src/sql/rewrite/ob_range_generator.{h,cpp}` | range generator |
| `src/sql/rewrite/ob_range_graph_generator.{h,cpp}` | range graph |
| `src/share/stat/ob_stat_define.{h,cpp}` | stat define |
| `src/share/stat/ob_stats_estimator.{h,cpp}` | stats estimator |
| `src/share/stat/ob_stat_item.{h,cpp}` | stat item |
| `src/share/stat/ob_opt_stat_manager.{h,cpp}` | OPT_STAT manager |
| `src/share/stat/ob_opt_stat_gather_stat.{h,cpp}` | gather stat |
| `src/share/stat/ob_opt_stat_sql_service.{h,cpp}` | SQL service |
| `src/share/stat/ob_opt_stat_monitor_manager.{h,cpp}` | monitor |
| `src/share/stat/ob_opt_stat_service.{h,cpp}` | service |
| `src/share/stat/ob_dbms_stats_preferences.h` | DBMS_STATS 偏好 |
| `src/sql/monitor/ob_phy_plan_monitor_info.h` | physical plan monitor |
| `src/sql/monitor/ob_exec_stat_collector.h` | exec stat collector |
| `src/sql/monitor/ob_sql_plan.h` | SQL plan |
| `src/sql/monitor/ob_phy_plan_exec_info.h` | physical plan exec info |
| `src/observer/virtual_table/ob_virtual_sql_monitor.h` | virtual SQL monitor |
| `src/sql/optimizer/ob_sharding_info.h` | sharding info |
| `src/sql/ob_sql.h` | OB SQL 主类 |

### 11.4 改写规则类型

| 规则 | 目的 |
|------|------|
| 子查询展开 | 消除子查询（IN / EXISTS） |
| 谓词下推 | 推 filter 到 join 之前 |
| 常量折叠 | 简化常量表达式 |
| Outer Join → Inner Join | 简化 join |
| IN → Semi Join | 优化 IN |
| Exists → Semi Join | 优化 EXISTS |
| Group By 下推 | 提前聚合 |
| Distinct → Group By | 优化 DISTINCT |
| Join Reorder | 优化 join 顺序 |

### 11.5 5 层架构

| 层级 | 元素 | 角色 |
|------|------|------|
| L1 | SQL 解析 | Parser → ParseNode |
| L2 | Resolver | 名称 + 类型解析 + Schema Guard |
| L3 | ObLogPlan | 25+ 种 logical plan + 改写 |
| L4 | ObOptimizer | CBO + 连接顺序 + 访问路径估算 |
| L5 | ObPhyPlan | 25+ 种 physical operator + Executor |

### 11.6 推荐下一步

按之前梳理的顺序，下一篇应该是 **#96 Plan Cache / 计划缓存详解**（深化 #22）：

OB Plan Cache —— 计划缓存的存储 / 失效 / 跨 observer 同步 / plan_shape 标准化。源码入口：`src/sql/plan_cache/`（推测）+ `src/sql/monitor/ob_phy_plan_monitor_info.h` + `src/sql/monitor/ob_sql_plan.h`。

适用场景：plan cache 调优 / 性能分析 / SQL 优化。

整吗？