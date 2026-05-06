# 11-explain-execution-plan — MySQL EXPLAIN 与执行计划分析

## 0. 概述 — 从 SQL 到 EXPLAIN 的完整内部链路

EXPLAIN 是 MySQL 中最关键的调试工具之一。它揭示一条 SQL 语句的**执行计划**：优化器选择的访问路径、连接顺序、索引使用、行数估算和代价模型。但 EXPLAIN 本身并非一个简单的格式化打印操作，它涉及一条完整的内部链路：

```
SQL 文本 → parser (sql_yacc.yy) → resolver (sql_resolver.cc)
  → optimizer (sql_optimizer.cc / hypergraph_optimizer.cc)
    → AccessPath 树 (join_optimizer/access_path.h)
      → EXPLAIN 分派 (opt_explain.cc)
        → 格式渲染 (opt_explain_traditional.cc / explain_access_path.cc / opt_explain_json.cc)
          → 客户端协议
```

关键节点是：

1. **优化器输出**：无论使用传统优化器 (`JOIN::optimize()`) 还是新超图优化器 (`EnumerateAccessPaths()`)，最终都生成一棵 `AccessPath` 树 — 这是执行计划的核心内部表示。

2. **EXPLAIN 入口分派**：`mysql_explain_query_expression()` (`opt_explain.cc:114`) 根据格式化类型选择路径：
   - 传统格式 (`FORMAT=TRADITIONAL` 或不指定) → 走 `explain_query_specification()`，迭代 `QEP_TAB` 数组
   - 迭代器格式 (`FORMAT=TREE` 或 `FORMAT=JSON`) → 走 `ExplainIterator()` → `PrintQueryPlan()` → `ExplainAccessPath()`，递归遍历 `AccessPath` 树

3. **代价/行数嵌入**：每个 `AccessPath` 节点都携带 `cost()`, `init_cost()`, `num_output_rows()` 等估计值，这些数据在格式化阶段被嵌入输出。

4. **ANALYZE 扩展**：`EXPLAIN ANALYZE` 在实际执行查询后，通过 `IteratorProfiler` (`row_iterator.h`) 获取每个迭代器的实际执行时间、行数和循环次数，与估计值并列显示。

---

## 1. 核心数据结构

### 1.1 AccessPath 树 — 执行计划内部表示

`AccessPath` (`join_optimizer/access_path.h:243`) 是执行计划的统一内部表示。它直接对应到执行时的 `RowIterator` — 每种 `AccessPath::Type` 都映射到一种 `RowIterator` 子类。代码注释明确描述了设计目标：

```c
// join_optimizer/access_path.h:243
/**
  Access paths are a query planning structure that correspond 1:1 to iterators,
  in that an access path contains pretty much exactly the information
  needed to instantiate given iterator, plus some information that is only
  needed during planning, such as costs. (The new join optimizer will extend
  this somewhat in the future. Some iterators also need the query block,
  ie., JOIN object, they are part of, but that is implicitly available when
  constructing the tree.)

  AccessPath objects build on a variant, ie., they can hold an access path of
  any type (table scan, filter, hash join, sort, etc.), although only one at the
  same time. Currently, they contain 32 bytes of base information that is common
  to any access path (type identifier, costs, etc.), and then up to 40 bytes
  that is type-specific (e.g. for a table scan, the TABLE object). It would be
  nice if we could squeeze it down to 64 and fit a cache line exactly, but it
  does not seem to be easy without fairly large contortions.

  We could have solved this by inheritance, but the fixed-size design makes it
  possible to replace an access path when a better one is found, without
  introducing a new allocation, which will be important when using them as a
  planning structure.
 */
```

关键设计理念：
- **1:1 映射**到 `RowIterator`，每个 `AccessPath` 可直接实例化为具体迭代器
- **固定大小**（通过 `union` 实现类型变体），避免堆分配，允许在优化阶段替换更好的计划而不引入新分配
- **紧凑约束**：`sizeof(AccessPath) <= 152` 字节（104 基础 + 52 变体）

`AccessPath::Type` 枚举定义了 41 种访问路径类型：

```c
// join_optimizer/access_path.h:268
enum Type : uint8_t {
    // 基础访问路径（没有子节点）
    TABLE_SCAN,             // 全表扫描
    SAMPLE_SCAN,            // 表采样扫描 (TABLESAMPLE)
    INDEX_SCAN,             // 全索引扫描
    INDEX_DISTANCE_SCAN,    // 向量距离扫描
    REF,                    // 非唯一索引等值查找
    REF_OR_NULL,           // 索引等值 + IS NULL
    EQ_REF,                // 唯一索引等值查找
    PUSHED_JOIN_REF,       // 条件下推到存储引擎的 ref
    FULL_TEXT_SEARCH,      // 全文索引搜索
    CONST_TABLE,           // 常量表 (最多 0 或 1 行)
    MRR,                   // 多范围读取
    FOLLOW_TAIL,           // 尾部扫描（WITH RECURSIVE）
    INDEX_RANGE_SCAN,      // 索引范围扫描
    INDEX_MERGE,           // 索引合并
    ROWID_INTERSECTION,    // ROWID 交集
    ROWID_UNION,           // ROWID 并集
    INDEX_SKIP_SCAN,       // 索引跳跃扫描
    GROUP_INDEX_SKIP_SCAN, // 分组索引跳跃扫描
    DYNAMIC_INDEX_RANGE_SCAN, // 动态索引范围扫描（每行重新规划）

    // 不对应具体表的基础路径
    TABLE_VALUE_CONSTRUCTOR,  // VALUES ROW() 构造器
    FAKE_SINGLE_ROW,       // 假单行（无 FROM 的 SELECT）
    ZERO_ROWS,            // 零行结果
    ZERO_ROWS_AGGREGATED, // 零行聚合为一行
    MATERIALIZED_TABLE_FUNCTION,  // 物化表函数
    UNQUALIFIED_COUNT,    // 纯 COUNT(*)（无 WHERE）

    // 连接
    NESTED_LOOP_JOIN,     // 嵌套循环连接
    NESTED_LOOP_SEMIJOIN_WITH_DUPLICATE_REMOVAL, // 去重半连接
    BKA_JOIN,             // 批量键访问连接
    HASH_JOIN,            // 哈希连接

    // 复合访问路径
    FILTER,               // 过滤条件
    SORT,                 // 排序
    AGGREGATE,            // 聚合（流式）
    TEMPTABLE_AGGREGATE,  // 聚合（临时表）
    LIMIT_OFFSET,         // LIMIT/OFFSET
    STREAM,               // 流式结果
    MATERIALIZE,          // 物化
    MATERIALIZE_INFORMATION_SCHEMA_TABLE, // 物化信息架构表
    APPEND,               // 追加（UNION ALL）
    WINDOW,               // 窗口函数
    WEEDOUT,              // 去重（weedout 策略）
    REMOVE_DUPLICATES,    // 通用去重
    REMOVE_DUPLICATES_ON_INDEX, // 索引去重（LooseScan）
    ALTERNATIVE,          // 替代计划（IN 子查询）
    CACHE_INVALIDATOR,    // 缓存失效

    // 修改表
    DELETE_ROWS,          // 删除行
    UPDATE_ROWS,          // 更新行
} type;
```

```c
// join_optimizer/access_path.cc:351
std::string_view AccessPathTypeName(AccessPath::Type type) {
  switch (type) {
    case AccessPath::TABLE_SCAN:      return "TABLE_SCAN";
    case AccessPath::SAMPLE_SCAN:     return "SAMPLE_SCAN";
    case AccessPath::INDEX_SCAN:      return "INDEX_SCAN";
    case AccessPath::INDEX_DISTANCE_SCAN: return "INDEX_DISTANCE_SCAN";
    case AccessPath::REF:             return "REF";
    case AccessPath::REF_OR_NULL:     return "REF_OR_NULL";
    case AccessPath::EQ_REF:          return "EQ_REF";
    case AccessPath::PUSHED_JOIN_REF: return "PUSHED_JOIN_REF";
    case AccessPath::FULL_TEXT_SEARCH: return "FULL_TEXT_SEARCH";
    case AccessPath::CONST_TABLE:     return "CONST_TABLE";
    case AccessPath::MRR:             return "MRR";
    case AccessPath::FOLLOW_TAIL:     return "FOLLOW_TAIL";
    case AccessPath::INDEX_RANGE_SCAN: return "INDEX_RANGE_SCAN";
    case AccessPath::INDEX_MERGE:     return "INDEX_MERGE";
    case AccessPath::ROWID_INTERSECTION: return "ROWID_INTERSECTION";
    case AccessPath::ROWID_UNION:     return "ROWID_UNION";
    case AccessPath::INDEX_SKIP_SCAN: return "INDEX_SKIP_SCAN";
    case AccessPath::GROUP_INDEX_SKIP_SCAN: return "GROUP_INDEX_SKIP_SCAN";
    case AccessPath::DYNAMIC_INDEX_RANGE_SCAN: return "DYNAMIC_INDEX_RANGE_SCAN";
    case AccessPath::TABLE_VALUE_CONSTRUCTOR: return "TABLE_VALUE_CONSTRUCTOR";
    case AccessPath::FAKE_SINGLE_ROW: return "FAKE_SINGLE_ROW";
    case AccessPath::ZERO_ROWS:       return "ZERO_ROWS";
    case AccessPath::ZERO_ROWS_AGGREGATED: return "ZERO_ROWS_AGGREGATED";
    case AccessPath::MATERIALIZED_TABLE_FUNCTION: return "MATERIALIZED_TABLE_FUNCTION";
    case AccessPath::UNQUALIFIED_COUNT: return "UNQUALIFIED_COUNT";
    case AccessPath::NESTED_LOOP_JOIN: return "NESTED_LOOP_JOIN";
    case AccessPath::NESTED_LOOP_SEMIJOIN_WITH_DUPLICATE_REMOVAL: return "NESTED_LOOP_SEMIJOIN_WITH_DUPLICATE_REMOVAL";
    case AccessPath::BKA_JOIN:        return "BKA_JOIN";
    case AccessPath::HASH_JOIN:       return "HASH_JOIN";
    case AccessPath::FILTER:          return "FILTER";
    case AccessPath::SORT:            return "SORT";
    case AccessPath::AGGREGATE:       return "AGGREGATE";
    case AccessPath::TEMPTABLE_AGGREGATE: return "TEMPTABLE_AGGREGATE";
    case AccessPath::LIMIT_OFFSET:    return "LIMIT_OFFSET";
    case AccessPath::STREAM:          return "STREAM";
    case AccessPath::MATERIALIZE:     return "MATERIALIZE";
    case AccessPath::MATERIALIZE_INFORMATION_SCHEMA_TABLE: return "MATERIALIZE_INFORMATION_SCHEMA_TABLE";
    case AccessPath::APPEND:          return "APPEND";
    case AccessPath::WINDOW:          return "WINDOW";
    case AccessPath::WEEDOUT:         return "WEEDOUT";
    case AccessPath::REMOVE_DUPLICATES: return "REMOVE_DUPLICATES";
    case AccessPath::REMOVE_DUPLICATES_ON_INDEX: return "REMOVE_DUPLICATES_ON_INDEX";
    case AccessPath::ALTERNATIVE:     return "ALTERNATIVE";
    case AccessPath::CACHE_INVALIDATOR: return "CACHE_INVALIDATOR";
    case AccessPath::DELETE_ROWS:     return "DELETE_ROWS";
    case AccessPath::UPDATE_ROWS:     return "UPDATE_ROWS";
  }
}
```

### 1.2 struct AccessPath — 完整结构

`AccessPath` 在 `union u` 中包含了所有 37 个类型相关子结构：

```c
// join_optimizer/access_path.h:324-967
struct AccessPath {
  // —— 基础成员（32 字节） ——
  Type type;
  Safety safe_for_rowid : 2;
  bool count_examined_rows : 1;
  bool has_group_skip_scan : 1;
  int8_t immediate_update_delete_table;
  int ordering_state;
  RowIterator *iterator;
  OverflowBitset filter_predicates;
  OverflowBitset delayed_predicates;
  hypergraph::NodeMap parameter_tables;
  void *secondary_engine_data;
  size_t signature;

  // —— 私有代价/行数成员 ——
 private:
  double m_num_output_rows;       // 估计输出行数
  double m_cost;                  // 扫描一次的总代价
  double m_init_cost;             // 初始化的代价
  double m_init_once_cost;         // 只需初始化一次的代价（如物化表）
  double m_cost_before_filter;    // 过滤前的代价

  // —— 类型变体（union, 52 字节） ——
  union {
    struct { TABLE *table; } table_scan;
    struct { TABLE *table; double sampling_percentage;
             enum tablesample_type sampling_type; } sample_scan;
    struct { TABLE *table; int idx; bool use_order; bool reverse; } index_scan;
    struct { TABLE *table; Index_lookup *ref; bool use_order;
             bool reverse; } ref;
    struct { TABLE *table; Index_lookup *ref; } eq_ref;
    struct { TABLE *table; Index_lookup *ref; bool use_order;
             bool is_unique; } pushed_join_ref;
    struct { AccessPath *outer, *inner;
             const JoinPredicate *join_predicate;
             bool allow_spill_to_disk; bool store_rowids;
             bool rewrite_semi_to_inner;
             table_map tables_to_get_rowid_for; } hash_join;
    struct { AccessPath *outer, *inner; JoinType join_type;
             bool pfs_batch_mode;
             bool already_expanded_predicates;
             const JoinPredicate *join_predicate;
             OverflowBitset equijoin_predicates; } nested_loop_join;
    struct { AccessPath *child; Filesort *filesort;
             table_map tables_to_get_rowid_for;
             ORDER *order; ha_rows limit;
             bool remove_duplicates; bool unwrap_rollup;
             bool force_sort_rowids; } sort;
    struct { AccessPath *child; Item *condition;
             bool materialize_subqueries; } filter;
    // ... 共 37 个子结构
  } u;

  // —— 工厂函数 ——
};

static_assert(sizeof(AccessPath) <= 152,
  "We are creating a lot of access paths in the join "
  "optimizer, so be sure not to bloat it without noticing. "
  "(104 bytes for the base, 52 bytes for the variant.)");
```

每个类型变体都有类型安全的访问器，如 `path->table_scan()`, `path->hash_join()` 等，它们在 debug 模式下会断言 `type` 匹配：

```c
// join_optimizer/access_path.h:472
auto &table_scan() {
    assert(type == TABLE_SCAN);
    return u.table_scan;
}
const auto &table_scan() const {
    assert(type == TABLE_SCAN);
    return u.table_scan;
}
```

工厂函数简化了创建过程，例如 `NewTableScanAccessPath()`:

```c
// join_optimizer/access_path.h:1395
inline AccessPath *NewTableScanAccessPath(THD *thd, TABLE *table,
                                          bool count_examined_rows) {
  AccessPath *path = new (thd->mem_root) AccessPath;
  path->type = AccessPath::TABLE_SCAN;
  path->count_examined_rows = count_examined_rows;
  path->table_scan().table = table;
  return path;
}
```

```c
// join_optimizer/access_path.h:1408
inline AccessPath *NewSampleScanAccessPath(THD *thd, TABLE *table,
                                           double sampling_percentage,
                                           bool count_examined_rows) {
  AccessPath *path = new (thd->mem_root) AccessPath;
  path->type = AccessPath::SAMPLE_SCAN;
  path->count_examined_rows = count_examined_rows;
  path->sample_scan().table = table;
  path->sample_scan().sampling_percentage = sampling_percentage;
  return path;
}
```

### 1.3 CopyBasicProperties — 路径复制时的属性搬移

```c
// join_optimizer/access_path.h:1373
inline void CopyBasicProperties(const AccessPath &from, AccessPath *to) {
  to->set_num_output_rows(from.num_output_rows());
  to->set_cost(from.cost());
  to->set_init_cost(from.init_cost());
  to->set_init_once_cost(from.init_once_cost());
  to->parameter_tables = from.parameter_tables;
  to->safe_for_rowid = from.safe_for_rowid;
  to->ordering_state = from.ordering_state;
  to->has_group_skip_scan = from.has_group_skip_scan;
  to->signature = from.signature;
}
```

### 1.4 Explain_format — EXPLAIN 输出格式基类

`Explain_format` (`opt_explain_format.h:506`) 是所有格式输出器的抽象基类：

```c
// opt_explain_format.h:506
class Explain_format {
 protected:
  Query_result *output;  ///< output resulting data there
  std::optional<std::string_view> m_explain_into_variable_name;

 public:
  virtual ~Explain_format() = default;

  /// 是层级文本格式（TREE/JSON）还是传统表格
  virtual bool is_hierarchical() const = 0;

  /// 是否是基于迭代器（AccessPath）的格式
  virtual bool is_iterator_based(THD *explain_thd,
                                 const THD *query_thd) const {
    return false;
  }

  /// 是否是 EXPLAIN INTO @var
  bool is_explain_into() const;

  /// 进入某个上下文（WITH / WHERE / GROUP BY 等）
  virtual bool begin_context(enum_parsing_context context,
                             Query_expression *subquery = nullptr,
                             const Explain_format_flags *flags = nullptr) = 0;

  /// 离开当前上下文
  virtual bool end_context(enum_parsing_context context) = 0;

  /// 输出一行（传统格式）
  virtual bool flush_entry() = 0;

  /// 获取当前行的属性缓冲区
  virtual qep_row *entry() = 0;

  /// 将 Json 树转为字符串（迭代器格式专用）
  virtual std::string ExplainJsonToString(Json_object *json) = 0;
};
```

### 1.5 Explain_format_traditional — 传统表格格式

```c
// opt_explain_traditional.h:40
class Explain_format_traditional : public Explain_format {
  class Item_null *nil;
  qep_row column_buffer;  ///< buffer for the current output row

 public:
  bool is_hierarchical() const override { return false; }
  bool send_headers(Query_result *result) override;
  bool begin_context(...) override { return false; }
  bool end_context(...) override { return false; }
  bool flush_entry() override;
  qep_row *entry() override { return &column_buffer; }
};
```

### 1.6 Explain_format_tree — TREE 格式

```c
// opt_explain_traditional.h:70
class Explain_format_tree : public Explain_format {
 public:
  bool is_hierarchical() const override { return false; }
  bool is_iterator_based(THD *explain_thd, const THD *query_thd) const override {
    return true;
  }
  std::string ExplainJsonToString(Json_object *json) override;
  void ExplainPrintTreeNode(const Json_dom *json, int level,
                            std::string *explain,
                            std::vector<std::string> *tokens_for_force_subplan);
};
```

### 1.7 QEP_TAB — 传统 EXPLAIN 的行级表示

`QEP_TAB`（全称 Query Execution Plan Table）是传统优化器 (`JOIN::optimize()`) 中每张表的执行计划表示。它是 `Explain_format_traditional::flush_entry()` 中逐行输出的数据来源，每个 `QEP_TAB` 对应 `explain` 输出的一行。

传统 EXPLAIN 路径 (`explain_query_specification()`) 迭代 `JOIN::qep_tab` 数组，从每个 `QEP_TAB` 中提取 id、select_type、table、type、key、ref、rows 和 Extra 信息，通过 `Explain_format_traditional::flush_entry()` 逐行发送到客户端。

---

## 2. AccessPath — 执行计划的内部表示

### 2.1 struct AccessPath 完整结构

详见 1.2 节。核心要点：
- **代价属性**：`m_cost`（总代价）、`m_init_cost`（初始化代价）、`m_init_once_cost`（仅首次初始化的代价，如物化表）、`m_cost_before_filter`（过滤前代价）
- **行数属性**：`m_num_output_rows`（估计输出行数）、`num_output_rows_before_filter`（过滤前行数）
- **谓词追踪**：`filter_predicates`（位图中记录哪些 WHERE 条件在此节点应用）、`delayed_predicates`（延迟的条件）
- **参数化**：`parameter_tables` 位图标记依赖的外部表（如 LATERAL 引用）
- **排序状态**：`ordering_state` 指向 `LogicalOrderings` 中的排序索引

### 2.2 AccessPathType 枚举值详解

所有 41 种类型按其功能分组（分组从源码注释中的 enum 排列可看出）：

**基础访问路径（表级）：**
| 类型 | 含义 | 对应迭代器 |
|------|------|-----------|
| `TABLE_SCAN` | 全表扫描 | `TableScanIterator` |
| `SAMPLE_SCAN` | 表采样扫描 | `SampleScanIterator` |
| `INDEX_SCAN` | 全索引扫描 | `IndexScanIterator` |
| `INDEX_DISTANCE_SCAN` | 向量距离索引扫描 | `IndexDistanceScanIterator` |
| `REF` | 非唯一索引等值查找 | `RefIterator` |
| `REF_OR_NULL` | 索引查找 + IS NULL 补查 | `RefOrNullIterator` |
| `EQ_REF` | 唯一索引等值（最多一行） | `EqRefIterator` |
| `PUSHED_JOIN_REF` | NDB 引擎下推的 ref | `PushedJoinRefIterator` |
| `FULL_TEXT_SEARCH` | 全文检索 | `FullTextSearchIterator` |
| `CONST_TABLE` | 常量表（0 或 1 行，代价为 0） | `ConstIterator` |
| `MRR` | 多范围读取 | `MRRIterator` |
| `FOLLOW_TAIL` | CTE 尾部递归 | `FollowTailIterator` |
| `INDEX_RANGE_SCAN` | 索引范围扫描 | `IndexRangeScanIterator` |
| `INDEX_MERGE` | 索引合并（多索引交集） | `IndexMergeIterator` |
| `ROWID_INTERSECTION` | ROWID 交集 | `RowIDIntersectionIterator` |
| `ROWID_UNION` | ROWID 并集 | `RowIDUnionIterator` |
| `INDEX_SKIP_SCAN` | 索引跳跃扫描 | `IndexSkipScanIterator` |
| `GROUP_INDEX_SKIP_SCAN` | 分组跳跃扫描 | `GroupIndexSkipScanIterator` |
| `DYNAMIC_INDEX_RANGE_SCAN` | 动态索引范围 | `DynamicIndexRangeScanIterator` |

**不对应具体表的基础路径：**
| 类型 | 含义 | 场景 |
|------|------|------|
| `TABLE_VALUE_CONSTRUCTOR` | VALUES ROW() 字面量表 | `SELECT * FROM (VALUES ROW(1,2))` |
| `FAKE_SINGLE_ROW` | 假单行 | `SELECT 1+1` (无 FROM) |
| `ZERO_ROWS` | 零行 | 不可达条件 |
| `ZERO_ROWS_AGGREGATED` | 零行聚合 | 空集聚合为一行 |
| `MATERIALIZED_TABLE_FUNCTION` | 表函数物化 | JSON_TABLE 等 |
| `UNQUALIFIED_COUNT` | 纯 COUNT(*) | 无 WHERE 时的快速计数 |

**连接路径：**
| 类型 | 含义 |
|------|------|
| `NESTED_LOOP_JOIN` | 嵌套循环连接（包括 SJ/FirstMatch 等） |
| `NESTED_LOOP_SEMIJOIN_WITH_DUPLICATE_REMOVAL` | 带去重的半连接 |
| `BKA_JOIN` | 批量键访问连接 |
| `HASH_JOIN` | 哈希连接 |

**复合路径（有子节点）：**
| 类型 | 含义 |
|------|------|
| `FILTER` | 过滤条件 |
| `SORT` | 排序（filesort） |
| `AGGREGATE` | 流式聚合（需排序输入） |
| `TEMPTABLE_AGGREGATE` | 临时表聚合 |
| `LIMIT_OFFSET` | 行数限制 |
| `STREAM` | 流式输出（将临时表转换为流） |
| `MATERIALIZE` | 物化（派生表/CTE/UNION） |
| `MATERIALIZE_INFORMATION_SCHEMA_TABLE` | 物化 I_S 表 |
| `APPEND` | UNION ALL 追加 |
| `WINDOW` | 窗口函数 |
| `WEEDOUT` | 去重（weedout 策略） |
| `REMOVE_DUPLICATES` | 通用去重 |
| `REMOVE_DUPLICATES_ON_INDEX` | 利用索引去重（LooseScan） |
| `ALTERNATIVE` | 多路选择（IN 子查询） |
| `CACHE_INVALIDATOR` | 缓存失效 |

**修改路径：**
| 类型 | 含义 |
|------|------|
| `DELETE_ROWS` | DELETE 操作 |
| `UPDATE_ROWS` | UPDATE 操作 |

### 2.3 type 特有字段

每个 `AccessPath::Type` 都有对应的 union 成员，例如 `index_range_scan` 的详细结构：

```c
// join_optimizer/access_path.h:610
struct {
    KEY_PART *used_key_part;
    QUICK_RANGE **ranges;
    unsigned num_ranges;
    unsigned mrr_flags;
    unsigned mrr_buf_size;
    unsigned index;
    unsigned num_used_key_parts;
    bool can_be_used_for_ror : 1;
    bool need_rows_in_rowid_order : 1;
    bool can_be_used_for_imerge : 1;
    bool reuse_handler : 1;
    bool geometry : 1;
    bool reverse : 1;
    bool using_extended_key_parts : 1;
} index_range_scan;
```

`hash_join` 的详细结构包含了哈希连接执行的所有信息：

```c
// join_optimizer/access_path.h:798
struct {
    AccessPath *outer, *inner;
    const JoinPredicate *join_predicate;
    bool allow_spill_to_disk;
    bool store_rowids;
    bool rewrite_semi_to_inner;
    table_map tables_to_get_rowid_for;
} hash_join;
```

`sort` 的结构记录了排序所需的所有参数：

```c
// join_optimizer/access_path.h:854
struct {
    AccessPath *child;
    Filesort *filesort;
    table_map tables_to_get_rowid_for;
    ORDER *order;
    ha_rows limit;
    bool remove_duplicates;
    bool unwrap_rollup;
    bool force_sort_rowids;
} sort;
```

### 2.4 从 JOIN 优化器到 AccessPath 的转换

在传统优化器中，`JOIN::optimize()` 调用 `Optimize_table_order()` 选择连接顺序和访问方法后，通过 `create_access_paths_for_join()` (`sql_optimizer.cc`) 将 `POSITION` 数组转换为 `AccessPath` 树。

超图优化器 (`hypergraph_optimizer.cc`) 中的 `EnumerateAccessPaths()` 则直接在搜索过程中构建 `AccessPath` 树，每种连接顺序候选都对应一棵完整的 `AccessPath` 树，最终选择代价最小的。

无论哪种优化器，最终的 `AccessPath` 树都挂在 `Query_expression::root_access_path()` 上。

---

## 3. EXPLAIN 入口与分派

### 3.1 mysql_explain_query_expression() — 完整入口分派

`opt_explain.cc:2394` 是 EXPLAIN 的主入口：

```c
// opt_explain.cc:2394
bool mysql_explain_query_expression(THD *explain_thd, const THD *query_thd,
                                    Query_expression *unit) {
  DBUG_TRACE;
  bool res = false;
  if (unit->is_simple())
    res = explain_query_specification(explain_thd, query_thd,
                                      unit->query_term(), CTX_JOIN);
  else
    res = unit->explain(explain_thd, query_thd);
  assert(res || !explain_thd->is_error());
  res |= explain_thd->is_error();
  return res;
}
```

分派逻辑：
- **简单查询**（非 UNION） → `explain_query_specification()`（传统格式入口）
- **集合查询**（UNION） → `unit->explain()`（调用 `Query_expression::explain()`）

在 `opt_explain.cc:2363` 处，真正的分派逻辑判断是否走迭代器路径：

```c
// opt_explain.cc:1924
if (explain_thd->lex->explain_format->is_iterator_based(explain_thd,
                                                          query_thd)) {
    // 这些查询没有带迭代器树的 JOIN
    return ExplainIterator(explain_thd, query_thd, nullptr);
}
```

这意味着当用户使用 `FORMAT=TREE` 或 `FORMAT=JSON`（超图优化器启用时）时，直接跳转到 `ExplainIterator()`，不走传统的 `explain_query_specification()` 路径。

### 3.2 ExplainIterator() — 新格式入口

```c
// opt_explain.cc:129
static bool ExplainIterator(THD *ethd, const THD *query_thd,
                            Query_expression *unit) {
  Query_result_send *result = nullptr;
  if (ethd->lex->explain_format->is_explain_into()) {
    result = new (ethd->mem_root) Query_result_explain_into_var(
        unit, result, ethd->lex->explain_format->explain_into_variable_name());
  } else {
    result = new (ethd->mem_root) Query_result_send();
  }
  if (result == nullptr) return true;

  {
    mem_root_deque<Item *> field_list(ethd->mem_root);
    Item *item = new Item_empty_string("EXPLAIN", 78, system_charset_info);
    field_list.push_back(item);
    if (result->send_result_set_metadata(
            ethd, field_list, Protocol::SEND_NUM_ROWS | Protocol::SEND_EOF)) {
      return true;
    }
  }

  {
    std::string explain = PrintQueryPlan(ethd, query_thd, unit);
    if (explain.empty()) {
      my_error(ER_INTERNAL_ERROR, MYF(0), "Failed to print query plan");
      return true;
    }
    mem_root_deque<Item *> field_list(ethd->mem_root);
    Item *item =
        new Item_string(explain.data(), explain.size(), system_charset_info);
    field_list.push_back(item);

    if (query_thd->killed) {
      ethd->raise_warning(ER_QUERY_INTERRUPTED);
    }

    if (result->send_data(ethd, field_list)) {
      return true;
    }
  }
  return result->send_eof(ethd);
}
```

`ExplainIterator()` 的核心流程：
1. 创建或获取 `Query_result_send` 对象（用于 `EXPLAIN INTO @var` 时使用特殊子类）
2. 发送结果集元数据（一个名为 "EXPLAIN" 的字符串列）
3. 调用 `PrintQueryPlan()` 生成完整的计划文本
4. 将文本作为单行发送到客户端

### 3.3 PrintQueryPlan() — AccessPath → 文本输出

`PrintQueryPlan()` (`explain_access_path.cc:2208`) 是迭代器格式的核心转换函数：

```c
// join_optimizer/explain_access_path.cc:2208
std::string PrintQueryPlan(THD *ethd, const THD *query_thd,
                           Query_expression *unit) {
  JOIN *join = nullptr;
  bool is_root_of_join = (unit != nullptr ? !unit->is_union() : false);
  AccessPath *path = (unit != nullptr ? unit->root_access_path() : nullptr);

  if (unit != nullptr && !unit->is_union())
    join = unit->first_query_block()->join;

  /* 创建一个 Json 对象表示计划 */
  unique_ptr<Json_object> query_plan_obj =
      ExplainQueryPlan(path, &query_thd->query_plan, join, is_root_of_join);
  if (query_plan_obj == nullptr) return "";

  unique_ptr<Json_object> obj = create_dom_ptr<Json_object>();
  if (obj == nullptr) return "";
  if (obj->add_alias("query_plan", std::move(query_plan_obj))) return "";

  // 附加重写后的查询字符串
  if (ethd == query_thd) {
    StringBuffer<1024> str;
    print_query_for_explain(query_thd, unit, &str);
    if (!str.is_empty()) {
      if (AddMemberToObject<Json_string>(obj, "query", str.ptr(), str.length()))
        return "";
    }
  }

  string query_type = GetQueryType(&query_thd->query_plan);
  if (!query_type.empty()) {
    AddMemberToObject<Json_string>(obj, "query_type", query_type);
  }

  // JSON Schema 版本号
  const uint8_t Major = 2;
  const uint8_t minor = 0;
  std::string explain_json_schema_version =
      std::to_string(Major) + "." + std::to_string(minor);
  AddMemberToObject<Json_string>(obj, "json_schema_version",
                                 explain_json_schema_version);

  return ethd->lex->explain_format->ExplainJsonToString(obj.get());
}
```

流程：
1. 从 `unit->root_access_path()` 获取根 `AccessPath`
2. 调用 `ExplainQueryPlan()` 将 `AccessPath` 树递归转换为 `Json_object` 树
3. 包装为 `{ "query_plan": ..., "query": ..., "query_type": ..., "json_schema_version": "2.0" }`
4. 通过格式化器的 `ExplainJsonToString()` 转为最终字符串

还有一个调试版本 `PrintQueryPlan(int level, ...)`：

```c
// join_optimizer/explain_access_path.cc:2275
std::string PrintQueryPlan(int level, AccessPath *path, JOIN *join,
                           bool is_root_of_join) {
  string ret;
  Explain_format_tree format;

  if (path == nullptr) {
    ret.assign(level * 4, ' ');
    return ret + "<not executable by iterator executor>\n";
  }

  /* 创建 Json 对象 */
  unique_ptr<Json_object> json =
      ExplainAccessPath(path, /*materialized_path=*/nullptr, join,
                        is_root_of_join, /*root_obj=*/nullptr);
  if (json == nullptr) return "";

  /* 输出树格式 */
  string explain;
  format.ExplainPrintTreeNode(json.get(), level, &explain, /*tokens=*/nullptr);
  return explain;
}
```

### 3.4 传统 vs 迭代器路径的分派逻辑

分派从 `opt_explain.cc:2292` 的 `explain_query_specification()` 开始：

```c
// opt_explain.cc:2292
if (is_iterator_based) {
    return ExplainIterator(explain_thd, query_thd, unit);
}
// 否则走传统路径：
// 1. 创建 Explain_format_traditional 实例
// 2. 迭代 JOIN::qep_tab
// 3. 逐行填充 qep_row → flush_entry()

if (query_thd->lex->using_hypergraph_optimizer()) {
    my_error(ER_HYPERGRAPH_NOT_SUPPORTED_YET, MYF(0),
             "EXPLAIN with TRADITIONAL format");
    return true;
}
```

关键规则：
- 超图优化器 + FORMAT=TRADITIONAL → 报错（不支持）
- FORMAT=TREE → `Explain_format_tree::is_iterator_based()` 返回 true → `ExplainIterator()`
- FORMAT=JSON（超图优化器） → `Explain_format_json` 返回 true → `ExplainIterator()`
- 传统优化器 + 无格式指定 → 走传统 `explain_query_specification()`

对于 `EXPLAIN ANALYZE`，`ExplainIterator()` 之前会先执行查询。执行使用 `Query_result_null` 来丢弃实际输出：

```c
// opt_explain.cc:2084
class Query_result_null : public Query_result_interceptor {
 public:
  Query_result_null() : Query_result_interceptor() {}
  uint field_count(const mem_root_deque<Item *> &) const override { return 0; }
  bool send_result_set_metadata(THD *, const mem_root_deque<Item *> &,
                                uint) override { return false; }
  bool send_data(THD *thd, const mem_root_deque<Item *> &items) override {
    for (Item *item : VisibleFields(items)) {
      item->val_str(&m_str);  // 确保子查询被求值，以获取实际行数和时间
      if (thd->is_error()) return true;
    }
    return false;
  }
  bool send_eof(THD *) override { return false; }
 private:
  String m_str;
};
```

---

## 4. 三种 EXPLAIN 格式

### 4.1 Traditional 格式 — 逐列源码分析

`Explain_format_traditional::flush_entry()` (`opt_explain_traditional.cc:214`) 是传统格式输出的核心。它从 `column_buffer`（`qep_row` 类型）读取属性，构造成一行 12 列发送：

```c
// opt_explain_traditional.cc:214
bool Explain_format_traditional::flush_entry() {
  Buffer_cleanup bc(&column_buffer);
  mem_root_deque<Item *> items(current_thd->mem_root);
  if (push(&items, column_buffer.col_id, nil) ||
      push_select_type(&items) ||
      push(&items, column_buffer.col_table_name, nil) ||
      push(&items, column_buffer.col_partitions, nil) ||
      push(&items, column_buffer.col_join_type, nil) ||
      push(&items, column_buffer.col_possible_keys, nil) ||
      push(&items, column_buffer.col_key, nil) ||
      push(&items, column_buffer.col_key_len, nil) ||
      push(&items, column_buffer.col_ref, nil) ||
      push(&items, column_buffer.col_rows, nil) ||
      push(&items, column_buffer.col_filtered, nil))
    return true;

  // Extra 列处理：将 Extra_tag 转为可读文本
  if (column_buffer.col_message.is_empty() &&
      column_buffer.col_extra.is_empty()) {
    items.push_back(nil);
  } else if (!column_buffer.col_extra.is_empty()) {
    StringBuffer<64> buff(system_charset_info);
    List_iterator<qep_row::extra> it(column_buffer.col_extra);
    qep_row::extra *e;
    while ((e = it++)) {
      assert(traditional_extra_tags[e->tag] != nullptr);
      if (buff.append(traditional_extra_tags[e->tag])) return true;
      if (e->data) { /* 附加参数 */ }
    }
    // ...
  }

  if (output->send_data(current_thd, items)) return true;
  return false;
}
```

Extra 标签使用 `traditional_extra_tags` 数组，与 `Extra_tag` 枚举一一对应：

```c
// opt_explain_traditional.cc:35
static const char *traditional_extra_tags[ET_total] = {
    nullptr,                            // ET_none
    "Using temporary",                  // ET_USING_TEMPORARY
    "Using filesort",                   // ET_USING_FILESORT
    "Using index condition",            // ET_USING_INDEX_CONDITION
    "Using",                            // ET_USING
    "Range checked for each record",    // ET_RANGE_CHECKED_FOR_EACH_RECORD
    "Using pushed condition",           // ET_USING_PUSHED_CONDITION
    "Using where",                      // ET_USING_WHERE
    "Not exists",                       // ET_NOT_EXISTS
    "Using MRR",                        // ET_USING_MRR
    "Using index",                      // ET_USING_INDEX
    "Full scan on NULL key",            // ET_FULL_SCAN_ON_NULL_KEY
    "Using index for group-by",         // ET_USING_INDEX_FOR_GROUP_BY
    "Using index for skip scan",        // ET_USING_INDEX_FOR_SKIP_SCAN
    "Distinct",                         // ET_DISTINCT
    "LooseScan",                        // ET_LOOSESCAN
    "Start temporary",                  // ET_START_TEMPORARY
    "End temporary",                    // ET_END_TEMPORARY
    "FirstMatch",                       // ET_FIRST_MATCH
    "Materialize",                      // ET_MATERIALIZE
    "Start materialize",                // ET_START_MATERIALIZE
    "End materialize",                  // ET_END_MATERIALIZE
    "Scan",                             // ET_SCAN
    "Using join buffer",                // ET_USING_JOIN_BUFFER
    "const row not found",              // ET_CONST_ROW_NOT_FOUND
    "unique row not found",             // ET_UNIQUE_ROW_NOT_FOUND
    "Impossible ON condition",          // ET_IMPOSSIBLE_ON_CONDITION
    "",                                 // ET_PUSHED_JOIN
    "Ft_hints:",                        // ET_FT_HINTS
    "Backward index scan",              // ET_BACKWARD_SCAN
    "Recursive",                        // ET_RECURSIVE
    "Table function:",                  // ET_TABLE_FUNCTION
    "Index dive skipped due to FORCE",  // ET_SKIP_RECORDS_IN_RANGE
    "Using secondary engine",           // ET_USING_SECONDARY_ENGINE
    "Rematerialize"                     // ET_REMATERIALIZE
};
```

传统格式的 select_type 列使用 `Query_block::get_type_str()` 返回类型字符串，并加上 DEPENDENT/UNCACHEABLE 前缀：

```c
// opt_explain_traditional.cc:187
bool Explain_format_traditional::push_select_type(
    mem_root_deque<Item *> *items) {
  assert(!column_buffer.col_select_type.is_empty());
  StringBuffer<32> buff;
  if (column_buffer.is_dependent) {
    if (buff.append(STRING_WITH_LEN("DEPENDENT "), system_charset_info))
      return true;
  } else if (!column_buffer.is_cacheable) {
    if (buff.append(STRING_WITH_LEN("UNCACHEABLE "), system_charset_info))
      return true;
  }
  const enum_explain_type sel_type = column_buffer.col_select_type.get();
  const char *type = (column_buffer.mod_type != MT_NONE &&
                      (sel_type == enum_explain_type::EXPLAIN_PRIMARY ||
                       sel_type == enum_explain_type::EXPLAIN_SIMPLE))
                         ? mod_type_name[column_buffer.mod_type]
                         : Query_block::get_type_str(sel_type);

  if (buff.append(type)) return true;

  Item_string *item = new Item_string(buff.dup(current_thd->mem_root),
                                      buff.length(), system_charset_info);
  if (item == nullptr) return true;
  items->push_back(item);
  return false;
}
```

### 4.2 JSON 格式 — 递归树结构

JSON 格式的 Extra 标签使用 `json_extra_tags` 数组，与 `Extra_tag` 枚举一一对应：

```c
// opt_explain_json.cc:37
static const char *json_extra_tags[ET_total] = {
    nullptr,                               // ET_none
    "using_temporary_table",               // ET_USING_TEMPORARY
    "using_filesort",                      // ET_USING_FILESORT
    "index_condition",                     // ET_USING_INDEX_CONDITION
    nullptr,                               // ET_USING
    "range_checked_for_each_record",       // ET_RANGE_CHECKED_FOR_EACH_RECORD
    "pushed_condition",                    // ET_USING_PUSHED_CONDITION
    "using_where",                         // ET_USING_WHERE
    "not_exists",                          // ET_NOT_EXISTS
    "using_MRR",                           // ET_USING_MRR
    "using_index",                         // ET_USING_INDEX
    "full_scan_on_NULL_key",               // ET_FULL_SCAN_ON_NULL_KEY
    "using_index_for_group_by",            // ET_USING_INDEX_FOR_GROUP_BY
    "using_index_for_skip_scan",           // ET_USING_INDEX_FOR_SKIP_SCAN
    "distinct",                            // ET_DISTINCT
    "loosescan",                           // ET_LOOSESCAN
    nullptr,                               // ET_START_TEMPORARY
    nullptr,                               // ET_END_TEMPORARY
    "first_match",                         // ET_FIRST_MATCH
    nullptr,                               // ET_MATERIALIZE
    nullptr,                               // ET_START_MATERIALIZE
    nullptr,                               // ET_END_MATERIALIZE
    nullptr,                               // ET_SCAN
    "using_join_buffer",                   // ET_USING_JOIN_BUFFER
    "const_row_not_found",                 // ET_CONST_ROW_NOT_FOUND
    "unique_row_not_found",                // ET_UNIQUE_ROW_NOT_FOUND
    "impossible_on_condition",             // ET_IMPOSSIBLE_ON_CONDITION
    "pushed_join",                         // ET_PUSHED_JOIN
    "ft_hints",                           // ET_FT_HINTS
    "backward_index_scan",                 // ET_BACKWARD_SCAN
    "recursive",                           // ET_RECURSIVE
    "table_function",                      // ET_TABLE_FUNCTION
    "skip_records_in_range_due_to_force",  // ET_SKIP_RECORDS_IN_RANGE
    "using_secondary_engine",              // ET_USING_SECONDARY_ENGINE
    "rematerialize"                        // ET_REMATERIALIZE
};
```

JSON 格式的递归渲染通过 `Explain_format_tree::ExplainJsonToString()` 和 `ExplainPrintTreeNode()` 实现：

```c
// join_optimizer/explain_access_path.cc:2354
string Explain_format_tree::ExplainJsonToString(Json_object *json) {
  string explain;
  vector<string> *token_ptr = nullptr;
#ifndef NDEBUG
  vector<string> tokens_for_force_subplan;
  DBUG_EXECUTE_IF("subplan_tokens", token_ptr = &tokens_for_force_subplan;);
#endif
  Json_dom *query_plan_json = json->get("query_plan");
  this->ExplainPrintTreeNode(query_plan_json, 0, &explain, token_ptr);
  if (explain.empty()) return "";

  DBUG_EXECUTE_IF("subplan_tokens", {
    explain += "\nTo force this plan, use:\nSET DEBUG='+d,subplan_tokens";
    for (const string &token : tokens_for_force_subplan) {
      explain += ",force_subplan_";
      explain += token;
    }
    explain += "';\n";
  });

  return explain;
}
```

`ExplainPrintTreeNode()` 递归遍历 JSON 树，每级缩进 4 个空格：

```c
// join_optimizer/explain_access_path.cc:2380
void Explain_format_tree::ExplainPrintTreeNode(const Json_dom *json, int level,
                                               string *explain,
                                               vector<string> *subplan_token) {
  string children_explain;
  string children_digest;

  explain->append(level * 4, ' ');

  if (json == nullptr || json->json_type() == enum_json_type::J_NULL) {
    explain->append("<not executable by iterator executor>\n");
    return;
  }

  const Json_object *obj = down_cast<const Json_object *>(json);

  AppendChildren(obj->get("inputs"), level + 1, &children_explain,
                 subplan_token, &children_digest);
  AppendChildren(obj->get("inputs_from_select_list"), level, &children_explain,
                 subplan_token, &children_digest);

  *explain += "-> ";
  // 如果是 debug 模式，添加子计划 token（用于 force_subplan）
  if (subplan_token) {
    string my_subplan_token = GetForceSubplanToken(obj, children_digest);
    *explain += '[' + my_subplan_token + "] ";
    subplan_token->push_back(my_subplan_token);
  }
  assert(obj->get("operation")->json_type() == enum_json_type::J_STRING);
  *explain += down_cast<Json_string *>(obj->get("operation"))->value();

  ExplainPrintCosts(obj, explain);
  *explain += children_explain;
}
```

代价渲染函数 `ExplainPrintCosts` 处理两种模式：
- **普通 EXPLAIN**：显示 `estimated_first_row_cost`, `estimated_total_cost`, `estimated_rows`
- **EXPLAIN ANALYZE**：额外显示 `actual_first_row_ms`, `actual_last_row_ms`, `actual_rows`, `actual_loops`

```c
// join_optimizer/explain_access_path.cc:2416
void Explain_format_tree::ExplainPrintCosts(const Json_object *obj,
                                            string *explain) {
  bool has_first_cost = obj->get("estimated_first_row_cost") != nullptr;
  bool has_cost = obj->get("estimated_total_cost") != nullptr;

  if (has_cost) {
    double last_cost = GetJSONDouble(obj, "estimated_total_cost");
    double rows = GetJSONDouble(obj, "estimated_rows");
    std::ostringstream stream;

    if (has_first_cost) {
      double first_row_cost = GetJSONDouble(obj, "estimated_first_row_cost");
      stream << "  (cost=" << FormatNumberReadably(first_row_cost) << ".."
             << FormatNumberReadably(last_cost)
             << " rows=" << FormatNumberReadably(rows) << ")";
    } else {
      stream << "  (cost=" << FormatNumberReadably(last_cost)
             << " rows=" << FormatNumberReadably(rows) << ")";
    }
    *explain += stream.str();
  }

  // EXPLAIN ANALYZE 的实际数据
  if (obj->get("actual_rows") != nullptr) {
    if (obj->get("actual_rows")->json_type() == enum_json_type::J_NULL) {
      *explain += "(never executed)";
    } else {
      double actual_first_row_ms = GetJSONDouble(obj, "actual_first_row_ms");
      double actual_last_row_ms = GetJSONDouble(obj, "actual_last_row_ms");
      double actual_rows = GetJSONDouble(obj, "actual_rows");
      uint64_t actual_loops =
          down_cast<Json_int *>(obj->get("actual_loops"))->value();

      std::ostringstream stream;
      stream << "(actual time=" << FormatNumberReadably(actual_first_row_ms)
             << ".." << FormatNumberReadably(actual_last_row_ms)
             << " rows=" << FormatNumberReadably(actual_rows)
             << " loops=" << FormatNumberReadably(actual_loops) << ")";
      *explain += stream.str();
    }
  }
  *explain += "\n";
}
```

### 4.3 TREE 格式 — 层级缩进文本

TREE 格式与 JSON 格式共享同一个 JSON 中间表示。区别仅在于 `Explain_format_tree::ExplainJsonToString()` 的输出：
- TREE 格式通过 `ExplainPrintTreeNode()` 输出为带缩进的层级文本
- JSON 格式则通过 `Json_dom::to_string()` 输出为 JSON 字符串

TREE 格式的输出结构：
```
-> Nested loop inner join  (cost=X..Y rows=Z)
    -> Table scan on t1  (cost=... rows=...)
    -> Filter: (t2.a > 5)  (cost=... rows=...)
        -> Index lookup on t2 using idx_a (a=...)  (cost=... rows=...)
```

### 4.4 ExplainQueryPlan — AccessPath 进入 JSON 的桥梁

```c
// join_optimizer/explain_access_path.cc:903
static unique_ptr<Json_object> ExplainQueryPlan(
    const AccessPath *path, THD::Query_plan const *query_plan, JOIN *join,
    bool is_root_of_join) {
  string dml_desc;
  string access_type;
  unique_ptr<Json_object> obj = nullptr;

  if (path != nullptr) {
    obj = ExplainAccessPath(path, /*materialized_path=*/nullptr, join,
                            is_root_of_join, /*root_obj=*/nullptr);
  } else {
    obj = ExplainNoAccessPath(query_plan);
  }
  if (obj == nullptr) return nullptr;

  // 如果是 DML 语句（INSERT/REPLACE），在 SELECT 计划外加一层 DML 节点
  if (query_plan != nullptr) {
    switch (query_plan->get_command()) {
      case SQLCOM_INSERT:
        access_type = "insert_values";
        [[fallthrough]];
      case SQLCOM_INSERT_SELECT:
        dml_desc = string("Insert into ") +
                   query_plan->get_lex()->insert_table_leaf->table->alias;
        break;
      // ... REPLACE 同理
    }
  }

  if (!dml_desc.empty()) {
    unique_ptr<Json_object> dml_obj(new (std::nothrow) Json_object());
    if (AddMemberToObject<Json_string>(dml_obj, "operation", dml_desc))
      return nullptr;
    // children 中放入 SELECT 计划节点
    unique_ptr<Json_array> children(new (std::nothrow) Json_array());
    children->append_alias(std::move(obj));
    dml_obj->add_alias("inputs", std::move(children));
    obj = std::move(dml_obj);
  }

  return obj;
}
```

对于没有 AccessPath 的查询（如 `INSERT ... VALUES`），走 `ExplainNoAccessPath()` 路径：

```c
// join_optimizer/explain_access_path.cc:2138
unique_ptr<Json_object> ExplainNoAccessPath(const THD::Query_plan *query_plan) {
  unique_ptr<Json_object> ret_obj = create_dom_ptr<Json_object>();
  LEX *lex = query_plan->get_lex();

  switch (lex->m_sql_cmd->sql_command_code()) {
    case SQLCOM_INSERT:
    case SQLCOM_REPLACE:
      error |= AddMemberToObject<Json_string>(ret_obj, "operation",
                                              "Rows fetched before execution");
      error |= AddMemberToObject<Json_string>(ret_obj, "access_type",
                                              "rows_fetched_before_execution");
      break;
    default:
      error |= AddMemberToObject<Json_string>(ret_obj, "operation",
                                              "<not executable by iterator executor>");
      break;
  }
  return ret_obj;
}
```

---

## 5. 执行计划类型源码解析

### 5.1 TABLE_SCAN → "Full table scan"

```c
// join_optimizer/explain_access_path.cc:1185
case AccessPath::TABLE_SCAN: {
    const TABLE &table = *path->table_scan().table;
    description += string("Table scan on ") + table.alias;
    if (table.s->is_secondary_engine()) {
        error |= AddMemberToObject<Json_string>(obj, "secondary_engine",
                                                table.file->table_type());
        description += string(" in secondary engine ") + table.file->table_type();
    }
    description += table.file->explain_extra();

    error |= AddTableInfoToObject(obj, &table);
    error |= AddMemberToObject<Json_string>(obj, "access_type", "table");
    if (!table.file->explain_extra().empty())
        error |= AddMemberToObject<Json_string>(obj, "message",
                                                table.file->explain_extra());
    error |= AddChildrenFromPushedCondition(table, children);
    break;
}
```

判断逻辑：`path->type == AccessPath::TABLE_SCAN`。当没有可用索引、或优化器认为全表扫描比索引访问更快时选择此路径。

### 5.2 INDEX_SCAN → "Index scan"

```c
// join_optimizer/explain_access_path.cc:1215
case AccessPath::INDEX_SCAN: {
    const TABLE &table = *path->index_scan().table;
    assert(table.file->pushed_idx_cond == nullptr);
    const KEY &key = table.key_info[path->index_scan().idx];
    error |= SetIndexInfoInObject(
        &description, path, "index_scan", nullptr, table, key, "scan",
        /*index_lookup*/ nullptr, /*range*/ nullptr, nullptr,
        path->index_scan().reverse, /*push_condition*/ nullptr, obj);
    error |= AddChildrenFromPushedCondition(table, children);
    break;
}
```

`SetIndexInfoInObject()` 生成格式化的索引描述：

```c
// join_optimizer/explain_access_path.cc:408
// 生成的描述格式：
// [<Prefix>] [COVERING] INDEX <index_operation>
//   ON table_alias USING index_name [ (<lookup_condition>) ]
//   [ OVER <range> [, <range>, ...] ]
//   [ (REVERSE) ]
//   [ WITH INDEX CONDITION: <pushed_idx_cond> ]
```

### 5.3 REF/EQ_REF/REF_OR_NULL → 索引等值查找

REF（非唯一索引等值查找）：

```c
// join_optimizer/explain_access_path.cc:1236
case AccessPath::REF: {
    const TABLE &table = *path->ref().table;
    const KEY &key = table.key_info[path->ref().ref->key];
    error |=
        SetIndexInfoInObject(&description, path, "index_lookup", nullptr,
                             table, key, "lookup", path->ref().ref,
                             /*ranges=*/nullptr, nullptr, path->ref().reverse,
                             table.file->pushed_idx_cond, obj);
    error |= AddChildrenFromPushedCondition(table, children);
    break;
}
```

EQ_REF（唯一索引等值，保证最多返回一行，前缀为 "Single-row"）：

```c
// join_optimizer/explain_access_path.cc:1258
case AccessPath::EQ_REF: {
    const TABLE &table = *path->eq_ref().table;
    const KEY &key = table.key_info[path->eq_ref().ref->key];
    error |= SetIndexInfoInObject(
        &description, path, "index_lookup", "Single-row", table, key,
        "lookup", path->eq_ref().ref,
        /*ranges=*/nullptr, nullptr, false, table.file->pushed_idx_cond, obj);
    error |= AddChildrenFromPushedCondition(table, children);
    break;
}
```

REF_OR_NULL（索引等值查找 + IS NULL 补查）：

```c
// join_optimizer/explain_access_path.cc:1248
case AccessPath::REF_OR_NULL: {
    const TABLE &table = *path->ref_or_null().table;
    const KEY &key = table.key_info[path->ref_or_null().ref->key];
    error |= SetIndexInfoInObject(
        &description, path, "index_lookup", nullptr, table, key, "lookup",
        path->ref_or_null().ref,
        /*ranges=*/nullptr, nullptr, false, table.file->pushed_idx_cond, obj);
    error |= AddChildrenFromPushedCondition(table, children);
    break;
}
```

### 5.4 INDEX_RANGE_SCAN → 范围扫描

```c
// join_optimizer/explain_access_path.cc:1309
case AccessPath::INDEX_RANGE_SCAN: {
    const auto &param = path->index_range_scan();
    const TABLE &table = *param.used_key_part[0].field->table;
    const KEY &key_info = table.key_info[param.index];

    unique_ptr<Json_array> range_arr(new (std::nothrow) Json_array());
    string ranges;
    error |= PrintRanges(param.ranges, param.num_ranges, key_info.key_part,
                         /*single_part_only=*/false, range_arr, &ranges);

    // MRR 优化检查：范围扫描可能使用 MRR
    uint mrr_flags = param.mrr_flags;
    bool using_mrr = false;
    if ((!(mrr_flags & HA_MRR_SORTED) || mrr_flags & HA_MRR_SUPPORT_SORTED) &&
        !(mrr_flags & HA_MRR_USE_DEFAULT_IMPL)) {
        using_mrr = true;
        error |= AddMemberToObject<Json_boolean>(obj, "multi_range_read", true);
    }
    error |= SetIndexInfoInObject(
        &description, path, "index_range_scan", nullptr, table, key_info,
        using_mrr ? "range scan (Multi-Range Read)" : "range scan",
        /*index_lookup*/ nullptr, &ranges, std::move(range_arr),
        path->index_range_scan().reverse, table.file->pushed_idx_cond, obj);

    error |= AddChildrenFromPushedCondition(table, children);
    break;
}
```

关键逻辑：
- 如果扫描是覆盖索引（`IsCoveringIndexScan()`），会添加 `COVERING` 标记
- 如果 MRR 可用（非排序要求或引擎支持排序），添加 `multi_range_read: true`
- 范围通过 `PrintRanges()` 序列化为 JSON 数组和文本描述

### 5.5 NESTED_LOOP_JOIN → 嵌套循环连接

```c
// join_optimizer/explain_access_path.cc:1484
case AccessPath::NESTED_LOOP_JOIN: {
    string join_type = JoinTypeToString(path->nested_loop_join().join_type);
    error |= AddMemberToObject<Json_string>(obj, "access_type", "join");
    error |= AddMemberToObject<Json_string>(obj, "join_type", join_type);
    error |=
        AddMemberToObject<Json_string>(obj, "join_algorithm", "nested_loop");
    description = "Nested loop " + join_type;

    // 半连接策略检测
    if (path->nested_loop_join().join_type == JoinType::SEMI) {
        description = description + " (FirstMatch)";
        error |= AddMemberToObject<Json_string>(obj, "semijoin_strategy",
                                                "firstmatch");
    }
    const JoinPredicate *predicate = path->nested_loop_join().join_predicate;
    if (predicate != nullptr &&
        predicate->expr->type == RelationalExpression::SEMIJOIN &&
        path->nested_loop_join().join_type == JoinType::INNER) {
        if (DoesDeduplicate(*path->nested_loop_join().outer)) {
            description.append(" (LooseScan)");
            error |= AddMemberToObject<Json_string>(obj, "semijoin_strategy",
                                                    "loosescan");
        } else {
            description.append(" (FirstMatch)");
            error |= AddMemberToObject<Json_string>(obj, "semijoin_strategy",
                                                    "firstmatch");
        }
    }
    children->push_back({path->nested_loop_join().outer});
    children->push_back({path->nested_loop_join().inner});
    break;
}
```

连接类型映射：

```c
// join_optimizer/explain_access_path.cc:324
string JoinTypeToString(JoinType join_type) {
  switch (join_type) {
    case JoinType::INNER:
      return "inner join";
    case JoinType::OUTER:
      return "left join";
    case JoinType::ANTI:
      return "anti join";
    case JoinType::SEMI:
      return "semijoin";
    case JoinType::OUTER_SEMI:
      return "outer semijoin";
  }
}
```

### 5.6 HASH_JOIN → 哈希连接

```c
// join_optimizer/explain_access_path.cc:1540
case AccessPath::HASH_JOIN: {
    const JoinPredicate *predicate = path->hash_join().join_predicate;
    RelationalExpression::Type type = path->hash_join().rewrite_semi_to_inner
                                          ? RelationalExpression::INNER_JOIN
                                          : predicate->expr->type;
    THD *const thd = current_thd;

    string json_join_type;
    description = HashJoinTypeToString(type, &json_join_type);

    // 哈希连接条件序列化
    vector<HashJoinCondition> equijoin_conditions;
    equijoin_conditions.reserve(predicate->expr->equijoin_conditions.size());
    for (Item_eq_base *cond : predicate->expr->equijoin_conditions) {
        equijoin_conditions.emplace_back(cond, thd->mem_root);
    }

    // 生成哈希条件文本：<hash>(left)=<hash>(right)
    if (!equijoin_conditions.empty()) {
        for (const HashJoinCondition &hj_cond : equijoin_conditions) {
            if (!hj_cond.store_full_sort_key()) {
                condition_str = "(<hash>(" + ItemToString(hj_cond.left_extractor()) +
                               ")=<hash>(" + ItemToString(hj_cond.right_extractor()) + "))";
            } else {
                condition_str = ItemToString(hj_cond.join_condition());
            }
            description.append(" " + condition_str);
        }
    }

    error |= AddMemberToObject<Json_string>(obj, "join_algorithm", "hash");
    children->push_back({path->hash_join().outer});
    children->push_back({path->hash_join().inner, "Hash"});
    break;
}
```

哈希连接在 TREE 格式中的输出示例：
```
-> Hash inner join  (<hash>(t1.id)=<hash>(t2.id))  (cost=X..Y rows=Z)
    -> Table scan on t1  (cost=... rows=...)
    -> Hash
        -> Table scan on t2  (cost=... rows=...)
```

### 5.7 SORT → 排序节点

```c
// join_optimizer/explain_access_path.cc:1705
case AccessPath::SORT: {
    error |= AddMemberToObject<Json_string>(obj, "access_type", "sort");
    if (path->sort().force_sort_rowids) {
        description = "Sort row IDs";
        error |= AddMemberToObject<Json_boolean>(obj, "row_ids", true);
    } else {
        description = "Sort";
    }
    if (path->sort().remove_duplicates) {
        description += " with duplicate removal: ";
        error |= AddMemberToObject<Json_boolean>(obj, "duplicate_removal", true);
    } else {
        description += ": ";
    }

    // 列出排序字段
    for (ORDER *order = path->sort().order; order != nullptr;
         order = order->next) {
        string sort_field;
        if (const Item *item = *order->item;
            item->item_name.is_set() && item->type() != Item::FIELD_ITEM) {
            sort_field = item->item_name.ptr();  // 使用别名
        } else {
            sort_field = ItemToString(item);     // 使用完整表达式
        }
        if (order->direction == ORDER_DESC) {
            sort_field += " DESC";
        }
        description += sort_field;
    }

    if (const ha_rows limit = path->sort().limit; limit != HA_POS_ERROR) {
        error |= AddMemberToObject<Json_int>(obj, "per_chunk_limit", limit);
    }
    children->push_back({path->sort().child});
    break;
}
```

### 5.8 MATERIALIZE → 物化

`MATERIALIZE` 是最复杂的节点之一，涉及派生表、CTE（公用表表达式）和 UNION 的物化。

```c
// join_optimizer/explain_access_path.cc:1080
static unique_ptr<Json_object> ExplainMaterializeAccessPath(
    const AccessPath *path, JOIN *join, unique_ptr<Json_object> ret_obj,
    vector<ExplainChild> *children, bool explain_analyze) {
  Json_object *obj = ret_obj.get();
  bool error = false;
  MaterializePathParameters *param = path->materialize().param;

  // CTE 只打印一次计划
  const bool explain_cte_now = param->cte != nullptr && [&]() {
    if (explain_analyze) {
      if (path->iterator == nullptr ||
          path->iterator->GetProfiler()->GetNumInitCalls() == 0) {
        return param->table == param->cte->tmp_tables[0]->table &&
               std::none_of(param->cte->tmp_tables.cbegin(),
                            param->cte->tmp_tables.cend(),
                            [](const Table_ref *tab) {
                              return tab->table->materialized;
                            });
      } else {
        return true;  // CTE 在此物化
      }
    } else {
      return param->table == param->cte->tmp_tables[0]->table;
    }
  }();

  const bool is_set_operation = param->m_operands.size() > 1;
  const bool doing_dedup = MaterializeIsDoingDeduplication(param->table);

  if (param->cte != nullptr) {
    error |= AddMemberToObject<Json_boolean>(obj, "cte", true);
    if (param->cte->recursive) {
      // 递归 CTE 特殊处理
      error |= AddMemberToObject<Json_boolean>(obj, "recursive", true);
    }
  }
  // ...
}
```

---

## 6. 代价与行数注入 — AddPathCosts

`AddPathCosts()` (`explain_access_path.cc:1003`) 负责向 JSON 对象中注入估计值和 ANALYZE 实测值：

```c
// join_optimizer/explain_access_path.cc:1003
static bool AddPathCosts(const AccessPath *path,
                         const AccessPath *materialized_path, Json_object *obj,
                         bool explain_analyze) {
  const AccessPath *table_path;
  double cost, subquery_cost;

  GetMaterializationInfo(path, &table_path, &subquery_cost);

  if (materialized_path == nullptr) {
    if (table_path == nullptr) {
      cost = std::max(0.0, path->cost());
    } else {
      // 物化路径的成本特殊处理：使用 init_cost()
      cost = path->init_cost();
    }
  } else {
    assert(materialized_path->cost() >= 0.0);
    cost = materialized_path->cost();
  }

  if (path->num_output_rows() >= 0.0) {
    double init_cost;
    if (materialized_path == nullptr) {
      init_cost = (table_path == nullptr) ? path->init_cost() : cost;
    } else {
      init_cost = materialized_path->init_cost();
    }

    if (init_cost >= 0.0) {
      error |= AddMemberToObject<Json_double>(
          obj, "estimated_first_row_cost",
          FirstRowCost(init_cost, cost, path->num_output_rows()));
    }
    error |= AddMemberToObject<Json_double>(obj, "estimated_total_cost", cost);
    error |= AddMemberToObject<Json_double>(
        obj, "estimated_rows",
        path->type == AccessPath::MATERIALIZE
            ? path->materialize().subquery_rows
            : path->num_output_rows());
  }

  // EXPLAIN ANALYZE 实际执行数据的注入
  if (explain_analyze) {
    int num_init_calls = 0;
    if (path->iterator != nullptr) {
      const IteratorProfiler *const profiler = path->iterator->GetProfiler();
      if ((num_init_calls = profiler->GetNumInitCalls()) != 0) {
        error |= AddMemberToObject<Json_double>(
            obj, "actual_first_row_ms",
            profiler->GetFirstRowMs() / profiler->GetNumInitCalls());
        error |= AddMemberToObject<Json_double>(
            obj, "actual_last_row_ms",
            profiler->GetLastRowMs() / profiler->GetNumInitCalls());
        error |= AddMemberToObject<Json_double>(
            obj, "actual_rows",
            static_cast<double>(profiler->GetNumRows()) / num_init_calls);
        error |= AddMemberToObject<Json_int>(obj, "actual_loops", num_init_calls);
      }
    }
    if (num_init_calls == 0) {
      error |= AddMemberToObject<Json_null>(obj, "actual_first_row_ms");
      error |= AddMemberToObject<Json_null>(obj, "actual_last_row_ms");
      error |= AddMemberToObject<Json_null>(obj, "actual_rows");
      error |= AddMemberToObject<Json_null>(obj, "actual_loops");
    }
  }
  return error;
}
```

成本归属的注释解释了物化路径中的成本反转问题：

```c
// join_optimizer/explain_access_path.cc:970
/*
  物化 AccessPath 有一个子路径（table_path）遍历物化行。
  codewise 上 table_path 是 materialized_path 的子节点，但在 EXPLAIN 
  输出中显示为父节点。成本需要补偿：

  - table_path 的成本 = materialized_path 的成本（包括物化和后代）
  - materialized_path 的成本 = 后代的成本 + 物化成本

  例如：
    .-> Sort: i  (cost=8.45..8.45 rows=10)
    .    -> Table scan on <union temporary>  (cost=1.76..4.12 rows=10)
    .        -> Union materialize with dedup (cost=1.50..1.50 rows=10)
    .            -> Table scan on t1  (cost=0.05..0.25 rows=5)
    .            -> Table scan on t2  (cost=0.05..0.25 rows=5)
*/
```

---

## 7. optimizer_trace — 优化器决策追踪

### 7.1 Opt_trace_context — 追踪上下文

`Opt_trace_context` (`opt_trace_context.h`) 是每个会话的追踪上下文，保存在 `THD::opt_trace` 中：

```c
// opt_trace_context.h:94
class Opt_trace_context {
 public:
  Opt_trace_context() : pimpl(nullptr), I_S_disabled(0) {}
  ~Opt_trace_context();

  // 启动新的追踪
  bool start(bool support_I_S, bool support_dbug_or_missing_priv,
             bool end_marker, bool one_line, long offset, long limit,
             ulong max_mem_size, ulonglong features);

  // 结束当前追踪
  void end();

  // 检查追踪是否启用
  bool is_started() const {
    return unlikely(pimpl != nullptr) && pimpl->current_stmt_in_gen != nullptr;
  }

  // 是否支持 I_S (information_schema)
  bool support_I_S() const;

  // 设置原始查询文本
  void set_query(const char *query, size_t length, const CHARSET_INFO *charset);

  // 检查优化器功能是否被追踪
  bool feature_enabled(feature_value f) const {
    return unlikely(pimpl != nullptr) && (pimpl->features & f);
  }

  // 获取当前正在生成的追踪语句
  Opt_trace_stmt *get_current_stmt_in_gen() {
    return pimpl->current_stmt_in_gen;
  }

  // 特性名称
  static const char *feature_names[];
  enum feature_value {
    GREEDY_SEARCH = 1 << 0,
    RANGE_OPTIMIZER = 1 << 1,
    DYNAMIC_RANGE = 1 << 2,
    REPEATED_SUBSELECT = 1 << 3,
    MISC = 1 << 7,  // 始终启用
  };

 private:
  class Opt_trace_context_impl {
   public:
    Opt_trace_stmt *current_stmt_in_gen;  // 当前生成中的追踪
    Opt_trace_stmt_array stack_of_current_stmts;  // 子语句栈
    Opt_trace_stmt_array all_stmts_for_I_S;       // 所有追踪
    Opt_trace_stmt_array all_stmts_to_del;        // 待删除追踪
    bool end_marker;
    bool one_line;
    feature_value features;
    long offset, limit;
    size_t max_mem_size;
    long since_offset_0;
    UnstructuredTrace *m_unstructured_trace{nullptr};
  };

  Opt_trace_context_impl *pimpl;  // 惰性堆分配
  int I_S_disabled;
};
```

### 7.2 Opt_trace_struct / Opt_trace_object / Opt_trace_array — RAII 追踪 API

`opt_trace.h` 定义了 RAII（资源获取即初始化）风格的追踪 API。开发者使用局部变量创建追踪结构，析构函数自动结束：

```c
// opt_trace.h:446
class Opt_trace_struct {
 protected:
  Opt_trace_struct(Opt_trace_context *ctx_arg, bool requires_key_arg,
                   const char *key, Opt_trace_context::feature_value feature)
      : started(false), requires_key(false), has_disabled_I_S(false),
        empty(false), stmt(nullptr), saved_key(nullptr) {
    if (unlikely(ctx_arg->is_started())) {
      do_construct(ctx_arg, requires_key_arg, key, feature);
    }
  }
  ~Opt_trace_struct() {
    if (unlikely(started)) do_destruct();
  }

 public:
  // 添加各种类型的值
  Opt_trace_struct &add_alnum(const char *key, const char *value);
  Opt_trace_struct &add_utf8(const char *key, const char *value,
                             size_t val_length);
  Opt_trace_struct &add(const char *key, const Item *item);
  Opt_trace_struct &add(const char *key, bool value);
  Opt_trace_struct &add(const char *key, int value);
  Opt_trace_struct &add(const char *key, double value);
  Opt_trace_struct &add_utf8_table(const Table_ref *tab);
  Opt_trace_struct &add(const char *key, const Cost_estimate &cost);

 private:
  bool started;
  bool requires_key;   // true: JSON 对象, false: JSON 数组
  bool has_disabled_I_S;
  bool empty;
  Opt_trace_stmt *stmt;
  const char *saved_key;
};
```

`Opt_trace_object` 和 `Opt_trace_array` 继承自 `Opt_trace_struct`，仅区别在于构造函数：

```c
// opt_trace.h:802
class Opt_trace_object : public Opt_trace_struct {
 public:
  Opt_trace_object(Opt_trace_context *ctx, const char *key = nullptr,
                   Opt_trace_context::feature_value feature =
                       Opt_trace_context::MISC)
      : Opt_trace_struct(ctx, /*requires_key=*/true, key, feature) {}
  Opt_trace_object(Opt_trace_context *ctx, const char *key,
                   Opt_trace_context::feature_value feature,
                   const char *saved_key)
      : Opt_trace_struct(ctx, /*requires_key=*/true, key, feature) {
    set_saved_key(saved_key);
  }
};

// opt_trace.h:832
class Opt_trace_array : public Opt_trace_struct {
 public:
  Opt_trace_array(Opt_trace_context *ctx, const char *key = nullptr,
                  Opt_trace_context::feature_value feature =
                      Opt_trace_context::MISC)
      : Opt_trace_struct(ctx, /*requires_key=*/false, key, feature) {}
};
```

使用示例（来自 opt_trace.h 文档注释）：

```c
// 示例: 在 advance_sj_state() 中使用追踪
{
  Opt_trace_array trace_choices(trace, "semijoin_strategy_choice");
  {
    Opt_trace_object trace_one_strategy(trace);
    trace_one_strategy.add_alnum("strategy", "FirstMatch");
    trace_one_strategy.add("cost", *current_read_time).
                        add("records", *current_record_count);
    trace_one_strategy.add("chosen", (pos->sj_strategy == SJ_OPT_FIRST_MATCH));
  }
  {
    Opt_trace_object trace_one_strategy(trace);
    trace_one_strategy.add_alnum("strategy", "DuplicatesWeedout");
    trace_one_strategy.add("cost", 1.1).
                        add("records", 1);
    trace_one_strategy.add("duplicate_tables_left", false);
    trace_one_strategy.add("chosen", false);
  }
}
```

产生的 JSON 输出：
```json
"semijoin_strategy_choice": [
  {
    "strategy": "FirstMatch",
    "cost": 1,
    "records": 1,
    "chosen": true
  },
  {
    "strategy": "DuplicatesWeedout",
    "cost": 1.1,
    "records": 1,
    "duplicate_tables_left": false,
    "chosen": false
  }
]
```

### 7.3 追踪启用路径

```c
// opt_trace_context.h
// 用户通过 SET SESSION optimizer_trace="enabled=on" 启用
// 追踪由 mysql_execute_command() 在每条语句执行前启动
// Opt_trace_start (在 sql_parse.cc 中) 负责在语句开始处调用
// Opt_trace_context::start()

// 特性控制：
// SET optimizer_trace_features="greedy_search=on|off,...";
// 每个 trace 构造时指定所属 feature，在 enabled=false 时跳过
```

### 7.4 追踪存储与信息架构

`Opt_trace_iterator` 用于遍历所有已保存的追踪，供 `information_schema.OPTIMIZER_TRACE` 查询：

```c
// opt_trace.h:309
struct Opt_trace_info {
  const char *trace_ptr;     // 追踪内容
  size_t trace_length;
  const char *query_ptr;     // 原始查询
  size_t query_length;
  const CHARSET_INFO *query_charset;
  size_t missing_bytes;      // 因 max_mem_size 截断的字节数
  bool missing_priv;         // 用户无权限查看
};

class Opt_trace_iterator {
 public:
  Opt_trace_iterator(Opt_trace_context *ctx);
  void next();
  void get_value(Opt_trace_info *info) const;
  bool at_end() const { return cursor == nullptr; }
};
```

---

## 8. 关键函数索引

| 函数 | 文件:行 | 功能 |
|------|---------|------|
| `mysql_explain_query_expression()` | `opt_explain.cc:2394` | EXPLAIN 入口分派（简单查询 → `explain_query_specification()`，集合查询 → `unit->explain()`）|
| `ExplainIterator()` | `opt_explain.cc:129` | 迭代器格式 EXPLAIN 入口（FORMAT=TREE/JSON）|
| `PrintQueryPlan(ethd, query_thd, unit)` | `explain_access_path.cc:2208` | AccessPath → JSON → 字符串的主转换 |
| `PrintQueryPlan(level, path, join, ...)` | `explain_access_path.cc:2275` | 调试用的 PrintQueryPlan 重载 |
| `ExplainQueryPlan()` | `explain_access_path.cc:903` | AccessPath → JSON 对象（处理 DML 包装）|
| `ExplainAccessPath()` | `explain_access_path.cc:2077` | 递归遍历 AccessPath 树，生成 JSON 节点 |
| `SetObjectMembers()` | `explain_access_path.cc:1177` | 核心 switch——按 type 填充 JSON字段和子节点 |
| `AddPathCosts()` | `explain_access_path.cc:1003` | 注入 estimated_* 和 actual_* 统计 |
| `ExplainMaterializeAccessPath()` | `explain_access_path.cc:1080` | 物化路径的 JSON 生成（CTE/UNION/派生表）|
| `AssignParentPath()` | `explain_access_path.cc:674` | 将子路径置于物化路径之上 |
| `ExplainNoAccessPath()` | `explain_access_path.cc:2138` | 无 AccessPath 的解释（INSERT VALUES）|
| `SetIndexInfoInObject()` | `explain_access_path.cc:408` | 生成索引访问的描述文本和 JSON 字段 |
| `ExplainIndexSkipScanAccessPath()` | `explain_access_path.cc:720` | 索引跳跃扫描的 JSON 描述 |
| `ExplainGroupIndexSkipScanAccessPath()` | `explain_access_path.cc:1553` | 分组索引跳跃扫描的 JSON 描述 |
| `GetMaterializationInfo()` | `explain_access_path.cc:987` | 获取物化路径的 table_path 和 subquery_cost |
| `PrintRanges()` | `explain_access_path.cc:436` | 范围数组的 JSON 和文本序列化 |
| `AddTableInfoToObject()` | `explain_access_path.cc:304` | 向 JSON 添加表名、schema、使用的列 |
| `AccessPathTypeName()` | `access_path.cc:351` | AccessPath::Type 枚举 → 字符串 |
| `JoinTypeToString()` | `explain_access_path.cc:324` | JoinType 枚举 → "inner join"/"left join" 等 |
| `HashJoinTypeToString()` | `explain_access_path.cc:340` | RelationalExpression::Type → 哈希连接类型 |
| `DoesDeduplicate()` | `explain_access_path.cc:1038` | 检查路径是否做去重 |
| `NewTableScanAccessPath()` | `access_path.h:1395` | 创建 TABLE_SCAN AccessPath |
| `NewIndexScanAccessPath()` | `access_path.h:1408` | 创建 INDEX_SCAN AccessPath |
| `NewRefAccessPath()` | `access_path.h:1429` | 创建 REF AccessPath |
| `NewHashJoinAccessPath()` | `access_path.h:1461` | 创建 HASH_JOIN AccessPath |
| `CopyBasicProperties()` | `access_path.h:1373` | 复制 AccessPath 的基础属性 |
| `Explain_format::ExplainJsonToString()` | `opt_explain_traditional.h:88` | 将 JSON 对象转为最终字符串 |
| `Explain_format_tree::ExplainPrintTreeNode()` | `explain_access_path.cc:2380` | 递归打印 TREE 格式 |
| `Explain_format_tree::ExplainPrintCosts()` | `explain_access_path.cc:2416` | 打印（cost=... rows=...）和 actual 统计 |
| `Explain_format_traditional::flush_entry()` | `opt_explain_traditional.cc:214` | 输出一行传统格式 |
| `Explain_format_traditional::push_select_type()` | `opt_explain_traditional.cc:187` | 推送 select_type 列值 |
| `print_query_for_explain()` | `opt_explain.cc:2100` | 生成重写后的 SQL 查询文本 |
| `Explain::shallow_explain()` | `opt_explain.cc:459` | 传统格式的核心解释逻辑 |
| `Opt_trace_context::start()` | `opt_trace_context.h:125` | 启动优化器追踪 |
| `Opt_trace_context::end()` | `opt_trace_context.h:140` | 结束优化器追踪 |
| `Opt_trace_object::Opt_trace_object()` | `opt_trace.h:802` | 创建 JSON 对象追踪节点（RAII） |
| `Opt_trace_array::Opt_trace_array()` | `opt_trace.h:832` | 创建 JSON 数组追踪节点（RAII） |
| `Opt_trace_struct::add_alnum()` | `opt_trace.h:487` | 添加 ASCII 字符串值到追踪 |
| `Opt_trace_struct::add_utf8()` | `opt_trace.h:508` | 添加 UTF-8 字符串值到追踪 |
| `Opt_trace_iterator::get_value()` | `opt_trace.h:319` | 读取 I_S.OPTIMIZER_TRACE 可用追踪 |
| `Query_result_null::send_data()` | `opt_explain.cc:2084` | EXPLAIN ANALYZE 中丢弃实际输出但仍求值子查询 |
| `GetForceSubplanToken()` | `explain_access_path.cc:2296` | 生成 force_subplan 的 SHA256 token |
| `WalkAccessPaths()` | `access_path.h:1725` | 遍历 AccessPath 树的通用访问器 |

---

## 附录：EXPLAIN 内部数据流图

```
EXPLAIN [FORMAT=TRADITIONAL]
  → mysql_explain_query_expression()                  [opt_explain.cc:2394]
    → explain_query_specification()                   [opt_explain.cc:2292]
      → Explain (基类) 创建                            [opt_explain.cc:144]
      → Explain::shallow_explain()                    [opt_explain.cc:459]
      → 迭代 JOIN::qep_tab 数组
      → qep_row 填充 → Explain_format_traditional::flush_entry()
        [opt_explain_traditional.cc:214]

EXPLAIN FORMAT=TREE / FORMAT=JSON (超图)
  → mysql_explain_query_expression()
    → ExplainIterator()                               [opt_explain.cc:129]
      → PrintQueryPlan()                             [explain_access_path.cc:2208]
        → ExplainQueryPlan()                         [explain_access_path.cc:903]
          → ExplainAccessPath() (递归)               [explain_access_path.cc:2077]
            → SetObjectMembers() (switch on type)    [explain_access_path.cc:1177]
            → AddPathCosts()                          [explain_access_path.cc:1003]
            → AddChildrenToObject() (递归子节点)
        → Explain_format_tree::ExplainJsonToString() [explain_access_path.cc:2354]

EXPLAIN ANALYZE
  → ExplainIterator()
    → 先用 Query_result_null 执行原查询                [opt_explain.cc:2084]
    → 然后 PrintQueryPlan() (实际数据来自 IteratorProfiler)
```
