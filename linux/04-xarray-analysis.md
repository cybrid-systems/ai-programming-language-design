# 04-xarray — XArray 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**XArray** 是 Linux 内核中稀疏数组的高效实现，由 Matthew Wilcox 在 Linux 4.17 中引入，用来替代原有的 radix tree。与 radix tree 相比，XArray 提供更简洁的 API，更好的类型安全性，以及内部锁管理。

XArray 的核心思想：**用基数树（radix tree）实现一个稀疏数组，支持按索引快速存取，覆盖 `void*` 指针的存储**。它被广泛用于 page cache（`address_space` 的页索引）、内存文件系统、及各种需要索引映射的场景。

doom-lsp 确认 `include/linux/xarray.h` 包含约 680+ 个符号，其中 17+ 个结构体，实现位于 `lib/xarray.c`（约 2000 行）。

---

## 1. 核心数据结构

### 1.1 struct xarray（`include/linux/xarray.h:75`）

```c
struct xarray {
    spinlock_t xa_lock;   // 内部自旋锁
    gfp_t xa_flags;       // 分配标志
    void __rcu *xa_head;  // 指向根节点（或直接存储的 entry）
};
```

XArray 将锁封装在结构体内部，多数操作自动管理锁。`xa_flags` 控制内存分配行为（如 `GFP_KERNEL`），`xa_head` 是树的根指针。

### 1.2 struct xa_node（`include/linux/xarray.h:81`）

```c
struct xa_node {
    unsigned char   shift;     // 在当前节点，索引需要移位的位数
    unsigned char   offset;    // 节点在父节点中的槽位索引
    unsigned char   count;     // 非空槽位数
    unsigned char   nr_values; // 值为 XA_ZERO_ENTRY 的槽位数
    struct xa_node __rcu *parent;  // 父节点
    struct xarray   *array;    // 所属 xarray
    union {
        struct list_head private_list;  // 回收用
        struct rcu_head rcu_head;       // RCU 释放
    };
    void __rcu      *slots[];  // 子节点/entry 数组
};
```

关键点：
- `slots[]` 是柔性数组，每层有 `XA_CHUNK_SIZE`（通常 64）个槽
- `shift`：该层索引的偏移量，每层为 `XA_CHUNK_SHIFT`（6）
- 多路基数树：每个节点 64 路分支，比二叉树的 O(log n) 更浅

### 1.3 Entry 编码

XArray 使用位编码来区分各种 entry 类型：

```
正常指针           → 直接存储（最低 2 位为 0）
内部 xa_node       → 正常指针（通过 xa_to_node() 访问）
XA_RETRY_ENTRY     → 表示需要重试
XA_ZERO_ENTRY      → 表示值为 0 的条目
XA_INTERNAL_ENTRY  → 各种内部标记
```

所有奇葩 entry 通过 `xa_mk_internal()` 编码，确保不与有效指针冲突。

---

## 2. 核心操作

### 2.1 设置值（xa_store）

```
xa_store(xa, index, entry, gfp)
  │
  ├─ 查找或创建路径
  │    └─ __xa_store
  │         ├─ xas_store(&xas, entry)
  │         │    └─ 在树中定位/创建节点，设置 entry
  │
  └─ 返回值：旧的 entry（如果有的话）
```

### 2.2 取值（xa_load）

```c
void *xa_load(struct xarray *xa, unsigned long index)
{
    XA_STATE(xas, xa, index);    // 初始化遍历状态
    void *entry;

    rcu_read_lock();              // RCU 保护
    do {
        entry = xas_load(&xas);   // 遍历树找到目标
        if (xas_retry(&xas, entry)) // 如果遇到重试标记
            continue;
        break;
    } while (true);
    rcu_read_unlock();

    return entry;
}
```

`xas_load` 返回的 entry 可能是：
- `NULL`：槽位为空
- 有效指针：用户数据
- `XA_RETRY_ENTRY`：并发操作导致，需要重试

### 2.3 条件操作（xa_cmpxchg）

```c
void *xa_cmpxchg(struct xarray *xa, unsigned long index,
                 void *old, void *entry, gfp_t gfp);
```

原子的比较-交换操作，常用于实现无锁或半无锁的数据结构（如 "如果槽位是 NULL，设置为新值"）。

---

## 3. 高级 API：xa_state

XArray 设计了 `struct xa_state`（xas）作为高级遍历器。与基础 API 不同，xas 允许：

```c
XA_STATE(xas, xa, index);   // 初始化

// 查找
entry = xas_load(&xas);      // 加载当前 entry
entry = xas_find(&xas, max); // 从当前位置查找下一个非空 entry
entry = xas_find_range(&xas);// 查找连续非空区间

// 写入
xas_store(&xas, entry);      // 在当前索引写入
xas_create(&xas);            // 确保路径上的节点已创建

// 迭代
xas_for_each(&xas, entry, max) {  // 遍历所有非空 entry
    // ...
}

// 标记
xas_set_mark(&xas, mark);    // 设置标记
xas_clear_mark(&xas, mark);  // 清除标记
xas_get_mark(&xas, mark);    // 检查标记
```

xas 的高级特性：多索引操作（`xas_set_range`）、标记操作（每个 entry 可关联位标记）、批量查找。

---

## 4. 标记系统

XArray 支持在任意 entry 上设置 2 个独立的标记位（`XA_MARK_0` 和 `XA_MARK_1`）。page cache 中，标记被用于：

```
XA_MARK_0 = PAGECACHE_TAG_DIRTY      ← 脏页标记
XA_MARK_1 = PAGECACHE_TAG_WRITEBACK  ← 回写中标记
```

标记通过 `xa_mark_node` 树中的内部节点传播：如果一个子树中有任何 entry 被打上标记，该标记会向上传播到根节点路径。这使得 `xa_find_marked`（查找第一个被打标记的 entry）可以在 O(1)~O(log n) 时间内完成。

---

## 5. 数据类型流

```
xa_load(index)
  │
  ├─ rcu_read_lock()
  │
  ├─ xas_load(&xas)        // 从 xa_head 开始，逐层下降
  │    ├─ root = xa->xa_head
  │    ├─ 提取 index 的高 6 位 → root 的槽位
  │    ├─ 如果槽位指向 xa_node → 下降一层
  │    ├─ 提取 index 的下 6 位 → xa_node.slots[offset]
  │    ├─ ... 直到叶子层 ...
  │    └─ 返回 slots 中的 entry
  │
  ├─ 如果遇到 XA_RETRY_ENTRY → 重试
  │
  └─ rcu_read_unlock()
  └─ 返回 entry

xa_store(xa, index, entry)
  │
  ├─ xa_lock(xa)
  │
  ├─ __xa_store
  │    ├─ xas_create(&xas)  // 确保路径节点存在
  │    │    └─ 逐层创建 xa_node（需要内存分配）
  │    ├─ xas_store(&xas, entry)
  │    │    └─ 写入目标槽位
  │    └─ 返回旧 entry
  │
  └─ xa_unlock(xa)
```

---

## 6. 设计决策总结

| 决策 | 原因 |
|------|------|
| 内部锁（`xa_lock`） | API 更简洁，减少调用者负担 |
| 多路基数树（64 路/层） | 树高最大约 10（64位），优于二叉树 |
| 标记系统 | 高效查找"脏页"等带标记的 entry |
| xa_state 高级 API | 允许批量操作、自定义遍历 |
| RCU 保护读路径 | 读写不互斥，高性能 |

---

## 7. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/xarray.h` | `struct xarray` | 75 |
| `include/linux/xarray.h` | `struct xa_node` | 81 |
| `include/linux/xarray.h` | `xa_load` | inline |
| `lib/xarray.c` | `xa_store` | 实现 |
| `lib/xarray.c` | `__xa_store` | 实现 |
| `mm/filemap.c` | `page_cache_*` | page cache 使用者 |

---

## 8. 关联文章

- **page cache**（article 20）：XArray 是 page cache 的底层数据结构
- **idr**（article 05）：XArray 的前身（但 idr 仍在使用）
- **radix tree**：XArray 的原有实现，已内化到 xarray

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
