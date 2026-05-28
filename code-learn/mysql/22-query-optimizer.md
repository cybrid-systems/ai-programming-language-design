# 22. MySQL 查询优化器（Query Optimizer）— 源码分析

> 本文分析 MySQL SQL 层查询优化器的实现，包括 JOIN 优化流程、表连接顺序搜索（贪心搜索 vs 穷举搜索）、条件优化与索引选择、范围扫描优化器、子查询解嵌套等核心路径。核心源文件：`sql/sql_optimizer.cc`、`sql/sql_planner.cc`、`sql/range_optimizer/`、`sql/sql_select.cc`。

---

## 0. 概述

MySQL 查询优化器将 SQL 语法树（SELECT/INSERT/UPDATE/DELETE）转换为最优的执行计划。其核心工作包括：

1. **逻辑优化**：条件化简（常量折叠、谓词下推）、子查询解嵌套（subquery_to_derived）、半连接转换（semi-join）
2. **物理优化**：JOIN 顺序搜索、索引选择、访问路径生成、JOIN 算法选择（NLJ/BNL/BKA/Hash Join）
3. **成本估算**：基于表和索引统计信息（`mysql.innodb_table_stats`/`mysql.innodb_index_stats`）计算每种执行计划的代价

### 优化器架构

```
SQL → parser → SELECT_LEX → JOIN → optimize()
  ├─ optimize_cond()         ← 条件化简
  ├─ substitute_gc()         ← 虚拟列替换
  ├─ substitute_for_best_effort_cond() ← 表达式简化
  ├─ flatten_subqueries()    ← 子查询解嵌套
  ├─ simplify_joins()        ← JOIN 语义化简
  ├─ make_join_plan()        ← 核心：JOIN 顺序搜索
  │   ├─ get_quick_record_count()  ← 索引范围估算
  │   ├─ best_access_path()        ← 单个表的最佳访问路径
  │   └─ best_extension_by_limited_search() ← 贪心搜索
  ├─ pick_table_access_method() ← 表访问方法选择
  └─ make_join_select()     ← 剩余条件处理
```

### 关键概念

| 概念 | 含义 |
|------|------|
| `JOIN::optimize()` | 每个 SELECT 语句的优化入口 |
| `TABLE_LIST` | FROM 子句中的表 |
| `SQL_SELECT` | WHERE 条件（位图编码的索引列用法） |
| `QEP` (Query Execution Plan) | 最终的执行计划 |
| `Cost_estimate` | 执行计划的总代价 |
| `join_tab` array | 优化后确定的表连接数组 |

---

## 1. 条件优化

### 1.1 optimize_cond()

```cpp
// sql_optimizer.cc
bool optimize_cond(THD *thd, Item **conds, COND_EQUAL **cond_equal,
                   List<TABLE_LIST> *join_list,
                   Item::cond_result *cond_value) {

  /* ──── 步骤 1：提取相等的常量 ──── */
  /* WHERE a = 5 → 在 a 的 Item_field 中标记 const_item */
  /* 后续可以利用此信息做索引范围扫描 */

  /* ──── 步骤 2：构建条件等价类 ──── */
  /* WHERE a = b AND b = 5 → a = 5, b = 5 的等价关系 */
  /* 存储在 COND_EQUAL 结构中，供 optimize_cond 内联 */

  /* ──── 步骤 3：简化条件表达式 ──── */
  /* WHERE 1=1 AND a > 0 → 简化为 a > 0 */
  /* WHERE a = a → 简化为 TRUE（如果 a 非 NULL）*/
  /* WHERE NULL = NULL → 简化为 FALSE */

  /* ──── 步骤 4：谓词下推 ──── */
  /* WHERE a > 10 AND a > 5 → 下推为 a > 10（更严格的条件）*/
}
```

**等价类传播的意义**：

```sql
SELECT * FROM t1 JOIN t2 ON t1.a = t2.b
WHERE t1.a = 5

→ 优化器推断出 t2.b = 5（等价类传递）
→ t2 也可以使用 b=5 做索引查找而不是全表扫描
→ 这在 JOIN 中节省了大量的嵌套循环次数
```

### 1.2 范围条件提取

```cpp
// sql/range_optimizer/
class SEL_ARG {
  /* 范围条件树：WHERE a > 5 AND a < 10 OR a IN (1, 2, 3) */
  /* → 树形结构表示多个范围的 OR/AND 组合 */
  SEL_ARG *left, *right;
  Field *field;
  SEL_ROOT *root;   /* 范围边界 */
};

/* 索引选择的最终结果：SimpleIndexRangeScan / GroupIndexRangeScan */
class IndexRangeScan {
  QUICK_RANGE *ranges;    /* 所有需要扫描的范围 */
  bool is_simple;         /* 是否单范围 */
};
```

**范围扫描的成本估算**：

```cpp
// 扫描行数估算
ha_rows check_quick_keys(...) {
  /* 1. 使用 records_in_range() 估算每个范围覆盖的行数 */
  /* 2. = 索引统计中的 (总行数 / 不同值的数量) */
  /* 3. 对于范围 WHERE a > 5 AND a < 10: */
  /*    = records_in_range(INDEX, 5, 10) 返回 (rows, rows) */
  /* 4. 对不同值合并并取平均 */
}
```

---

## 2. JOIN 顺序搜索

### 2.1 make_join_plan()

```cpp
// sql_planner.cc
bool JOIN::make_join_plan() {
  /* ──── 步骤 1：计算每个表的最优访问路径 ──── */
  /* 对 FROM 子句中的每个表，计算全表扫描、所有可能的索引扫描的成本 */
  /* 更新 join->best_ref[] 数组 */
  update_ref_and_keys();

  /* ──── 步骤 2：确定表的连接顺序 ──── */
  /* 使用贪心或穷举搜索找到成本最低的连接顺序 */
  bool straight_join = (join->select_lex->join_list_contains_sj);
  bool use_greedy = true;

  if (table_count > MAX_TABLES) {
    /* 表太多（> 61）→ 用贪心搜索 */
    greedy_search(join_table_count, ...);
  } else {
    /* 表较少 → 用穷举搜索找到最优解 */
    choose_plan();
  }

  /* ── 步骤 3：如果有半连接子查询 → 执行 semi-join 策略选择 ── */
  if (has_sj) {
    /* 尝试 Materialization / FirstMatch / LooseScan / DuplicateWeedout */
    /* 选择成本最低的半连接实现策略 */
  }

  return false;
}
```

### 2.2 best_access_path() — 单表最佳访问路径

```cpp
// sql_planner.cc
void best_access_path(JOIN *join, JOIN_TAB *tab, table_map remaining_tables,
                     uint idx, double record_count,
                     POSITION *pos, POSITION *loose_scan_pos) {

  Cost_estimate best_cost = MAX_COST;
  int best_idx = -1;

  /* ──── 检查全表扫描成本 ──── */
  best_cost = scan_time(record_count);          /* 全表扫描 = 页数 * io_cost + row_count * cpu_cost */
  best_idx = -1;                                 /* -1 = 全表扫描 */

  /* ──── 检查每个可用索引 ──── */
  for (uint i = 0; i < tab->table->s->keys; i++) {
    if (!usable_index(i, tab->table, remaining_tables)) continue;

    /* 估算使用该索引的成本 */
    Cost_estimate idx_cost = index_scan_cost(i, tab, record_count);

    if (idx_cost < best_cost && idx_cost != MAX_COST) {
      best_cost = idx_cost;
      best_idx = i;
    }
  }

  /* ──── 记录最佳选择 ──── */
  pos->cost = best_cost;
  pos->table = tab;
  pos->key = best_idx;
  pos->records_read = estimated_rows(best_idx, record_count);
  pos->loosescan_key = ...;
}
```

**成本估算公式**（简化）：

```
全表扫描成本 = pages × avg_io_cost + rows × cpu_row_cost
索引扫描成本 = (scan_depth × io_cost) + (matched_rows × cpu_row_cost)

其中:
  avg_io_cost: 磁盘随机/顺序读取页面代价（~1.0 per page）
  cpu_row_cost: 处理一行记录的代价（~0.2）
  scan_depth: B-Tree 深度（通常 2-4）
  matched_rows: 使用 records_in_range 估算
```

### 2.3 best_extension_by_limited_search() — 贪心扩展搜索

```cpp
// sql_planner.cc — 贪心搜索
void best_extension_by_limited_search(
    JOIN *join, table_map remaining_tables,
    uint idx, double record_count, double read_time,
    uint search_depth) {

  /* 对剩余的每个表，尝试作为下一个连接的表 */
  for (each table t in remaining_tables) {
    /* ──── 计算将表 t 加入当前部分计划的成本 ──── */
    POSITION pos;
    best_access_path(join, t, remaining_tables, idx,
                     record_count, &pos, ...);

    /* ──── 递归：继续扩展 ──── */
    best_extension_by_limited_search(
        join, remaining_tables & ~t.table_map,
        idx + 1, pos.records_read, pos.read_time, search_depth);

    /* ──── 跟踪全局最优 ──── */
    if (current_cost < optimal_cost) {
      memcpy(best_positions + idx, ...);
    }
  }
}
```

**搜索深度的含义**：

```
search_depth = 0 → 贪心（只考虑当前最佳下一步）
search_depth = 1 → 贪心（只考虑下一步）
search_depth = 61 → 穷举（尝试所有排列组合，最多 61 个表）

默认 search_depth = 62（穷举），但当表数 > 31 时退化为贪心。
因为 32! 种排列已经天文数字。
```

### 2.4 直连（straight_join）

```sql
SELECT STRAIGHT_JOIN * FROM t1, t2, t3 WHERE ...
```

当指定 `STRAIGHT_JOIN` 时，优化器**跳过**贪心/穷举搜索，直接使用 FROM 子句写的顺序：

```cpp
// sql_planner.cc
bool JOIN::make_join_plan() {
  if (select_lex->straight_join) {
    /* 跳过 choose_plan / greedy_search */
    /* 直接按表：t1, t2, t3 的原始顺序评估 */
    for (i = 0; i < table_count; i++) {
      best_access_path(join, join_tab[i], remaining_tables, ...);
    }
    return false;
  }
  ...
}
```

---

## 3. 子查询优化

### 3.1 flatten_subqueries()

```cpp
// sql_opt_cc — 子查询解嵌套
bool flatten_subqueries(THD *thd, SELECT_LEX_UNIT *unit) {

  for (SELECT_LEX *sl = unit->first_select();
       sl; sl = sl->next_select()) {

    if (sl->master_unit()->item) continue;
    if (sl->outer_join) continue;

    Item_subselect *subq_predicate = sl->item;
    if (!subq_predicate->can_be_flattened()) continue;

    /* ──── 尝试转换为半连接 ──── */
    /* WHERE a IN (SELECT b FROM t2) → semi-join(t1, t2) */

    if (convert_subquery_to_semijoin(thd, subq_predicate)) {
      /* 转换后，子查询变为 JOIN 的一部分 */
      sl->master_unit()->exclude_level();
      continue;
    }

    /* ──── 尝试子查询物化 ──── */
    /* WHERE a IN (SELECT b FROM t2) → 物化 t2 的结果 → hash 查找 */
    if (convert_subquery_to_materialization(thd, subq_predicate)) {
      ...
    }
  }

  return false;
}
```

可解嵌套的条件：

```sql
-- 可以解嵌套
SELECT * FROM t1 WHERE a IN (SELECT b FROM t2)  -- IN -> semi-join
SELECT * FROM t1 WHERE EXISTS (SELECT * FROM t2 WHERE t1.a = t2.b) -- EXISTS -> semi-join

-- 不能解嵌套
SELECT * FROM t1 WHERE (SELECT MAX(a) FROM t2) > 10   -- 标量子查询，不能展开
SELECT * FROM t1 WHERE a IN (SELECT b FROM t2 LIMIT 1) -- 有 LIMIT，不能展开
SELECT * FROM t1 WHERE a IN (SELECT SUM(b) FROM t2)    -- 聚合，不能展开
```

---

## 4. JOIN 算法选择

MySQL 8.0 支持多种 JOIN 算法：

| 算法 | 使用条件 | 内存 |
|------|---------|------|
| Nested Loop Join (NLJ) | 始终可用 | 无 |
| Block Nested Loop (BNL) | 8.0 之前 | join_buffer_size |
| Batched Key Access (BKA) | 需要 MRR | join_buffer_size |
| Hash Join | 8.0.18+ | join_buffer_size（内存不够 spill to disk） |

### 4.1 Hash Join 选择

```cpp
// sql_planner.cc — 判断是否使用 Hash Join
if (join_type == INNER_JOIN && !use_index && 
    join_tab->table->file->ha_table_flags() & HA_BLOCK_CURSOR) {
  /* INNER JOIN，没有合适的索引 → 尝试 Hash Join */
  hash_join_cost = estimate_hash_join_cost(left_rows, right_rows);
  if (hash_join_cost < nested_loop_cost) {
    pos->use_hash_join = true;
    pos->hash_join_build_size = min(left_rows, right_rows) * row_size;
  }
}
```

Hash Join 的阶段：

```
Phase 1 — Build:
  1. 加载较小的表（build table）的所有匹配行到 hash 表
  2. 使用 join key 作为 hash 键
  3. 如果 build table 很大，分成多个 chunk（spill to disk）

Phase 2 — Probe:
  1. 逐行扫描较大的表（probe table）
  2. 对每行计算 join key 的 hash
  3. 在 hash 表中查找匹配行
  4. 如果 spill to disk，将不匹配的行写入对应的 probe chunk
```

---

## 5. 执行计划生成

### 5.1 make_join_select()

```cpp
// sql_optimizer.cc
int JOIN::make_join_select() {
  /* ──── 步骤 1：确定每个 JOIN_TAB 要做的条件检查 ──── */
  for (i = join->join_tab; ...) {
    /* 将 WHERE 条件分配到能最早使用的表 */
    /* WHERE t1.a > 5 AND t2.b = 10 */
    /* → t1: a > 5, t2: b = 10 */
  }

  /* ──── 步骤 2：标记哪些条件是"马上可用"的 ──── */
  for (i = 0; i < join->tables; i++) {
    for (j = first_inner; j < i; j++) {
      /* 如果条件中所有相关表已经 join 完毕 → 下推 */
      push_cond_to_join_tab(join_tab[j], cond);
    }
  }

  /* ──── 步骤 3：选择 JOIN 算法 ──── */
  choose_join_algorithm();

  return 0;
}
```

### 5.2 示例执行计划生成

```sql
SELECT t1.a, t2.b
FROM t1 JOIN t2 ON t1.id = t2.t1_id
WHERE t1.c > 10 AND t2.d = 'x'
ORDER BY t1.a
LIMIT 10
```

优化结果：

```
1. 表顺序: t1 → t2 (通过贪心搜索，t1 先筛选)
2. t1 访问路径: 索引 idx_c → range [10, +∞) → ~100 行
3. t2 访问路径: 索引 idx_t1_id → ref(t1.id) → ~1 行/次
4. JOIN 算法: Nested Loop Join (内表有索引)
5. 排序: t1 的 idx_a 可提供有序输出（避免 filesort）
6. 使用索引覆盖: t1 只需读 a, c, id 三个列（如果索引包含）
   → 回表次数减少
```

---

## 6. 源码索引

| 函数/结构 | 文件 | 关键作用 |
|-----------|------|---------|
| `JOIN::optimize()` | `sql/sql_optimizer.cc` | 优化主入口 |
| `optimize_cond()` | `sql/sql_optimizer.cc` | 条件化简 |
| `make_join_plan()` | `sql/sql_planner.cc` | JOIN 计划生成 |
| `best_access_path()` | `sql/sql_planner.cc` | 单表最佳访问路径 |
| `best_extension_by_limited_search()` | `sql/sql_planner.cc` | 贪心搜索 |
| `greedy_search()` | `sql/sql_planner.cc` | 贪心搜索入口 |
| `choose_plan()` | `sql/sql_planner.cc` | 穷举搜索 |
| `flatten_subqueries()` | `sql/sql_opt_cc` | 子查询解嵌套 |
| `check_quick_keys()` | `sql/range_optimizer/` | 范围估算 |
| `SEL_ARG` | `sql/range_optimizer/` | 范围条件树 |
| `SEL_ROOT` | `sql/range_optimizer/` | 范围边界 |
