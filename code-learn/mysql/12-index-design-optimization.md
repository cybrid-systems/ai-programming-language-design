# 12-index-design-optimization — MySQL 索引设计与优化

## 0. 概述

索引是关系数据库性能的核心。MySQL/InnoDB 使用 B+Tree 作为主索引结构，其实现横跨 InnoDB 存储引擎层和 MySQL Server 层的优化器。理解索引的**物理存储**（B+Tree 结构）、**元数据结构**（`dict_index_t`、`dict_field_t`）、**优化器如何选择索引**（`find_best_ref()`、`get_index_for_order()`）、以及**执行层的增强特性**（ICP、MRR、覆盖索引），是设计和优化索引的前提。

本章从源码层面深入 MySQL 索引设计的所有关键环节：

```
索引生命周期：
  创建 (dict_create_index / btr_create)
    → 元数据 (dict_index_t / dict_field_t / KEY)
    → 优化器选择 (JOIN::optimize → find_best_ref / get_index_for_order)
    → 执行 (btr_cur_search_to_nth_level / ICP / MRR)
    → 维护 (btr_compress / btr_page_split / OPTIMIZE TABLE)
    → 监控 (INNODB_INDEXES / SHOW INDEX)
```

### 0.1 索引在 InnoDB 中的物理存储

每个索引对应一棵 B+Tree。聚簇索引（`DICT_CLUSTERED`）的叶子节点存储完整数据行；二级索引的叶子节点存储索引键 + 聚簇索引键（主键值）。

```
聚簇索引（Clustered Index）:     二级索引（Secondary Index）:
┌──────────────┐                 ┌──────────────┐
│  根节点 L2   │                 │  根节点 L2   │
│  (page=N)   │                 │  (page=M)   │
└──────┬───────┘                 └──────┬───────┘
       │                                │
┌──────┴───────┐                 ┌──────┴───────┐
│ 内部节点 L1  │                 │ 内部节点 L1  │
└──────┬───────┘                 └──────┬───────┘
       │                                │
┌──────┴──────────────┐         ┌──────┴──────────────┐
│ 叶子节点 L0         │         │ 叶子节点 L0         │
│ (完整行数据)         │         │ (键值 + 主键)       │
│ ← → ← → (双向链表)  │         │ ← → ← → (双向链表)  │
└─────────────────────┘         └─────────────────────┘
```

- **聚簇索引**：每个表只有一个。叶子页通过 `FIL_PAGE_PREV` / `FIL_PAGE_NEXT` 形成双向链表（`fil0types.h:46`），支持高效范围扫描。
- **二级索引**：可能多个。需回表（通过主键值查找聚簇索引）才能获取完整行。
- **根页号**存储在 `dict_index_t::page`。
- B+Tree 最大深度由 `BTR_MAX_LEVELS = 100` 定义（`btr0btr.h`），实际通常 3-5 层。

### 0.2 聚簇索引 vs 二级索引的关键差异

| 维度 | 聚簇索引 | 二级索引 |
|------|---------|---------|
| 类型标志 | `DICT_CLUSTERED` | 无 `DICT_CLUSTERED` |
| 叶子数据 | 完整行（含隐藏列） | 索引列 + 主键值 |
| 唯一性 | 始终唯一（由主键或 `row_id` 保证） | 可选（`DICT_UNIQUE`） |
| 回表 | 不需要 | 需要 |
| 锁机制 | 行锁直接作用 | `next-key lock` 通过回表加锁 |
| 数量 | 1 | 0~N |

### 0.3 索引选择性与基数

优化器依赖**索引统计信息**（`dict_index_stats_t`）来估算每个索引的效率。核心指标：

- **`n_diff_key_vals[i]`**：前 i+1 列的不同键值数——即**基数**（cardinality）。
- **`n_leaf_pages`**：叶子节点页数，决定全索引扫描代价。
- **回表代价**：对二级索引，每次回表 = 一次聚簇索引 B+Tree 搜索（`btr_cur_search_to_nth_level`）。

`rec_per_key` 是优化器的核心估计算子：`rows = table_rows / n_diff_key_vals[index][col]`。当无统计信息时，使用默认估计 `MATCHING_ROWS_IN_OTHER_TABLE`（见 `sql_planner.cc`）。

---

## 1. 核心数据结构

### 1.1 dict_index_t (dict0mem.h:1067) — 索引元数据结构

`dict_index_t` 是 InnoDB 在内存中描述一个索引的对象，包含从索引 ID、名称、类型到统计信息的全部元数据：

```c
// dict0mem.h:1067
struct dict_index_t {
  /** index id */
  space_index_t id;

  /** memory heap */
  mem_heap_t *heap;

  /** index name */
  id_name_t name;

  /** table name */
  const char *table_name;

  /** back pointer to table */
  dict_table_t *table;

  /** space where the index tree is placed */
  unsigned space : 32;

  /** index tree root page number */
  unsigned page : 32;

  /** merge threshold in percent (default 50) */
  unsigned merge_threshold : 6;

  /** index type (DICT_CLUSTERED, DICT_UNIQUE, DICT_IBUF, DICT_CORRUPT) */
  unsigned type : DICT_IT_BITS;

  /** offset of trx_id in clustered index record, if the fields
  before it are known to be of a fixed size, 0 otherwise */
  unsigned trx_id_offset : MAX_KEY_LENGTH_BITS;

  /** number of user-defined columns */
  unsigned n_user_defined_cols : 10;

  /** allow duplicate values even if index created with unique constraint */
  unsigned allow_duplicates : 1;

  /** SQL NULL == SQL NULL */
  unsigned nulls_equal : 1;

  /** disable AHI (Adaptive Hash Index) */
  unsigned disable_ahi : 1;

  /** number of fields from the beginning which uniquely determine an entry */
  unsigned n_uniq : 10;

  /** number of fields defined so far */
  unsigned n_def : 10;

  /** number of fields in the index */
  unsigned n_fields : 10;

  /** number of total fields (including INSTANT dropped fields) */
  unsigned n_total_fields : 10;

  /** number of nullable fields */
  unsigned n_nullable : 10;

  /** nullable fields before first instant ADD COLUMN */
  unsigned n_instant_nullable : 10;

  /** true if the index object is in the dictionary cache */
  unsigned cached : 1;

  /** true if the index is to be dropped */
  unsigned to_be_dropped : 1;

  /** enum online_index_status */
  unsigned online_status : 2;

  /** true for secondary indexes not yet committed to dd */
  unsigned uncommitted : 1;

  /** true if clustered index has instant columns */
  unsigned instant_cols : 1;

  /** true if clustered index and table has row versions */
  unsigned row_versions : 1;

  /** spatial reference id (SRID) */
  uint32_t srid;
  bool srid_is_valid;

  /** Cached spatial reference system for R-tree indexes */
  std::unique_ptr<dd::Spatial_reference_system> rtr_srs;

  /** array of field descriptions */
  dict_field_t *fields;

  /** Field pos sorted by physical position in record (for INSTANT DDL) */
  std::vector<uint16_t> fields_array;

  /** Number of nullable columns in each version (for INSTANT DDL) */
  uint32_t nullables[MAX_ROW_VERSION + 1] = {0};

  /** fulltext parser plugin (non-hotbackup) */
  st_mysql_ftparser *parser;
  bool is_ngram;
  bool has_new_v_col;
  bool hidden;

  /** list of indexes of the table */
  UT_LIST_NODE_T(dict_index_t) indexes;

  /** info used in optimistic searches (AHI) */
  btr_search_t *search_info;

  /** log of modifications during online index creation */
  row_log_t *online_log;

  /** Statistics for query optimization */
  dict_index_stats_t stats;

  /** cached last insert position (intrinsic table only) */
  last_ops_cur_t *last_ins_cur;

  /** cached last select position (intrinsic table only) */
  last_ops_cur_t *last_sel_cur;

  /** read-write lock protecting upper levels of the index tree */
  rw_lock_t lock;

  /** id of the transaction that created this index, or 0 */
  trx_id_t trx_id;
};
// dict0mem.h:1067-1215
```

关键字段语义：

| 字段 | 含义 |
|------|------|
| `id` | 全局唯一索引 ID，由 `space_index_t`（`uint32_t`）表示 |
| `space` | 表空间 ID，决定索引所在的 `.ibd` 文件 |
| `page` | B+Tree 根页的页号，`btr_create()` 返回 |
| `type` | 位掩码：`DICT_CLUSTERED=1`, `DICT_UNIQUE=2`, `DICT_IBUF=4`, `DICT_FTS=8`, `DICT_CORRUPT=16`, `DICT_SPATIAL=32` |
| `n_uniq` | 唯一确定一条记录的字段数。对聚簇索引 = 主键列数；对二级索引 = 索引列数 + 主键列数（含隐式扩展） |
| `n_fields` | 索引总字段数 |
| `online_status` | 在线 DDL 状态，取值见下方枚举 |
| `online_log` | 在线创建二级索引期间记录的增量修改日志 |
| `search_info` | AHI（自适应哈希索引）的搜索信息 |
| `stats` | 统计信息（`dict_index_stats_t`），用于优化器 |
| `lock` | 保护 B+Tree 非叶子节点的 `rw_lock_t`（`btr_search_latch` 的补充） |

在线 DDL 状态枚举：

```c
// dict0mem.h:1645
enum online_index_status {
  /** the index is complete and ready for access */
  ONLINE_INDEX_COMPLETE = 0,
  /** the index is being created, online (allowing concurrent modifications) */
  ONLINE_INDEX_CREATION,
  /** secondary index creation was aborted and the index
  should be dropped as soon as index->table->n_ref_count reaches 0 */
  ONLINE_INDEX_ABORTED,
  /** the online index creation was aborted, the index was
  dropped from the data dictionary and the tablespace */
  ONLINE_INDEX_ABORTED_DROPPED
};
// dict0mem.h:1645-1658
```

### 1.2 dict_field_t (dict0mem.h:891) — 索引字段定义

每个索引列对应一个 `dict_field_t`：

```c
// dict0mem.h:891
struct dict_field_t {
  dict_field_t() : col(nullptr), prefix_len(0), fixed_len(0), is_ascending(0) {}

  dict_col_t *col;            /*!< pointer to the table column */
  id_name_t name;             /*!< name of the column */
  unsigned prefix_len : 12;   /*!< 0 or column prefix length in bytes
                              for e.g., INDEX (textcol(25));
                              must be smaller than DICT_MAX_FIELD_LEN_BY_FORMAT */
  unsigned fixed_len : 10;    /*!< 0 or fixed length if smaller than
                              DICT_ANTELOPE_MAX_INDEX_COL_LEN */
  unsigned is_ascending : 1;  /*!< 0=DESC, 1=ASC */

  uint16_t get_phy_pos() const {
    if (prefix_len != 0) {
      return col->get_prefix_phy_pos();
    }
    return col->get_col_phy_pos();
  }
};
// dict0mem.h:891-901
```

每个字段的关键属性：

- **`col`**：指向表列（`dict_col_t`），通过它获得数据类型、长度、字符集等信息。
- **`prefix_len`**：列前缀索引长度（如 `INDEX(name(10))`），0 表示完整列。`get_phy_pos()` 会根据前缀长度选择物理偏移。
- **`fixed_len`**：定长列长度（0 表示不定长或长度 >= `DICT_ANTELOPE_MAX_INDEX_COL_LEN`）。
- **`is_ascending`**：排序方向。0 = DESC（MySQL 8.0+ 支持降序索引）。

### 1.3 dict_col_t (dict0mem.h:485) — 列定义

```c
// dict0mem.h:485
struct dict_col_t {
  /** Default value for instantly added column */
  dict_col_default_t *instant_default{nullptr};

  unsigned prtype : 32;  /*!< precise type: MySQL data type, charset code,
                          flags for nullability, signedness, binary string,
                          true VARCHAR (2-byte length) */
  unsigned mtype : 8;    /*!< main data type */

  unsigned len : 16;     /*!< length: field->pack_length() for MySQL data,
                          except that for true VARCHAR this is the max byte
                          length of string data */

  unsigned mbminmaxlen : 5; /*!< min and max byte length of a character:
                            DATA_MBMINMAXLEN(mbminlen, mbmaxlen) */

  unsigned ind : 10;        /*!< table column position (starting from 0) */
  unsigned ord_part : 1;    /*!< nonzero if this column appears in the
                            ordering fields of an index */
  unsigned max_prefix : 12; /*!< max index prefix length on this column */
};
// dict0mem.h:485-530
```

`mtype` 和 `prtype` 决定列的完整语义：

```c
// dtype0type.h（内部类型定义）
#define DATA_VARCHAR  5   /* true VARCHAR */
#define DATA_CHAR     1   /* fixed-length CHAR */
#define DATA_INT      6   /* integer */
#define DATA_FLOAT    7   /* float */
#define DATA_DOUBLE   8   /* double */
#define DATA_BLOB     12  /* BLOB/TEXT */
```

`prtype` 的高位还编码了 `DATA_NOT_NULL`、`DATA_UNSIGNED`、`DATA_BINARY_TYPE` 等标志位，以及字符集编号（`prtype >> 20`）。

### 1.4 dict_index_stats_t (dict0mem.h:1025) — 索引统计信息

```c
// dict0mem.h:1025
struct dict_index_stats_t {
#ifndef UNIV_HOTBACKUP
  /** approximate number of different key values for each n-column prefix,
  where 1 <= n <= n_uniq (indexed 0 to n_uniq-1) */
  uint64_t *n_diff_key_vals;

  /** number of pages sampled to calculate each n_diff_key_vals[] entry */
  uint64_t *n_sample_sizes;

  /** approximate number of non-null key values (for nulls_ignored stats_method) */
  uint64_t *n_non_null_key_vals;

  /** approximate index size in database pages */
  ulint index_size;
#endif /* !UNIV_HOTBACKUP */
  /** approximate number of leaf pages in the index tree */
  ulint n_leaf_pages;
};
// dict0mem.h:1025-1043
```

- **`n_diff_key_vals[i]`**：前 i+1 个列的基数（cardinality）。优化器用此估算 `rec_per_key`。
- **`n_leaf_pages`**：叶子页数。优化器用此估算全索引扫描代价。
- **`index_size`**：索引总页数（包含非叶子页）。
- 统计信息通过 `btr_estimate_number_of_different_key_vals()`（`btr0cur.cc:5390`）采样计算，采样页数由 `innodb_stats_transient_sample_pages` 控制（默认 8）。

### 1.5 KEY (MySQL Server 层) — 优化器视角的索引

InnoDB 的索引通过 `handler::info()` 与 Server 层的 `KEY` 结构桥接：

```c
// sql/handler.h — KEY structure (simplified)
struct KEY {
  KEY_PART_INFO *key_part;   // key part descriptors
  const char *name;          // index name
  const char **key_rec_per_key;  // record per key estimates
  float *rec_per_key_float;
  uint *rec_per_key;
  uint key_length;           // total key length in bytes
  ulonglong flags;           // HA_GENERATED_KEY, HA_FULLTEXT, etc.
  uint actual_key_parts;     // actual number of key parts
  uint user_defined_key_parts; // user-defined key parts
  uint table_flags;          // table-level flags
  bool is_visible;           // invisible index
  // ...
};
```

`actual_key_parts` vs `user_defined_key_parts` 的区别体现了 MySQL 对 InnoDB 二级索引的隐式扩展——`actual_key_parts` 包含了 InnoDB 自动追加的主键列。优化器通过 `actual_key_parts()` 函数（见 `sql_select.cc`）控制是否使用扩展键部分，受 `optimizer_switch` 中的 `use_index_extensions` 标志控制。

---

## 2. 索引创建

### 2.1 聚簇索引创建（dict_mem_index_create + dict_create_index）

InnoDB 创建聚簇索引的过程：当用户定义 `PRIMARY KEY` 时，使用用户指定的列；否则 InnoDB 自动创建 `GEN_CLUST_INDEX`——一个 6 字节 `row_id` 上的隐式聚簇索引。

```c
// storage/innobase/handler/ha_innodb.cc:12447
index = dict_mem_index_create(
    table_name, innobase_index_reserve_name, /* "GEN_CLUST_INDEX" */
    0, ind_type, n_fields);
```

`btr_create()` 负责物理创建 B+Tree 的根页：

```c
// btr0btr.cc:858
ulint btr_create(ulint type, space_id_t space, space_index_t index_id,
                 dict_index_t *index, mtr_t *mtr) {
  page_no_t page_no;
  buf_block_t *block;
  page_t *page;

  /* Create file segments for the index tree */
  if (type & DICT_IBUF) {
    /* ibuf tree: separate ibuf header page */
    buf_block_t *ibuf_hdr_block =
        fseg_create(space, 0, IBUF_HEADER + IBUF_TREE_SEG_HEADER, mtr);
    block = fseg_alloc_free_page(
        buf_block_get_frame(ibuf_hdr_block) + IBUF_HEADER + IBUF_TREE_SEG_HEADER,
        IBUF_TREE_ROOT_PAGE_NO, FSP_UP, mtr);
  } else {
    block = fseg_create(space, 0, PAGE_HEADER + PAGE_BTR_SEG_TOP, mtr);
  }

  page_no = block->page.id.page_no();

  if (!(type & DICT_IBUF)) {
    /* Create a file segment for leaf pages */
    if (!fseg_create(space, page_no,
                     PAGE_HEADER + PAGE_BTR_SEG_LEAF, mtr)) {
      btr_free_root(block, mtr);
      return (FIL_NULL);
    }
  }

  /* Initialize the page: set level=0 (leaf), set the infimum and
  supremum records, mark PAGE_N_RECS = 0 */
  page_create(block, mtr, dict_table_page_size(index->table),
              type, index);

  return (page_no);
}
// btr0btr.cc:858-930
```

创建流程：
1. `fseg_create()` 分配文件段（segment），非 ibuf 树会创建两个段：一棵用于叶子页（`PAGE_BTR_SEG_LEAF`），一棵用于内部页（`PAGE_BTR_SEG_TOP`）。
2. `page_create()` 初始化根页：设置 `PAGE_LEVEL = 0`，插入 infimum 和 supremum 记录，`PAGE_N_RECS = 0`。
3. 返回的 `page_no` 存储到 `dict_index_t::page`。

### 2.2 二级索引创建路径

二级索引的创建由 `CREATE INDEX` 触发，经过 `ha_innobase::create_index()` → `dict_mem_index_create()` → `dict_create_index()`。

在 InnoDB handler 中：

```c
// ha_innodb.cc:12260
index = dict_mem_index_create(table_name, key->name, 0, ind_type,
                              key->actual_key_parts);
// ...
index->n_uniq = key->actual_key_parts;
```

`ind_type` 包含了索引属性标志：

```c
ulint ind_type = 0;
if (key->flags & HA_NOSAME) ind_type |= DICT_UNIQUE;  // UNIQUE 索引
if (!(flags & DICT_CLUSTERED)) ind_type |= DICT_SECONDARY;
```

`dict_create_index()` 执行以下步骤：
1. 调用 `btr_create()` 创建 B+Tree 根页。
2. 将索引元数据插入 InnoDB 数据字典表 `SYS_INDEXES`。
3. 如果表非空，通过聚簇索引全扫描逐个插入索引条目。
4. 插入期间，对于非空表的索引创建，每批插入会以 mini-transaction 的形式写入 redo log。

### 2.3 在线 DDL：INPLACE vs COPY 算法

MySQL 5.6+ 支持的 `ALGORITHM=INPLACE` 实现了**在线索引创建**。其核心是 `online_index_status` 机制和 `online_log`：

```c
// dict0mem.h:1145-1148
/** enum online_index_status. Transitions from ONLINE_INDEX_COMPLETE (to
ONLINE_INDEX_CREATION) are protected by dict_operation_lock and
dict_sys->mutex. Other changes are protected by index->lock. */
unsigned online_status : 2;
```

在线二级索引创建的三阶段流程：

```
阶段 1：初始化
  - 分配新索引的 B+Tree（btr_create）
  - 设置 online_status = ONLINE_INDEX_CREATION
  - 创建 online_log 记录增量修改

阶段 2：构建索引数据
  - 以 S 锁或 SX 锁扫描聚簇索引
  - 提取键值插入新二级索引
  - 期间对聚簇索引的 INSERT/UPDATE/DELETE
    同时记录到 online_log

阶段 3：日志回放
  - row_log_apply() 将 online_log 中的增量修改
    应用到新建立的二级索引
  - 完成后设置 online_status = ONLINE_INDEX_COMPLETE
```

`online_log` 的结构：

```c
/** the log of modifications during online index creation;
valid when online_status is ONLINE_INDEX_CREATION */
row_log_t *online_log;
```

日志条目记录了每个 DML 操作的**行前镜像**和**行后镜像**，通过 `row_log_table_apply()`（`row0merge.cc`）回放到新索引。

### 2.4 索引创建期间的 redo log 记录

InnoDB 在索引创建期间通过 `mlog_write_ulint`、`mlog_write_string` 等函数记录 redo 日志。典型操作如写 `PAGE_N_RECS`：

```c
// page0page.cc
mlog_write_ulint(page + PAGE_HEADER + PAGE_N_RECS,
                 page_get_n_recs(page) + 1, MLOG_4BYTES, mtr);
```

`btr_create()` 本身不需要 redo 日志中的特殊记录——其页分配和初始化操作由 `fseg_create()` 和 `page_create()` 在 mtr 中自动记录。

对于 ALTER TABLE ... ALGORITHM=INPLACE 的在线 DDL，`dict_stats_update_transient_for_index()` 在 `btr_get_size()` 调用中会遇到 `ULINT_UNDEFINED`——因为在线 DDL 期间 B+Tree 的段分配尚未完成：

```c
// dict0stats.cc:800-820
size = btr_get_size(index, BTR_TOTAL_SIZE, &mtr);
if (size != ULINT_UNDEFINED) {
    index_stats->index_size = size;
    size = btr_get_size(index, BTR_N_LEAF_PAGES, &mtr);
}
mtr_commit(&mtr);

switch (size) {
    case ULINT_UNDEFINED:
        // Statistics are rebuilt at the end of
        // ha_innobase::commit_inplace_alter_table_impl()
        return;
    // ...
}
// dict0stats.cc:800-825
```

---

## 3. 索引选择

MySQL 优化器在 `JOIN::optimize()` 中为每个表选择合适的索引和访问路径。这部分代码分布在 `sql_optimizer.cc` 和 `sql_planner.cc` 中。

### 3.1 JOIN::optimize() — 优化器入口

```c
// sql_optimizer.cc:344
bool JOIN::optimize(bool finalize_access_paths) {
  DBUG_TRACE;
  // ...
  // Phase 1: Optimize derived tables/views
  for (Table_ref *tl = query_block->leaf_tables; tl; tl = tl->next_leaf) {
    if (tl->is_view_or_derived()) {
      if (tl->optimize_derived(thd)) return true;
    }
  }

  if (thd->lex->using_hypergraph_optimizer()) {
    // Use the hypergraph optimizer (MySQL 8.0+ experimental)
    // EnumerateAccessPaths() generates the AccessPath tree
  } else {
    // Use the traditional optimizer
    if (make_join_plan()) {  // -> Optimize_table_order::choose_table_order()
      return true;
    }
  }

  // Phase 2: Optimize ORDER BY / GROUP BY
  if (optimize_distinct_group_order()) {  // <- test_if_cheaper_ordering
    return true;
  }

  // Phase 3: Refine access methods (covering keys, ICP selection)
  if (finalize_access_paths) {
    for (auto &tab : qep_tab) {
      switch (tab.type()) {
        case JT_EQ_REF:
        case JT_REF:
          // Check covering index
          if (table->covering_keys.is_set(tab.ref().key) &&
              !table->no_keyread)
            table->set_keyread(true);
          else
            tab.push_index_cond(/* ICP pushdown */);
          break;

        case JT_RANGE:
        case JT_INDEX_MERGE:
          if (table->covering_keys.is_set(used_index(tab.range_scan())))
            table->set_keyread(true);
          if (!table->key_read)
            tab.push_index_cond(/* ICP pushdown */);
          break;
      }
    }
  }
  // ...
}
// sql_optimizer.cc:344-721
```

`JOIN::optimize()` 的主要决策点：
1. **传统 vs 超图优化器**：根据 `optimizer_switch` 中的 `hypergraph_optimizer` 选择。
2. **`make_join_plan()`**：传统优化器使用 `Optimize_table_order::choose_table_order()`，通过贪心 + 少量穷举搜索最佳表连接顺序和访问路径。
3. **`optimize_distinct_group_order()`**：检查 ORDER BY/GROUP BY 是否可以利用索引避免排序，内部调用 `get_index_for_order()`。
4. **`finalize_access_paths`**：决定是否启用覆盖索引读取（`set_keyread`）和 ICP 推入。

### 3.2 find_best_ref() — 等值查找的索引选择

在 `Optimize_table_order` 迭代连接顺序时，`find_best_ref()` 评估每个表在每个索引上做 `ref` 访问的代价：

```c
// sql_planner.cc:208
Key_use *Optimize_table_order::find_best_ref(
    const JOIN_TAB *tab, const table_map remaining_tables, const uint idx,
    const double prefix_rowcount, bool *found_condition,
    table_map *ref_depend_map, uint *used_key_parts) {
  Key_use *best_ref = nullptr;
  double best_ref_cost = DBL_MAX;

  TABLE *const table = tab->table();

  // Guessing distinct values when no statistics available
  ha_rows distinct_keys_est = tab->records() / MATCHING_ROWS_IN_OTHER_TABLE;

  // Test how we can use keys
  for (Key_use *keyuse = tab->keyuse();
       keyuse->table_ref == tab->table_ref;) {
    key_part_map found_part = 0;
    key_part_map const_part = 0;
    double cur_read_cost;
    double cur_fanout;
    uint cur_used_keyparts = 0;
    table_map table_deps = 0;
    const uint key = keyuse->key;
    const KEY *const keyinfo = table->key_info + key;

    enum idx_type cur_keytype =
        (keyuse->keypart == FT_KEYPART) ? FULLTEXT : NOT_UNIQUE;

    // Calculate how many key segments of the current key we can use
    Key_use *const start_key = keyuse;
    start_key->bound_keyparts = 0;

    // For each keypart, find the best equality predicate
    while (keyuse->table_ref == tab->table_ref &&
           keyuse->key == key) {
      const uint keypart = keyuse->keypart;
      table_map cur_keypart_table_deps = 0;
      double best_distinct_prefix_rowcount = DBL_MAX;

      // Check all equality predicates for this keypart
      for (; keyuse->table_ref == tab->table_ref &&
             keyuse->key == key && keyuse->keypart == keypart;
           ++keyuse) {
        // Skip if keyuse references tables outside the plan prefix
        if (keyuse->used_tables & ~remaining_tables) continue;

        // Prefer const comparisons (best selectivity)
        if (keyuse->used_tables == 0) {
          found_part |= 1U << keypart;
          const_part |= 1U << keypart;
          if (keyuse->null_rejecting || keyuse->opt_arg) {
            null_rejecting_part |= 1U << keypart;
          }
          table_deps = 0;
          cur_used_keyparts++;
        } else if (cur_keytype != FULLTEXT) {
          // Table-dependant ref access
          found_part |= 1U << keypart;
          table_deps |= keyuse->used_tables;
          cur_used_keyparts++;
        }
      }
    }

    // Compute cost for ref access on this index
    cur_read_cost = tab->table()->file->ref_cost(
        cur_used_keyparts, prefix_rowcount);

    // Estimate fanout using statistics or heuristic
    cur_fanout = tab->records();
    for (uint i = 0; i < cur_used_keyparts; i++) {
      if (const_part & (1U << i)) {
        // Const equality: use rec_per_key
        double rec_per_key = keyinfo->rec_per_key[i];
        cur_fanout = std::max(1.0, cur_fanout / rec_per_key);
      }
    }

    // Choose this index if cheaper
    double ref_cost = cur_read_cost + cur_fanout * ROW_EVALUATE_COST;
    ref_cost *= prefix_rowcount;

    if (ref_cost < best_ref_cost) {
      best_ref_cost = ref_cost;
      best_ref = start_key;
    }
  }

  return best_ref;
}
// sql_planner.cc:208-760
```

`find_best_ref()` 的核心逻辑：
1. **遍历每个索引**的每个 `Key_use`（优化器构建的可用索引条件集合）。
2. **对每个 keypart**，评估等值谓词：优先使用 **const 比较**（如 `WHERE col=5`），其次使用**表依赖比较**（如 `WHERE t1.col=t2.col`）。
3. **估算 fanout**：`rec_per_key` 来自统计信息 `n_diff_key_vals[0]`（第一列基数），估算每个匹配行数。
4. **比较代价**：`ref_cost = (ref I/O cost + row evaluate cost × fanout) × prefix_rowcount`。

### 3.3 get_index_for_order() — 排序的索引选择

当查询需要 ORDER BY 或 GROUP BY 时，`get_index_for_order()` 判断是否存在索引可以避免文件排序（filesort）：

```c
// sql_select.cc:5450
uint get_index_for_order(ORDER_with_src *order, TABLE *table, ha_rows limit,
                         AccessPath *range_scan, bool *need_sort,
                         bool *reverse) {
  // Single row select: always ordered
  if (range_scan && unique_key_range(range_scan)) {
    *need_sort = false;
    return MAX_KEY;
  }

  if (order->empty()) {
    *need_sort = false;
    if (range_scan)
      return used_index(range_scan);
    else
      return table->file->key_used_on_scan;
  }

  if (!is_simple_order(order->order)) {
    // Complex expression: must sort
    *need_sort = true;
    return MAX_KEY;
  }

  if (range_scan) {
    if (used_index(range_scan) == MAX_KEY) {
      *need_sort = true;
      return MAX_KEY;
    }

    uint used_key_parts;
    bool skip_path;
    switch (test_if_order_by_key(order, table, used_index(range_scan),
                                 &used_key_parts, &skip_path)) {
      case 1:   // desired order
        *need_sort = false;
        return used_index(range_scan);
      case 0:   // unacceptable order
        *need_sort = true;
        return MAX_KEY;
      case -1:  // opposite direction
        if (!skip_path && !make_reverse(used_key_parts, range_scan)) {
          *need_sort = false;
          return used_index(range_scan);
        } else {
          *need_sort = true;
          return MAX_KEY;
        }
    }
  } else if (limit != HA_POS_ERROR) {
    // LIMIT query: check if index scan + LIMIT is cheaper than filesort
    int key, direction;
    if (test_if_cheaper_ordering(nullptr, order, table,
                                 table->keys_in_use_for_order_by, -1, limit,
                                 &key, &direction, &limit)) {
      *need_sort = false;
      *reverse = (direction < 0);
      return key;
    }
  }
  *need_sort = true;
  return MAX_KEY;
}
// sql_select.cc:5450-5580
```

决策逻辑：
1. **唯一键范围**覆盖任何排序（只有 0 或 1 行结果）。
2. **空 ORDER BY** 不需要排序。
3. **简单 ORDER BY** 检查是否可以用同一索引（`test_if_order_by_key`）：返回 `1`→完全匹配；`-1`→方向相反（可反向扫描）；`0`→不可用。
4. **LIMIT 场景**：`test_if_cheaper_ordering()` 综合考虑扫描代价和 LIMIT 大小，判断索引顺序扫描是否比 filesort 更优。

`Optimize_table_order::test_if_cheaper_ordering()`（`sql_select.cc:5198`）使用更全面的代价估算：

```c
// sql_select.cc:5198-5450（test_if_cheaper_ordering 关键部分）
static bool test_if_cheaper_ordering(
    const JOIN_TAB *tab, ORDER_with_src *order,
    TABLE *table, Key_map usable_keys, int ref_key,
    ha_rows select_limit, int *new_key,
    int *new_key_direction, ha_rows *new_select_limit, ...) {
  bool is_best_covering = false;
  // ...

  for (uint nr = usable_keys.get_first();
       nr != usable_keys.get_last() + 1;
       ++nr) {
    if (!usable_keys.is_set(nr)) continue;

    const bool is_covering = table->covering_keys.is_set(nr) ||
        (ref_key >= 0 && table->covering_keys.is_set(ref_key));

    // If covering and cheaper than current best, choose this index
    if (ref_key < 0 ||
        (is_best_covering && !is_covering) ||
        (is_covering && refkey_select_limit < select_limit) ||
        (!is_covering && read_time < best_read_time)) {
      // Switch to this index for ordering
    }
  }
}
// sql_select.cc:5273-5407
```

### 3.4 索引统计信息

统计信息由 `dict_stats_update_transient_for_index()` 计算：

```c
// dict0stats.cc:766
static void dict_stats_update_transient_for_index(
    dict_index_t *index,
    dict_index_stats_t *index_stats) {
  // ...
  mtr_t mtr;
  mtr_start(&mtr);
  mtr_s_lock(dict_index_get_lock(index), &mtr, UT_LOCATION_HERE);

  size = btr_get_size(index, BTR_TOTAL_SIZE, &mtr);
  if (size != ULINT_UNDEFINED) {
    index_stats->index_size = size;
    size = btr_get_size(index, BTR_N_LEAF_PAGES, &mtr);
  }
  mtr_commit(&mtr);

  index_stats->n_leaf_pages = size;

  // Sample leaf pages to estimate cardinality
  btr_estimate_number_of_different_key_vals(index, index_stats);
}
// dict0stats.cc:766-840
```

`btr_estimate_number_of_different_key_vals()`（`btr0cur.cc:5390`）通过扫描随机采样的叶子页来计算 `n_diff_key_vals`：

```c
// btr0cur.cc:5390
bool btr_estimate_number_of_different_key_vals(
    dict_index_t *index, dict_index_stats_t *index_stats) {
  btr_cur_t cursor;
  uint64_t *n_diff;
  ulint n_cols = dict_index_get_n_unique(index);

  // Determine sample size
  ulint n_sample_pages;
  if (srv_stats_transient_sample_pages > index_stats->index_size) {
    n_sample_pages = (index_stats->index_size > 0) ?
                      index_stats->index_size : 1;
  } else {
    n_sample_pages = srv_stats_transient_sample_pages;
  }

  // Sample pages randomly from the index
  for (i = 0; i < n_sample_pages; i++) {
    mtr_start(&mtr);
    btr_cur_open_at_rnd_pos(index, BTR_SEARCH_LEAF, &cursor,
                            __FILE__, __LINE__, &mtr);
    page = btr_cur_get_page(&cursor);
    rec = page_rec_get_next(page_get_infimum_rec(page));

    // Count different key values for each prefix
    for (;;) {
      // Compare consecutive records, count changes
      cmp = cmp_rec_rec_with_match(rec, next_rec, offsets_rec, offsets_next_rec,
                                   index, true, &matched_fields);
      if (matched_fields > 0) {
        for (j = 0; j < matched_fields; j++) {
          n_diff[j]++;
        }
      }
      // ...
    }
    mtr_commit(&mtr);
  }

  // Scale estimates to whole index
  add_on = index_stats->n_leaf_pages / n_sample_pages;
  for (i = 0; i < n_cols; i++) {
    n_diff[i] = n_diff[i] * add_on + not_empty_flag;
  }

  index_stats->n_diff_key_vals = n_diff;
  return true;
}
// btr0cur.cc:5390-5530
```

采样算法：
1. 随机选择 `srv_stats_transient_sample_pages` 个叶页（默认 8），通过 `btr_cur_open_at_rnd_pos()` 定位。
2. 遍历页内所有记录，用 `cmp_rec_rec_with_match()` 比较相邻记录的前缀匹配情况。
3. 对每个匹配前缀长度 `j`，递增 `n_diff[j]`。
4. 缩放：`n_diff[i] = n_diff[i] × (总叶页数 / 采样页数)`。

### 3.5 基数估算与回表代价

优化器的回表代价计算：

```c
// handler::ref_cost — 从 SQL 层的代价估算
const double KEY_READ_COST = 1.0;       // 一次索引读
const double KEY_NEXT_COST = 0.1;       // 索引上连续一行
const double ROW_READ_COST = 2.0;       // 回表读（聚簇索引定位）
const double ROW_NEXT_COST = 0.2;       // 回表后连续一行
```

对二级索引 `ref` 访问，总代价 ≈ `KEY_READ_COST + rows × (ROW_READ_COST + ROW_NEXT_COST)`。

当 `rec_per_key` 未知（`REC_PER_KEY_UNKNOWN`）时，优化器使用启发式估值：

```c
// sql_planner.cc 中
ha_rows distinct_keys_est = tab->records() / MATCHING_ROWS_IN_OTHER_TABLE;
// MATCHING_ROWS_IN_OTHER_TABLE = 10（无统计时各表的行估计）
```

这意味着当统计信息缺失时，优化器保守估计每个等值匹配约 10 行。

---

## 4. 覆盖索引与索引下推

### 4.1 覆盖索引 (Covering Index) 原理

若查询所需的所有列都包含在同一个索引中，InnoDB 可以**只访问索引而不回表**。这通过在 Server 层设置 `table->key_read = true` 实现：

```c
// sql_select.cc:3450-3489 — 覆盖索引启用逻辑
switch (qep_tab->type()) {
  case JT_EQ_REF:
  case JT_REF_OR_NULL:
  case JT_REF:
  case JT_SYSTEM:
  case JT_CONST:
    if (table->covering_keys.is_set(qep_tab->ref().key) &&
        !table->no_keyread)
      table->set_keyread(true);   // 启用覆盖索引
    else
      qep_tab->push_index_cond(tab, qep_tab->ref().key, &trace_refine_table);
    break;

  case JT_RANGE:
  case JT_INDEX_MERGE:
    if (!table->no_keyread && qep_tab->type() == JT_RANGE) {
      if (table->covering_keys.is_set(used_index(qep_tab->range_scan()))) {
        assert(used_index(qep_tab->range_scan()) != MAX_KEY);
        table->set_keyread(true);  // 启用覆盖索引
      }
      if (!table->key_read)
        qep_tab->push_index_cond(tab, used_index(qep_tab->range_scan()),
                                 &trace_refine_table);
    }
    break;
}
// sql_select.cc:3445-3520
```

`covering_keys` 的初始化发生在 `TABLE_SHARE` 加载时：

```c
// sql/table.cc:6083
if (!invisible) {
  if (field_count == key_part_count)
    covering_keys.set_bit(keyno);  // 所有列都在索引中 = 可覆盖
  keys_in_use_for_group_by.set_bit(keyno);
  keys_in_use_for_order_by.set_bit(keyno);
}
// sql/table.cc:6080-6086
```

但注意 `covering_keys` 还会被 `opt_hints.cc` 缩减——禁用某些索引的提示（如 `NO_INDEX`）会清除其在 `covering_keys` 中的位：

```c
// opt_hints.cc:1220
Key_map covering_keys(tbl->keys_in_use_for_query);
covering_keys.merge(tbl->keys_in_use_for_group_by);
covering_keys.merge(tbl->keys_in_use_for_order_by);
tbl->covering_keys.intersect(covering_keys);
// opt_hints.cc:1220-1224
```

### 4.2 索引下推 (Index Condition Pushdown, ICP)

ICP 允许将部分 `WHERE` 条件下推到 InnoDB 存储引擎，在**索引记录层面**过滤，减少回表次数和回表后的过滤代价。

**Server 层的推送判断**（`sql_select.cc`）：

```c
// sql_select.cc:3058-3130 — push_index_cond()
void QEP_TAB::push_index_cond(const JOIN_TAB *tab, uint keyno,
                              Opt_trace_object *trace_obj) {
  // Criteria for ICP pushdown (7 conditions):
  // 1. Storage engine supports ICP (HA_DO_INDEX_COND_PUSHDOWN)
  // 2. Optimizer switch enables it, no NO_ICP hint
  // 3. Not multi-table UPDATE/DELETE
  // 4. Not subquery with guarded conditions (Full scan on NULL key)
  // 5. Not CONST or SYSTEM join type
  // 6. Not the clustered primary key (less benefit)
  // 7. Not virtual generated column index

  if (condition() &&
      tbl->file->index_flags(keyno, 0, true) & HA_DO_INDEX_COND_PUSHDOWN &&
      hint_key_state(join_->thd, table_ref, keyno, ICP_HINT_ENUM,
                     OPTIMIZER_SWITCH_INDEX_CONDITION_PUSHDOWN) &&
      join_->thd->lex->sql_command != SQLCOM_UPDATE_MULTI &&
      join_->thd->lex->sql_command != SQLCOM_DELETE_MULTI &&
      !has_guarded_conds() && type() != JT_CONST && type() != JT_SYSTEM &&
      !(keyno == tbl->s->primary_key &&
        tbl->file->primary_key_is_clustered())) {

    Item *idx_cond = make_cond_for_index(condition(), tbl, keyno, other_tbls_ok);
    if (idx_cond) {
      idx_cond->update_used_tables();
      if ((idx_cond->used_tables() & table_ref->map()) == 0) {
        // Condition only references other tables — skip push
        return;
      }
      // Push down to handler
      Item *idx_remainder_cond = tbl->file->idx_cond_push(keyno, idx_cond);
      // ...
    }
  }
}
// sql_select.cc:3058-3160
```

关键调用链：
1. `make_cond_for_index()` 从完整 `WHERE` 条件中提取出可通过索引列评估的**下推部分**。
2. `ha_innobase::idx_cond_push()` 将下推条件传给 InnoDB handler。
3. InnoDB 通过 `innobase_index_cond()`（`ha_innodb.cc:23867`）在扫描索引记录时评估条件：

```c
// ha_innodb.cc:23867 — InnoDB ICP 条件评估
ICP_RESULT innobase_index_cond(ha_innobase *h) {
  assert(h->pushed_idx_cond);
  assert(h->pushed_idx_cond_keyno != MAX_KEY);

  if (h->end_range && h->compare_key_icp(h->end_range) > 0) {
    return ICP_OUT_OF_RANGE;  // 已超出范围，终止扫描
  }

  return h->pushed_idx_cond->val_int() ? ICP_MATCH : ICP_NO_MATCH;
}
// ha_innodb.cc:23867-23880
```

ICP 的工作时序：

```
无 ICP：                           有 ICP：
扫描索引页 → 回表 → 过滤 WHERE      扫描索引页 → ICP 过滤 → (通过) → 回表
               × → 丢弃行                            × → 跳过回表
```

`make_cond_for_index()` 的逻辑（`sql_select.cc:2921`）：

```c
// sql_select.cc:2921
static Item *make_cond_for_index(Item *cond, TABLE *table, uint keyno,
                                  bool other_tbls_ok) {
  if (cond->type() == Item::COND_ITEM) {
    Item_cond *cond_item = (Item_cond *)cond;
    if (cond_item->functype() == Item_func::COND_AND_FUNC) {
      // For AND: extract conditions usable for each index part
      List_iterator<Item> li(*cond_item->argument_list());
      Item *item;
      while ((item = li++)) {
        Item *fix = make_cond_for_index(item, table, keyno, other_tbls_ok);
        if (fix) new_cond->add(fix);
      }
    }
    // OR: only push if entire OR branch is usable
  } else {
    // Leaf condition: check if it references only index columns
    if (exclude_index &&
        cond->marker == Item::MARKER_ICP_COND_USES_INDEX_ONLY) {
      // Skip conditions that fully match the index
    }
    // Check if condition can be evaluated using index columns
    if (!used_tables || other_tbls_ok) {
      // This condition can be pushed
    }
  }
}
// sql_select.cc:2921-3010
```

### 4.3 MRR (Multi-Range Read)

MRR 优化二级索引范围扫描的回表行为：将回表行 ID 排序后批量回表，将随机 I/O 转化为顺序 I/O。

**Server 层接口**（`handler.h`）：

```c
// handler.h: handler MRR interface
virtual int multi_range_read_init(RANGE_SEQ_IF *seq, void *seq_init_param,
                                  uint n_ranges, uint mode, HANDLER_BUFFER *buf);
virtual int multi_range_read_next(char **range_info);
virtual ha_rows multi_range_read_info_const(uint keyno, RANGE_SEQ_IF *seq, ...);
```

**InnoDB 实现**（`ha_innodb.cc:23820`）：

```c
// ha_innodb.cc:23820 — InnoDB MRR implementation via DS-MRR
int ha_innobase::multi_range_read_init(
    RANGE_SEQ_IF *seq, void *seq_init_param,
    uint n_ranges, uint mode, HANDLER_BUFFER *buf) {
  m_ds_mrr.init(table);
  return (m_ds_mrr.dsmrr_init(seq, seq_init_param, n_ranges, mode, buf));
}

int ha_innobase::multi_range_read_next(char **range_info) {
  return (m_ds_mrr.dsmrr_next(range_info));
}
// ha_innodb.cc:23825-23835
```

`m_ds_mrr` 是 `DsMrr_impl` 类型的成员，实现**磁盘感知的 MRR**（Disk-Sensitive MRR）。其工作流程：

```
MRR 执行时序：
multi_range_read_init()
  → dsmrr_init(): 初始化范围队列和缓冲区

for each range:
  → dsmrr_next() 返回下个范围
  → rowid 按页号排序（缓冲多个 rowid）
  → 批量回表（按物理顺序读取，减少随机 I/O）

最后 dsmrr_fill_buffer(): 填充排序后的行 ID
```

`DsMrr_impl` 的核心是**行 ID 排序**——在缓冲区中收集多个回表请求的 `(page_no, row_id)` 对，按 `page_no` 排序后依次读取。

---

## 5. 联合索引设计

### 5.1 最左前缀原则

MySQL 的 B+Tree 索引按字段定义顺序构建复合键。一个索引 `(a, b, c)` 实际上定义了三个**键前缀**：

- 前缀 1（`n_diff_key_vals[0]`）：列 `a` 的不同值
- 前缀 2（`n_diff_key_vals[1]`）：列 `(a, b)` 的不同值
- 前缀 3（`n_diff_key_vals[2]`）：列 `(a, b, c)` 的不同值

只有当 WHERE 条件使用**从左开始的连续前缀**时，索引才能生效。这直接体现在 `find_best_ref()` 的循环中：

```c
// sql_planner.cc —— 计算可用 keypart 数
while (keyuse->table_ref == tab->table_ref &&
       keyuse->key == key) {
  const uint keypart = keyuse->keypart;
  // 遍历每个 keypart
  for (; keyuse->table_ref == tab->table_ref &&
         keyuse->key == key && keyuse->keypart == keypart;
       ++keyuse) {
    if (keyuse->used_tables & ~remaining_tables)
      continue;  // 跳过对后续表的依赖
    // 成功绑定此 keypart
    found_part |= 1U << keypart;
    cur_used_keyparts++;
  }
}
```

如果跳过一个 keypart（如 `WHERE a=1 AND c=3`，未使用 b），则 `b` 之后的 keypart 无法用于索引定位——因为 B+Tree 的比较函数按**完整前缀**而非跳跃比较。

### 5.2 字段顺序选择

联合索引的字段顺序决定了索引的存储结构和过滤能力。影响顺序选择的因素：

**区分度优先原则**：将区分度高的列放在前面，减少扫描范围。

```c
// btr0cur.cc — 记录比较
cmp = cmp_rec_rec_with_match(rec, next_rec,
                             offsets_rec, offsets_next_rec,
                             index, true, &matched_fields);
// matched_fields 表示前 matched_fields 列相等
// 这一信息直接反映到 n_diff_key_vals[matched_fields-1]
```

**查询频率优先原则**：如果 `col_a` 同时出现在等值条件和高频查询中，即使区分度较低，也应前置。

**排序需求**：ORDER BY `col_a, col_b` 可以直接使用 `idx(col_a, col_b)` 避免 filesort——这由 `get_index_for_order()` 和 `test_if_order_by_key()` 判断。

### 5.3 索引合并（Index Merge）

MySQL 允许在 `WHERE` 条件中多个索引通过集合运算合并使用。内部用 `IndexRangeScan` 的联合或交集表示：

```c
// join_optimizer/access_path.h:256-257
enum Type : uint8_t {
    INDEX_MERGE,         // 索引合并（通用）
    ROWID_INTERSECTION,  // ROWID 交集（AND）
    ROWID_UNION,         // ROWID 并集（OR）
};
```

对应的 AccessPath 结构体：

```c
// access_path.h:1084 — INDEX_MERGE
struct {
  TABLE *table;
  bool forced_by_hint;
  Mem_root_array<AccessPath *> *children;
} index_merge;

// access_path.h:1088 — ROWID_INTERSECTION
struct {
  TABLE *table;
  Mem_root_array<AccessPath *> *children;
  AccessPath *cpk_child;        // 聚簇主键扫描（可选）
  bool forced_by_hint;
  bool retrieve_full_rows;
  bool need_rows_in_rowid_order;
  bool reuse_handler;
  bool is_covering;             // 无需回表
} rowid_intersection;

// access_path.h:1095 — ROWID_UNION
struct {
  TABLE *table;
  Mem_root_array<AccessPath *> *children;
  bool forced_by_hint;
} rowid_union;
// access_path.h:1084-1098
```

**ROWID_INTERSECTION**（AND 合并）：
- 从每个子索引扫描获取 `(page_no, row_id)`。
- 取交集（回表前就知道哪些行同时满足多个索引条件）。
- 如果 `is_covering = true`，无需回表（所有需要列都在索引合并结果中）。

**ROWID_UNION**（OR 合并）：
- 从每个子索引扫描获取 `(page_no, row_id)`。
- 去重并集后回表。
- 每个子扫描的 rowid 顺序不同，需要排序与去重。

合并操作的代价估算：

```c
// sql_planner.cc — 合并代价的计算
// ROWID_INTERSECTION 代价 = Σ(子扫描代价) + 交集运算代价 + 回表代价 × 交集行数
// ROWID_UNION 代价 = Σ(子扫描代价) + 去重+排序代价 + 回表代价 × 并集行数
```

优化器只在单索引的选择性不足时才考虑索引合并。`calc_join_type()` 将索引合并路径映射为 `JT_INDEX_MERGE`：

```c
// sql_select.cc
join_type calc_join_type(AccessPath *path) {
  switch (path->type) {
    case AccessPath::INDEX_RANGE_SCAN:
    case AccessPath::INDEX_SKIP_SCAN:
    case AccessPath::GROUP_INDEX_SKIP_SCAN:
      return JT_RANGE;
    case AccessPath::INDEX_MERGE:
    case AccessPath::ROWID_INTERSECTION:
    case AccessPath::ROWID_UNION:
      return JT_INDEX_MERGE;
    // ...
  }
}
// sql_select.cc
```

---

## 6. 索引维护

### 6.1 页分裂

当向一个已满的 B+Tree 页插入记录时，InnoDB 执行 `btr_page_split_and_insert()`：

```c
// btr0btr.cc:2305
rec_t *btr_page_split_and_insert(
    uint32_t flags, btr_cur_t *cursor, ulint **offsets,
    mem_heap_t **heap, const dtuple_t *tuple, mtr_t *mtr) {
  // ...
func_start:
  // 1. Try to insert into the right sibling first (avoids split)
  rec = btr_insert_into_right_sibling(flags, cursor, offsets, *heap, tuple, mtr);
  if (rec != nullptr) {
    return (rec);
  }

  page_no = block->page.id.page_no();

  // 2. Determine split point
  insert_left = false;
  if (n_iterations > 0) {
    // Retry: use split record from previous attempt
    direction = FSP_UP;
    hint_page_no = page_no + 1;
    split_rec = btr_page_get_split_rec(cursor, tuple);
  } else if (btr_page_get_split_rec_to_right(cursor, &split_rec)) {
    direction = FSP_UP;
    hint_page_no = page_no + 1;
  } else if (btr_page_get_split_rec_to_left(cursor, &split_rec)) {
    direction = FSP_DOWN;
    hint_page_no = page_no - 1;
  } else {
    direction = FSP_UP;
    hint_page_no = page_no + 1;
    if (page_get_n_recs(page) > 1) {
      split_rec = page_get_middle_rec(page);
    } else if (btr_page_tuple_smaller(cursor, tuple, offsets, n_uniq, heap)) {
      split_rec = page_rec_get_next(page_get_infimum_rec(page));
    } else {
      split_rec = nullptr;  // New record becomes the first on upper half
    }
  }

  // 3. Allocate new page
  new_block = btr_page_alloc(cursor->index, hint_page_no, direction,
                             BTR_NO_LEVEL, mtr);

  // 4. Copy half of the records to new page
  // 5. Update parent node pointers
  btr_page_insert_into_parent(/* ... */);
}
// btr0btr.cc:2305-2497
```

分裂的优化策略：

1. **`btr_insert_into_right_sibling()`**：先尝试插入到右兄弟页（如果右页有空间且满足分区约束），避免不必要的分裂。这是 MySQL 5.7+ 的重要优化。

2. **分裂方向判断**：`btr_page_get_split_rec_to_right()` 和 `btr_page_get_split_rec_to_left()` 根据插入位置决定将哪一半移走——尽量让插入页保留大部分数据。

3. **分裂点选择**：默认取 `page_get_middle_rec()`（页的中间记录），保证分裂后两页负载均衡。

4. **递归更新父节点**：`btr_page_insert_into_parent()` 可能需要递归向上分裂，在最坏情况下传播到根节点（B+Tree 高度 +1）。

### 6.2 索引碎片

频繁的页分裂和页面合并导致索引碎片——逻辑上连续的键值分布在物理上不连续的页中。`btr_compress()` 负责页面合并：

```c
// btr0btr.cc:3023
bool btr_compress(btr_cur_t *cursor, bool adjust, mtr_t *mtr) {
  block = btr_cur_get_block(cursor);
  page = btr_cur_get_page(cursor);
  index = cursor->index;

  left_page_no = btr_page_get_prev(page, mtr);
  right_page_no = btr_page_get_next(page, mtr);

  if (left_page_no == FIL_NULL && right_page_no == FIL_NULL) {
    // Only page on this level: lift records to father
    merge_block = btr_lift_page_up(index, block, mtr);
    goto func_exit;
  }

  // Find best merge candidate
  is_left = btr_can_merge_with_page(cursor, left_page_no, &merge_block, mtr);
  // ...

  if (is_left) {
    // Merge with left page: move our records to left
    btr_cur_t *merge_cursor = &mvec.mvec[0].btr_cur;
    page_copy_rec_list_to_page(/* destination page, source page */);
  } else {
    // Merge with right page
    page_copy_rec_list_to_page(/* ... */);
  }

  // Remove our page from the level
  btr_page_remove_level_ptr(/* ... */);

  // Free the page
  btr_page_free(index, block, mtr);

  // Recursively compress the parent if needed
  if (adjust) {
    btr_compress(&father_cursor, adjust, mtr);
  }
}
// btr0btr.cc:3023-3123
```

合并触发条件：当一个页的数据量低于 `merge_threshold` 百分比（默认 50%，见 `dict_index_t::merge_threshold`）。

### 6.3 OPTIMIZE TABLE / ALGORITHM=INPLACE

`OPTIMIZE TABLE` 在 InnoDB 中通常被映射为 `ALTER TABLE ... ENGINE=InnoDB`，即表重建。当使用 `ALGORITHM=INPLACE` 时（MySQL 5.6+），它执行在线重建：

```
OPTIMIZE TABLE t;
  → ALTER TABLE t ENGINE=InnoDB, ALGORITHM=INPLACE;
    → ha_innobase::commit_inplace_alter_table()
      → 新建表空间（临时 .ibd 文件）
      → 逐行复制数据到新表
        → 聚簇索引和二级索引在新空间上重新构建
        → 索引顺序与数据插入顺序一致：逻辑连续 = 物理连续
      → 应用在线日志（row_log_table_apply）
      → 切换文件：临时文件替换原文件 → 删除旧文件
    → dict_stats_update() 刷新统计信息
```

索引碎片率可以通过以下方式评估：

- `information_schema.INNODB_INDEXES.PAGE_NO`（根页号）
- 页数与记录数的比值（理想情况：每页约 70-80% 填充率）
- 自动触发的 `btr_compress()` 调用频率（`MONITOR_INDEX_MERGE_ATTEMPTS`）

### 6.4 索引统计信息更新

统计信息更新通过 `dict_stats_update()` 进行：

```c
// dict0stats.cc:3173
dberr_t dict_stats_update(dict_table_t *table,
                          dict_stats_upd_option_t stats_upd_option,
                          const char *db, const char *tbl, bool only_calc) {
  switch (stats_upd_option) {
    case DICT_STATS_RECALC_TRANSIENT:
      // 临时统计（内存中，不持久化）
      dict_stats_update_transient(table);
      break;
    case DICT_STATS_RECALC_PERSISTENT:
      // 持久化统计（写入 mysql.innodb_index_stats）
      err = dict_stats_update_persistent(table);
      break;
  }
}
// dict0stats.cc:3173-3217
```

统计信息的触发时机：

| 触发事件 | 函数 |
|---------|------|
| `ANALYZE TABLE` | `dict_stats_update()` |
| `OPTIMIZE TABLE` | `dict_stats_update()` |
| 自动统计（超过 `innodb_stats_auto_recalc` 的 10% 行变更） | 后台 `dict_stats_thread()` |
| `SHOW INDEX FROM`（首次打开表时） | `dict_stats_update()` |
| 页面合并/分裂 | `btr_compress()` 不直接触发 |

自动重算逻辑：InnoDB 在每张表的 `dict_table_t` 中维护一个计数器 `n_rows_before_stats`，当变更行数超定时阈值时发起重算。

---

## 7. 索引监控

### 7.1 information_schema.INNODB_INDEXES

这张表直接暴露 `dict_index_t` 的元数据：

```c
// i_s.cc — INNODB_INDEXES 表的填充逻辑
// (基于 dict_index_t 字段直接输出)
```

| 字段 | 对应 `dict_index_t` 字段 | 含义 |
|------|------------------------|------|
| `INDEX_ID` | `id` | 索引 ID，全局唯一 |
| `NAME` | `name` | 索引名称 |
| `TABLE_ID` | `table->id` | 所属表 ID |
| `TYPE` | `type` | 类型位掩码（0=非唯一二级索引，1=聚簇，2=唯一，3=聚簇唯一，32=全文，64=空间） |
| `N_FIELDS` | `n_fields` | 索引列数 |
| `PAGE_NO` | `page` | B+Tree 根页号（-1 表示尚未分配） |
| `SPACE` | `space` | 表空间 ID |
| `MERGE_THRESHOLD` | `merge_threshold` | 页面合并阈值百分比 |

### 7.2 information_schema.INNODB_TABLESTATS

提供表级别的统计信息：

```c
// i_s.cc:5772
OK(fields[INNODB_TABLESTATS_NROW]->store(table->stat_n_rows, true));
```

| 字段 | 含义 |
|------|------|
| `TABLE_ID` | 表 ID |
| `NAME` | 表名 |
| `STATS_INITIALIZED` | 统计信息是否已初始化 |
| `NUM_ROWS` | 估算行数（`stat_n_rows`） |
| `CLUST_INDEX_SIZE` | 聚簇索引页数 |
| `OTHER_INDEX_SIZE` | 二级索引总页数 |
| `MODIFIED_COUNTER` | 修改计数器（超过阈值触发统计重算） |
| `AUTOINC` | 自增值 |

### 7.3 SHOW INDEX FROM

`SHOW INDEX FROM` 返回每个索引列的详细信息，包括基数（`cardinality`，即 `n_diff_key_vals[column_index]`）。

| 字段 | 数据来源 | 含义 |
|------|---------|------|
| `Cardinality` | `index->stats.n_diff_key_vals[pos]` | 基数估算 |
| `Sub_part` | `dict_field_t::prefix_len` | 前缀长度 |
| `Null` | `dict_col_t::prtype & DATA_NOT_NULL` | 是否允许 NULL |
| `Index_type` | `index->type` 推断 | BTREE / FULLTEXT / HASH 等 |
| `Comment` | 索引属性 | `disabled`（不可见索引） |
| `Visible` | `key_info->is_visible` | 是否可见 |

---

## 8. 关键函数索引

以下为 40+ 个与索引设计、选择、创建、维护直接相关的核心函数及源码位置：

### B+Tree 搜索与遍历

| 函数 | 文件:行 | 作用 |
|------|---------|------|
| `btr_cur_search_to_nth_level()` | `btr0cur.h:134` | B+Tree 从根到目标层搜索，定位记录 |
| `btr_cur_search_to_nth_level_with_no_latch()` | `btr0cur.h:184` | 无锁版本搜索（intrinsic table） |
| `btr_cur_open_at_index_side()` | `btr0cur.h:201` | 在 B+Tree 最左/最右打开游标 |
| `btr_cur_open_at_rnd_pos()` | `btr0cur.cc` | 随机打开一个叶页（统计采样用） |
| `page_rec_get_next()` | `page0page.h:385` | 获取链表中的下一条记录 |
| `page_get_infimum_rec()` | `page0page.h:218` | 获取 infimum 记录（页内最小虚拟记录） |
| `page_get_n_recs()` | `page0page.h:267` | 获取页内用户记录数 |

### 索引创建

| 函数 | 文件:行 | 作用 |
|------|---------|------|
| `dict_mem_index_create()` | `dict0mem.cc` | 创建内存中的 `dict_index_t` 对象 |
| `btr_create()` | `btr0btr.cc:858` | 创建 B+Tree 根页和段结构 |
| `fseg_create()` | `fsp0fsp.cc` | 创建文件段（segment） |
| `page_create()` | `page0page.cc` | 初始化空页（infimum/supremum 记录） |
| `ha_innobase::create_index()` | `ha_innodb.cc:12260` | 二级索引创建的 handler 入口 |
| `dict_create_index()` | `dict0crea.cc` | 完整索引创建流程（元数据 + 数据填充） |
| `innobase_init_vc_templ()` | `ha_innodb.cc:23880` | 虚拟列索引模板初始化 |

### 在线 DDL

| 函数 | 文件:行 | 作用 |
|------|---------|------|
| `row_log_t` | `dict0mem.h:1207` | 在线索引创建增量日志结构 |
| `row_log_table_apply()` | `row0merge.cc` | 在线日志回放到新索引 |
| `ha_innobase::commit_inplace_alter_table()` | `ha_innodb.cc` | INPLACE ALTER 提交阶段 |
| `dict_stats_update_transient_for_index()` | `dict0stats.cc:766` | 在线 DDL 期间统计信息更新 |
| `ha_innobase::create_index()` | `ha_innodb.cc` | 在线索引创建入口 |

### 索引选择与优化器

| 函数 | 文件:行 | 作用 |
|------|---------|------|
| `JOIN::optimize()` | `sql_optimizer.cc:344` | 查询优化的主入口 |
| `Optimize_table_order::choose_table_order()` | `sql_planner.cc` | 表连接顺序和访问方法选择 |
| `find_best_ref()` | `sql_planner.cc:208` | 最佳 ref 访问的索引选择 |
| `get_index_for_order()` | `sql_select.cc:5450` | ORDER BY 的索引选择 |
| `test_if_cheaper_ordering()` | `sql_select.cc:5198` | LIMIT 场景下索引排序 vs filesort |
| `test_if_order_by_key()` | `sql_select.cc` | 检查索引是否满足 ORDER BY |
| `calc_join_type()` | `sql_select.cc` | AccessPath → 连接类型映射 |
| `actual_key_parts()` | `sql_select.cc` | 考虑 `use_index_extensions` 后的键部分数 |
| `make_cond_for_index()` | `sql_select.cc:2921` | 提取可下推的索引条件 |

### 覆盖索引与 ICP

| 函数 | 文件:行 | 作用 |
|------|---------|------|
| `QEP_TAB::push_index_cond()` | `sql_select.cc:3058` | 推送索引条件下推到存储引擎 |
| `ha_innobase::idx_cond_push()` | `ha_innodb.cc` | InnoDB 接收下推条件 |
| `innobase_index_cond()` | `ha_innodb.cc:23867` | InnoDB 评估下推条件 |
| `TABLE::set_keyread()` | `sql/table.cc` | 启用覆盖索引读取（仅读索引列） |
| `Handler::index_flags()` | `handler.h` | 查询存储引擎的索引能力（包括 ICP） |
| `covering_keys.set_bit()` | `sql/table.cc:6083` | 标记索引为可覆盖 |

### MRR

| 函数 | 文件:行 | 作用 |
|------|---------|------|
| `ha_innobase::multi_range_read_init()` | `ha_innodb.cc:23825` | MRR 初始化 |
| `ha_innobase::multi_range_read_next()` | `ha_innodb.cc:23833` | MRR 获取下个范围 |
| `DsMrr_impl::dsmrr_init()` | `handler.cc` | DS-MRR 初始化（排序+缓冲） |
| `DsMrr_impl::dsmrr_fill_buffer()` | `handler.cc` | 填充并排序 rowid 缓冲区 |
| `multi_range_read_info_const()` | `ha_innodb.cc:23837` | MRR 代价估算 |

### 统计信息

| 函数 | 文件:行 | 作用 |
|------|---------|------|
| `btr_estimate_number_of_different_key_vals()` | `btr0cur.cc:5390` | 采样估计索引基数 |
| `dict_stats_update_transient()` | `dict0stats.cc:838` | 计算临时统计信息 |
| `dict_stats_update_persistent()` | `dict0stats.cc:2288` | 计算并持久化统计信息 |
| `dict_stats_update()` | `dict0stats.cc:3173` | 统计信息更新总入口 |
| `btr_get_size()` | `btr0btr.cc` | 获取索引页数及叶子页数 |
| `cmp_rec_rec_with_match()` | `rem0cmp.cc` | 记录比较，返回匹配的列数 |

### 索引维护

| 函数 | 文件:行 | 作用 |
|------|---------|------|
| `btr_page_split_and_insert()` | `btr0btr.cc:2305` | B+Tree 页分裂并插入新记录 |
| `btr_compress()` | `btr0btr.cc:3023` | B+Tree 页合并（相邻页不足时触发） |
| `btr_lift_page_up()` | `btr0btr.cc` | 将唯一页的记录提升到父页 |
| `btr_page_alloc()` | `btr0btr.cc` | 分配新的 B+Tree 页 |
| `btr_page_free()` | `btr0btr.cc` | 释放 B+Tree 页 |
| `btr_can_merge_with_page()` | `btr0btr.cc` | 判断是否可以与相邻页合并 |
| `btr_insert_into_right_sibling()` | `btr0btr.cc` | 优先插入右兄弟（避免分裂） |
| `btr_cur_optimistic_insert()` | `btr0cur.cc` | 乐观插入（不分裂） |
| `btr_cur_pessimistic_insert()` | `btr0cur.cc` | 悲观插入（可能触发分裂） |
| `page_copy_rec_list_to_page()` | `page0page.cc` | 记录列表批量复制（合并用） |

### AccessPath 类型定义

| 枚举/结构 | 文件:行 | 作用 |
|-----------|---------|------|
| `AccessPath::Type` | `access_path.h:240` | 41 种访问路径类型 |
| `AccessPath::index_merge` | `access_path.h:1084` | 索引合并访问路径 |
| `AccessPath::rowid_intersection` | `access_path.h:1088` | ROWID 交集 |
| `AccessPath::rowid_union` | `access_path.h:1095` | ROWID 并集 |
| `AccessPath::index_range_scan` | `access_path.h:1060` | 索引范围扫描 |
| `AccessPath::ref` | `access_path.h:1078` | 索引等值查找 |
| `AccessPath::mrr` | `access_path.h:1074` | 多范围读取 |

### 数据字典操作

| 函数 | 文件:行 | 作用 |
|------|---------|------|
| `dict_index_get_n_unique()` | `dict0mem.ic` | 获取唯一确定记录所需的列数 |
| `dict_index_is_clustered()` | `dict0mem.ic` | 判断是否为聚簇索引 |
| `dict_index_is_spatial()` | `dict0mem.ic` | 判断是否为空间索引 |
| `dict_index_is_online_ddl()` | `dict0mem.ic` | 检查索引是否处于在线 DDL 中 |
| `dict_table_get_index()` | `dict0mem.cc` | 按名称查找表的索引 |

---

## 总结

MySQL 索引设计与优化涉及从存储引擎 B+Tree 结构到优化器代价模型的全链路理解。关键要点：

1. **物理层**：`dict_index_t` 管理索引元数据，包括根页号、类型、在线 DDL 状态、统计信息。B+Tree 的操作由 `btr0btr.cc` 和 `btr0cur.cc` 中约 10,000 行代码实现。

2. **创建层**：`btr_create()` 创建一个包含两段的 B+Tree（叶子段 + 内部段）。在线 DDL 通过 `online_log` 记录增量修改，在最后阶段通过 `row_log_table_apply()` 回放。

3. **选择层**：`JOIN::optimize()` → `find_best_ref()` 评估 ref 访问，`get_index_for_order()` 评估排序索引。核心估计算子是 `n_diff_key_vals`（基数）和 `rec_per_key`。

4. **执行层**：覆盖索引（`set_keyread(true)`）避免回表；ICP（`innobase_index_cond()`）在索引扫描时过滤，减少回表次数；MRR（`dsmrr_fill_buffer()`）将随机回表转化为顺序 I/O。

5. **维护层**：`btr_page_split_and_insert()` 处理分裂，`btr_compress()` 处理合并，`OPTIMIZE TABLE` 通过表重建消除碎片。

无论使用哪种特性，最终都落地在 B+Tree 的基本操作上——每毫秒数千次的 `btr_cur_search_to_nth_level()` 调用构成了 MySQL 在线事务处理的基石。

> 所有 `file:line` 引用基于 MySQL 9.x 源码。索引统计信息的采样参数由 `innodb_stats_transient_sample_pages` 和 `innodb_stats_persistent_sample_pages` 系统变量控制。
