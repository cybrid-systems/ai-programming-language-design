# 19. InnoDB 文件空间管理 (File Space Management)

> 本文分析 InnoDB 文件空间的物理组织、空间分配与回收机制，包括表空间头页面布局、Extent 描述符、段管理和文件节点管理。核心文件：`fil0fil.cc`、`fil0fil.h`、`fsp0fsp.cc`、`fsp0fsp.h`。

---

## 1. 概述

InnoDB 以 **表空间 (Tablespace)** 为单位管理磁盘文件。每个表空间由若干文件节点 (`fil_node_t`) 组成，内部以 **Extent（区）** 为分配单位（默认 64 页 = 1MB）。空间管理的核心数据结构位于 **Space Header 页面**（page 0），通过 Extent Descriptor (XDES) 页面追踪每个 Extent 的状态。

| 组件 | 文件 | 职责 |
|------|------|------|
| `fil_space_t` | `fil0fil.h:240` | 表空间描述符 |
| `fil_node_t` | `fil0fil.h:160` | 文件节点（单个 .ibd 文件） |
| `fsp_header_t` | `fsp0fsp.h` | 表空间头（page 0 上） |
| `xdes_t` | `fsp0fsp.h` | 每个 Extent 的描述符 |
| `Fil_shard` | `fil0fil.h` | 表空间集合的分片管理器 |

---

## 2. 核心数据结构

### 2.1 表空间描述 `fil_space_t`

```cpp
// fil0fil.h:240
struct fil_space_t {
  char *name;                           // 表空间名
  space_id_t id;                        // 表空间 ID
  Files files;                          // 文件节点向量

  /** 版本号：截断/删除时递增，使 BP 中旧页面变 stale */
  std::atomic<uint32_t> m_version{};

  /** 引用计数：有多少 buf_page_t 指向此实例 */
  std::atomic_size_t m_n_ref_count{};

  /** 删除标记 */
  std::atomic<bool> m_deleted{};

  page_no_t size_in_header;             // FSP_SIZE（头中的空间大小）
  page_no_t free_len;                   // FSP_FREE 链表长度（空闲 extent 数）
  page_no_t free_limit;                 // FSP_FREE_LIMIT

  /** Extent Descriptor 页面数组 */
  using List_node = UT_LIST_NODE_T(fil_space_t);
};
```

### 2.2 文件节点 `fil_node_t`

```cpp
// fil0fil.h:160
struct fil_node_t {
  fil_space_t *space;              // 所属表空间
  char *name;                      // 文件名
  bool is_open;                    // 文件是否已打开
  pfs_os_file_t handle;            // 文件句柄
  os_event_t sync_event;           // fsync 同步事件
  page_no_t size;                  // 文件大小（页数）
  page_no_t init_size;             // 初始大小
  page_no_t max_size;              // 最大大小
  size_t n_pending_ios;            // 待处理 I/O 计数
  int64_t modification_counter;    // 修改计数器
  int64_t flush_counter;           // 刷盘计数器（同步时使用）
  bool punch_hole;                 // 是否支持打孔
  List_node LRU;                   // 文件节点 LRU 链表节点
};
```

`flush_counter == modification_counter` 表示该文件的所有页面已刷盘。

### 2.3 Space Header 页面布局

```cpp
// fsp0fsp.h — 常量偏移定义
constexpr uint32_t FSP_SPACE_ID = 0;       // 空间 ID
constexpr uint32_t FSP_NOT_USED = 4;       // 保留
constexpr uint32_t FSP_SIZE = 8;           // 空间总页数
constexpr uint32_t FSP_FREE_LIMIT = 12;    // 未初始化的最小页面号
constexpr uint32_t FSP_SPACE_FLAGS = 16;   // 空间标志（行格式、压缩等）
constexpr uint32_t FSP_FRAG_N_USED = 20;   // FSP_FREE_FRAG 列表中已使用的页数
constexpr uint32_t FSP_FREE = 24;          // 空闲 Extent 链表
constexpr uint32_t FSP_FREE_FRAG = 24 + FLST_BASE_NODE_SIZE; // 部分空闲的碎片 Extent
constexpr uint32_t FSP_FULL_FRAG = 24 + 2 * FLST_BASE_NODE_SIZE; // 已满的碎片 Extent
constexpr uint32_t FSP_SEG_ID = 32 + 3 * FLST_BASE_NODE_SIZE; // 下一个未使用的段 ID
constexpr uint32_t FSP_SEG_INODES_FULL = 40 + 3 * FLST_BASE_NODE_SIZE;
constexpr uint32_t FSP_SEG_INODES_FREE = 40 + 4 * FLST_BASE_NODE_SIZE;
constexpr uint32_t FSP_HEADER_SIZE = 32 + 5 * FLST_BASE_NODE_SIZE;
```

### 2.4 Extent 描述符（XDES）

每个 Extent（64 页）对应一个 `xdes_t`，存储在 XDES 页面中（page 0 和 page XDES_SIZE 的倍数页面）。

```cpp
// fsp0fsp.h — XDES 偏移量
constexpr uint32_t XDES_ID = 0;            // 段 ID
constexpr uint32_t XDES_FLST_NODE = 8;     // 链表节点（连接 free/frag 链表）
constexpr uint32_t XDES_STATE = FLST_NODE_SIZE + 8; // Extent 状态
constexpr uint32_t XDES_BITMAP = FLST_NODE_SIZE + 12; // 页位图
constexpr uint32_t XDES_BITS_PER_PAGE = 2; // 每页 2 bits（FREE + CLEAN）
```

Extent 状态枚举：

```cpp
// fsp0fsp.h:293
enum xdes_state_t {
  XDES_FREE = 1,       // 全空闲
  XDES_FREE_FRAG = 2,  // 部分页被分配（碎片 extent）
  XDES_FULL_FRAG = 3,  // 所有页已被分配
  XDES_FSEG = 4        // 属于某个段的完整 extent
};
```

---

## 3. 初始化流程：表空间创建

### 3.1 `fil_ibd_create` → `fil_create_tablespace`

```cpp
// fil0fil.cc:5692
dberr_t fil_ibd_create(space_id_t space_id, const char *name,
                       const char *path, uint32_t flags, page_no_t size) {
  ut_a(size >= FIL_IBD_FILE_INITIAL_SIZE);
  return fil_create_tablespace(space_id, name, path, flags, size,
                               FIL_TYPE_TABLESPACE);
}
```

### 3.2 `fsp_header_init` — 初始化 page 0

```cpp
// fsp0fsp.cc:1007
bool fsp_header_init(space_id_t space_id, page_no_t size, mtr_t *mtr) {
  auto space = fil_space_get(space_id);
  mtr_x_lock_space(space, mtr);

  auto block = buf_page_create(page_id_t(space_id, 0), page_size,
                               RW_SX_LATCH, mtr);             // line 1016

  auto page = buf_block_get_frame(block);

  // Step 1: 写入文件页类型为 FIL_PAGE_TYPE_FSP_HDR
  mlog_write_ulint(page + FIL_PAGE_TYPE,
                   FIL_PAGE_TYPE_FSP_HDR, MLOG_2BYTES, mtr);  // line 1030

  // Step 2: 写入空间 ID、标志、大小
  auto header = FSP_HEADER_OFFSET + page;
  mlog_write_ulint(header + FSP_SPACE_ID, space_id, MLOG_4BYTES, mtr); // line 1043
  mlog_write_ulint(header + FSP_SPACE_FLAGS, space->flags, MLOG_4BYTES, mtr);

  // Step 3: 初始化所有链表（free / free_frag / full_frag / inodes_full / inodes_free）
  flst_init(header + FSP_FREE, mtr);               // line 1058
  flst_init(header + FSP_FREE_FRAG, mtr);
  flst_init(header + FSP_FULL_FRAG, mtr);
  flst_init(header + FSP_SEG_INODES_FULL, mtr);
  flst_init(header + FSP_SEG_INODES_FREE, mtr);

  // Step 4: 填充初始空闲 Extent
  fsp_fill_free_list(..., space, header, mtr);      // line 1070
  return true;
}
```

---

## 4. 页面分配路径

### 4.1 完整调用链

```
fseg_alloc_page_no()              # fsp0fsp.cc:2736（段分配页面）
 └─ fsp_alloc_free_extent()       # fsp0fsp.cc:1585（分配完整 extent）
     ├─ xdes_get_descriptor_with_space_hdr()  # 获取 hint 页的 XDES
     ├─ flst_get_first(header + FSP_FREE)     # 从空闲链表取第一个 extent
     │   └─ fsp_fill_free_list()              # 空闲链表为空时补充
     └─ flst_remove(header + FSP_FREE)        # 从空闲链表移除
 └─ fsp_alloc_from_free_frag()    # fsp0fsp.cc:1632（从碎片 extent 分配）
     ├─ xdes_set_state()          # 更新 XDES_STATE
     ├─ xdes_set_bit()            # 设置 FREE_BIT
     └─ 更新 FSP_FRAG_N_USED
     └─ flst_remove / flst_add_last()  # 在 free_frag / full_frag 间移动
fsp_page_create()                 # 创建零点页面
```

### 4.2 Extent 分配 `fsp_alloc_free_extent`

```cpp
// fsp0fsp.cc:1585
static xdes_t *fsp_alloc_free_extent(space_id_t space_id,
                                     const page_size_t &page_size,
                                     page_no_t hint, mtr_t *mtr) {
  auto header = fsp_get_space_header(space_id, page_size, mtr);

  // Step 1: 尝试从 hint 位置获取空闲 Extent
  auto descr = xdes_get_descriptor_with_space_hdr(header, space_id,
                                                   hint, mtr, false, &desc_block);

  if (descr && xdes_get_state(descr, mtr) == XDES_FREE) {
    /* 命中 hint 位置的空闲 Extent */
  } else {
    // Step 2: 从 FSP_FREE 链表取第一个
    auto first = flst_get_first(header + FSP_FREE, mtr);     // line 1621
    if (fil_addr_is_null(first)) {
      fsp_fill_free_list(false, space, header, mtr);         // line 1627
      first = flst_get_first(header + FSP_FREE, mtr);
    }
    if (fil_addr_is_null(first)) return nullptr;

    descr = xdes_lst_get_descriptor(space_id, page_size, first, mtr); // line 1633
  }

  // Step 3: 从空闲链表中移除
  flst_remove(header + FSP_FREE, descr + XDES_FLST_NODE, mtr);  // line 1637
  space->free_len--;
  return descr;
}
```

### 4.3 碎片页分配 `fsp_alloc_from_free_frag`

```cpp
// fsp0fsp.cc:1632
static void fsp_alloc_from_free_frag(
    fsp_header_t *header, xdes_t *descr, page_no_t *free, mtr_t *mtr) {
  // 在 XDES 位图中找到第一个空闲页
  for (;;) {
    if (!xdes_mtr_get_bit(descr, XDES_FREE_BIT, i, mtr)) {     // line 1683
      *free = page_no; break;
    }
    i++;
  }

  // 设置 FREE_BIT=0（已分配）
  xdes_set_bit(descr, XDES_FREE_BIT, i, false, mtr);           // line 1701

  // 根据剩余空闲页数在 FSP_FREE_FRAG / FSP_FULL_FRAG 间移动
  auto frag_n_used = mtr_read_ulint(header + FSP_FRAG_N_USED, MLOG_4BYTES, mtr);
  frag_n_used++;
  mlog_write_ulint(header + FSP_FRAG_N_USED, frag_n_used, MLOG_4BYTES, mtr);

  if (frag_n_used == FSP_EXTENT_SIZE) {
    flst_remove(header + FSP_FREE_FRAG, descr + XDES_FLST_NODE, mtr);
    xdes_set_state(descr, XDES_FULL_FRAG, mtr);
    flst_add_last(header + FSP_FULL_FRAG, descr + XDES_FLST_NODE, mtr);
  }
}
```

---

## 5. 文件打开与关闭

### 5.1 `fil_space_open`

```cpp
// fil0fil.cc:3530
bool fil_space_open(space_id_t space_id) {
  auto shard = fil_system->shard_by_id(space_id);
  shard->mutex_acquire();

  auto space = shard->get_space_by_id(space_id);
  if (space == nullptr) {
    shard->mutex_release();
    return false;
  }

  // 遍历所有文件节点，打开文件
  for (auto &node : space->files) {
    if (!node.is_open) {
      auto err = os_file_open(node.name, ...);
      node.handle = err;
      node.is_open = true;
    }
  }

  shard->mutex_release();
  return true;
}
```

### 5.2 `fil_space_close`

```cpp
// fil0fil.cc:3544
void fil_space_close(space_id_t space_id) {
  auto shard = fil_system->shard_by_id(space_id);
  shard->mutex_acquire();

  auto space = shard->get_space_by_id(space_id);
  for (auto &node : space->files) {
    if (node.is_open) {
      os_file_close(node.handle);
      node.is_open = false;
    }
  }

  shard->mutex_release();
}
```

---

## 6. 空闲列表补充 `fsp_fill_free_list`

当 `FSP_FREE` 链表为空时，从 `FSP_FREE_LIMIT` 之后的空间区域批量初始化新的 Extent：

```cpp
// fsp0fsp.cc（概念）
static void fsp_fill_free_list(bool use_mtr, fil_space_t *space,
                               fsp_header_t *header, mtr_t *mtr) {
  auto free_limit = mtr_read_ulint(header + FSP_FREE_LIMIT, MLOG_4BYTES, mtr);
  auto size = mtr_read_ulint(header + FSP_SIZE, MLOG_4BYTES, mtr);

  // 每次添加 FSP_FREE_ADD(=4) 个空闲 Extent
  auto limit = free_limit + FSP_FREE_ADD * FSP_EXTENT_SIZE;
  limit = std::min(limit, ut_uint64_align_down(size, FSP_EXTENT_SIZE));

  for (page_no_t i = free_limit; i < limit; i += FSP_EXTENT_SIZE) {
    // 初始化该 Extent 的 XDES → 设置为 XDES_FREE
    // 加入 FSP_FREE 链表尾部
  }

  mlog_write_ulint(header + FSP_FREE_LIMIT, limit, MLOG_4BYTES, mtr);
}
```

---

## 7. 页面释放 `fsp_free_page`

```cpp
// fsp0fsp.cc:1830
static void fsp_free_page(const page_id_t &page_id,
                          const page_size_t &page_size, mtr_t *mtr) {
  auto header = fsp_get_space_header(page_id.space(), page_size, mtr);
  auto descr = xdes_get_descriptor_with_space_hdr(header, page_id.space(),
                                                   page_id.page_no(), mtr);
  auto state = xdes_get_state(descr, mtr);             // line 1840

  // 断言该页当前为已分配状态
  ut_ad(state != XDES_FREE);

  // 在 XDES 位图中设置 FREE_BIT=1
  xdes_set_bit(descr, XDES_FREE_BIT, bit, true, mtr);  // line 1880
  xdes_set_bit(descr, XDES_CLEAN_BIT, bit, true, mtr);

  // 根据 frag 使用数，调整链表归属
  if (state == XDES_FULL_FRAG) {
    flst_remove(header + FSP_FULL_FRAG, descr + XDES_FLST_NODE, mtr);
    xdes_set_state(descr, XDES_FREE_FRAG, mtr);
    flst_add_last(header + FSP_FREE_FRAG, descr + XDES_FLST_NODE, mtr);
  }
  // 若整个 Extent 均为空闲，则移回 FSP_FREE 链表
}
```

---

## 8. 表空间类型与初始化

| 类型 | ID | 文件 | 说明 |
|------|----|------|------|
| 系统表空间 | 0 | `ibdata1` | 包含 Data Dictionary、Undo、Change Buffer |
| 临时表空间 | 0xFFFF... | `ibtmp1` | 临时表 |
| 用户表空间 | > 0 | `db/table.ibd` | 每个表一个文件（file-per-table） |
| undo 表空间 | > 0 | `undo_001` | 独立的 undo 日志文件 |

---

## 9. 总结

InnoDB 文件空间管理的核心设计：

1. **三级分配层次**：Segment → Extent (64 pages) → Page，减少元数据开销。
2. **XDES 位图**：每个 Extent 用 128 bits 管理 64 页的 FREE/CLEAN 状态，高效支持页面级的分配回收。
3. **链表管理**：FSP_FREE / FSP_FREE_FRAG / FSP_FULL_FRAG 三个链表按使用程度分级管理 Extent。
4. **懒初始化**：`fsp_fill_free_list` 仅在空闲 Extent 耗尽时按 `FSP_FREE_ADD`（4）批量准备新 Extent。
5. **原子写入**：所有空间元数据的修改（XDES 位图、链表操作）通过 MLOG 记录到 redo log 以保持 crash-safe。

### 源码引用汇总

| 文件 | 行号 | 关键内容 |
|------|------|----------|
| `fil0fil.h` | 160 | `struct fil_node_t` 定义 |
| `fil0fil.h` | 240 | `struct fil_space_t` 定义 |
| `fil0fil.cc` | 3530 | `fil_space_open()` |
| `fil0fil.cc` | 3544 | `fil_space_close()` |
| `fil0fil.cc` | 5692 | `fil_ibd_create()` |
| `fsp0fsp.h` | 293 | `enum xdes_state_t` (XDES_FREE/XDES_FREE_FRAG/XDES_FULL_FRAG/XDES_FSEG) |
| `fsp0fsp.cc` | 1007 | `fsp_header_init()` |
| `fsp0fsp.cc` | 1585 | `fsp_alloc_free_extent()` |
| `fsp0fsp.cc` | 1632 | `fsp_alloc_from_free_frag()` |
| `fsp0fsp.cc` | 1801 | `fsp_alloc_free_page()` |
| `fsp0fsp.cc` | 1830 | `fsp_free_page()` |
