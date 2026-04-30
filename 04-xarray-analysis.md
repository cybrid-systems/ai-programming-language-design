# XArray — 内核新型数组索引深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/xarray.h` + `lib/test_xarray.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照
> 行号索引：xarray.h 全文

---

## 0. 概述

**XArray** 是 Linux 4.20 引入的**替代 IDA（IDR）的新型数组索引**，用于稀疏数组的高效存储和查找。相比 IDA：

- **空间优化**：稀疏数组不浪费内存
- **操作原子化**：所有操作都是 RCU 安全的
- **API 简化**：统一了 store/load/erase/slot API
- **Tag 支持**：支持标记（XA_MARK_0/1/2）批量操作

---

## 1. 核心数据结构

### 1.1 xarray — 数组锚点

```c
// include/linux/xarray.h:300 — struct xarray
struct xarray {
    spinlock_t      xa_lock;        // 保护整个数组的自旋锁
    gfp_t          xa_flags;      // 分配标志（GFP_*）
    void __rcu     *xa_head;       // RCU 保护的指向 xa_node 或 entry 的指针
};
```

**三种状态的 `xa_head`**：

| 状态 | `xa_head` 值 | 含义 |
|------|--------------|------|
| 全空 | `NULL` | 整个数组为空 |
| 唯一 entry | 指向 entry 的指针 | 仅 index 0 有值（XA 优化）|
| 多 entry | 指向 `xa_node` | 需要查树 |

### 1.2 xa_node — 内部节点

```c
// 内部结构，xarray.h 不直接暴露
// 但可以从测试代码推断其结构：

struct xa_node {
    unsigned long   shift;    // 当前层级（shift = 0/6/12/18/24/30）
    unsigned long   offset;   // 父节点中的偏移
    unsigned long   count;    // 此节点中的 entry 数量
    unsigned long   nr_values; // 非 NULL entry 数量
    struct xa_node *parent;  // 父节点
    void            *slots[XA_CHUNK_SIZE]; // 指针数组（通常 16 或 32）
    // ...
};

// XA_CHUNK_SIZE = 16（每节点 16 个槽）
// 最大深度 = 6 层（16^6 = 16M 项）
```

### 1.3 标记系统

```c
// include/linux/xarray.h
// 标记类型：
typedef unsigned int xa_mark_t;

#define XA_MARK_0   0   // 普通标记
#define XA_MARK_1   1
#define XA_MARK_2   2
#define XA_PRESENT  3   // 特殊：表示 slot 有值
```

---

## 2. xa_store — 存储 entry

```c
// include/linux/xarray.h:356
void *xa_store(struct xarray *xa, unsigned long index, void *entry, gfp_t);
```

**算法**：
```
xa_store(xa, index=100, entry)
    ↓
1. 申请 xa_lock 自旋锁
    ↓
2. 如果 index == 0 且 xa_head == NULL:
       → 直接存储 entry 到 xa_head（优化路径）
    ↓
3. 否则：
    → 分配 xa_node（如果需要）
    → 沿着树向下找到对应 slot
    → 设置 slot = entry
    → 更新父节点 count/nr_values
    ↓
4. 释放锁
    ↓
5. 返回原 entry（或 NULL）
```

**图示（多层树）**：
```
xa_head ──► xa_node (shift=18, offset=0)
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
    xa_node (shift=12)    xa_node (shift=12)
         │                       │
    ┌────┴────┐            ┌────┴────┐
    ▼         ▼            ▼         ▼
  slot[0]  slot[1]    slot[2]  slot[3]
```

---

## 3. xa_load — 加载 entry

```c
// include/linux/xarray.h:355
void *xa_load(struct xarray *xa, unsigned long index);
```

**算法**：
```
xa_load(xa, index)
    ↓
1. 读取 xa_head（RCU 保护）
    ↓
2. 如果 xa_head == NULL:
       → 返回 NULL（空数组）
    ↓
3. 如果 xa_head 是 entry（index==0 且只有一项）：
       → 返回 xa_head
    ↓
4. 否则：
    → 遍历 xa_node 层
    → 计算每层的 offset = (index >> shift) & (XA_CHUNK_SIZE-1)
    → 从 slots[offset] 取出下一层节点或 entry
    ↓
5. 返回 entry（或 NULL）
```

---

## 4. xa_erase — 删除 entry

```c
// include/linux/xarray.h:357
void *xa_erase(struct xarray *xa, unsigned long index);
```

**特点**：
- 删除后释放空闲的 xa_node（向上合并）
- 返回被删除的 entry

---

## 5. xa_find / xa_find_after — 查找下一个有值位置

```c
// include/linux/xarray.h:363
void *xa_find(struct xarray *xa, unsigned long *index,
        unsigned long max, xa_mark_t);
```

**用途**：批量遍历有值的 slot

```c
unsigned long index = 0;
void *entry;
xa_for_each(xa, &index, XA_PRESENT) {
    printk("found at %lu: %p\n", index, entry);
}
```

---

## 6. 内部节点层级（多层树）

**Linux XArray 使用 6 层树结构**（每层 16 个 slot）：

| 层 | shift | 覆盖范围 |
|----|-------|---------|
| Level 0 | 30 | 2^30 = 1G 项 |
| Level 1 | 24 | 2^24 = 16M 项 |
| Level 2 | 18 | 2^18 = 256K 项 |
| Level 3 | 12 | 2^12 = 4K 项 |
| Level 4 | 6 | 2^6 = 64 项 |
| Level 5 | 0 | 16 项 |

**为什么用 16 个 slot**？
- 每个节点 16 个指针，内存友好（Cache line 友好）
- 层级数 = log₁₆(N)

---

## 7. 与 IDA 的对比

| 特性 | IDA | XArray |
|------|-----|--------|
| 存储 | 径向树（radix tree）| 改进的径向树 |
| 最大索引 | 2^31 | 2^32 |
| Tag 支持 | 无 | XA_MARK_0/1/2 |
| API | idr_alloc / idr_find | xa_store / xa_load |
| RCU 安全 | 需手动实现 | 原生支持 |

---

## 8. 内核使用案例

### 8.1 page cache（页缓存）

```c
// include/linux/pglist_data.h — radix_tree
struct radix_tree_root {
    unsigned int            height;
    struct radix_tree_node  *rnode;
};
```

XArray 替代了旧 radix_tree 用于 page cache：

```c
// mm/filemap.c — pagecache
struct address_space {
    struct xarray          i_pages;    // 页缓存
    // ...
};
```

### 8.2 IDR（现在用 XArray 实现）

```c
// include/linux/idr.h — IDR 包装在 XArray 上
struct idr {
    struct xarray  xa;
    // ...
};
```

---

## 9. 完整文件索引

| 文件路径 | 关键行 | 内容 |
|---------|-------|------|
| `include/linux/xarray.h` | 300 | `struct xarray` |
| `include/linux/xarray.h` | 355 | `xa_load` |
| `include/linux/xarray.h` | 356 | `xa_store` |
| `include/linux/xarray.h` | 357 | `xa_erase` |
| `include/linux/xarray.h` | 363 | `xa_find` |
| `include/linux/xarray.h` | 453 | `xa_for_each` |
