# 02-hlist — Linux 内核散列链表深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**hlist（hash list）** 是 Linux 内核中为散列表（hash table）量身定做的链表变体。它与 `list_head`（article 01）最核心的区别在于：**头节点只包含一个 `first` 指针，而不是双向链表需要的两个指针**。

为什么要这样设计？考虑一个典型的内核散列表：系统可能创建了上万个 bucket，但大多数 bucket 在任意时刻都是空的。如果每个空 bucket 都维持着一个 16 字节的双向链表头节点，那将浪费大量的内存。hlist 将头节点缩减到 8 字节，将省下的内存用在了更有意义的地方。

hlist 的设计权衡牺牲了两种能力——反向遍历和 O(1) 尾部插入——换来了更小的头节点和在散列表场景中依然保持 O(1) 的删除能力。这种"有意识放弃"的设计哲学贯穿了整个 Linux 内核。

doom-lsp 确认 `struct hlist_head` 定义于 `include/linux/types.h:208`，`struct hlist_node` 定义于同文件的 `212` 行。所有 hlist 操作实现在 `include/linux/list.h:960~1206`。

---

## 1. 核心数据结构

### 1.1 struct hlist_head（`include/linux/types.h:208`）

```c
struct hlist_head {
    struct hlist_node *first;   // 指向链表第一个节点，NULL = 空链表
};
```

仅 **8 字节**（64 位系统上）。对比 list_head 的 16 字节，每个 bucket 节省 8 字节。对于一个拥有 10 万个 bucket 的散列表，这节省了 800 KB 内核内存。

空链表的表示：`first == NULL`。这与 list_head 的"指向自己"方案不同。

### 1.2 struct hlist_node（`include/linux/types.h:212`）

```c
struct hlist_node {
    struct hlist_node *next;    // 指向下一个节点
    struct hlist_node **pprev;  // 指向前一个节点的 next 指针的地址
};
```

`pprev` 是 hlist 中最巧妙的设计。它不是指向前一个节点本身（那是一个 `struct hlist_node*`），而是**指向前一个节点的 `next` 字段的地址**（或头节点的 `first` 字段的地址）。

对于链表中的第一个节点，`pprev` 指向 `hlist_head.first`。对于链表中的非首节点，`pprev` 指向前一个节点的 `next`。

为什么不用前驱指针（`prev`）？如果 hlist_node 使用 `struct hlist_node *prev`（就像 list_head 那样），那么从中间删除一个节点就需要找到前驱节点——而这是一个**单向链表**，没有从后往前遍历的能力。传统的做法是遍历找到前驱，那是 O(n)。

`pprev` 解决了这个问题：因为 `pprev` 直接指向"前驱节点指向我的指针"（要么是前驱节点的 `next`，要么是头节点的 `first`），所以删除时不需要遍历：

```c
// 删除当前节点：
*(n->pprev) = n->next;   // 让前驱跳过自己
```

这比 list_head 的删除更少了一次指针赋值——list_head 需要操作 `prev->next` 和 `next->prev` 两个指针，而 hlist 只需要操作 `*pprev` 和 `next->pprev`（如果有后驱）。

---

## 2. 初始化与判空

### 2.1 初始化（`list.h:943-945`）

```c
#define HLIST_HEAD_INIT { .first = NULL }
#define HLIST_HEAD(name) struct hlist_head name = { .first = NULL }
#define INIT_HLIST_HEAD(ptr) ((ptr)->first = NULL)

// 节点初始化
static inline void INIT_HLIST_NODE(struct hlist_node *h)  // list.h:946
{
    h->next = NULL;
    h->pprev = NULL;
}
```

`HLIST_HEAD_INIT` 使用 C99 的指定初始化器语法，将 `first` 明确设为 NULL。空链表的标志就是 `first == NULL`。

### 2.2 判空与判无节点

```c
// list.h:982
static inline int hlist_empty(const struct hlist_head *h)
{
    return !READ_ONCE(h->first);
}

// list.h:960
static inline int hlist_unhashed(const struct hlist_node *h)
{
    return !h->pprev;
}
```

`hlist_empty` 检查链表头是否为空。`hlist_unhashed` 检查一个节点是否不在任何链表中。当节点被删除后，`pprev` 被置为 NULL（`hlist_del_init` 的行为），所以 `hlist_unhashed` 可以判断节点是否已从链表分离。

---

## 3. 插入操作

### 3.1 hlist_add_head（`list.h:1033`）

```c
static inline void hlist_add_head(struct hlist_node *n, struct hlist_head *h)
{
    struct hlist_node *first = h->first;
    WRITE_ONCE(n->next, first);
    if (first)
        WRITE_ONCE(first->pprev, &n->next);
    WRITE_ONCE(h->first, n);
    WRITE_ONCE(n->pprev, &h->first);
}
```

数据流：

```
插入前：
  head.first → node_A → node_B → NULL

hlist_add_head(&new_node, &head)

  步骤 1: new_node.next = head.first (= node_A)
  步骤 2: node_A.pprev = &new_node.next   （如果有旧首节点）
  步骤 3: head.first = new_node
  步骤 4: new_node.pprev = &head.first

插入后：
  head.first → new_node → node_A → node_B → NULL
```

因为散列表通常只需要头插法（LIFO/栈行为），所以 `hlist_add_head` 是最主要的插入操作。`hlist_add_before`（`list.h:1048`）和 `hlist_add_behind`（`list.h:1062`）提供了更灵活的插入位置。

### 3.2 hlist_add_before（`list.h:1048`）

```c
static inline void hlist_add_before(struct hlist_node *n,
                                     struct hlist_node *next)
{
    WRITE_ONCE(n->pprev, next->pprev);
    WRITE_ONCE(n->next, next);
    WRITE_ONCE(*n->pprev, n);      // 让前驱指向 n
    WRITE_ONCE(next->pprev, &n->next);
}
```

在已知节点 `next` 之前插入 `n`。这个操作在散列表的关联链表中使用，比如在特定位置的链表中插入新节点时需要保持顺序。

### 3.3 hlist_add_behind（`list.h:1062`）

```c
static inline void hlist_add_behind(struct hlist_node *n,
                                     struct hlist_node *prev)
{
    WRITE_ONCE(n->next, prev->next);
    WRITE_ONCE(prev->next, n);
    WRITE_ONCE(n->pprev, &prev->next);
    if (n->next)
        WRITE_ONCE(n->next->pprev, &n->next);
}
```

在已知节点 `prev` 之后插入 `n`。

---

## 4. 删除操作

### 4.1 __hlist_del（`list.h:987`）

```c
static inline void __hlist_del(struct hlist_node *n)
{
    struct hlist_node *next = n->next;
    struct hlist_node **pprev = n->pprev;

    WRITE_ONCE(*pprev, next);       // 前驱节点的 next 跳过 n
    if (next)
        WRITE_ONCE(next->pprev, pprev);  // 后驱节点的 pprev 指向原前驱
}
```

数据流：

```
删除前：
  head.first → node_A → node_B → node_C → NULL

__hlist_del(&node_B):
  *node_B.pprev = *(node_A.next 的地址)
                 = node_A.next = node_B.next = node_C
  
  node_C.pprev = node_B.pprev = &node_A.next

删除后：
  head.first → node_A → node_C → NULL
```

注意 `pprev` 在删除中的关键作用：`*(n->pprev)` 直接定位到前驱节点（或头节点）指向 `n` 的那个指针，然后将它设为 `n->next`。这样 `n` 就被跳过了，而整个过程**不需要知道前驱节点是谁**——`pprev` 已经保存了"谁指向我"的信息。

### 4.2 hlist_del（`list.h:1004`）

```c
static inline void hlist_del(struct hlist_node *n)
{
    __hlist_del(n);
    n->next = LIST_POISON1;
    n->pprev = LIST_POISON2;
}
```

标准删除，毒化指针。

### 4.3 hlist_del_init（`list.h:1017`）

```c
static inline void hlist_del_init(struct hlist_node *n)
{
    if (!hlist_unhashed(n)) {       // 检查是否已在链表中
        __hlist_del(n);
        INIT_HLIST_NODE(n);         // 重新初始化节点
    }
}
```

与 `list_del_init` 类似——删除后初始化节点。但增加了 `hlist_unhashed` 检查：如果节点已不在链表中，就不执行删除。这是安全的双删保护。

---

## 5. 遍历宏

### 5.1 基本遍历

```c
// list.h:1166
#define hlist_for_each_entry(pos, head, member)                         \
    for (pos = hlist_entry_safe((head)->first, typeof(*pos), member);    \
         pos;                                                            \
         pos = hlist_entry_safe(pos->member.next, typeof(*(pos)), member))
```

与 `list_for_each_entry` 的核心区别：**终止条件是 `pos != NULL`，而非 `pos != head`**。因为 hlist 的终止是 NULL 指针（最后一个节点的 `next == NULL`），而不是像 list_head 那样绕回头节点。

```c
// list.h:1197
#define hlist_for_each_entry_safe(pos, n, head, member)                 \
    for (pos = hlist_entry_safe((head)->first, typeof(*pos), member),    \
         n = pos ? hlist_entry_safe(pos->member.next, typeof(*pos), member) : NULL; \
         pos;                                                            \
         pos = n,                                                        \
         n = pos ? hlist_entry_safe(pos->member.next, typeof(*pos), member) : NULL)
```

安全版本，预存下一个节点。

### 5.2 遍历宏一览

| 宏 | 位置 | 用途 |
|-----|------|------|
| `hlist_for_each` | 头指针遍历 | 底层遍历 |
| `hlist_for_each_entry` | 1166 | **最常用**，遍历数据节点 |
| `hlist_for_each_entry_continue` | 1176 | 从当前位置继续 |
| `hlist_for_each_entry_from` | 1186 | 从指定节点开始 |
| `hlist_for_each_entry_safe` | 1197 | 可删除遍历 |

---

## 6. hlist 与 list_head 对比

| 特性 | list_head | hlist |
|------|-----------|-------|
| 头节点大小 | 16 字节（next + prev） | 8 字节（first） |
| 节点大小 | 16 字节（next + prev） | 16 字节（next + pprev） |
| 空链表表示 | `head->next == head` | `head->first == NULL` |
| 尾部插入 | O(1) | O(n) |
| 反向遍历 | ✅ | ❌ |
| 删除节点 | O(1)，需前驱信息 | O(1)，通过 pprev |
| 适用场景 | 通用链表 | 散列表 bucket |
| 是否有哨兵 | ✅（循环哨兵） | ❌（NULL 终止）|
| 遍历终止条件 | `pos != head` | `pos != NULL` |

---

## 7. 内核中的应用场景

hlist 被广泛用于内核中的各种散列表。doom-lsp 可以追踪到以下典型使用：

### 7.1 inode 哈希表

```c
// fs/inode.c
// 通过 super_block 和 inode 编号查找 inode 时使用 hlist
struct hlist_head *head = inode_hashtable + hash(sb, ino);
hlist_for_each_entry(inode, head, i_hash) {
    if (inode->i_ino == ino && inode->i_sb == sb)
        return inode;
}
```

### 7.2 dentry 哈希表

```c
// fs/dcache.c
// 路径名查找时使用 hlist 链接所有哈希到同一 bucket 的 dentry
struct hlist_bl_head *b = d_hash(nd->path.dentry->d_sb, name);
hlist_bl_for_each_entry(dentry, b, d_hash) {
    if (dentry->d_name.hash == namehash && ...)
        return dentry;
}
```

### 7.3 模块哈希表

```c
// kernel/module/main.c
// 通过模块名查找模块
struct hlist_head *head = &module_hashtable[hash(name)];
hlist_for_each_entry(mod, head, m_list) {
    if (strcmp(mod->name, name) == 0)
        return mod;
}
```

---

## 8. pprev 二级指针的设计原理

`pprev` 是整个 hlist 设计中最精妙的部分。它是一个二级指针（`struct hlist_node **`），指向的是"指向当前节点的指针"的地址。

```
链表示例：
  head.first
      │
      ├─→ 0x1000 (struct hlist_node node_A)
      │       ├─ next: 0x2000
      │       └─ pprev: &head.first  ← 指向 head.first 的地址
      │
      ├─→ 0x2000 (struct hlist_node node_B)
      │       ├─ next: 0x3000
      │       └─ pprev: &node_A.next  ← 指向前驱节点的 next 字段
      │
      └─→ 0x3000 (struct hlist_node node_C)
              ├─ next: NULL
              └─ pprev: &node_B.next
```

删除 `node_B` 时：
```c
// __hlist_del(&node_B):
// n->pprev = &node_A.next
// *(n->pprev) = node_A.next = node_B.next = &node_C

// 等效于：node_A.next = node_C
// 同时维护 node_C.pprev = &node_A.next
```

这就是为什么不需要遍历就能 O(1) 删除——`pprev` 已经记录了"我应该修改谁"的信息。

---

## 9. 设计决策总结

| 决策 | 好处 | 代价 |
|------|------|------|
| `first` 单指针头 | 头节点减半到 8 字节 | 失去 O(1) 尾部插入 |
| `pprev` 二级指针 | O(1) 删除，无需遍历 | 多 8 字节/节点 |
| NULL 终止 | 空 bucket 零开销 | 失去哨兵节点 |
| LIFO 头插为主 | 适合散列表场景 | 不支持顺序保证 |

---

## 10. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/types.h` | `struct hlist_head` | 208 |
| `include/linux/types.h` | `struct hlist_node` | 212 |
| `include/linux/list.h` | `INIT_HLIST_NODE` | 946 |
| `include/linux/list.h` | `hlist_unhashed` | 960 |
| `include/linux/list.h` | `hlist_empty` | 982 |
| `include/linux/list.h` | `__hlist_del` | 987 |
| `include/linux/list.h` | `hlist_del` | 1004 |
| `include/linux/list.h` | `hlist_del_init` | 1017 |
| `include/linux/list.h` | `hlist_add_head` | 1033 |
| `include/linux/list.h` | `hlist_add_before` | 1048 |
| `include/linux/list.h` | `hlist_add_behind` | 1062 |
| `include/linux/list.h` | `hlist_for_each_entry` | 1166 |

---

## 11. 关联文章

- **list_head**（article 01）：双向循环链表——hlist 的对照物
- **rhashtable**（article 02 关联）：使用 hlist 的可扩容散列表框架
- **dcache**（article 161）：dentry cache 使用 hlist_bl（hlist + 位的锁）

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
