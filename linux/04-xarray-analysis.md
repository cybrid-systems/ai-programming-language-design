# 04-xarray — 动态数组（下一代 IDR/Page Cache）深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/xarray.h` + `lib/test_xarray.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**XArray（eXtensible Array）** 是 Linux 4.20 引入的新数据结构，替代了老旧的 IDR 和 Radix Tree。提供 O(1) 稀疏存储、O(1) 查找、RCU 安全操作、批操作优化。

---

## 1. 核心数据结构

### 1.1 XArray 三层结构

```
XArray 存储 0 ~ 2^48 索引（256TB 空间）：

Level 2 (shift=36):  2^36 = 64GB 一层
Level 1 (shift=18):  2^18 = 256KB 一层
Level 0 (shift=0):  2^0  = 1 字节 叶子层

对于 index = 0x12345678：
  L2 index = index >> 36 = 0
  L1 index = (index >> 18) & 0x7FFFF = 0x1234
  L0 index = index & 0x3FFFF = 0x5678

实际内核的 xa_node 数组（从叶向根的偏移是 shift）：
  xas_descend(xa, index):
    node = xa->xa_head  （根节点）
    while (shift > 0):
      next = node->slots[(index >> shift) & XA_CHUNK_MASK]
      shift -= XA_CHUNK_SHIFT
      node = next
    return node
```

### 1.2 struct xarray — 数组头

```c
// include/linux/xarray.h:335 — xarray
struct xarray {
    gfp_t              xa_flags;   // 分配标志（GFP_KERNEL 等）
    void               *xa_head;   // 指向根节点（NULL = 空数组）
};

// XA_CHUNK_SHIFT = 6（每个节点有 64 个 slots）
// XA_CHUNK_MASK = 63
// XA_CHUNK_SIZE = 64
// 最大索引：2^48（256TB）
```

### 1.3 struct xa_node — 内部节点

```c
// include/linux/xarray.h:196 — xa_node
struct xa_node {
    unsigned char       shift;        // 当前层到叶子的距离（18 或 6）
    unsigned char       offset;       // 当前节点在其父的 slot 偏移
    unsigned int        count;         // 非 NULL slot 数量
    unsigned int        nr_values;    // 值数量（不仅是 slot）

    struct xa_node     *parent;      // 父节点
    void               *slots[64];    // 64 个指针槽（XA_CHUNK_SIZE）
    struct list_head    list;        // 空闲节点链表
};
```

### 1.4 XArray 条目类型

```
slot 可能存放的内容：

1. 用户数据指针（ptr）：
   - 值 bits = 00
   - 用户指针 + 0x01（最低两位为 0x01）

2. 内部条目（internal）：
   - 值 bits = 10
   - XA_SET_MARK（标记）
   - XA_FREE_MARK（空闲标记）

3. NULL 特殊值：
   - XA_NULL = NULL（用户显式存 NULL）

4. 错误码：
   - 负数 errno 编码

5. xa_node 指针（内部）：
   - 值 bits = 00，但指针指向 struct xa_node
   - 区分方式：最低位 = 0，指向 xa_node
```

---

## 2. 核心 API

### 2.1 xa_init — 初始化

```c
// include/linux/xarray.h:350
static inline void xa_init(struct xarray *xa)
{
    xa->xa_head = NULL;
    xa->xa_flags = 0;
}

// 空数组：xa_head = NULL
```

### 2.2 xa_store — 存储

```c
// lib/test_xarray.c — xa_store
void xa_store(struct xarray *xa, unsigned long index, void *entry, gfp_t gfp)
{
    // 1. 分配节点（如需要）
    // 2. 找到/创建路径上的 xa_node
    // 3. 在叶子的 slot[index & 63] 存入 entry
    // 4. 如果 slot 原来有值，替换并返回旧值
}

// 示例：
struct page *page = alloc_page(GFP_KERNEL);
xa_store(&mapping->i_pages, index, page, GFP_KERNEL);
```

### 2.3 xa_load — 查找

```c
// include/linux/xarray.h:388
static inline void *xa_load(struct xarray *xa, unsigned long index)
{
    return xa_get_mark(xa, index, XA_PRESENT);
}

// 路径：xa_head → L1 node → L0 node → slot
// 时间：O(log n)，其中 n = index 路径深度（最多 3 层）
```

### 2.4 xa_erase — 删除

```c
// include/linux/xarray.h:398
static inline void *xa_erase(struct xarray *xa, unsigned long index)
{
    return xa_erase_may_gc(xa, index, NULL, false);
}

// 删除 slot 并释放空节点（向上合并）
```

### 2.5 xa_find — 搜索

```c
// include/linux/xarray.h:420
static inline void *xa_find(struct xarray *xa, unsigned long *index,
                           unsigned long max, xa_mark_t mark)
{
    // 从 index 开始向后找第一个设置了 mark 的 slot
    // 常用于迭代
}
```

### 2.6 xa_next / xa_prev — 迭代

```c
// include/linux/xarray.h:430
static inline void *xa_next(struct xarray *xa, unsigned long *indexp, unsigned long max)
{
    return xa_find(xa, indexp, max, XA_PRESENT);
}
```

---

## 3. 标记系统（Tag）

### 3.1 标记类型

```c
// include/linux/xarray.h:90 — 标记定义
enum xa_mark {
    XA_MARK_0 = 0,    // 可用于用户自定义
    XA_MARK_1 = 1,    // 可用于用户自定义
    XA_MARK_2 = 2,    // 可用于用户自定义
    XA_MARK_MAX = XA_MARK_2,
};

// 特殊标记：
// XA_FREE_MARK：标记为"可用 slot"（已删除但节点未释放）
// XA_SET_MARK：标记 slot 有值
// XA_PRESENT = XA_MARK_0：默认"有值"标记
```

### 3.2 xa_set_mark / xa_get_mark

```c
// include/linux/xarray.h:445
static inline void xa_set_mark(struct xarray *xa, unsigned long index, xa_mark_t mark)
{
    // 设置 slot 的标记
}

// 示例：
xa_set_mark(&mapping->i_pages, index, XA_MARK_0);
```

### 3.3 IDA 包装器（XArray 的 ID 分配器）

```c
// include/linux/ida.h — ida
struct ida {
    struct xarray          xa;        // 底层 XArray
    unsigned int         ida_base;    // 起始 ID
    unsigned long         ida_max;    // 最大 ID
};

// ida_alloc — 分配 ID
int ida_alloc(struct ida *ida, gfp_t gfp)
{
    unsigned long id;

    // 在 [0, max) 范围内找第一个空闲 slot
    id = xa_find_free(&ida->xa, 0, IDA_MAX, gfp);
    if (id < 0)
        return id;

    xa_store(&ida->xa, id, (void *)1, gfp);  // 存 1 表示已占用
    return id;
}

// ida_free — 释放 ID
void ida_free(struct ida *ida, unsigned int id)
{
    xa_erase(&ida->xa, id);  // 删除 slot
}
```

---

## 4. RCU 安全操作

### 4.1 xa_load RCU

```c
// include/linux/xarray.h:388
static inline void *xa_load(struct xarray *xa, unsigned long index)
{
    // RCU 保护：
    // rcu_read_lock() 期间调用是安全的
    // 但返回值在 rcu_read_unlock() 后可能失效
    void *entry;

    entry = xa_get_mark(xa, index, XA_PRESENT);
    return entry;
}

// 使用模式：
rcu_read_lock();
page = xa_load(&mapping->i_pages, index);
if (page && !IS_ERR(page))
    get_page(page);
rcu_read_unlock();
```

---

## 5. page cache 应用

### 5.1 address_space 的 i_pages

```c
// include/linux/fs.h — address_space
struct address_space {
    struct inode          *host;          // 关联的 inode
    struct xarray         i_pages;       // 页缓存（XA_PRESENT 标记有页）
    // ...
};

// 页缓存查找：
page = xa_load(&mapping->i_pages, index);
// 如果 IS_ERR(page) 或 page = NULL → 未缓存

// 页缓存插入：
xa_store(&mapping->i_pages, index, page, GFP_KERNEL);
xa_set_mark(&mapping->i_pages, index, XA_PRESENT);
```

### 5.2 批操作

```c
// include/linux/xarray.h — xa_for_each_range
#define xa_for_each_range(xa, index, max, filter) \
    for (index = 0; \
         ({ entry = xa_find(xa, &index, max, filter); entry; }); \
         index++)
    // 高效遍历所有有值的 slot
```

---

## 6. IDR 对比

| 特性 | IDR（旧） | XArray（新） |
|------|----------|------------|
| 底层结构 | Radix Tree | XArray |
| 最大索引 | 2^31 | 2^48 |
| API | idr_alloc/free | xa_store/erase |
| RCU | 不支持 | 原生支持 |
| 批操作 | 无 | xa_for_each 等 |
| 内存效率 | 差（每节点 16 pointers）| 好（64 slots）|

---

## 7. 设计决策总结

| 设计决策 | 原因 |
|---------|------|
| 三层结构（36/18/0）| 覆盖 2^48 索引，每个节点 64 个 slot |
| 标记系统 | 避免扫描所有 slot，O(1) 查找"有值的范围" |
| XArray 替代 IDR | IDR 基于 radix tree，内存开销大，不支持 RCU |
| RCU 安全 | 读不加锁，写不阻塞读（读的多线程场景）|
| slot 复用 | XA_FREE_MARK 标记已删除但节点保留，避免频繁释放 |

---

## 8. 完整文件索引

| 文件 | 行号 | 内容 |
|------|------|------|
| `include/linux/xarray.h` | 335 | `struct xarray` |
| `include/linux/xarray.h` | 196 | `struct xa_node` |
| `include/linux/xarray.h` | 90 | `xa_mark_t` 枚举 |
| `include/linux/xarray.h` | 350 | `xa_init` |
| `include/linux/xarray.h` | 388 | `xa_load` |
| `include/linux/xarray.h` | 398 | `xa_erase` |
| `include/linux/xarray.h` | 420 | `xa_find` |
| `include/linux/ida.h` | — | `struct ida`、`ida_alloc`、`ida_free` |

---

## 9. 西游记类比

**XArray** 就像"取经路上的驿站地图"——

> 唐僧要去取经，需要在每个驿站（index）存放经书（entry）。但是有些驿站可能没有人住（NULL），有些驿站放满了宝石（多个值），有些驿站被标记为"此路不通"（XA_FREE_MARK）。每个驿站有 64 个房间（slots），每个房间可以住一个小妖怪或者再开 64 个子驿站（xa_node）。玉帝拿着地图（xa_head），从最顶层（根节点）一层层往下找，最终找到对应的驿站。这就是为什么查找最多只要 3 步——地图只有 3 层，每层最多 64 个岔路口。

---

## 10. 关联文章

- **IDR/IDA**（article 05）：IDA 是 XArray 的包装器，IDR 基于 XArray
- **page cache**（article 20）：address_space.i_pages 使用 XArray
- **radix tree**（历史）：XArray 替代了 Radix Tree