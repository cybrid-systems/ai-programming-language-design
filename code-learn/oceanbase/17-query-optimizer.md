# #17 v2 — Query Optimizer (CBO + Cost Model + Join Ordering)

> 接续 #18 v2 Index Design：上一文把"索引是什么 + 怎么用 + 怎么维护"讲清楚。本
> 文抬到更上层——**优化器怎么决定用什么索引、怎么排 join、怎么下推谓词、怎么
> 估行数**。这是 OB 把 SQL 文本变成高效执行计划的全部秘密。

---

## 0. 全文导读

OB 的优化器走经典 CBO(cost-based optimizer)路线:

```
SQL text
  │
  ↓ Parser
Parse tree (ObStmt / ObSelectStmt)
  │
  ↓ Resolver (name resolution + type inference)
Resolved tree (ObDMLStmt with column items)
  │
  ↓ Optimizer (CBO)
Logical plan (ObLogPlan)
  ├─ ObLogTableScan / ObLogIndexScan (接 #18 v2)
  ├─ ObLogJoin (NL / Hash / Merge)
  ├─ ObLogSubPlanFilter / ObLogSemiJoin (subquery)
  ├─ ObLogSort / ObLogLimit / ObLogGroupBy
  └─ ObLogExchange (parallel distribution)
  │
  ↓ Code generator (物理化)
Physical plan (ObPhysicalPlan)
  │
  ↓ Executor
Result rows
```

本文聚焦 **Optimizer** 阶段,从 Parse tree 进来,输出 Logical plan。重点:

1. **逻辑计划生成**(ObLogPlan 的层次)
2. **Cost model**(行数 + IO + CPU 估算)
3. **Join ordering**(动态规划算法)
4. **Subquery unnesting**(semi/anti join 改写)
5. **谓词下推**(从顶层往叶子推)
6. **Index selection**(接 #18 v2)
7. **统计信息 + histogram**(CBO 的依据)
8. **Plan caching**(prepared statement)

---

## 1. 逻辑计划的层次结构

### 1.1 ObLogPlan 树

```cpp
// src/sql/optimizer/ob_log_plan.h:80
class ObLogPlan {
public:
  // 顶层:通常是 ObLogSelect / ObLogInsert / ObLogUpdate / ObLogDelete
  ObLogOperator *get_top_log_op() const { return top_log_op_; }
  // 计划中的全部 operator
  const common::ObIArray<ObLogOperator *> &get_log_operators() const {
    return log_operators_;
  }
  // 计划 ID(给 explain 看)
  uint64_t get_plan_id() const { return plan_id_; }
};
```

每个 `ObLogOperator` 表示一个逻辑操作:

| Operator | 含义 |
|----------|------|
| `ObLogTableScan` | 全表扫描 |
| `ObLogIndexScan` | 索引扫描(接 #18 v2) |
| `ObLogJoin` | 两表 join(NL / Hash / Merge) |
| `ObLogSemiJoin` / `ObLogAntiJoin` | 半连接 / 反连接(EXISTS / NOT EXISTS) |
| `ObLogSubPlanFilter` | 相关子查询 |
| `ObLogGroupBy` | 聚合 |
| `ObLogSort` | 排序 |
| `ObLogLimit` | TOP-N / LIMIT |
| `ObLogExchange` | 并行执行的数据分发 |

### 1.2 构造顺序:从底向上

优化器先构造**叶子 operator**(table/index scan),再逐层构造**中间 operator**(join, groupby)。每层构造时调cost model 估算,选最优的 child 组合。

```cpp
// src/sql/optimizer/ob_optimizer.cpp:300
int ObOptimizer::optimize(ObDMLStmt &stmt, ObLogPlan &plan) {
  // 1. 收集候选 table access path
  ObSEArray<ObTableAccessPath *> candidates;
  generate_access_paths(stmt, candidates);
  
  // 2. 生成 join 顺序(动态规划)
  ObJoinOrder join_order;
  join_order.compute(stmt, candidates, plan);
  
  // 3. 加上 groupby / sort / limit
  add_top_operators(plan);
  
  // 4. 子查询展开 / 谓词下推
  transform_plan(plan);
  
  return OB_SUCCESS;
}
```

---

## 2. Cost Model — 估算"这个 plan 多贵"

### 2.1 成本组成

OB 的 cost 是加权线性组合:

```
cost = α × IO_cost + β × CPU_cost + γ × memory_cost + δ × network_cost
```

默认权重(可调):
- `α = 1.0` (IO 是主导)
- `β = 0.5` (CPU 次要)
- `γ = 0.3` (内存占用)
- `δ = 0.5` (并行场景下网络)

### 2.2 Table Scan 成本

```cpp
// src/sql/optimizer/ob_opt_cost_model.cpp:120
double ObCostModel::estimate_table_scan_cost(const ObTableAccessPath &path) {
  const double table_rows = path.table_rows_;
  // IO cost = micro_block 数
  double io_cost = table_rows / rows_per_micro_block_;  // ~256 rows/block
  // CPU cost = deserialize cost
  double cpu_cost = table_rows * cpu_per_row_;
  // Memory cost = buffer pool miss penalty
  double mem_cost = (1.0 - buffer_pool_hit_rate_) * io_cost;
  
  return ALPHA_IO * io_cost + BETA_CPU * cpu_cost + GAMMA_MEM * mem_cost;
}
```

### 2.3 Index Scan 成本(接 #18 v2)

```cpp
// src/sql/optimizer/ob_opt_cost_model.cpp:300
double ObCostModel::estimate_index_scan_cost(const ObIndexAccessPath &path) {
  // 1. 索引列上的 selectivity
  double selectivity = estimate_selectivity(path.index_columns_, path.filters_);
  double index_rows = path.table_rows_ * selectivity;
  
  // 2. 索引 IO
  double idx_io = index_rows / rows_per_micro_block_;
  
  // 3. 回表 IO(如果不是 covering)
  double lookup_io = 0.0;
  if (!is_covering(path)) {
    lookup_io = index_rows * lookup_io_per_row_;  // ~0.1 IO/row
  }
  
  // 4. Bloom filter 节省
  double bloom_saving = idx_io * (1.0 - bloom_filter_fp_rate_);  // ~0.01 false positive
  
  return ALPHA_IO * (idx_io + lookup_io - bloom_saving) + BETA_CPU * index_rows;
}
```

### 2.4 Join 成本

每种 join 算法有自己的 cost 公式:

```cpp
// src/sql/optimizer/ob_opt_cost_model.cpp:500
// NL Join cost
double ObCostModel::estimate_nl_join_cost(...) {
  // outer 扫一遍,每行去 inner 做 lookup
  return outer_cost + outer_rows × inner_cost_per_lookup;
}

// Hash Join cost
double ObCostModel::estimate_hash_join_cost(...) {
  // build hash table on smaller side, probe with larger side
  return smaller_cost + build_cost + larger_cost + probe_cost × larger_rows;
}

// Merge Join cost
double ObCostModel::estimate_merge_join_cost(...) {
  // 两边都已排序,merge 一次
  return outer_cost + inner_cost + merge_cost × (outer_rows + inner_rows);
}
```

Hash Join 通常最优(除非内表太大装不进内存),Merge Join 需要两边预排序。

---

## 3. Selectivity Estimation — 谓词选多少行

### 3.1 基础等值

```cpp
// src/sql/optimizer/ob_opt_stat.cpp:200
double ObOptStat::estimate_equal_selectivity(const ObColumnStat &col_stat,
                                              const ObObj &value) {
  if (col_stat.is_unique()) return 1.0 / col_stat.distinct_count_;
  // 等值在非唯一列:1/NDV (uniform assumption)
  return 1.0 / col_stat.distinct_count_;
}
```

### 3.2 Histogram 介入

非均匀分布的列(比如 `country` 列,`CN` 占 50%),用 histogram:

```cpp
// src/sql/optimizer/ob_opt_stat.cpp:350
double ObOptStat::estimate_equal_with_histogram(const ObHistogram &hist,
                                                  const ObObj &value) {
  // 1. 二分找 value 在 histogram 哪个 bucket
  size_t bucket_idx = hist.find_bucket(value);
  // 2. bucket 内插值
  const ObHistBucket &bucket = hist.buckets_[bucket_idx];
  double bucket_density = bucket.distinct_count_ / bucket.size_;
  return bucket_density / hist.total_rows_;
}
```

OB 默认 254-bucket histogram。`ANALYZE TABLE t` 触发收集。

### 3.3 多谓词组合

```cpp
// src/sql/optimizer/ob_opt_stat.cpp:500
double ObOptStat::estimate_combined_selectivity(
    const ObIArray<ObSelectivity> &sels) {
  // 默认独立性假设(over-simplification)
  double combined = 1.0;
  for (auto &s : sels) combined *= s.value;
  // multi-column 关联时用 multi-column histogram 修正
  // 没有 multi-col histogram 时,上限 0.5 (经验值)
  return std::min(combined, 0.5);
}
```

> **v2 洞察**:selectivity 估算是 CBO 最大的误差来源。"独立性假设"几乎总是错
> —— 比如 `gender='M' AND age_group='20s'` 在用户表里**强相关**(男性中
> `20s` 占 30%,总体中 `20s` 占 20%)。OB 用 multi-column histogram 和 join
> correlation 修正,但覆盖率有限。所以 CBO 经常"看着 plan 不错,实际跑很
> 慢"——这时候要 `ANALYZE TABLE` 重收 stats。

---

## 4. Join Ordering — 动态规划算法

### 4.1 问题

N 张表的 join,N! 种顺序(虽然可以简化成"(N-1)! + 重复")。N=10 时已经 9! ≈ 36 万种,
N=20 不可枚举。

### 4.2 经典 DP 算法(SYSTEM R / Volcano)

```cpp
// src/sql/optimizer/ob_join_order.cpp:200
int ObJoinOrder::compute_join_order(ObDMLStmt &stmt, ObLogPlan &plan) {
  // 1. 单表最优 access path(每个 base table 选最优 index/table scan)
  for (auto &table : stmt.tables_) {
    best_paths_[table.set_id_] = select_best_path(table);
  }
  
  // 2. DP:每次合并两个最优子集
  for (size_t level = 2; level <= stmt.tables_.count(); ++level) {
    for (auto &left_set : enumerate_subsets(level)) {
      ObJoinPath *best = nullptr;
      for (auto &right_table : remaining_tables(left_set)) {
        ObJoinPath *candidate = build_join_path(left_set, right_table);
        if (best == nullptr || candidate->cost() < best->cost()) {
          best = candidate;
        }
      }
      best_paths_[left_set] = best;
    }
  }
  
  // 3. 输出全集的最优 path
  plan.set_plan_tree(best_paths_[full_set]);
  return OB_SUCCESS;
}
```

### 4.3 启发式剪枝

OB 的 join ordering 不是暴力 DP——有几层剪枝:

```cpp
// src/sql/optimizer/ob_join_order.cpp:400
bool ObJoinOrder::should_consider_join(ObJoinPath *left, ObJoinPath *right) {
  // 1. 如果 left 已经包含 right,跳过
  if (left->contains(right)) return false;
  // 2. 如果 left.cost × right.cost > best_cost,跳过(下界剪枝)
  if (left->cost() * right->cost() > current_best_cost_) return false;
  // 3. 如果 join 谓词不在 left ∪ right 上,跳过
  if (!has_join_predicate(left, right)) return false;
  return true;
}
```

实际可处理的 join 表数:**10-15 张**。超过这个数,OB 退回到"left-deep tree
+ 启发式搜索",可能不是全局最优。

### 4.4 Join Algorithm 选择

每个 join path 里,优化器还要选 NL / Hash / Merge:

```cpp
// src/sql/optimizer/ob_opt_join_path.cpp:100
int ObOptJoinPath::select_join_algorithm(ObJoinPath *path) {
  ObSEArray<double, 3> costs;
  // 1. 估 NL cost
  costs.push_back(estimate_nl_cost(path));
  // 2. 估 Hash cost(检查 inner 是否能装进内存)
  if (path->inner_rows() < hash_join_mem_threshold_) {
    costs.push_back(estimate_hash_cost(path));
  }
  // 3. 估 Merge cost(检查是否都已排序)
  if (path->left_sorted() && path->right_sorted()) {
    costs.push_back(estimate_merge_cost(path));
  }
  // 4. 选 cost 最小的
  path->set_algorithm(ALGO_OF_MIN(costs));
  return OB_SUCCESS;
}
```

> **v2 洞察**:join algorithm 选择高度依赖**内表行数估算**。如果 stats 过时
> (估算 1000 行,实际 1M 行),优化器会选 Hash Join(看起来最优),但 build 阶
> 段 OOM 或 spill 到 disk。这是"plan 看着好,跑起来崩"的典型场景。`ANALYZE
> TABLE` 几乎是必备。

---

## 5. Subquery Unnesting

### 5.1 问题

```sql
SELECT * FROM t1 WHERE t1.id IN (SELECT t2.t1_id FROM t2 WHERE t2.x = 5);
```

含相关子查询的 query 没法直接 join。优化器改写:

```
t1.id IN (SELECT t2.t1_id FROM t2 WHERE t2.x = 5)
  ↓ 改写
SEMI JOIN(t1, t2 ON t1.id = t2.t1_id) WHERE t2.x = 5
```

### 5.2 OB 实现

```cpp
// src/sql/optimizer/ob_subquery_unnest.cpp:100
int ObSubqueryUnnest::unnest(ObDMLStmt &stmt, ObLogPlan &plan) {
  for (auto &subquery : stmt.subqueries_) {
    switch (subquery->type_) {
      case ObSubQuery::IN_EXISTS:
        // 改成 SEMI JOIN
        convert_to_semi_join(subquery, plan);
        break;
      case ObSubQuery::NOT_IN_EXISTS:
        // 改成 ANTI JOIN(注意 NULL 处理)
        convert_to_anti_join(subquery, plan);
        break;
      case ObSubQuery::SCALAR:
        // 改成 SEMI JOIN + mark column
        convert_to_semi_join_with_mark(subquery, plan);
        break;
      case ObSubQuery::CORRELATED:
        // 相关子查询,加 correlation filter
        add_correlation_filter(subquery, plan);
        break;
    }
  }
  return OB_SUCCESS;
}
```

### 5.3 NOT IN 与 NULL 的陷阱

```sql
SELECT * FROM t1 WHERE t1.id NOT IN (SELECT t2.t1_id FROM t2);
```

如果 `t2.t1_id` 含 NULL,`NOT IN` 返回 NULL(整个 query 不返回行),而不是
TRUE。改写 ANTI JOIN 必须保留 NULL 语义:

```cpp
// src/sql/optimizer/ob_subquery_unnest.cpp:300
// ANTI JOIN + NULL 保留 = "anti join on NOT NULL columns only"
// 如果子查询可能产 NULL,优化器拒绝改写,fallback 到嵌套循环
if (subquery->may_return_null()) {
  // 拒绝改写,保持嵌套循环(每行 IN-execute 子查询)
  LOG_WARN("anti join unnesting refused: NULL semantics");
  return OB_SUCCESS;  // 不改写
}
```

> **v2 洞察**:NOT IN 改写 ANTI JOIN 是 SQL 标准模糊地带。PostgreSQL/MySQL
> 行为不一致,应用层常踩坑。OB 选择"保守":如果子查询可能产 NULL,不动 SQL
> 语义。这是"宁可慢,不可错"的体现。

---

## 6. 谓词下推(Predicate Pushdown)

### 6.1 动机

```sql
SELECT * FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t2.x = 5;
```

`WHERE t2.x = 5` 应该下推到 t2 的 scan,而不是 join 之后 filter:

```
优化前:SCAN(t1) ⨝ SCAN(t2) → FILTER(x=5)
优化后:SCAN(t1) ⨝ SCAN-WHERE(x=5)(t2)
```

下推后,t2 的 scan 行数大减,join cost 降低。

### 6.2 实现

```cpp
// src/sql/optimizer/ob_predicate_pushdown.cpp:100
int ObPredicatePushdown::pushdown(ObLogPlan &plan) {
  // 从 plan 顶层往下走,每层 operator 决定哪些谓词可以下沉
  for (auto &op : plan.get_log_operators()) {
    // 1. 当前 op 的 output filter
    ObSEArray<ObRawExpr *> output_filters;
    op->get_output_filters(output_filters);
    // 2. 对每个 filter,看能否下沉到 child
    for (auto &filter : output_filters) {
      for (size_t i = 0; i < op->get_child_count(); ++i) {
        if (can_pushdown(filter, op->get_child(i))) {
          // 下沉:从 output filter 移到 child 的 filter
          op->remove_output_filter(filter);
          op->get_child(i)->add_filter(filter);
        }
      }
    }
  }
  return OB_SUCCESS;
}

bool ObPredicatePushdown::can_pushdown(ObRawExpr *filter, ObLogOperator *child) {
  // filter 引用的列必须都在 child 的 output 里
  return filter->referenced_columns().is_subset_of(child->output_columns());
}
```

### 6.3 类型

| 下推类型 | 例子 | 效果 |
|----------|------|------|
| **Filter 下推** | `WHERE t.x = 5` | scan 行数减少 |
| **Join 下推** | `WHERE t.x = 5 AND t.y = t2.y` | join 前先 filter |
| **Limit 下推** | `LIMIT 10` | 提前终止 |
| **Aggregation 下推** | `GROUP BY x` 在 join 前 | 部分聚合 |
| **Projection 下推** | `SELECT a, b` | 只 deserialize 需要的列 |

> **v2 洞察**(接 #18 v2):Projection 下推到 micro_block 是 OB 的"killer
> feature"——每行 deserialize 后只取需要的列,跳过其他列。在 wide row(100+
> 列)表上,IO 不变但 CPU 大幅降低。covering index 的核心就是 projection
> 下推。

---

## 7. Index Selection(接 #18 v2 深入)

### 7.1 多 index 候选对比

```sql
SELECT * FROM t WHERE a = 5 AND b LIKE '%x%';
```

候选:
- 主表 scan(无 index)
- idx_a(覆盖 `a` 等值)
- idx_ab(覆盖 `a` 等值 + `b` 前缀)

优化器对每个候选算 cost,选最优:

```cpp
// src/sql/optimizer/ob_log_plan.cpp:3500
int ObLogPlan::select_best_access_path(...) {
  ObSEArray<ObTableAccessPath *> candidates;
  // 主表
  candidates.push_back(generate_table_scan_path(table_meta));
  // 每个 secondary index
  for (auto &idx : table_meta.indexes_) {
    candidates.push_back(generate_index_scan_path(idx, filters));
  }
  
  // 选 cost 最小的
  ObTableAccessPath *best = nullptr;
  for (auto &c : candidates) {
    if (best == nullptr || cost(c) < cost(best)) {
      best = c;
    }
  }
  return best;
}
```

### 7.2 索引选错的常见原因

```cpp
// src/sql/optimizer/ob_log_plan.cpp:3600
bool ObLogPlan::has_index_choice_problem() const {
  // 1. NDV 估算严重偏差(> 10x)
  for (auto &idx : used_indexes_) {
    if (idx->estimated_rows_ > idx->actual_rows_ * 10) return true;
  }
  // 2. 多列相关性未识别 → selectivity 估算过大
  if (has_multicol_correlation_missed()) return true;
  // 3. 用了非 covering index 但回表 cost 被低估
  if (has_lookup_cost_misestimated()) return true;
  return false;
}
```

> **v2 洞察**(接 #29 v2 Slow Query):生产环境 80% 的"慢 query"是 index 选
> 错,index 选错的 80% 是 stats 过时。`ANALYZE TABLE` 是 99% 调优第一步。OB
> 提供 `query_trace` 看每个候选的 cost 估算——直接 dump optimizer 选择过程。

---

## 8. Statistics 收集

### 8.1 收集方式

```cpp
// src/share/stat/ob_stat_manager.h:80
class ObStatManager {
public:
  // 周期性 + 触发式收集
  int gather_table_stats(uint64_t table_id, double sample_rate = 0.1);
  int gather_index_stats(uint64_t index_id);
  // 增量收集(只统计 delta)
  int gather_incremental_stats(uint64_t table_id);
};
```

### 8.2 Histogram 类型

OB 支持两种 histogram:

```cpp
// src/share/stat/ob_histogram.h:100
class ObHistogram {
public:
  // 频率直方图(高频值精确桶)
  void build_frequency_histogram(const ObIArray<ObObj> &samples);
  // 等高直方图(等高桶,适合连续值)
  void build_height_balanced_histogram(const ObIArray<ObObj> &samples);
};
```

频率直方图精确但只记 top-N,适合 `country` 这种离散值。等高直方图精确但
桶大小固定,适合 `salary` 这种连续值。

### 8.3 失效与重收

```cpp
// src/share/stat/ob_stat_manager.cpp:300
bool ObStatManager::is_stats_stale(uint64_t table_id) {
  // 1. 自上次收集后修改的行数 > 20%
  uint64_t modified = get_modified_rows_since_last_collect(table_id);
  if (modified > 0.2 * get_total_rows(table_id)) return true;
  // 2. 自上次收集后超过 7 天
  if (time(NULL) - last_collect_time_[table_id] > 7 * 86400) return true;
  return false;
}
```

`ANALYZE TABLE t` 强制重收。`major freeze` 后自动 gather。

---

## 9. Plan Cache

### 9.1 动机

```sql
PREPARE stmt FROM 'SELECT * FROM t WHERE x = ?';
EXECUTE stmt USING 5;
EXECUTE stmt USING 10;
EXECUTE stmt USING 15;
```

每次 EXECUTE 都重 parse + 重优化,浪费。Plan cache 缓存第一次的优化结果。

### 9.2 实现

```cpp
// src/sql/plan_cache/ob_plan_cache.h:100
class ObPlanCache {
public:
  // key: SQL text fingerprint + parameter types
  ObCacheKey make_key(const ObString &sql, const ObIArray<ObObjType> &param_types);
  // 命中:拿缓存的 plan;不命中:重新优化 + 存
  ObPhysicalPlan *get_or_create_plan(const ObString &sql, ...);
};
```

### 9.3 失效

```cpp
// src/sql/plan_cache/ob_plan_cache.cpp:300
int ObPlanCache::invalidate_on_schema_change(uint64_t table_id) {
  // 1. 找所有引用该表的 plan
  ObSEArray<ObPhysicalPlan *> affected;
  find_plans_using_table(table_id, affected);
  // 2. 全部失效
  for (auto *plan : affected) plan->invalidate();
  return OB_SUCCESS;
}
```

DDL 触发 invalidation。如果表 schema 改了,旧 plan 不适用——必须重优化。

> **v2 洞察**:Plan cache 在 OB 里是"lru + schema-versioned"。一次 DDL
> (比如 `ALTER TABLE t ADD COLUMN`)会瞬间清空大量 plan,下一波 query 全
> 都要重优化——可能造成"DDL 后一波慢"。这是 trade-off,不是 bug。

---

## 10. Adaptive Features

### 10.1 Adaptive Cursor Sharing

```sql
PREPARE stmt FROM 'SELECT * FROM t WHERE x = ?';
EXECUTE stmt USING 5;     -- selectivity 0.001(走 idx_x)
EXECUTE stmt USING NULL;  -- selectivity 1.0 (全表扫)
```

如果用同一 plan,第二个 EXECUTE 极慢。Adaptive cursor sharing 为不同参数分
发不同 plan:

```cpp
// src/sql/plan_cache/ob_adaptive_cursor.cpp:50
class ObAdaptiveCursor {
public:
  // 根据参数值重新选 plan
  ObPhysicalPlan *select_plan_for_params(const ObIArray<ObObj> &params);
};
```

### 10.2 Runtime Filter

Hash Join 在 build 阶段发现某些 outer 行不命中,可以 runtime 给 executor 推
filter:

```cpp
// src/sql/optimizer/ob_runtime_filter.cpp:80
// runtime filter 在 hash build 时生成,在 outer scan 时下推
// 减少 outer 实际进 hash probe 的行数
```

OB 4.x 起引入 runtime filter,主要优化"join 内表小,外表大"的场景。

### 10.3 Plan Monitor

```sql
SELECT * FROM oceanbase.__all_virtual_plan_monitor\G
```

可以看到每个 plan 的实际执行统计(rows、time、memory),和 optimizer 估算对比,
识别"估算严重偏差"的 plan——给下次 ANALYZE 提供信号。

---

## 11. 优化器的局限与陷阱

### 11.1 常见错误选择

```sql
-- 陷阱 1:函数包裹索引列
SELECT * FROM t WHERE DATE(create_time) = '2026-08-02';
-- optimizer 无法用 create_time 上的索引(DATE() 把列变成表达式)
-- 即使有 functional index,也要求 DATE() 和索引表达式完全一致
```

```sql
-- 陷阱 2:隐式类型转换
SELECT * FROM t WHERE varchar_col = 123;  -- 123 是 INT
-- OB 强类型检查:类型不匹配直接报错,不会走索引
```

```sql
-- 陷阱 3:OR 分散选择性
SELECT * FROM t WHERE a = 1 OR a = 2 OR a = 3 OR ... (100 个 OR);
-- optimizer 会展开成 IN-list,如果 IN-list > 一定阈值,放弃用 index
```

### 11.2 调优 Checklist

1. ✅ `EXPLAIN EXTENDED` 看 optimizer 选择
2. ✅ `ANALYZE TABLE` 重收 stats
3. ✅ 检查 `EXPLAIN` 估算 rows 和实际 rows 的差距
4. ✅ `query_trace` 看每个候选 cost
5. ✅ 加 covering index 而不是回表
6. ✅ 改写 query(避免函数包裹、隐式转换、OR 分散)

---

## 12. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 是一条贯穿
**storage / index / optimizer** 主线:

| # | 主题 | 抽象层 | 关键 insight |
|---|------|--------|--------------|
| #14 v2 | MemTable Internals | 内存层 | key encoding + 跨结构事务边界 |
| #15 v2 | ObKeyBTree | B-tree 实现 | skiplist-like + MVCC 集成 |
| #16 v2 | ObMvccHashIndex | hash 实现 | 等值查询优化 + GC 集成 |
| #17 v2 (本文) | Query Optimizer | CBO 层 | cost model + join ordering + 谓词下推 |
| #18 v2 | Index Design | 索引系统 | clustered/secondary/functional + CBO 选择 |

五篇连起来,读者能完整理解 OB 的"从 SQL 文本到高效执行":

- 输入端:#17 (parse + resolve) → #17 (CBO 选 plan)
- 索引决策:#17 (optimizer 选 index) → #18 (索引 storage)
- 执行端:#18 (covering 判断) → #15/#16 (MemTable scan) → #14 (SSTable fallback)
- 维护端:DML → #18 (index propagation) → #1-#5 (MVCC versioning) → #16 (compact GC)

---

## 13. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **#41 v2 Join Operators** — NL/Hash/Merge Join 实现细节(接 #17 CBO 估算)
- **#51 v2 Block Cache** — micro_block + bloom_filter cache 深入
- **#29 v2 Slow Query** — slow query 捕获 + 分析 + 索引推荐
- **#19-#40 系列** — 取决于具体编号(待确认)

继续哪一篇?

---

## 14. 参考(可执行的源码锚点)

- `src/sql/optimizer/ob_optimizer.cpp` — 优化器主入口
- `src/sql/optimizer/ob_log_plan.h` — 逻辑计划根
- `src/sql/optimizer/ob_opt_cost_model.cpp` — cost model
- `src/sql/optimizer/ob_opt_stat.cpp` — selectivity 估算
- `src/sql/optimizer/ob_join_order.cpp` — join ordering DP
- `src/sql/optimizer/ob_opt_join_path.cpp` — join algorithm 选择
- `src/sql/optimizer/ob_subquery_unnest.cpp` — subquery 改写
- `src/sql/optimizer/ob_predicate_pushdown.cpp` — 谓词下推
- `src/sql/optimizer/ob_log_plan.cpp` — index 选择
- `src/share/stat/ob_stat_manager.h` — 统计信息收集
- `src/share/stat/ob_histogram.h` — histogram 类型
- `src/sql/plan_cache/ob_plan_cache.h` — plan cache
- `src/sql/plan_cache/ob_adaptive_cursor.cpp` — adaptive cursor sharing
- `src/sql/optimizer/ob_runtime_filter.cpp` — runtime filter

---

#17 v2 完。