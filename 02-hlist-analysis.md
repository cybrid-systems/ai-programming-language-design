# Linux Kernel hlist（哈希链表）— 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/list.h` + `include/linux/list_nulls.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 更新：整合 2026-04-15 学习笔记强化内容

---

## 0. 为什么要 hlist？——list_head 的哈希表困境

`list_head` 是双向循环链表，**每个链表头需要 2 个指针（16 字节）**。

在内核哈希表场景中，bucket 数量可能非常大：

| 哈希表 | bucket 数量 | list_head 开销 | hlist 开销 |
|--------|------------|--------------|-----------|
| dentry cache | 4096 | 64 KB | 32 KB |
| inode cache | 8192 | 128 KB | 64 KB |
| module idem | 16384 | 256 KB | 128 KB |
| pid hash | 65536 | 1 MB | 512 KB |

**hlist 的核心改进**：把桶头从 2 个指针压缩为 1 个指针，**每桶省 8 字节**，代价是失去双向遍历和 O(1) 尾访问能力——但哈希表根本不需要这两件事。

**全内核使用量统计**（Linux 7.0 源码）：
- `hlist_add_head`：**466 处**
- `hlist_for_each_entry`：**1111 处**
- `hlist_del`：**210 处**

---

## 1. 核心数据结构

```c
// include/linux/types.h:208-213

// 桶头 — 只需要一个指针（指向第一个节点，空时为 NULL）
struct hlist_head {
    struct hlist_node *first;
};

// 节点 — 单向 next 指针 + pprev（指向"引用本节点之指针"的地址）
struct hlist_node {
    struct hlist_node *next;      // 指向下一个节点（NULL 表示链表尾部）
    struct hlist_node **pprev;    // 指向**前驱节点的 next 指针变量**（或桶头的 first）
};
```

---

## 2. 与 list_head 全面对比

| 特性 | `list_head` | `hlist` |
|------|------------|----------|
| 链表类型 | 双向循环 | 单向（非循环） |
| 桶头指针 | 2 个（16 字节） | **1 个（8 字节）** |
| 节点大小 | 2 指针（16 字节） | 2 指针（16 字节） |
| 尾节点访问 | O(1)（prev 指针） | **O(n)**（无法直接访问） |
| 删除操作 | 需要 prev 指针 | **O(1)，pprev 技巧** |
| 空链表判断 | `head->next == head` | `first == NULL` |
| 遍历终止 | `pos == head` | `pos == NULL` |
| 适用场景 | 通用链表、进程树 | **哈希桶**、模块表 |

---

## 3. 内存布局图

```
list_head 哈希表（每个桶 2 指针 = 16B）：
bucket[0] ──→ prev │ next ──→ prev │ next ──→ NULL
          16B    │          16B
                 │
bucket[1] ──→ prev │ next ──→ NULL
          16B    │

hlist 哈希表（每个桶 1 指针 = 8B）：
bucket[0] ──→ next**pprev ──→ next**pprev ──→ NULL
          8B     │          16B
                 │
bucket[1] ──→ next**pprev ──→ NULL
          8B     │

pprev 指针链详解：
  bucket[0].first = &node1          node1.pprev = &bucket[0].first
  node1.next = &node2               node2.pprev = &node1.next
  node2.next = NULL

删除 node1：*node1.pprev = node1.next
          → *(&bucket[0].first) = &node2
          → bucket[0].first = &node2 ✅ O(1)，无需遍历
```

---

## 4. `pprev` 技巧详解（核心精髓）

### 4.1 为什么 `pprev` 不是"指向前一个节点的指针"？

如果 `pprev` 存的是前一个节点的地址，删除时：
```
node1.pprev = &node0  // 存 node0 的地址

// 删除 node1 时仍然需要知道 node0 → 必须遍历找前驱 → O(n)
```

### 4.2 `pprev` 的正确理解

`pprev` 存的是"**前驱节点的 `next` 指针变量本身的地址**"。

删除时只需要：
```c
*pprev = next;  // 把前驱的 next 指向改为本节点的 next
```

这相当于把链表中的 `... → node0.next → node1 → node2 → ...`
变成                `... → node0.next → node2 → ...`

**一条赋值语句完成 O(1) 删除**，不需要知道头节点在哪！

### 4.3 三种 `pprev` 指向情况

```
情况1：node 是桶的第一个节点
  pprev = &bucket.first
  
情况2：node 在桶内（不是第一个）
  pprev = &前一个节点.next
  
情况3：node 是最后一个节点（next == NULL）
  pprev = &前一个节点.next
  删除后：前一个节点.next = NULL
```

---

## 5. 初始化

```c
// include/linux/list.h:942-951

// 桶头初始化（静态）
#define HLIST_HEAD_INIT { .first = NULL }
#define HLIST_HEAD(name) struct hlist_head name = { .first = NULL }

// 桶头初始化（运行时）
#define INIT_HLIST_HEAD(ptr) ((ptr)->first = NULL)

// 节点初始化（next=NULL, pprev=NULL 表示未加入任何链表）
static inline void INIT_HLIST_NODE(struct hlist_node *h)
{
    WRITE_ONCE(h->next, NULL);
    WRITE_ONCE(h->pprev, NULL);
}
```

**为什么用 `WRITE_ONCE`**：与 `list_head` 相同，编译器屏障防止并发场景下的指令重排。

---

## 6. 核心操作

### 6.1 判断状态

```c
// 是否已脱链（pprev == NULL）
static inline int hlist_unhashed(const struct hlist_node *h)
{
    return !h->pprev;
}

// 桶是否为空（first == NULL）
static inline int hlist_empty(const struct hlist_head *h)
{
    return !READ_ONCE(h->first);
}

// 是否是桶中唯一节点
static inline bool hlist_is_singular_node(struct hlist_node *n, struct hlist_head *h)
{
    return !n->next && n->pprev == &h->first;
}
```

### 6.2 删除操作

```c
// include/linux/list.h:987 — 内部实现（不改变节点状态）
static inline void __hlist_del(struct hlist_node *n)
{
    struct hlist_node *next = n->next;
    struct hlist_node **pprev = n->pprev;

    WRITE_ONCE(*pprev, next);         // 前驱的 next 指向本节点的 next
    if (next)
        WRITE_ONCE(next->pprev, pprev); // 下一个节点的 pprev 修正
}

// include/linux/list.h:1004 — 公开接口（置毒）
static inline void hlist_del(struct hlist_node *n)
{
    __hlist_del(n);
    n->next = LIST_POISON1;   // 0x100 + delta
    n->pprev = LIST_POISON2;  // 0x122 + delta
}

// include/linux/list.h:1017 — 删除并重新初始化
static inline void hlist_del_init(struct hlist_node *n)
{
    if (!hlist_unhashed(n)) {
        __hlist_del(n);
        INIT_HLIST_NODE(n);  // 恢复 next=NULL, pprev=NULL
    }
}
```

### 6.3 插入操作

```c
// include/linux/list.h:1033 — 头部插入（栈行为）
static inline void hlist_add_head(struct hlist_node *n, struct hlist_head *h)
{
    struct hlist_node *first = h->first;
    WRITE_ONCE(n->next, first);
    if (first)
        WRITE_ONCE(first->pprev, &n->next);  // 旧首节点的 pprev 指向 n.next
    WRITE_ONCE(h->first, n);
    WRITE_ONCE(n->pprev, &h->first);          // n 的 pprev 指向桶的 first
}

// include/linux/list.h:1048 — 在某个节点前插入
static inline void hlist_add_before(struct hlist_node *n, struct hlist_node *next)
{
    WRITE_ONCE(n->pprev, next->pprev);         // n.pprev = 前驱的 next 地址
    WRITE_ONCE(n->next, next);
    WRITE_ONCE(next->pprev, &n->next);        // next.pprev = n.next 地址
    WRITE_ONCE(*(n->pprev), n);               // *前驱的next = n
}

// include/linux/list.h:1062 — 在某个节点后插入
static inline void hlist_add_behind(struct hlist_node *n, struct hlist_node *prev)
{
    WRITE_ONCE(n->next, prev->next);
    WRITE_ONCE(prev->next, n);
    WRITE_ONCE(n->pprev, &prev->next);
    if (n->next)
        WRITE_ONCE(n->next->pprev, &n->next);
}
```

---

## 7. 遍历宏

### 7.1 基础遍历

```c
// pos 是 hlist_node *（普通指针）
#define hlist_for_each(pos, head) \
    for (pos = (head)->first; pos; pos = pos->next)

// 安全遍历（可删除当前节点）
#define hlist_for_each_safe(pos, n, head) \
    for (pos = (head)->first; pos && ({ n = pos->next; 1; }); pos = n)
```

### 7.2 容器遍历（最常用）

```c
// hlist_entry_safe：ptr 为 NULL 时返回 NULL（防空指针）
#define hlist_entry_safe(ptr, type, member) \
    ({ typeof(ptr) ____ptr = (ptr); \
       ____ptr ? hlist_entry(____ptr, type, member) : NULL; \
    })

// 遍历容器结构体（pos 是外层结构体指针）
#define hlist_for_each_entry(pos, head, member) \
    for (pos = hlist_entry_safe((head)->first, typeof(*(pos)), member);\
         pos; \
         pos = hlist_entry_safe((pos)->member.next, typeof(*(pos)), member))

// 安全版本（可删除）
#define hlist_for_each_entry_safe(pos, n, head, member) \
    for (pos = hlist_entry_safe((head)->first, typeof(*pos), member);\
         pos && ({ n = pos->member.next; 1; }); \
         pos = hlist_entry_safe(n, typeof(*pos), member))
```

**与 `list_for_each_entry` 的关键区别**：不需要 `list_entry_is_head` 检查，因为 hlist **非循环**，空桶时 `first == NULL`，遍历自然终止。

---

## 8. `hlist_nulls` — 防 ABA 问题的增强版

```c
// include/linux/list_nulls.h
// hlist 的问题是 NULL 被用作链表尾部标记，无法区分"正常尾节点"和"曾删除过的节点"

/*
 * hlist_nulls 的核心思想：
 * 标准 hlist：尾节点 next = NULL
 * hlist_nulls：尾节点 next = NULLS_MARKER(value)，其中 value 可以是任意数
 * 这样每个哈希桶可以有不同的"nulls 值"，解决 ABA 问题
 */

#define NULLS_MARKER(value) (1UL | (((long)value) << 1))
// 最低位 = 1 表示这是 nulls 标记，剩余位存储 value

struct hlist_nulls_head {
    struct hlist_nulls_node *first;
};

struct hlist_nulls_node {
    struct hlist_nulls_node *next, **pprev;
};

// 判断是否是 nulls 标记（最低位为 1）
static inline int is_a_nulls(const struct hlist_nulls_node *ptr)
{
    return ((unsigned long)ptr & 1);
}

// 获取 nulls 的值
static inline unsigned long get_nulls_value(const struct hlist_nulls_node *ptr)
{
    return ((unsigned long)ptr) >> 1;
}
```

**ABA 问题举例**：
```
线程A：读取 node1.next = NULL，準備删除
线程B：删除 node1，重新分配相同地址 node1'，加入链表
线程A：执行 *node1.pprev = node1.next（但此时 node1 已变为 node1'！）
       导致链表断裂

hlist_nulls 解决：不同哈希链表的尾节点有不同的 marker 值，
即使地址相同，marker 不同则 is_a_nulls() 能区分
```

---

## 9. 真实内核使用案例

### 9.1 inode 哈希表（`fs/inode.c`）

```c
// include/linux/fs.h:826
struct inode {
    ...
    struct hlist_node i_hash;  // 加入 inode_hashtable 的节点
    ...
};

// 查找 inode（O(1) hash + O(n) 桶内查找）
static struct inode *find_inode(struct super_block *sb, ...)
{
    struct hlist_head *head = inode_hashtable + hash;
    hlist_for_each_entry(ino, head, i_hash) {
        if (ino->i_ino == ino && ...)
            return ino;
    }
}
```

### 9.2 dentry 哈希表（`fs/dcache.c`）

```c
// include/linux/dcache.h:97
struct dentry {
    struct hlist_bl_node d_hash;    // 哈希桶链表节点（bl = bucket list）
    struct hlist_node d_sib;        // sibling 链表（child of parent）
    struct hlist_head d_children;    // 子目录链表头
    struct hlist_node d_alias;      // inode 别名（一个 inode 可有多个 dentry）
};

// dentry 哈希表
static struct hlist_bl_head *dentry_hashtable;
static inline struct hlist_bl_head *d_hash(unsigned long hashlen)
{
    return dentry_hashtable + (hashlen >> d_hash_shift);
}
```

### 9.3 module 哈希表（`kernel/module/main.c`）

```c
// kernel/module/main.c
static struct hlist_head idem_hash[1 << IDEM_HASH_BITS];

// 插入
hlist_add_head(&u->entry, idem_hash + hash);

// 查找
hlist_for_each_entry(existing, head, entry) {
    if (existing->key == key)
        return existing;
}

// 安全删除
hlist_for_each_entry_safe(pos, next, head, entry) {
    if (pos->key == key)
        hlist_del_init(&pos->entry);
}
```

### 9.4 网络命名空间设备链表（`net/core/dev.c`）

```c
// net/core/dev.c
list_add_tail_rcu(&dev->dev_list, &net->dev_base_head);  // 设备加入命名空间
hlist_add_head_rcu(&dev->index_hlist, dev_index_hash(net, idx)); // 设备按索引哈希
```

---

## 10. 算法复杂度分析

| 操作 | 时间复杂度 | 说明 |
|------|----------|------|
| `INIT_HLIST_HEAD` | O(1) | 单指针赋值 |
| `INIT_HLIST_NODE` | O(1) | 两个写操作 |
| `hlist_add_head` | O(1) | 4 个指针操作 |
| `hlist_add_before` | O(1) | 4 个指针操作 |
| `hlist_add_behind` | O(1) | 最多 4 个指针操作 |
| `hlist_del` | **O(1)** | 2-3 个指针操作 |
| 遍历（n 个节点） | O(n) | 单向遍历 |

**关键**：hlist 保持了 list_head 的所有 O(1) 链表操作特性，同时将桶头从 16 字节压缩到 8 字节。

---

## 11. 设计思想总结

| 设计决策 | 权衡 | 结果 |
|---------|------|------|
| 单向链表（非循环） | 失去双向遍历和 O(1) 尾访问 | 哈希表不需要这些 |
| `pprev` = 指针的指针 | 删除逻辑稍复杂 | 换来 O(1) 删除，无需遍历 |
| `first == NULL` 空桶 | 无法区分"空桶"和"只删剩一个节点的桶" | 实际上无影响（node.pprev != NULL） |
| `hlist_nulls` | 尾部 marker 比 NULL 复杂 | 解决 ABA 问题，支持 RCU 安全 |

---

## 12. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/list.h` | hlist 基本实现（行 940-1206） |
| `include/linux/list_nulls.h` | hlist_nulls 防 ABA 变体 |
| `include/linux/types.h:208-213` | 数据结构定义 |
| `include/linux/rculist_nulls.h` | RCU + nulls 组合版本 |
| `fs/inode.c` | inode 哈希表 |
| `fs/dcache.c` | dentry 哈希表 |
| `kernel/module/main.c` | 模块哈希表 |

---

## 附录：全内核使用量统计

```
grep -rn "hlist_add_head" linux/ --include="*.c" | wc -l  →  466 处
grep -rn "hlist_for_each_entry" linux/ --include="*.c" | wc -l  →  1111 处
grep -rn "hlist_del\b" linux/ --include="*.c" | wc -l  →  210 处
```
