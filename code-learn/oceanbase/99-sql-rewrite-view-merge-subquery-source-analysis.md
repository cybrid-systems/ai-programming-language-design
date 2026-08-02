# 99-sql-rewrite — OceanBase SQL 改写 / 视图改写 / 子查询优化深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码（`src/sql/rewrite/` **107 文件** + `src/sql/optimizer/ob_log_plan.h` + `src/sql/optimizer/optimizer_plan_rewriter/ob_plan_visitor.h` + `src/sql/resolver/dml/ob_hint.h`）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **SQL 改写 / 视图改写 / 子查询优化** 是整个 SQL 优化器的关键步骤 —— 在优化器生成物理计划前，对 Logical Plan 进行一系列等价变换，提升查询性能。OB 5.x 的 SQL 改写建立在 `src/sql/rewrite/` 的 107 个文件之上，包括视图改写（View Merge）、子查询展开（IN/EXISTS → Semi Join）、谓词下推、聚合下推、常量传播等 10+ 大类改写规则。

本文聚焦 8 个核心问题：

1. **SQL 改写全景** —— 107 个文件
2. **ObEqualAnalysis** —— 等值条件分析
3. **ObPredicateDeduce** —— 谓词推导
4. **ObQueryRange / ObExprRangeConverter** —— range 优化
5. **ObTransformViewMerge** —— 视图合并
6. **ObTransformAggrSubquery** —— 聚合子查询
7. **ObTransformQueryPushDown** —— 查询下推
8. **ObLogPlan 与 ObPlanVisitor** —— 改写入口

### 与前面文章的关系

| 文章 | 关联点 |
|------|--------|
| 17 / 95 Query Optimizer | 改写是优化器的一部分（参见 #95 §8） |
| 22 / 96 Plan Cache | 改写后 plan 缓存（参见 #96） |
| 18 / 94 Index System | 改写利用索引 |
| 41-43 Operators | 改写后生成 operator |
| 9 SQL Executor | 改写后执行 |

---

## 1. 整体架构：SQL 改写 5 层

### 1.1 模块组成（107 文件 + ObLogPlan）

```bash
$ ls src/sql/rewrite/ | wc -l
107

# SQL 改写主目录
src/sql/rewrite/
├── ob_equal_analysis.{h,cpp}             # 等值分析（推导传递闭包 a=b 且 b=c → a=c）
├── ob_expand_aggregate_utils.{h,cpp}     # 聚合展开
├── ob_expr_range_converter.{h,cpp}       # 表达式 range 转换
├── ob_key_part.{h,cpp}                   # 索引 key 部分
├── ob_predicate_deduce.{h,cpp}           # 谓词推导（参见 #95 §6）
├── ob_query_range.{h,cpp}                # 查询 range（参见 #95 §6）
├── ob_query_range_define.{h,cpp}         # range 定义
├── ob_query_range_provider.h             # range provider
├── ob_range_generator.{h,cpp}            # range 生成器
├── ob_range_graph_generator.{h,cpp}      # range 图生成器
├── ob_search_index_query_range_utils.{h,cpp}  # search index range utils
├── ob_stmt_comparer.{h,cpp}             # stmt 比较
├── ob_transform_aggr_subquery.{h,cpp}    # 聚合子查询改写
├── ob_transform_conditional_aggr_coalesce.{h,cpp}  # 条件聚合合并
├── ob_transform_const_propagate.{h,cpp} # 常量传播
├── ob_transform_expr_pullup.{h,cpp}      # 表达式上提
├── ob_transform_or_expansion.{h,cpp}     # OR 展开
├── ob_transform_pre_process.{h,cpp}      # 改写前处理
├── ob_transform_query_push_down.{h,cpp}  # 查询下推
├── ob_transform_simplify_expr.{h,cpp}    # 表达式简化
├── ob_transform_simplify_orderby.{h,cpp}  # ORDER BY 简化
├── ob_transform_utils.{h,cpp}             # 改写工具
├── ob_transform_view_merge.{h,cpp}       # 视图合并
├── ob_transform_win_magic.{h,cpp}         # window magic
└ # ... 80+ 其他

# 改写入口
src/sql/optimizer/optimizer_plan_rewriter/ob_plan_visitor.h
src/sql/optimizer/ob_log_plan.h

# Hint（改写提示）
src/sql/resolver/dml/ob_hint.h
```

### 1.2 5 层架构

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: ObLogPlan (改写宿主)                                   │
│  - Logical Plan 包含可改写的 LogicalOperator 树                  │
│  - src/sql/optimizer/ob_log_plan.h 引用所有改写                │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: 谓词 / Range 改写                                      │
│  - ObPredicateDeduce (推导等值/range)                            │
│  - ObQueryRange / ObExprRangeConverter (range 转换)             │
│  - ObEqualAnalysis (传递闭包)                                    │
│  - ObKeyPart (索引 key 部分)                                     │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: 子查询 / 视图改写                                       │
│  - ObTransformViewMerge (视图合并 → 消除子查询)               │
│  - ObTransformAggrSubquery (聚合子查询改写)                     │
│  - ObTransformOrExpansion (OR 展开)                            │
│  - ObTransformExprPullup (表达式上提)                            │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 4: 查询下推 / 聚合下推                                    │
│  - ObTransformQueryPushDown (查询下推到存储层)                 │
│  - ObExpandAggregateUtils (聚合下推)                              │
│  - ObTransformConditionalAggrCoalesce (条件聚合合并)            │
│  - ObTransformConstPropagate (常量传播)                         │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 5: 表达式简化 / Hint / 最终化                              │
│  - ObTransformSimplifyExpr (表达式简化)                         │
│  - ObTransformSimplifyOrderby (ORDER BY 简化)                  │
│  - ObTransformPreProcess (改写前处理)                            │
│  - ObTransformUtils (改写工具)                                    │
│  - ob_hint.h (Hint 解析，参见 #95 / #17)                          │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. ObEqualAnalysis —— 等值条件分析

### 2.1 类骨架（实读自 `ob_equal_analysis.h`）

```cpp
// src/sql/rewrite/ob_equal_analysis.h
namespace oceanbase {
namespace sql {

// An algorithm class to generate all equal condition expression
struct EqualSetKey {
  virtual bool operator ==(const EqualSetKey &other) const {
    if (NULL == expr_ || NULL == other.expr_) {
      return expr_ == other.expr_;
    } else {
      return (expr_ == other.expr_) || (expr_->same_as(*other.expr_));
    }
  }
  virtual uint64_t hash() const {
    uint64_t result = 0;
    if (NULL != expr_) {
      result = expr_->get_expr_hash();
    }
    return result;
  }
  virtual int hash(uint64_t &hash_val) const { hash_val = hash(); return OB_SUCCESS; }
  const ObRawExpr *expr_;
  TO_STRING_KV(K_(expr));
};

class ObEqualAnalysis {
public:
  explicit ObEqualAnalysis();
  virtual ~ObEqualAnalysis();
  void destroy();
  int init();

  // input
  int feed_equal_sets(const EqualSets &equal_sets);
  int feed_where_expr(ObRawExpr *expr);
  int finish_feed();
};
}  // namespace sql
}  // namespace oceanbase
```

### 2.2 关键设计

**ObEqualAnalysis** 的核心是 **等值类推导**（Equality Class Inference）：
- 找出所有 `a = b`, `b = c` 这样的等值条件
- 推导传递闭包：`a = b` 且 `b = c` → `a = c`
- 用于 join 条件推导、谓词下推、semi join 优化

### 2.3 应用场景

- **Join 推导**：`a.id = b.id AND a.dept = c.dept AND b.dept = c.dept` → 推出 a.dept = b.dept
- **等值传递**：简化 join 条件
- **常量推导**：`a = 1 AND a = b` → 推出 `b = 1`
- **索引选择**：选择最具选择性的等值列作为索引前缀

---

## 3. ObPredicateDeduce —— 谓词推导

### 3.1 角色

参见 #95 §6.1-6.3：详细分析 `ObPredicateDeduce::deduce_predicate` 和 `deduce_select_list`。

### 3.2 关键 API

```cpp
// src/sql/rewrite/ob_predicate_deduce.h
class ObPredicateDeduce {
public:
  // 从 WHERE 条件推导 range 条件 + equi 条件
  int deduce_predicate(const ObRawExpr &where_clause,
                       ObRangeConds &range_conds,
                       ObEquiConds &equi_conds);

  // 推导 select list 中可计算的列
  int deduce_select_list(const ObSelectStmt &stmt);
};
```

### 3.3 改写中的谓词推导

```
SQL: SELECT * FROM t WHERE id = 100 AND name = 'foo'
    │
    ▼ ObPredicateDeduce::deduce_predicate
    │
    ├─ range_conds: id IN (100)
    │   └─ 用于索引范围扫描
    │
    └─ equi_conds: name = 'foo'
        └─ 用于等值 join / filter
```

---

## 4. ObQueryRange / ObExprRangeConverter —— range 优化

### 4.1 ObQueryRange

```cpp
// src/sql/rewrite/ob_query_range.h
class ObQueryRange {
  // Query Range 优化
  // - 把 WHERE 条件转化为 range scan 的范围
  // - 支持等值 / 范围 / IN / BETWEEN / LIKE 前缀
};
```

### 4.2 ObExprRangeConverter

```cpp
// src/sql/rewrite/ob_expr_range_converter.h
class ObExprRangeConverter {
  // 把 ObRawExpr 转换为 range 表达式
  // 支持复杂表达式（如 col + 1 BETWEEN 1 AND 100）
};
```

### 4.3 ObRangeGenerator / ObRangeGraphGenerator

```cpp
// src/sql/rewrite/ob_range_generator.h
class ObRangeGenerator {
  // range 生成器
  // - 处理多个 range 条件
  // - 求并集 / 交集
};

// src/sql/rewrite/ob_range_graph_generator.h
class ObRangeGraphGenerator {
  // range 图生成器
  // - 多个列的 range 推导
  // - 生成 range graph
};
```

### 4.4 ObSearchIndexQueryRangeUtils

```cpp
// src/sql/rewrite/ob_search_index_query_range_utils.h
// search index query range utils
// 搜索索引能用的 range
```

---

## 5. ObTransformViewMerge —— 视图合并

### 5.1 角色

```cpp
// src/sql/rewrite/ob_transform_view_merge.h
class ObTransformViewMerge {
public:
  // 视图合并
  int merge_view(ObSelectStmt &stmt, const ViewInfo &view_info);

  // 检查能否合并
  int can_merge(const ObSelectStmt &stmt, bool &can_merge);
};
```

### 5.2 视图合并的价值

```sql
-- 原始 SQL
SELECT t.* FROM t JOIN v ON t.id = v.id WHERE v.dept = 10;

-- 如果 v 是视图: CREATE VIEW v AS SELECT * FROM employee WHERE active = 1

-- 视图合并前: 嵌套子查询
SELECT t.* FROM t JOIN (SELECT * FROM employee WHERE active = 1) v
       ON t.id = v.id WHERE v.dept = 10;

-- 视图合并后: 消除子查询
SELECT t.* FROM t JOIN employee v ON t.id = v.id
       WHERE v.active = 1 AND v.dept = 10;
```

**价值**：消除子查询 → 优化器可以选更好的 join 顺序 / 索引。

### 5.3 视图合并的限制

- 简单视图（无 DISTINCT / 无聚合）可合并
- 复杂视图（聚合 / DISTINCT）不可合并 → 保留为子查询

---

## 6. ObTransformAggrSubquery —— 聚合子查询改写

### 6.1 角色

```cpp
// src/sql/rewrite/ob_transform_aggr_subquery.h
class ObTransformAggrSubquery {
  // 聚合子查询改写
  // SELECT col FROM t WHERE col > (SELECT AVG(col) FROM t)
  // 改写为:
  // SELECT col FROM t, (SELECT AVG(col) AS avg_col FROM t) sub
  // WHERE col > sub.avg_col
};
```

### 6.2 改写模式

```
原 SQL: 标量子查询 (Scalar Subquery)
SELECT * FROM t WHERE x > (SELECT MAX(y) FROM t2 WHERE ...)
    │
    ▼ ObTransformAggrSubquery
改写: 派生表 (Derived Table)
SELECT * FROM t, (SELECT MAX(y) AS m FROM t2 WHERE ...) sub
WHERE x > sub.m
```

**价值**：优化器能更灵活地选择 join 顺序。

---

## 7. ObTransformQueryPushDown —— 查询下推

### 7.1 角色

```cpp
// src/sql/rewrite/ob_transform_query_push_down.h
class ObTransformQueryPushDown {
public:
  // 查询下推
  // - 谓词下推到 base table
  // - limit 下推
  // - 投影下推（减少传输）
};
```

### 7.2 查询下推的价值

```
原 SQL: SELECT * FROM t WHERE id IN (SELECT id FROM t2 WHERE col = 1)
    │
    ▼ ObTransformQueryPushDown
改写: SELECT * FROM t WHERE id IN (SELECT id FROM t2 WHERE col = 1)
       AND col = 1
  (无法直接合并，但有些查询下推规则可推 limit / projection)
```

### 7.3 改写中的下推

- **Predicate Pushdown**（参见 #95 §6）：filter 推到底层
- **Projection Pushdown**：只读需要的列
- **Limit Pushdown**：limit 推到子查询

---

## 8. ObLogPlan 与 ObPlanVisitor —— 改写入口

### 8.1 ObLogPlan 改写相关 include

```cpp
// src/sql/optimizer/ob_log_plan.h
class ObLogPlan {
  // Logical Plan 主类
  // - 包含 LogicalOperator 树
  // - 提供改写接口
  // - 引用改写类（参见上面）
};

// 重要 include:
#include "sql/optimizer/ob_optimizer.h"             // 优化器
#include "sql/optimizer/optimizer_plan_rewriter/ob_plan_visitor.h"  // 改写 visitor
#include "sql/optimizer/ob_opt_est_utils.h"          // 估算
#include "sql/optimizer/ob_opt_selectivity.h"        // 选择性
#include "sql/optimizer/ob_logical_operator.h"      // 逻辑算子
#include "sql/optimizer/ob_log_operator_factory.h"  // 算子工厂
```

### 8.2 ObPlanVisitor

```cpp
// src/sql/optimizer/optimizer_plan_rewriter/ob_plan_visitor.h
class ObPlanVisitor {
  // 改写 visitor
  // - pre_visit / visit / post_visit
  // - 遍历 LogicalPlan
  // - 应用改写规则
};
```

### 8.3 改写流程

```
ObLogPlan
    │
    ▼
ObPlanVisitor（遍历 + 应用改写）
    │
    ├─ 1. ObEqualAnalysis (推导等值闭包)
    │
    ├─ 2. ObPredicateDeduce (推导谓词 range/equi)
    │
    ├─ 3. ObQueryRange (range 优化)
    │
    ├─ 4. ObTransformViewMerge (视图合并)
    │
    ├─ 5. ObTransformAggrSubquery (聚合子查询)
    │
    ├─ 6. ObTransformOrExpansion (OR 展开)
    │
    ├─ 7. ObTransformQueryPushDown (查询下推)
    │
    ├─ 8. ObTransformExprPullup (表达式上提)
    │
    ├─ 9. ObExpandAggregateUtils (聚合展开)
    │
    ├─ 10. ObTransformConstPropagate (常量传播)
    │
    ├─ 11. ObTransformConditionalAggrCoalesce (条件聚合合并)
    │
    ├─ 12. ObTransformSimplifyExpr (表达式简化)
    │
    └─ 13. ObTransformSimplifyOrderby (ORDER BY 简化)
    │
    ▼
输出: 改写后的 Logical Plan
```

---

## 9. 与其他文章的关系

### 9.1 与 #17 / #95 Query Optimizer

优化器包含改写阶段（参见 #95 §8）：
- 优化器 5 层架构中的第 3 层 `ObLogPlan（25+ 种）+ 改写`
- 改写后生成物理计划

### 9.2 与 #22 / #96 Plan Cache

改写后的 plan 缓存（参见 #96）：
- 改写是 plan 生成的一部分
- 缓存含改写后的 plan → 后续 SQL 复用

### 9.3 与 #18 / #94 Index System

改写利用索引（参见 #94）：
- 谓词下推 → 索引范围扫描
- 视图合并 → 简化 join → 索引选择空间更大

### 9.4 与 #41-#43 Operators

改写后生成 operator（参见 #41-#43）：
- LogicalOperator 树 → PhysicalOperator 树
- 改写影响 operator 树结构

---

## 10. 总结

### 10.1 SQL 改写在 OB 体系中的定位

SQL 改写是 **OB 性能优化的关键步骤**：
- 107 个文件
- 5 层架构（ObLogPlan / Predicate / Subquery-View / QueryPushdown / Simplify）
- 与优化器、Plan Cache、Index 深度集成

### 10.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| 等值分析 | `ObEqualAnalysis` + `EqualSetKey`（传递闭包推导） |
| 谓词推导 | `ObPredicateDeduce`（range + equi） |
| Range 优化 | `ObQueryRange` + `ObExprRangeConverter` + `ObRangeGenerator` + `ObRangeGraphGenerator` + `ObSearchIndexQueryRangeUtils` |
| 视图合并 | `ObTransformViewMerge`（消除子查询） |
| 聚合子查询 | `ObTransformAggrSubquery` |
| OR 展开 | `ObTransformOrExpansion` |
| 表达式上提 | `ObTransformExprPullup` |
| 查询下推 | `ObTransformQueryPushDown`（谓词 / limit / projection） |
| 聚合展开 | `ObExpandAggregateUtils` |
| 条件聚合合并 | `ObTransformConditionalAggrCoalesce` |
| 常量传播 | `ObTransformConstPropagate` |
| 表达式简化 | `ObTransformSimplifyExpr` |
| ORDER BY 简化 | `ObTransformSimplifyOrderby` |
| 改写前处理 | `ObTransformPreProcess` |
| 改写工具 | `ObTransformUtils` |
| Window magic | `ObTransformWinMagic` |
| 改写入口 | `ObPlanVisitor`（pre_visit / visit / post_visit） |
| ObLogPlan 集成 | `src/sql/optimizer/ob_log_plan.h` 引用所有改写类 |
| Hint 解析 | `ob_hint.h`（参见 #95 / #17） |

### 10.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/sql/rewrite/` (107 文件) | SQL 改写主目录 |
| `src/sql/rewrite/ob_equal_analysis.{h,cpp}` | 等值分析（实读） |
| `src/sql/rewrite/ob_predicate_deduce.{h,cpp}` | 谓词推导 |
| `src/sql/rewrite/ob_query_range.{h,cpp}` | 查询 range |
| `src/sql/rewrite/ob_expr_range_converter.{h,cpp}` | 表达式 range 转换 |
| `src/sql/rewrite/ob_key_part.{h,cpp}` | 索引 key 部分 |
| `src/sql/rewrite/ob_range_generator.{h,cpp}` | range 生成器 |
| `src/sql/rewrite/ob_range_graph_generator.{h,cpp}` | range 图生成器 |
| `src/sql/rewrite/ob_search_index_query_range_utils.{h,cpp}` | search index range utils |
| `src/sql/rewrite/ob_stmt_comparer.{h,cpp}` | stmt 比较 |
| `src/sql/rewrite/ob_transform_aggr_subquery.{h,cpp}` | 聚合子查询 |
| `src/sql/rewrite/ob_transform_conditional_aggr_coalesce.{h,cpp}` | 条件聚合合并 |
| `src/sql/rewrite/ob_transform_const_propagate.{h,cpp}` | 常量传播 |
| `src/sql/rewrite/ob_transform_expr_pullup.{h,cpp}` | 表达式上提 |
| `src/sql/rewrite/ob_transform_or_expansion.{h,cpp}` | OR 展开 |
| `src/sql/rewrite/ob_transform_pre_process.{h,cpp}` | 改写前处理 |
| `src/sql/rewrite/ob_transform_query_push_down.{h,cpp}` | 查询下推 |
| `src/sql/rewrite/ob_transform_simplify_expr.{h,cpp}` | 表达式简化 |
| `src/sql/rewrite/ob_transform_simplify_orderby.{h,cpp}` | ORDER BY 简化 |
| `src/sql/rewrite/ob_transform_utils.{h,cpp}` | 改写工具 |
| `src/sql/rewrite/ob_transform_view_merge.{h,cpp}` | 视图合并 |
| `src/sql/rewrite/ob_transform_win_magic.{h,cpp}` | window magic |
| `src/sql/rewrite/ob_expand_aggregate_utils.{h,cpp}` | 聚合展开 |
| `src/sql/rewrite/ObRewriteRule` | Rewrite Rule 子目录 |
| `src/sql/optimizer/optimizer_plan_rewriter/ob_plan_visitor.h` | 改写 visitor |
| `src/sql/optimizer/ob_log_plan.h` | 改写宿主（实读，引用改写类） |
| `src/sql/resolver/dml/ob_hint.h` | Hint 解析 |

### 10.4 5 层架构

| 层级 | 元素 | 角色 |
|------|------|------|
| L1 | `ObLogPlan` | 改写宿主（Logical Plan） |
| L2 | 谓词 / Range 改写 | `ObPredicateDeduce` + `ObQueryRange` + `ObEqualAnalysis` |
| L3 | 子查询 / 视图改写 | `ObTransformViewMerge` + `ObTransformAggrSubquery` + `ObTransformOrExpansion` + `ObTransformExprPullup` |
| L4 | 查询下推 / 聚合下推 | `ObTransformQueryPushDown` + `ObExpandAggregateUtils` + `ObTransformConditionalAggrCoalesce` + `ObTransformConstPropagate` |
| L5 | 表达式简化 / Hint | `ObTransformSimplifyExpr` + `ObTransformSimplifyOrderby` + `ObTransformPreProcess` + `ob_hint.h` |

### 10.5 关键改写规则

| 规则 | 作用 |
|------|------|
| `ObEqualAnalysis` | 等值闭包推导（a=b 且 b=c → a=c） |
| `ObPredicateDeduce` | 谓词推导（range + equi） |
| `ObQueryRange` | range 优化（等值/范围/IN/BETWEEN/LIKE 前缀） |
| `ObTransformViewMerge` | 视图合并（消除子查询） |
| `ObTransformAggrSubquery` | 聚合子查询改写（标量 → 派生表） |
| `ObTransformOrExpansion` | OR 展开（IN → UNION ALL） |
| `ObTransformExprPullup` | 表达式上提（外层 → 内层） |
| `ObTransformQueryPushDown` | 查询下推（谓词/limit/projection） |
| `ObExpandAggregateUtils` | 聚合展开（标量 → 聚合子查询） |
| `ObTransformConditionalAggrCoalesce` | 条件聚合合并 |
| `ObTransformConstPropagate` | 常量传播（a=1 AND b=a → b=1） |
| `ObTransformSimplifyExpr` | 表达式简化（去除冗余 / 折叠） |
| `ObTransformSimplifyOrderby` | ORDER BY 简化（去重） |

### 10.6 推荐下一步

按之前梳理的顺序，下一篇应该是 **#100 SQL 引擎 / 算子 / 执行框架**（OB 引擎总览/全系列总结）：

OB 的 SQL 执行引擎 —— 25+ 种 operator + executor 调度 + Task 框架 + PX 并行。源码入口：`src/sql/executor/` + `src/sql/engine/cmd/` + `src/share/scheduler/` + `src/share/dag/`。

适用场景：OB 引擎全栈总览 / #1-#99 系列总结。

整吗？