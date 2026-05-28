# 19. InnoDB 文件空间管理（File Space Management）— 源码深度分析

> 本文分析 InnoDB 文件空间的物理组织、页面分配与回收机制，包括表空间头布局、Extent 描述符 (XDES) 结构、段管理、碎片分配、空闲链表补充和崩溃恢复。核心源文件：`fil0fil.cc`、`fil0fil.h`、`fsp0fsp.cc`、`fsp0fsp.h`。

---

## 0. 概述

InnoDB 以**表空间 (Tablespace)** 为最高单位管理磁盘文件。每个表空间由一个或多个文件节点（`fil_node_t`）组成，逻辑划分为 **Extent（区）**、**Page（页）** 两级。空间管理的核心是：

1. **物理布局**：表空间文件由固定大小的页面（默认 16KB）组成
2. **分配粒度**：段（Segment）→ Extent（64 页）→ Page（1 页）
3. **元数据跟踪**：Space Header（page 0）记录空闲 Extent 链表，XDES 页面记录每页状态

### 表空间的层次结构

```
表空间文件 (.ibd / ibdata1)
├── Page 0: FSP Header（空间头）
├── Page 1: XDES（前 256 个 Extent 的描述符）
├── Page 2: IBUF Bitmap（Change Buffer 位图）
├── Page 3: INODE（段描述符）
├── Pages 4-63: 预留/系统用
├── Page 64: 第一个用户 Extent 的开始
│   └── 每个 Extent = 64 页（1MB，页面 16KB 时）
├── ...
└── Page N-1: 最后一个页面
```

---

## 1. 核心数据结构

### 1.1 表空间描述 — fil_space_t

```cpp
// fil0fil.h:240
struct fil_space_t {
  char *name;                           /* 表空间名（如 "mydb/t"） */
  space_id_t id;                        /* 表空间 ID（0=系统, >0=用户） */

  /* 组成该表空间的文件列表 */
  Files files;                          /* fil_node_t 向量 */

  /* 版本号：每次 truncate/drop 后递增 */
  /* Buffer Pool 中旧页面通过比较此版本发现过期 */
  std::atomic<uint32_t> m_version{};

  /* 引用计数：有多少 buf_page_t 指向此实例 */
  std::atomic_size_t m_n_ref_count{};

  /* 删除标记：标记为已删除的 space 不再接受新操作 */
  std::atomic<bool> m_deleted{};

  /* 从 FSP_HEADER 缓存的字段（减少读磁盘） */
  page_no_t size_in_header;             /* FSP_SIZE */
  page_no_t free_len;                   /* FSP_FREE 链表长度 */
  page_no_t free_limit;                 /* FSP_FREE_LIMIT */

  /* 该表空间所属的分片 */
  uint32_t m_shard_id;

  /* 链表节点：所有 space 通过此链接到 Fil_system 的分片 */
  UT_LIST_NODE_T(fil_space_t, m_spaces);

  /* 表空间标志 */
  uint32_t flags;                       /* 行格式、压缩等 */
};
```

**`m_version` 的设计意图**：

当 `TRUNCATE TABLE` 执行后，该表的表空间被重建（分配新空间 ID 或重用），但 Buffer Pool 中可能还有旧页面的缓存。通过比较 `space->m_version` 与页面内的版本标记，InnoDB 能发现这些页面已经过期，强制重新从磁盘读取。

### 1.2 文件节点 — fil_node_t

```cpp
// fil0fil.h:160
struct fil_node_t {
  fil_space_t *space;              /* 所属表空间 */

  char *name;                      /* 文件全路径名 */
  bool is_open;                    /* 文件句柄是否已打开 */
  pfs_os_file_t handle;            /* 操作系统文件句柄 */
  os_event_t sync_event;           /* fsync 完成事件 */

  page_no_t size;                  /* 文件当前大小（页数） */
  page_no_t init_size;             /* 创建时的初始大小 */
  page_no_t max_size;              /* 允许的最大大小（防止无限增长）*/

  size_t n_pending_ios;            /* 待处理的 I/O 请求数 */
  int64_t modification_counter;    /* 修改计数器（每次写操作递增）*/
  int64_t flush_counter;           /* 刷盘计数器（每次 fsync 后递增）*/

  bool punch_hole;                 /* 是否支持打孔（TRUNCATE / DISCARD）*/
  bool modify_uncommitted;         /* 是否有未提交的修改 */

  UT_LIST_NODE_T(fil_node_t, m_LRU);    /* LRU 链表节点 */
};
```

**`flush_counter == modification_counter`** 表示该文件没有未刷盘的数据。在 checkpoint 或 shutdown 时，InnoDB 等待这些计数器相等才认为数据安全。

### 1.3 Fil_shard — 分片管理器

`fil_system` 被分为多个 `Fil_shard`，每个 shard 管理一组表空间的集合，通过 `space_id` 哈希路由：

```cpp
// fil0fil.h — Fil_shard (简化)
class Fil_shard {
  /* 保护该分片的互斥锁 */
  Fil_shard_mutex mutex;

  /* 该分片管理的所有表空间 */
  using Spaces = std::unordered_map<space_id_t, fil_space_t *>;
  Spaces m_spaces;

  /* 未打开文件的节点 LRU */
  UT_LIST_BASE_NODE_T(fil_node_t, m_unflushed_nodes);

  int n_spaces;                   /* 表空间计数 */
  int n_pending_flushes;          /* 待刷盘计数 */
};
```

`Fil_shard` 的作用：将全局 `fil_system` 的锁竞争分散到多个分片上。分片数等于 `srv_n_fil_system_shards`，默认是 `FSP_MAX_OPEN_FILES / 1`。

```cpp
// fil_system->shard_by_id(space_id) 将 space_id 路由到对应分片
Fil_shard *Fil_system::shard_by_id(space_id_t id) const {
  return const_cast<Fil_shard *>(
      &m_shards[id % m_shards.size()]);
}
```

### 1.4 Space Header — 页面 0 布局

每个表空间的第一页是 FSP Header 页，类型 `FIL_PAGE_TYPE_FSP_HDR`。其 FSP 区域布局如下：

```
偏移量      大小   字段              说明
─────────────────────────────────────────────
0           4B    FSP_SPACE_ID      表空间 ID
4           4B    FSP_NOT_USED      保留
8           4B    FSP_SIZE          表空间总页数
12          4B    FSP_FREE_LIMIT    已初始化 XDES 的最大页号
16          4B    FSP_SPACE_FLAGS   空间标志
20          4B    FSP_FRAG_N_USED   FSP_FREE_FRAG 碎片 Extent 中已用页数
24          16B   FSP_FREE          空闲完整 Extent 链表头
40          16B   FSP_FREE_FRAG     部分空闲的碎片 Extent 链表头
56          16B   FSP_FULL_FRAG     全满的碎片 Extent 链表头
72          8B    FSP_SEG_ID        下一个段 ID
80          16B   FSP_SEG_INODES_FULL  满的 INODE 页链表头
96          16B   FSP_SEG_INODES_FREE  空闲 INODE 页链表头
```

其中链表头是 `flst_base_node_t` 结构：

```
flst_base_node_t (16 bytes):
  offset 0 (4B):  链表中的第一个节点的页内偏移
  offset 4 (4B):  链表中的第一个节点的页号
  offset 8 (4B):  链表中的最后一个节点的页内偏移
  offset 12 (4B): 链表中的最后一个节点的页号
```

这种"页号 + 页内偏移"的组合寻址方式允许链表跨越不同的页面。

### 1.5 XDES — Extent Descriptor

每个 Extent（连续 64 页）对应一个 `xdes_t`。XDES 条目存储在**XDES 页面**中。

**XDES 页面位置**：

```
Page 0:  FSP Header + 前 256 个 Extent 的 XDES（0-255，即页 0-16383）
Page 1:  更多 XDES（如果表空间 > 16GB）
Page N:  当表空间超过 16GB 时，每隔 XDES_DESCRIBED_PER_PAGE 页有一个 XDES 页面
```

**每个 XDES 条目（`xdes_t`）40 字节**：

```cpp
// fsp0fsp.h — 偏移定义
constexpr uint32_t XDES_ID = 0;            /* 8B: 所属段 ID */
constexpr uint32_t XDES_FLST_NODE = 8;     /* 12B: 链表节点 */
constexpr uint32_t XDES_STATE = FLST_NODE_SIZE + 8; /* 4B: Extent 状态 */
constexpr uint32_t XDES_BITMAP = FLST_NODE_SIZE + 12; /* 16B: 页位图 */
/* XDES_BITMAP 后每页 2 bits，共 128 bits = 16 字节 */
/* XDES 总大小 = 8 + 12 + 4 + 16 = 40 字节 */
```

**页位图（128 bits = 16 bytes）**：

每页占用 2 bits：

| Bit | 名称 | 含义 |
|-----|------|------|
| 0 | XDES_FREE_BIT | 该页是否空闲（1=空闲, 0=已分配） |
| 1 | XDES_CLEAN_BIT | 该页是否干净（1=干净, 0=脏页） |

64 页 × 2 bits = 128 bits = 16 bytes。

**Extent 状态枚举**：

```cpp
// fsp0fsp.h:293
enum xdes_state_t {
  XDES_FREE = 1,       /* Extent 中所有页都是空闲的 */
  XDES_FREE_FRAG = 2,  /* 部分页被分配（碎片分配模式） */
  XDES_FULL_FRAG = 3,  /* 所有页都已分配（碎片模式满） */
  XDES_FSEG = 4        /* 属于某个段的完整 Extent（段独占） */
};
```

状态转换：

```
              初始化
                │
                ▼
          XDES_FREE ◄─────────────────┐
          /         \                  │
         /           \                 │
        ▼              ▼               │
  XDES_FREE_FRAG    XDES_FSEG         │
   (碎片分配)      (段独占分配)         │
        │              │               │
        ▼              ▼               │
  XDES_FULL_FRAG    (段释放时)          │
        │              │               │
        └────── 全部释放 ───────────────┘
```

---

## 2. 表空间初始化

### 2.1 fsp_header_init() — 页面 0 初始化

```cpp
// fsp0fsp.cc:1007
bool fsp_header_init(space_id_t space_id, page_no_t size, mtr_t *mtr) {
  auto space = fil_space_get(space_id);
  mtr_x_lock_space(space, mtr);

  /* ──── 步骤 1：创建/获取页面 0 ──── */
  auto block = buf_page_create(page_id_t(space_id, 0),
                               page_size, RW_SX_LATCH, mtr);
  auto page = buf_block_get_frame(block);

  /* ──── 步骤 2：设置页面类型 ──── */
  /* FIL_PAGE_TYPE_FSP_HDR = 10 */
  mlog_write_ulint(page + FIL_PAGE_TYPE,
                   FIL_PAGE_TYPE_FSP_HDR, MLOG_2BYTES, mtr);

  /* ──── 步骤 3：写入基本元数据 ──── */
  auto header = FSP_HEADER_OFFSET + page;  /* FSP_HEADER_OFFSET = 38 */
  mlog_write_ulint(header + FSP_SPACE_ID, space_id, MLOG_4BYTES, mtr);
  mlog_write_ulint(header + FSP_SPACE_FLAGS, space->flags, MLOG_4BYTES, mtr);
  mlog_write_ulint(header + FSP_SIZE, size, MLOG_4BYTES, mtr);
  mlog_write_ulint(header + FSP_FREE_LIMIT, FSP_FIRST_FREE_PAGE, MLOG_4BYTES, mtr);
  /* FSP_FIRST_FREE_PAGE = 64 — 前 64 页留给系统使用 */

  /* ──── 步骤 4：初始化所有链表 ──── */
  flst_init(header + FSP_FREE, mtr);
  flst_init(header + FSP_FREE_FRAG, mtr);
  flst_init(header + FSP_FULL_FRAG, mtr);
  flst_init(header + FSP_SEG_INODES_FULL, mtr);
  flst_init(header + FSP_SEG_INODES_FREE, mtr);

  /* ──── 步骤 5：写入 FSP_FRAG_N_USED ──── */
  mlog_write_ulint(header + FSP_FRAG_N_USED, 0, MLOG_4BYTES, mtr);

  /* ──── 步骤 6：初始化前 256 个 Extent 的 XDES ──── */
  /* 它们在 page 0 的 FSP Header 之后连续存储 */
  /* 并添加到 FSP_FREE 链表中 */
  fsp_fill_free_list(false, space, header, mtr);

  /*
   * 步骤 7：初始化 FSP_SEG_INODES_FREE
   * 第一张 INODE 页面在 page 3（FSP_FIRST_INODE_PAGE）
   */
  ...

  return true;
}
```

**前 64 页的用途**：

```
Page 0:  FSP Header + XDES（前 256 个 Extent）
Page 1:  XDES 扩展页（如果表空间 > 16GB）
Page 2:  IBUF Bitmap
Page 3:  INODE（段描述符）
Page 4-7:  预留
Page 8-63:  保留（将来使用）
─────────────────────────────
Page 64+:  用户数据
```

### 2.2 物理页面（FIL_PAGE）的通用布局

每个页面（无论类型）都包含相同的 FIL 头部：

```
FIL Header (38 bytes):
  FIL_PAGE_SPACE_OR_CHKSUM    (4B, offset 0):  页面校验和
  FIL_PAGE_OFFSET              (4B, offset 4):  页面号
  FIL_PAGE_PREV                (4B, offset 8):  上一个页面号
  FIL_PAGE_NEXT                (4B, offset 12): 下一个页面号
  FIL_PAGE_LSN                 (8B, offset 16): 最新修改的 LSN
  FIL_PAGE_TYPE                (2B, offset 24): 页面类型
  FIL_PAGE_FILE_FLUSH_LSN     (8B, offset 26): 最近刷盘 LSN
  FIL_PAGE_ARCH_LOG_NO_OR_SPACE_ID (4B, offset 34): 空间 ID

页面类型 (FIL_PAGE_TYPE):
  0 = FIL_PAGE_INDEX          B+Tree 索引页
  1 = FIL_PAGE_RTREE          空间索引页
  2 = FIL_PAGE_SDI            SDI 数据页
  3 = FIL_PAGE_TYPE_RSEG_UNDO 回滚段页
  10 = FIL_PAGE_TYPE_FSP_HDR  文件空间头
  11 = FIL_PAGE_TYPE_XDES     Extent 描述符页
  12 = FIL_PAGE_TYPE_IBUF_BITMAP  Change Buffer 位图
  13 = FIL_PAGE_TYPE_SYS      系统页
  14 = FIL_PAGE_TYPE_TRX_SYS  事务系统页
  17854 = FIL_PAGE_TYPE_COMPRESSED  压缩页
  21845 = FIL_PAGE_TYPE_BLOB  BLOB 页
```

页面校验和（offset 0）的重要性：InnoDB 会在读取后写入前都验证校验和。如果 `FIL_PAGE_SPACE_OR_CHKSUM` 与页面内容的校验和不匹配（比如硬件损坏或文件系统 bug），InnoDB 会报告 `Corrupted page` 错误。

---

## 3. 页面分配路径

### 3.1 分配入口

页面分配有两个入口：

```
btr_page_alloc() — B+Tree 使用（从段中分配）
  └─ fseg_alloc_free_page_general()
      └─ fseg_alloc_page_no()

fsp_page_create() — 通用页面分配（如空间管理页）
  └─ fsp_alloc_from_free_frag()
```

### 3.2 段分配 — fseg_alloc_page_no()

```cpp
// fsp0fsp.cc:2736
page_no_t fseg_alloc_page_no(space_index_t seg_id,
                             page_no_t hint, ...) {

  /* ──── 步骤 1：查找段 INODE ──── */
  inode = fseg_inode_try_get(seg_id, hint_page_no, ...);

  /* ──── 步骤 2：根据段的使用模式选择分配策略 ──── */

  /* 段策略：FSP_SEG_FULL = 已满, FSP_SEG_FREE_LST = 有空闲页 */
  if (xdes_full_frag_mode(inode)) {
    /* 段已满 → 分配一个完整 Extent */
    return fseg_alloc_extent(seg_id, ...);
  }

  /* ──── 步骤 3：尝试从当前碎片 Equent 中分配 ──── */
  auto extent_id = inode->free_frag_extent;
  if (extent_id != FIL_NULL) {
    xdes = xdes_get(extent_id);
    auto page_no = fsp_alloc_from_free_frag(
        header, xdes, &free, mtr);
    if (free != FIL_NULL) return page_no;
  }

  /* ──── 步骤 4：碎片 Equent 也满了 → 分配新 Equent ──── */
  return fseg_alloc_extent(seg_id, ...);
}
```

### 3.3 fsp_alloc_free_extent() — 分配完整 Extent

```cpp
// fsp0fsp.cc:1585
static xdes_t *fsp_alloc_free_extent(...) {
  auto header = fsp_get_space_header(space_id, page_size, mtr);

  /* ──── 步骤 1：尝试 hint 位置（空间局部性优化）──── */
  auto descr = xdes_get_descriptor_with_space_hdr(
      header, space_id, hint, mtr, false, &desc_block);

  if (descr != nullptr &&
      xdes_get_state(descr, mtr) == XDES_FREE) {
    /* hint 命中 → 使用 hint 位置的 Equent */
  } else {
    /* ──── 步骤 2：从 FSP_FREE 链表取第一个 ──── */
    auto first = flst_get_first(header + FSP_FREE, mtr);

    if (fil_addr_is_null(first)) {
      /* 空闲链表为空 → 调用 fsp_fill_free_list 补充 */
      fsp_fill_free_list(false, space, header, mtr);
      first = flst_get_first(header + FSP_FREE, mtr);
    }

    if (fil_addr_is_null(first)) {
      /* 表空间已满 → 返回 NULL */
      return nullptr;
    }

    descr = xdes_lst_get_descriptor(
        space_id, page_size, first, mtr);
  }

  /* ──── 步骤 3：从 FSP_FREE 链表移除 ──── */
  flst_remove(header + FSP_FREE, descr + XDES_FLST_NODE, mtr);
  space->free_len--;

  return descr;
}
```

### 3.4 fsp_alloc_from_free_frag() — 从碎片 Extent 分配单页

```cpp
// fsp0fsp.cc:1632
static void fsp_alloc_from_free_frag(
    fsp_header_t *header, xdes_t *descr,
    page_no_t *free, mtr_t *mtr) {

  /* ──── 步骤 1：在 XDES 位图中找到第一个空闲页 ──── */
  ulint i = 0;
  for (;;) {
    if (!xdes_mtr_get_bit(descr, XDES_FREE_BIT, i, mtr)) {
      /* FREE_BIT=0 = 已分配 → 找下一个 */
      i++;
      continue;
    }
    /* FREE_BIT=1 = 空闲 → 找到了 */
    *free = page_no_from_extent(descr_extent_no, i);
    break;
  }

  /* ──── 步骤 2：设置 FREE_BIT=0（标记为已分配）──── */
  xdes_set_bit(descr, XDES_FREE_BIT, i, false, mtr);
  xdes_set_bit(descr, XDES_CLEAN_BIT, i, false, mtr);

  /* ──── 步骤 3：更新 FSP_FRAG_N_USED ──── */
  auto frag_n_used = mtr_read_ulint(header + FSP_FRAG_N_USED,
                                    MLOG_4BYTES, mtr);
  frag_n_used++;
  mlog_write_ulint(header + FSP_FRAG_N_USED,
                   frag_n_used, MLOG_4BYTES, mtr);

  /* ──── 步骤 4：如果这个 Extent 满了 → 移到 FULL_FRAG 链表 ──── */
  if (frag_n_used == FSP_EXTENT_SIZE) {
    /* 从 FREE_FRAG 链表移除 */
    flst_remove(header + FSP_FREE_FRAG,
                descr + XDES_FLST_NODE, mtr);
    /* 状态改为 XDES_FULL_FRAG */
    xdes_set_state(descr, XDES_FULL_FRAG, mtr);
    /* 加入 FULL_FRAG 链表 */
    flst_add_last(header + FSP_FULL_FRAG,
                  descr + XDES_FLST_NODE, mtr);
  }
}
```

### 3.5 完整的 B-Tree 页面分配路径

```
B+Tree 插入 → 当前叶子页已满 → 需要分配新页
  └─ btr_page_split_and_insert()
      └─ btr_page_alloc()                   # btr0btr.cc
          └─ fseg_alloc_free_page_general()  # fsp0fsp.cc:2585
              ├─ 从段的碎片 Extent 分配:
              │   fseg_alloc_page_no()
              │   ├─ fsp_alloc_from_free_frag() ← 碎片 Extent
              │   └─ 如果碎片 Extent 已满:
              │       fseg_alloc_extent()
              │       └─ fsp_alloc_free_extent() ← 完整 Extent
              │       └─ 新 Extent 的第一个页:
              │           × 不设为碎片分配模式
              │           └─ XDES_STATE = XDES_FSEG
              └─ 写入新页的 FIL_PAGE_TYPE = FIL_PAGE_INDEX
              └─ 更新段 INODE 中的使用计数

段 (segment) 将获得的 Extent 标记为 XDES_FSEG，
并记录在 INODE 的 free_frag_extent 或完整 Extent 列表中。
```

---

## 4. 空闲链表补充 — fsp_fill_free_list()

当 `FSP_FREE` 链表为空时，InnoDB 不会逐页分配，而是**批量初始化新 Extent**：

```cpp
// fsp0fsp.cc — 简化
static void fsp_fill_free_list(bool use_mtr, fil_space_t *space,
                               fsp_header_t *header, mtr_t *mtr) {

  /* 读取当前 free_limit 和表空间总大小 */
  auto free_limit = mtr_read_ulint(header + FSP_FREE_LIMIT,
                                   MLOG_4BYTES, mtr);
  auto size = mtr_read_ulint(header + FSP_SIZE,
                               MLOG_4BYTES, mtr);

  /* 每次添加 FSP_FREE_ADD(=4) 个空闲 Extent */
  auto limit = free_limit + FSP_FREE_ADD * FSP_EXTENT_SIZE;
  /* 不超过表空间大小（向下对齐到 Extent 边界） */
  limit = std::min(limit,
                   ut_uint64_align_down(size, FSP_EXTENT_SIZE));

  /* 为这 4 个新 Extent 初始化 XDES */
  for (page_no_t i = free_limit;
       i < limit; i += FSP_EXTENT_SIZE) {

    /* 获取该 Extent 对应的 XDES 描述符 */
    auto xdes = xdes_get_descriptor_with_space_hdr(
        header, space->id, i, mtr, true, ...);

    /* 设置状态为 XDES_FREE */
    xdes_set_state(xdes, XDES_FREE, mtr);

    /* 所有页的 FREE_BIT = 1, CLEAN_BIT = 1 */
    for (ulint j = 0; j < FSP_EXTENT_SIZE; j++) {
      xdes_set_bit(xdes, XDES_FREE_BIT, j, true, mtr);
      xdes_set_bit(xdes, XDES_CLEAN_BIT, j, true, mtr);
    }

    /* 加入 FSP_FREE 链表尾部 */
    flst_add_last(header + FSP_FREE, xdes + XDES_FLST_NODE, mtr);
  }

  /* 更新 FSP_FREE_LIMIT */
  mlog_write_ulint(header + FSP_FREE_LIMIT,
                   limit, MLOG_4BYTES, mtr);
}
```

**`FSP_FREE_ADD = 4` 的设计理由**：

每次补充 4 个 Extent（256 页 = 4MB）的批量操作减少了 redo log 的写入频率。如果每分配一页就更新一次 FSP_FREE_LIMIT，会导致大量小的 redo 记录。

但 4 个 Extent 也只是保守值——InnoDB 不做太大的批量操作，因为分配后可能不需要这么多（避免浪费 XDES 初始化的工作）。

---

## 5. INODE — 段管理

段（segment）是 InnoDB 的更高分配抽象。每个 B-Tree（或 Change Buffer）需要维护自己的段来管理页面资源。

### 5.1 INODE 页面结构

```
INODE 页 (FIL_PAGE_TYPE = page 3 或 FSP_SEG_INODES 链表的页):

  ├── INODE 条目 0  ← 预留
  ├── INODE 条目 1  ← 预留
  ├── ...
  ├── INODE 条目 N  ← 每个 B-Tree 或 ibuf 的段
  └── ...

每个 INODE 条目 (fseg_inode_t):
  ├── magic_number   (4B):  魔数 (FSEG_MAGIC_NUMBER=12348701)
  ├── n_reserved     (8B):  预留的 Extent 页数
  ├── free_frag_extent (4B):  当前碎片 Extent 的页号（FIL_NULL 则无）
  ├── full_frag_extent (4B):  已满碎片 Extent 的页号
  ├── free_extents   (×32):  最多 32 个完整 Extent 的位置
  └── not_full_extents (×32):  最多 32 个部分满的 Extent
```

### 5.2 INODE 的 Extent 链表

每个段管理三组 Extent：

```
段 INODE:
  ┌─ free_frag_extent: 当前碎片 Extent（有 FREE_BIT=1 的页）
  ├─ full_frag_extent: 已满碎片 Extent
  ├─ free_extents[32]: 完整空闲 Extent 列表（段自己持有的完整 Extent）
  └─ not_full_extents[32]: 部分页已释放的完整 Extent
```

当段需要分配单页时，优先从 `free_frag_extent` 分配。当该 Extent 满了，移到 `full_frag_extent`。当没有碎片 Extent 可用时，从 `free_extents` 取一个完整 Extent 转为碎片分配模式。

### 5.3 B-Tree 与段的关系

```
聚簇索引 = 两个段：叶子段 (leaf) + 非叶子段 (non-leaf)
二级索引 = 两个段：叶子段 + 非叶子段

为什么需要分开？
- 叶子段和非叶子的访问模式不同（写多 vs 读多）
- 正常操作不会同时修改两者（页分裂时除外）
- 分开后 Buffer Pool 和空间分配可以分别优化
```

```cpp
// dict0mem.h:1067 — dict_index_t 的段信息
struct dict_index_t {
  ...
  /* 叶子段的段 ID */
  space_index_t m_leaf_segment_id;
  /* 非叶子段的段 ID */
  space_index_t m_non_leaf_segment_id;
  ...
};
```

---

## 6. 页面回收路径

### 6.1 fsp_free_page() — 释放单页

```cpp
// fsp0fsp.cc:1830
static void fsp_free_page(const page_id_t &page_id,
                          const page_size_t &page_size, mtr_t *mtr) {

  auto header = fsp_get_space_header(page_id.space(), page_size, mtr);
  auto descr = xdes_get_descriptor_with_space_hdr(
      header, page_id.space(), page_id.page_no(), mtr);

  auto state = xdes_get_state(descr, mtr);
  ut_ad(state != XDES_FREE);  /* 不能释放已经空闲的页 */

  /* ──── 步骤 1：在位图中设置 FREE_BIT=1 ──── */
  xdes_set_bit(descr, XDES_FREE_BIT, bit, true, mtr);
  xdes_set_bit(descr, XDES_CLEAN_BIT, bit, true, mtr);

  /* ──── 步骤 2：根据 Extent 状态调整链表归属 ──── */
  switch (state) {
    case XDES_FULL_FRAG:
      /* 满碎片 → 变成部分空闲碎片 */
      flst_remove(header + FSP_FULL_FRAG,
                  descr + XDES_FLST_NODE, mtr);
      xdes_set_state(descr, XDES_FREE_FRAG, mtr);
      flst_add_last(header + FSP_FREE_FRAG,
                    descr + XDES_FLST_NODE, mtr);
      break;

    case XDES_FREE_FRAG:
      /* 检查是否所有页都变成空闲了 */
      if (xdes_is_all_bits_set(descr, XDES_FREE_BIT,
                               FSP_EXTENT_SIZE, mtr)) {
        /* 整个 Extent 都空了 → 移到 FSP_FREE */
        flst_remove(header + FSP_FREE_FRAG,
                    descr + XDES_FLST_NODE, mtr);
        xdes_set_state(descr, XDES_FREE, mtr);
        flst_add_last(header + FSP_FREE,
                      descr + XDES_FLST_NODE, mtr);
      }
      break;

    case XDES_FSEG:
      /* 段独占的 Extent → 段内部管理回收 */
      /* 段将释放的页标记后，等整个 Extent 都空闲时还给全局 */
      break;
  }
}
```

### 6.2 段级别的回收 — fseg_free_page()

当 B-Tree 合并（如删除大量数据后页收缩）时，调用段级别的释放：

```cpp
void fseg_free_page(space_index_t seg_id, page_no_t page_no, mtr_t *mtr) {
  /* 通知该段：这个页被释放了 */
  /* 段从 INODE 的 free_extents/not_full_extents 中管理 */
  /* 如果整个 Extent 都空了 → 还给 FSP_FREE 链表 */
  /* 更新 INODE 中的 n_reserved */
}
```

**回收的策略**：

```
B-Tree 页合并（DELETE / UPDATE）:
  1. btr_cur_del_mark_set_sec_rec() 删除记录
  2. 页变空 → btr_page_empty()
  3. 如果是区间合并页 → 释放该页
  4. fseg_free_page() → XDES FREE_BIT 置 1
  5. 如果 Extent 全空 → 回到 FSP_FREE 链表
  6. 如果段不再需要该 Extent → 从段 INODE 列表移除
```

---

## 7. 并发控制

### 7.1 Fil_shard mutex

每个 `Fil_shard` 使用独立的 mutex，减少全局锁竞争：

```cpp
// 表空间元数据的修改
fil_space_open()   ─→ shard->mutex_acquire()
fil_space_close()  ─→ shard->mutex_acquire()
fil_ibd_create()   ─→ shard->mutex_acquire()
```

### 7.2 页面分配的锁

```
分配路径的锁持有:
  fsp_alloc_free_extent():
    ├─ Space Header 页: mtr 管理的 SX latch
    ├─ XDES 页: mtr 管理的 X latch
    └─ FSP_FREE 链表操作: mtr 管理的 X latch

  fsp_alloc_from_free_frag():
    ├─ XDES 页: mtr 管理的 X latch
    └─ FSP_FREE_FRAG 链表: mtr 管理的 X latch
```

由于所有操作都在 `mtr` 内完成，`mtr_commit()` 时批量释放所有锁，不存在锁的嵌套等待。

### 7.3 表空间截断的原子性

`TRUNCATE TABLE` 需要表空间重建：

```
TRUNCATE TABLE:
  1. X-lock 表空间的 MTR
  2. 原 .ibd 文件重命名为临时文件
  3. 创建新 .ibd 文件
  4. fsp_header_init() 新文件
  5. space->m_version++（使 BP 中的旧页过期）
  6. 释放原文件句柄
  7. 关闭 MTR
  8. 删除临时文件（后台异步）
```

---

## 8. 崩溃恢复

崩溃恢复时的空间元数据恢复：

```
崩溃恢复开始
  └─ redo log 从 checkpoint LSN 开始 Apply
      ├─ 所有 MLOG 记录被重放
      ├─ 包括 FSP_HEADER 的修改（FSP_SIZE、链表操作等）
      ├─ 包括 XDES 位图的修改
      └─ 包括 INODE 页面修改

  └─ 恢复完成后:
      ├─ 所有表空间处于一致状态
      ├─ FSP_FREE 链表中列出了所有空闲 Extent
      ├─ INODE 正确记录了每个段的 Extent 归属
      └─ Bitmap（IBUF_BITMAP）可能不一致 → merge 时修复
```

**关键设计**：所有空间管理操作（`mlog_write_ulint` / `flst_*` / `xdes_set_bit`）都被记录在 redo log 中，因此崩溃后表空间分配状态是完全可恢复的。

但 **XDES_CLEAN_BIT** 不保证恢复后正确——因为它只是"页面是否脏"的缓存在 redo log 中没有可靠记录。Buffer Pool 的 LRU 或 flush list 追踪了真正的脏页。

---

## 9. 性能考量

### 9.1 分配局部性

InnoDB 的空间分配优先考虑**局部性**：

- `hint` 参数：调用者提供期望的页号位置，分配器优先满足
- B-Tree 分裂时，新页分配在兄弟页附近（同一 Extent 或相邻 Extent）
- 段的碎片 Extent 策略：先给单个页，满了再给完整 Extent

### 9.2 碎片化问题

碎片 Extent（`FSP_FREE_FRAG`）用于小规模分配，但如果一个表经常分配单页然后释放，会导致：

```
大量碎片 Equent:
  每个 Extent 只有 1-2 页被使用，其余页在 FREE_FRAG 链表中
  → 浪费空间（一个 Extent 1MB 实际上只用了 32KB）

缓解方案:
  FSP_FRAG_N_USED: 跟踪碎片 Equent 的已用页数
  如果一个 Equent 的使用率长期很低，合并回收
  但目前 InnoDB 不做主动碎片整理
```

### 9.3 文件扩展

当表空间空间不足时，InnoDB 会扩展文件（`fil_space_extend`）：

```cpp
// fil0fil.cc — fil_space_extend()
  /* 每次扩展 FIL_EXTEND_SIZE 页（= 32 pages = 512KB 或 1 个 Extent） */
  /* 如果表空间很大（> 32MB），一次扩展 4 个 Extent */
  /* 然后更新 FSP_SIZE */
```

---

## 10. 完整调用链总结

### 10.1 页面分配

```
B-Tree 插入（页满）:
  btr_page_split_and_insert()
    └─ btr_page_alloc(index, hint_page_no, ...)
        └─ fseg_alloc_free_page_general(seg_id, hint, ...)
            ├─ fseg_alloc_page_no(seg_id, hint, ...)
            │   ├─ fseg_inode_try_get(seg_id) → 查找段 INODE
            │   ├─ free_frag_extent 可用?
            │   │   └─ fsp_alloc_from_free_frag(header, xdes, ...)
            │   │       ├─ XDES 位图查找第一个 FREE_BIT=1 的页
            │   │       ├─ 设置 FREE_BIT=0, CLEAN_BIT=0
            │   │       ├─ FSP_FRAG_N_USED++
            │   │       └─ 如果满了 → 移到 FULL_FRAG 链表
            │   └─ 碎片不可用?
            │       └─ fseg_alloc_extent(seg_id, ...)
            │           └─ fsp_alloc_free_extent(space_id, hint, ...)
            │               ├─ hint 位置 XDES_FREE → 取
            │               ├─ FSP_FREE 链表取第一个
            │               │   └─ 空? → fsp_fill_free_list() 补充 4 个
            │               └─ flst_remove, xdes_set_state(XDES_FSEG)
            ├─ buf_page_create(page_id) → 创建新页帧
            └─ 更新段 INODE 计数
        └─ FIL_PAGE_TYPE = FIL_PAGE_INDEX
        └─ 新页链接入 B-Tree 结构
```

### 10.2 页面释放

```
B-Tree 删除（页变空）:
  btr_page_free(index, block, mtr)
    └─ fseg_free_page(seg_id, page_no, mtr)
        ├─ fsp_free_page(page_id, page_size, mtr)
        │   ├─ xdes_set_bit(FREE_BIT=1, CLEAN_BIT=1)
        │   ├─ 更新 XDES 状态链表归属:
        │   │   XDES_FULL_FRAG → XDES_FREE_FRAG
        │   │   或全部释放 → XDES_FREE → FSP_FREE
        │   └─ 更新 FSP_FRAG_N_USED（如果适用）
        └─ 更新段 INODE 的 Extent 列表
```

### 10.3 表空间创建

```
CREATE TABLE ... ENGINE=InnoDB
  └─ dict_create_table()
      └─ fil_ibd_create(space_id, name, path, flags, FIL_IBD_FILE_INITIAL_SIZE)
          └─ fil_create_tablespace(...)
              ├─ os_file_create(path) → 创建 .ibd 文件
              ├─ buf_page_create(page_id(space_id, 0))
              ├─ fsp_header_init(space_id, size, mtr)
              │   ├─ 写入 FIL_PAGE_TYPE_FSP_HDR
              │   ├─ FSP_SPACE_ID, FSP_SIZE, FSP_SPACE_FLAGS
              │   ├─ 初始化所有链表
              │   └─ fsp_fill_free_list() → 4 个空 Extent
              ├─ ibuf_bitmap_page_init(page 2)
              └─ fseg_create(...) → 创建初始段的 INODE
```

---

## 11. 源码索引

| 函数/结构 | 文件 | 行号 | 关键作用 |
|-----------|------|------|---------|
| `fil_space_t` | `fil0fil.h` | 240 | 表空间描述符 |
| `fil_node_t` | `fil0fil.h` | 160 | 文件节点（.ibd 文件） |
| `Fil_shard` | `fil0fil.h` | — | 分片管理器 |
| `xdes_state_t` | `fsp0fsp.h` | 293 | XDES 状态枚举 |
| `FSP_HEADER_OFFSET` | `fsp0fsp.h` | — | 38 |
| `XDES_DESCRIBED_PER_PAGE` | `fsp0fsp.h` | — | 256 |
| `FSP_EXTENT_SIZE` | `fsp0fsp.h` | — | 64 |
| `FSP_FREE_ADD` | `fsp0fsp.h` | — | 4 |
| `fsp_header_init()` | `fsp0fsp.cc` | 1007 | 表空间头初始化 |
| `fsp_alloc_free_extent()` | `fsp0fsp.cc` | 1585 | 分配完整 Extent |
| `fsp_alloc_from_free_frag()` | `fsp0fsp.cc` | 1632 | 从碎片 Extent 分配单页 |
| `fsp_free_page()` | `fsp0fsp.cc` | 1830 | 释放单页 |
| `fsp_fill_free_list()` | `fsp0fsp.cc` | 1726 | 批量补充空闲 Extent |
| `fseg_alloc_page_no()` | `fsp0fsp.cc` | 2736 | 段级别页面分配 |
| `fil_ibd_create()` | `fil0fil.cc` | 5692 | 创建 .ibd 文件 |
| `fil_space_open()` | `fil0fil.cc` | 3530 | 打开表空间文件 |
| `fil_space_close()` | `fil0fil.cc` | 3544 | 关闭表空间文件 |
