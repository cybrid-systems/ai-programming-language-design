# 16-change-buffer — InnoDB Change Buffer 源码深度分析

## 0. 概述

Change Buffer（曾用名 Insert Buffer）是 InnoDB 用来优化**非唯一二级索引**写入的核心机制。当目标索引页不在 Buffer Pool 中时，InnoDB 将修改操作缓存到 Change Buffer 中，等到该页被读取时再异步合并（merge），从而将随机写入聚合为顺序写入。

### 解决的问题

二级索引的写入通常是离散的：插入一条记录需要定位到 B+Tree 的某个叶子页，该页大概率不在 Buffer Pool 中，导致频繁的随机 I/O。Change Buffer 将多个针对不同页的操作缓存起来，在合并时一次性刷回，大幅降低随机 I/O 对写入性能的影响。

### 可缓存的操作类型

```c
// ibuf0ibuf.h:36 — 枚举定义（注意：这些值存储在磁盘上，不得修改！）
typedef enum {
  IBUF_OP_INSERT = 0,       // INSERT
  IBUF_OP_DELETE_MARK = 1,   // DELETE MARK（标记删除）
  IBUF_OP_DELETE = 2,        // PURGE 阶段的物理删除
  IBUF_OP_COUNT = 3
} ibuf_op_t;
```

用户通过 `innodb_change_buffering` 变量控制缓存范围：

```c
// ibuf0ibuf.h:49
enum ibuf_use_t {
  IBUF_USE_NONE = 0,
  IBUF_USE_INSERT,             // 仅 INSERT
  IBUF_USE_DELETE_MARK,        // 仅 DELETE MARK
  IBUF_USE_INSERT_DELETE_MARK, // INSERT + DELETE MARK
  IBUF_USE_DELETE,             // DELETE MARK + PURGE DELETE
  IBUF_USE_ALL                 // 全部（默认）
};
```

### 限制条件

Change Buffer **不会/不能**缓存以下操作：

- 聚簇索引页（主键）的修改
- 唯一二级索引的插入（需要立即检查唯一性约束）
- 空间索引（SPATIAL）
- 降序索引（DESC）
- 系统表空间（`dict_space_id`）
- 临时表空间的页
- `innodb_force_recovery >= SRV_FORCE_NO_IBUF_MERGE`

---

## 1. 核心数据结构

### 1.1 ibuf_t 控制结构

`ibuf_t` 定义在 `ibuf0ibuf.ic:62`，是整个 Change Buffer 的全局状态：

```c
// ibuf0ibuf.ic:62-87
struct ibuf_t {
  ulint size;           /* = ibuf B-tree 当前页面数 */
  ulint max_size;       /* = ibuf 推荐最大页面数（基于 BP 百分比计算） */
  ulint seg_size;       /* = file segment 已分配的页面数 */
  bool empty;           /* = true 当且仅当 ibuf B-tree 为空 */
  ulint free_list_len;  /* = free list 长度 */
  ulint height;         /* = B-tree 高度 */
  dict_index_t *index;  /* = ibuf B-tree 的字典索引对象 */

  std::atomic<ulint> n_merges;            /* = 已触发的 merge 次数 */
  std::atomic<ulint> n_merged_ops[IBUF_OP_COUNT];   /* = 各类型已合并操作数 */
  std::atomic<ulint> n_discarded_ops[IBUF_OP_COUNT]; /* = 因表删除而丢弃的操作数 */
};
```

全局单例：

```c
// ibuf0ibuf.cc:212
ibuf_t *ibuf = nullptr;
```

### 1.2 B-tree 物理布局

Change Buffer B-tree 存储在**系统表空间（space 0）**的两个固定页上：

```
FSP_IBUF_HEADER_PAGE_NO  = FSP_IBUF_HEADER_PAGE_NO   /* ibuf header 页 */
FSP_IBUF_TREE_ROOT_PAGE_NO = FSP_IBUF_TREE_ROOT_PAGE_NO /* ibuf B-tree 根页 */
```

B-tree 的每条记录对应一个对目标页的缓存操作，记录的排序键为 `(space_id, page_no, counter)`。

### 1.3 Bitmap 页

每个表空间每隔 `IBUF_BITMAP_INTERVAL`（默认 16384）页有一张 bitmap 页，用于跟踪每页的 buffering 状态。

对每页（在 bitmap 中占 4 个 bit）：

```c
// ibuf0ibuf.cc:246-255
constexpr uint32_t IBUF_BITMAP_FREE     = 0;  // [0:2)  空闲空间级别（0-3）
constexpr uint32_t IBUF_BITMAP_BUFFERED = 2;  // [2:3)  是否有缓存操作
constexpr uint32_t IBUF_BITMAP_IBUF     = 3;  // [3:4)  是否 ibuf 内部页
```

每页 4 bit，所以 bitmap 页的一条记录只需 1 字节（`8 pages / byte`）。

---

## 2. 初始化路径 — ibuf_init_at_db_start()

在 InnoDB 启动时调用（`ibuf0ibuf.cc:458`）：

```c
// ibuf0ibuf.cc:458-527
void ibuf_init_at_db_start(void) {
  page_t *root;
  mtr_t mtr;
  ulint n_used;
  page_t *header_page;

  // 分配 ibuf 控制结构
  ibuf = static_cast<ibuf_t *>(
      ut::zalloc_withkey(UT_NEW_THIS_FILE_PSI_KEY, sizeof(ibuf_t)));

  // 初始 max_size = Buffer Pool 页面数的 5%（默认值）
  ibuf->max_size = ((buf_pool_get_curr_size() / UNIV_PAGE_SIZE) *
                    CHANGE_BUFFER_DEFAULT_SIZE) / 100;

  // 创建三把互斥锁
  mutex_create(LATCH_ID_IBUF, &ibuf_mutex);
  mutex_create(LATCH_ID_IBUF_BITMAP, &ibuf_bitmap_mutex);
  mutex_create(LATCH_ID_IBUF_PESSIMISTIC_INSERT, &ibuf_pessimistic_insert_mutex);

  mtr_start(&mtr);
  mtr_x_lock_space(fil_space_get_sys_space(), &mtr);
  mutex_enter(&ibuf_mutex);

  // 读取 ibuf header 页，查询 file segment 已用页数
  header_page = ibuf_header_page_get(&mtr);
  fseg_n_reserved_pages(header_page + IBUF_HEADER + IBUF_TREE_SEG_HEADER,
                        &n_used, &mtr);

  ibuf_enter(&mtr);
  ut_ad(n_used >= 2);
  ibuf->seg_size = n_used;

  // 读取 B-tree 根页，更新 size
  {
    buf_block_t *block;
    block = buf_page_get(page_id_t(IBUF_SPACE_ID, FSP_IBUF_TREE_ROOT_PAGE_NO),
                         univ_page_size, RW_X_LATCH, UT_LOCATION_HERE, &mtr);
    buf_block_dbg_add_level(block, SYNC_IBUF_TREE_NODE);
    root = buf_block_get_frame(block);
  }

  ibuf_size_update(root);
  mutex_exit(&ibuf_mutex);

  // 检查 B-tree 是否为空
  ibuf->empty = page_is_empty(root);
  ibuf_mtr_commit(&mtr);

  // 构造一个伪 dict_index_t 供内部 B-tree 操作使用
  ibuf->index =
      dict_mem_index_create("innodb_change_buffer", "CLUST_IND",
                            IBUF_SPACE_ID, DICT_CLUSTERED | DICT_IBUF, 1);
  ibuf->index->id = DICT_IBUF_ID_MIN + IBUF_SPACE_ID;
  ibuf->index->table = dict_mem_table_create("innodb_change_buffer",
                                             IBUF_SPACE_ID, 1, 0, 0, 0, 0);
  ibuf->index->n_uniq = REC_MAX_N_FIELDS;
  rw_lock_create(index_tree_rw_lock_key, &ibuf->index->lock,
                 LATCH_ID_IBUF_INDEX_TREE);
  ibuf->index->search_info = btr_search_info_create(ibuf->index->heap);
  ibuf->index->page = FSP_IBUF_TREE_ROOT_PAGE_NO;
  ut_d(ibuf->index->cached = true);
}
```

关键点：

- **`CHANGE_BUFFER_DEFAULT_SIZE = 5`**：默认 ibuf 最大大小是 BP 的 5%
- **伪 `dict_index_t`**：ibuf B-tree 走的是常规的 `btr_` 接口，因此需要一个 `dict_index_t` 对象来描述 schema。这个对象并非从数据字典读取，而是运行时构造的
- **三把互斥锁**：`ibuf_mutex` 保护 size/max_size 等元数据；`ibuf_bitmap_mutex` 保护 bitmap 页；`ibuf_pessimistic_insert_mutex` 保护悲观插入

---

## 3. 写入缓存路径 — ibuf_insert()

当 `btr_cur_ins_lock_and_rec()` 执行二级索引插入时，如果目标页不在 BP 中，会调用 `ibuf_insert()` 尝试缓存（`ibuf0ibuf.cc:3284`）。

### 3.1 入口检查

```c
// ibuf0ibuf.cc:3284-3353
bool ibuf_insert(ibuf_op_t op, const dtuple_t *entry, dict_index_t *index,
                 const page_id_t &page_id, const page_size_t &page_size,
                 que_thr_t *thr) {
  dberr_t err;
  ulint entry_size;
  ibuf_use_t use = static_cast<ibuf_use_t>(innodb_change_buffering);

  ut_a(!index->is_clustered());

  // 步骤 1：根据 op 和 use 判断此操作能否缓存
  switch (op) {
    case IBUF_OP_INSERT:
      switch (use) {
        case IBUF_USE_NONE:
        case IBUF_USE_DELETE:
        case IBUF_USE_DELETE_MARK:
          return false;  // 不允许缓存 INSERT
        // ...
      }
    // ...（DELETE_MARK 和 DELETE 类似）
  }
```

### 3.2 Buffer Pool Watch 冲突检查

```c
  // ibuf0ibuf.cc:3355-3375 — 步骤 2：Buffer Pool Watch
check_watch:
  {
    buf_pool_t *buf_pool = buf_pool_get(page_id);
    buf_page_t *bpage = buf_page_get_also_watch(buf_pool, page_id);

    if (bpage != nullptr) {
      // 页已经被读入 BP 或有 purge watch 设置 → 不缓存
      return false;
    }
  }
```

**Buffer Pool Watch** 是一个重要的同步机制：当 purge 要清理某页上的记录时，它会设置一个"哨兵"（watch），阻止该页的新操作被缓存。这避免了以下竞争：

```
Thread A: INSERT → 缓存到 ibuf
Thread B: PURGE → 删除同一行 → 也缓存到 ibuf
                     ↓
Page 读入后: INSERT 被应用（行存在）
            PURGE 也被应用（行被删除）
                     ↓
            行丢失！
```

Watch 机制确保正在被 purge 扫描的页上不会再接受新的 ibuf 缓存。

### 3.3 记录大小检查

```c
  // ibuf0ibuf.cc:3377-3381 — 步骤 3：记录不能太大
skip_watch:
  entry_size = rec_get_converted_size(index, entry);

  if (entry_size >=
      page_get_free_space_of_empty(dict_table_is_comp(index->table)) / 2) {
    return false;  // 超过空页一半大小 → 不缓存
  }
```

如果记录太大（超过一个空页的一半），直接在原页上写入更经济。

### 3.4 插入到 ibuf B-tree

```c
  // ibuf0ibuf.cc:3383-3402 — 步骤 4：插入 ibuf B-tree
  err = ibuf_insert_low(BTR_MODIFY_PREV, op, no_counter, entry, entry_size,
                        index, page_id, page_size, thr);
  if (err == DB_FAIL) {
    // 乐观插入失败（页满），重试悲观插入
    err =
        ibuf_insert_low(BTR_MODIFY_TREE | BTR_LATCH_FOR_INSERT, op, no_counter,
                        entry, entry_size, index, page_id, page_size, thr);
  }

  if (err == DB_SUCCESS) {
    // 插入成功 → 在 bitmap 中标记 IBUF_BITMAP_BUFFERED
    ibuf_set_bitmap_for_page(page_id, page_size, thr, false);
    // 如果 ibuf 太大，触发收缩
    ibuf_contract_after_insert(entry_size);
    return true;
  }

  return false;
}
```

**调用链总结**：

```
ibuf_insert()                    ← 入口
  └─ buf_page_get_also_watch()   ← 检查 watch 冲突
  └─ ibuf_insert_low()           ← 插入 ibuf B-tree
      ├─ 乐观: BTR_MODIFY_PREV   ← 期望页够用
      └─ 悲观: BTR_MODIFY_TREE   ← 页不够用，分裂/分配
  └─ ibuf_set_bitmap_for_page()  ← 更新 bitmap
  └─ ibuf_contract_after_insert()← 检查是否需要收缩
```

---

## 4. Merge 路径

Merge 是将 Change Buffer 中的缓存操作"回放"到目标二级索引页上的过程。

### 4.1 触发 Merge 的三种场景

1. **目标页被读入 BP 时** — 最核心的触发点
2. **后台线程定期收缩** — `ibuf_merge_in_background()`
3. **插入后 ibuf 过大** — `ibuf_contract_after_insert()`

### 4.2 页面调入触发 Merge

当 `buf_read_page_low()` 读取一个二级索引页时，最终会调用 `ibuf_merge_or_delete_for_page()`（`ibuf0ibuf.cc:3962`）：

```c
// ibuf0ibuf.cc:3962-4062
void ibuf_merge_or_delete_for_page(buf_block_t *block, const page_id_t &page_id,
                                   const page_size_t *page_size,
                                   bool update_ibuf_bitmap) {
  // 步骤 1：快速路径 — 检查 bitmap 是否有缓存
  if (update_ibuf_bitmap) {
    space = fil_space_acquire_silent(page_id.space());
    // ...
    bitmap_bits = ibuf_bitmap_page_get_bits(bitmap_page, page_id, *page_size,
                                            IBUF_BITMAP_BUFFERED, &mtr);
    if (!bitmap_bits) {
      fil_space_release(space);
      return;  // 无缓存 → 直接返回
    }
  }

  // 步骤 2：在 ibuf B-tree 中定位所有匹配记录
  heap = mem_heap_create(512, UT_LOCATION_HERE);
  search_tuple = ibuf_search_tuple_build(page_id.space(), page_id.page_no(), heap);

  // 步骤 3：遍历所有匹配记录，应用到目标页
  pcur.open(ibuf->index, 0, search_tuple, PAGE_CUR_GE,
            BTR_SEARCH_LEAF, &mtr, UT_LOCATION_HERE);

  while (rec = pcur.get_rec(),
         !page_rec_is_infimum(rec) &&
         ibuf_rec_get_space(&mtr, rec) == page_id.space() &&
         ibuf_rec_get_page_no(&mtr, rec) == page_id.page_no()) {

    // 应用操作到目标页（INSERT / DELETE_MARK / DELETE）
    btr_cur_t btr_cursor;
    btr_pcur_t btr_pcur;
    // ...在目标索引上定位位置，执行对应操作
    // 更新统计计数
    mops[op]++;

    pcur.move_to_next(&mtr);
  }
```

**完整调用链**：

```
buf_read_page_low()                          ← 发起 I/O
  └─ 读取完成后
  └─ buf_page_io_complete()
      └─ ibuf_merge_or_delete_for_page()     ← 合并/清理 ibuf 记录
```

### 4.3 后台 Merge — ibuf_merge_in_background()

后台线程（`srv_master_thread` 或 `srv_purge_coordinator_thread`）定期调用 `ibuf_merge_in_background()`（`ibuf0ibuf.cc:2399`）：

```c
// ibuf0ibuf.cc:2399-2460
ulint ibuf_merge_in_background(bool full) {
  ulint sum_bytes = 0;
  ulint sum_pages = 0;
  ulint n_pages;

  if (full) {
    n_pages = PCT_IO(100);  // 完全合并：100% IO capacity
  } else {
    n_pages = PCT_IO(5);    // 默认：5% IO capacity

    mutex_enter(&ibuf_mutex);
    // 如果 ibuf->size > max_size/2，增加合并力度
    if (ibuf->size > ibuf->max_size / 2) {
      ulint diff = ibuf->size - ibuf->max_size / 2;
      diff = std::min(diff, ibuf->max_size);
      n_pages += PCT_IO((diff * 100) / (ibuf->max_size + 1));
    }
    mutex_exit(&ibuf_mutex);
  }

  while (sum_pages < n_pages) {
    ulint n_bytes = ibuf_merge(&n_pag2, false);
    if (n_bytes == 0) return (sum_bytes);
    sum_bytes += n_bytes;
    sum_pages += n_pag2;
  }

  return (sum_bytes);
}
```

**ibuf_merge()** → **ibuf_merge_pages()** 的核心逻辑：

```c
// ibuf0ibuf.cc:2232-2291
static ulint ibuf_merge_pages(ulint *n_pages, bool sync) {
  // 步骤 1：在 ibuf B-tree 上随机打开一个 cursor
  ibuf_mtr_start(&mtr);
  pcur.set_random_position(ibuf->index, BTR_SEARCH_LEAF, &mtr, UT_LOCATION_HERE);

  // 步骤 2：收集要合并的 pages（至多 IBUF_MAX_N_PAGES_MERGED 个）
  sum_sizes = ibuf_get_merge_page_nos(true, pcur.get_rec(), &mtr,
                                      space_ids, page_nos, n_pages);
  ibuf_mtr_commit(&mtr);
  pcur.close();

  // 步骤 3：发起批量异步读取 → 读入时会自动触发 ibuf_merge_or_delete_for_page
  buf_read_ibuf_merge_pages(sync, space_ids, page_nos, *n_pages);

  return (sum_sizes + 1);
}
```

**随机选择 + 批量读**的设计意图：

- 随机选择 B-tree 叶子节点，避免反复合并同一页
- 批量读入多个目标页（`buf_read_ibuf_merge_pages`），合并效率高
- 读入时触发 `ibuf_merge_or_delete_for_page` → 合并自然发生

### 4.4 插入后收缩 — ibuf_contract_after_insert()

每次成功插入 ibuf 后调用：

```c
// ibuf0ibuf.cc:2472-2495
static inline void ibuf_contract_after_insert(ulint entry_size) {
  // 脏读 ibuf->size 和 ibuf->max_size（减少互斥锁竞争）
  auto size = ibuf->size;
  auto max_size = ibuf->max_size;

  if (size < max_size + IBUF_CONTRACT_ON_INSERT_NON_SYNC) {
    return;  // 未超过阈值，不做收缩
  }

  auto sync = (size >= max_size + IBUF_CONTRACT_ON_INSERT_SYNC);

  ulint sum_sizes = 0;
  size = 1;
  do {
    size = ibuf_contract(sync);
    sum_sizes += size;
  } while (size > 0 && sum_sizes < entry_size);
}
```

两个阈值：

- `IBUF_CONTRACT_ON_INSERT_NON_SYNC`：超过 `max_size` 这个量后开始异步收缩
- `IBUF_CONTRACT_ON_INSERT_SYNC`：超过 `max_size` 更多后开始同步收缩（等待 I/O 完成）

---

## 5. 三层页面访问规则

为了避免 ibuf 系统中的死锁，InnoDB 定义了严格的三层页面访问顺序（`ibuf0ibuf.cc:186-207`）：

```
Level 1: 非 ibuf 页（普通数据/索引页）
Level 2: ibuf B-tree 页 + ibuf free list 页
Level 3: ibuf bitmap 页
```

**规则**：持有低级页（level N）的 latch 时，不得访问更高级页（level > N）。

```
✅ 允许: Level 2 → Level 1 (ibuf 合并时读目标页)
❌ 禁止: Level 1 → Level 2 (普通操作试图读 ibuf 页)
❌ 禁止: Level 1/2 → Level 3 (试图读 bitmap 页)
```

**例外**：同步 I/O 的线程可以访问任何级别，因为不涉及跨线程的锁依赖。

---

## 6. Bitmap 操作

### 6.1 bitmap 页初始化

```c
// ibuf0ibuf.cc:536-557
void ibuf_bitmap_page_init(buf_block_t *block, mtr_t *mtr) {
  page_t *page = buf_block_get_frame(block);
  fil_page_set_type(page, FIL_PAGE_IBUF_BITMAP);

  // 清零所有 bitmap 位
  byte_offset = UT_BITS_IN_BYTES(block->page.size.physical() * IBUF_BITS_PER_PAGE);
  memset(page + IBUF_BITMAP, 0, byte_offset);
}
```

### 6.2 设置 buffered bit

```c
// ibuf0ibuf.cc:3484 (ibuf_set_bitmap_for_page, 简化)
// 在成功缓存后标记 IBUF_BITMAP_BUFFERED
ibuf_set_bitmap_for_page(page_id, page_size, thr, false);
```

### 6.3 检查是否有缓存

```c
// ibuf0ibuf.ic 中的 inline 函数获取 bitmap bits
bitmap_bits = ibuf_bitmap_page_get_bits(bitmap_page, page_id, *page_size,
                                        IBUF_BITMAP_BUFFERED, &mtr);
```

---

## 7. ibuf_should_try() — 能否尝试缓存

`ibuf_should_try()` 是一个前置检查，在真正的插入路径之前判断是否值得尝试 ibuf（`ibuf0ibuf.ic:92`）：

```c
// ibuf0ibuf.ic:92-99
static inline bool ibuf_should_try(dict_index_t *index, ulint ignore_sec_unique) {
  return (innodb_change_buffering != IBUF_USE_NONE
          && ibuf->max_size != 0
          && index->space != dict_sys_t::s_dict_space_id
          && !index->is_clustered()
          && !dict_index_is_spatial(index)
          && !dict_index_has_desc(index)
          && index->table->quiesce == QUIESCE_NONE
          && (ignore_sec_unique || !dict_index_is_unique(index))
          && srv_force_recovery < SRV_FORCE_NO_IBUF_MERGE);
}
```

所有条件**必须全部满足**才能尝试使用 Change Buffer。这个检查在 `btr_cur_ins_lock_and_rec()` 和 `row_ins_sec_index_entry()` 等调用链中被调用。

---

## 8. 配置与统计

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `innodb_change_buffering` | `all` | 控制可缓存操作类型 |
| `innodb_change_buffer_max_size` | `25` | ibuf 最大大小占 BP 的百分比 |
| `ibuf->max_size` | 启动时 5% | 启动时初始值，之后被 `innodb_change_buffer_max_size` 覆盖 |

`ibuf_max_size_update()`（`ibuf0ibuf.cc:531`）用于运行时更新：

```c
void ibuf_max_size_update(ulint new_val) {
  ulint new_size = ((buf_pool_get_curr_size() / UNIV_PAGE_SIZE) * new_val) / 100;
  mutex_enter(&ibuf_mutex);
  ibuf->max_size = new_size;
  mutex_exit(&ibuf_mutex);
}
```

可以通过 `SHOW ENGINE INNODB STATUS` 查看 Change Buffer 统计：

```
-------------------------------------
INSERT BUFFER AND ADAPTIVE HASH INDEX
-------------------------------------
Ibuf: size 1, free list len 0, seg size 2,
0 merges
merged operations:
 insert 0, delete mark 0, delete 0
discarded operations:
 insert 0, delete mark 0, delete 0
```

---

## 9. 调用链总结

```
INSERT 写入二级索引
  └─ ibuf_should_try()                     ← 前置检查
  └─ ibuf_insert()                         ← 尝试缓存
      ├─ IBUF_OP_INSERT/DELETE_MARK/DELETE ← 操作类型
      ├─ buf_page_get_also_watch()         ← watch 冲突检测
      ├─ ibuf_insert_low()                 ← 插入 ibuf B-tree
      │   ├─ 乐观插入 (BTR_MODIFY_PREV)
      │   └─ 悲观插入 (BTR_MODIFY_TREE)    ← 页分裂
      ├─ ibuf_set_bitmap_for_page()        ← 标记 bitmap
      └─ ibuf_contract_after_insert()      ← 检查是否需收缩

MERGE 触发时机
  ├─ 页面调入: ibuf_merge_or_delete_for_page()
  │   └─ 定位 ibuf 记录 → 逐个应用到目标页
  ├─ 后台线程: ibuf_merge_in_background()
  │   └─ ibuf_merge() → ibuf_merge_pages()
  │       └─ 随机 cursor → 收集 pages → buf_read_ibuf_merge_pages()
  └─ ibuf 过大: ibuf_contract_after_insert()
      └─ ibuf_contract() → ibuf_merge_pages()
```

## 10. 注意事项

1. **Bitmap 是唯一的"是否有缓存"线索**：Merge 时优先检查 bitmap。如果 bitmap 显示没有缓存，直接跳过 ibuf B-tree 查找
2. **Change Buffer 自身也是 B-tree**：内部使用普通 `btr_` 接口，通过伪 `dict_index_t` 描述 schema
3. **MTR（Mini-Transaction）嵌套**：ibuf 操作通常在一个独立的 MTR 中完成，以避免影响主操作的 MTR
4. **速度上限**：ibuf 的最大合并速度受 `innodb_io_capacity` 和 `innodb_io_capacity_max` 控制（由 `PCT_IO()` 宏换算）

---

## 源码索引

| 函数/结构 | 文件 | 行号 |
|-----------|------|------|
| `ibuf_t` struct | `ibuf0ibuf.ic` | 62 |
| `ibuf_should_try()` | `ibuf0ibuf.ic` | 92 |
| `ibuf_op_t / ibuf_use_t` | `ibuf0ibuf.h` | 36-56 |
| `IBUF_BITMAP_*` 常量 | `ibuf0ibuf.cc` | 246-255 |
| `ibuf_init_at_db_start()` | `ibuf0ibuf.cc` | 458 |
| `ibuf_max_size_update()` | `ibuf0ibuf.cc` | 531 |
| `ibuf_bitmap_page_init()` | `ibuf0ibuf.cc` | 536 |
| `ibuf_merge_pages()` | `ibuf0ibuf.cc` | 2232 |
| `ibuf_get_merge_pages()` | `ibuf0ibuf.cc` | 2194 |
| `ibuf_merge_space()` | `ibuf0ibuf.cc` | 2297 |
| `ibuf_merge()` | `ibuf0ibuf.cc` | 2377 |
| `ibuf_contract()` | `ibuf0ibuf.cc` | 2386 |
| `ibuf_merge_in_background()` | `ibuf0ibuf.cc` | 2399 |
| `ibuf_contract_after_insert()` | `ibuf0ibuf.cc` | 2472 |
| `ibuf_insert()` | `ibuf0ibuf.cc` | 3284 |
| `ibuf_merge_or_delete_for_page()` | `ibuf0ibuf.cc` | 3962 |
| `buf_read_ibuf_merge_pages()` | `buf0rea.cc` | 588 |
