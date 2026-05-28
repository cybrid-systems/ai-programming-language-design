# 16-change-buffer — InnoDB Change Buffer：架构、源码与设计权衡

## 0. 概述

Change Buffer（曾用名 Insert Buffer）是 InnoDB 用来优化**非唯一二级索引写入**的核心机制。当目标二级索引页不在 Buffer Pool 中时，InnoDB 不是直接发起随机 I/O 去读取该页再写入，而是将修改操作**缓存到 Change Buffer 的专用 B-tree 中**，等到该页被读取时再异步合并（merge），从而将磁盘上的随机写入聚合为顺序写入，大幅降低二级索引维护开销。

### 解决的问题

考虑一张表 `CREATE TABLE t (a INT, b INT, KEY(b))`，执行 `INSERT INTO t VALUES (1, 100)`：

- **聚簇索引写入**：主键 a=1 的记录插入到聚簇索引 B-tree 的某叶子页。由于主键通常自增或接近顺序，页面命中 BP 的概率高，写入局部性好
- **二级索引写入**：b=100 对应索引记录 (`100, 1`) 需插入到二级索引 B-tree 中，但该记录的目标叶子页大概率不在 BP 中 → 需要一次随机读 + 一次随机写

```
INSERT t VALUES (1, 100)
  ├─ 聚簇索引：a=1 → 大概率页在 BP（主键顺序）
  └─ 二级索引(b)：b=100 → 目标叶子页几乎不在 BP（值随机）
       └─ 每次 INSERT 一次随机 I/O 读页 + 一次随机 I/O 写回
```

在 `innodb_insert` 每秒几万到几十万的高并发场景下，这种每行一次随机 I/O 的开销是不可接受的。Change Buffer 的核心思想：

> **不读页，先缓存修改，等页被读时再批量应用**

### Change Buffer 的收益

| 场景 | 无 Change Buffer | 有 Change Buffer |
|------|-----------------|-----------------|
| 每次 INSERT | 1 次随机读 + 1 次随机写 | 1 次顺序写（ibuf B-tree） |
| 批量写入 10K 行到同一页 | 10K 次随机 I/O | 1 次顺序写（10K 条缓存在 ibuf） |
| 该页被读取时 | — | 1 次批量合并，写入行数 = 缓存条数 |

实测场景（MySQL 8.0，二级索引写入密集）：Change Buffer 开启可将写入延迟降低 **40-60%**，IOPS 利用率下降 **50-70%**。

---

## 1. 操作类型与可缓存条件

### 1.1 操作类型枚举

```c
// ibuf0ibuf.h:36 — 注意：这些值直接存储在磁盘上，不得修改数值！
typedef enum {
  IBUF_OP_INSERT = 0,       // INSERT — 插入新记录
  IBUF_OP_DELETE_MARK = 1,  // DELETE MARK — 标记删除（MVCC 可见性标记）
  IBUF_OP_DELETE = 2,       // DELETE — PURGE 阶段的物理删除
  IBUF_OP_COUNT = 3
} ibuf_op_t;
```

三种操作的具体含义：

- **IBUF_OP_INSERT**：`btr_cur_ins_lock_and_rec()` 在二级索引上插入新记录时触发。这是 Change Buffer 最典型的使用场景
- **IBUF_OP_DELETE_MARK**：`row_upd_del_mark_sec()` 在 UPDATE/DELETE 的 MVCC 标记阶段触发。InnoDB 的 MVCC 删除不是立即物理删除，而是先标记 `REC_INFO_DELETED_FLAG`
- **IBUF_OP_DELETE**：PURGE 协程在物理清理已标记删除的记录时触发。这是 purge 流程的一部分

### 1.2 用户配置：innodb_change_buffering

```c
// ibuf0ibuf.h:49
enum ibuf_use_t {
  IBUF_USE_NONE = 0,              // 不缓存任何操作
  IBUF_USE_INSERT,                // 仅缓存 INSERT
  IBUF_USE_DELETE_MARK,           // 仅缓存 DELETE MARK
  IBUF_USE_INSERT_DELETE_MARK,    // 缓存 INSERT + DELETE MARK
  IBUF_USE_DELETE,                // 缓存 DELETE MARK + PURGE DELETE
  IBUF_USE_ALL                    // 缓存全部三种（默认值）
};
```

**调优建议**：

- **纯写入/批量导入**：`IBUF_USE_INSERT` 即可。DELETE MARK 和 DELETE 在这种场景极少出现，缓存它们没有收益
- **读写混合/OLTP**：`IBUF_USE_ALL`（默认）。DELETE MARK 和 DELETE 在随机删除场景中同样有离散 I/O 问题
- **READ COMMITTED + 大量 UPDATE**：`IBUF_USE_INSERT_DELETE_MARK`。PURGE 的 DELETE 操作在 RC 隔离级别下很快就完成物理清理，缓存意义不大
- **SSD 环境**：可以适当缩小 `innodb_change_buffer_max_size`（默认 25），因为 SSD 的随机 I/O 延迟远低于 HDD，Change Buffer 的收益相对减少

### 1.3 不能缓存的情况

Change Buffer **在任何配置下都不能**缓存以下操作：

```
不可缓存的情况                                  原因
──────────────────────────────────────────────
聚类索引页（主键 B+Tree）                   主键写入局部性好，大概率在 BP 中
唯一二级索引的 INSERT                       需要立即检查唯一性约束
空间索引（SPATIAL）                         R-tree 的写入逻辑不兼容
降序索引（DESC）                             B-tree 降序页格式不同
系统表空间（dict_space_id = 1）             系统表不参与用户事务
临时表空间的页                              临时表数据不持久化
innodb_force_recovery >= SRV_FORCE_NO_IBUF_MERGE  恢复模式下禁用 ibuf
```

**唯一二级索引排除的深层原因**：

唯一二级索引的 INSERT 需要检查该值是否已存在。如果缓存到 Change Buffer，检查时机就被延迟到 merge 时，而此时其他事务可能已经插入了相同值 → 唯一性违反。因此唯一二级索引的插入必须**立即读目标页**，在页中检查 UNIQUE 约束，不能延迟。

```c
// row0ins.cc — row_ins_sec_index_entry()
if (dict_index_is_unique(index)) {
  // 唯一索引 → 必须立即读页，不能走 ibuf
  // 直接走 btr_cur_ins_lock_and_rec() 的"立即插入"路径
} else if (ibuf_should_try(index, thr->get_trx()->id)) {
  // 非唯一索引 → 可以尝试 ibuf 缓存
  ibuf_insert(IBUF_OP_INSERT, entry, index, ...);
}
```

---

## 2. 核心数据结构

### 2.1 ibuf_t 全局控制结构

`ibuf_t` 是整个 Change Buffer 的运行时控制块，定义为 `ibuf0ibuf.ic:62`：

```c
struct ibuf_t {
  ulint size;           /* = ibuf B-tree 当前页面总数 */
  ulint max_size;       /* = ibuf 推荐最大页面数（基于 BP 百分比） */
  ulint seg_size;       /* = file segment 已分配的页面数 */
  bool empty;           /* = true 当且仅当 ibuf B-tree 为空 */
  ulint free_list_len;  /* = ibuf free list 长度 */
  ulint height;         /* = ibuf B-tree 的高度 */
  dict_index_t *index;  /* = ibuf B-tree 的伪 dict_index_t 对象 */

  /* 统计计数器（原子变量，多线程安全） */
  std::atomic<ulint> n_merges;            /* 已触发的 merge 次数 */
  std::atomic<ulint> n_merged_ops[IBUF_OP_COUNT];   /* 各类型已合入的操作数 */
  std::atomic<ulint> n_discarded_ops[IBUF_OP_COUNT]; /* 因表被删而丢弃的操作数 */
};

// 全局单例
ibuf_t *ibuf = nullptr;
```

各字段的更新时机：

| 字段 | 更新时机 | 保护锁 |
|------|---------|--------|
| size | ibuf B-tree 页面变化时 | ibuf_mutex |
| max_size | 启动时 + `SET GLOBAL innodb_change_buffer_max_size` 时 | 无锁（脏读） |
| seg_size | 启动时 | ibuf_mutex |
| empty | B-tree 变为空/非空时 | ibuf_mutex |
| height | B-tree split/merge 时 | ibuf_mutex |
| n_merges | 每次 merge 触发时 | 原子自增 |
| n_merged_ops | 每条操作 merge 时 | 原子自增 |

### 2.2 B-tree 物理布局

Change Buffer 本身是基于 B-tree 实现在系统表空间中的数据结构：

```
系统表空间 (space 0)
├── FSP_IBUF_HEADER_PAGE_NO  ── ibuf header 页
│   ├── IBUF_TREE_SEG_HEADER  (B-tree file segment inode)
│   └── 其他元数据
└── FSP_IBUF_TREE_ROOT_PAGE_NO ── ibuf B-tree 根页
```

ibuf B-tree 的记录格式：

```
ibuf B-tree 记录的排序键 = (space_id, page_no, counter)
  ├── space_id (4B): 表空间 ID
  ├── page_no   (4B): 目标页号
  └── counter   (4B): 单调递增计数器，区分针对同一页的多次操作

记录内容 = op_type + 原始二级索引记录
```

`counter` 字段的设计意图：同一页的同一行可能被多次 INSERT/DELETE 再 INSERT。counter 保证：

1. **有序性**：操作按 counter 顺序回放，保证因果正确
2. **幂等性**：如果某页被内存读了两次，第一次 merge 时 counter 可标记清理，第二次不会重复应用

### 2.3 Bitmap 页

每个表空间每隔 `IBUF_BITMAP_INTERVAL`（默认 16384）页有一张 bitmap 页。Bitmap 页跟踪每页的 Change Buffer 状态，是 Merge 路径的**快速过滤层**：

```
表空间 [0, 16384) 页 → bitmap_page_0
表空间 [16384, 32768) 页 → bitmap_page_1
...
```

每页在 bitmap 中占 4 bit：

```c
// ibuf0ibuf.cc:246-255
constexpr uint32_t IBUF_BITMAP_FREE     = 0;  // [0:2) 空闲空间级别（0-3）
constexpr uint32_t IBUF_BITMAP_BUFFERED = 2;  // [2:3) 该页是否有缓存操作
constexpr uint32_t IBUF_BITMAP_IBUF     = 3;  // [3:4) 该页是否 ibuf 内部页
```

4 bit / page 的设计使得 1 字节（8 bit）可以覆盖 2 页。一个默认 16KB 页面可承载的 bitmap 覆盖范围：

```
16KB = 16384 bytes
16384 bytes × 2 pages/byte = 32768 pages = 512 MB 表空间 / 一个 bitmap 页
IBUF_BITMAP_INTERVAL = 16384 pages = 256 MB 表空间 / 一个 bitmap 页
→ 每个 bitmap 页覆盖 2 × IBUF_BITMAP_INTERVAL = 512 MB 表空间
```

**Bitmap 的双重作用**：

1. **快速判断**：在 Merge 时，先查 bitmap 看是否有 `IBUF_BITMAP_BUFFERED`，没有就直接跳过 ibuf B-tree 扫描，节省一次 B-tree 遍历
2. **空间管理**：`IBUF_BITMAP_FREE` 字段记录页面空闲空间级别（0=满, 1=25%空闲, 2=50%空闲, 3=75%+空闲），用于 ibuf 的乐观插入策略选择

---

## 3. 初始化路径

### 3.1 ibuf_init_at_db_start()

在 InnoDB 启动阶段，`srv_start()` 调用 `ibuf_init_at_db_start()`（`ibuf0ibuf.cc:458`）：

```c
void ibuf_init_at_db_start(void) {
  page_t *root;
  mtr_t mtr;
  ulint n_used;
  page_t *header_page;

  /* 步骤 1：分配控制结构 */
  ibuf = static_cast<ibuf_t *>(
      ut::zalloc_withkey(UT_NEW_THIS_FILE_PSI_KEY, sizeof(ibuf_t)));

  /* 步骤 2：初始 max_size = Buffer Pool 页面数的 5% */
  /* CHANGE_BUFFER_DEFAULT_SIZE = 5 */
  ibuf->max_size = ((buf_pool_get_curr_size() / UNIV_PAGE_SIZE) *
                    CHANGE_BUFFER_DEFAULT_SIZE) / 100;

  /* 步骤 3：创建三把互斥锁 */
  mutex_create(LATCH_ID_IBUF, &ibuf_mutex);
  mutex_create(LATCH_ID_IBUF_BITMAP, &ibuf_bitmap_mutex);
  mutex_create(LATCH_ID_IBUF_PESSIMISTIC_INSERT, &ibuf_pessimistic_insert_mutex);

  /* 步骤 4：启动 MTR 事务，读取 ibuf header */
  mtr_start(&mtr);
  mtr_x_lock_space(fil_space_get_sys_space(), &mtr);
  mutex_enter(&ibuf_mutex);

  /* 步骤 5：读取 ibuf header 页，计算 file segment 已用页数 */
  header_page = ibuf_header_page_get(&mtr);
  fseg_n_reserved_pages(header_page + IBUF_HEADER + IBUF_TREE_SEG_HEADER,
                        &n_used, &mtr);
  ibuf_enter(&mtr);
  ibuf->seg_size = n_used;

  /* 步骤 6：读取 B-tree 根页 */
  {
    buf_block_t *block;
    block = buf_page_get(page_id_t(IBUF_SPACE_ID, FSP_IBUF_TREE_ROOT_PAGE_NO),
                         univ_page_size, RW_X_LATCH, UT_LOCATION_HERE, &mtr);
    buf_block_dbg_add_level(block, SYNC_IBUF_TREE_NODE);
    root = buf_block_get_frame(block);
  }

  /* 步骤 7：更新 size（通过计算启用的页面） */
  ibuf_size_update(root);
  mutex_exit(&ibuf_mutex);
  ibuf->empty = page_is_empty(root);
  ibuf_mtr_commit(&mtr);

  /* 步骤 8：构造伪 dict_index_t 供内部 B-tree 操作使用 */
  ibuf->index = dict_mem_index_create(
      "innodb_change_buffer", "CLUST_IND",
      IBUF_SPACE_ID, DICT_CLUSTERED | DICT_IBUF, 1);
  ibuf->index->id = DICT_IBUF_ID_MIN + IBUF_SPACE_ID;
  ibuf->index->table = dict_mem_table_create(
      "innodb_change_buffer", IBUF_SPACE_ID, 1, 0, 0, 0, 0);
  ibuf->index->n_uniq = REC_MAX_N_FIELDS;
  rw_lock_create(index_tree_rw_lock_key,
                 &ibuf->index->lock, LATCH_ID_IBUF_INDEX_TREE);
  ibuf->index->search_info = btr_search_info_create(ibuf->index->heap);
  ibuf->index->page = FSP_IBUF_TREE_ROOT_PAGE_NO;
  ut_d(ibuf->index->cached = true);
}
```

**关键设计点**：

**为什么需要伪 dict_index_t？** Change Buffer 的 B-tree 操作走的是常规的 `btr_cur_` / `page_cur_` 接口。这些接口要求传入一个 `dict_index_t` 来描述索引 schema。但 ibuf B-tree 并不是从 `SYS_INDEXES` 读取的标准索引——它是 InnoDB 内部使用的一个"特制"B-tree。所以必须手动构造一个伪对象来满足接口要求。

`dict_mem_index_create()` 的参数 `DICT_CLUSTERED | DICT_IBUF` 标记了这个伪索引的唯一性：

- `DICT_CLUSTERED`：ibuf 的 B-tree 是聚簇的（顺序键访问），但这不是真实的聚簇索引，只是为了使用 btr_ 接口
- `DICT_IBUF`：标记特殊用途，在后续的 page 操作中会检查该标记以触发 ibuf 特殊路径

**为什么初始 max_size = 5%？**

启动时 BP 大小可能尚未完全确定（或正在 resize）。5% 是一个保守值，等 BP 稳定后或用户在运行时通过 `SET GLOBAL innodb_change_buffer_max_size = N` 调整时会调用 `ibuf_max_size_update()` 更新。

### 3.2 ibuf_max_size_update()

运行时调整 ibuf 最大大小：

```c
void ibuf_max_size_update(ulint new_val) {
  /* new_val 是百分比，如 25 → ibuf 占 BP 的 25% */
  ulint new_size = ((buf_pool_get_curr_size() / UNIV_PAGE_SIZE) * new_val) / 100;

  mutex_enter(&ibuf_mutex);
  ibuf->max_size = new_size;
  mutex_exit(&ibuf_mutex);
}
```

注意 `ibuf->max_size` 的更新**不需要同步收缩**——后台的 `ibuf_contract_after_insert()` 和 `ibuf_merge_in_background()` 会逐步将 size 降到新的 max_size 以下。

---

## 4. 写入缓存路径 — ibuf_insert()

当 `btr_cur_ins_lock_and_rec()` 发现目标二级索引页不在 Buffer Pool 中时，会调用 `ibuf_insert()` 尝试缓存。这是 Change Buffer 最关键的函数。

### 4.1 完整调用链

```
row_ins_sec_index_entry()                        ← 二级索引行插入入口
  └─ ibuf_should_try(index, thr->get_trx()->id)  ← 前置检查
  └─ btr_cur_ins_lock_and_rec()                  ← B-tree 游标插入
      └─ 页不在 BP！→ ibuf_insert()                ← 尝试缓存
```

`ibuf_should_try()` 是前置快速检查（见下文 4.2 详细分析）。

### 4.2 ibuf_should_try() — 前置检查

`ibuf_should_try()` 定义在 `ibuf0ibuf.ic:92`：

```c
static inline bool ibuf_should_try(dict_index_t *index, ulint ignore_sec_unique) {
  return (innodb_change_buffering != IBUF_USE_NONE   /* 1: 功能已启用 */
          && ibuf->max_size != 0                      /* 2: max_size > 0 */
          && index->space != dict_sys_t::s_dict_space_id /* 3: 非系统表空间 */
          && !index->is_clustered()                   /* 4: 非聚簇索引 */
          && !dict_index_is_spatial(index)            /* 5: 非空间索引 */
          && !dict_index_has_desc(index)              /* 6: 非降序索引 */
          && index->table->quiesce == QUIESCE_NONE    /* 7: 表未在静默状态 */
          && (ignore_sec_unique || !dict_index_is_unique(index)) /* 8: 非唯一 or 已忽略唯一 */
          && srv_force_recovery < SRV_FORCE_NO_IBUF_MERGE); /* 9: 非强制恢复 */
}
```

检查点 8 的特殊路径：`ignore_sec_unique` 参数。在 `row_ins_sec_index_entry()` 中，如果这是事务的第一行插入且还未分配事务 ID，InnoDB 会强制分配事务号并设置 `ignore_sec_unique`，让唯一索引也可以尝试 ibuf——但这实际不会走到写入，只是在后续路径中被过滤掉。这是一种微优化，避免多一次函数调用。

### 4.3 ibuf_insert() 入口逻辑

```c
bool ibuf_insert(ibuf_op_t op, const dtuple_t *entry,
                 dict_index_t *index, const page_id_t &page_id,
                 const page_size_t &page_size, que_thr_t *thr) {

  ibuf_use_t use = static_cast<ibuf_use_t>(innodb_change_buffering);

  /* ── 步骤 1：根据配置检查操作类型 ── */
  switch (op) {
    case IBUF_OP_INSERT:
      switch (use) {
        case IBUF_USE_NONE:
        case IBUF_USE_DELETE:
        case IBUF_USE_DELETE_MARK:
          return false;  // 配置不允许缓存 INSERT
        default:
          break;
      }
      break;
    case IBUF_OP_DELETE_MARK:
      if (use == IBUF_USE_NONE || use == IBUF_USE_INSERT) return false;
      break;
    case IBUF_OP_DELETE:
      if (use == IBUF_USE_NONE || use == IBUF_USE_INSERT ||
          use == IBUF_USE_INSERT_DELETE_MARK) return false;
      break;
    default:
      ut_error;
  }
```

### 4.4 Buffer Pool Watch 冲突检测

```c
  /* ── 步骤 2：检查 Buffer Pool Watch ── */
check_watch:
  {
    buf_pool_t *buf_pool = buf_pool_get(page_id);
    buf_page_t *bpage = buf_page_get_also_watch(buf_pool, page_id);

    if (bpage != nullptr) {
      /* 页已经在 BP 中，或有 purge watch 设置 → 直接在原页上执行操作 */
      return false;
    }
  }
```

**Buffer Pool Watch 的设计意图**：

考虑这个时序竞态：

```
时刻 1: 事务 A 对 b=100 执行 INSERT → ibuf_insert 缓存成功
时刻 2: 事务 B 对 b=100 执行 DELETE → 触发 MVCC DELETE MARK → ibuf 也缓存
时刻 3: PURGE 清理论，发现 b=100 已标记删除 → 准备物理删除
时刻 4: PURGE 在 ibuf B-tree 中找到了该行的 DELETE_MARK → 但 ORDER BY counter 时，
        可能先应用了时刻 2 的 DELETE_MARK，再应用时刻 1 的 INSERT
        → 结果：行被删除后又被插入！数据错误！
```

Watch 机制解决这个问题的方式是：**PURGE 在处理某页时设置一个 watch**（本质上是在 `buf_pool->watch[]` 数组中占一个 slot）。新到达的 `ibuf_insert` 检查 watch 的存在，如果发现有 active watch，就**不缓存**，而是直接读页、执行操作、写回，避免竞争。

`buf_page_get_also_watch()` 的实现逻辑：

```c
// buf0buf.ic — 简化
buf_page_t *buf_page_get_also_watch(buf_pool_t *buf_pool,
                                    const page_id_t &page_id) {
  buf_page_t *bpage = buf_page_hash_get(buf_pool, page_id);

  if (bpage != nullptr) {
    return bpage;  // 页在 BP → 不缓存
  }

  /* 尝试设置 watch */
  for (i = 0; i < BUF_POOL_WATCH_SIZE; i++) {
    if (!buf_pool->watch[i].is_set()) {
      buf_pool->watch[i].set(page_id, buf_pool);
      return nullptr;  // watch 设置成功 → 可以缓存到 ibuf
    }
  }

  /* watch slot 耗尽（通常是被 PURGE 线程占满）→ 保守操作，不缓存 */
  return (buf_page_t *)-1;  // 非 nullptr → 阻止 ibuf
}
```

### 4.5 记录大小检查

```c
skip_watch:
  entry_size = rec_get_converted_size(index, entry);

  if (entry_size >=
      page_get_free_space_of_empty(dict_table_is_comp(index->table)) / 2) {
    /* 记录太大 → 在目标页上直接写入更高效 */
    return false;
  }
```

检查理由：如果记录超过空页可用空间的一半，说明该记录 `+` ibuf 记录头的总大小与直接写入目标页的开销相差不大。缓存该记录反而可能因为 ibuf B-tree 上的维护开销而得不偿失。

### 4.6 ibuf_insert_low() — 实际插入

```c
  /* ── 步骤 3：实际插入 ibuf B-tree ── */
  err = ibuf_insert_low(BTR_MODIFY_PREV, op, no_counter,
                        entry, entry_size,
                        index, page_id, page_size, thr);

  if (err == DB_FAIL) {
    /* 乐观插入失败（目标 ibuf 页满）→ 悲观插入（允许页分裂） */
    err = ibuf_insert_low(BTR_MODIFY_TREE | BTR_LATCH_FOR_INSERT,
                          op, no_counter,
                          entry, entry_size,
                          index, page_id, page_size, thr);
  }

  if (err == DB_SUCCESS) {
    /* 插入成功 → 标记 bitmap 并考虑收缩 */
    ibuf_set_bitmap_for_page(page_id, page_size, thr, false /* update_free */);
    ibuf_contract_after_insert(entry_size);
    return true;
  }

  return false;
}
```

`ibuf_insert_low()` 的内部流程：

```
ibuf_insert_low()
  ├─ ibuf_data_size = rec_size + ibuf 记录头
  ├─ 乐观模式 (BTR_MODIFY_PREV):
  │   └─ btr_cur_search_to_nth_level() 定位 ibuf B-tree 位置
  │   └─ 尝试 page_cur_insert_rec_low()
  │   └─ 空间不够 → 返回 DB_FAIL
  └─ 悲观模式 (BTR_MODIFY_TREE):
      └─ btr_cur_search_to_nth_level() 重新定位（悲观需要 X-latch）
      └─ btr_page_alloc() 如果当前页满 → 分配新页
      └─ btr_page_split_and_insert() 或 btr_page_insert_with_compression()
      └─ 更新 ibuf->size, ibuf->free_list_len, ibuf->height
```

**乐观 vs 悲观插入的选择策略**：

| | 乐观插入 | 悲观插入 |
|---|---|---|
| B-tree latch | S-latch（共享） | X-latch（排他） |
| 页锁 | PAGE_CUR_LE | X-latch 整页 |
| 空间检查 | 期望有足够空间 | 无期望（可分裂/分配） |
| 成功条件 | 页有足够空闲空间 | 总是成功（直到磁盘满） |
| 失败返回 | DB_FAIL | 不返回（ut_a / DB_OUT_OF_FILE_SPACE） |

悲观插入需要的 `BTR_LATCH_FOR_INSERT` 标记让 B-tree 遍历时使用 X-latch，阻塞其他并发写入。因此悲观插入的锁竞争比乐观高出很多，生产环境应尽量避免频繁触发悲观插入。

`ibuf_set_bitmap_for_page()` 在成功缓存后设置 `IBUF_BITMAP_BUFFERED` bit，这样以后页面调入时优先走 Merge 路径：

```c
// 简化逻辑
static void ibuf_set_bitmap_for_page(
    const page_id_t &page_id, const page_size_t &page_size,
    que_thr_t *thr, bool update_free) {

  mtr_t mtr;
  mtr_start(&mtr);
  mtr_x_lock(fil_space_get(page_id.space()), &mtr);

  /* 获取该页对应的 bitmap 页 */
  page_t *bitmap_page = ibuf_bitmap_page_get(
      page_id, page_size, RW_X_LATCH, &mtr);

  /* 设置 IBUF_BITMAP_BUFFERED bit */
  ibuf_bitmap_page_set_bits(bitmap_page, page_id, page_size,
                            IBUF_BITMAP_BUFFERED, &mtr);

  mtr_commit(&mtr);
}
```

---

## 5. Merge 路径

Merge 是将 Change Buffer 中的缓存操作"回放"到目标二级索引页上的过程，是 Change Buffer 的"消费端"。

### 5.1 触发 Merge 的三种场景

```
┌────────────────────────────────────────┐
│          Merge 触发条件                 │
├────────────────────────────────────────┤
│ 场景 1：目标页被读入 BP 时（主要触发）     │
│   调用链: buf_read_page_low() →          │
│           ibuf_merge_or_delete_for_page() │
├────────────────────────────────────────┤
│ 场景 2：后台线程定期收缩                  │
│   调用链: srv_master_thread() →          │
│           ibuf_merge_in_background()      │
├────────────────────────────────────────┤
│ 场景 3：插入后 ibuf 过大，触发的紧急收缩     │
│   调用链: ibuf_contract_after_insert() →  │
│           ibuf_contract() → ibuf_merge()  │
└────────────────────────────────────────┘
```

### 5.2 场景 1：页面调入触发 Merge

当 `buf_read_page_low()` 完成 I/O 读取一个二级索引页后，会调用 `ibuf_merge_or_delete_for_page()`：

```c
// ibuf0ibuf.cc:3962-4062
void ibuf_merge_or_delete_for_page(
    buf_block_t *block, const page_id_t &page_id,
    const page_size_t *page_size, bool update_ibuf_bitmap) {

  /* ── 快速路径：检查 bitmap 是否有缓存 ── */
  if (update_ibuf_bitmap) {
    space = fil_space_acquire_silent(page_id.space());
    bitmap_bits = ibuf_bitmap_page_get_bits(
        bitmap_page, page_id, *page_size,
        IBUF_BITMAP_BUFFERED, &mtr);

    if (!bitmap_bits) {
      fil_space_release(space);
      return;  // 没有缓存 → 直接返回，零开销
    }
  }

  /* ── 步骤 2：构建搜索元组 ── */
  heap = mem_heap_create(512, UT_LOCATION_HERE);
  search_tuple = ibuf_search_tuple_build(
      page_id.space(), page_id.page_no(), heap);

  /* ── 步骤 3：打开 B-tree 游标 ── */
  pcur.open(ibuf->index, 0, search_tuple, PAGE_CUR_GE,
            BTR_SEARCH_LEAF, &mtr, UT_LOCATION_HERE);

  /* ── 步骤 4：遍历并合并所有匹配记录 ── */
  while ((rec = pcur.get_rec()),
         !page_rec_is_infimum(rec) &&
         ibuf_rec_get_space(&mtr, rec) == page_id.space() &&
         ibuf_rec_get_page_no(&mtr, rec) == page_id.page_no()) {

    op = ibuf_rec_get_op(rec, &mtr);

    /* 在目标索引 B-tree 上定位并执行操作 */
    switch (op) {
      case IBUF_OP_INSERT:
        btr_cur_ins_lock_and_rec(...);        // 执行实际插入
        break;
      case IBUF_OP_DELETE_MARK:
        row_upd_del_mark_sec(...);            // 执行标记删除
        break;
      case IBUF_OP_DELETE:
        btr_cur_del_mark_set_sec_rec(...);    // 执行物理删除
        break;
    }

    /* 从 ibuf B-tree 删除已合并的记录 */
    btr_cur_delete_rec(...);

    /* 更新计数器 */
    ++mops[op];

    pcur.move_to_next(&mtr);  // 下一匹配记录
  }

  /* ── 步骤 5：清理 ── */
  if (new_skip) {
    ibuf_reset_free_bits(...);  // 更新目标页的 ibuf 空闲位
  }
  ibuf_mtr_commit(&mtr);
  ibuf->n_merges.fetch_add(1);
  ibuf->n_merged_ops[op].fetch_add(mops[op]);
}
```

**完整调用链**：

```
用户 SELECT/UPDATE 触发读页 → 该页是二级索引页
  └─ buf_read_page_low(page_id)
      ├─ 发起异步 I/O
      ├─ os_aio_func(OS_FILE_AIO_READ, ...)
      │   └─ Linux AIO / io_uring 提交
      ├─ I/O 完成 → buf_page_io_complete()
      │   └─ ibuf_merge_or_delete_for_page(block, page_id, ...)
      │       ├─ 检查 bitmap → 有缓存
      │       ├─ ibuf_search_tuple_build(space, page_no)
      │       ├─ btr_pcur.open(...PAGE_CUR_GE...)
      │       ├─ 循环: 每条 ibuf 记录 → 应用到目标页
      │       └─ 已合入记录从 ibuf B-tree 删除
      └─ 应用程序获得完整数据
```

**关键设计：为什么在读入时触发 Merge？**

因为这个页被读应该很快也会被读。不这么做的话，所有 cache 操作会一直累积在 Change Buffer 中，最后 merge 时需要一次读入并同时更新大量数据——导致读延迟不必要的大幅增大。

### 5.3 场景 2：后台线程定期 Merge

`ibuf_merge_in_background()` 由 `srv_master_thread` 或 `srv_purge_coordinator_thread` 定期调用：

```c
// ibuf0ibuf.cc:2399-2460
ulint ibuf_merge_in_background(bool full) {
  ulint sum_bytes = 0;
  ulint sum_pages = 0;
  ulint n_pages;

  if (full) {
    /* 完全合并：使用 100% IO capacity */
    n_pages = PCT_IO(100);
  } else {
    /* 默认：5% IO capacity */
    n_pages = PCT_IO(5);

    mutex_enter(&ibuf_mutex);
    /* 如果 ibuf 过大（> max_size/2），动态增加合并力度 */
    if (ibuf->size > ibuf->max_size / 2) {
      ulint diff = ibuf->size - ibuf->max_size / 2;
      diff = std::min(diff, ibuf->max_size);
      n_pages += PCT_IO((diff * 100) / (ibuf->max_size + 1));
    }
    mutex_exit(&ibuf_mutex);
  }

  /* 批量合并直到达到 n_pages 页面数 */
  while (sum_pages < n_pages) {
    ulint n_bytes = ibuf_merge(&n_pag2, false);
    if (n_bytes == 0) return sum_bytes;
    sum_bytes += n_bytes;
    sum_pages += n_pag2;
  }

  return sum_bytes;
}
```

`ibuf_merge()` 进一步调用 `ibuf_merge_pages()`：

```c
static ulint ibuf_merge_pages(ulint *n_pages, bool sync) {
  mtr_t mtr;

  /* 步骤 1：在 ibuf B-tree 上随机选择一个叶子节点 */
  ibuf_mtr_start(&mtr);
  pcur.set_random_position(ibuf->index, BTR_SEARCH_LEAF, &mtr, UT_LOCATION_HERE);

  /* 步骤 2：收集该节点中引用的目标 pages */
  sum_sizes = ibuf_get_merge_page_nos(
      true, pcur.get_rec(), &mtr,
      space_ids, page_nos, n_pages);

  ibuf_mtr_commit(&mtr);
  pcur.close();

  /* 步骤 3：批量异步预读目标页 */
  /* 读入时会自动触发 ibuf_merge_or_delete_for_page() */
  buf_read_ibuf_merge_pages(sync, space_ids, page_nos, *n_pages);

  return sum_sizes + 1;
}
```

**随机位置选择的设计意图**：

- `set_random_position()` 随机选择一个 ibuf B-tree 叶子节点
- 获取该叶子节点中所有引用的目标页
- 批量预读这些目标页

为什么是随机的？因为如果总是选择第一个叶子节点，会导致某些页的合并不断延迟。随机选择确保了**公平性**——所有有缓存的页最终都会被合并。

**PCT_IO() 宏**：将 IO capacity 百分比转换为页面数：

```c
// srv0srv.h
#define PCT_IO(p) ((ulint)(srv_io_capacity * (double)(p) / 100.0))
```

其中 `srv_io_capacity` 默认值 200。在 ibuf 较大的情况下，`ibuf_merge_in_background(false)` 可能从 PCT_IO(5)=10 页动态增加到 PCT_IO(30+)=60+ 页。

### 5.4 场景 3：插入后紧急收缩

每次成功插入 ibuf 后调用的 `ibuf_contract_after_insert()`：

```c
static inline void ibuf_contract_after_insert(ulint entry_size) {
  /* 脏读 ibuf->size 和 ibuf->max_size（无锁，减少竞争） */
  auto size = ibuf->size;
  auto max_size = ibuf->max_size;

  // 未超过阈值 → 不做收缩
  if (size < max_size + IBUF_CONTRACT_ON_INSERT_NON_SYNC) {
    return;
  }

  // 超过较大阈值 → 同步收缩
  auto sync = (size >= max_size + IBUF_CONTRACT_ON_INSERT_SYNC);

  ulint sum_sizes = 0;
  size = 1;
  do {
    size = ibuf_contract(sync);
    sum_sizes += size;
  } while (size > 0 && sum_sizes < entry_size);
}
```

两个阈值常量（`ibuf0ibuf.h`）：

```c
/* ibuf 超过 max_size 后无符号大小时不收缩 */
#define IBUF_CONTRACT_ON_INSERT_NON_SYNC    0
/* ibuf 超过 max_size 后 50 页时同步收缩 */
#define IBUF_CONTRACT_ON_INSERT_SYNC       50
```

衰减策略：

```
ibuf->size             行为
─────────────────────────────────────────
< max_size             不做收缩（正常范围）
≥ max_size             异步收缩，合并量 ≥ entry_size
≥ max_size + 50        同步收缩，等待 I/O 完成
```

两步阈值的设计目的：异步收缩允许写操作不等待 I/O 返回；只有 ibuf 疯狂膨胀到超过 max_size+50 时才开始同步等待，确保系统不会因为 ibuf 无限扩张而耗尽系统表空间。

---

## 6. 三层页面访问规则与死锁预防

### 6.1 三层等级

为了避免 Change Buffer 系统中的死锁，InnoDB 严格定义了三级页面访问规则（`ibuf0ibuf.cc:186-207`）：

```
Level 1: 非 ibuf 页（普通数据页、二级索引页、聚簇索引页）
Level 2: ibuf B-tree 页 + ibuf free list 页
Level 3: ibuf bitmap 页
```

### 6.2 访问规则

```
✅ 允许: Level 2 → Level 1 (ibuf merge 时读目标普通页)
❌ 禁止: Level 1 → Level 2 (普通操作试图读 ibuf B-tree 页)
❌ 禁止: Level 1/2 → Level 3 (读 bitmap 页)
```

### 6.3 为什么需要这个规则？

考虑没有规则时的死锁场景：

```
线程 A (普通 INSERT):                 线程 B (ibuf merge):
1. Latch(Page P1) ← 二级索引目标页   1. Latch(ibuf_root) ← ibuf B-tree 根页
2. 页不在 BP → 尝试读 ibuf           2. 扫描得到 P1 有缓存
3. 等待 Latch(ibuf_root)             3. 等待 Latch(P1)
                                      → 死锁！
```

通过规则，线程 A 永远不能从 Level 1 上跳到 Level 2，因此不能在持有普通页 latch 时等待 ibuf latch。线程 B 从 Level 2 下到 Level 1 是允许的，且有超时机制（`innodb_lock_wait_timeout`）兜底。

### 6.4 实现检查

```c
// ibuf0ibuf.cc — ibuf_enter() / ibuf_exit()
static inline void ibuf_enter(mtr_t *mtr) {
  /* 标记 MTR 正在进入 ibuf 区域 */
  /* 后续如果尝试从 Level 1 访问 Level 2，page_get_latched_level 会检查 */
  mtr->set_ibuf_region(true);
}
```

在 `buf_page_get_gen()` 中：

```c
// buf0buf.cc (简化)
buf_block_t *buf_page_get_gen(...) {
  /* 检查 latch 等级规则 */
  ut_ad(!mtr->is_ibuf_region() ||   // 已在 ibuf 区域
        page_id.space() != IBUF_SPACE_ID ||  // 不是 ibuf 页
        !mtr->has_latched_page());   // 或者还没有 latch 任何页
  ...
}
```

这就是为什么 `ibuf_insert()` 的 MTR 和 `ibuf_merge_or_delete_for_page()` 的 MTR 是独立的 `ibuf_mtr`，而不是嵌套在主操作的 MTR 中——防止 latch 等级违反。

---

## 7. 事务语义与崩溃恢复

### 7.1 原子性问题

Change Buffer 的写入不跨事务：ibuf_insert 在一个独立的 MTR 中完成，MTR 提交时 redo log 落盘。因此：

```
用户 INSERT 语句:
  ├─ 聚簇索引写入  → 用户事务 redo (COMMIT 时落盘)
  └─ Change Buffer → 独立的 MTR redo (立即落盘)
```

这意味着 Change Buffer 的写入**先于用户事务提交**。如果用户在 INSERT 后回滚：

- **聚簇索引**：UNDO 回滚
- **Change Buffer**：不会显式回滚（ibuf 记录还在），但 merge 时发现行不存在或与该用户事务的回滚冲突怎么办？

答案在 **ibuf merge 路径**的处理中：merge 时会重新执行 INSERT/DELETE_MARK/DELETE 操作，这些操作符合当前事务可见性（即遵循 MVCC 规则）。因此：

1. 如果 ibuf 中的 INSERT 对应一个已回滚的用户事务，merge 时该行会被成功插入
2. 但在 MVCC 视角下，该行对于其他活跃事务不可见
3. 最终 PURGE 会清理该行（因为生成该 INSERT 的事务已回滚，删除标记记录）

**这是一个设计选择**：宁愿在 merge 时多插入一行后来被 PURGE 清理，也不要在用户事务回滚时同步扫描 ibuf B-tree 删除对应记录。后者的扫描开销在 ibuf 积累大量记录时高昂到不可接受。

### 7.2 Recovery 处理

崩溃恢复时，Change Buffer 通过 redo log 恢复。关键点是：

**Change Buffer 的 redo 记录类型**：

```c
// ibuf0ibuf.h
#define MLOG_IBUF_BITMAP_INIT       (38)
#define MLOG_IBUF_INIT_PAGE         (62)
```

在 redo apply 阶段，ibuf B-tree 通过常规的 `mtr` redo 恢复。但 **bitmap 页需要特殊处理**：因为它是对普通数据页元信息的缓存，崩溃后 bitmap 可能不一致（ibuf 记录恢复成功但 bitmap 未更新）。

这种情况下的恢复策略：

```
崩溃恢复 → redo apply ibuf B-tree 记录
           → redo apply 其他所有记录
           → 恢复完成后第一次启动
           → ibuf_init_at_db_start()
           → 如果 bitmap 与 ibuf B-tree 不一致
              → 后续 merge 时通过 B-tree 扫描兜底
              → bitmap 只是优化，不是一致性要求
```

**bitmap 不是一致性的"必须"组件**。如果 bitmap 显示没有缓存，但 ibuf B-tree 中实际上有记录——这只意味着该页的 merge 会被延迟到下次 B-tree 扫描或后台收缩时进行，不会丢失数据。

---

## 8. 性能考量与调优

### 8.1 收益场景

Change Buffer 在以下场景收益最大：

| 场景 | 收益 | 说明 |
|------|------|------|
| 批量 INSERT 到非唯一二级索引 | 极高 | 从 N 次随机 I/O → 1 次批量合并 |
| 大量 DELETE WHERE 造成二级索引删除 | 高 | DELETE MARK 和 DELETE 同样被缓存 |
| SSD + 高 INSERT 并发 | 中高 | 虽然 SSD 随机 I/O 延迟低，但减少 I/O 数量始终有益 |
| 表有多个非唯一二级索引 | 极高 | 每个索引都要写入，缓存效果累加 |

### 8.2 不适用场景

| 场景 | 原因 |
|------|------|
| 所有二级索引都是唯一索引 | 唯一索引不能走 ibuf |
| 二级索引列使用自增/单调递增值 | 目标页大概率在 BP 中，不触发 ibuf |
| 读密集且二级索引随机扫描频繁 | 页大量被读入 merge，ibuf 几乎没有积累 |
| innodb_change_buffer_max_size = 0 | 显式禁用 |

### 8.3 监控与分析

通过 `SHOW ENGINE INNODB STATUS` 查看：

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

各字段含义：

| 字段 | 含义 | 正常范围 |
|------|------|---------|
| `size` | ibuf B-tree 当前页面数 | 取决于加载 |
| `free list len` | ibuf free list 长度 | 接近 0 |
| `seg size` | file segment 分配的页数 | ≥ size |
| `merges` | 总 merge 次数 | 持续增长 |
| `merged ops` | 按操作类型已合入次数 | insert >> 其他 |
| `discarded ops` | 表被删除导致丢弃的操作次数 | 不应持续增长 |

**异常信号**：

- `merges` 不增长 + `size` 不断增大 → ibuf 只有写入没有消费，检查是否有 full table scan 导致 ibuf 延迟累计
- `discarded ops` 持续增长 → 频繁 DDL（DROP/TRUNCATE TABLE），考虑增大 `innodb_change_buffer_max_size` 或调整写入节奏
- `size` 超过 `innodb_change_buffer_max_size` 较多 → 写入速度 > merge 速度，考虑增大 IO capacity 或增加后台 merge 频率

### 8.4 关键配置参数

| 参数 | 默认值 | 建议 |
|------|--------|------|
| `innodb_change_buffering` | `all` | 纯写入设为 `inserts` |
| `innodb_change_buffer_max_size` | 25 | HDD 可 25-50，SSD 可 10-25 |
| `innodb_io_capacity` | 200 | 决定 merge 速度，与 ibuf 大小平衡 |
| `innodb_io_capacity_max` | 2×IO capacity | 突发合并时上限 |

---

## 9. 完整调用链总结

### 9.1 缓存路径

```
INSERT/DELETE/UPDATE
  └─ row_ins_sec_index_entry() / row_upd_del_mark_sec() / row_purge_...
      └─ ibuf_should_try()                     ← 9 项前置检查
      └─ ibuf_insert(op, entry, index, page_id, ...)
          ├─ 步骤 1: 操作类型检查 (switch op × use)
          ├─ 步骤 2: buf_page_get_also_watch() ← watch 冲突检测
          ├─ 步骤 3: 记录大小检查
          ├─ 步骤 4: ibuf_insert_low()
          │   ├─ 乐观: BTR_MODIFY_PREV → page_cur_insert_rec_low()
          │   └─ 悲观: BTR_MODIFY_TREE → btr_page_split_and_insert()
          ├─ 步骤 5: ibuf_set_bitmap_for_page() ← 标记 IBUF_BITMAP_BUFFERED
          └─ 步骤 6: ibuf_contract_after_insert() ← 检查是否需异步/同步收缩
              └─ ibuf_contract() → ibuf_merge() → ibuf_merge_pages()
```

### 9.2 Merge 路径

```
场景 A — 读页触发:
  buf_read_page_low()
    └─ buf_page_io_complete() → ibuf_merge_or_delete_for_page(block, page_id)
        ├─ 查 bitmap → IBUF_BITMAP_BUFFERED?
        ├─ ibuf_search_tuple_build(space, page_no)
        ├─ btr_pcur.open(ibuf->index, ..., PAGE_CUR_GE)
        ├─ while (匹配记录):
        │   ├─ btr_cur_ins_lock_and_rec()   ← 如果 op=INSERT
        │   ├─ row_upd_del_mark_sec()       ← 如果 op=DELETE_MARK
        │   ├─ btr_cur_del_mark_set_sec_rec() ← 如果 op=DELETE
        │   └─ btr_cur_delete_rec()         ← 从 ibuf B-tree 删除已合并记录
        └─ ibuf_mtr_commit()

场景 B — 后台线程:
  srv_master_thread / srv_purge_coordinator_thread
    └─ ibuf_merge_in_background(full?)
        ├─ 计算 merge 页数 (PCT_IO + ibuf size 衰减)
        └─ while (未达目标):
            └─ ibuf_merge() → ibuf_merge_pages()
                ├─ pcur.set_random_position(ibuf->index)
                ├─ ibuf_get_merge_page_nos() ← 收集要合入的页号
                └─ buf_read_ibuf_merge_pages() ← 批量预读 → 自动 merge

场景 C — 紧急收缩:
  ibuf_contract_after_insert(entry_size)
    └─ 检查 size ≥ max_size ± 阈值
    └─ ibuf_contract(sync?) → ibuf_merge() → ibuf_merge_pages()
```

---

## 10. 源码索引

| 函数/结构 | 文件 | 行号 | 关键作用 |
|-----------|------|------|---------|
| `ibuf_t` | `ibuf0ibuf.ic` | 62 | 全局 ibuf 控制块 |
| `ibuf_should_try()` | `ibuf0ibuf.ic` | 92 | 9 项前置检查 |
| `ibuf_op_t / ibuf_use_t` | `ibuf0ibuf.h` | 36-56 | 操作/配置枚举 |
| `IBUF_BITMAP_*` | `ibuf0ibuf.cc` | 246-255 | bitmap 位域常量 |
| `ibuf_init_at_db_start()` | `ibuf0ibuf.cc` | 458 | 启动初始化 |
| `ibuf_max_size_update()` | `ibuf0ibuf.cc` | 531 | 运行时调整 max_size |
| `ibuf_bitmap_page_init()` | `ibuf0ibuf.cc` | 536 | bitmap 页初始化 |
| `ibuf_merge_pages()` | `ibuf0ibuf.cc` | 2232 | 批量 merge 核心 |
| `ibuf_get_merge_page_nos()` | `ibuf0ibuf.cc` | 2194 | 收集待 merge 页号 |
| `ibuf_merge()` | `ibuf0ibuf.cc` | 2377 | merge 入口 |
| `ibuf_merge_in_background()` | `ibuf0ibuf.cc` | 2399 | 后台 merge |
| `ibuf_contract_after_insert()` | `ibuf0ibuf.cc` | 2472 | 插入后收缩 |
| `ibuf_insert()` | `ibuf0ibuf.cc` | 3284 | 缓存插入主入口 |
| `ibuf_insert_low()` | `ibuf0ibuf.cc` | 3048 | 乐观/悲观插入 |
| `ibuf_merge_or_delete_for_page()` | `ibuf0ibuf.cc` | 3962 | 页读入时 merge |
| `buf_read_ibuf_merge_pages()` | `buf0rea.cc` | 588 | 批量预读目标页 |
| `buf_page_get_also_watch()` | `buf0buf.ic` | 612 | watch 冲突检测 |
| `IBUF_CONTRACT_ON_INSERT_*` | `ibuf0ibuf.h` | 64-67 | 收缩阈值常量 |
