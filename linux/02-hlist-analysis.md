# 02-hlist — 单向链表（哈希表专用）深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/list.h` + `include/linux/list_nulls.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**hlist（哈希链表）** 是 list_head 的变体，专为 hash table 桶设计：只需要 O(1) 头插入、O(1) 删除，但不需要双向遍历。内存节省一半（8 字节 vs 16 字节）。

---

## 1. 核心数据结构

### 1.1 struct hlist_head — 哈希桶头

```c
// include/linux/list.h:558 — hlist_head
struct hlist_head {
    struct hlist_node  *first;   // 指向第一个节点（NULL = 空桶）
};
// 只有 8 字节（vs list_head 的 16 字节）
// 因为 hlist 是单向的，只需要 next，不需要 prev
```

### 1.2 struct hlist_node — 哈希链表节点

```c
// include/linux/list.h:552 — hlist_node
struct hlist_node {
    struct hlist_node  *next;    // 指向下一个节点
    // 注意：没有 prev 指针！
    // prev 需要从哈希桶或其他节点间接获取
};
```

### 1.3 内存布局对比

```
list_head（双向）：              hlist_node（单向）：
[prev指针 | next指针]          [next指针]
= 16 字节（64位）               = 8 字节（64位）

hash table 桶（hlist_head）：
[first指针] = 8 字节            空桶：first = NULL

hlist 插入后：
  head.first ──→ [node1] ──→ [node2] ──→ NULL
                 [node1].next = &node2
                 [node2].next = NULL
```

---

## 2. 核心操作函数

### 2.1 hlist_add_head — 头部插入

```c
// include/linux/list.h:567
static inline void hlist_add_head(struct hlist_node *n, struct hlist_head *h)
{
    struct hlist_node *first = h->first;

    n->next = first;
    if (first)
        first->pprev = &n->next;   // 关键：记录 node1 的 pprev
    h->first = n;
    n->pprev = &h->first;         // n 的 pprev 指向 head.first 的地址
}

// 关键设计：pprev 是"指向当前节点 next 指针的指针"（二级指针）
// 这样在 O(1) 删除时能直接找到前驱节点的 next 指针
```

**内存布局：**

```
head.first ──→ [n] ──→ [node1] ──→ [node2] ──→ NULL
              ↑        ↑
         n->pprev    n->next = first
         (&h->first) (&n->next)

对于 node1：
  node1->next = &node2
  node1->pprev = &n->next  （指向前一个节点的 next 指针的地址）
```

### 2.2 hlist_add_before — 在节点前插入

```c
// include/linux/list.h:585
static inline void hlist_add_before(struct hlist_node *n,
                                    struct hlist_node *next)
{
    n->pprev = next->pprev;
    n->next = next;
    next->pprev = &n->next;
    *(n->pprev) = n;
}
```

### 2.3 hlist_add_behind — 在节点后插入

```c
// include/linux/list.h:593
static inline void hlist_add_behind(struct hlist_node *n,
                                    struct hlist_node *prev)
{
    n->next = prev->next;
    prev->next = n;
    n->pprev = &prev->next;

    if (n->next)
        n->next->pprev = &n->next;
}
```

### 2.4 hlist_del — 删除节点

```c
// include/linux/list.h:601
static inline void hlist_del(struct hlist_node *n)
{
    struct hlist_node *next = n->next;
    struct hlist_node **pprev = n->pprev;

    *pprev = next;                      // 前驱节点的 next 指向后继
    if (next)
        next->pprev = pprev;         // 后继的 pprev 修正

    n->next = LIST_POISON1;
    n->pprev = LIST_POISON2;
}
```

**关键：为什么 O(1) 删除可行？**

```
因为 pprev 保存了"前驱节点的 next 指针的地址"
所以删除时：*n->pprev = n->next 即可完成

不需要遍历找到前驱！这是比普通单向链表厉害的地方。
```

### 2.5 hlist_del_init — 删除并初始化

```c
// include/linux/list.h:615
static inline void hlist_del_init(struct hlist_node *n)
{
    if (!hlist_unhashed(n)) {
        __hlist_del(n);
        INIT_HLIST_NODE(n);  // n->next = NULL; n->pprev = NULL;
    }
}
```

### 2.6 hlist_empty — 判空

```c
// include/linux/list.h:562
static inline int hlist_empty(const struct hlist_head *h)
{
    return !READ_ONCE(h->first);
}
```

---

## 3. 遍历宏

### 3.1 hlist_for_each — 遍历节点

```c
// include/linux/list.h:630
#define hlist_for_each(pos, head) \
    for (pos = (head)->first; pos; pos = pos->next)
```

### 3.2 hlist_for_each_entry — 遍历数据节点

```c
// include/linux/list.h:649
#define hlist_for_each_entry(tpos, pos, head, member) \
    for (pos = (head)->first; \
         pos && ({ tpos = hlist_entry(pos, typeof(*tpos), member); 1; }); \
         pos = pos->next)
```

### 3.3 hlist_for_each_entry_rcU — RCU 安全遍历

```c
// include/linux/rculist.h:67
#define hlist_for_each_entry_rcu(tpos, pos, head, member, lock...) \
    for (pos = rcu_dereference_raw((head)->first); \
         pos && ({ tpos = hlist_entry(pos, typeof(*tpos), member); 1; }); \
         pos = rcu_dereference_raw(pos->next))
```

### 3.4 hlist_for_each_entry_safe — 安全遍历

```c
// include/linux/list.h:668
#define hlist_for_each_entry_safe(tpos, pos, n, head, member) \
    for (pos = (head)->first; \
         pos && ({ tpos = hlist_entry(pos, typeof(*tpos), member); 1; }); \
         pos = n)
```

---

## 4. nulls 标记（解决哈希冲突）

### 4.1 什么是 nulls

```c
// include/linux/list_nulls.h — nulls marker
// 当 hash slot 用尽时，hlist_node->next 可能指向一个特殊的 nulls 值
// 而不是真正的 NULL

// nulls 是一个"故意设置为特殊值"的指针：
// 例如：node->next = (struct hlist_node *)((unsigned long)NULL + 1)
// 这样区分"链表结束"和"hash slot 标记"
```

### 4.2 is_a_nulls / get_nulls_value

```c
// include/linux/list_nulls.h:43
static inline int is_a_nulls(const struct hlist_nulls_node *ptr)
{
    return ((unsigned long)ptr) & 1L;  // 最低位为 1 = nulls 标记
}

// include/linux/list_nulls.h:57
static inline unsigned long get_nulls_value(const struct hlist_nulls_node *ptr)
{
    return ((unsigned long)ptr) >> 1;  // 提取 nulls 值
}
```

### 4.3 hlist_nulls_for_each_entry — 遍历含 nulls 的链表

```c
// include/linux/list_nulls.h:71
#define hlist_nulls_for_each_entry(tpos, pos, head, member) \
    for (pos = (head)->first; \
         (!is_a_nulls(pos)) && ({ tpos = hlist_entry(pos, typeof(*tpos), member); 1; }); \
         pos = pos->next)
```

---

## 5. pprev 的精妙设计

### 5.1 为什么需要二级指针 pprev

```
普通单向链表的问题：
  A → B → C → NULL
  删除 B 需要知道 A（遍历）

hlist 的解决方案：
  A → B → C
  ↑
  pprev 指向 B 的位置

hlist_node 的 pprev 指向"前一个节点的 next 指针所在的地址"
  - 如果 B 是第一个节点：pprev = &head.first
  - 如果 B 不是第一个节点：pprev = &A.next

删除时：
  *n->pprev = n->next
  即：前一个节点的 next = n->next
  O(1) 完成！
```

### 5.2 图解 pprev

```
head.first ──→ [n] ──→ [node1] ──→ [node2] ──→ NULL
              ↑
         pprev = &head.first

n->pprev 指向 head.first 本身（一个指针变量）的地址
所以 *n->pprev = n->next 相当于 head.first = n->next

对于 node1：
  node1->next = &node2
  node1->pprev = &n->next  （指向 n 节点的 next 指针）
删除 node1：*node1->pprev = node1->next → n->next = &node2
```

---

## 6. hlist vs list 全面对比

| 特性 | hlist | list_head |
|------|-------|-----------|
| 节点大小 | 8 字节 | 16 字节 |
| 方向 | 单向 | 双向 |
| 头节点 | hlist_head（8字节）| list_head（16字节）|
| 删除复杂度 | O(1)（有 pprev）| O(1) |
| 尾部遍历 | 不支持 | 支持 |
| 反向遍历 | 不支持 | 支持 |
| 适用场景 | Hash table 桶 | 通用链表 |
| RCU 支持 | hlist_for_each_entry_rcu | list_for_each_entry_rcu |

---

## 7. 内核使用案例

### 7.1 dentry 哈希表

```c
// include/linux/dcache.h — dentry
struct dentry {
    struct qstr            d_name;           // 文件名
    struct inode           *d_inode;         // 关联 inode
    struct dentry         *d_parent;        // 父目录

    // 哈希链表
    struct hlist_node      d_hash;          // 接入 dentry_hashtable
    struct hlist_node      d_child;         // 接入父目录的 d_subdirs

    struct list_head       d_lru;           // LRU 链表（用的是 list_head）
    // ...
};

// 系统所有 dentry 通过 d_hash 接入全局哈希表：
static struct hlist_head *dentry_hashtable;
// 哈希表大小：512 ~ 2^13（根据内存大小动态）
```

### 7.2 inode 哈希表

```c
// include/linux/fs.h — inode
struct inode {
    // ...
    struct hlist_node      i_hash;           // 接入 inode_hashtable
    struct list_head       i_list;          // 接入 inode 链表（用 list_head）
    // ...
};

// inode_hashtable 哈希表，用于通过 inode 号快速查找 inode
static struct hlist_head *inode_hashtable;
```

### 7.3 pagecache 的 radix tree 配合

```c
// mm/filemap.c — page cache
// radix tree 查找 page → 如果找不到，通过某些 hlist 链表处理冲突
```

---

## 8. 设计决策总结

| 设计决策 | 原因 |
|---------|------|
| 单向链表 | Hash table 桶只需要头部插入，不需要尾部遍历 |
| pprev 二级指针 | O(1) 删除（无需遍历找前驱）|
| hlist_head 只有 first | 空桶 = NULL，节省 8 字节 |
| nulls 标记 | 区分"链表结束"和"特殊标记" |
| 8 字节 vs 16 字节 | Hash table 有数千个桶，内存节省显著 |

---

## 9. 完整文件索引

| 文件 | 行号 | 内容 |
|------|------|------|
| `include/linux/list.h` | 552 | `struct hlist_node` |
| `include/linux/list.h` | 558 | `struct hlist_head` |
| `include/linux/list.h` | 562 | `hlist_empty` |
| `include/linux/list.h` | 567 | `hlist_add_head` |
| `include/linux/list.h` | 585 | `hlist_add_before` |
| `include/linux/list.h` | 593 | `hlist_add_behind` |
| `include/linux/list.h` | 601 | `hlist_del` |
| `include/linux/list.h` | 615 | `hlist_del_init` |
| `include/linux/list.h` | 630 | `hlist_for_each` |
| `include/linux/list.h` | 649 | `hlist_for_each_entry` |
| `include/linux/list.h` | 668 | `hlist_for_each_entry_safe` |
| `include/linux/list_nulls.h` | 43 | `is_a_nulls` |
| `include/linux/list_nulls.h` | 57 | `get_nulls_value` |

---

## 10. 西游记类比

**hlist** 就像"天兵天将的编号簿"——

> 玉帝每次抓妖怪，只需要从编号簿的第一个开始点名（hlist_add_head）。每个妖怪的"下一个"指向同伴，但他的"前驱位置"（pprev）记录的是"前面那个人的名字栏的地址"。这样哪吒三太子删除其中一个妖怪时，不需要知道前面是谁——只要把自己的"前驱位置"那栏改成后面人的名字就行了。这就是 O(1) 删除的精妙！list_head 是双向跑道（谁都能往前往后），hlist 是单向追击（只追前面的人，但知道前面那个人的逃跑方向）。

---

## 11. 关联文章

- **list_head**（article 01）：hlist 的"前身"，通用双向链表
- **radix_tree / xarray**（article 04）：hash table 通常配合 radix tree 用于 page cache 索引
- **dentry**（VFS 部分）：dentry_hashtable 使用 hlist 存储同名文件冲突