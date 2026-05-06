# 04-innodb-undo-log — InnoDB Undo Log：MVCC 与事务回滚

## 0. 概述

Undo Log 是 InnoDB 实现**事务原子性（Atomicity）** 和 **MVCC 一致性读**的核心机制。与 Redo Log 的前滚（roll-forward）相反，Undo Log 负责回滚（roll-back）——在事务回滚时撤销已做的修改，并为一致性读构建记录的旧版本。

### 0.1 Undo Log vs Redo Log

| 维度 | Redo Log | Undo Log |
|------|----------|----------|
| 方向 | 前滚恢复（物理） | 回滚撤销（逻辑） |
| 持久性 | 事务提交时必须 fsync | 事务提交后可被 purge |
| 记录内容 | 物理 page 级别的修改 | 逻辑 undo record（旧版本数据） |
| 空间回收 | 循环写，自动覆盖 | 通过 Purge 线程清理 |
| 作用阶段 | 故障恢复 | 回滚 + MVCC |
| 是否包含于 Redo | — | Undo 页的修改也有自己的 Redo |

### 0.2 Undo 的两大用途

1. **事务回滚（Rollback）**：撤销事务已做的 INSERT/UPDATE/DELETE 操作
2. **MVCC 一致性读**：为 SELECT 语句构建记录的历史版本，实现 `READ COMMITTED` 和 `REPEATABLE READ` 隔离级别

### 0.3 日志类型

- **Insert Undo Log（`TRX_UNDO_INSERT`）**：记录 INSERT 操作。由于 insert 记录的事务 id 就是自己，其他事务不可能看见，因此回滚只需直接删除，MVCC 不需要使用。事务提交后可立即释放。
- **Update Undo Log（`TRX_UNDO_UPDATE`）**：记录 UPDATE 和 DELETE 操作。包含旧版本的完整信息，供 MVCC 构建历史版本。事务提交后仍需要保留，直到所有活跃读视图都不再需要它。

```c
// trx0undo.h:192-193
constexpr uint32_t TRX_UNDO_INSERT = 1;
constexpr uint32_t TRX_UNDO_UPDATE = 2;
```

---

## 1. 核心数据结构

### 1.1 trx_undo_t — undo log 段头内存对象

每个事务在首次修改数据时会被分配一个 `trx_undo_t` 内存对象，记录 undo log 段的元数据。该对象受对应 transaction 的 `undo_mutex` 保护。

```c
// trx0undo.h:213-277
struct trx_undo_t {
  ulint id;            /*!< undo log slot number within the rollback segment */
  ulint type;          /*!< TRX_UNDO_INSERT or TRX_UNDO_UPDATE */
  ulint state;         /*!< state of the undo log segment */
  bool del_marks;      /*!< true if transaction may have delete mark operations */
  trx_id_t trx_id;     /*!< id of the trx assigned to the undo log */
  XID xid;             /*!< X/Open XA transaction identification */
  ulint flag;          /*!< flag for XID and GTID */
  bool dict_operation; /*!< true if a dict operation trx */
  trx_rseg_t *rseg;    /*!< rseg where the undo log belongs */

  space_id_t space;          /*!< space id where placed */
  page_size_t page_size;
  page_no_t hdr_page_no;     /*!< header page number */
  ulint hdr_offset;          /*!< header offset on the page */
  page_no_t last_page_no;    /*!< last page in the undo log */
  ulint size;                /*!< current size in pages */

  bool empty;                /*!< true if the stack is currently empty */
  page_no_t top_page_no;     /*!< page of latest undo record */
  ulint top_offset;          /*!< offset of latest undo record */
  undo_no_t top_undo_no;     /*!< undo number of latest record */
  buf_block_t *guess_block;  /*!< buffer block guess where top page is */
  UT_LIST_NODE_T(trx_undo_t) undo_list; /*!< chain node */
};
```

每个 `trx_t` 通过 `trx->rsegs.m_redo`（持久表空间）和 `trx->rsegs.m_noredo`（临时表空间）持有两个 undo 指针：

```c
// trx0types.h
struct trx_rsegs_t {
  trx_undo_ptr_t m_redo;    /* redo-logged undo (normal tables) */
  trx_undo_ptr_t m_noredo;  /* no-redo undo (temporary tables) */
};

struct trx_undo_ptr_t {
  trx_rseg_t *rseg;
  trx_undo_t *insert_undo;  /* TRX_UNDO_INSERT */
  trx_undo_t *update_undo;  /* TRX_UNDO_UPDATE */
  bool is_empty() const;
  bool is_insert_only() const;
  bool is_update() const;
};
```

### 1.2 trx_undo_rec_t — undo record 格式

`trx_undo_rec_t` 本质上就是 `byte *` 指针，指向 undo 页面上的一段连续数据：

```c
// trx0types.h:167
typedef byte trx_undo_rec_t;
```

每个 undo record 以 2 字节的 **next record offset** 开头，表示同一页上下一个 undo record 的偏移（或 0 表示这是最后一个）：

```c
// trx0rec.ic:37-41
static inline ulint trx_undo_rec_get_type(
    const trx_undo_rec_t *undo_rec)
{
  return (mach_read_from_1(undo_rec + 2) & (TRX_UNDO_CMPL_INFO_MULT - 1));
}
```

```c
// trx0rec.ic:65-76
static inline undo_no_t trx_undo_rec_get_undo_no(
    const trx_undo_rec_t *undo_rec)
{
  const byte *ptr = undo_rec + 2;
  uint8_t type_cmpl = mach_read_from_1(ptr);
  const bool blob_undo = type_cmpl & TRX_UNDO_MODIFY_BLOB;

  if (blob_undo) {
    ptr = undo_rec + 4;   // + extra flag byte
  } else {
    ptr = undo_rec + 3;
  }
  return (mach_u64_read_much_compressed(ptr));
}
```

Record 类型常量定义：

```c
// trx0rec.h:299-306
constexpr uint32_t TRX_UNDO_INSERT_REC    = 11;  // fresh insert
constexpr uint32_t TRX_UNDO_UPD_EXIST_REC = 12;  // update existing
constexpr uint32_t TRX_UNDO_UPD_DEL_REC   = 13;  // update delete-marked → not deleted
constexpr uint32_t TRX_UNDO_DEL_MARK_REC  = 14;  // delete mark a record
```

多用途的 type+cmpl_info 编码：

```c
// trx0rec.h:366-368
struct type_cmpl_t {
  ulint type_info()  { return (m_flag & 0x0F); }  // bits 0-3
  ulint cmpl_info()  { return ((m_flag >> 4) & 0x03); }  // bits 4-5
  bool is_lob_updated() { return (m_flag & TRX_UNDO_UPD_EXTERN); }  // bit 7
  bool is_lob_undo() const { return (m_flag & TRX_UNDO_MODIFY_BLOB); }  // bit 6
  ...
};
```

### 1.3 trx_rseg_t — rollback segment

Rollback segment 是管理 undo log 段的核心结构。系统默认有 128 个 slot（每个 slot 对应一个可能的并发活跃事务），每 2 个 undo segment 共享一个 slot（一个 insert undo + 一个 update undo）：

```c
// trx0rseg.h:90
#define TRX_RSEG_N_SLOTS (UNIV_PAGE_SIZE / 16)
#define TRX_RSEG_MAX_N_TRXS (TRX_RSEG_N_SLOTS / 2)
```

每个 rseg 维护两个 undo list：

```c
// trx0types.h
struct trx_rseg_t {
  ...
  UT_LIST_BASE_NODE_T(trx_undo_t) insert_undo_list;     // active insert undo logs
  UT_LIST_BASE_NODE_T(trx_undo_t) insert_undo_cached;   // cached (reusable)
  UT_LIST_BASE_NODE_T(trx_undo_t) update_undo_list;     // active update undo logs
  UT_LIST_BASE_NODE_T(trx_undo_t) update_undo_cached;   // cached (reusable)

  space_id_t space_id;     /* tablespace ID */
  page_no_t page_no;       /* rseg header page */
  page_size_t page_size;   /* page size */

  volatile ulint curr_size; /* current total size in pages */
  ulint max_size;           /* max size allowed */
  ...
};
```

Rollback segment header 页面布局常量：

```c
// trx0rseg.h:108-140
constexpr uint32_t TRX_RSEG = FSEG_PAGE_DATA;

constexpr uint32_t TRX_RSEG_MAX_SIZE     = 0;      /* max size in pages */
constexpr uint32_t TRX_RSEG_HISTORY_SIZE = 4;      /* pages in history list */
constexpr uint32_t TRX_RSEG_HISTORY      = 8;      /* history list base node */
constexpr uint32_t TRX_RSEG_FSEG_HEADER  = 8 + FLST_BASE_NODE_SIZE;
constexpr uint32_t TRX_RSEG_UNDO_SLOTS   = 8 + FLST_BASE_NODE_SIZE + FSEG_HEADER_SIZE;
```

### 1.4 trx_purge_t — purge 系统

全局结构体 `purge_sys` 是 InnoDB 的中央 purge 控制器：

```c
// trx0purge.h:220-290
struct trx_purge_t {
  sess_t *sess;               /* system session running the purge query */
  trx_t *trx;                 /* system transaction (never ends) */
  rw_lock_t latch;            /* protects the purge view */
  os_event_t event;           /* state signal */
  volatile bool running;      /* is purge active */
  volatile purge_state_t state; /* PURGE_STATE_INIT/RUN/STOP/EXIT */
  que_t *query;               /* purge query graph */
  ReadView view;              /* purge view — MVCC minimum visible trx_id */

  trx_id_t m_lowest_needed_trx_no; /* lower bound for purge safety */

  ulint n_submitted;          /* total tasks submitted */
  std::atomic<ulint> n_completed; /* tasks completed */

  purge_iter_t iter;          /* read/parse position */
  purge_iter_t limit;         /* purge pointer (advances during purge) */

  bool next_stored;
  trx_rseg_t *rseg;           /* rseg for next record to purge */
  page_no_t page_no;
  ulint offset;
  page_no_t hdr_page_no;
  ulint hdr_offset;

  TrxUndoRsegsIterator *rseg_iter;  /* round-robin rseg iterator */
  purge_pq_t *purge_queue;          /* min-heap on trx_no */
  undo::Truncate undo_trunc;        /* undo tablespace truncation tracker */
  mem_heap_t *heap;                 /* temp heap for reading records */
};
```

Purge 迭代器 `purge_iter_t`：

```c
// trx0purge.h:117-131
struct purge_iter_t {
  trx_id_t trx_no;              /* purge past all trx_no < this */
  undo_no_t undo_no;            /* purge past undo_no < this */
  space_id_t undo_rseg_space;   /* space id of last record */
  trx_id_t modifier_trx_id;     /* creator trx of the undo record */
};
```

### 1.5 ReadView — MVCC 一致性读

ReadView 决定了一个快照读"看到"哪些事务的修改：

```c
// read0types.h:86-218
class ReadView {
 public:
  bool changes_visible(trx_id_t id, const table_name_t &name) const {
    ut_ad(id > 0);
    if (id < m_up_limit_id || id == m_creator_trx_id) {
      return (true);  // committed or my own changes
    }
    check_trx_id_sanity(id, name);
    if (id >= m_low_limit_id) {
      return (false); // future transactions, not visible
    } else if (m_ids.empty()) {
      return (true);  // no concurrent RW transactions
    }
    const ids_t::value_type *p = m_ids.data();
    return (!std::binary_search(p, p + m_ids.size(), id));
  }

 private:
  trx_id_t m_low_limit_id;     /* high water mark: >= this are invisible */
  trx_id_t m_up_limit_id;      /* low water mark: < this are all visible */
  trx_id_t m_creator_trx_id;   /* my own trx id */
  ids_t m_ids;                 /* set of active RW transaction ids at snapshot time */
  trx_id_t m_low_limit_no;     /* purge can remove undo with trx_no < this */
  std::atomic_bool m_closed;
  node_t m_view_list;
};
```

核心可见性规则：
- `trx_id < m_up_limit_id` → 已提交，可见
- `trx_id == m_creator_trx_id` → 自己可见
- `trx_id >= m_low_limit_id` → 创建 ReadView 之后的事务，不可见
- `trx_id ∈ m_ids` → 创建 ReadView 时活跃的 RW 事务，不可见
- 否则 → 已提交，可见

---

## 2. Undo 日志类型与状态机

### 2.1 TRX_UNDO_INSERT vs TRX_UNDO_UPDATE

两种 undo log 的差异不仅仅是类型标记。Insert undo 只需要记录足够回滚的信息（直接删除），而 update undo 必须记录旧版本的完整数据以便 MVCC 构建：

| 特性 | Insert Undo | Update Undo |
|------|-------------|-------------|
| 记录内容 | 聚簇索引键值 | 全部旧版本列 + DB_TRX_ID + DB_ROLL_PTR |
| 事务提交后 | 立即释放（CACHED 或 TO_FREE） | 放入 history list（TO_PURGE） |
| MVCC 用途 | 无 | 构建历史版本 |
| 是否缓存复用 | 可缓存单页小段 | 可缓存单页小段 |

### 2.2 状态转换

Undo log segment 的生命周期由以下状态驱动：

```c
// trx0undo.h:196-206
constexpr uint32_t TRX_UNDO_ACTIVE         = 1;  // active transaction
constexpr uint32_t TRX_UNDO_CACHED         = 2;  // cached for reuse
constexpr uint32_t TRX_UNDO_TO_FREE        = 3;  // insert undo: can free
constexpr uint32_t TRX_UNDO_TO_PURGE       = 4;  // update undo: must purge first
constexpr uint32_t TRX_UNDO_PREPARED_80028 = 5;  // XA prepared (pre-8.0.29 format)
constexpr uint32_t TRX_UNDO_PREPARED       = 6;  // XA prepared
constexpr uint32_t TRX_UNDO_PREPARED_IN_TC = 7;  // prepared + TC processed
```

状态转换路径：

```
ACTIVE ──── commit ────→ CACHED       (单页小段，可复用)
ACTIVE ──── commit ────→ TO_FREE      (insert undo 大段)
ACTIVE ──── commit ────→ TO_PURGE     (update undo 大段，进入 history list)
CACHED ──── reuse ─────→ ACTIVE       (被新事务复用)
TO_PURGE ── purge ─────→ FREED        (purge 清理完后释放)
TO_FREE ──── purge ────→ FREED        (立即释放)
```

`trx_undo_set_state_at_finish()` 是事务结束时决定状态的关键函数：

```c
// trx0undo.cc:1838-1860
page_t *trx_undo_set_state_at_finish(trx_undo_t *undo, mtr_t *mtr) {
  page_t *undo_page = trx_undo_page_get(
      page_id_t(undo->space, undo->hdr_page_no), undo->page_size, mtr);

  trx_usegf_t *seg_hdr = undo_page + TRX_UNDO_SEG_HDR;
  trx_upagef_t *page_hdr = undo_page + TRX_UNDO_PAGE_HDR;

  ulint state;
  if (trx_undo_reusable(undo, page_hdr)) {
    state = TRX_UNDO_CACHED;
  } else if (undo->type == TRX_UNDO_INSERT) {
    state = TRX_UNDO_TO_FREE;
  } else {
    state = TRX_UNDO_TO_PURGE;
  }
  undo->state = state;
  ...
}
```

可复用性判断：单页且用量不超过 75% 时缓存：

```c
#define TRX_UNDO_PAGE_REUSE_LIMIT (3 * UNIV_PAGE_SIZE / 4)  // trx0undo.h:319

static bool trx_undo_reusable(const trx_undo_t *undo,
                              const trx_upagef_t *page_hdr) {
  return undo->size == 1 &&
         mach_read_from_2(page_hdr + TRX_UNDO_PAGE_FREE) <
             TRX_UNDO_PAGE_REUSE_LIMIT;
}
```

---

## 3. Undo 记录格式

### 3.1 Insert undo record 格式

Insert undo 记录结构如下（从 undo page 偏移处开始）：

```
Offset  Size  Field
─────────────────────────────────────
0       2     Next record offset (within this page)
2       1     Type (TRX_UNDO_INSERT_REC = 11)
3       var   undo_no (mach_u64_read_much_compressed)
3+var   var   table_id
...           Clustered index key fields
```

解析入口：

```c
// trx0rec.cc:2116-2258
dberr_t trx_undo_report_row_operation(
    ulint flags, ulint op_type, que_thr_t *thr,
    dict_index_t *index, const dtuple_t *clust_entry, ...)
{
  ...
  if (op_type == TRX_UNDO_INSERT_OP) {
    offset = trx_undo_page_report_insert(
        undo_page, trx, index, clust_entry, &mtr);
  } else {
    offset = trx_undo_page_report_modify(
        undo_page, trx, index, rec, ...);
  }
  ...
}
```

INSERT 操作的调用点在 `btr_cur_insert_if_new`：

```c
// btr0cur.cc:2605
err = trx_undo_report_row_operation(flags, TRX_UNDO_INSERT_OP, thr, index,
                                    clust_entry, ...);
```

### 3.2 Update undo record 格式

Update undo 记录包含完整的旧版本信息：

```
Offset  Size  Field
─────────────────────────────────────
0       2     Next record offset
2       1     type_cmpl (type + cmpl_info + lob flags)
3/4     var   undo_no (blob_undo → +1 byte)
3/4+var 8     table_id
var     var   Clustered index key (row reference)
var     var   Old columns for non-PK indexes
var     6     Old DB_TRX_ID (6 bytes)
var     7     Old DB_ROLL_PTR (7 bytes, encoded)
var     var   info_bits (1 byte)
var     var   Updated field values (update vector)
```

UPDATE 操作的调用点：

```c
// btr0cur.cc:3119
return (trx_undo_report_row_operation(flags, TRX_UNDO_MODIFY_OP, thr, index,
                                      nullptr, rec, ...));
```

DELETE MARK 操作（软删除）：

```c
// btr0cur.cc:4322
trx_undo_report_row_operation(flags, TRX_UNDO_MODIFY_OP, thr, index,
                              nullptr, rec, ...);
```

### 3.3 Roll ptr 的编码方式

Roll pointer（7 字节）是连接当前记录和其 undo log 的"指针"，存储在聚簇索引记录的 `DB_ROLL_PTR` 中：

```c
// trx0undo.h:46-53
static inline void trx_write_roll_ptr(byte *ptr, roll_ptr_t roll_ptr);

static inline roll_ptr_t trx_read_roll_ptr(const byte *ptr);
```

编码格式（7 字节）：

```
Bit   Field
─────────────────────────────────────
0     is_insert: 1 = insert undo, 0 = update undo
1-9   rseg_id (9 bits, up to 512 rollback segments)
10-41 space_id (32 bits)
42-57 page_no  (32 bits, within undo tablespace)
58-69 offset   (12 bits, within undo page)
```

解析方式：

```c
// trx0undo.ic
static inline bool trx_undo_roll_ptr_is_insert(roll_ptr_t roll_ptr) {
  return (roll_ptr & 0x01UL);
}
```

### 3.4 Tablespace undo vs temporary undo

InnoDB 8.4 中 undo 日志可存在于三种表空间中：

1. **System tablespace (space_id=0)**：传统 ibdata1，不推荐
2. **Undo tablespace (space_id ∈ [128M+1, 128M+N])**：独立 undo_001/undo_002 文件，推荐
3. **Temporary tablespace (space_id 为临时空间)**：`TRX_UNDO_INSERT` 写入临时表空间的 undo 采用 `MTR_LOG_NO_REDO` 模式

```c
// trx0undo.cc:1740-1744
bool no_redo = (&trx->rsegs.m_noredo == undo_ptr);
...
if (no_redo) {
  mtr.set_log_mode(MTR_LOG_NO_REDO);   // temporary tables: no redo logging
} else {
  ut_ad(&trx->rsegs.m_redo == undo_ptr);
}
```

---

## 4. Undo 日志写入路径

### 4.1 INSERT 时写入 insert undo

当 btr_cur 插入一条记录时，调用 `trx_undo_report_row_operation`(flags, `TRX_UNDO_INSERT_OP`, ...)。如果当前事务还没有 insert undo 段，会调用 `trx_undo_assign_undo()` 分配一个。

写入 insert undo 的底层函数：

```c
// trx0rec.cc:483
static ulint trx_undo_page_report_insert(
    page_t *undo_page,    /* undo segment page */
    trx_t *trx,           /* transaction */
    dict_index_t *index,  /* clustered index */
    const dtuple_t *clust_entry, /* inserted row */
    mtr_t *mtr)
{
  ...
  // Write undo record to the page
  ptr = undo_page + free;  // free is current free offset
  mach_write_to_2(ptr, undo_no + undo_record_len);  // next record offset
  ptr += 2;
  mach_write_to_1(ptr, TRX_UNDO_INSERT_REC);  // type
  ptr++;
  ptr = mach_u64_write_much_compressed(ptr, undo_no);
  ptr = mach_u64_write_much_compressed(ptr, table_id);
  // ... write key fields ...
  // Update page free pointer
  mlog_write_ulint(page_hdr + TRX_UNDO_PAGE_FREE, new_free, MLOG_2BYTES, mtr);
  ...
}
```

### 4.2 UPDATE/DELETE 时写入 update undo

UPDATE 和 DELETE MARK 操作统一走 `TRX_UNDO_MODIFY_OP` 路径：

```c
// trx0rec.cc:2116
dberr_t trx_undo_report_row_operation(
    ulint flags, ulint op_type, que_thr_t *thr,
    dict_index_t *index, const dtuple_t *clust_entry, const rec_t *rec,
    const ulint *offsets, ...)
{
  trx_t *trx = thr_get_trx(thr);
  ... 
  /* Ensure undo segment is assigned */
  mutex_enter(&trx->undo_mutex);
  if (op_type == TRX_UNDO_MODIFY_OP && undo_ptr->update_undo == nullptr) {
    err = trx_undo_assign_undo(trx, undo_ptr, TRX_UNDO_UPDATE);
  }
  ...
  /* Append the record to the undo log page */
  if (op_type == TRX_UNDO_INSERT_OP) {
    offset = trx_undo_page_report_insert(undo_page, trx, index, clust_entry, &mtr);
  } else {
    offset = trx_undo_page_report_modify(undo_page, trx, index, rec, offsets, ...);
  }
  ...
}
```

### 4.3 trx_undo_assign_undo() — 分配 undo log

当事务第一次 INSERT 或 MODIFY 时，需要分配一个 undo log 段：

```c
// trx0undo.cc:1688-1802
dberr_t trx_undo_assign_undo(
    trx_t *trx, trx_undo_ptr_t *undo_ptr, ulint type)
{
  trx_rseg_t *rseg = undo_ptr->rseg;
  ...
  // Step 1: Try to reuse a cached undo segment
  undo = trx_undo_reuse_cached(rseg, type, trx->id, trx->xid,
                               gtid_storage, &mtr);

  // Step 2: If no cache, create a new one
  if (undo == nullptr) {
    err = trx_undo_create(rseg, type, trx->id, trx->xid, gtid_storage,
                          &undo, &mtr);
  }

  // Step 3: Link to rseg's list
  if (type == TRX_UNDO_INSERT) {
    UT_LIST_ADD_FIRST(rseg->insert_undo_list, undo);
    undo_ptr->insert_undo = undo;
  } else {
    UT_LIST_ADD_FIRST(rseg->update_undo_list, undo);
    undo_ptr->update_undo = undo;
  }
  ...
}
```

创建新的 undo log segment 时，会通过 `fseg_create_general` 分配文件段，并在 segment header page 上初始化 segment header：

```c
// trx0undo.cc:370-418
static dberr_t trx_undo_seg_create(
    trx_rseg_t *rseg, trx_rsegf_t *rseg_hdr, ulint type,
    ulint *id, page_t **undo_page, mtr_t *mtr)
{
  // Find a free slot in rseg header
  slot_no = trx_rsegf_undo_find_free(rseg_hdr, mtr);
  if (slot_no == ULINT_UNDEFINED) {
    return DB_TOO_MANY_CONCURRENT_TRXS;
  }
  // Allocate file segment
  block = fseg_create_general(space, 0,
           TRX_UNDO_SEG_HDR + TRX_UNDO_FSEG_HEADER, true, mtr);
  *undo_page = buf_block_get_frame(block);
  // Initialize page header with type
  trx_undo_page_init(*undo_page, type, mtr);
  // Set up segment header
  mach_write_to_2(seg_hdr + TRX_UNDO_LAST_LOG, 0);
  flst_init(seg_hdr + TRX_UNDO_PAGE_LIST, mtr);
  flst_add_last(seg_hdr + TRX_UNDO_PAGE_LIST,
                page_hdr + TRX_UNDO_PAGE_NODE, mtr);
  // Write slot in rseg header
  trx_rsegf_set_nth_undo(rseg_hdr, slot_no, page_no, mtr);
  *id = slot_no;
  ...
}
```

### 4.4 Undo 页的 Redo 记录

Undo 页的修改也需要生成 Redo Log，以保证崩溃恢复后 undo 数据完整：

```c
// trx0undo.cc:310-316
static inline void trx_undo_page_init_log(
    page_t *undo_page, ulint type, mtr_t *mtr)
{
  mlog_write_initial_log_record(undo_page, MLOG_UNDO_INIT, mtr);
  mlog_catenate_ulint_compressed(mtr, type);
}
```

```c
// trx0undo.cc:533-535
static inline void trx_undo_header_create_log(
    const page_t *undo_page, trx_id_t trx_id, mtr_t *mtr)
{
  mlog_write_initial_log_record(undo_page, MLOG_UNDO_HDR_CREATE, mtr);
  mlog_catenate_ull_compressed(mtr, trx_id);
}
```

`MLOG_UNDO_INIT`、`MLOG_UNDO_HDR_CREATE`、`MLOG_UNDO_HDR_REUSE` 是三种专门的 redo 记录类型，确保 undo 页面的初始化操作在崩溃后可以重做。

### 4.5 添加新页

当 undo log 写满当前页时，需要分配新页：

```c
// trx0undo.cc:870-924
buf_block_t *trx_undo_add_page(
    trx_t *trx, trx_undo_t *undo,
    trx_undo_ptr_t *undo_ptr, mtr_t *mtr)
{
  ...
  header_page = trx_undo_page_get(...);
  // Reserve free extent from file space
  fsp_reserve_free_extents(&n_reserved, undo->space, 1, FSP_UNDO, mtr);
  // Allocate new page
  new_block = fseg_alloc_free_page_general(
      TRX_UNDO_SEG_HDR + TRX_UNDO_FSEG_HEADER + header_page,
      undo->top_page_no + 1, FSP_UP, true, mtr, mtr);
  // Initialize new page
  trx_undo_page_init(new_page, undo->type, mtr);
  // Link into page list
  flst_add_last(header_page + TRX_UNDO_SEG_HDR + TRX_UNDO_PAGE_LIST,
                new_page + TRX_UNDO_PAGE_HDR + TRX_UNDO_PAGE_NODE, mtr);
  undo->size++;
  rseg->incr_curr_size();
  ...
}
```

---

## 5. 事务回滚路径

### 5.1 trx_rollback() — 入口

MySQL 层通过 `trx_rollback_for_mysql()` 发起回滚：

```c
// trx0roll.cc:269-278
dberr_t trx_rollback_for_mysql(trx_t *trx) {
  if (TrxInInnoDB::is_async_rollback(trx)) {
    return (trx_rollback_low(trx));
  } else {
    TrxInInnoDB trx_in_innodb(trx, true);
    return (trx_rollback_low(trx));
  }
}
```

核心分发函数 `trx_rollback_low()` 根据事务状态处理：

```c
// trx0roll.cc:181-269
static dberr_t trx_rollback_low(trx_t *trx) {
  switch (trx->state.load(std::memory_order_relaxed)) {
    case TRX_STATE_ACTIVE:
      trx_undo_gtid_add_update_undo(trx, false, true);
      return (trx_rollback_for_mysql_low(trx));

    case TRX_STATE_PREPARED:
      // XA rollback: change undo state back to ACTIVE
      trx_undo_set_state_at_prepare(trx, undo_ptr->insert_undo, true, &mtr);
      trx_undo_set_state_at_prepare(trx, undo_ptr->update_undo, true, &mtr);
      return (trx_rollback_for_mysql_low(trx));

    case TRX_STATE_NOT_STARTED:
      return (DB_SUCCESS);  // nothing to rollback
    ...
  }
}
```

`trx_rollback_for_mysql_low` 遍历所有 undo log，对每个 undo segment 执行回滚（从最新记录开始向上遍历）：

```c
// trx0roll.cc:159-169
static dberr_t trx_rollback_for_mysql_low(trx_t *trx) {
  // ... lock release ...
  trx_rollback_to_savepoint_low(trx, nullptr);
  // ... cleanup ...
}
```

### 5.2 row_undo_step() — 逐条回滚 undo records

被回滚引擎逐个排队的节点：

```c
// row0undo.cc:408-435
que_thr_t *row_undo_step(que_thr_t *thr) {
  undo_node_t *node = static_cast<undo_node_t *>(thr->run_node);
  err = row_undo(node, thr);
  trx->error_state = err;
  ...
  return (thr);
}
```

`row_undo()` 函数是核心调度器，根据 undo record 类型分发到 `row_undo_ins()` 或 `row_undo_mod()`：

```c
// row0undo.cc:320-370
static dberr_t row_undo(undo_node_t *node, que_thr_t *thr) {
  ...
  if (node->state == UNDO_NODE_FETCH_NEXT) {
    node->undo_rec = trx_roll_pop_top_rec_of_trx(
        &trx, trx.roll_limit, &roll_ptr, node->heap);

    if (!node->undo_rec) {
      trx.roll_limit = 0;
      return (DB_SUCCESS);  // rollback complete
    }

    node->roll_ptr = roll_ptr;
    node->undo_no = trx_undo_rec_get_undo_no(node->undo_rec);

    if (trx_undo_roll_ptr_is_insert(roll_ptr)) {
      node->state = UNDO_NODE_INSERT;
    } else {
      node->state = UNDO_NODE_MODIFY;
    }
  }

  if (node->state == UNDO_NODE_INSERT) {
    err = row_undo_ins(node, thr);
    node->state = UNDO_NODE_FETCH_NEXT;
  } else {
    ut_ad(node->state == UNDO_NODE_MODIFY);
    err = row_undo_mod(node, thr);
  }
  ...
}
```

### 5.3 row_undo_ins() — 回滚 INSERT

回滚 INSERT 的逻辑是：删除聚簇索引记录和所有二级索引记录：

```c
// row0uins.cc:464-504
dberr_t row_undo_ins(undo_node_t *node, que_thr_t *thr) {
  ut_ad(node->state == UNDO_NODE_INSERT);
  ut_ad(node->trx.in_rollback);

  row_undo_ins_parse_undo_rec(node, thd, &mdl);

  if (node->table == nullptr) return (DB_SUCCESS);

  /* Iterate over all the indexes and undo the insert. */
  node->index = node->table->first_index();
  node->index = node->index->next();  /* skip clustered */

  err = row_undo_ins_remove_sec_rec(node, thr);  // remove secondary index records

  if (err == DB_SUCCESS) {
    log_free_check();
    err = row_undo_ins_remove_clust_rec(node);   // remove clustered index record
  }
  ...
}
```

### 5.4 row_undo_mod() — 回滚 UPDATE/DELETE

回滚 UPDATE/DELETE 的核心是**恢复旧版本**——将记录还原到 undo record 中保存的状态：

```c
// row0umod.cc:1274-1335
dberr_t row_undo_mod(undo_node_t *node, que_thr_t *thr) {
  ut_ad(node->state == UNDO_NODE_MODIFY);
  ut_ad(!trx_undo_roll_ptr_is_insert(node->roll_ptr));

  row_undo_mod_parse_undo_rec(node, thd, &mdl);

  switch (node->rec_type) {
    case TRX_UNDO_UPD_EXIST_REC:
      err = row_undo_mod_upd_exist_sec(node, thr);
      break;
    case TRX_UNDO_DEL_MARK_REC:
      err = row_undo_mod_del_mark_sec(node, thr);
      break;
    case TRX_UNDO_UPD_DEL_REC:
      err = row_undo_mod_upd_del_sec(node, thr);
      break;
    default:
      ut_error;
  }

  if (err == DB_SUCCESS) {
    log_free_check();
    err = row_undo_mod_clust(node);  // restore old version in clustered index
  }
  ...
}
```

处理完二级索引后，`row_undo_mod_clust()` 负责用 undo record 中的旧值覆盖聚簇索引记录。

---

## 6. Purge 路径

### 6.1 Purge 的作用

Purge 线程负责：
1. **清理物理删除的标记记录**（已提交事务的 `delete-marked` 记录）
2. **释放 undo log 空间**（purge 完成后，undo 段进入 FREED 状态）
3. **回收 undo tablespace 空间**（undo truncation）

### 6.2 srv_purge_coordinator_thread() — purge 协调线程

Purge coordinator 是一个独立的后台线程，循环执行 purge batch：

```c
// srv0srv.cc:3032-3140
void srv_purge_coordinator_thread() {
  ...
  do {
    if (srv_shutdown_state.load() < SRV_SHUTDOWN_PURGE &&
        (purge_sys->state == PURGE_STATE_STOP || n_total_purged == 0)) {
      srv_purge_coordinator_suspend(slot, rseg_history_len);
    }

    if (srv_purge_should_exit(n_total_purged)) break;

    n_total_purged = 0;
    rseg_history_len = srv_do_purge(&n_total_purged);

  } while (!srv_purge_should_exit(n_total_purged));
  ...
}
```

每个 purge batch 的核心是 `trx_purge()`：

```c
// trx0purge.cc:2396-2422
ulint trx_purge(ulint n_purge_threads, ulint batch_size, bool truncate) {
  // Step 1: Update m_lowest_needed_trx_no
  trx_purge_update_oldest_needed();

  // Step 2: Fetch undo records
  n_pages_handled = trx_purge_attach_undo_recs(n_purge_threads, batch_size);

  // Step 3: Submit tasks to worker queue
  for (ulint i = 0; i < n_purge_threads - 1; ++i) {
    thr = que_fork_scheduler_round_robin(purge_sys->query, thr);
    srv_que_task_enqueue_low(thr);
  }

  // Step 4: Run coordinator's own share
  que_run_threads(thr);

  // Step 5: Wait for workers
  trx_purge_wait_for_workers_to_complete();

  // Step 6: Truncate history
  if (truncate) {
    trx_purge_truncate();
  }
  ...
}
```

### 6.3 trx_purge_attach_undo_recs() — 收集待清理的 undo

这是从 rseg history list 中收集需要清理的 undo record 的关键函数：

```c
// trx0purge.cc:2243-2320
static ulint trx_purge_attach_undo_recs(
    const ulint n_purge_threads, ulint batch_size) {
  ...
  while (n_pages_handled < batch_size) {
    if (trx_purge_check_limit()) {
      purge_sys->limit = purge_sys->iter;
    }

    // Fetch next record via min-heap (ordered by trx_no)
    rec.undo_rec = trx_purge_fetch_next_rec(
        &rec.modifier_trx_id, &rec.roll_ptr, &n_pages_handled, heap);

    if (rec.undo_rec == &trx_purge_ignore_rec) continue;
    else if (rec.undo_rec == nullptr) break;

    purge_groups.add(rec);
  }

  purge_groups.distribute_if_needed();
  purge_groups.assign(run_thrs);
  ...
}
```

`trx_purge_fetch_next_rec` 使用 `TrxUndoRsegsIterator` 从所有 rseg 的 history list 中选择 `trx_no` 最小的记录：

```c
// trx0purge.cc:99-103
TrxUndoRsegsIterator::TrxUndoRsegsIterator(trx_purge_t *purge_sys)
    : m_purge_sys(purge_sys), m_iter() {
  // Constructor - purge_queue is a min-heap ordered by trx_no
}
```

### 6.4 row_purge_record() → row_purge_del_mark() — 清理标记删除

### 6.4.1 trx_purge_add_update_undo_to_history() — 将 update undo 加入 history

事务提交时，update undo log 被放入 rseg 的 history list 中。这是 purge 线程后续扫描的数据结构：

```c
// trx0purge.cc:352-430
trx_purge_add_update_undo_to_history(
    trx_t *trx, trx_undo_ptr_t *undo_ptr,
    page_t *undo_page, bool update_rseg_history_len,
    ulint n_added_logs, mtr_t *mtr)
{
  undo = undo_ptr->update_undo;
  rseg_header = trx_rsegf_get(undo->rseg->space_id, undo->rseg->page_no,
                              undo->rseg->page_size, mtr);
  undo_header = undo_page + undo->hdr_offset;

  if (undo->state != TRX_UNDO_CACHED) {
    trx_rsegf_set_nth_undo(rseg_header, undo->id, FIL_NULL, mtr);
    hist_size = mtr_read_ulint(rseg_header + TRX_RSEG_HISTORY_SIZE, ...);
    mlog_write_ulint(rseg_header + TRX_RSEG_HISTORY_SIZE,
                     hist_size + undo->size, MLOG_4BYTES, mtr);
  }

  // Add to front of rseg history list
  flst_add_first(rseg_header + TRX_RSEG_HISTORY,
                 undo_header + TRX_UNDO_HISTORY_NODE, mtr);

  // Write trx number to undo header (used by purge ordering)
  mlog_write_ull(undo_header + TRX_UNDO_TRX_NO, trx->no, mtr);
  ...
}
```

### 6.4.2 trx_purge_remove_log_hdr() — 从 history list 移除

Purge 完成后，undo log header 从 history list 中移除：

```c
// trx0purge.cc:440
static void trx_purge_remove_log_hdr(trx_rsegf_t *rseg_hdr,
                                     trx_ulogf_t *log_hdr, mtr_t *mtr) {
  flst_remove(rseg_hdr + TRX_RSEG_HISTORY,
              log_hdr + TRX_UNDO_HISTORY_NODE, mtr);
  ...
}
```

### 6.4.3 row_purge_record() → row_purge_del_mark() — 清理标记删除

Purge 节点执行 `row_purge_record_func()`，根据记录类型分发：

```c
// row0purge.cc:1074-1142
static bool row_purge_record_func(purge_node_t *node,
    trx_undo_rec_t *undo_rec) {
  ...
  switch (node->rec_type) {
    case TRX_UNDO_DEL_MARK_REC:
      purged = row_purge_del_mark(node);
      break;
    case TRX_UNDO_UPD_EXIST_REC:
    case TRX_UNDO_UPD_DEL_REC:
      row_purge_upd_exist_or_extern_func(thr, node, undo_rec);
      break;
    default:
      ut_error;
  }
  ...
}
```

`row_purge_del_mark()` 删除 delete-marked 记录的二级索引和聚簇索引：

```c
// row0purge.cc:656-700
static bool row_purge_del_mark(purge_node_t *node) {
  heap = mem_heap_create(1024, UT_LOCATION_HERE);

  while (node->index != nullptr) {
    if (node->index->type != DICT_FTS) {
      if (node->index->is_multi_value()) {
        row_purge_remove_multi_sec_if_poss(node, heap, false);
      } else {
        dtuple_t *entry = row_build_index_entry_low(
            node->row, nullptr, node->index, heap, ROW_BUILD_FOR_PURGE);
        row_purge_remove_sec_if_poss(node, node->index, entry);
      }
      mem_heap_empty(heap);
    }
    node->index = node->index->next();
  }
  mem_heap_free(heap);

  return (row_purge_remove_clust_if_poss(node));  // finally remove clustered
}
```

### 6.5 ReadView 对 purge 的约束

Purge 不能清除任何活跃 ReadView 还需要的数据。约束表现为 `m_low_limit_no`：

```c
// trx0purge.h:261
trx_id_t m_lowest_needed_trx_no;
```

计算方式在 `trx_purge_update_oldest_needed()`：

```c
// trx0purge.cc:252-273
static void trx_purge_update_oldest_needed() {
  // m_lowest_needed_trx_no = min(
  //     oldest open view's m_low_limit_no,
  //     GTID persistor's min needed trx_no
  // )
  ...
  purge_sys->m_lowest_needed_trx_no =
      std::min(oldest_view_trx_no, gtid_min_trx_no);
}
```

Purge 只清理 `trx_no < m_lowest_needed_trx_no` 的 undo log。这确保了任何活跃的快照读都能通过 undo chain 构建旧版本。

### 6.5.1 roll ptr 判断函数

```c
// trx0undo.ic
static inline bool trx_undo_roll_ptr_is_insert(roll_ptr_t roll_ptr) {
  return (roll_ptr & 0x01UL);
}
```

### 6.5.2 从 undo record 中读取 trx id

```c
// trx0rec.cc:1705-1728
const byte *trx_undo_update_rec_get_sys_cols(
    const byte *ptr, trx_id_t *trx_id,
    roll_ptr_t *roll_ptr, ulint *info_bits)
{
  *trx_id = mach_read_from_6(ptr);
  ptr += 6;
  *roll_ptr = trx_read_roll_ptr(ptr);
  ptr += 7;
  *info_bits = mach_read_from_1(ptr);
  ptr++;
  return (ptr);
}
```

### 6.5.3 cmpl_info 的读取

```c
// trx0rec.ic:45-49
static inline ulint trx_undo_rec_get_cmpl_info(
    const trx_undo_rec_t *undo_rec)
{
  return (mach_read_from_1(undo_rec + 2) / TRX_UNDO_CMPL_INFO_MULT);
}
```

---

## 7. MVCC — 一致性非锁定读

### 7.1 ReadView::prepare() — 创建读视图

当一个 `SELECT`（InnoDB 级别为 consistent read）开始时，创建 ReadView：

```c
// read0read.cc:446-470
void ReadView::prepare(trx_id_t id) {
  ut_ad(trx_sys_mutex_own());

  m_creator_trx_id = id;
  m_low_limit_no = trx_get_serialisation_min_trx_no();
  m_low_limit_id = trx_sys_get_next_trx_id_or_no();

  if (!trx_sys->rw_trx_ids.empty()) {
    copy_trx_ids(trx_sys->rw_trx_ids);      // copy active RW trx ids
  } else {
    m_ids.clear();
  }

  m_up_limit_id = !m_ids.empty() ? m_ids.front() : m_low_limit_id;
  m_closed.store(false);
}
```

`MVCC::view_open()` 创建或复用 ReadView：

```c
// read0read.cc:499-565
void MVCC::view_open(ReadView *&view, trx_t *trx) {
  ...
  view = get_view();  // from free list or new allocation
  view->prepare(trx->id);
  view->m_closed = false;

  trx_sys->serialisation_min_trx_no = ...;  // update global min
  UT_LIST_ADD_FIRST(m_views, view);
  ...
}
```

### 7.2 ReadView::changes_visible() — 判断版本可见性

此函数在 `read0types.h:109-130` 中实现，核心逻辑：

```c
bool changes_visible(trx_id_t id, const table_name_t &name) const {
  if (id < m_up_limit_id || id == m_creator_trx_id)
    return (true);          // committed or self → visible

  check_trx_id_sanity(id, name);

  if (id >= m_low_limit_id)
    return (false);         // future trx → invisible

  if (m_ids.empty())
    return (true);          // no concurrent RW → visible

  return (!std::binary_search(m_ids.data(), m_ids.data() + m_ids.size(), id));
}
```

### 7.3 row_vers_build_for_consistent_read() — 构建旧版本

当 `changes_visible()` 返回 false 时，InnoDB 通过 undo chain 构建旧版本：

```c
// row0vers.cc:1249-1330
dberr_t row_vers_build_for_consistent_read(
    const rec_t *rec, mtr_t *mtr, dict_index_t *index,
    ulint **offsets, ReadView *view, mem_heap_t **offset_heap,
    mem_heap_t *in_heap, rec_t **old_vers, ...)
{
  trx_id = row_get_rec_trx_id(rec, index, *offsets);
  ut_ad(!view->changes_visible(trx_id, index->table->name));

  version = rec;

  for (;;) {
    heap = mem_heap_create(1024, UT_LOCATION_HERE);
    
    // Use undo to build previous version
    bool purge_sees = trx_undo_prev_version_build(
        rec, mtr, version, index, *offsets, heap,
        &prev_version, nullptr, vrow, 0, lob_undo);

    if (prev_version == nullptr) {
      *old_vers = nullptr;  // freshly inserted → no old version
      break;
    }

    trx_id = row_get_rec_trx_id(prev_version, index, *offsets);

    if (view->changes_visible(trx_id, index->table->name)) {
      // Found a version visible to our snapshot → copy and return
      buf = static_cast<byte *>(mem_heap_alloc(in_heap, rec_offs_size(*offsets)));
      *old_vers = rec_copy(buf, prev_version, *offsets);
      break;
    }
    version = prev_version;  // continue walking the undo chain
  }
  ...
}
```

### 7.4 通过 undo 构建历史版本 — roll_ptr → prev version

`trx_undo_prev_version_build()` 沿着 `DB_ROLL_PTR` 链遍历 undo record：

```c
// trx0rec.cc:2500-2560
const byte *trx_undo_update_rec_get_sys_cols(
    const byte *ptr, trx_id_t *trx_id,
    roll_ptr_t *roll_ptr, ulint *info_bits)
{
  ...
  // Decode 6-byte TRX_ID
  *trx_id = mach_read_from_6(ptr);
  ptr += 6;
  // Decode 7-byte ROLL_PTR
  *roll_ptr = trx_read_roll_ptr(ptr);
  ptr += 7;
  *info_bits = mach_read_from_1(ptr);
  ptr++;
  return (ptr);
}
```

整体版本链遍历路径：

```
clustered index record
    │ DB_ROLL_PTR ──────→ undo record (version N-1)
        │ DB_ROLL_PTR in undo record ──→ undo record (version N-2)
            │ ... until changes_visible() returns true or no more undo
```

---

## 8. Undo 表空间

### 8.1 Undo tablespace 文件格式

每个 undo tablespace 独立存放为 `undo_NNN` 文件，包含：
- **Space 0 (page 0)**：FSP header
- **Page 1 (FSP_FSEG_DIR_PAGE_NUM)**：RSEG_ARRAY page（rollback segment 目录）
- **Pages 2+**：各个 rseg header pages + undo segment pages

RSEG_ARRAY page 结构：

```c
// trx0rseg.h:153-176
constexpr uint32_t RSEG_ARRAY_HEADER = FSEG_PAGE_DATA;
constexpr uint32_t RSEG_ARRAY_VERSION_OFFSET = 0;
constexpr uint32_t RSEG_ARRAY_SIZE_OFFSET = 4;
constexpr uint32_t RSEG_ARRAY_FSEG_HEADER_OFFSET = 8;
constexpr uint32_t RSEG_ARRAY_PAGES_OFFSET = 8 + FSEG_HEADER_SIZE;
constexpr uint32_t RSEG_ARRAY_SLOT_SIZE = 4;
```

### 8.2 配置参数

```c
// 通过系统变量配置
innodb_undo_directory       // undo 文件存放目录，默认 datadir
innodb_undo_tablespaces     // undo tablespace 数量（范围 1-127），默认 2
innodb_rollback_segments    // 每个 undo tablespace 的 rseg 数量（范围 1-128）
innodb_max_undo_log_size    // undo tablespace 最大大小，默认 1GB
innodb_purge_rseg_truncate_frequency // truncation 检查频率，默认 128
```

### 8.3 Undo tablespace truncation

Purge coordinator 会周期性检查是否可以 truncate undo tablespace：

```c
// trx0purge.h:363-373
namespace undo {

/** Track an UNDO tablespace marked for truncate. */
class Truncate {
 public:
  void mark(Tablespace *undo_space);     // mark space for truncate
  bool is_marked() const;               // is any space marked?
  void reset();                         // reset for next round
  space_id_t get_marked_space_num() const;
  ...
 private:
  space_id_t m_space_id_marked;
  bool m_marked_space_is_empty;
  static size_t s_scan_pos;            // round-robin scan position
};
```

truncation 流程：
1. 选择一个 undo tablespace 标记为 inactive（停止分配新事务给它）
2. 等待该 tablespace 中的所有 undo log 被 purge 清理
3. 对该 tablespace 执行物理 truncate（重建为新文件）
4. 标记为 active，继续服务

```c
// trx0undo.cc
bool trx_undo_truncate_tablespace(undo::Tablespace *marked_space);
```

### 8.4 Temporary tablespace undo

临时表的 undo 不写 Redo Log：

```c
// trx0undo.cc:1742-1744
if (no_redo) {
  mtr.set_log_mode(MTR_LOG_NO_REDO);   // MTR_LOG_NO_REDO for temp
}
```

---

## 9. 完整数据流

### 9.1 UPDATE 的数据流

```
UPDATE SET name='new' WHERE id=42
  │
  ├── 1. trx_undo_report_row_operation(TRX_UNDO_MODIFY_OP)
  │     ├── trx_undo_assign_undo(trx, rseg, TRX_UNDO_UPDATE)  // first time
  │     └── trx_undo_page_report_modify()
  │           └── Write old column values + old DB_TRX_ID + old DB_ROLL_PTR
  │                 to undo page, update TRX_UNDO_PAGE_FREE
  │
  ├── 2. btr_cur_optimistic_update() / btr_cur_pessimistic_update()
  │     └── Modify clustered index record in-place
  │           ├── Set DB_TRX_ID = trx->id
  │           └── Set DB_ROLL_PTR = encoded (is_insert=0, rseg_id, space, page, offset)
  │
  ├── 3. Transaction COMMIT
  │     ├── trx_undo_set_state_at_finish()
  │     │     └── state → TRX_UNDO_TO_PURGE (if big) or TRX_UNDO_CACHED (if small)
  │     ├── trx_undo_update_cleanup()
  │     │     └── Add to rseg->history list
  │     └── trx_purge_add_update_undo_to_history()
  │
  └── 4. Purge (background)
        ├── srv_purge_coordinator_thread() wakes up
        ├── trx_purge_attach_undo_recs() — collect undo records
        ├── Worker threads: row_purge_record_func()
        │     └── row_purge_upd_exist_or_extern_func()
        │           ├── Rebuild old index entries
        │           └── Remove outdated secondary index entries
        └── trx_purge_truncate() — truncate history + undo tablespace
```

### 9.2 SELECT 的 MVCC 数据流

```
SELECT * FROM t WHERE id=42
  │
  ├── START TRANSACTION (REPEATABLE READ)
  │     └── First SELECT: MVCC::view_open()
  │           └── ReadView::prepare(trx->id)
  │                 ├── m_low_limit_id = next trx_id
  │                 ├── m_up_limit_id = min active RW trx id
  │                 └── m_ids = copy of currently active RW trx ids
  │
  ├── btr_search_guess() / btr_pcur_open()
  │     └── Locate clustered index record for id=42
  │
  ├── row_sel_get_clust_rec_for_mysql()
  │     └── Read DB_TRX_ID from the record
  │
  ├── ReadView::changes_visible(trx_id, table_name)
  │     ├── trx_id < m_up_limit_id  → TRUE → use current version directly
  │     ├── trx_id == m_creator_trx_id → TRUE → use current version directly
  │     ├── trx_id ≥ m_low_limit_id  → FALSE → need old version
  │     └── not in m_ids → TRUE, else FALSE → need old version
  │
  ├── [if invisible] row_vers_build_for_consistent_read()
  │     ├── trx_undo_prev_version_build()
  │     │     └── Follow DB_ROLL_PTR → undo page → decode old TRX_ID/ROLL_PTR
  │     ├── Check changes_visible() on the built version
  │     └── Continue walking undo chain until visible version found
  │
  └── Return the visible version to MySQL layer
```

---

## 10. 关键函数索引

| 函数 | 文件:行 | 作用 |
|------|---------|------|
| `trx_undo_assign_undo` | `trx0undo.cc:1688` | 分配 undo log 段（新建或缓存复用） |
| `trx_undo_page_report_insert` | `trx0rec.cc:483` | 写入 INSERT undo record 到页 |
| `trx_undo_report_row_operation` | `trx0rec.cc:2116` | 通用入口：决定写 insert 还是 modify undo |
| `trx_undo_seg_create` | `trx0undo.cc:370` | 创建新的 undo segment 文件段 |
| `trx_undo_header_create` | `trx0undo.cc:512` | 创建 undo header (写入 TRX_ID, DEL_MARKS, NEXT_LOG) |
| `trx_undo_set_state_at_finish` | `trx0undo.cc:1838` | 事务结束时设置 undo segment 状态 |
| `trx_undo_add_page` | `trx0undo.cc:870` | 给 undo log 分配一个新页 |
| `trx_undo_truncate_end_func` | `trx0undo.cc:1235` | 回滚时从尾部截断 undo log |
| `trx_undo_truncate_start` | `trx0undo.cc:1305` | Purge 时从头部截断 undo log |
| `trx_undo_page_init` | `trx0undo.cc:341` | 初始化 undo 页面 |
| `trx_undo_page_truncate_offset` | `trx0undo.cc:1185` | 计算 undo 页面的截断点 |
| `trx_undo_reuse_cached` | `trx0undo.cc:*` | 复用缓存的 undo segment |
| `trx_undo_insert_cleanup` | `trx0undo.cc:*` | 提交后清理 insert undo |
| `trx_undo_update_cleanup` | `trx0undo.cc:*` | 提交后将 update undo 放入 history list |
| `trx_rollback_low` | `trx0roll.cc:181` | 回滚核心调度函数 |
| `trx_rollback_for_mysql` | `trx0roll.cc:269` | MySQL 层回滚入口 |
| `row_undo_step` | `row0undo.cc:408` | 逐条回滚调度节点 |
| `row_undo_ins` | `row0uins.cc:464` | 回滚 INSERT（删除记录） |
| `row_undo_mod` | `row0umod.cc:1274` | 回滚 UPDATE/DELETE（恢复旧版本） |
| `row_undo_mod_clust` | `row0umod.cc:*` | 修改聚簇索引回旧版本 |
| `row_undo_mod_upd_exist_sec` | `row0umod.cc:1021` | 更新已存在记录的二级索引回滚 |
| `row_undo_mod_del_mark_sec` | `row0umod.cc:*` | DELETE MARK 二级索引回滚 |
| `srv_purge_coordinator_thread` | `srv0srv.cc:3032` | Purge 协调线程主循环 |
| `trx_purge` | `trx0purge.cc:2396` | 执行一个 purge batch |
| `trx_purge_attach_undo_recs` | `trx0purge.cc:2243` | 收集待清理的 undo records |
| `trx_purge_add_update_undo_to_history` | `trx0purge.cc:352` | 将 update undo 添加到 history list |
| `trx_purge_truncate` | `trx0purge.cc:*` | 截断已提交 undo 的 history list |
| `trx_purge_truncate_rseg_history` | `trx0purge.cc:538` | 截断单个 rseg 的 history list |
| `trx_purge_update_oldest_needed` | `trx0purge.cc:252` | 计算最小的安全 trx_no |
| `trx_purge_fetch_next_rec` | `trx0purge.cc:*` | 从 min-heap 中获取下一个待清理 record |
| `row_purge_record_func` | `row0purge.cc:1074` | Purge 节点执行函数 |
| `row_purge_del_mark` | `row0purge.cc:656` | 清理 delete-marked 记录 |
| `row_purge_upd_exist_or_extern_func` | `row0purge.cc:736` | 清理已存在记录的更新 |
| `row_purge_remove_clust_if_poss` | `row0purge.cc:*` | 清理聚簇索引记录 |
| `row_purge_remove_sec_if_poss` | `row0purge.cc:*` | 清理二级索引条目 |
| `ReadView::prepare` | `read0read.cc:446` | 创建读视图 |
| `ReadView::changes_visible` | `read0types.h:109` | 判断事务 ID 是否可见 |
| `MVCC::view_open` | `read0read.cc:499` | 打开并分配 MVCC ReadView |
| `row_vers_build_for_consistent_read` | `row0vers.cc:1249` | 通过 undo chain 构建旧版本 |
| `trx_undo_prev_version_build` | `trx0rec.cc:*` | 从 undo record 构建上一版本 |
| `trx_undo_update_rec_get_sys_cols` | `trx0rec.cc:1705` | 解析 undo record 中的系统列 |
| `trx_undo_update_rec_get_update` | `trx0rec.cc:1725` | 解析 undo record 中的更新向量 |
| `trx_undo_rec_get_undo_no` | `trx0rec.ic:65` | 读取 undo record 的序号 |
| `trx_undo_rec_get_type` | `trx0rec.ic:37` | 读取 undo record 的类型 |
| `trx_undo_rec_get_pars` | `trx0rec.h:*` | 解析 undo record 的通用参数 |
| `trx_undo_rec_get_extern_storage` | `trx0rec.ic:51` | 检查是否有外部存储字段 |
| `trx_rseg_header_create` | `trx0rseg.cc:*` | 创建 rollback segment header |
| `trx_rseg_mem_create` | `trx0rseg.cc:*` | 创建 rseg 内存对象 |
| `trx_undo_truncate_tablespace` | `trx0undo.cc:*` | 物理 truncate undo tablespace |
| `trx_undo_parse_page_init` | `trx0undo.cc:320` | 解析 undo page init 的 redo 日志 |
| `trx_undo_parse_page_header` | `trx0undo.cc:847` | 解析 undo header 的 redo 日志 |
| `trx_write_roll_ptr` | `trx0undo.h:46` | 编码 roll pointer 到 7 字节 |
| `trx_read_roll_ptr` | `trx0undo.h:53` | 解码 7 字节 roll pointer |
