# 22. MySQL 查询优化器 (Query Optimizer)

> 本文分析 MySQL SQL 层查询优化器的实现，包括 JOIN 优化流程、表连接顺序搜索、条件优化、范围扫描选择。核心文件：`sql/sql_optimizer.cc`、`sql/sql_planner.cc`、`sql/range_optimizer/`。

---

## 1. 概述

MySQL 的查询优化器位于 SQL 层，负责将解析后的查询树转换为高效的执行计划。核心入口是 `JOIN::optimize()`，其执行流程可概括为：

```
JOIN::optimize()                          # sql_optimizer.cc:344
 ├─ 表达式化简：optimize_cond()           # WHERE/HAVING 条件化简
 ├─ 分区裁剪：prune_table_partitions()
 ├─ 聚合优化：optimize_aggregated_query() # COUNT(*) / MIN / MAX
 ├─ 子查询优化
 ├─ 表连接顺序优化                         # Optimize_table_order::choose_table_order()
 │   └─ best_extension_by_limited_search() # 动态规划/贪心搜索
 ├─ 访问路径选择                           # 全表扫描 / 索引范围 / 索引合并
 │   └─ get_key_scans_params()             # 评估各索引的 range 扫描
 └─ 生成 AccessPath 树                    # create_access_paths_for_join()
```

---

## 2. 核心流程：`JOIN::optimize()`

### 2.1 入口与初始化

```cpp
// sql_optimizer.cc:344
bool JOIN::optimize(bool finalize_access_paths) {
  // 防止 EXPLAIN 重复调用
  if (optimized) return false;

  /* Step 1: 优化 derived table / view */
  for (Table_ref *tl = query_block->leaf_tables; tl; tl = tl->next_leaf) {
    if (tl->is_view_or_derived()) {
      tl->optimize_derived(thd);                     // line 427
    }
  }

  /* Step 2: 条件化简（WHERE / HAVING）*/
  if (where_cond) {
    optimize_cond(thd, &where_cond, &cond_equal,
                  &query_block->m_table_nest, ...);   // line 478
  }

  /* Step 3: 分区裁剪 */
  if (query_block->partitioned_table_count) {
    prune_table_partitions();                         // line 499
  }

  /* Step 4: 常量聚合优化 */
  if (implicit_grouping) {
    optimize_aggregated_query(thd, query_block,
                              *fields, where_cond, &outcome);  // line 515
  }

  /* Step 5: 选择连接顺序（多表时）*/
  if (tables_list && !(active_options() & OPTION_NO_JOIN_CACHE)) {
    Optimize_table_order opt(this, ...);
    opt.choose_table_order();                         // line ~750
  }

  /* Step 6: 生成最终 AccessPath */
  set_root_access_path(create_access_paths_for_join());  // line ~1200
}
```

### 2.2 条件优化 `optimize_cond`

`optimize_cond()`（定义于 `sql_opt_cond.cc`）执行：

- **常量传播**：`WHERE a = 1 AND a = b → b = 1`
- **条件移除**：`WHERE 1=1` 移除
- **OR 分解**：`WHERE a=1 OR a=2 → key IN(1,2)` 转化为 range
- **等值推断**：`a = b AND b = 5 → a = 5`

---

## 3. 表连接顺序优化

### 3.1 `Optimize_table_order::choose_table_order()`

```cpp
// sql/sql_planner.cc:1953
bool Optimize_table_order::choose_table_order() {
  /* Step 1: 查找常量表（0-1 行结果）*/
  search_in_other_tables(const_tables, ...);       // line 1960

  /* Step 2: 确定连接顺序搜索边界 */
  const auto remaining = join->tables - join->const_tables;
  const auto search_depth = min(remaining, join->thd->variables.optimizer_search_depth);

  /* Step 3: 贪心/穷举搜索最优连接顺序 */
  best_extension_by_limited_search(
      0, join->tables - join->const_tables,
      remaining, search_depth,                             // line 1996
      current_record_count, current_read_time, current_join_factors);
}
```

`optimizer_search_depth` 控制搜索深度：
- `0`：自动选择（通常为 `min(n_tables, 7)`）
- `1`：贪心算法（仅考虑当前最优）
- `N`：穷举所有 N 表组合

### 3.2 `best_extension_by_limited_search`

```cpp
// sql/splanner.cc:2721
bool Optimize_table_order::best_extension_by_limited_search(
    uint idx, uint remaining, double record_count, double read_time,
    table_factors *cur_join_factors) {

  if (remaining == 0) {
    /* 完整路径 → 评估总成本 */
    best_read = read_time;
    best_record_count = record_count;
    return false;
  }

  for (const auto &pos : join->positions[idx].table) {
    /* 如果剩余表数 ≤ search_depth，全排列搜索 */
    /* 否则贪心选择下一个表 */
    const bool disable_jbuf =
        (idx + best_n_jbuf_sort) >= no_jbuf_after || !check_join_cache_usage();

    /* 构建该表的访问路径并计算成本 */
    best_access_path(pos, ...);

    /* 递归搜索剩余表的顺序 */
    best_extension_by_limited_search(idx + 1, remaining - 1, ...);
  }
}
```

**成本估算**：`record_count × read_time`，其中 `read_time` 包括磁盘 I/O 和 CPU 时间。

---

## 4. 范围扫描优化

### 4.1 入口：`get_key_scans_params`

```cpp
// sql/range_optimizer/index_range_scan_plan.cc:822
AccessPath *get_key_scans_params(THD *thd, RANGE_OPT_PARAM *param,
                                 SEL_TREE *tree, bool index_read_must_be_used,
                                 bool update_tbl_stats,
                                 enum_order order_direction,
                                 bool skip_records_in_range,
                                 const double cost_est, bool ror_only,
                                 Key_map *needed_reg) {

  /* Step 1: 遍历每个可能索引 */
  for (idx = 0; idx < param->keys; idx++) {
    key = tree->keys[idx];

    if (key) {
      bool is_ror_scan, is_imerge_scan;

      /* Step 2: 调用 check_quick_select 估算行数 */
      found_records = check_quick_select(
          thd, param, idx, read_index_only, key, update_tbl_stats,
          order_direction, skip_records_in_range,               // line 861
          &mrr_flags, &buf_size, &cost, &is_ror_scan, &is_imerge_scan);

      /* Step 3: 记录最优方案 */
      if (found_records < best_records) {
        // 选择行数最少的索引
        best_records = found_records;
        best_idx = idx;
      }
    }
  }

  /* Step 4: 创建 Quick_range_select 或 index merge */
  // ...
}
```

### 4.2 Range 分析流程

```
WHERE 条件
 └─ SEL_TREE 构建               # range_analysis.cc
     ├─ SEL_ARG 语法树（区间树）
     └─ 合并 = / > / < / BETWEEN / IN
 └─ check_quick_select()        # index_range_scan.cc
     └─ 遍历 SEL_ARG 树估算行数
         └─ 使用 records_in_range 引擎调用
```

**SEL_TREE** 是条件表达式的一种内部表示，其中每个索引对应一棵 `SEL_ROOT`（区间树）。多个索引之间可能通过 index_merge 合并。

---

## 5. 访问路径生成

优化完成后，`JOIN::optimize()` 调用 `create_access_paths_for_join()` 生成 `AccessPath` 树：

```
AccessPath(root)
 ├─ AccessPath(HashJoin) / AccessPath(NestedLoopJoin)
 │   ├─ AccessPath(TableScan)         # 全表扫描
 │   ├─ AccessPath(RangeScan)         # 索引范围扫描
 │   ├─ AccessPath(IndexSkipScan)     # 索引跳跃扫描
 │   ├─ AccessPath(IndexMerge)        # 索引合并
 │   ├─ AccessPath(RefAccess)         # 等值引用访问
 │   └─ AccessPath(MaterializedTable) # 物化派生表
```

`finalize_access_paths` 参数控制是否在优化阶段同时完成路径的最终化（成本计算、排序方式等）。

---

## 6. 子查询优化

MySQL 8.0 为子查询引入了多种优化策略（受 `optimizer_switch` 控制）：

| 策略 | 说明 |
|------|------|
| **Semi-Join** | `IN (SELECT ...)` 转换为半连接，允许多表连接顺序优化 |
| **Materialization** | 将子查询结果物化为临时表，`WHERE IN (SELECT ...)` 场景 |
| **Exists -> IN** | `EXISTS` 条件转换为 `IN` 子查询以利用索引 |
| **Subquery Decorrelation** | 将相关子查询改写为无关联子查询 |

半连接的实现入口在 `sql_planner.cc` 的 `Optimize_table_order` 中，优化器在搜索连接顺序时尝试将子查询的表与外部表合并。

## 7. 成本模型详解

优化器的成本估算基于以下公式：

```
total_cost = startup_cost + row_count × tuple_cost
```

其中各因素包括：

- **row_count**：通过 `records_in_range()` 引擎调用估算索引区间内的行数
- **startup_cost**：索引查找（B+Tree 根到叶子）的固定 I/O 成本
- **tuple_cost**：每条记录的处理成本（CPU + 可能的磁盘 I/O）
- **disk_io_cost**：`read_time = disk_seeks × seek_cost + disk_reads × page_cost`

`JOIN::best_read` 存储了最优连接顺序的估算执行成本。

## 8. 优化器关键参数

| 系统变量 | 默认值 | 说明 |
|----------|--------|------|
| `optimizer_search_depth` | 0（自动） | 连接顺序搜索深度 |
| `optimizer_switch` | — | 控制半连接、物化、索引合并等特性开关 |
| `optimizer_prune_level` | 1 | 是否启用启发式剪枝 |
| `range_optimizer_max_mem_size` | 0（无限制） | Range 优化器的最大内存使用 |
| `join_buffer_size` | 256KB | 连接缓冲区大小 |

## 9. 执行计划生成与 EXPLAIN

优化结束后，`JOIN::optimize()` 调用 `set_root_access_path()` 生成 `AccessPath` 树。EXPLAIN 通过遍历 AccessPath 树输出计划：

```
EXPLAIN FORMAT=TREE
└─ -> Nested loop inner join
    ├─ -> Index scan on t2 using PRIMARY
    └─ -> Filter: (t1.id = t2.id)
        └─ -> Table scan on t1
```

`create_explain_access_path()`（`sql/opt_explain.cc`）将 AccessPath 节点转换为 Explain_node。EXPLAIN FORMAT=JSON 则输出成本明细、索引名、范围条件等详细信息。

---

## 10. 总结

MySQL 查询优化器的核心设计理念：

1. **多阶段优化**：先化简条件再搜索计划，`optimize_cond` 简化搜索空间。
2. **动态规划 + 贪心混合**：`best_extension_by_limited_search` 在小表量时穷举，大表量时贪心剪枝。
3. **成本模型驱动**：基于 `read_time` 和 `record_count` 的乘积比较不同连接顺序和访问路径。
4. **Range 引擎独立**：`range_optimizer/` 目录下的组件负责从 WHERE 条件推导索引区间，支持单索引范围扫描和索引合并（Index Merge）。
5. **AccessPath 统一表达**：所有执行计划元素最终统一为 `AccessPath` 树，降低优化器与执行器的耦合。

### 源码引用汇总

| 文件 | 行号 | 关键内容 |
|------|------|----------|
| `sql_optimizer.cc` | 344 | `JOIN::optimize()` |
| `sql_optimizer.cc` | 478 | `optimize_cond()` 条件化简 |
| `sql_planner.cc` | 1953 | `Optimize_table_order::choose_table_order()` |
| `sql_planner.cc` | 2721 | `best_extension_by_limited_search()` |
| `index_range_scan_plan.cc` | 822 | `get_key_scans_params()` |
| `sql/sql_optimizer.h` | 133 | `class JOIN` 定义 |
