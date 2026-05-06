# 11-explain-execution-plan — MySQL EXPLAIN 与执行计划分析

## 0. 概述

MySQL 的 EXPLAIN 语句是性能分析的起点。它揭示了一条 SQL 语句将被如何执行：访问哪些表、用什么索引、以何种顺序连接、需要多少行估算等。本文从源码层面拆解 EXPLAIN 的工作原理，覆盖三种输出格式（Traditional / JSON / TREE），解析 AccessPath 这个内部执行计划表示结构，并通过 optimizer_trace 展示优化器的决策过程。

一条 SQL 从文本到 EXPLAIN 输出经历以下链路：

```
SQL text → parser → resolver → optimizer → AccessPath tree → EXPLAIN formatter → output
```

其中关键节点是：优化器生成一棵 **AccessPath 树**（执行计划的内核表示），然后 EXPLAIN 代码遍历这棵树，根据所选格式渲染输出。

---

## 1. EXPLAIN 内部实现

### 1.1 ExplainIterator() — EXPLAIN 入口

`opt_explain.cc:129` 的 `ExplainIterator()` 是新的迭代器风格 EXPLAIN 的入口。当用户执行 `EXPLAIN FORMAT=TREE` 或 `EXPLAIN FORMAT=JSON`（启用超图优化器时），走的是这条路。

```c
// opt_explain.cc:129
static bool ExplainIterator(THD *ethd, const THD *query_thd,
                            Query_expression *unit) {
  Query_result_send *result = nullptr;
  // ... 准备 result 对象 ...
  {
    std::string explain = PrintQueryPlan(ethd, query_thd, unit);
    // ... 发送到客户端 ...
  }
  return result->send_eof(ethd);
}
```

`ExplainIterator()` 的核心是调用 `PrintQueryPlan()`，后者在 `explain_access_path.cc:2208` 实现。如果是 EXPLAIN ANALYZE，还会先执行查询，然后打印出带实际行数和时间的计划。

老的传统格式入口是 `opt_explain.cc` 中的 `explain_query_specification()` （line ~1017），它使用 `Explain_join` / `Explain_table` 等类，迭代 QEP_TAB 数组而不是 AccessPath 树。

```sql
-- 传统格式 (Use FORMAT=TREE or FORMAT=JSON with hypergraph optimizer)
mysql> EXPLAIN FORMAT=TREE SELECT * FROM t1 JOIN t2 ON t1.id = t2.id\G
```

### 1.2 mysql_explain_query_expression() — 查询表达式入口

`mysql_explain_query_expression()`（`opt_explain.cc:114`）是任意查询表达式的 EXPLAIN 入口。它会判断单元是简单查询还是集合操作（UNION），然后分派到不同的处理路径：

```c
// opt_explain.cc:114
bool mysql_explain_query_expression(THD *explain_thd, const THD *query_thd,
                                    Query_expression *unit) {
  if (unit->is_simple())
    res = explain_query_specification(explain_thd, query_thd,
                                      unit->query_term(), CTX_JOIN);
  else
    res = unit->explain(explain_thd, query_thd);
  // ...
}
```

对于 UNION，`Query_expression::explain()` 会迭代每个 query block。对于简单的 SELECT，`explain_query_specification()` 根据 plan_state 分发：`ZERO_RESULT` 输出 "Impossible WHERE"；`NO_TABLES` 输出 "No tables used"；`PLAN_READY` 则创建 `Explain_join` 对象开始遍历 QEP_TAB。

### 1.3 Explain_format 三子类：Traditional / JSON / TREE

`Explain_format` 是抽象基类（`opt_explain_format.h`），定义三个关键虚函数：

```c
// opt_explain_format.h
class Explain_format {
 public:
  virtual bool is_hierarchical() const = 0;
  virtual bool is_iterator_based(THD *explain_thd, const THD *query_thd) const;
  virtual bool begin_context(enum_parsing_context context,
                             Query_expression *subquery = nullptr,
                             const Explain_format_flags *flags = nullptr) = 0;
  virtual bool end_context(enum_parsing_context context) = 0;
  virtual bool flush_entry() = 0;
  virtual qep_row *entry() = 0;
};
```

三个具体子类：

| 子类 | 文件 | is_hierarchical | is_iterator_based | 备注 |
|------|------|----------------|-------------------|------|
| `Explain_format_traditional` | `opt_explain_traditional.cc` | false | false | 旧格式，遍历 QEP_TAB |
| `Explain_format_json` | `opt_explain_json.cc` | true | 旧:false / 新:true | 老 JSONv1 / 新 JSONv2 |
| `Explain_format_tree` | `explain_access_path.cc` | true | true | TREE 格式 |

传统格式输出表格化的 plan（id / select_type / table / type / key / ref / rows / Extra），每行对应一个 QEP_TAB：

```c
// opt_explain_traditional.cc（节选）
static const char *traditional_extra_tags[ET_total] = {
    nullptr,                            // ET_none
    "Using temporary",                  // ET_USING_TEMPORARY
    "Using filesort",                   // ET_USING_FILESORT
    "Using index condition",            // ET_USING_INDEX_CONDITION
    "Using",                            // ET_USING
    "Range checked for each record",    // ET_RANGE_CHECKED_FOR_EACH_RECORD
    "Using where",                      // ET_USING_WHERE
    // ...
};
```

JSON 格式输出层次化的 JSON。TREE 格式（`Explain_format_tree`）将 JSON 对象渲染为缩进的文本树：

```c
// explain_access_path.cc:2357
void Explain_format_tree::ExplainPrintTreeNode(const Json_dom *json, int level,
                                               string *explain, ...) {
  explain->append(level * 4, ' ');
  *explain += "-> ";
  *explain += down_cast<Json_string *>(obj->get("operation"))->value();
  ExplainPrintCosts(obj, explain);
  *explain += children_explain;
}
```

TREE 格式的输出如：

```
-> Nested loop inner join  (cost=1.1 rows=5)
    -> Index scan on t1 using PRIMARY  (cost=0.35 rows=2)
    -> Index lookup on t2 using idx_t2_id (id = t1.id)  (cost=0.35 rows=2)
```

### 1.4 AccessPath → 各 format 的输出路径

对于迭代器格式（TREE / 新 JSON），输出路径为：

```
AccessPath tree → ExplainAccessPath(path=root_access_path, ...)
  → SetObjectMembers() 遍历每个 AccessPath::Type
    → 生成 Json_object（包含 "operation", "access_type", 特定字段）
    → 递归处理 children
  → 最后通过 Explain_format_tree::ExplainJsonToString() 或 JSON 序列化输出
```

对于传统格式，输出路径不同：

```
JOIN::qep_tab[] → Explain_join::shallow_explain()
  → 对每个 QEP_TAB 调用 explain_qep_tab()
    → prepare_columns() → explain_join_type(), explain_key_and_len(), ...
    → fmt->flush_entry() 输出一行
```

---

## 2. AccessPath — 执行计划的内部表示

### 2.1 struct AccessPath（access_path.h:57）

`AccessPath` 是 MySQL 8.0+ 迭代器执行引擎的核心计划结构。它本质上是一个 tagged union（类型安全的联合体），用单一 `struct AccessPath` + 匿名 union 来表示所有可能的计划节点。

```c
// access_path.h:57
struct AccessPath {
  enum Type : uint8_t { /* 见 2.2 */ } type;
  Safety safe_for_rowid;        // 行 ID 安全性
  bool count_examined_rows;     // 是否计入 examined_rows
  int ordering_state;           // 输出顺序
  RowIterator *iterator;        // 已实例化的迭代器（EXPLAIN ANALYZE 用）

  // 成本估计
  double cost() const;          // 总成本
  double init_cost() const;     // 初始化成本
  double first_row_cost() const; // 首行成本
  double num_output_rows() const; // 输出行数估计

  union {
    struct { TABLE *table; } table_scan;
    struct { TABLE *table; int idx; ... } index_scan;
    struct { TABLE *table; Index_lookup *ref; ... } ref;
    struct { TABLE *table; Index_lookup *ref; } eq_ref;
    struct { AccessPath *outer, *inner; } nested_loop_join;
    struct { AccessPath *outer, *inner; } hash_join;
    struct { AccessPath *child; Item *condition; } filter;
    struct { AccessPath *child; Filesort *filesort; } sort;
    // ... 30+ 种类型
  } u;
};
```

AccessPath 设计为一个 152 字节的固定大小结构（`access_path.h:350`），避免动态分配的开销。每个 type 对应 union 中不同的成员字段。

### 2.2 AccessPathType 枚举（access_path.h:243-290）

所有 AccessPath 类型按功能分组：

```c
// access_path.h:243
enum Type : uint8_t {
  // 基础访问路径（叶子节点）
  TABLE_SCAN,               // 全表扫描
  SAMPLE_SCAN,              // 表采样（TABLESAMPLE）
  INDEX_SCAN,               // 全索引扫描
  INDEX_DISTANCE_SCAN,      // 向量距离扫描
  REF,                      // 非唯一索引等值查找
  REF_OR_NULL,              // ref + IS NULL 回退
  EQ_REF,                   // 唯一索引等值查找
  PUSHED_JOIN_REF,          // 引擎下推的 join ref
  FULL_TEXT_SEARCH,         // 全文检索
  CONST_TABLE,              // 常数表（最多一行）
  MRR,                      // Multi-Range Read
  FOLLOW_TAIL,              // 追踪新记录（CTE）
  INDEX_RANGE_SCAN,         // 索引范围扫描
  INDEX_MERGE,              // 索引合并
  ROWID_INTERSECTION,       // RowID 交集
  ROWID_UNION,              // RowID 并集
  INDEX_SKIP_SCAN,          // 索引跳跃扫描
  GROUP_INDEX_SKIP_SCAN,    // GROUP BY 跳跃扫描
  DYNAMIC_INDEX_RANGE_SCAN, // 动态重规划的范围扫描

  // 非表基础路径
  TABLE_VALUE_CONSTRUCTOR,  // VALUES 行构造器
  FAKE_SINGLE_ROW,          // 单行（无表）
  ZERO_ROWS,                // 已知零行
  ZERO_ROWS_AGGREGATED,     // 零行聚合后一行
  MATERIALIZED_TABLE_FUNCTION, // 表函数物化
  UNQUALIFIED_COUNT,        // COUNT(*) 优化

  // 连接
  NESTED_LOOP_JOIN,                   // 嵌套循环连接
  NESTED_LOOP_SEMIJOIN_WITH_DUPLICATE_REMOVAL, // 半连接去重
  BKA_JOIN,                           // Batched Key Access
  HASH_JOIN,                          // 哈希连接

  // 组合路径
  FILTER,                       // 过滤
  SORT,                         // 排序
  AGGREGATE,                    // 流式聚合
  TEMPTABLE_AGGREGATE,          // 临时表聚合
  LIMIT_OFFSET,                 // LIMIT/OFFSET
  STREAM,                       // 流式结果
  MATERIALIZE,                  // 物化（派生表/CTE）
  MATERIALIZE_INFORMATION_SCHEMA_TABLE, // I_S 表填充
  APPEND,                       // UNION ALL
  WINDOW,                       // 窗口函数
  WEEDOUT,                      // Duplicate Weedout
  REMOVE_DUPLICATES,            // 去重
  REMOVE_DUPLICATES_ON_INDEX,   // 基于索引去重
  ALTERNATIVE,                  // 二选一回退
  CACHE_INVALIDATOR,            // 缓存失效器

  DELETE_ROWS,                  // 删除
  UPDATE_ROWS,                  // 更新
};
```

### 2.3 各 AccessPath 的 type 特定字段

每种 type 对应 union 中不同的结构体。以下是几种关键类型的字段：

**TABLE_SCAN** — `access_path.h:u.table_scan`
```c
struct {
  TABLE *table;
} table_scan;
```
最简单的类型：只需要一个 TABLE 指针。

**REF / EQ_REF** — `access_path.h:u.ref` / `u.eq_ref`
```c
struct {
  TABLE *table;
  Index_lookup *ref;    // 查找描述（key, key_parts, key_copy）
  bool use_order;       // 是否保持索引顺序
  bool reverse;         // 反向扫描
} ref;

struct {
  TABLE *table;
  Index_lookup *ref;    // 唯一查找（保证最多一行）
} eq_ref;
```

**INDEX_RANGE_SCAN** — `access_path.h:u.index_range_scan`
```c
struct {
  KEY_PART *used_key_part;
  QUICK_RANGE **ranges;
  unsigned num_ranges;
  unsigned mrr_flags, mrr_buf_size;
  unsigned index;
  unsigned num_used_key_parts;
  bool can_be_used_for_ror;
  bool reverse;
  // ...
} index_range_scan;
```

**NESTED_LOOP_JOIN** — `access_path.h:u.nested_loop_join`
```c
struct {
  AccessPath *outer, *inner;
  JoinType join_type;           // INNER / OUTER / SEMI / ANTI
  const JoinPredicate *join_predicate;
  OverflowBitset equijoin_predicates;
} nested_loop_join;
```

**HASH_JOIN** — `access_path.h:u.hash_join`
```c
struct {
  AccessPath *outer, *inner;
  const JoinPredicate *join_predicate;
  bool allow_spill_to_disk;
  bool rewrite_semi_to_inner;
  // ...
} hash_join;
```

**FILTER** — `access_path.h:u.filter`
```c
struct {
  AccessPath *child;
  Item *condition;
  bool materialize_subqueries;
} filter;
```

**SORT** — `access_path.h:u.sort`
```c
struct {
  AccessPath *child;
  Filesort *filesort;
  ORDER *order;
  ha_rows limit;
  bool remove_duplicates;
  // ...
} sort;
```

---

## 3. EXPLAIN 输出详解

### 3.1 Traditional 格式

传统格式的输出是一个表格，每一行的列如下：

```sql
mysql> EXPLAIN SELECT * FROM t1 WHERE id = 1\G
*************************** 1. row ***************************
           id: 1
  select_type: SIMPLE
        table: t1
   partitions: NULL
         type: const
possible_keys: PRIMARY
          key: PRIMARY
      key_len: 4
          ref: const
         rows: 1
     filtered: 100.00
        Extra: NULL
```

各列含义：

| 列 | 来源 | 说明 |
|----|------|------|
| `id` | `Explain::explain_id()` (`opt_explain.cc:1230`) | SELECT 序号，数值越大优先级越高 |
| `select_type` | `Explain::explain_select_type()` (`opt_explain.cc:1239`) | SIMPLE / PRIMARY / UNION / DERIVED / SUBQUERY 等 |
| `table` | `Explain_join::explain_table_name()` (`opt_explain.cc:751`) | 表名，派生表用 `<derivedN>` |
| `partitions` | `Explain_table_base::explain_partitions()` (`opt_explain.cc:598`) | 匹配的分区 |
| `type` | `Explain_join::explain_join_type()` (`opt_explain.cc:772`) | 访问类型，见 `join_type_str[]` |
| `possible_keys` | `Explain_table_base::explain_possible_keys()` (`opt_explain.cc:605`) | 候选索引 |
| `key` | `Explain_join::explain_key_and_len()` (`opt_explain.cc:797`) | 实际使用的索引 |
| `key_len` | 同上 | 索引使用的字节数 |
| `ref` | `Explain_join::explain_ref()` (`opt_explain.cc:812`) | 索引查找的参照列/常量 |
| `rows` | `Explain_join::explain_rows_and_filtered()` (`opt_explain.cc:817`) | 估计扫描行数 |
| `filtered` | 同上 | 经过条件过滤后剩余行的百分比 |
| `Extra` | `Explain_join::explain_extra()` (`opt_explain.cc:846`) | 补充信息 |

**type 列** 的值定义在 `opt_explain.cc:53`：

```c
const char *join_type_str[] = {
    "UNKNOWN", "system", "const",    "eq_ref",      "ref",        "ALL",
    "range",   "index",  "fulltext", "ref_or_null", "index_merge"};
```

按性能从好到差排列：**system > const > eq_ref > ref > range > index > ALL**。

**Extra 列** 的重要值：

```c
// opt_explain_traditional.cc
static const char *traditional_extra_tags[ET_total] = {
    "Using temporary",         // 使用了临时表
    "Using filesort",          // 需要外部排序
    "Using index condition",   // ICP（索引条件下推）
    "Using where",             // 有 WHERE 过滤
    "Using index",             // 覆盖索引
    "Backward index scan",     // 反向扫描
    "Using index for group-by",// 松散索引扫描用于 GROUP BY
    // ...
};
```

### 3.2 JSON 格式

`EXPLAIN FORMAT=JSON` 输出的结构在 `explain_access_path.cc` 中构建。核心是 `ExplainAccessPath()`（`explain_access_path.cc:2077`）：

```c
static unique_ptr<Json_object> ExplainAccessPath(
    const AccessPath *path, const AccessPath *materialized_path, JOIN *join,
    bool is_root_of_join, unique_ptr<Json_object> root_obj) {
  // ...
  root_obj = SetObjectMembers(std::move(root_obj), path, materialized_path,
                              join, &children);
  // ...
  if (AddChildrenToObject(original_object, std::move(children), join,
                          delayed_root_of_join, "inputs")) { ... }
  return root_obj;
}
```

`SetObjectMembers()`（`explain_access_path.cc:1177`）通过 switch 语句处理每个 AccessPath type，调用 `AddMemberToObject` 填充 JSON 字段。

JSON 格式的关键特性：
- 使用 `"access_type"` 标识节点类型（`"table"`, `"index"`, `"join"`, `"filter"`, `"sort"` 等）
- 使用 `"inputs"` 数组表示子节点
- 包含完整的成本信息（`"cost"`, `"rows"`, `"loops"` — EXPLAIN ANALYZE）
- 包含 `"condition"`, `"join_type"`, `"join_algorithm"` 等精细化信息

示例输出结构：

```json
{
  "query_plan": {
    "operation": "Nested loop inner join",
    "access_type": "join",
    "join_type": "inner join",
    "join_algorithm": "nested_loop",
    "inputs": [
      {
        "operation": "Index scan on t1 using PRIMARY",
        "access_type": "index",
        "index_access_type": "index_scan",
        "table_name": "t1",
        "index_name": "PRIMARY",
        "cost": 0.35,
        "rows": 2
      },
      {
        "operation": "Index lookup on t2 using idx_t2_id (id = t1.id)",
        "access_type": "index",
        "index_access_type": "index_lookup",
        "table_name": "t2",
        "index_name": "idx_t2_id",
        "lookup_condition": "id = t1.id"
      }
    ]
  }
}
```

### 3.3 TREE 格式

`EXPLAIN FORMAT=TREE` 将内部 JSON 对象渲染为人类可阅读的文本树。实现在 `Explain_format_tree::ExplainPrintTreeNode()`（`explain_access_path.cc:2357`）。

```c
void Explain_format_tree::ExplainPrintTreeNode(const Json_dom *json, int level,
                                               string *explain, ...) {
  explain->append(level * 4, ' ');   // 缩进
  *explain += "-> ";                  // 节点标记
  *explain += operation_string;      // 操作描述
  ExplainPrintCosts(obj, explain);   // 成本
  *explain += children_explain;      // 递归子节点
}
```

TREE 格式的例子：

```sql
mysql> EXPLAIN FORMAT=TREE
  SELECT * FROM t1 JOIN t2 ON t1.id = t2.id WHERE t1.val > 10\G
*************************** 1. row ***************************
EXPLAIN:
-> Nested loop inner join  (cost=2.15 rows=5)
    -> Filter: (t1.val > 10)  (cost=0.85 rows=2)
        -> Index scan on t1 using idx_t1_val  (cost=0.55 rows=10)
    -> Index lookup on t2 using idx_t2_id (id = t1.id)  (cost=0.65 rows=2)
```

每行显示：
- 缩进层级表示树深度
- `->` 标记节点
- 操作描述（Scan / Lookup / Filter / Join 等）
- 括号中的 `cost=N rows=N loops=N`（EXPLAIN ANALYZE 有实际值）

---

## 4. 常见执行计划类型

### 4.1 const / system — 常数查找

当表最多返回一行（PRIMARY KEY 或 UNIQUE 等值查找），MySQL 会将这行数据当成常量折叠进计划：

```sql
mysql> EXPLAIN SELECT * FROM t WHERE id = 100\G
*************************** 1. row ***************************
         type: const
          key: PRIMARY
          ref: const
         rows: 1
```

源码中 `CONST_TABLE` AccessPath 的处理（`explain_access_path.cc`）：

```c
// explain_access_path.cc (SetObjectMembers)
case AccessPath::CONST_TABLE: {
  const TABLE &table = *path->const_table().table;
  description = string("Constant row from ") + table.alias;
  error |= AddMemberToObject<Json_string>(obj, "access_type", "constant_row");
  error |= AddTableInfoToObject(obj, &table);
  break;
}
```

`system` 是 `const` 的变体，表只有一行（如系统表）。两者的 AccessPath 类型一致，仅在输出的 `join_type_str` 中区分。

### 4.2 eq_ref — 唯一索引等值查找

出现在 JOIN 中，内表有 UNIQUE 或 PRIMARY KEY 索引，且外表提供等值条件。保证每行在外表最多匹配一行。

```sql
mysql> EXPLAIN SELECT * FROM t1 JOIN t2 ON t1.id = t2.id\G
*************************** 1. row ***************************
         type: eq_ref
          key: PRIMARY
          ref: test.t1.id
```

AccessPath 处理：

```c
// explain_access_path.cc (SetObjectMembers)
case AccessPath::EQ_REF: {
  const TABLE &table = *path->eq_ref().table;
  const KEY &key = table.key_info[path->eq_ref().ref->key];
  error |= SetIndexInfoInObject(
      &description, path, "index_lookup", "Single-row", table, key,
      "lookup", path->eq_ref().ref, ...);
  break;
}
```

`SetIndexInfoInObject()`（`explain_access_path.cc:306`）生成描述文本和 JSON 字段：

```c
// explain_access_path.cc:306
static bool SetIndexInfoInObject(string *str, const AccessPath *path,
                                 const char *json_index_access_type,
                                 const char *prefix, const TABLE &table,
                                 const KEY &key, const char *index_access_type,
                                 ...) {
  // 生成类似 "Single-row index lookup on t2 using PRIMARY (t1.id)"
  *str += (prefix ? string(prefix) + " " : "") + ... +
          index_access_type + " on " + table.alias + " using " + key.name +
          (!lookup_condition.empty() ? " (" + lookup_condition + ")" : "");
  // 添加 JSON 字段
  error |= AddMemberToObject<Json_string>(obj, "access_type", "index");
  error |= AddMemberToObject<Json_string>(obj, "index_access_type",
                                          json_index_access_type);
  // ...
}
```

### 4.3 ref — 非唯一索引等值查找

与 eq_ref 相似，但索引不唯一，可能返回多行。

```sql
mysql> EXPLAIN SELECT * FROM t1 WHERE name = 'alice'\G
*************************** 1. row ***************************
         type: ref
          key: idx_name
          ref: const
         rows: 3
```

AccessPath 对应的 `REF` 类型：

```c
// access_path.h:u.ref
struct {
  TABLE *table;
  Index_lookup *ref;
  bool use_order;
  bool reverse;
} ref;
```

### 4.4 range — 索引范围扫描

使用索引扫描一个范围（`BETWEEN`、`>`、`<`、`IN` 列表）：

```sql
mysql> EXPLAIN SELECT * FROM t1 WHERE id BETWEEN 10 AND 20\G
*************************** 1. row ***************************
         type: range
          key: PRIMARY
         rows: 11
```

`INDEX_RANGE_SCAN` AccessPath 的处理涉及范围打印：

```c
// explain_access_path.cc:SetObjectMembers()
case AccessPath::INDEX_RANGE_SCAN: {
  const auto &param = path->index_range_scan();
  const TABLE &table = *param.used_key_part[0].field->table;
  const KEY &key_info = table.key_info[param.index];

  unique_ptr<Json_array> range_arr(new (std::nothrow) Json_array());
  string ranges;
  error |= PrintRanges(param.ranges, param.num_ranges, key_info.key_part,
                       false, range_arr, &ranges);

  error |= SetIndexInfoInObject(
      &description, path, "index_range_scan", nullptr, table, key_info,
      "range scan", nullptr, &ranges, std::move(range_arr),
      path->index_range_scan().reverse, table.file->pushed_idx_cond, obj);
  break;
}
```

`PrintRanges()`（`explain_access_path.cc:890`）将 `QUICK_RANGE` 数组转为文本形式，并在超过 3 个范围时截断显示 `"(N more)"`。

### 4.5 index — 索引全扫描

遍历整个索引，比全表扫描好（因为索引通常比表小），但仍需避免：

```sql
mysql> EXPLAIN SELECT COUNT(*) FROM t1\G
*************************** 1. row ***************************
         type: index
          key: PRIMARY
         Extra: Using index
```

如果 Extra 出现 "Using index"，说明是覆盖索引扫描。

### 4.6 ALL — 全表扫描（最需要避免的）

```sql
mysql> EXPLAIN SELECT * FROM t1 WHERE name = 'alice'\G
*************************** 1. row ***************************
         type: ALL
          rows: 1000000
     filtered: 10.00
         Extra: Using where
```

`TABLE_SCAN` AccessPath 的处理：

```c
case AccessPath::TABLE_SCAN: {
  const TABLE &table = *path->table_scan().table;
  description += string("Table scan on ") + table.alias;
  error |= AddTableInfoToObject(obj, &table);
  error |= AddMemberToObject<Json_string>(obj, "access_type", "table");
  break;
}
```

### 4.7 Using index（覆盖索引）

当查询的所有列都包含在索引中时，不需要回表：

```sql
mysql> EXPLAIN SELECT id, name FROM t1 WHERE name = 'alice'\G
*************************** 1. row ***************************
         Extra: Using index
```

`idx_name(name, id)` 是一个覆盖索引。判断逻辑在 `explain_access_path.cc:372`：

```c
static bool IsCoveringIndexScan(const KEY &key, const TABLE &table) {
  return !table.no_keyread && table.covering_keys.is_set(&key - table.key_info);
}
```

### 4.8 Using filesort

查询需要额外的排序操作（无法使用索引顺序）：

```sql
mysql> EXPLAIN SELECT * FROM t1 ORDER BY name\G
*************************** 1. row ***************************
         Extra: Using filesort
```

`SORT` AccessPath 的处理：

```c
// explain_access_path.cc:SetObjectMembers()
case AccessPath::SORT: {
  description = "Sort: ";
  unique_ptr<Json_array> sort_fields(new (std::nothrow) Json_array());
  for (ORDER *order = path->sort().order; order; order = order->next) {
    if (order != path->sort().order) description += ", ";
    string sort_field = ItemToString(*order->item);
    if (order->direction == ORDER_DESC) sort_field += " DESC";
    description += sort_field;
    error |= AddElementToArray<Json_string>(sort_fields, sort_field);
  }
  children->push_back({path->sort().child});
  break;
}
```

### 4.9 Using temporary

查询需要创建临时表（常见于 GROUP BY、DISTINCT、子查询物化）：

```sql
mysql> EXPLAIN SELECT DISTINCT name FROM t1 ORDER BY id\G
*************************** 1. row ***************************
         Extra: Using temporary; Using filesort
```

---

## 5. optimizer_trace — 优化器决策过程

### 5.1 启用和使用

```sql
-- 启用跟踪
SET optimizer_trace='enabled=on';

-- 执行查询
SELECT * FROM t1 JOIN t2 ON t1.id = t2.id WHERE t1.val > 10;

-- 查看跟踪
SELECT * FROM information_schema.OPTIMIZER_TRACE\G

-- 关闭跟踪
SET optimizer_trace='enabled=off';
```

optimizer_trace 的基础设施在 `opt_trace.h` 和 `opt_trace_context.h` 中定义。核心类包括：

```c
// opt_trace_context.h
class Opt_trace_context {
  // 每个 THD 一个实例
  bool start(...);
  void end();
  bool is_started() const;
};
```

`Opt_trace_object` 和 `Opt_trace_array` 使用 RAII 管理跟踪的 JSON 结构：

```c
// opt_trace.h:Opt_trace_struct
class Opt_trace_struct {
 protected:
  Opt_trace_struct(Opt_trace_context *ctx_arg, bool requires_key_arg,
                   const char *key, feature_value feature);
  ~Opt_trace_struct();

 public:
  Opt_trace_struct &add_alnum(const char *key, const char *value);
  Opt_trace_struct &add_utf8(const char *key, const char *value,
                              size_t val_length);
  Opt_trace_struct &add(double value);
  Opt_trace_struct &add(ulonglong value);
  // ...
};
```

### 5.2 跟踪信息解读

典型的 optimizer_trace 包含以下顶级键：

```json
{
  "steps": [
    {
      "join_preparation": {
        "select#": 1,
        "steps": [...]
      }
    },
    {
      "join_optimization": {
        "select#": 1,
        "steps": [
          {
            "condition_processing": {
              "condition": "WHERE",
              "original_condition": "(`t1`.`val` > 10)",
              "steps": [
                {
                  "transformation": "equality_propagation",
                  "resulting_condition": "(`t1`.`val` > 10)"
                },
                {
                  "transformation": "constant_propagation",
                  "resulting_condition": "(`t1`.`val` > 10)"
                }
              ]
            }
          },
          {
            "table_scan_estimates": {
              "rows": 1000,
              "cost": 100
            }
          },
          {
            "considered_execution_plans": [
              {
                "plan_prefix": [],
                "table": "`t1`",
                "best_access_path": {
                  "considered_access_paths": [
                    {
                      "access_type": "index",
                      "index": "idx_t1_val",
                      "rows": 20,
                      "cost": 10,
                      "chosen": true
                    }
                  ]
                }
              }
            ]
          }
        ]
      }
    },
    {
      "join_execution": {
        "select#": 1,
        "steps": [...]
      }
    }
  ]
}
```

重要部分包括：
- **`condition_processing`** — 条件优化（等值传播、常量折叠等）
- **`table_scan_estimates`** — 全表扫描的成本估计（作为 baseline）
- **`considered_execution_plans`** — 优化器考虑过的所有计划
- **`best_access_path`** — 每个表最终选择的访问路径

### 5.3 为什么优化器选了这个计划而不是另一个？

通过 `considered_execution_plans` 可以看到所有候选方案及其成本。例如一个三表 JOIN，优化器可能考虑了 6 种不同的连接顺序，最终选择成本最低的那个。

```json
"considered_execution_plans": [
  {
    "plan_prefix": ["t1"],
    "table": "`t2`",
    "best_access_path": {
      "considered_access_paths": [
        {"access_type": "ref", "index": "idx_t2_id", "rows": 5, "cost": 2.5, "chosen": true},
        {"access_type": "scan", "rows": 100, "cost": 50, "chosen": false}
      ]
    },
    "cost_for_plan": 12.5,
    "rows_for_plan": 5
  },
  {
    "plan_prefix": ["t2"],
    "table": "`t1`",
    "best_access_path": {
      "considered_access_paths": [
        {"access_type": "scan", "rows": 1000, "cost": 100, "chosen": true}
      ]
    },
    "cost_for_plan": 150,
    "rows_for_plan": 1000
  }
]
```

优化器选择第一个计划（`t1` → `t2` via ref），因为成本 12.5 远低于第二个的 150。

---

## 6. EXPLAIN 实战诊断

### 6.1 慢查询分析流程

遇到慢查询的标准分析流程：

1. 运行 `EXPLAIN FORMAT=TREE <query>`
2. 检查 type 列：`ALL` 或 `index` 通常意味着缺少索引
3. 检查 rows 列：估计扫描行数是否远超预期
4. 检查 Extra 列：`Using filesort` / `Using temporary` 是常见瓶颈
5. 检查 key 列：是否使用了预期的索引
6. 运行 `EXPLAIN FORMAT=JSON` 查看详细的成本分析
7. 如有必要，启用 `optimizer_trace` 查看优化器的决策过程

### 6.2 索引选择性判断

```sql
-- 假设表有 100 万行，name 列的选择性
mysql> SELECT COUNT(DISTINCT name) / COUNT(*) AS selectivity FROM t1;
+-------------+
| selectivity |
+-------------+
|     0.0001  |  -- 非常差，只有 0.01%
+-------------+

mysql> EXPLAIN SELECT * FROM t1 WHERE name = 'alice'\G
*************************** 1. row ***************************
         type: ALL
         rows: 1000000
         Extra: Using where
```

选择性差意味着 MySQL 认为走索引不如全表扫描更划算。如果选择性提高（例如 10%+），优化器会更倾向于使用索引。

```sql
-- 选择性好的列
mysql> SELECT COUNT(DISTINCT id) / COUNT(*) FROM t1;
+-------------+
| selectivity |
+-------------+
|     1.0000  |  -- 100%，唯一
+-------------+

mysql> EXPLAIN SELECT * FROM t1 WHERE id = 100\G
*************************** 1. row ***************************
         type: const
          key: PRIMARY
         rows: 1
```

### 6.3 连接顺序对性能的影响

```sql
-- 查询三表 JOIN
mysql> EXPLAIN FORMAT=TREE
  SELECT * FROM t1 JOIN t2 ON t1.a = t2.a
                    JOIN t3 ON t2.b = t3.b\G
*************************** 1. row ***************************
EXPLAIN:
-> Nested loop inner join  (cost=5.5 rows=20)
    -> Nested loop inner join  (cost=2.5 rows=10)
        -> Table scan on t1  (cost=0.35 rows=5)
        -> Index lookup on t2 using idx_t2_a (a = t1.a)  (cost=0.425 rows=2)
    -> Index lookup on t3 using idx_t3_b (b = t2.b)  (cost=0.3 rows=2)
```

优化器选择了 `t1 → t2 → t3` 的顺序，因为 `t1` 最小（5 行），`t2` 可通过索引快速查找。如果优化器选了 `t3 → t2 → t1` 且 `t3` 很大，性能会差很多。

### 6.4 子查询与外连接转换

```sql
-- IN 子查询可能被转换为半连接（semi-join）
mysql> EXPLAIN FORMAT=TREE
  SELECT * FROM t1 WHERE id IN (SELECT id FROM t2)\G
*************************** 1. row ***************************
EXPLAIN:
-> Nested loop inner join  (cost=2.5 rows=10)
    -> Table scan on t1  (cost=0.35 rows=5)
    -> Index lookup on t2 using PRIMARY (id = t1.id)  (cost=0.425 rows=2)
```

优化器自动将 `IN (subquery)` 转换为半连接。如果转换失败，子查询会被物化：

```c
// opt_explain.cc:1149 (子查询物化时)
if (unit->item &&
    (unit->item->engine_type() == Item_subselect::HASH_SJ_ENGINE)) {
  fmt->entry()->is_materialized_from_subquery = true;
  fmt->entry()->col_table_name.set_const("<materialized_subquery>");
  fmt->entry()->col_join_type.set_const(join_type_str[unit->item->get_join_type()]);
  fmt->entry()->col_key.set_const("<auto_key>");
  // ...
}
```

### 6.5 实战案例

**案例：ORDER BY 导致 filesort，但完全可以通过索引消除**

```sql
-- 慢查询：10 秒
mysql> SELECT * FROM orders WHERE status = 'PAID' ORDER BY created_at DESC LIMIT 100;

-- 当前 EXPLAIN
mysql> EXPLAIN FORMAT=TREE
  SELECT * FROM orders WHERE status = 'PAID' ORDER BY created_at DESC LIMIT 100\G
*************************** 1. row ***************************
EXPLAIN:
-> Limit: 100 row(s)  (cost=10500 rows=100)
    -> Sort: orders.created_at DESC  (cost=10500 rows=100000)
        -> Filter: (orders.status = 'PAID')  (cost=10500 rows=100000)
            -> Table scan on orders  (cost=10500 rows=1000000)

-- optimizer_trace 显示优化器只考虑了全表扫描后排序
```

分析：全表扫描 + filesort，`created_at` 无法利用索引排序因为 `status` 过滤在后面。

**解决方案**：创建覆盖索引 `(status, created_at)`

```sql
CREATE INDEX idx_status_created ON orders(status, created_at);

-- 再次 EXPLAIN
mysql> EXPLAIN FORMAT=TREE
  SELECT * FROM orders WHERE status = 'PAID' ORDER BY created_at DESC LIMIT 100\G
*************************** 1. row ***************************
EXPLAIN:
-> Limit: 100 row(s)  (cost=10.5 rows=100)
    -> Index lookup on orders using idx_status_created (status='PAID')  (cost=10.5 rows=100000)
```

现在 `status = 'PAID'` 通过 ref 查找，且索引顺序天然匹配 `ORDER BY created_at`，filesort 消失。

---

## 7. 关键函数索引

| 函数 | 文件 | 行号 | 作用 |
|------|------|------|------|
| `mysql_explain_query_expression()` | `opt_explain.cc` | 114 | EXPLAIN 入口，分发到简单查询或集合操作 |
| `ExplainIterator()` | `opt_explain.cc` | 129 | 迭代器格式 EXPLAIN 入口 |
| `explain_query_specification()` | `opt_explain.cc` | 1017 | 执行计划渲染，按 plan_state 分发 |
| `Explain::shallow_explain()` | `opt_explain.cc` | 1131 | 调用 `prepare_columns()` → 各 explain_*() |
| `Explain_join::shallow_explain()` | `opt_explain.cc` | 475 | JOIN 的 EXPLAIN 主体，遍历 QEP_TAB |
| `Explain_join::explain_qep_tab()` | `opt_explain.cc` | 661 | 解释单个 QEP_TAB（一行输出） |
| `Explain_join::explain_join_type()` | `opt_explain.cc` | 772 | 输出 type 列（const/ref/all 等） |
| `Explain_join::explain_extra()` | `opt_explain.cc` | 846 | 输出 Extra 列 |
| `Explain_format::send()` | `opt_explain.cc` | 1182 | 顶层发送函数 |
| `Explain_format_traditional::send_headers()` | `opt_explain_traditional.cc` | 72 | 传统格式发送表头 |
| `PrintQueryPlan()` | `explain_access_path.cc` | 2208 | 迭代器格式的 EXPLAIN 主函数 |
| `ExplainAccessPath()` | `explain_access_path.cc` | 2077 | 递归构建 JSON 计划树 |
| `SetObjectMembers()` | `explain_access_path.cc` | 1177 | 根据 AccessPath 类型设置 JSON 字段 |
| `SetIndexInfoInObject()` | `explain_access_path.cc` | 306 | 索引访问的 JSON 字段填充 |
| `ExplainMaterializeAccessPath()` | `explain_access_path.cc` | 459 | 物化节点的 EXPLAIN |
| `ExplainIndexSkipScanAccessPath()` | `explain_access_path.cc` | 783 | 索引跳跃扫描的 EXPLAIN |
| `PrintRanges()` | `explain_access_path.cc` | 890 | 范围打印 |
| `Explain_format_tree::ExplainPrintTreeNode()` | `explain_access_path.cc` | 2357 | TREE 格式格式化 |
| `Explain_format_tree::ExplainPrintCosts()` | `explain_access_path.cc` | 2408 | TREE 格式的成本打印 |
| `AccessPathTypeName()` | `access_path.cc` | 351 | AccessPath type 名 |
| `CreateIteratorFromAccessPath()` | `access_path.h` | 516 | AccessPath → 实际迭代器 |
| `NewTableScanAccessPath()` | `access_path.h` | 367 | 创建 TABLE_SCAN AccessPath |
| `NewRefAccessPath()` | `access_path.h` | 411 | 创建 REF AccessPath |
| `NewEQRefAccessPath()` | `access_path.h` | 428 | 创建 EQ_REF AccessPath |
| `NewFilterAccessPath()` | `access_path.h` | 485 | 创建 FILTER AccessPath |
| `NewSortAccessPath()` | `access_path.h` | 504 | 创建 SORT AccessPath |
| `ExpandFilterAccessPaths()` | `access_path.h` | 574 | 将 filter_predicates 展开为 FILTER 节点 |
| `IsCoveringIndexScan()` | `explain_access_path.cc` | 372 | 判断是否为覆盖索引扫描 |
| `JoinTypeToString()` | `explain_access_path.cc` | 430 | 连接类型转字符串 |
| `HashJoinTypeToString()` | `explain_access_path.cc` | 439 | 哈希连接类型描述 |
| `Opt_trace_context::start()` | `opt_trace_context.h` | 103 | 启动 optimizer trace |
| `Opt_trace_context::end()` | `opt_trace_context.h` | 165 | 结束 optimizer trace |
| `Opt_trace_struct::add_alnum()` | `opt_trace.h` | 418 | 添加字符串键值对到 trace |
| `Opt_trace_struct::add_utf8()` | `opt_trace.h` | 443 | 添加 UTF-8 字符串键值对到 trace |

---

## 参考

- `~/code/mysql/sql/opt_explain.cc` — 传统 EXPLAIN 核心实现
- `~/code/mysql/sql/opt_explain_format.h` — `Explain_format` 基类
- `~/code/mysql/sql/opt_explain_traditional.cc` — 传统格式输出
- `~/code/mysql/sql/opt_explain_json.cc` — JSON 格式输出
- `~/code/mysql/sql/join_optimizer/explain_access_path.cc` — 迭代器格式 EXPLAIN（TREE/新 JSON）
- `~/code/mysql/sql/join_optimizer/access_path.h` — `AccessPath` 结构定义
- `~/code/mysql/sql/opt_trace.h` — optimizer_trace 使用说明和 API
- `~/code/mysql/sql/opt_trace_context.h` — `Opt_trace_context`, `Opt_trace_object`, `Opt_trace_array`
