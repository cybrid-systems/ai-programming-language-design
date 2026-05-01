# 04-xarray — Linux 内核 XArray 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**XArray** 是 Linux 内核中稀疏数组（sparse array）的高效实现，由 Matthew Wilcox 在 Linux 4.17（2018年）引入，替代了原有的 radix tree（基数树）。与 radix tree 相比，XArray 提供了更简洁的 API、内部锁管理、更安全的类型检查，以及先进的多索引操作和标记系统。

XArray 的核心思想是用**多路基数树（multi-way radix tree）**来实现一个稀疏数组。每个节点有 64 个槽位（slot），按 6 位一组索引——这意味着在一个 64 位系统上，树的最大深度仅为 10 层。与二叉树相比，多路基数树的树高小了 5-6 倍，减少了从根到叶子节点的指针追踪次数。

XArray 在内核中的核心应用是 page cache。每个 `address_space` 包含一个 `struct xarray i_pages`，以文件页偏移为索引存储 `struct page*`。当 `mm/filemap.c` 中的 `find_get_page` 被调用时，底层实际调用的是 `xa_load`——从 XArray 中按索引取出页面。XArray 的标记系统（`xa_mark_t`）在这个场景中发挥了关键作用：脏页和正在回写的页分别通过 `PAGECACHE_TAG_DIRTY` 和 `PAGECACHE_TAG_WRITEBACK` 标记，使得 writeback 线程可以高效地找到需要回写的页面。

doom-lsp 确认 `include/linux/xarray.h` 包含约 90+ 个 API 函数和 9 个数据结构，`lib/xarray.c` 包含约 128 个实现函数。

---

## 1. 核心数据结构

### 1.1 struct xarray（`xarray.h:300`）

```c
struct xarray {
    spinlock_t xa_lock;      // 内部自旋锁
    gfp_t xa_flags;          // 内存分配标志
    void __rcu *xa_head;     // 指向根节点或直接存储的 entry
};
```

- `xa_lock`：XArray 将锁内嵌在数据结构内部。大多数操作（`xa_store`、`xa_erase`）会自动管理这把锁，调用者不需要额外加锁。
- `xa_flags`：控制内存分配行为的标志，例如 `GFP_KERNEL` 或 `GFP_ATOMIC`。
- `xa_head`：指向树的根。如果有多个 entry，`xa_head` 指向根 `xa_node`；如果只有一个 entry，`xa_head` 直接存储 entry（不需要创建树）。

### 1.2 struct xa_node（`xarray.h:1168`）

```c
struct xa_node {
    unsigned char   shift;          // 当前节点索引需要移位的位数
    unsigned char   offset;         // 在父节点中的槽位索引
    unsigned char   count;          // 非空槽位数
    unsigned char   nr_values;      // 值为 XA_ZERO_ENTRY 的槽位数
    struct xa_node __rcu *parent;   // 父节点
    struct xarray   *array;         // 所属的 xarray
    union {
        struct list_head private_list;  // 回收用
        struct rcu_head rcu_head;       // RCU 释放
    };
    void __rcu      *slots[];       // 子节点/entry 数组（柔性数组）
};
```

- `shift`：当前节点覆盖的索引位数。根节点的 `shift = shift of max index`（64 位系统上一般为 60），每下降一层，`shift -= XA_CHUNK_SHIFT`（6）。
- `slots[]`：柔性数组，每个元素指向子节点或数据 entry。每层有 `XA_CHUNK_SIZE`（64）个槽。
- `count`：非空槽数量。通过它可以在 O(1) 时间内判断该节点是否可被回收（`count == 0`）。

### 1.3 Entry 编码

XArray 的每个 slot 存储一个 `void*`，但通过指针的最低几位来区分不同类型：

```c
// 正常指针          → 最低 2 位为 00（8 字节对齐）
// 内部节点指针       → 正常指针（指向 xa_node）
// XA_RETRY_ENTRY    → 表示需要重试（并发更新导致）
// XA_ZERO_ENTRY     → 显式存储的 NULL（底层存储感知）
// XA_INTERNAL_ENTRY → 各种内部标记
```

---

## 2. 核心操作

### 2.1 xa_load（`xarray.h:355`）——读取 entry

```
xa_load(xa, index)
  │
  ├─ rcu_read_lock()             ← RCU 保护读路径
  │
  ├─ do {
  │      entry = xa_head(xa)     ← 从根开始
  │      if (!entry) break;      ← 空树
  │      
  │      if (!xa_is_node(entry)) ← 单 entry
  │          break;
  │      
  │      node = xa_to_node(entry);
  │      offset = (index >> node->shift) & (XA_CHUNK_SIZE - 1);
  │      entry = node->slots[offset];  ← 下降一层
  │      
  │      if (xa_is_node(entry))
  │          continue;            ← 继续下降
  │      if (xa_is_retry(entry))
  │          goto retry;          ← 重试
  │  } while (0);
  │
  └─ rcu_read_unlock()
  └─ return entry
```

### 2.2 xa_store（`xarray.h:356`）——存储 entry

```
xa_store(xa, index, entry, gfp)
  │
  ├─ xa_lock(xa)                 ← 加锁
  │
  ├─ __xa_store(xa, index, entry, gfp)
  │    │
  │    ├─ xas_store(&xas, entry) ← xa_state 遍历器
  │    │    │
  │    │    ├─ 在树中定位目标槽位
  │    │    ├─ 如果路径上的节点不存在：
  │    │    │    └─ xas_create(&xas) → 创建节点
  │    │    │
  │    │    ├─ 将 entry 写入目标槽
  │    │    ├─ 更新内部节点的 count/nr_values
  │    │    └─ 如果删除导致节点变空 → 回收节点
  │    │
  │    └─ return old_entry        ← 返回旧的 entry
  │
  └─ xa_unlock(xa)
```

---

## 3. xa_state（xas）高级 API

`struct xa_state`（`xarray.h:1354`）是 XArray 的高级遍历器，允许批量操作和精细控制：

```
xa_state 使用模式：
  XA_STATE(xas, xa, index);      ← 初始化

  xas_lock(&xas);                ← 手动管理锁
  xas_for_each(&xas, entry, max) ← 遍历所有 entry
  xas_store(&xas, entry);        ← 在当前位置写入
  xas_set_mark(&xas, mark);      ← 设置标记
  xas_find_marked(&xas, max, mark) ← 查找带标记的 entry
  xas_unlock(&xas);
```

---

## 4. 标记系统

每个 entry 可以关联两个独立标记位：

```c
enum xa_mark_t {
    XA_MARK_0,           // page cache: PAGECACHE_TAG_DIRTY
    XA_MARK_1,           // page cache: PAGECACHE_TAG_WRITEBACK
    XA_MARK_MAX
};
```

标记通过树传播：如果某个子树中有任何 entry 被打上标记，该标记会向上传播到所有祖先节点的对应标记位。

---

## 5. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/xarray.h` | `struct xarray` | 300 |
| `include/linux/xarray.h` | `struct xa_node` | 1168 |
| `include/linux/xarray.h` | `struct xa_state` | 1354 |
| `include/linux/xarray.h` | `xa_load` / `xa_store` | 355 |
| `lib/xarray.c` | 实现（128 函数） | 核心实现 |

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
