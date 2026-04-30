# hlist — 内核单向链表变体深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/list_nulls.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照
> 行号索引：list_nulls.h 全文

---

## 0. 概述

`hlist`（准确说是 `hlist_nulls`）是 Linux 内核针对 **哈希表桶头** 优化的单向链表变体。核心改进：

- **单指针桶头**：相比 `list_head` 的双指针，桶头从 16 → 8 字节（64-bit）
- **nulls marker**：用特殊标记替代 NULL，解决哈希冲突链表的遍历终止问题
- **`pprev` 双向指向**：节点既有 `next` 指针，又保存 `next` 的地址（`pprev`），实现 O(1) 删除

---

## 1. 核心数据结构

### 1.1 hlist_nulls_head — 桶头

```c
// include/linux/list_nulls.h
struct hlist_nulls_head {
    struct hlist_nulls_node *first;  // 指向第一个节点或 nulls marker
};
```

**设计要点**：
- 只有一个指针，**8 字节**（64-bit）
- `first` 指向两种情况：
  1. 正常节点：`first` 最低位 = 0
  2. nulls marker：`first` 最低位 = 1

### 1.2 hlist_nulls_node — 链表节点

```c
// include/linux/list_nulls.h
struct hlist_nulls_node {
    struct hlist_nulls_node *next;      // 指向下一个节点
    struct hlist_nulls_node **pprev;    // 指向"前一个节点的 next 指针"的地址
};
```

**为什么需要 `pprev`？**

对于普通单向链表 `A → B → C`，删除 B 需要知道 B 的前驱 A（才能修改 `A->next = C`）。但单向链表没有保存前驱信息。

**`pprev` 的设计**：
```
正常情况：A.next → B，B.pprev → &A.next
删除 B 后：只需 *B.pprev = B.next，即 A.next = C
```

**图示**：
```
hlist_nulls_head
    │
    └── first ────────────────────────────────►
                                                  │
    ┌───────────────────────────────────────────┘
    │
    ▼
┌───────┐    pprev          ┌───────┐    pprev          ┌───────┐
│ node0 │ ───────────────►  │ node1 │ ───────────────►  │ node2 │
│next──►│◄──────────────────│next──►│◄─────────────────│next──►│► nulls
└───────┘                   └───────┘                   └───────┘
  &node0.next              &node1.next              &node2.next
```

---

## 2. nulls marker — 替代 NULL

### 2.1 为什么不用 NULL？

对于哈希桶，每个桶链表的结尾值不同（因为用于统计/调试）。如果都用 NULL，遍历时无法区分"链表结束"和"某个具体值"。

### 2.2 NULLS_MARKER 宏

```c
// include/linux/list_nulls.h
#define NULLS_MARKER(value) (1UL | (((long)value) << 1))

// nulls = 0 时：
// NULLS_MARKER(0) = 0b...001 = 1（最低位为 1，表示 nulls 标记）

// nulls = 5 时：
// NULLS_MARKER(5) = 0b...01101（最低位为 1，高位存 5）
```

### 2.3 辅助函数

```c
// 检测是否是 nulls marker
static inline int is_a_nulls(const struct hlist_nulls_node *ptr)
{
    return ((unsigned long)ptr & 1);  // 最低位 = 1
}

// 获取 nulls 的值
static inline unsigned long get_nulls_value(const struct hlist_nulls_node *ptr)
{
    return ((unsigned long)ptr) >> 1;  // 右移 1 位
}
```

---

## 3. 初始化

### 3.1 INIT_HLIST_NULLS_HEAD

```c
// include/linux/list_nulls.h
#define INIT_HLIST_NULLS_HEAD(ptr, nulls) \
    ((ptr)->first = (struct hlist_nulls_node *) NULLS_MARKER(nulls))

// 使用示例：
INIT_HLIST_NULLS_HEAD(&hash_table[0], 0);  // 桶 0，nulls = 0
INIT_HLIST_NULLS_HEAD(&hash_table[1], 1);  // 桶 1，nulls = 1
```

---

## 4. 插入操作

### 4.1 hlist_nulls_add_head — 头部插入

```c
// include/linux/list_nulls.h
static inline void hlist_nulls_add_head(struct hlist_nulls_node *n,
                    struct hlist_nulls_head *h)
{
    struct hlist_nulls_node *first = h->first;

    n->next = first;                    // [1] n.next 指向原第一个节点
    WRITE_ONCE(n->pprev, &h->first);   // [2] n.pprev 指向桶头的 first 指针本身
    h->first = n;                      // [3] 桶头指向新节点

    if (!is_a_nulls(first))            // [4] 如果不是 nulls marker
        WRITE_ONCE(first->pprev, &n->next);  // [5] 更新旧节点的 pprev
}
```

**图示**：
```
插入前：
h.first → node1 → node2 → nulls(marker=2)

插入 n（n = new_node）后：
h.first → n → node1 → node2 → nulls(marker=2)
        ↑
        └── n->pprev = &h.first
        └── n->next->pprev = &n.next（即 n->pprev 更新 node1.pprev）
```

---

## 5. 删除操作

### 5.1 __hlist_nulls_del — 内部删除

```c
// include/linux/list_nulls.h
static inline void __hlist_nulls_del(struct hlist_nulls_node *n)
{
    struct hlist_nulls_node *next = n->next;           // [1] 保存后继
    struct hlist_nulls_node **pprev = n->pprev;       // [2] pprev 是"前驱 next"的地址

    WRITE_ONCE(*pprev, next);                          // [3] 前驱.next = 后继

    if (!is_a_nulls(next))                             // [4] 如果后继不是 nulls
        WRITE_ONCE(next->pprev, pprev);               // [5] 后继.pprev = 前驱.next 的地址
}
```

**关键**：删除节点只需要知道 `n->pprev`（即前驱 next 的地址），不需要遍历整个链表。

### 5.2 hlist_nulls_del — 删除并置毒

```c
// include/linux/list_nulls.h
static inline void hlist_nulls_del(struct hlist_nulls_node *n)
{
    __hlist_nulls_del(n);                    // [1] 执行删除
    WRITE_ONCE(n->pprev, LIST_POISON2);     // [2] 置毒，防止 use-after-free
}
```

---

## 6. 遍历操作

### 6.1 hlist_nulls_for_each_entry — 遍历外层结构

```c
// include/linux/list_nulls.h
#define hlist_nulls_for_each_entry(tpos, pos, head, member)          \
    for (pos = (head)->first;                                     \
         (!is_a_nulls(pos)) &&                                     \
            ({ tpos = hlist_nulls_entry(pos, typeof(*tpos), member); 1;}); \
         pos = pos->next)
```

**展开示例**：
```c
struct hash_entry {
    int key;
    int value;
    struct hlist_nulls_node node;  // 嵌入
};

struct hlist_nulls_head hash_table[256];

struct hash_entry *entry;
struct hlist_nulls_node *pos;

hlist_nulls_for_each_entry(entry, pos, &hash_table[5], node) {
    // entry 指向包含此 node 的 hash_entry
    printk("key=%d value=%d\n", entry->key, entry->value);
}
```

### 6.2 hlist_nulls_entry_safe — 安全获取条目

```c
// include/linux/list_nulls.h
#define hlist_nulls_entry_safe(ptr, type, member) \
    ({ typeof(ptr) ____ptr = (ptr); \
       !is_a_nulls(____ptr) ? hlist_nulls_entry(____ptr, type, member) : NULL; \
    })
```

---

## 7. 与 list_head 的对比

| 特性 | list_head | hlist_nulls |
|------|-----------|-------------|
| 桶头大小（64-bit）| 16 字节 | 8 字节 |
| 链表方向 | 双向循环 | 单向（pprev 是双指针）|
| 删除复杂度 | O(1)（知道 prev）| O(1)（知道 pprev）|
| NULL 尾 | 双向都有 NULL | 用 nulls marker |
| 适用场景 | 通用链表 | 哈希表桶、 inode 缓存 |

---

## 8. 内核中的实际使用

### 8.1 进程表（pid_hash）

```c
// kernel/pid.c
struct pid_hash {
    struct hlist_nulls_head head;
    unsigned int count;
};

struct pid_hash *pid_hash_table[PIDTYPE_MAX];

// 遍历某 PID 类型的哈希桶：
hlist_nulls_for_each_entry(pid, node, &pid_hash_table[type][bucket], pid_chain)
```

### 8.2 inode 缓存（inode_hashtable）

```c
// fs/inode.c
static struct hlist_nulls_head inode_hashtable[IHASH_BITS];

// 查找 inode：
hlist_nulls_for_each_entry(inode, node, &inode_hashtable[hash], i_hash)
```

### 8.3 dcache（dentry_hashtable）

```c
// fs/dcache.c
struct hlist_nulls_head *dentry_hashtable;

hlist_nulls_for_each_entry(dentry, d_hash, &dentry_hashtable[hash], d_hash)
```

---

## 9. 完整文件索引

| 文件路径 | 关键行 | 内容 |
|---------|-------|------|
| `include/linux/list_nulls.h` | 全文 | `hlist_nulls_head`、`hlist_nulls_node`、`NULLS_MARKER` |
| `include/linux/list_nulls.h` | hlist_nulls_add_head | 头部插入（O(1)）|
| `include/linux/list_nulls.h` | __hlist_nulls_del | 删除（利用 pprev）|
| `include/linux/list_nulls.h` | hlist_nulls_for_each_entry | 遍历宏 |
| `include/linux/list_nulls.h` | is_a_nulls / get_nulls_value | nulls marker 工具 |
