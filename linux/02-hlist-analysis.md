# 02-hlist — 散列链表深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**hlist**（hash list）是专为散列表设计的**单向链表**变体。与 list_head 不同，hlist 的头节点只包含一个 `first` 指针（没有 `prev`），使得散列表在内存使用上显著优化——每个 hash bucket 只需要一个指针，而不是双向链表的两个指针。

hlist 的核心设计理念：**用空间换时间的场景反向优化**。散列表中大部分 bucket 是空的，空 bucket 的头节点如果也存储双向指针，会造成大量浪费（每个空 bucket 多存储一个指针）。hlist 让头节点只存一个指针，仅在非空节点上存储双向指针，实现了空间与功能的平衡。

---

## 1. 核心数据结构

### 1.1 struct hlist_head（`include/linux/list.h:42`）

```c
struct hlist_head {
    struct hlist_node *first;   // 指向第一个节点，NULL=空
};
```

仅 8 字节（单指针），而 list_head 的头节点需要 16 字节。

### 1.2 struct hlist_node（`include/linux/list.h:48`）

```c
struct hlist_node {
    struct hlist_node *next;    // 指向下一个节点
    struct hlist_node **pprev;  // 指向前一个节点的 next 指针的地址
};
```

**关键设计：`pprev` 不是指向"前一个节点"的地址，而是指向前一个节点的 `next` 字段的地址。** 这解决了单向链表中删除操作需要遍历前驱的问题。

删除时的操作：
```c
static inline void __hlist_del(struct hlist_node *n)
{
    struct hlist_node *next = n->next;
    struct hlist_node **pprev = n->pprev;

    WRITE_ONCE(*pprev, next);   // 让前一个节点的 next 跳过当前节点
    if (next)
        next->pprev = pprev;    // 修复后一个节点的 pprev
}
```

不需要遍历链表找到前驱——因为 `pprev` 直接指向了"前驱指向我的地方"。

---

## 2. 与 list_head 对比

| 特性 | list_head | hlist |
|------|-----------|-------|
| 头节点大小 | 16 字节（2 ptr） | 8 字节（1 ptr） |
| 节点大小 | 16 字节（2 ptr） | 16 字节（2 ptr） |
| head 判空 | `head->next == head` | `head->first == NULL` |
| 双向遍历 | ✅ 支持反向 | ❌ 仅正向 |
| 删除 | O(1) | O(1) |
| 适用场景 | 通用链表 | 散列表 |
| RCU 支持 | ✅ | ✅ |

核心差异在于：**hlist 牺牲了反向遍历和"头节点 = 哨兵"的优雅设计，换来了更小的头节点和同样 O(1) 的删除能力。**

---

## 3. 关键操作

### 3.1 hlist_add_head（`include/linux/list.h:76`）

```c
static inline void hlist_add_head(struct hlist_node *n, struct hlist_head *h)
{
    struct hlist_node *first = h->first;
    n->next = first;
    if (first)
        first->pprev = &n->next;
    WRITE_ONCE(h->first, n);
    n->pprev = &h->first;
}
```

散列表插入通常都在 bucket 头部进行（LIFO 顺序），因为 `hlist_add_head` 比尾部插入更高效。

### 3.2 hlist_unhashed（`include/linux/list.h:60`）

```c
static inline int hlist_unhashed(const struct hlist_node *h)
{
    return !h->pprev;
}
```

判断节点是否不在任何链表中。当节点被删除时，`pprev` 被设为 `NULL`，这比 list_head 的毒化指针方案更轻量。

---

## 4. 遍历宏

```c
// include/linux/list.h:97
#define hlist_for_each(pos, head) \
    for (pos = (head)->first; pos; pos = pos->next)

#define hlist_for_each_entry(pos, head, member)                   \
    for (pos = hlist_entry_safe((head)->first, typeof(*pos), member); \
         pos;                                                     \
         pos = hlist_entry_safe(pos->member.next, typeof(*(pos)), member))

#define hlist_for_each_entry_safe(pos, n, head, member)           \
    for (pos = hlist_entry_safe((head)->first, typeof(*pos), member); \
         pos && ({ n = pos->member.next; 1; });                   \
         pos = hlist_entry_safe(n, typeof(*(pos)), member))
```

遍历终止条件是 `pos != NULL`，而非 list_head 的 `pos != head`。

---

## 5. 应用场景：内核散列表

hlist 广泛用于内核中所有散列表的实现。doom-lsp 追踪到以下典型使用：

```
哈希表                   使用 hlist_bucket 的原因
─────────────────────────────────────────────────
inode hash              大量 inode，空 bucket 多
dentry hash             dcache 可能大部分 bucket 为空
pid hash                进程数 << bucket 数
module hash             模块数通常远少于 bucket
socket hash             连接数动态变化
```

---

## 6. 数据类型流

```
struct hlist_head         // 8 字节，散列表 bucket
    └─ first              // 指向链表第一个节点

struct hlist_node         // 16 字节，链表节点
    ├─ next               // 向后指针
    └─ pprev              // 指向前驱的 next 指针的地址
                          // **关键**: &(prev->next) 或 &(head->first)

插入（头部）：
  hlist_add_head(n, head)
    → n->next = head->first
    → if (old_first) old_first->pprev = &n->next
    → head->first = n
    → n->pprev = &head->first

删除：
  hlist_del(n)
    → *(n->pprev) = n->next     // 前驱"指向我的地方"跳过 n
    → if (n->next) n->next->pprev = n->pprev
    → n->pprev = LIST_POISON2   // 毒化
```

---

## 7. 设计决策总结

| 决策 | 原因 |
|------|------|
| 头节点只有 first | 节省内存，空 bucket 只浪费 8 字节 |
| pprev 是二级指针 | 实现 O(1) 删除，无需遍历找前驱 |
| LIFO 插入 | 散列表常用头部插入，cache 性能好 |
| 不支持反向遍历 | 散列表不需要反向遍历 |

---

## 8. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/list.h` | `struct hlist_head` | 42 |
| `include/linux/list.h` | `struct hlist_node` | 48 |
| `include/linux/list.h` | `hlist_add_head` | 76 |
| `include/linux/list.h` | `hlist_del` | 86 |

---

## 9. 关联文章

- **list_head**（article 01）：双向循环链表，hlist 的对照物
- **rhashtable**（article 03 关联）：使用 hlist 的可扩容散列表

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
