# 06-innodb-btree-index — InnoDB B+Tree 索引：搜索、插入、分裂、合并、AHI

## 0. 概述

InnoDB 使用 B+Tree 作为其主要的索引结构。每个 InnoDB 表都有一个**聚簇索引**（clustered index，`dict0mem.h:1067` 中 `type` 字段包含 `DICT_CLUSTERED`），其叶子节点存放完整的数据行。用户创建的**二级索引**（secondary index）的叶子节点存放的是聚簇索引的键值。从起点到终点，B+Tree 操作的代码分布在 `btr/` 目录下约 13,000 行的 C++ 源码中（`btr0cur.cc` 5613 行、`btr0btr.cc` 4920 行、`btr0sea.cc` 2057 行、`btr0pcur.cc` 474 行）。

B+Tree 的基本结构：

```
    根节点 (level N)
       /    |    \
    内部节点 (level N-1)
   /    |    |    \
叶子节点 (level 0) ←→ 叶子节点 (level 0)
```

- **根节点**：树的顶层，可能同时是叶子节点（当树只有一层时）。根页号存储在 `dict_index_t::page`。
- **内部节点**：存储索引键和指向子页的**节点指针**（node pointer），通过 `btr_node_ptr_get_child_page_no()`（`btr0btr.ic`）读取子页号。
- **叶子节点**：level 0，存储实际数据行（聚簇索引）或索引键+主键引用（二级索引）。

B+Tree 的每个节点对应一个磁盘页，默认 `UNIV_PAGE_SIZE` = 16 KiB。同一 level 的节点通过 `FIL_PAGE_PREV` / `FIL_PAGE_NEXT`（`fil0types.h:46`）形成双向链表，支持高效的范围扫描。最大深度由 `BTR_MAX_LEVELS = 100`（`btr0btr.h`）定义。

> 所有 `file:line` 引用基于 MySQL 8.4 / 9.x 源码主干。

---

## 1. 核心数据结构

### 1.1 dict_index_t (dict0mem.h:1067) — 索引元数据

`dict_index_t` 是描述索引的运行时结构。每个 B+Tree 索引在内存中对应一个这样的对象：

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

  /** offset of trx_id in clustered index record */
  unsigned trx_id_offset : MAX_KEY_LENGTH_BITS;

  /** number of user-defined columns */
  unsigned n_user_defined_cols : 10;

  /** if true, allow duplicate values */
  unsigned allow_duplicates : 1;

  /** number of fields uniquely determining an entry */
  unsigned n_uniq : 10;

  /** number of fields defined so far */
  unsigned n_def : 10;

  /** number of fields in the index */
  unsigned n_fields : 10;

  /** whether AHI is disabled */
  unsigned disable_ahi : 1;

  /** array of field descriptions */
  dict_field_t *fields;

  /** info used in optimistic searches (AHI) */
  btr_search_t *search_info;

  /** statistics for query optimization */
  dict_index_stats_t stats;
  // ... more fields
};
```

关键字段：

- **`page`**：根节点的 page number。B+Tree 的所有搜索从根开始，由 `btr_root_block_get()`（`btr0btr.h`）访问。
- **`n_uniq`**：唯一确定记录的字段数，用于节点指针比较。
- **`search_info`**：指向 `btr_search_t`，AHI（自适应哈希索引）的核心状态（`btr0sea.h:46`）。
- **`n_fields`**：索引中所有字段数（包括内部添加的 DB_TRX_ID, DB_ROLL_PTR 等系统列）。
- **`merge_threshold`**：默认 50%，在 `BTR_CUR_PAGE_COMPRESS_LIMIT`（`btr0cur.h`）宏中使用。

### 1.2 btr_cur_t (btr0types.h:48 / btr0cur.h) — B-tree 游标

B-tree 游标是执行一次 B+Tree 搜索后的"结果"——它记录了搜索定位到的记录、页面、匹配信息等。

```c
// btr0cur.h （非匿名化结构体）
struct btr_cur_t {
  /** Index on which the cursor is positioned. */
  dict_index_t *index;

  /** Page cursor (page + record pointer). */
  page_cur_t page_cur;

  /** Purge node, for BTR_DELETE */
  purge_node_t *purge_node;

  /** Pointer to left neighbor page (BTR_SEARCH_PREV / BTR_MODIFY_PREV). */
  buf_block_t *left_block;

  /** Query thread (used in insert buffer). */
  que_thr_t *thr;

  /** Search method flag: BTR_CUR_HASH, BTR_CUR_BINARY, ... */
  btr_cur_method flag;

  /** Tree height (for pessimistic insert/update). */
  ulint tree_height;

  /** Number of matched fields to the right (after search). */
  ulint up_match;
  ulint up_bytes;

  /** Number of matched fields to the left (after search). */
  ulint low_match;
  ulint low_bytes;

  /** AHI-related fields */
  struct {
    btr_search_prefix_info_t prefix_info;
    uint64_t ahi_hash_value;
  } ahi;

  /** Path array for row estimation */
  btr_path_t *path_arr;

  /** R-tree info */
  rtr_info_t *rtr_info;
};
```

游标方法标志（`btr0cur.h`）：`BTR_CUR_HASH`、`BTR_CUR_BINARY`、`BTR_CUR_HASH_FAIL` 等，用于 `btr_search_info_update_slow()`（`btr0sea.cc:649`）的 AHI 决策。

### 1.3 btr_pcur_t (btr0pcur.h:99) — 持久游标

持久游标用于范围扫描：它可以在提交 mini-transaction 后重新定位到之前的位置。

```c
// btr0pcur.h:99
struct btr_pcur_t {
  /** B-tree cursor (embedded) */
  btr_cur_t m_btr_cur;

  /** Latch mode: BTR_SEARCH_LEAF, BTR_MODIFY_LEAF, ... or BTR_NO_LATCHES */
  ulint m_latch_mode;

  /** true if old_rec is stored */
  bool m_old_stored;

  /** initial segment of the record cursor was positioned on */
  rec_t *m_old_rec;

  /** number of fields in old_rec */
  ulint m_old_n_fields;

  /** BTR_PCUR_ON, BTR_PCUR_BEFORE, or BTR_PCUR_AFTER */
  btr_pcur_pos_t m_rel_pos;

  /** buffer block hint (for optimistic restoration) */
  buf::Block_hint m_block_when_stored;

  /** modify clock value at store time */
  uint64_t m_modify_clock;

  /** position state */
  pcur_pos_t m_pos_state;

  /** buffer for old_rec */
  byte *m_old_rec_buf;
  size_t m_buf_size;

  /** Functions (declared in btr0pcur.h, implemented in btr0pcur.cc) */
  void open(dict_index_t *index, ulint level, const dtuple_t *tuple,
            page_cur_mode_t mode, ulint latch_mode, mtr_t *mtr,
            ut::Location location);

  void store_position(mtr_t *mtr);
  bool restore_position(ulint latch_mode, mtr_t *mtr, ut::Location location);
  bool move_to_next(mtr_t *mtr);
  bool move_to_prev(mtr_t *mtr);
  // ...
};
```

持久游标的核心思想：当前 mtr 提交后释放了页面 latch，下一次操作前通过 `restore_position()`（`btr0pcur.cc:203`）重新找到之前的位置。它存储了记录的 key prefix + modify_clock，第一次尝试乐观恢复（通过 `btr_cur_optimistic_latch_leaves()`，`btr0cur.h` 声明），失败则走完整 B+Tree 搜索。

### 1.4 page_cur_t (page0cur.h:311) — 页面游标

页面游标指向一个页面上的一个特定记录。

```c
// page0cur.h:311
struct page_cur_t {
  /** Index the cursor is on. */
  const dict_index_t *index;

  /** pointer to a record on page */
  rec_t *rec;

  /** Current offsets of the record. */
  ulint *offsets;

  /** Pointer to the current block containing rec. */
  buf_block_t *block;
};
```

`btr_cur_t::page_cur` 就是这样一个页面游标，通过 `btr_cur_get_block()` / `btr_cur_get_rec()`（`btr0cur.h` 内联函数）访问具体的记录。

### 1.5 btr_search_t (btr0sea.h:46) — 自适应哈希索引

每个索引维护一个 `btr_search_t`，用于跟踪 AHI 的构建状态：

```c
// btr0sea.h:46
struct btr_search_t {
  /** Number of blocks whose AHI entries point to this index */
  std::atomic<size_t> ref_count;

  /** Root page guess (root page frame when last fetched, or NULL) */
  buf_block_t *root_guess;

  /** Hash analysis counter; exceeds BTR_SEARCH_HASH_ANALYSIS to start */
  std::atomic<uint64_t> hash_analysis;

  /** Whether last search would have succeeded using hash index */
  bool last_hash_succ;

  /** Consecutive searches that would have succeeded via hash */
  std::atomic<uint64_t> n_hash_potential;

  /** Prefix info (n_fields, n_bytes, left_side) */
  std::atomic<btr_search_prefix_info_t> prefix_info;

#ifdef UNIV_SEARCH_PERF_STAT
  std::atomic<ulint> n_hash_succ;
  std::atomic<ulint> n_hash_fail;
#endif
};
```

全局 AHI 系统 `btr_search_sys` 是一个分区的哈希表（`btr0sea.h`），通过 `btr_ahi_parts`（默认 8）个分区减少锁竞争：

```c
// btr0sea.h
class btr_search_sys_t {
 public:
  class search_part_t {
    /** RW latch protecting this AHI part */
    rw_lock_t latch;

    /** The actual hash table */
    hash_table_t *hash_table;

    /** Free block for heap allocations */
    std::atomic<buf_block_t *> free_block_for_heap;
  };

  /** Array of partitions */
  ut::unique_ptr_aligned<search_part_t[]> parts;
};

extern btr_search_sys_t *btr_search_sys;
```

每个索引映射到一个分区：`btr_search_hash_index_id(index)` 基于 `(space_id, index_id)` 哈希选择分区。AHI latch 通过 `btr_search_s_lock()` / `btr_search_x_lock()`（`btr0sea.ic:60`）获取。

---

## 2. btr_cur_search_to_nth_level — B+Tree 搜索 (btr0cur.cc:619)

这是 InnoDB B+Tree 搜索的核心函数。它将游标定位到指定 level（通常是 level 0 = 叶子层）上满足搜索条件的记录。

### 2.1 函数签名

```c
// btr0cur.cc:619
void btr_cur_search_to_nth_level(
    dict_index_t *index,     /*!< in: 索引 */
    ulint level,            /*!< in: 目标 level (0=叶子) */
    const dtuple_t *tuple,  /*!< in: 搜索键 */
    page_cur_mode_t mode,   /*!< in: PAGE_CUR_LE, PAGE_CUR_GE, ... */
    ulint latch_mode,       /*!< in: BTR_SEARCH_LEAF, BTR_MODIFY_LEAF, ... */
    btr_cur_t *cursor,      /*!< out: 搜索结果游标 */
    ulint has_search_latch, /*!< in: 调用者是否持有 AHI S-latch */
    const char *file,       /*!< in: 调用文件名 */
    ulint line,             /*!< in: 调用行号 */
    mtr_t *mtr)             /*!< in/out: mini-transaction */
```

### 2.2 搜索流程

```c
// btr0cur.cc:619 开始
void btr_cur_search_to_nth_level(...)
{
  page_t *page = nullptr;
  buf_block_t *block;
  ulint height;
  ulint up_match, up_bytes, low_match, low_bytes;
  // ... 局部变量（tree_blocks 数组 BTR_MAX_LEVELS=100 等）

  // 1. 解析 latch_mode 中的 flag
  btr_op = /* BTR_INSERT / BTR_DELETE / BTR_DELETE_MARK / BTR_NO_OP */;
  latch_mode = BTR_LATCH_MODE_WITHOUT_FLAGS(latch_mode);

  // 2. 尝试 AHI 快速路径
  cursor->flag = BTR_CUR_BINARY;
  cursor->index = index;

  if (/* AHI enabled && latch_mode <= BTR_MODIFY_LEAF &&
       info->last_hash_succ && ... */) {
    if (btr_search_guess_on_hash(tuple, mode, latch_mode, cursor,
                                 has_search_latch, mtr)) {
      btr_cur_n_sea++;
      return;  // ← AHI 命中，直接返回
    }
  }
  btr_cur_n_non_sea++;
  /* 统计计数器 btr_cur_n_sea / btr_cur_n_non_sea
     声明在 btr0cur.h */

  // 3. 获取索引树 latch
  switch (latch_mode) {
    case BTR_MODIFY_TREE:
      mtr_sx_lock(dict_index_get_lock(index), mtr, UT_LOCATION_HERE);
      break;
    case BTR_SEARCH_LEAF:
      mtr_s_lock(dict_index_get_lock(index), mtr, UT_LOCATION_HERE);
      break;
    // ...
  }

  // 4. 从根开始逐层搜索
search_loop:
  // 获取当前 level 的页面
  block = buf_page_get_gen(page_id, page_size, rw_latch,
                           root_guess, fetch, ..., mtr);

  // 如果是内部节点，调整 search mode
  //（非叶子层使用 PAGE_CUR_L 或 PAGE_CUR_LE）

  // 5. 在页面上二分查找
  page_cur_search_with_match(
      block, index, tuple, page_mode,
      &up_match, &low_match, page_cursor, ...);

  // 6. 如果未到达目标 level，获取 node pointer 的子页号
  if (height != level) {
    node_ptr = btr_cur_get_rec(cursor);
    offsets = rec_get_offsets(node_ptr, index, ...);
    page_no = btr_node_ptr_get_child_page_no(node_ptr, offsets);
    page_id.set_page_no(page_no);
    height--;
    goto search_loop;
  }

  // 7. 到达目标 level：latch leaves
  // 设置 up_match / low_match 到 cursor
  cursor->up_match = up_match;
  cursor->low_match = low_match;

func_exit:
  // 释放上层页面的 latch
  for (i = 0; i < n_releases; i++) {
    mtr_release_savepoint(mtr, tree_savepoints[i]);
  }

  // 对于叶子层搜索，使用 btr_cur_latch_leaves() 精确 latch
  // （btr0cur.h 声明，btr0cur.cc 实现）

  // 更新 AHI 统计信息
  btr_search_info_update(cursor);
}
```

### 2.3 二分查找：page_cur_search_with_match (page0cur.cc:328)

```c
// page0cur.cc:328
void page_cur_search_with_match(const buf_block_t *block,
                                const dict_index_t *index,
                                const dtuple_t *tuple, page_cur_mode_t mode,
                                ulint *iup_matched_fields,
                                ulint *ilow_matched_fields,
                                page_cur_t *cursor, rtr_info_t *rtr_info)
{
  // 1. 先通过 page directory 二分：找到 page_dir 中的上下界 slot
  low = 0;
  up = page_dir_get_n_slots(page) - 1;

  while (up - low > 1) {
    mid = (low + up) / 2;
    slot = page_dir_get_nth_slot(page, mid);
    mid_rec = page_dir_slot_get_rec(slot);

    cur_matched_fields = min(low_matched_fields, up_matched_fields);
    cmp = tuple->compare(mid_rec, index, offsets, &cur_matched_fields);

    if (cmp > 0) {
      low = mid;
      low_matched_fields = cur_matched_fields;
    } else if (cmp) {
      up = mid;
      up_matched_fields = cur_matched_fields;
    } else if (mode == PAGE_CUR_G || mode == PAGE_CUR_LE) {
      low = mid; /* 相等时取低 */
    } else {
      up = mid;  /* 相等时取高 */
    }
  }

  // 2. 再在 slot 内部线性搜索
  while (page_rec_get_next_const(low_rec) != up_rec) {
    mid_rec = page_rec_get_next_const(low_rec);
    cmp = tuple->compare(mid_rec, index, offsets, &cur_matched_fields);
    // ... 同上判断
  }

  // 3. 设置 cursor 位置
  if (mode <= PAGE_CUR_GE) {
    page_cur_position(up_rec, block, cursor);
  } else {
    page_cur_position(low_rec, block, cursor);
  }

  *iup_matched_fields = up_matched_fields;
  *ilow_matched_fields = low_matched_fields;
}
```

关键算法：
1. **Page directory 二分**：page directory 把页内的记录分成多个 slot（每个 slot 管理 4~8 条记录，`PAGE_DIR_SLOT_MAX_N_OWNED = 8`, `PAGE_DIR_SLOT_MIN_N_OWNED = 4`，定义于 `page0page.h`），第一步找到正确的 slot。
2. **Slot 内线性扫描**：在 slot 管理的记录链中线性搜索到精确位置。
3. **匹配计数**：`up_match` / `low_match` 记录有多少个字段完全匹配，这对 AHI 和后续插入优化至关重要。`page_dir_slot_get_rec()` / `page_dir_get_nth_slot()`（`page0page.h:307`）是访问 page directory 的核心函数。

### 2.4 乐观 latch 与修改时钟

```c
// btr0cur.h 声明
bool btr_cur_optimistic_latch_leaves(
    buf_block_t *block, uint64_t modify_clock,
    ulint *latch_mode, btr_cur_t *cursor,
    const char *file, ulint line, mtr_t *mtr);
```

持久游标在 `restore_position()`（`btr0pcur.cc:203`）中调用此函数：如果页面自存储后未曾被修改（通过 `modify_clock` 验证），则可以直接获取 latch 而无需重新搜索整棵树。

---

## 3. 页面结构

### 3.1 文件页头 (FIL_PAGE 系列 - fil0types.h)

每个磁盘页以 38 字节的文件页头开始：

```c
// fil0types.h:46
constexpr uint32_t FIL_PAGE_SPACE_OR_CHKSUM = 0;  // 4 bytes checksum
constexpr uint32_t FIL_PAGE_OFFSET       = 4;      // page offset
constexpr uint32_t FIL_PAGE_PREV         = 8;      // prev page (for B-tree levels)
constexpr uint32_t FIL_PAGE_NEXT         = 12;     // next page
constexpr uint32_t FIL_PAGE_LSN          = 16;     // 8 bytes LSN
constexpr uint32_t FIL_PAGE_TYPE         = 24;     // 2 bytes page type
constexpr uint32_t FIL_PAGE_FILE_FLUSH_LSN = 26;   // 8 bytes
constexpr uint32_t FIL_PAGE_SPACE_ID     = 34;     // 4 bytes space id
constexpr uint32_t FIL_PAGE_DATA         = 38;     // start of page data
```

`FIL_PAGE_TYPE` 的取值包括 `FIL_PAGE_INDEX = 17855`（`fil0fil.h:1227`）、`FIL_PAGE_RTREE = 17854`、`FIL_PAGE_SDI = 17853`。`fil_page_get_prev()` / `fil_page_get_next()`（`fil0fil.h`）读取双向链表指针。

### 3.2 索引页头 (PAGE_HEADER — page0types.h)

紧接文件页头之后是索引页头：

```c
// page0types.h
constexpr uint32_t PAGE_HEADER          = FSEG_PAGE_DATA;  // = FIL_PAGE_DATA

// 页头内部偏移
constexpr uint32_t PAGE_N_DIR_SLOTS  = 0;   // number of slots in page directory
constexpr uint32_t PAGE_HEAP_TOP     = 2;   // pointer to record heap top
constexpr uint32_t PAGE_N_HEAP       = 4;   // number of records in heap
constexpr uint32_t PAGE_FREE         = 6;   // free record list
constexpr uint32_t PAGE_GARBAGE      = 8;   // bytes in deleted records
constexpr uint32_t PAGE_LAST_INSERT  = 10;  // last insert position
constexpr uint32_t PAGE_DIRECTION    = 12;  // last insert direction
constexpr uint32_t PAGE_N_DIRECTION  = 14;  // consecutive inserts same direction
constexpr uint32_t PAGE_N_RECS       = 16;  // number of user records
constexpr uint32_t PAGE_MAX_TRX_ID   = 18;  // max trx id (8 bytes for trx_id_t)
constexpr uint32_t PAGE_LEVEL        = 26;  // B-tree level (0=leaf)
constexpr uint32_t PAGE_INDEX_ID     = 28;  // index id
constexpr uint32_t PAGE_BTR_SEG_LEAF = 36;  // leaf segment header (root only)
constexpr uint32_t PAGE_BTR_SEG_TOP  = 36 + FSEG_HEADER_SIZE; // internal segment header
```

布局示意（16 KiB 默认页）：

```
+-----------------+ 0
| FIL_PAGE header  | 38 bytes (checksum, offset, prev/next, LSN, type, space)
+-----------------+ FIL_PAGE_DATA (38)
| PAGE_HEADER      | 36 + 2*FSEG_HEADER_SIZE bytes
+-----------------+ PAGE_DATA (~110)
| Infimum record   | 固定的最小记录
+-----------------+
| Supremum record  | 固定的最大记录
+-----------------+
| User records     | ← 自顶向下增长
| ...              |
+-----------------+ ← HEAP_TOP
| 空闲空间          |
+-----------------+
| Page directory   | ← 自底向上增长（2 bytes/slot）
+-----------------+ ← PAGE_DIR
| FIL_PAGE trailer | 8 bytes (checksum)
+-----------------+ UNIV_PAGE_SIZE
```

`btr_page_get_level()`（`btr0btr.ic`）返回页面 level，`page_is_leaf()`（`page0page.h:361`）检查 level == 0。

### 3.3 页目录 (Page Directory)

Page directory 是一个稀疏索引，指向页内的记录：
- 每条记录被一个 slot "拥有"（owner）。
- 每个 slot 拥有 4~8 条记录（`PAGE_DIR_SLOT_MIN_N_OWNED` / `PAGE_DIR_SLOT_MAX_N_OWNED`，`page0page.h`）。
- infimum 和 supremum records 总是各有一个 slot。

```c
// page0page.h
constexpr uint32_t PAGE_DIR          = FIL_PAGE_DATA_END;
constexpr uint32_t PAGE_DIR_SLOT_SIZE = 2;
constexpr uint32_t PAGE_DIR_SLOT_MAX_N_OWNED = 8;
constexpr uint32_t PAGE_DIR_SLOT_MIN_N_OWNED = 4;

// 访问函数
page_dir_get_n_slots(page);     // page0page.h:291
page_dir_get_nth_slot(page, n); // page0page.h:307
page_dir_slot_get_rec(slot);    // page0page.h:319
```

`page_get_infimum_rec()` / `page_get_supremum_rec()`（`page0page.h:218-227`）返回页面两端的哨兵记录。`page_rec_get_next()` / `page_rec_get_prev()`（`page0page.h:385-410`）沿记录链表遍历。

### 3.4 记录格式与节点指针

每条记录有 header（长度取决于 REDUNDANT / COMPACT / DYNAMIC / COMPRESSED 格式），然后是字段值。

对于非叶子层（internal node），记录是 **node pointer**，结构为：

```
| 索引键 | child_page_no |
```

`child_page_no` 是记录最后一个字段，通过 `btr_node_ptr_get_child_page_no()` 读取：

```c
// btr0btr.ic (内联)
static inline page_no_t btr_node_ptr_get_child_page_no(
    const rec_t *rec, const ulint *offsets)
{
  ut_ad(offsets);
  /* 最后一个字段（offsets 中的最后一列）就是子页号 */
  ulint len;
  const byte *data = rec_get_nth_field(rec, nullptr, offsets,
                                       rec_offs_n_fields(offsets) - 1, &len);
  ut_ad(len == 4);
  return (mach_read_from_4(data));
}
```

`btr_node_ptr_get_child()`（`btr0btr.h`）不仅读取子页号，还会 latch 子页面。`btr_page_get_parent()` 的递归调用在 `btr_page_split_and_insert()` 中处理父节点更新。

叶子页和内部页的类型由 `btr_page_get_level(page)`（`btr0btr.ic`）区分——leaf level == 0。`page_is_leaf()` 在 `page_is_empty()` 之前检查 `PAGE_LEVEL` 字段。

---

## 4. 记录插入路径

### 4.1 btr_cur_optimistic_insert() — 乐观插入 (btr0cur.cc:2660)

乐观插入假设页面上有空闲空间，不需要页面分裂：

```c
// btr0cur.cc:2660
dberr_t btr_cur_optimistic_insert(
    ulint flags, btr_cur_t *cursor,
    ulint **offsets, mem_heap_t **heap,
    dtuple_t *entry, rec_t **rec,
    big_rec_t **big_rec, que_thr_t *thr, mtr_t *mtr)
{
  big_rec_t *big_rec_vec = nullptr;
  dict_index_t *index;
  page_cur_t *page_cursor;
  buf_block_t *block;
  page_t *page;
  ulint rec_size;
  dberr_t err;

  block = btr_cur_get_block(cursor);
  page = buf_block_get_frame(block);
  index = cursor->index;

  // 1. 计算转换后的记录大小
  rec_size = rec_get_converted_size(index, entry);

  // 2. 检查是否需要外部存储（blob）
  if (page_zip_rec_needs_ext(rec_size, page_is_comp(page),
                             dtuple_get_n_fields(entry), page_size)) {
    big_rec_vec = dtuple_convert_big_rec(index, nullptr, entry);
    if (big_rec_vec == nullptr) return DB_TOO_BIG_RECORD;
    rec_size = rec_get_converted_size(index, entry);
  }

  // 3. 检查是否有足够空间
  LIMIT_OPTIMISTIC_INSERT_DEBUG(page_get_n_recs(page), goto fail);

  if (leaf && page_size.is_compressed() &&
      (page_get_data_size(page) + rec_size >=
       dict_index_zip_pad_optimal_page_size(index))) {
fail:
    err = DB_FAIL;  // 空间不足，需要悲观插入
    // 预取兄弟页面 (btr_cur_prefetch_siblings)
    if (page_is_leaf(page)) {
      btr_cur_prefetch_siblings(block);
    }
    goto fail_err;
  }

  // 4. 检查是否需要重组页面碎片
  if (page_get_data_size(page) + rec_size + page_dir_calc_reserved_space() +
          PAGE_PTR_FILE_SPACE_RESERVED >
      page_get_max_insert_size(page, rec_size)) {
    /* 需要重组 → btr_page_reorganize() */
    if (page_size.is_compressed() && !btr_page_reorganize(
            page_cursor, index, mtr)) {
      err = DB_FAIL;
      goto fail_err;
    }
  } else {
    /* 如果 page 有碎片 (>10%)，重组 */
    reorg = (page_get_garbage(page) + rec_size >
             page_get_max_insert_size_after_reorganize(page, rec_size) / 10);
    if (reorg && !page_size.is_compressed()) {
      btr_page_reorganize(page_cursor, index, mtr);
    }
  }

  // 5. 写入 redo log + 页内插入
  page_cur_insert_rec(page_cursor, entry, index, offsets, mtr);

  // 6. 更新 AHI
  btr_search_update_hash_on_insert(cursor);   // btr0sea.cc

  return DB_SUCCESS;
}
```

关键点：
- 如果页面碎片过多（garbage > 10% 可回收空间），会先重组页面。
- 压缩页面的乐观插入受限更严：如果插入后接近最优填充率，直接返回 `DB_FAIL`。
- `page_cur_insert_rec()`（`page0cur.cc`）完成实际的页内记录写入。

### 4.2 btr_cur_pessimistic_insert() — 悲观插入 (btr0cur.cc:2928)

当乐观插入返回 `DB_FAIL` 时，调用悲观插入。它会锁整棵树、预留文件空间，必要时分裂页面。

```c
// btr0cur.cc:2928
dberr_t btr_cur_pessimistic_insert(
    uint32_t flags, btr_cur_t *cursor,
    ulint **offsets, mem_heap_t **heap,
    dtuple_t *entry, rec_t **rec,
    big_rec_t **big_rec, que_thr_t *thr, mtr_t *mtr)
{
  dict_index_t *index = cursor->index;
  dberr_t err;

  cursor->flag = BTR_CUR_BINARY;

  // 1. 检查锁和执行 undo
  err = btr_cur_ins_lock_and_undo(flags, cursor, entry, thr, mtr, &inherit);
  if (err != DB_SUCCESS) return err;

  // 2. 预留空闲 extent（根据树高度调整）
  ulint n_extents = cursor->tree_height / 16 + 3;
  fsp_reserve_free_extents(&n_reserved, index->space, n_extents, FSP_NORMAL, mtr);
  if (!success) return DB_OUT_OF_FILE_SPACE;

  // 3. 根页面 → 提升树高度
  if (dict_index_get_page(index) ==
      btr_cur_get_block(cursor)->page.id.page_no()) {
    *rec = btr_root_raise_and_insert(flags, cursor, offsets, heap, entry, mtr);
  } else {
    // 非根页面 → 分裂
    *rec = btr_page_split_and_insert(flags, cursor, offsets, heap, entry, mtr);
  }

  // ...
}
```

两种路径：
- **根页面插满** → `btr_root_raise_and_insert()`（`btr0btr.h` 声明, `btr0btr.cc` 实现）提升树高度。
- **非根页面插满** → `btr_page_split_and_insert()`（`btr0btr.cc:2305`）分裂页面。

`btr_cur_pessimistic_delete()`（`btr0cur.h` 声明）是删除的对应操作路径。

### 4.3 page_cur_insert_rec() — 页内记录插入

在页面上实际插入记录的底层函数（`page0cur.cc` 中的 `page_cur_insert_rec`）。它将记录写入页面堆顶部、更新页目录、设置 slot owner 关系。

```c
// page0cur.cc (page_cur_insert_rec)
// 函数流程：
// 1. 从 PAGE_HEAP_TOP 分配空间
// 2. 将 dtuple 转换为物理记录并写入
// 3. 更新 PAGE_N_RECS++
// 4. 维护记录链表（prev->next, next->prev）
// 5. 更新 page directory（必要时增加 slot 或调整 owner）
// 6. 更新 PAGE_LAST_INSERT / PAGE_DIRECTION / PAGE_N_DIRECTION
// 7. 写 MLOG_REC_INSERT redo 日志
```

### 4.4 写 redo log (MLOG_REC_INSERT)

每个记录插入都生成 redo 日志条目：

```c
// page0cur.cc 中的 redo 写入
mlog_write_initial_log_record_fast(rec, MLOG_REC_INSERT, mtr, &log_start);
// 然后写入记录数据和页内偏移
mlog_catenate_string(mtr, buf, len);
```

`mlog_write_initial_log_record_fast()`（`page0cur.ic`）写入 redo 记录头，`mlog_catenate_string()` 写入记录载荷。重做日志的类型常量在 `page0types.h` / `mlog0mlog.h` 中定义。

---

## 5. 页面分裂

### 5.1 btr_page_split_and_insert() — 分裂+插入 (btr0btr.cc:2305)

这是页面分裂的核心函数。它把已有的页面一分为二，把新记录插入到合适的一半。

```c
// btr0btr.cc:2305
rec_t *btr_page_split_and_insert(
    uint32_t flags, btr_cur_t *cursor,
    ulint **offsets, mem_heap_t **heap,
    const dtuple_t *tuple, mtr_t *mtr)
{
  // 1. 先尝试插入右侧兄弟（如果可能的话避免分裂）
  rec = btr_insert_into_right_sibling(flags, cursor, offsets, *heap, tuple, mtr);
  if (rec != nullptr) return rec;

  // 2. 决定分裂位置
  insert_left = false;

  if (btr_page_get_split_rec_to_right(cursor, &split_rec)) {
    direction = FSP_UP;
    hint_page_no = page_no + 1;
  } else if (btr_page_get_split_rec_to_left(cursor, &split_rec)) {
    direction = FSP_DOWN;
    hint_page_no = page_no - 1;
  } else {
    // 默认：取中间记录 (page_get_middle_rec, page0page.h)
    if (page_get_n_recs(page) > 1) {
      split_rec = page_get_middle_rec(page);
    } else if (btr_page_tuple_smaller(cursor, tuple, offsets, n_uniq, heap)) {
      split_rec = page_rec_get_next(page_get_infimum_rec(page));
    } else {
      split_rec = nullptr;  // 新记录是新的上界
    }
  }

  // 3. 分配新页面 (btr_page_alloc, btr0btr.h macro)
  new_block = btr_page_alloc(cursor->index, hint_page_no, direction,
                             btr_page_get_level(page), mtr, mtr);
  btr_page_create(new_block, new_page_zip, cursor->index,
                  btr_page_get_level(page), mtr);

  // 4. 确定上下半页的分界记录
  if (split_rec) {
    first_rec = move_limit = split_rec;
    insert_left = cmp_dtuple_rec(tuple, split_rec, ...) < 0;
  }

  // 5. 修改 B+Tree 结构：附加上半页 (btr_attach_half_pages)
  btr_attach_half_pages(flags, cursor->index, block, first_rec,
                        new_block, direction, mtr);

  // 6. 如果可行，释放树锁然后移动记录（减少树锁争用）
  if (insert_will_fit && page_is_leaf(page) && ...) {
    mtr->memo_release(dict_index_get_lock(cursor->index), ...);
    /* NOTE: 此时可以在不持有树锁的情况下移动记录 */
  }

  // 7. 真正移动记录到新页面
  if (insert_left) {
    // 插入左侧（原页）
  } else {
    // 插入右侧（新页）
  }

  // 8. 写入 redo log (MLOG_COMP_PAGE_CREATE / MLOG_ZIP_PAGE_COMPRESS 等)

  return rec;
}
```

`btr_page_alloc()`（`btr0btr.h` 宏展开为 `btr_page_alloc_priv()`）分配新页面。对于 R-tree, `rtr_page_split_and_insert()` 代替默认逻辑。

### 5.2 分裂位置选择 — 中位数

对于普通索引，默认分裂位置是 `page_get_middle_rec()`（`page0page.h`）：

```c
// page0page.h
static inline rec_t *page_get_middle_rec(page_t *page) {
  ulint n_recs = page_get_n_recs(page);
  ut_ad(n_recs > 1);
  return page_rec_get_nth(page, n_recs / 2);  // page_rec_get_nth() 也定义于 page0page.h
}
```

对于插入模式检测，`btr_page_get_split_rec_to_right()` 和 `btr_page_get_split_rec_to_left()`（`btr0btr.h` 声明，`btr0btr.cc` 实现）会分析 `PAGE_DIRECTION` 和 `PAGE_N_DIRECTION` 统计信息：如果插入一直在向右新增（顺序插入），则偏右分裂。

### 5.3 分裂后父节点更新

分裂后调用 `btr_attach_half_pages()`，它在父节点上插入一个新的 node pointer 指向新页面。这可能导致父节点也需要分裂——这是一个递归过程。

```c
// btr0btr.cc
static void btr_attach_half_pages(...) {
  // 1. 为新页面创建 node pointer
  // 2. 在父节点上插入新的 node pointer
  //   → btr_insert_on_non_leaf_level(flags, index, level + 1, tuple, ...)
  //     (btr0btr.h 声明)
  // 3. 更新原页面的 FIL_PAGE_NEXT/FIL_PAGE_PREV
  // 4. 调整双向链表
}
```

### 5.4 创建兄弟节点

新的兄弟页面通过 `btr_page_alloc()` 分配：

```c
// btr0btr.h → btr_page_alloc macro
buf_block_t *btr_page_alloc_priv(
    dict_index_t *index, page_no_t hint_page_no,
    byte file_direction, ulint level,
    mtr_t *mtr, mtr_t *init_mtr ...);
```

`hint_page_no` 是接近原页面的页号，`file_direction` 是 `FSP_UP` 或 `FSP_DOWN`，用于空间局部性优化。`btr_page_create()`（`btr0btr.h` 声明）初始化新页面。

---

## 6. 页面合并与压缩

### 6.1 btr_compress() — 页面合并 (btr0btr.cc:3023)

当页面删除记录后变得太稀疏（低于 `merge_threshold`，默认 50%），InnoDB 会尝试合并页面。

```c
// btr0btr.cc:3023
bool btr_compress(btr_cur_t *cursor, bool adjust, mtr_t *mtr) {
  block = btr_cur_get_block(cursor);
  page = btr_cur_get_page(cursor);
  index = cursor->index;

  left_page_no = btr_page_get_prev(page, mtr);
  right_page_no = btr_page_get_next(page, mtr);

  // 1. 如果此 level 只有这一页 → 提升到父页 (btr_lift_page_up)
  if (left_page_no == FIL_NULL && right_page_no == FIL_NULL) {
    merge_block = btr_lift_page_up(index, block, mtr);
    goto func_exit;
  }

  // 2. 决定与左侧还是右侧合并 (btr_can_merge_with_page)
  is_left = btr_can_merge_with_page(cursor, left_page_no, &merge_block, mtr);

  if (!is_left && !btr_can_merge_with_page(cursor, right_page_no,
                                           &merge_block, mtr)) {
    goto err_exit;  // 无法与任一兄弟合并
  }

  // 3. 移动记录到合并页
  if (is_left) {
    // 把当前页的所有记录移动到左侧页
    page_copy_rec_list_start(merge_block, block,
                             page_get_supremum_rec(page), index, mtr);
    btr_search_drop_page_hash_index(block);
    btr_level_list_remove(space, page_size, page, index, mtr);
    btr_page_free(index, block, mtr);
  } else {
    // 把当前页的所有记录移动到右侧页
    btr_search_drop_page_hash_index(block);
    btr_level_list_remove(space, page_size, page, index, mtr);
    page_copy_rec_list_end(merge_block, block,
                           page_get_infimum_rec(page), index, mtr);
    btr_page_free(index, block, mtr);
  }

  // 4. 删除父节点的 node pointer（btr_node_ptr_delete, btr0btr.h 声明）
  btr_node_ptr_delete(index, block, mtr);

  // ... 如果父页也变空，递归合并

func_exit:
  MONITOR_INC(MONITOR_INDEX_MERGE_SUCCESSFUL);
  if (adjust) { /* 调整 cursor 位置 */ }
  return true;
}
```

`btr_page_free()`（`btr0btr.h` 声明）释放空页回文件空间。

### 6.2 什么时触发合并

合并的判断来自 `BTR_CUR_PAGE_COMPRESS_LIMIT`：

```c
// btr0cur.h
#define BTR_CUR_PAGE_COMPRESS_LIMIT(index) \
  ((UNIV_PAGE_SIZE * (ulint)((index)->merge_threshold)) / 100)
```

默认 `merge_threshold` = 50（`dict0mem.h:1067` 中 `merge_threshold : 6` 字段），即页面使用率低于 50% 时尝试合并。删除时 `btr_cur_compress_if_useful()`（`btr0cur.h` 声明）在 `btr_cur_pessimistic_delete()` 中记录删除后调用：

```c
// btr0cur.cc 中的悲观删除
if (page_get_data_size(page) < BTR_CUR_PAGE_COMPRESS_LIMIT(index)) {
  btr_cur_compress_if_useful(cursor, adjust, mtr);
}
```

### 6.3 btr_page_reorganize() — 页面重组 (btr0btr.cc:1396)

```c
// btr0btr.cc:1396
bool btr_page_reorganize(page_cur_t *cursor, dict_index_t *index, mtr_t *mtr) {
  return btr_page_reorganize_low(false, page_zip_level, cursor, index, mtr);
}
```

`btr_page_reorganize_low()`（`btr0btr.cc`）的实现：

```
// btr_page_reorganize_low 流程（btr0btr.cc）:
// 1. 清除当前页的 AHI 条目（btr_search_drop_page_hash_index, btr0sea.cc:755）
// 2. 将页内所有记录按顺序重新排列到新缓冲区
// 3. 重建 page directory
// 4. 重置 PAGE_HEAP_TOP, PAGE_GARBAGE=0
// 5. 如果是压缩页，重新压缩
// 6. 写 MLOG_PAGE_REORGANIZE redo 日志
// 7. 重建 AHI 条目
```

重组消除页内碎片（garbage space），但不改变页面的记录数量。

### 6.4 释放空页

合并后，空页面通过 `btr_page_free()` 释放回文件空间：

```c
// btr0btr.h 声明
void btr_page_free(dict_index_t *index, buf_block_t *block, mtr_t *mtr);
```

这会将页面标记为空闲，放入 extent 的空闲列表中。`btr_page_free_low()`（`btr0btr.h`）也支持释放 BLOB 外部存储页。

---

## 7. 自适应哈希索引 (AHI)

### 7.1 btr_search_t 结构 (btr0sea.h:46)

之前已在 1.5 节描述。每个索引有一个 `btr_search_t` 跟踪 AHI 状态。全局 AHI 系统 `btr_search_sys` 包含多个分区（`btr_ahi_parts`，默认 8）。

`btr_search_sys_create()`（`btr0sea.cc` 构造函数）在数据库启动时初始化 AHI 系统，`btr_search_sys_free()` 在关闭时释放。

### 7.2 btr_search_guess_on_hash() — 哈希查找 (btr0sea.cc:804)

这是 AHI 的查找入口。在 `btr_cur_search_to_nth_level()` 循环之前调用：

```c
// btr0sea.cc:804
bool btr_search_guess_on_hash(const dtuple_t *tuple, ulint mode,
                              ulint latch_mode, btr_cur_t *cursor,
                              ulint has_search_latch, mtr_t *mtr)
{
  if (!btr_search_enabled) return false;

  const auto index = cursor->index;
  const auto info = index->search_info;

  // 1. 检查 n_hash_potential：如果为 0，AHI 从未被构建
  cursor->flag = BTR_CUR_HASH_NOT_ATTEMPTED;
  if (info->n_hash_potential == 0) return false;

  // 2. 获取记录的 prefix_info（哈希参数）
  const auto prefix_info = info->prefix_info.load();
  cursor->ahi.prefix_info = prefix_info;

  // 3. 检查 tuple 字段数是否足够
  if (dtuple_get_n_fields(tuple) < btr_search_get_n_fields(cursor)) {
    return false;
  }

  // 4. 计算哈希值（使用 btr_hash_seed_for_record + prefix_info）
  const auto hash_value =
      dtuple_hash(tuple, prefix_info.n_fields, prefix_info.n_bytes,
                  btr_hash_seed_for_record(index));
  cursor->ahi.ahi_hash_value = hash_value;

  // 5. 获取 AHI latch（S模式，不等待）
  if (!has_search_latch) {
    if (!btr_search_s_lock_nowait(index, UT_LOCATION_HERE)) {
      return false;  // 锁争用，跳过 AHI
    }
  }

  // 6. 从哈希表查找 (ha_search_and_get_data, ha0ha.h)
  rec = (rec_t *)ha_search_and_get_data(
      btr_get_search_table(index), hash_value);

  if (rec == nullptr) {
    cursor->flag = BTR_CUR_HASH_FAIL;
    info->last_hash_succ = false;
    return false;
  }

  // 7. 获取缓存页（不等待/不阻塞）
  buf_block_t *block = buf_block_from_ahi(rec);
  if (!buf_page_get_known_nowait(latch_mode, block, Cache_hint::MAKE_YOUNG,
                                 __FILE__, __LINE__, mtr)) {
    return false;  // 页不在 buffer pool 中
  }

  // 8. 验证 AHI 条目是否仍有效
  if (block->ahi.index != index ||
      block->ahi.prefix_info.load() != prefix_info) {
    return false;  // 条目已失效
  }

  // 9. 验证记录是否满足搜索条件
  cursor->page_cur.block = block;
  cursor->page_cur.rec = (rec_t *)rec;
  cursor->page_cur.index = index;

  // 10. 验证比较结果
  // ...

  cursor->flag = BTR_CUR_HASH;
  info->last_hash_succ = true;
  return true;
}
```

AHI 查找的成功路径：

```
btr_cur_search_to_nth_level()
  ↓ (AHI enabled + last_hash_succ + ...)
btr_search_guess_on_hash()
  ↓ 计算 hash_value
  ↓ 获取 AHI S-latch（不等待, btr_search_s_lock_nowait, btr0sea.ic:60）
  ↓ ha_search_and_get_data(hash_table, hash_value)
  ↓ 获取页面（buf_page_get_known_nowait, 不等待）
  ↓ 验证 index + prefix_info
  ↓ 验证比较结果
  ↓ 成功！BTR_CUR_HASH，直接返回
```

### 7.3 btr_search_build_page_hash_index() — 构建索引 (btr0sea.cc:1404)

当某个页面的访问达到一定频率后，AHI 会在该页面构建哈希索引：

```c
// btr0sea.cc:1404
static void btr_search_build_page_hash_index(
    dict_index_t *index, buf_block_t *block, bool update)
{
  if (index->disable_ahi || !btr_search_enabled) return;

  // 如果 block 已有不同 prefix_info 的 AHI → 先删除
  if (block->ahi.index && block->ahi.prefix_info.load() != prefix_info) {
    btr_search_drop_page_hash_index(block);
  }

  if (prefix_info.n_fields == 0 && prefix_info.n_bytes == 0) return;

  // 扫描页面上的所有记录，计算哈希值
  const auto n_recs = page_get_n_recs(page);
  auto hashes = ut::make_unique<uint64_t[]>(n_recs);
  auto recs = ut::make_unique<rec_t *[]>(n_recs);

  // 遍历每条记录，使用 rec_hash() 计算哈希值
  for (;;) {
    hash_value = rec_hash(rec, offsets, prefix_info.n_fields,
                          prefix_info.n_bytes, index_hash, index);
    if (prefix_info.left_side) {
      hashes[n_cached] = hash_value;
      recs[n_cached] = rec;
    }
    // 按 left_side 规则分组插入
    // ...
  }

  // 批量插入到 AHI 哈希表
  btr_search_x_lock(index, UT_LOCATION_HERE);  // 获取 X latch (btr0sea.ic)
  for (i = 0; i < n_cached; i++) {
    ha_insert_for_hash(hash_table, hashes[i], block, recs[i]);
  }
  btr_search_x_unlock(index);

  // 更新 block 的 AHI 元数据
  block->ahi.index = index;
  block->ahi.prefix_info.store(prefix_info);
  /* 增加 index->search_info->ref_count */
  btr_search_info_ref_count_inc(index);
}
```

`rec_hash()` 函数基于 `n_fields` 个前缀字段 + `n_bytes` 额外字节计算哈希值，`left_side` 控制记录的哈希存储策略。

### 7.4 分区 AHI (btr_search_t.parts)

AHI 被分成多个分区来减少锁竞争：

```c
// btr0sea.h
extern ulong btr_ahi_parts;  // 默认 8
extern ut::fast_modulo_t btr_ahi_parts_fast_modulo;

static inline size_t btr_search_hash_index_id(const dict_index_t *index) {
  // 通过 index id + space id 选择分区
  return ut::hash_uint64_pair(index->space, index->id) %
         btr_ahi_parts.load();
}

static inline btr_search_sys_t::search_part_t &btr_get_search_part(
    const dict_index_t *index) {
  return btr_search_sys->parts[btr_search_hash_index_id(index)];
}
```

每个分区有独立的 `rw_lock_t latch` 和 `hash_table_t *hash_table`，以及一个 `free_block_for_heap` 原子指针用于无锁内存分配。

### 7.5 何时构建/删除 AHI

构建的触发：

```c
// btr0sea.ic
static inline void btr_search_info_update(btr_cur_t *cursor) {
  if (dict_index_is_spatial(index) || !btr_search_enabled) return;
  if (cursor->flag == BTR_CUR_HASH_NOT_ATTEMPTED) return;

  // 当 hash_analysis 超过 BTR_SEARCH_HASH_ANALYSIS (17) 时触发分析
  const auto hash_analysis_value = ++index->search_info->hash_analysis;
  if (hash_analysis_value < BTR_SEARCH_HASH_ANALYSIS) return;

  btr_search_info_update_slow(cursor);  // btr0sea.cc:649
}

// btr0sea.cc:649
void btr_search_info_update_slow(btr_cur_t *cursor) {
  // 1. 更新前缀信息（n_fields, n_bytes, left_side）
  btr_search_info_update_hash(cursor);      // btr0sea.cc

  // 2. 决定是否在当前页构建哈希索引
  if (btr_search_update_block_hash_info(block, cursor)) {
    // → 最终调用 btr_search_build_page_hash_index() (btr0sea.cc:1404)
  }
}
```

删除 AHI 条目的时机（`btr0sea.h` 声明，`btr0sea.cc` 实现）：
- **页面分裂/合并**：`btr_search_drop_page_hash_index(block)`（`btr0sea.cc:755`）
- **页面重组**：`btr_search_drop_page_hash_index(block)`
- **页面 eviction**：`btr_search_drop_page_hash_when_freed(page_id, page_size)`（`btr0sea.cc:766`）
- **DDL 操作**：`btr_drop_ahi_for_table(table)` / `btr_drop_ahi_for_index(index)`（`btr0sea.cc:801`）
- **AHI 禁用**：`btr_search_disable()`（`btr0sea.h` 声明）

---

## 8. 持久游标 (btr_pcur)

### 8.1 btr_pcur_open() — 打开游标

```c
// btr0pcur.h (inline 实现)
inline void btr_pcur_t::open(dict_index_t *index, ulint level,
                             const dtuple_t *tuple, page_cur_mode_t mode,
                             ulint latch_mode, mtr_t *mtr,
                             ut::Location location)
{
  init();
  open_no_init(index, tuple, mode, latch_mode, 0, mtr, location);
}

inline void btr_pcur_t::open_no_init(
    dict_index_t *index, const dtuple_t *tuple, page_cur_mode_t mode,
    ulint latch_mode, ulint has_search_latch, mtr_t *mtr,
    ut::Location location)
{
  m_pos_state = BTR_PCUR_IS_POSITIONED;
  m_latch_mode = latch_mode;
  m_search_mode = mode;

  btr_cur_search_to_nth_level(index, 0, tuple, mode, latch_mode,
                               &m_btr_cur, has_search_latch, ...);
}
```

### 8.2 btr_pcur_move_to_next() — 下一条 (btr0pcur.h:320 声明)

```c
// btr0pcur.cc
bool btr_pcur_t::move_to_next(mtr_t *mtr) {
  // 1. 在当前页面内移动到下一条
  move_to_next_on_page();

  // 2. 如果还在当前页面内，直接返回
  if (!is_after_last_on_page()) return true;

  // 3. 如果已经在页尾，需要跨页
  // 获取下一页（FIL_PAGE_NEXT）
  page_no_t next_page_no = btr_page_get_next(get_page(), mtr);
  if (next_page_no == FIL_NULL) {
    // 已经是最后一页
    return false;
  }

  // 4. 移动到下一页 (move_to_next_page, 释放当前页 latch, latch 下一页)
  move_to_next_page(mtr);

  // 5. 定位到第一用户记录
  page_cur_set_before_first(get_block(), get_page_cur());
  move_to_next_on_page();

  return true;
}
```

`move_to_prev()` / `move_to_next_user_rec()` 等变体也定义在 `btr0pcur.h` 和 `btr0pcur.cc` 中。

### 8.3 btr_pcur_get_block / get_rec — 获取当前

```c
// btr0pcur.h
inline buf_block_t *btr_pcur_t::get_block() {
  return btr_cur_get_block(&m_btr_cur);
}
inline rec_t *btr_pcur_t::get_rec() {
  return btr_cur_get_rec(&m_btr_cur);
}
```

`get_page()`、`get_up_match()`、`get_low_match()` 等函数也定义在 `btr0pcur.h` 中。

### 8.4 用于范围扫描

典型范围扫描模式（`row0sel.cc` 中的 `row_search_mvcc()` 使用）：

```c
// 范围扫描伪代码
btr_pcur_t pcur;
pcur.open(index, 0, &lower_tuple, PAGE_CUR_GE, BTR_SEARCH_LEAF, mtr);

while (!pcur.is_after_last_in_tree(mtr)) {
  rec_t *rec = pcur.get_rec();
  // 处理当前记录
  // ...

  pcur.move_to_next(mtr);
}
```

持久游标的 `restore_position()` 机制（`btr0pcur.h` 声明，`btr0pcur.cc:203` 实现）让它在跨 mtr 操作时仍然能正确恢复位置：

```c
// btr0pcur.cc:203
bool btr_pcur_t::restore_position(ulint latch_mode, mtr_t *mtr,
                                  ut::Location location)
{
  // 尝试乐观恢复（使用 modify_clock 检查页面是否未变）
  if (btr_cur_optimistic_latch_leaves(
          hint, m_modify_clock, &latch_mode, &m_btr_cur,
          location.filename, location.line, mtr)) {
    // 乐观恢复成功
    return true;
  }

  // 乐观恢复失败 → 走完整搜索
  // 构造搜索 tuple 从 m_old_rec
  // 调用 btr_cur_search_to_nth_level()
  return false;
}
```

---

## 9. 完整数据流

### 9.1 唯一键查找 (point lookup) 路径

```
SQL: SELECT * FROM t WHERE id = 42;

→ row_search_mvcc()                          (row0sel.cc)
  → btr_pcur_open(index, tuple, PAGE_CUR_GE, BTR_SEARCH_LEAF)
    → btr_cur_search_to_nth_level(index, 0, tuple, PAGE_CUR_GE,
                                    BTR_SEARCH_LEAF, cursor, ...)
      → AHI 快速路径尝试：
        btr_search_guess_on_hash() — 成功则直接返回
      → 从根页面开始，逐层：
        1. latch 根节点 (btr_root_block_get, btr0btr.h)
        2. page_cur_search_with_match() — 二分查找定位 (page0cur.cc:328)
        3. btr_node_ptr_get_child_page_no() — 获取子页号 (btr0btr.ic)
        4. 释放父节点 latch（mtr_release_savepoint）
        5. repeat 直到叶子层
      → latch 叶子页
      → 返回记录的精确位置
    → 读取记录数据 (row_sel_get_clust_rec, row0sel.cc)
```

### 9.2 范围扫描 (range scan) 路径

```
SQL: SELECT * FROM t WHERE id BETWEEN 10 AND 100;

→ row_search_mvcc()                          (row0sel.cc)
  → btr_pcur_open(index, &lower_bound, PAGE_CUR_GE, BTR_SEARCH_LEAF)
    → 同上，定位到 >=10 的第一个记录
  → while (pcur.move_to_next(mtr)):
    → 如果当前记录 <= 100：返回记录
    → 否则：扫描结束

  // 持久游标的跨页能力
  → move_to_next() (btr0pcur.cc) 自动处理：
    同一页内 → page_rec_get_next()
    下一页   → btr_page_get_next() → move_to_next_page()
    直到 FIL_PAGE_NEXT == FIL_NULL
```

`btr_estimate_n_rows_in_range()`（`btr0cur.h` 声明，`btr0cur.cc` 实现）和 `btr_estimate_number_of_different_key_vals()` 利用 `btr_path_t` 数组（`btr_path_t`，`btr0cur.h`，`BTR_PATH_ARRAY_N_SLOTS = 250`）进行统计信息采样。

### 9.3 插入一条记录在 B+Tree 中的完整路径

```
SQL: INSERT INTO t VALUES (42, 'hello');

→ row_insert_for_mysql()                     (row0ins.cc)
  → btr_cur_search_to_nth_level(..., PAGE_CUR_LE, BTR_MODIFY_LEAF | BTR_INSERT)
    → 找到插入位置（<=42 的最后一条记录后）
  → btr_cur_optimistic_insert()              (btr0cur.cc:2660)
    成功 → 直接插入，完成
    失败 (DB_FAIL) →
      → btr_cur_pessimistic_insert()         (btr0cur.cc:2928)
        → 锁整棵树 (mtr_sx_lock 或 mtr_x_lock)
        → 预留文件空间 (fsp_reserve_free_extents)
        → 如果当前页是根页：
          btr_root_raise_and_insert()         // 提升树高度
        → 否则：
          btr_page_split_and_insert()         // btr0btr.cc:2305
            → 决定分裂位置（中位数/偏向）
            → btr_page_alloc() 分配新页
            → btr_attach_half_pages():
                创建 node pointer 插入父节点（可能递归 btr_insert_on_non_leaf_level）
            → 移动记录到合适的一半
            → 插入新记录
        → 释放树锁
```

`btr_root_raise_and_insert()` 创建新的根节点，在旧根节点与新根之间插入 node pointer。`btr_create()`（`btr0btr.h` 声明）用于新建空 B-tree 的根节点。

### 9.4 删除记录在 B+Tree 中的路径

```
SQL: DELETE FROM t WHERE id = 42;

→ row_delete_for_mysql()                     (row0del.cc)
  → btr_cur_search_to_nth_level(..., PAGE_CUR_GE, BTR_MODIFY_LEAF | BTR_DELETE)
  → btr_cur_optimistic_delete()              (btr0cur.h inline)
    → btr_cur_optimistic_delete_func()       (btr0cur.cc)
    成功 → 检查是否需要合并
    失败 →
      → btr_cur_pessimistic_delete()         (btr0cur.h 声明, btr0cur.cc 实现)
        → 锁整棵树
        → 删除记录
        → 如果页面数据量 < merge_threshold：
          btr_cur_compress_if_useful()
            → btr_compress()                 (btr0btr.cc:3023)
              → 与左/右兄弟合并 (btr_can_merge_with_page)
              → 移动记录 (page_copy_rec_list_start/end)
              → btr_search_drop_page_hash_index(block)  (btr0sea.cc:755)
              → btr_level_list_remove()
              → btr_page_free() 释放空页
              → btr_node_ptr_delete() 删除父节点 node pointer
              → 递归检查父节点是否需要压缩
```

对于二级索引，删除标记通过 `btr_cur_del_mark_set_sec_rec()`（`btr0cur.h` 声明）设置 delete mark 位。聚簇索引的 delete mark 通过 `btr_cur_del_mark_set_clust_rec()` 设置，同时写入 undo 日志。`btr_cur_pessimistic_delete()` 支持重试（`BTR_CUR_RETRY_DELETE_N_TIMES = 100`, `btr0cur.h`）。

---

## 10. 关键函数索引

| 函数 | 文件 | 行号 | 用途 |
|------|------|------|------|
| `btr_cur_search_to_nth_level` | btr0cur.cc | 619 | B+Tree 搜索（根→叶） |
| `page_cur_search_with_match` | page0cur.cc | 328 | 页内二分查找 |
| `page_cur_search_with_match_bytes` | page0cur.cc | 或搜索 page0cur.cc | 含字节匹配的页内二分查找 |
| `btr_cur_optimistic_insert` | btr0cur.cc | 2660 | 乐观插入 |
| `btr_cur_pessimistic_insert` | btr0cur.cc | 2928 | 悲观插入（含分裂） |
| `btr_cur_optimistic_delete` | btr0cur.h | inline | 乐观删除 |
| `btr_cur_pessimistic_delete` | btr0cur.h | 声明 | 悲观删除 |
| `btr_cur_del_mark_set_clust_rec` | btr0cur.h | 声明 | 聚簇索引 delete mark |
| `btr_cur_del_mark_set_sec_rec` | btr0cur.h | 声明 | 二级索引 delete mark |
| `btr_page_split_and_insert` | btr0btr.cc | 2305 | 页面分裂+插入 |
| `btr_root_raise_and_insert` | btr0btr.h/cc | 声明/实现 | root page 分裂提升树高 |
| `btr_attach_half_pages` | btr0btr.cc | 静态函数 | 分裂后半页附着到树 |
| `btr_insert_on_non_leaf_level` | btr0btr.h | 声明 | 非叶子层插入 node pointer |
| `btr_compress` | btr0btr.cc | 3023 | 页面合并 |
| `btr_page_reorganize` | btr0btr.cc | 1396 | 页面重组（碎片整理） |
| `btr_lift_page_up` | btr0btr.cc | 静态函数 | level 仅一页时提升 |
| `btr_search_guess_on_hash` | btr0sea.cc | 804 | AHI 哈希查找 |
| `btr_search_build_page_hash_index` | btr0sea.cc | 1404 | 构建页面的 AHI 条目 |
| `btr_search_info_update_slow` | btr0sea.cc | 649 | 更新 AHI 统计/构建决策 |
| `btr_search_drop_page_hash_index` | btr0sea.cc | 755 | 删除页面 AHI 条目 |
| `btr_search_drop_page_hash_when_freed` | btr0sea.cc | 766 | 页面释放时清理 AHI |
| `btr_pcur_open` | btr0pcur.h | inline | 打开持久游标 |
| `btr_pcur_restore_position` | btr0pcur.cc | 203 | 恢复游标位置 |
| `btr_pcur_move_to_next` | btr0pcur.cc | btr0pcur.cc 实现 | move to next, 跨页处理 |
| `btr_pcur_store_position` | btr0pcur.cc | btr0pcur.cc 实现 | 存储位置供后续恢复 |
| `btr_pcur_move_to_prev` | btr0pcur.h | 声明 | 前一条记录 |
| `btr_pcur_move_to_next_user_rec` | btr0pcur.h | 声明 | 跳到下一条用户记录 |
| `btr_node_ptr_get_child_page_no` | btr0btr.ic | inline | 从 node pointer 取子页号 |
| `btr_node_ptr_get_child` | btr0btr.h | 声明 | 取子页并 latch |
| `btr_node_ptr_delete` | btr0btr.h | 声明 | 删除父节点 node pointer |
| `btr_page_get_level` | btr0btr.ic | inline | 获取页面的 B-tree level |
| `btr_page_get_next/prev` | btr0btr.ic | inline | 页面的双向链表指针 |
| `btr_height_get` | btr0btr.h | 声明 | 获取 B-tree 高度 |
| `page_cur_insert_rec` | page0cur.cc | 实现 | 页内记录插入 |
| `page_create` | page0page.h | 553 | 创建空页面 |
| `page_get_middle_rec` | page0page.h | inline | 获取中间记录（用于分裂） |
| `page_dir_get_nth_slot` | page0page.h | 307 | 获取第 n 个 directory slot |
| `page_dir_slot_get_rec` | page0page.h | 319 | 从 slot 获取记录指针 |
| `btr_page_alloc` | btr0btr.h | macro | 分配新页面 |
| `btr_page_free` | btr0btr.h | 声明 | 释放页面 |
| `btr_create` | btr0btr.h | 声明 | 创建新 B-tree 的根节点 |
| `btr_block_get` | btr0btr.h | inline | 获取页面并声明 latching order |
| `btr_root_block_get` | btr0btr.h | 声明 | 获取根页面 |
| `btr_cur_optimistic_latch_leaves` | btr0cur.h | 声明 | 乐观 latch 叶子页 |
| `btr_cur_compress_if_useful` | btr0cur.h | 声明 | 必要时尝试压缩页面 |
| `btr_cur_latch_leaves` | btr0cur.h | 声明 | latch 叶子页及兄弟 |
| `btr_search_info_update` | btr0sea.ic | inline | 更新 AHI 统计（搜索后调用） |
| `btr_search_s_lock/x_lock` | btr0sea.ic | 60+ | AHI partition latch 操作 |
| `page_is_leaf` | page0page.h | 361 | 检查是否叶子页 (PAGE_LEVEL=0) |
| `page_rec_get_next/prev` | page0page.h | 385-410 | 页内记录链表遍历 |
| `fil_page_get_prev/next` | fil0fil.h | 声明 | 文件级页双向链表 |

---

## 总结

InnoDB 的 B+Tree 实现经过 30 年（自 Heikki Tuuri 1994 年创建以来）的打磨，在以下方面做了深度优化：

1. **搜索路径**：从根到叶子逐层二分查找（`page_cur_search_with_match`, `page0cur.cc:328`），配合 AHI 快速路径（`btr_search_guess_on_hash`, `btr0sea.cc:804`）在热点查询时可跳过整棵树。
2. **插入路径**：乐观/悲观双路径设计（`btr0cur.cc:2660`/`btr0cur.cc:2928`），乐观插入只在页面有足够空间时执行，否则走页面分裂（`btr_page_split_and_insert`, `btr0btr.cc:2305`）。
3. **分裂策略**：根据插入模式（顺序插入 vs 随机插入）动态选择分裂位置，通过 `PAGE_DIRECTION` / `PAGE_N_DIRECTION` 统计判断。
4. **合并策略**：删除导致页面过空后（`BTR_CUR_PAGE_COMPRESS_LIMIT` < 50%）尝试与兄弟页合并（`btr_compress`, `btr0btr.cc:3023`），必要时减少 B-Tree 高度（`btr_lift_page_up`）。
5. **自适应哈希索引**：通过分析搜索模式，自动为热点页面构建 O(1) 哈希索引（`btr_search_build_page_hash_index`, `btr0sea.cc:1404`），以 8 个分区（`btr_ahi_parts`）减少锁竞争。
6. **持久游标**：通过 key prefix + modify_clock 实现跨 mini-transaction 的游标位置恢复（`btr_pcur_t`, `btr0pcur.cc:203`），支撑高效范围扫描。

所有这些机制协作，使得 InnoDB 的 B+Tree 即使在高并发、随机读写场景下也能保持稳定的性能。

---

## 补充参考

以下是正文中未直接引用的关键函数和常量的补充参考：

| 符号 | 文件 | 说明 |
|------|------|------|
| `btr_search_update_hash_on_insert` | btr0sea.cc:1736 | 插入后更新页的 AHI |
| `btr_search_update_hash_on_delete` | btr0sea.cc:1631 | 删除后更新页的 AHI |
| `btr_search_update_hash_ref` | btr0sea.cc:具体实现 | 更新 AHI 哈希引用（BTR_CUR_HASH_FAIL 后） |
| `btr_search_update_block_hash_info` | btr0sea.cc:具体实现 | 决定是否在某块构建 AHI |
| `btr_search_info_update_hash` | btr0sea.cc:具体实现 | 更新索引的 prefix_info |
| `btr_search_drop_ahi_for_index` | btr0sea.h:声明 | 删除指定索引的所有 AHI 条目 |
| `btr_search_drop_ahi_for_table` | btr0sea.h:声明 | 删除指定表的所有 AHI 条目 |
| `btr_pcur_t::store_position` | btr0pcur.cc:42 | 存储游标当前位置 |
| `btr_pcur_t::copy_stored_position` | btr0pcur.cc:具体实现 | 复制存储的游标位置 |
| `btr_pcur_t::move_to_next_page` | btr0pcur.h:声明 | 跨页移动到下一页 |
| `btr_pcur_t::move_to_prev` | btr0pcur.h:声明 | 前一条记录 |
| `btr_pcur_t::move_to_next_user_rec` | btr0pcur.h:声明 | 跳到下一条用户记录 |
| `btr_pcur_t::commit_specify_mtr` | btr0pcur.h:声明 | 提交 mtr 并脱离游标 |
| `btr_root_raise_and_insert` | btr0btr.cc:1482 | 提升根节点一层 |
| `btr_lift_page_up` | btr0btr.cc:2856 | 页面提升（压缩树） |
| `btr_node_ptr_delete` | btr0btr.h:声明 | 删除父节点中的 node pointer |
| `btr_attach_half_pages` | btr0btr.cc:实现 | 分裂后附着半页 |
| `btr_insert_on_non_leaf_level` | btr0btr.h:声明 | 非叶子层插入记录 |
| `btr_page_create` | btr0btr.h:声明 | 创建新索引页 |
| `btr_page_empty` | btr0btr.cc:实现 | 清空索引页 |
| `btr_page_alloc` | btr0btr.h:macro | 分配新页面 |
| `btr_page_free` | btr0btr.h:声明 | 释放页面 |
| `btr_page_free_low` | btr0btr.h:声明 | 释放页面（含 BLOB） |
| `btr_truncate` | btr0btr.h:声明 | 截断 B-tree |
| `btr_free_if_exists` | btr0btr.h:声明 | 释放 B-tree |
| `page_cur_insert_rec` | page0cur.cc:实现 | 页内记录插入 |
| `page_is_comp` | page0page.h:内联 | 检查是否紧凑格式 |
| `page_check_dir` | page0page.h:内联 | 验证 page directory |
| `page_rec_get_nth` | page0page.h:内联 | 获取第 n 条记录 |
| `page_rec_get_n_recs_before` | page0page.h:内联 | 获取某记录前的记录数 |
| `page_is_empty` | page0page.h:365 | 检查页面是否为空 |
| `page_create_zip` | page0page.h:566 | 创建压缩空页面 |
| `fil_page_get_type` | fil0fil.h:内联 | 获取文件页类型 |
| `fil_page_set_type` | fil0fil.h:声明 | 设置文件页类型 |
| `BTR_CUR_PAGE_COMPRESS_LIMIT` | btr0cur.h:macro | 页面合并阈值宏 |
| `BTR_CUR_RETRY_DELETE_N_TIMES` | btr0cur.h:100 | 悲观删除重试次数 |
| `BTR_CUR_RETRY_SLEEP_TIME_MS` | btr0cur.h:50 | 重试间隔毫秒 |
| `BTR_SEARCH_HASH_ANALYSIS` | btr0sea.h:17 | AHI 分析触发阈值 |
| `BTR_SEARCH_ON_HASH_LIMIT` | btr0sea.h:3 | 哈希搜索尝试上限 |
| `BTR_MAX_LEVELS` | btr0btr.h:100 | B-tree 最大深度 |
| `BTR_MAX_NODE_LEVEL` | btr0btr.h:45 | 节点最大 level 断言值 |
| `PAGE_DIR_SLOT_MAX_N_OWNED` | page0page.h:8 | slot 最大管理记录数 |
| `PAGE_DIR_SLOT_MIN_N_OWNED` | page0page.h:4 | slot 最小管理记录数 |
