# 08 — InnoDB 数据页格式与行格式

> **深度解析 InnoDB 的物理存储单元：从 16KB 页到单行记录的二进制布局**
>
> 覆盖 Redundant / Compact / Dynamic / Compressed 四种行格式，页内二分查找、页面分裂、压缩页等核心机制。

---

## 0. 概述

InnoDB 的数据以 **页（Page）** 为基本单位进行管理。默认页大小为 16 KiB（可通过 `innodb_page_size` 配置），数据页承载两种核心结构：

1. **文件页头（FIL Header）** — 38 字节，描述页在表空间中的元信息
2. **索引页体（Index Page）** — 按 `PAGE_HEADER → Infimum/Supremum → 用户记录 → 空闲空间 → 页目录 → 尾部校验` 布局

行格式（Row Format）定义了单行记录在页内的物理编码方式，经历了四个阶段的演进：

| 行格式 | 引入版本 | 特点 |
|--------|----------|------|
| REDUNDANT | InnoDB 原始格式 | 6 字节额外头，字段偏移固定 1/2 字节，冗余存储 |
| COMPACT | MySQL 5.0.3 | 5 字节额外头，变长字段长度数组 + NULL 位图 |
| DYNAMIC | MySQL 5.6 | 继承 COMPACT，大字段完全溢出到 BLOB 页 |
| COMPRESSED | MySQL 5.6 | 继承 DYNAMIC，页级压缩（zlib / LZ4 / ZSTD） |

判断页是旧格式还是新格式，通过 `PAGE_N_HEAP` 的最高位（bit 15）：

```c
// file: storage/innobase/include/page0types.h:155
constexpr uint32_t PAGE_N_HEAP = 4;
// 最高位是 new-style compact page format 的标志

// file: storage/innobase/include/page0page.h:360
static inline bool page_is_comp(const page_t *page)
{
    return (page_header_get_field(page, PAGE_N_HEAP) & 0x8000);
}
```

---

## 1. 文件页头 (FIL Header)

每个 InnoDB 页的前 38 字节称为 FIL Header，以 `page_t`（即 `byte*`）开头。

### 1.1 页偏移与前后指针

```c
// file: storage/innobase/include/fil0types.h:33
/** page offset inside space */
constexpr uint32_t FIL_PAGE_OFFSET = 4;

/** if there is a 'natural' predecessor of the page, its offset */
constexpr uint32_t FIL_PAGE_PREV = 8;

/** if there is a 'natural' successor of the page, its offset */
constexpr uint32_t FIL_PAGE_NEXT = 12;
```

B-tree 索引页通过 `FIL_PAGE_PREV` 和 `FIL_PAGE_NEXT` 构成同层双向链表。注释明确写道：

```
// file: storage/innobase/include/fil0types.h:45
B-tree index pages(FIL_PAGE_TYPE contains FIL_PAGE_INDEX) on the
same PAGE_LEVEL are maintained as a doubly linked list via FIL_PAGE_PREV and
FIL_PAGE_NEXT in the collation order of the smallest user record on each
page.
```

即页之间按该页最小用户记录的排序键维护双向链表。

### 1.2 页类型 (FIL_PAGE_TYPE)

```c
// file: storage/innobase/include/fil0types.h:56
constexpr uint32_t FIL_PAGE_TYPE = 24;  // 2 bytes

// file: storage/innobase/include/fil0fil.h:1227
constexpr page_type_t FIL_PAGE_INDEX = 17855;         // B-tree 节点：0x45BF
constexpr page_type_t FIL_PAGE_RTREE = 17854;         // R-tree 节点
constexpr page_type_t FIL_PAGE_SDI = 17853;           // 表空间 SDI 索引页
constexpr page_type_t FIL_PAGE_TYPE_ALLOCATED = 0;    // 未分配页
constexpr page_type_t FIL_PAGE_UNDO_LOG = 2;           // Undo 日志页
constexpr page_type_t FIL_PAGE_INODE = 3;              // 索引节点（段管理）
constexpr page_type_t FIL_PAGE_IBUF_BITMAP = 5;        // Insert Buffer 位图
constexpr page_type_t FIL_PAGE_TYPE_BLOB = 10;         // 未压缩 BLOB 页
constexpr page_type_t FIL_PAGE_TYPE_ZBLOB = 11;        // 压缩 BLOB 首页
constexpr page_type_t FIL_PAGE_TYPE_ZBLOB2 = 12;       // 压缩 BLOB 后继页
constexpr page_type_t FIL_PAGE_COMPRESSED = 14;        // 压缩页
```

注意：`FIL_PAGE_INDEX = 17855`（`0x45BF`）这个魔术值不是随意选择的 — 旧版 InnoDB 通过该值来判断页是否已正确初始化。

### 1.3 最新 LSN

```c
// file: storage/innobase/include/fil0types.h:51
constexpr uint32_t FIL_PAGE_LSN = 16;
```

每次修改页时，Redo log 记录的末尾 LSN 会写入此字段（8 字节）。这是崩溃恢复时判断页是否需要重做的重要依据。

### 1.4 校验和与尾部

页尾（trailer）固定 8 字节：

```c
// file: storage/innobase/include/fil0types.h:82
constexpr uint32_t FIL_PAGE_END_LSN_OLD_CHKSUM = 8;  // 低 4 字节是校验和
constexpr uint32_t FIL_PAGE_DATA_END = 8;             // 尾部固定 8 字节
```

校验和算法由 `innodb_checksum_algorithm` 控制，支持 CRC32、严格 CRC32、InnoDB 旧算法等。

### 1.5 `Fil_page_header` 封装

```c
// file: storage/innobase/include/fil0types.h:113
struct Fil_page_header {
    explicit Fil_page_header(const byte *frame) : m_frame(frame) {}

    [[nodiscard]] space_id_t get_space_id() const noexcept;
    [[nodiscard]] page_no_t get_page_no() const noexcept;
    [[nodiscard]] page_no_t get_page_prev() const noexcept;
    [[nodiscard]] page_no_t get_page_next() const noexcept;
    [[nodiscard]] uint16_t get_page_type() const noexcept;
    std::ostream &print(std::ostream &out) const noexcept;

private:
    const byte *m_frame{};
};
```

---

## 2. 索引页布局 (FIL_PAGE_INDEX)

### 2.1 PAGE_HEADER 字段

索引页头从 `PAGE_HEADER`（即 `FSEG_PAGE_DATA`）开始，共 36 + 2 × `FSEG_HEADER_SIZE` 字节：

```c
// file: storage/innobase/include/page0types.h:30
typedef byte page_header_t;

constexpr uint32_t PAGE_HEADER = FSEG_PAGE_DATA;

constexpr uint32_t PAGE_N_DIR_SLOTS = 0;     // 页目录槽数 (2 bytes)
constexpr uint32_t PAGE_HEAP_TOP = 2;         // 记录堆顶部指针 (2 bytes)
constexpr uint32_t PAGE_N_HEAP = 4;           // 堆中记录数 (2 bytes, bit15=compact flag)
constexpr uint32_t PAGE_FREE = 6;             // 空闲记录链表头 (2 bytes)
constexpr uint32_t PAGE_GARBAGE = 8;          // 已删记录总字节数 (2 bytes)
constexpr uint32_t PAGE_LAST_INSERT = 10;     // 最后插入位置 (2 bytes)
constexpr uint32_t PAGE_DIRECTION = 12;       // 插入方向 (2 bytes)
constexpr uint32_t PAGE_N_DIRECTION = 14;     // 同方向连续插入次数 (2 bytes)
constexpr uint32_t PAGE_N_RECS = 16;          // 用户记录数 (2 bytes)
constexpr uint32_t PAGE_MAX_TRX_ID = 18;      // 最大修改事务 ID (8 bytes)
constexpr uint32_t PAGE_LEVEL = 26;           // B-tree 层数 (2 bytes, leaf=0)
constexpr uint32_t PAGE_INDEX_ID = 28;        // 索引 ID (8 bytes)
constexpr uint32_t PAGE_BTR_SEG_LEAF = 36;    // 叶子段文件段头 (FSEG_HEADER_SIZE)
constexpr uint32_t PAGE_BTR_SEG_TOP = 36 + FSEG_HEADER_SIZE; // 非叶子段头

constexpr uint32_t PAGE_DATA = PAGE_HEADER + 36 + 2 * FSEG_HEADER_SIZE;
```

`PAGE_LEVEL` 仅在 B-tree 非叶节点上 > 0；叶节点恒为 0。`PAGE_INDEX_ID` 标识该页属于哪个索引。

插入方向追踪是 InnoDB 的顺序插入优化：

```c
// file: storage/innobase/include/page0types.h:128
enum cursor_direction_t : uint8_t {
    PAGE_LEFT = 1,
    PAGE_RIGHT = 2,
    PAGE_SAME_REC = 3,
    PAGE_SAME_PAGE = 4,
    PAGE_NO_DIRECTION = 5
};
```

### 2.2 Infimum / Supremum 伪记录

每一页都有两条系统伪记录：Infimum（最小值）和 Supremum（最大值）。它们位于用户数据区域的开头：

```c
// file: storage/innobase/include/page0types.h:91
constexpr uint32_t PAGE_DATA = PAGE_HEADER + 36 + 2 * FSEG_HEADER_SIZE;

#define PAGE_NEW_INFIMUM  (PAGE_DATA + REC_N_NEW_EXTRA_BYTES)
#define PAGE_NEW_SUPREMUM (PAGE_DATA + 2 * REC_N_NEW_EXTRA_BYTES + 8)
#define PAGE_NEW_SUPREMUM_END (PAGE_NEW_SUPREMUM + 8)

#define PAGE_OLD_INFIMUM  (PAGE_DATA + 1 + REC_N_OLD_EXTRA_BYTES)
#define PAGE_OLD_SUPREMUM (PAGE_DATA + 2 + 2 * REC_N_OLD_EXTRA_BYTES + 8)
#define PAGE_OLD_SUPREMUM_END (PAGE_OLD_SUPREMUM + 9)
```

它们在 `page_create_low` 时被写入：

```c
// file: storage/innobase/page/page0page.cc:285
static const byte infimum_supremum_redundant[] = {
    /* the infimum record */
    0x08 /*end offset*/, 0x01 /*n_owned*/, 0x00, 0x00 /*heap_no=0*/,
    0x03 /*n_fields=1, 1-byte offsets*/, 0x00, 0x74 /* pointer to supremum */,
    'i', 'n', 'f', 'i', 'm', 'u', 'm', 0,
    /* the supremum record */
    0x09 /*end offset*/, 0x01 /*n_owned*/, 0x00, 0x08 /*heap_no=1*/,
    0x03 /*n_fields=1, 1-byte offsets*/, 0x00, 0x00 /* end of record list */,
    's', 'u', 'p', 'r', 'e', 'm', 'u', 'm', 0};

// file: storage/innobase/page/page0page.cc:296
static const byte infimum_supremum_compact[] = {
    /* the infimum record */
    0x01 /*n_owned=1*/, 0x00, 0x02 /* heap_no=0, REC_STATUS_INFIMUM */, 0x00,
    0x0d /* pointer to supremum */, 'i', 'n', 'f', 'i', 'm', 'u', 'm', 0,
    /* the supremum record */
    0x01 /*n_owned=1*/, 0x00, 0x0b /* heap_no=1, REC_STATUS_SUPREMUM */, 0x00,
    0x00 /* end of record list */, 's', 'u', 'p', 'r', 'e', 'm', 'u', 'm'};
```

注意两者的差异：
- REDUNDANT 格式：infimum 记录有 8+6=14 字节，supremum 有 9+6=15 字节
- COMPACT 格式：各 5+8=13 字节（无 `REC_N_OLD_EXTRA_BYTES` 中的字段数/偏移标志位）

### 2.3 用户记录区域

紧接伪记录之后的是用户记录。每条记录的布局见下文「记录格式」章节。记录的物理位置由 `PAGE_HEAP_TOP` 指针追踪，新的分配从该指针处增长：

```c
// file: storage/innobase/include/page0page.h:233
byte *page_mem_alloc_heap(
    page_t *page,
    page_zip_des_t *page_zip,
    ulint need,
    ulint *heap_no);
```

### 2.4 空闲空间

有两种空闲空间管理方式：

**Heap 分配** — 从 `PAGE_HEAP_TOP` 向上增长：

```
[FIL_HDR][PAGE_HDR][Infimum][Supremum][User Recs ... ↑] [Free Space] [↑ Page Directory][Trailer]
```

**Free List** — 已删除并移入空闲链表的记录，通过 `PAGE_FREE` 指向链表头：

```c
// file: storage/innobase/include/page0page.h:247
static inline void page_mem_alloc_free(
    page_t *page,
    page_zip_des_t *page_zip,
    rec_t *next_rec,
    ulint need);
```

`PAGE_GARBAGE` 记录因删除而浪费的总字节数（碎片空间），在 `OPTIMIZE TABLE` 或页重组时回收。

### 2.5 页目录 (Page Directory)

页目录从页尾向页内生长（从 `FIL_PAGE_DATA_END` 向下偏移）：

```c
// file: storage/innobase/include/page0page.h:39
constexpr uint32_t PAGE_DIR = FIL_PAGE_DATA_END;       // 8
constexpr uint32_t PAGE_DIR_SLOT_SIZE = 2;             // 每个槽 2 字节
constexpr uint32_t PAGE_EMPTY_DIR_START = PAGE_DIR + 2 * PAGE_DIR_SLOT_SIZE;
```

### 2.6 尾部校验

```c
// file: storage/innobase/include/fil0types.h:82
constexpr uint32_t FIL_PAGE_END_LSN_OLD_CHKSUM = 8;
```

尾部 8 字节：低 4 字节为页校验和，高 4 字节应与 `FIL_PAGE_LSN` 的低 4 字节一致。

---

## 3. 页目录 (Page Directory)

### 3.1 页目录槽结构

每个目录槽 2 字节，指向该槽所拥有记录链中最后（即排序最大）的那条记录：

```c
// file: storage/innobase/include/page0page.h:39
typedef byte page_dir_slot_t;
typedef page_dir_slot_t page_dir_t;

// file: storage/innobase/include/page0page.h:291
static inline const rec_t *page_dir_slot_get_rec(
    const page_dir_slot_t *slot)
{
    return (page + mach_read_from_2(slot));
}

// file: storage/innobase/include/page0page.h:297
static inline ulint page_dir_slot_get_n_owned(
    const page_dir_slot_t *slot)
{
    return (mach_read_from_1(slot - PAGE_DIR_SLOT_SIZE));
}
```

每个槽拥有 4–8 条记录：

```c
// file: storage/innobase/include/page0page.h:49
constexpr uint32_t PAGE_DIR_SLOT_MAX_N_OWNED = 8;
constexpr uint32_t PAGE_DIR_SLOT_MIN_N_OWNED = 4;
```

第一个和最后一个槽（分别指向 Infimum 和 Supremum）允许少于 4 条。

### 3.2 二分查找流程

`page_cur_search_with_match` 是 InnoDB 页内查找的核心函数。它分两步：

1. **通过页目录二分查找** — 在 `[0, n_slots-1]` 之间二分
2. **在线性扫描精确定位** — 在目标槽的链中线性扫描

```c
// file: storage/innobase/page/page0cur.cc:328
void page_cur_search_with_match(const buf_block_t *block,
                                const dict_index_t *index,
                                const dtuple_t *tuple, page_cur_mode_t mode,
                                ulint *iup_matched_fields,
                                ulint *ilow_matched_fields,
                                page_cur_t *cursor, rtr_info_t *rtr_info)
{
    ulint up;
    ulint low;
    ulint mid;
    const page_t *page;
    const page_dir_slot_t *slot;
    const rec_t *up_rec;
    const rec_t *low_rec;
    const rec_t *mid_rec;
    int cmp = 0;
    // ...

    /* Perform binary search. First the search is done through the page
    directory, after that as a linear search in the list of records
    owned by the upper limit directory slot. */
    low = 0;
    up = page_dir_get_n_slots(page) - 1;
    // ...

    /* Start binary search on page directory.
    We need to begin the search from low, up as above */
    while (up - low > 0) {
        mid = (low + up) / 2;
        // ...
    }
    // Then linear search within the slot's owned records
}
```

二分查找的模式枚举：

```c
// file: storage/innobase/include/page0types.h:146
enum page_cur_mode_t {
    PAGE_CUR_UNSUPP = 0,
    PAGE_CUR_G = 1,     // 大于（greater than）
    PAGE_CUR_GE = 2,    // 大于等于
    PAGE_CUR_L = 3,     // 小于（less than）
    PAGE_CUR_LE = 4,    // 小于等于
    PAGE_CUR_CONTAIN = 7,
    PAGE_CUR_INTERSECT = 8,
    // ...
};
```

### 3.3 自适应搜索优化

InnoDB 还有一个短路径优化 — 如果最近 3 次插入都是向右的（`PAGE_DIRECTION == PAGE_RIGHT`），且 `PAGE_LAST_INSERT` 指针仍有效，则尝试从最后插入位置开始比较：

```c
// file: storage/innobase/page/page0cur.cc:387
#ifdef PAGE_CUR_ADAPT
    if (page_is_leaf(page) && (mode == PAGE_CUR_LE) &&
        !dict_index_is_spatial(index) &&
        (page_header_get_field(page, PAGE_N_DIRECTION) > 3) &&
        (page_header_get_ptr(page, PAGE_LAST_INSERT)) &&
        (page_header_get_field(page, PAGE_DIRECTION) == PAGE_RIGHT))
    {
        if (page_cur_try_search_shortcut(block, index, tuple, iup_matched_fields,
                                         ilow_matched_fields, cursor)) {
            return;
        }
    }
#endif
```

### 3.4 槽分裂与合并

当槽的 `n_owned` 超过 `PAGE_DIR_SLOT_MAX_N_OWNED`（8）时触发分裂：

```c
// file: storage/innobase/page/page0page.cc:1283
void page_dir_split_slot(page_t *page, page_zip_des_t *page_zip,
                         ulint slot_no)
{
    slot = page_dir_get_nth_slot(page, slot_no);
    n_owned = page_dir_slot_get_n_owned(slot);
    ut_ad(n_owned == PAGE_DIR_SLOT_MAX_N_OWNED + 1);

    /* 1. Find the middle record owned by the slot */
    prev_slot = page_dir_get_nth_slot(page, slot_no - 1);
    rec = (rec_t *)page_dir_slot_get_rec(prev_slot);
    for (i = 0; i < n_owned / 2; i++) {
        rec = page_rec_get_next(rec);
    }

    /* 2. Add a new directory slot */
    page_dir_add_slot(page, page_zip, slot_no - 1);

    /* 3. Set the new slot to point to the middle record */
    page_dir_slot_set_rec(new_slot, rec);
    page_dir_slot_set_n_owned(new_slot, page_zip, n_owned / 2);

    /* 4. Update the old slot's owned count */
    page_dir_slot_set_n_owned(slot, page_zip, n_owned - (n_owned / 2));
}
```

当槽的记录数少于 `PAGE_DIR_SLOT_MIN_N_OWNED`（4）时调用 `page_dir_balance_slot` 进行平衡（可能合并）。

---

## 4. 记录格式 (REC)

### 4.1 REDUNDANT 行格式（旧格式）

REDUNDANT 格式的记录有 6 字节额外头（`REC_N_OLD_EXTRA_BYTES`）：

```c
// file: rem/rec.h:50
/**
Extra Bytes in Redudant Row Format:

  byte 6    byte 5    byte 4    byte 3    byte 2    byte 1
[iiiioooo][hhhhhhhh][hhhhhfff][fffffffs][pppppppp][pppppppp]+

1. The + is the record origin.
2. The next record pointer is given by the bits marked as 'p'.  This takes
   2 bytes - 1st and 2nd byte.
3. One bit is used to indicate whether the field offsets array uses 1 byte or
   2 bytes each.  This is given by the bit 's' in 3rd byte.
4. The total number of fields is given by the bits marked as 'f'.  It spans
   the 4th and 3rd bytes.  It uses a total of 10 bits.
5. The heap number of the record is given by the bits marked as 'h'.  It spans
   the 5th and 4th bytes.  It uses a total of 13 bits.
6. The record owned (by dir slot) information is given by bits marked as 'o'.
   It uses a total of 4 bits. It is available in the 6th byte.
7. The info bits are given by the bits marked as 'i'.  It uses a total of 4
   bits. It is available in the 6th byte.
*/

constexpr uint32_t REC_N_OLD_EXTRA_BYTES = 6;
```

位域操作的常用宏：

```c
// file: rem/rec.h:90
constexpr uint32_t REC_NEXT = 2;
constexpr uint32_t REC_NEXT_MASK = 0xFFFFUL;
constexpr uint32_t REC_NEXT_SHIFT = 0;

constexpr uint32_t REC_OLD_SHORT = 3;
constexpr uint32_t REC_OLD_SHORT_MASK = 0x1UL;

constexpr uint32_t REC_OLD_N_FIELDS = 4;
constexpr uint32_t REC_OLD_N_FIELDS_MASK = 0x7FEUL;
constexpr uint32_t REC_OLD_N_FIELDS_SHIFT = 1;

constexpr uint32_t REC_OLD_HEAP_NO = 5;
constexpr uint32_t REC_HEAP_NO_MASK = 0xFFF8UL;

constexpr uint32_t REC_OLD_N_OWNED = 6;
constexpr uint32_t REC_N_OWNED_MASK = 0xFUL;

constexpr uint32_t REC_OLD_INFO_BITS = 6;
constexpr uint32_t REC_INFO_BITS_MASK = 0xF0UL;
```

REDUNDANT 的字段偏移数组：紧接在 6 字节额外头之后。`REC_OLD_SHORT` 位控制每个偏移量用 1 字节还是 2 字节：

```c
// file: rem/rec.h:259
static inline bool rec_get_1byte_offs_flag(const rec_t *rec)
{
    return (rec_get_bit_field_1(rec, REC_OLD_SHORT, REC_OLD_SHORT_MASK,
                                REC_OLD_SHORT_SHIFT));
}
```

如果 `REC_1BYTE_OFFS_LIMIT = 0x7F` 且实际数据长度大于 127 字节，则自动使用 2 字节偏移。

### 4.2 COMPACT 行格式（新格式）

COMPACT（也是 DYNAMIC / COMPRESSED 的基础）格式的额外头减少到 5 字节：

```c
// file: rem/rec.h:80
constexpr int32_t REC_N_NEW_EXTRA_BYTES = 5;
```

COMPACT 记录布局：

```
+-------+-------+-------+-------+-------+--------+--------+----------+------+
| n_own | heap  | status| info  | next  |   NULL  |  var-len |  field  | ...  |
|  ed   | _no   |       | _bits | _offs |   bitmap|  length  |  data   |      |
| 1 byte| 2 byte| 1 byte| 1 byte| 2 byte|  n bytes|  n bytes |         |      |
+-------+-------+-------+-------+-------+--------+----------+----------+------+
|<-             REC_N_NEW_EXTRA_BYTES  = 5             ->|<--- data --->|
```

新格式的位域分布：

```c
// file: rem/rec.h:70
constexpr uint32_t REC_NEW_HEAP_NO = 4;
constexpr uint32_t REC_HEAP_NO_SHIFT = 3;

constexpr uint32_t REC_NEW_STATUS = 3;
constexpr uint32_t REC_NEW_STATUS_MASK = 0x7UL;

constexpr uint32_t REC_NEW_N_OWNED = 5;
constexpr uint32_t REC_NEW_INFO_BITS = 5;

constexpr uint32_t REC_INFO_BITS_MASK = 0xF0UL;
```

Recrod status 值：

```c
// file: rem/rec.h:114
constexpr uint32_t REC_STATUS_ORDINARY = 0;   // 普通用户记录
constexpr uint32_t REC_STATUS_NODE_PTR = 1;   // B-tree 节点指针（非叶子页）
constexpr uint32_t REC_STATUS_INFIMUM = 2;    // Infimum 伪记录
constexpr uint32_t REC_STATUS_SUPREMUM = 3;   // Supremum 伪记录
```

`rec_get_status` 实现：

```c
// file: rem/rec.h:171
static inline ulint rec_get_status(const rec_t *rec)
{
    ulint ret;
    ret = rec_get_bit_field_1(rec, REC_NEW_STATUS, REC_NEW_STATUS_MASK,
                              REC_NEW_STATUS_SHIFT);
    return (ret);
}
```

### 4.3 DYNAMIC 行格式（默认）

从 MySQL 5.6 起 `DYNAMIC` 是默认行格式。它完全继承 COMPACT 的额外头和 NULL 位图/变长字段编码，唯一的区别在于 **大字段的处理**：

- COMPACT：大字段（如 TEXT/BLOB）在行内存储 768 字节前缀，剩余部分溢出到 BLOB 页
- DYNAMIC：大字段完全溢出（可能存 0 字节行内），仅在行内存储 20 字节的 BLOB 指针

溢出标记在 `rec_get_offsets()` 返回的偏移数组中通过 `REC_OFFS_EXTERNAL` 位标识：

```c
// file: rem/rec.h:49
constexpr uint32_t REC_OFFS_EXTERNAL = 1 << 30;
```

### 4.4 COMPRESSED 行格式

继承 DYNAMIC，额外添加 zlib（或 LZ4/ZSTD）页级压缩。压缩失败时自动增加 padding：

```c
// file: storage/innobase/include/dict0mem.h:937
constexpr uint32_t ZIP_PAD_ROUND_LEN = 128;
constexpr uint32_t ZIP_PAD_SUCCESSFUL_ROUND_LIMIT = 5;
constexpr uint32_t ZIP_PAD_INCR = 128;
```

压缩页使用 `page_zip_des_t` 管理：

```c
// file: storage/innobase/include/page0types.h:167
struct page_zip_des_t {
    page_zip_t *data;           // 压缩后的页数据
    uint16_t m_start;           // 修改日志起始偏移
    uint16_t m_end;             // 修改日志结束偏移
    uint16_t n_blobs;           // 外部存储列数（最大 744 on 16K）
    bool m_nonempty;            // 修改日志非空
    uint8_t ssize;              // 压缩页 shift size (0 或 512/1024/2048/4096/8192/16384)
};
```

### 4.5 系统列

每个聚簇索引的记录都包含三个系统列（在用户定义的字段之后）：

```c
// file: storage/innobase/include/data0type.h:153
constexpr uint32_t DATA_ROW_ID = 0;
constexpr uint32_t DATA_ROW_ID_LEN = 6;       // 6 字节行 ID（仅当无用户定义主键时）

constexpr size_t DATA_TRX_ID = 1;
constexpr size_t DATA_TRX_ID_LEN = 6;          // 6 字节事务 ID

constexpr size_t DATA_ROLL_PTR = 2;
constexpr size_t DATA_ROLL_PTR_LEN = 7;        // 7 字节回滚指针

constexpr uint32_t DATA_N_SYS_COLS = 3;        // 系统列数
```

`DB_TRX_ID` 读取函数：

```c
// file: storage/innobase/include/rem0rec.h:380
trx_id_t rec_get_trx_id(const rec_t *rec, const dict_index_t *index);
```

---

## 5. 记录头信息

### 5.1 下一条记录偏移 (rec_get_next_offs)

```c
// file: storage/innobase/include/rem0rec.h:50
static inline ulint rec_get_next_offs(const rec_t *rec, ulint comp)
{
    if (comp) {
        return (rec_get_bit_field_2(rec, REC_NEXT, REC_NEXT_MASK,
                                    REC_NEXT_SHIFT));
    } else {
        return (rec_get_bit_field_2(rec, REC_NEXT, REC_NEXT_MASK,
                                    REC_NEXT_SHIFT));
    }
}
```

注意：偏移量是从页起始计算的绝对值，因此可以通过 `page + next_offs` 直接定位到下一条记录。

设置下一条记录：

```c
// file: storage/innobase/include/rem0rec.h:60
static inline void rec_set_next_offs_old(rec_t *rec, ulint next)
{
    mach_write_to_2(rec - REC_NEXT, next);
}

static inline void rec_set_next_offs_new(rec_t *rec, ulint next)
{
    mach_write_to_2(rec - REC_NEXT, next);
}
```

### 5.2 类型标志 (info_bits)

```c
// file: rem/rec.h:107
constexpr uint32_t REC_INFO_MIN_REC_FLAG = 0x10UL;    // 最小记录标志（非叶左兄弟页的首条记录）
constexpr uint32_t REC_INFO_DELETED_FLAG = 0x20UL;     // 已删除标记
constexpr uint32_t REC_INFO_VERSION_FLAG = 0x40UL;     // 记录版本标志（Instant DDL）
constexpr uint32_t REC_INFO_INSTANT_FLAG = 0x80UL;     // Instant ADD COLUMN 标志
```

info_bits 的 4 位分布在字节的高 4 位：

```c
// file: rem/rec.h:195
static inline ulint rec_get_info_bits(const rec_t *rec, ulint comp)
{
    const ulint val =
        rec_get_bit_field_1(rec, comp ? REC_NEW_INFO_BITS : REC_OLD_INFO_BITS,
                            REC_INFO_BITS_MASK, REC_INFO_BITS_SHIFT);
    ut_ad(rec_info_bits_valid(val));
    return (val);
}
```

### 5.3 变长字段长度数组编码

COMPACT/DYNAMIC 使用 NULL 位图后跟变长字段长度数组的描述：

```c
// file: rem/rec.h:631
inline void rec_init_offsets_comp_ordinary(const rec_t *rec, bool temp,
                                           const dict_index_t *index,
                                           ulint *offsets)
{
    // ...
    /* 读取字段长度。
       如果字段的最大长度 ≤ 255 字节，用一个字节存长度。
       如果最大长度 > 255 字节：
         - 长度 0–127：一个字节
         - 长度 ≥ 128 或外部存储：两个字节（高 2 位是标志位） */
    if (DATA_BIG_COL(col)) {
        if (len & 0x80) {
            /* 1exxxxxxx xxxxxxxx */
            len <<= 8;
            len |= *lens--;
            offs += len & 0x3fff;
            if (UNIV_UNLIKELY(len & 0x4000)) {
                ut_ad(index->is_clustered());
                any_ext = REC_OFFS_EXTERNAL;
                len = offs | REC_OFFS_EXTERNAL;
            } else {
                len = offs;
            }
            goto resolved;
        }
    }
    len = offs += len;
}
```

一个字段的外部存储标志通过 `REC_2BYTE_EXTERN_MASK` 检查：

```c
// file: rem/rec.h:121
constexpr uint32_t REC_2BYTE_EXTERN_MASK = 0x4000UL;
```

---

## 6. 页面操作

### 6.1 page_create() — 创建新页

`page_create` 是 `page_create_low` + redo 日志写入的封装：

```c
// file: storage/innobase/page/page0page.cc:374
page_t *page_create(buf_block_t *block, mtr_t *mtr, ulint comp,
                    page_type_t page_type) {
    page_create_write_log(buf_block_get_frame(block), mtr, comp, page_type);
    return (page_create_low(block, comp, page_type));
}
```

`page_create_low` 完成真正的初始化：

```c
// file: storage/innobase/page/page0page.cc:309
page_t *page_create_low(buf_block_t *block, ulint comp, page_type_t page_type)
{
    page_t *page;
    buf_block_modify_clock_inc(block);
    page = buf_block_get_frame(block);

    fil_page_set_type(page, page_type);

    memset(page + PAGE_HEADER, 0, PAGE_HEADER_PRIV_END);
    page[PAGE_HEADER + PAGE_N_DIR_SLOTS + 1] = 2;     // 初始 2 个槽
    page[PAGE_HEADER + PAGE_DIRECTION + 1] = PAGE_NO_DIRECTION;

    if (comp) {
        page[PAGE_HEADER + PAGE_N_HEAP] = 0x80;        // 设置 compact 标志位
        page[PAGE_HEADER + PAGE_N_HEAP + 1] = PAGE_HEAP_NO_USER_LOW;
        page[PAGE_HEADER + PAGE_HEAP_TOP + 1] = PAGE_NEW_SUPREMUM_END;
        memcpy(page + PAGE_DATA, infimum_supremum_compact,
               sizeof infimum_supremum_compact);
        // 初始页目录：2 个槽，分别指向 supremum（槽 0）和 infimum（槽 1）
        page[UNIV_PAGE_SIZE - PAGE_DIR - PAGE_DIR_SLOT_SIZE * 2 + 1] = PAGE_NEW_SUPREMUM;
        page[UNIV_PAGE_SIZE - PAGE_DIR - PAGE_DIR_SLOT_SIZE + 1] = PAGE_NEW_INFIMUM;
    } else {
        // REDUNDANT: 无 0x80 标志位
        page[PAGE_HEADER + PAGE_N_HEAP + 1] = PAGE_HEAP_NO_USER_LOW;
        page[PAGE_HEADER + PAGE_HEAP_TOP + 1] = PAGE_OLD_SUPREMUM_END;
        memcpy(page + PAGE_DATA, infimum_supremum_redundant,
               sizeof infimum_supremum_redundant);
        page[UNIV_PAGE_SIZE - PAGE_DIR - PAGE_DIR_SLOT_SIZE * 2 + 1] = PAGE_OLD_SUPREMUM;
        page[UNIV_PAGE_SIZE - PAGE_DIR - PAGE_DIR_SLOT_SIZE + 1] = PAGE_OLD_INFIMUM;
    }
    return (page);
}
```

### 6.2 page_cur_insert_rec() — 记录插入

`page_cur_insert_rec_low` 是插入的核心实现：

```c
// file: storage/innobase/page/page0cur.cc:1229
rec_t *page_cur_insert_rec_low(
    rec_t *current_rec, dict_index_t *index,
    const rec_t *rec, ulint *offsets, mtr_t *mtr)
{
    byte *insert_buf;
    ulint rec_size;
    rec_t *free_rec;
    rec_t *insert_rec;
    ulint heap_no;

    page = page_align(current_rec);

    /* 1. 计算物理记录大小 */
    rec_size = rec_offs_size(offsets);

    /* 2. 尝试从空闲链表分配 */
    free_rec = page_header_get_ptr(page, PAGE_FREE);
    if (UNIV_LIKELY_NULL(free_rec)) {
        // 检查空闲记录是否足够大
        if (rec_offs_size(foffsets) < rec_size) goto use_heap;
        insert_buf = free_rec - rec_offs_extra_size(foffsets);
        heap_no = ...;
        page_mem_alloc_free(page, nullptr, rec_get_next_ptr(free_rec, ...), rec_size);
    } else {
    use_heap:
        insert_buf = page_mem_alloc_heap(page, nullptr, rec_size, &heap_no);
        if (UNIV_UNLIKELY(insert_buf == nullptr)) return (nullptr);
    }

    /* 3. 复制记录 */
    insert_rec = rec_copy(insert_buf, rec, offsets);

    /* 4. 插入链表 */
    rec_t *next_rec = page_rec_get_next(current_rec);
    page_rec_set_next(insert_rec, next_rec);
    page_rec_set_next(current_rec, insert_rec);

    page_header_set_field(page, nullptr, PAGE_N_RECS,
                          1 + page_get_n_recs(page));

    /* 5. 设置 n_owned = 0 和 heap_no */
    rec_set_n_owned_new(insert_rec, nullptr, 0);
    rec_set_heap_no_new(insert_rec, heap_no);

    /* 6. 更新最后插入信息 */
    last_insert = page_header_get_ptr(page, PAGE_LAST_INSERT);
    if (last_insert == current_rec && PAGE_DIRECTION != PAGE_LEFT) {
        page_header_set_field(page, nullptr, PAGE_DIRECTION, PAGE_RIGHT);
    } else if (...) {
        // ... 类似逻辑追踪 PAGE_LEFT
    }
    page_header_set_ptr(page, nullptr, PAGE_LAST_INSERT, insert_rec);

    /* 7. 更新 owner 记录的 n_owned 计数 */
    owner_rec = page_rec_find_owner_rec(insert_rec);
    n_owned = rec_get_n_owned_new(owner_rec);
    rec_set_n_owned_new(owner_rec, nullptr, n_owned + 1);

    /* 8. 如果超过 8 条，分裂目录槽 */
    if (UNIV_UNLIKELY(n_owned == PAGE_DIR_SLOT_MAX_N_OWNED)) {
        page_dir_split_slot(page, nullptr, page_dir_find_owner_slot(owner_rec));
    }

    // 9. 写 redo 日志
    if (UNIV_LIKELY(mtr != nullptr)) {
        page_cur_insert_rec_write_log(insert_rec, rec_size, current_rec, index, mtr);
    }

    return (insert_rec);
}
```

### 6.3 page_cur_delete_rec() — 记录删除

```c
// file: storage/innobase/page/page0cur.cc:2307
void page_cur_delete_rec(
    page_cur_t *cursor, const dict_index_t *index,
    const ulint *offsets, mtr_t *mtr)
{
    page_t *page = page_cur_get_page(cursor);
    rec_t *current_rec = cursor->rec;

    ut_ad(page_rec_is_user_rec(current_rec));

    // 特殊情况：只剩一条用户记录时清空整页
    if (page_get_n_recs(page) == 1 && !recv_recovery_is_on()) {
        page_cur_move_to_next(cursor);
        page_create_empty(page_cur_get_block(cursor),
                          const_cast<dict_index_t *>(index), mtr);
        return;
    }

    /* 1. 找 owner 槽，更新 n_owned 计数 */
    cur_slot_no = page_dir_find_owner_slot(current_rec);
    cur_dir_slot = page_dir_get_nth_slot(page, cur_slot_no);
    cur_n_owned = page_dir_slot_get_n_owned(cur_dir_slot);

    // 2. 写日志
    page_cur_delete_rec_write_log(current_rec, index, mtr);

    // 3. 重置最后插入信息
    page_header_set_ptr(page, page_zip, PAGE_LAST_INSERT, nullptr);

    // 4. 从链表中移除，放入空闲列表
    prev_rec = page_rec_get_prev(current_rec);
    next_rec = page_rec_get_next(current_rec);
    page_rec_set_next(prev_rec, next_rec);

    page_mem_free(page, page_zip, current_rec, index, offsets);

    // 5. 更新 n_owned，如果低于最小则平衡槽
    page_dir_slot_set_n_owned(cur_dir_slot, page_zip, cur_n_owned - 1);
    if (cur_n_owned - 1 < PAGE_DIR_SLOT_MIN_N_OWNED) {
        page_dir_balance_slot(page, page_zip, cur_slot_no);
    }

    // 6. 更新 PAGE_N_RECS
    page_header_set_field(page, page_zip, PAGE_N_RECS,
                          page_get_n_recs(page) - 1);

    // 7. 移动光标到后继记录
    page_cur_position(next_rec, page_cur_get_block(cursor), cursor);
}
```

### 6.4 page_copy_rec_list_end() — 分裂时的记录复制

```c
// file: storage/innobase/include/page0page.h:184
rec_t *page_copy_rec_list_end(
    buf_block_t *new_block, buf_block_t *block,
    rec_t *rec, dict_index_t *index, mtr_t *mtr);
```

此函数从 `rec` 开始（包括 `rec`）将记录复制到 `new_block` 的记录列表开头。在 B-tree 页分裂时由 `btr_page_split_and_insert` 调用。

配套函数也有 `page_copy_rec_list_start`（复制从 infimum 到 rec 之前）和 `page_move_rec_list_end`（移动而非复制）。

---

## 7. 列存储 (dtuple / dfield)

### 7.1 dtuple_t — 数据元组

`dtuple_t` 是 InnoDB 层用于在内存中操作行数据的抽象：

```c
// 结构定义在 data0data.h / data0tuple.h
struct dtuple_t {
    dict_index_t *index;   // 所属索引（可能为 NULL）
    ulint n_fields;       // 字段数
    ulint n_v_fields;     // 虚拟字段数
    dfield_t *fields;     // 字段数组
    dfield_t *v_fields;   // 虚拟字段数组
    ulint info_bits;      // 信息位（DELETED / INSTANT / VERSION 等）
};
```

### 7.2 dfield_t — 单个列数据

```c
struct dfield_t {
    void *data;           // 列数据指针
    ulint len;            // 数据长度（UNIV_SQL_NULL 表示 SQL NULL）
    dtype_t *type;        // 数据类型描述
    ulint ext : 1;        // 外部存储标志
};
```

### 7.3 大字段溢出：BLOB 页

当记录中某个变长字段大小超过阈值时，InnoDB 将其部分或全部量存储在单独的 BLOB 页中：

```c
// file: storage/innobase/include/rem0rec.h:160
static inline bool rec_offs_any_extern(const ulint *offsets)
{
    return (*rec_offs_base(offsets) & REC_OFFS_EXTERNAL);
}
```

BLOB 页的类型包括：

```c
// file: storage/innobase/include/fil0fil.h:1267
constexpr page_type_t FIL_PAGE_TYPE_BLOB = 10;     // 未压缩 BLOB 页
constexpr page_type_t FIL_PAGE_TYPE_ZBLOB = 11;    // 压缩 BLOB 首页
constexpr page_type_t FIL_PAGE_TYPE_ZBLOB2 = 12;   // 压缩 BLOB 后继页
```

DYNAMIC 格式中，行内 BLOB 指针的结构为：

```
+------+------+------+------+------+------+------+------+------+------+
| len  | len  | spc  | spc  | pgno | pgno | pgno | pgno | offs | offs |
| hi   | lo   | hi   | lo   | hi      ...      lo | hi   | lo   |
+------+------+------+------+------+------+------+------+------+------+
  1 B    1 B    2 B    2 B    4 B (page number)        2 B (offset within page)
                  \________________20 bytes total___________________/
```

---

## 8. 压缩页

### 8.1 page_zip_des_t — 压缩页结构设计

```c
// file: storage/innobase/include/page0types.h:167
struct page_zip_des_t {
    page_zip_t *data;     // 压缩页数据指针
    uint16_t m_start;     // 修改日志开始偏移
    uint16_t m_end;       // 修改日志结束偏移
    uint16_t n_blobs;     // 外部存储列数
    bool m_nonempty;      // 日志非空标志
    uint8_t ssize;        // 压缩页 shift size
};
```

压缩页的工作机制：
1. 修改先在未压缩的 `page_t` 上执行（`buf_block_get_frame`）
2. 同时记录修改日志到 `m_start` 到 `m_end` 的区域
3. `page_zip_compress()` 在事务提交时执行真正的压缩

```c
// file: storage/innobase/include/page0zip.h:121
bool page_zip_compress(page_zip_des_t *page_zip, page_t *page,
                       dict_index_t *index, ulint level, mtr_t *mtr);
```

### 8.2 压缩页插入

```c
// file: storage/innobase/include/page0cur.h:118
rec_t *page_cur_insert_rec_zip(
    page_cur_t *cursor, dict_index_t *index,
    const rec_t *rec, ulint *offsets, mtr_t *mtr);
```

压缩页的页目录使用密集格式（dense page directory），而不是未压缩页的稀疏格式：

```c
// file: storage/innobase/include/page0types.h:214
void page_zip_dir_add_slot(page_zip_des_t *page_zip, bool is_clustered);
void page_zip_dir_delete(page_zip_des_t *page_zip, byte *rec,
                         dict_index_t *index, const ulint *offsets,
                         const byte *free);
```

压缩页大小通过 `ssize` 表示（`UNIV_ZIP_SIZE_MIN = 512`，ssize=1 表示 1K，ssize=2 表示 2K...）：

```c
// file: storage/innobase/include/page0types.h:136
constexpr uint8_t PAGE_ZIP_SSIZE_BITS = 3;
```

### 8.3 压缩统计信息

```c
// file: storage/innobase/include/page0types.h:212
struct page_zip_stat_t {
    ulint compressed;
    ulint compressed_ok;
    ulint decompressed;
    std::chrono::microseconds compress_time;
    std::chrono::microseconds decompress_time;
    bool dropped{false};
};
```

---

## 9. 关键函数索引

| 函数 / 宏 | 文件 | 行号 | 说明 |
|---|---|---|---|
| `FIL_PAGE_OFFSET` | `fil0types.h` | 33 | 页偏移 |
| `FIL_PAGE_TYPE` | `fil0types.h` | 56 | 页类型字段 |
| `FIL_PAGE_INDEX` | `fil0fil.h` | 1227 | B-tree 索引页 (17855) |
| `PAGE_N_DIR_SLOTS` | `page0types.h` | 68 | 页目录槽数 |
| `PAGE_N_HEAP` | `page0types.h` | 72 | 堆记录数 + compact 标志 |
| `PAGE_LEVEL` | `page0types.h` | 86 | B-tree 级别 |
| `page_is_comp()` | `page0page.h` | 360 | 判断 compact 格式 |
| `page_create()` | `page0page.cc` | 374 | 创建新页 |
| `page_create_low()` | `page0page.cc` | 309 | 底层页初始化 |
| `page_create_zip()` | `page0page.cc` | 387 | 创建压缩页 |
| `page_cur_search_with_match()` | `page0cur.cc` | 328 | 页内二分查找 |
| `page_cur_insert_rec_low()` | `page0cur.cc` | 1229 | 记录插入 |
| `page_cur_delete_rec()` | `page0cur.cc` | 2307 | 记录删除 |
| `page_dir_split_slot()` | `page0page.cc` | 1283 | 目录槽分裂 |
| `page_dir_balance_slot()` | `page0page.cc` | 1320 | 目录槽平衡 |
| `rec_get_next_offs()` | `rem0rec.h` | 50 | 下一条记录偏移 |
| `rec_get_status()` | `rem/rec.h` | 171 | 记录状态位 |
| `rec_get_info_bits()` | `rem/rec.h` | 195 | 获取 info_bits |
| `rec_get_offsets()` | `rem/rec.h` | 139 | 计算字段偏移数组 |
| `rec_init_offsets_comp_ordinary()` | `rem/rec.h` | 631 | COMPACT 格式偏移初始化 |
| `rec_get_n_fields_old()` | `rem/rec.h` | 219 | REDUNDANT 格式字段数 |
| `rec_get_trx_id()` | `rem0rec.h` | 380 | 读取 DB_TRX_ID |
| `rec_convert_dtuple_to_rec()` | `rem0rec.h` | 280 | 元组转物理记录 |
| `REC_N_OLD_EXTRA_BYTES` | `rem/rec.h` | 80 | Redundant 6 字节额外头 |
| `REC_N_NEW_EXTRA_BYTES` | `rem/rec.h` | 81 | Compact 5 字节额外头 |
| `REC_OFFS_EXTERNAL` | `rem/rec.h` | 49 | 外部存储标志 |
| `dict_col_t` | `dict0mem.h` | 485 | 列描述结构体 |
| `dict_field_t` | `dict0mem.h` | 891 | 索引字段描述 |
| `page_zip_des_t` | `page0types.h` | 167 | 压缩页描述符 |
| `page_zip_compress()` | `page0zip.h` | 121 | 压缩页 |
| `page_zip_dir_add_slot()` | `page0types.h` | 214 | 压缩页目录槽添加 |
| `infimum_supremum_compact` | `page0page.cc` | 296 | COMPACT 伪记录数据 |
| `infimum_supremum_redundant` | `page0page.cc` | 285 | REDUNDANT 伪记录数据 |

---

## 总结

InnoDB 的页格式经过精心设计，在存储密度、查找效率和并发安全之间取得了平衡：

- **页目录 + 二分查找**：O(log(n)) 的查找复杂度，通过 `PAGE_DIR_SLOT_MAX_N_OWNED=8` 控制线性扫描的代价上限
- **自适应插入优化**：通过 `PAGE_DIRECTION` / `PAGE_LAST_INSERT` 追踪插入模式，顺序插入时跳过二分查找
- **行格式演进**：从 REDUNDANT 到 COMPACT 节省了 1 字节额外头和 NULL 位图空间；DYNAMIC 进一步优化了大字段的场景；COMPRESSED 增加了透明页压缩
- **Instant DDL**：通过 `REC_INFO_INSTANT_FLAG` / `REC_INFO_VERSION_FLAG` 标志位实现了无阻塞的即时列添加/删除

理解页格式是深入掌握 InnoDB B-tree 索引、MVCC、Redo 日志、以及崩溃恢复的基础。当你进行 `CREATE INDEX`、`OPTIMIZE TABLE` 或插入大量数据时，这些底层机制决定了实际的性能和行为。
