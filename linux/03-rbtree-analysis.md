# 03-rbtree — 红黑树深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/rbtree.h` + `lib/rbtree.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**rbtree（红黑树）** 是 Linux 内核最常用的自平衡二叉搜索树，用于虚拟内存管理（VMA）、CFS 调度器、epoll 事件管理、文件描述符管理等 O(log n) 场景。

---

## 1. 核心数据结构

### 1.1 struct rb_node — 红黑树节点

```c
// include/linux/rbtree.h:23 — rb_node
struct rb_node {
    unsigned long          __rb_parent_color; // 关键！parent + color 编码在 1 个 unsigned long 中
    struct rb_node         *right;             // 右子树
    struct rb_node         *left;             // 左子树
};

// __rb_parent_color 编码：
//   bits[63:1] = parent 指针（64位下偏移 1 位）
//   bit[0] = 节点颜色（0=红色，1=黑色）
//
// 技巧：利用指针对齐（最低位通常是 0）来复用空间
// Linux 使用这个技巧节省了 8 字节
```

### 1.2 struct rb_root — 红黑树根

```c
// include/linux/rbtree.h:35 — rb_root
struct rb_root {
    struct rb_node         *rb_node;  // 指向树的根节点
};

// 空树：rb_node = NULL
```

### 1.3 struct rb_root_cached — 带缓存的红黑树

```c
// include/linux/rbtree.h:37 — rb_root_cached
struct rb_root_cached {
    struct rb_root         rb_root;  // 红黑树本身
    struct rb_node         *rb_leftmost; // 最左节点缓存（O(1) 找最小）
};

// 用于 CFS 调度器等需要频繁找最小节点的场景
// 避免每次都从根遍历到最左
```

---

## 2. 节点颜色操作

### 2.1 rb_parent / rb_color / rb_set_parent_color

```c
// include/linux/rbtree.h:26
static inline struct rb_node *rb_parent(const struct rb_node *node)
{
    return (struct rb_node *)(node->__rb_parent_color & ~3UL);
    // ~3UL = ...11111100，所以 color 位被清零，parent 指针露出
}

static inline bool rb_is_red(const struct rb_node *node)
{
    return !(node->__rb_parent_color & 1);
    // bit[0] = 0 → 红色
}

static inline bool rb_is_black(const struct rb_node *node)
{
    return (node->__rb_parent_color & 1);
    // bit[0] = 1 → 黑色
}

static inline void rb_set_parent_color(struct rb_node *node,
                                        struct rb_node *parent, int color)
{
    node->__rb_parent_color = (unsigned long)parent | color;
    // parent 地址加上 color 位
}
```

---

## 3. 旋转操作（保持 BST 性质）

### 3.1 左旋（rb_rotate_left）

```c
// lib/rbtree.c:24 — rb_rotate_left
static inline void __rb_rotate_left(struct rb_node *node, struct rb_root *root)
{
    struct rb_node *right = node->right;   // node 的右子
    struct rb_node *parent = rb_parent(node);
    struct rb_node *right_left = right->left; // right 的左子（会成为 node 的右子）

    // 1. right 的左子成为 node 的右子
    node->right = right_left;
    if (right_left)
        rb_set_parent_color(right_left, node, RB_BLACK);

    // 2. right 成为 node 的父节点
    right->__rb_parent_color = node->__rb_parent_color;
    __rb_link_node(node, right, &right->left);
}
```

### 3.2 右旋（rb_rotate_right）

```c
// lib/rbtree.c:37 — rb_rotate_right
static inline void __rb_rotate_right(struct rb_node *node, struct rb_root *root)
{
    struct rb_node *left = node->left;     // node 的左子
    struct rb_node *parent = rb_parent(node);
    struct rb_node *left_right = left->right; // left 的右子

    // 1. left 的右子成为 node 的左子
    node->left = left_right;
    if (left_right)
        rb_set_parent_color(left_right, node, RB_BLACK);

    // 2. left 成为 node 的父节点
    left->__rb_parent_color = node->__rb_parent_color;
    __rb_link_node(node, left, &left->right);
}
```

### 3.3 旋转图解

```
左旋（对 node X）：
      X              Y
     / \    →      / \
    A   Y         X   C
       / \       / \
      B   C     A   B

右旋（对 node Y）：
      Y              X
     / \    →      / \
    X   C         A   Y
   / \               / \
  A   B             B   C
```

---

## 4. 插入与修复（rb_insert）

### 4.1 __rb_insert — 插入后修复

```c
// lib/rbtree.c:69 — __rb_insert
static __always_inline void
__rb_insert(struct rb_node *node, struct rb_root *root,
             bool leftmost, struct rb_node **leftmost_ptr,
             struct rb_node **rightmost_ptr)
{
    struct rb_node *parent = rb_parent(node);
    struct rb_node *gparent;  // 祖父
    struct rb_node *tmp;      // 叔父

    // 情况 1：新节点成为根节点
    if (!parent) {
        rb_set_parent_color(node, NULL, RB_BLACK);
        return;
    }

    // 情况 2：父节点是黑色，直接插入（不影响黑高）
    if (rb_is_red(parent))
        return;

    gparent = rb_parent(parent);  // 祖父一定存在（因为父节点是红色，所以祖父一定存在）

    // 根据父节点是祖父的左子还是右子，分支处理（对称）
    tmp = gparent->right;

    // 父是祖父的左子
    if (parent == gparent->left) {
        // 叔父是右子
        if (tmp && rb_is_red(tmp)) {
            // Case 1: 父和叔都是红色
            // → 父、叔变黑，祖父变红，递归检查祖父
            rb_set_parent_color(tmp, gparent, RB_BLACK);
            rb_set_parent_color(parent, gparent, RB_BLACK);
            node = gparent;
            parent = rb_parent(node);
            rb_set_parent_color(node, parent, RB_RED);
            // 继续向上修复
        }

        tmp = gparent->right;  // 更新叔父

        if (parent->right == node) {
            // Case 2: 新节点是父的右子（内 grandchildren）
            // → 先对父左旋，转为 Case 3
            __rb_rotate_left(parent, root);
            tmp = parent;
            parent = node;
            node = tmp;
        }

        // Case 3: 新节点是父的左子（外 grandchildren）
        // → 对祖父右旋，父变黑，祖父变红
        rb_set_parent_color(parent, gparent, RB_BLACK);
        __rb_rotate_right(gparent, root);
    }

    // 父是祖父的右子（对称处理）
    else {
        tmp = gparent->left;  // 叔父是左子
        // ... 对称代码 ...
    }
}
```

### 4.2 修复的 3 种情况

```
Case 1: 父红 + 叔红（无关于新节点是左还是右）
  处理：父、叔变黑，祖父变红，递归检查祖父

       G(B)              G(R)
      /   \     →       /   \
   P(R)   U(R)        P(B)  U(B)
     |
   N(R)

Case 2: 新节点是父的右子（内 grandchildren）
  处理：父左旋，变成 Case 3

   P(R)            N(R)
     \      →      /
      N(R)        P(R)

Case 3: 新节点是父的左子（外 grandchildren）
  处理：祖父右旋，父变黑，祖父变红

      G(B)              P(B)
      /      →         /  \
   P(R)                N(R) G(R)
     /
  N(R)
```

---

## 5. 删除与修复（rb_erase）

### 5.1 __rb_erase_color — 删除后修复

```c
// lib/rbtree.c:148 — __rb_erase_color
static __always_inline void
__rb_erase_color(struct rb_node *node, struct rb_node *parent,
                  struct rb_root *root)
{
    // 当被删除的节点是黑色时调用（会影响黑高）
    // 通过旋转和重新着色恢复红黑性质

    while (true) {
        // 分 4 种情况处理（根据兄弟节点的颜色和子女颜色）
        // ...
    }
}
```

### 5.2 rb_erase — 删除节点

```c
// lib/rbtree.c:109 — __rb_erase
static inline void __rb_erase(struct rb_node *node, struct rb_root *root)
{
    struct rb_node *rebalance = NULL;  // 需要修复的节点
    struct rb_node *child;

    // 1. 如果有两个子女，用后继替换（后继 = 右子树最左）
    //    删除后继，rebalance = 后继的旧位置
    if (node->left && node->right) {
        struct rb_node *s = rb_next(node);  // 后继
        // 用后继 s 替换 node
        __rb_transplant(node, s, root);
        rebalance = s;  // 删除 s 的位置需要修复
        goto rebalance;
    }

    // 2. 单子女或叶子
    child = node->right ?: node->left;
    __rb_transplant(node, child, root);
    rebalance = node;  // 删除 node 的位置需要修复

rebalance:
    if (child) {
        // child 继承 node 的颜色，所以黑高不变
    } else {
        // child = NULL（叶子），需要修复
    }
}
```

---

## 6. 遍历操作

### 6.1 rb_first / rb_last

```c
// include/linux/rbtree.h:83
static inline struct rb_node *rb_first(const struct rb_root *root)
{
    struct rb_node  *n = root->rb_node;

    if (!n)
        return NULL;

    // 最左 = 最小
    while (n->left)
        n = n->left;
    return n;
}

static inline struct rb_node *rb_last(const struct rb_root *root)
{
    struct rb_node  *n = root->rb_node;

    if (!n)
        return NULL;

    // 最右 = 最大
    while (n->right)
        n = n->right;
    return n;
}
```

### 6.2 rb_next / rb_prev

```c
// include/linux/rbtree.h:90
static inline struct rb_node *rb_next(const struct rb_node *node)
{
    struct rb_node *parent;

    if (rb_parent(node) == node)  // 空树或根
        return NULL;

    // 如果有右子树，后继 = 右子树最左
    if (node->right)
        return rb_first(node->right);

    // 否则向上找最近的一个"作为左子"的祖先
    parent = rb_parent(node);
    while (parent && node == parent->right) {
        node = parent;
        parent = rb_parent(parent);
    }
    return parent;
}
```

### 6.3 遍历宏

```c
// include/linux/rbtree.h:116
#define rb_for_each(pos, root) \
    for (pos = rb_first(root); pos; pos = rb_next(pos))

#define rb_for_each_entry(pos, root, field) \
    for (pos = rb_entry(rb_first(root), typeof(*pos), field); \
         &pos->field; \
         pos = rb_entry(rb_next(&pos->field), typeof(*pos), field))
```

---

## 7. 增强型红黑树（Augmented RB）

### 7.1 rb_augment

```c
// include/linux/rbtree_augmented.h — 增强 API
// 允许在每个节点存储额外信息（如子树大小、最大值等）
// 用途：CFS 调度器的 vruntime 比较

static inline void rb_insert_augmented(struct rb_node *node,
                                       struct rb_root *root,
                                       const struct rb_augment_callbacks *augments,
                                       void *data)
{
    // 插入时自动向上更新 augment 信息
}

// augments->propagate() 在旋转时被调用，更新受影响的节点
```

---

## 8. 内核使用案例

### 8.1 VMA 红黑树（虚拟内存）

```c
// include/linux/mm_types.h — mm_struct
struct mm_struct {
    struct vm_area_struct   *mmap;            // VMAs 链表（线性）
    struct rb_root         mm_rb;           // VMAs 红黑树（快速查找）
    // ...
};

// 查找覆盖 addr 的 VMA：
// rb_search(mm->mm_rb, addr, vm_start) → O(log n)
```

### 8.2 CFS 调度器的 vruntime 树

```c
// kernel/sched/sched.h — cfs_rq（完全公平调度器队列）
struct cfs_rq {
    struct rb_root         tasks_timeline;  // 按 vruntime 排序的红黑树
    struct rb_node         *leftmost;        // 最小 vruntime（最需要调度的任务）
    // ...
};
// 调度器总是选 leftmost = 最小 vruntime 的任务
```

### 8.3 epoll 的红黑树

```c
// fs/eventpoll.c — eventpoll
struct eventpoll {
    struct rb_root         rbr;  // 红黑树，key = 文件描述符
    // ...
};
// epoll_ctl(add) → rb_insert → O(log n) 插入
// epoll_wait → 遍历 rdllist（就绪事件链表），不用红黑树
```

---

## 9. 红黑树 vs 其他树

| 特性 | 红黑树 | AVL 树 | B+ 树 |
|------|--------|--------|-------|
| 平衡程度 | 基本平衡 | 严格平衡 | 叶节点同深度 |
| 高度 | ≤ 2*log n | log n | log n |
| 插入/删除 | O(log n) + 最多 2 次旋转 | O(log n) + 最多 2 次旋转 | O(log n) + 多次旋转 |
| 适合 | 内核（通用）| 数据库（严格平衡）| 文件系统/数据库（磁盘）|

---

## 10. 设计决策总结

| 设计决策 | 原因 |
|---------|------|
| __rb_parent_color 编码 | 节省 8 字节（一个指针的空间存 color）|
| 左旋/右旋 | O(1) 局部调整恢复平衡 |
| O(log n) 查找 | 配合 mm_rb、schedules 等高频查找场景 |
| rb_leftmost 缓存 | CFS 调度器每次要取最小 vruntime，O(1) 优于 O(log n) |
| augmented rbtree | 允许在旋转时更新额外信息（如子树统计）|

---

## 11. 完整文件索引

| 文件 | 行号 | 内容 |
|------|------|------|
| `include/linux/rbtree.h` | 23 | `struct rb_node`（__rb_parent_color 编码）|
| `include/linux/rbtree.h` | 35 | `struct rb_root`、`struct rb_root_cached` |
| `include/linux/rbtree.h` | 26 | `rb_parent`、`rb_is_red`、`rb_set_parent_color` |
| `include/linux/rbtree.h` | 83 | `rb_first`、`rb_last`、`rb_next`、`rb_prev` |
| `include/linux/rbtree_augmented.h` | — | augmented rbtree API |
| `lib/rbtree.c` | 24 | `__rb_rotate_left` |
| `lib/rbtree.c` | 37 | `__rb_rotate_right` |
| `lib/rbtree.c` | 69 | `__rb_insert`、`__rb_insert_color` |
| `lib/rbtree.c` | 109 | `__rb_erase` |
| `lib/rbtree.c` | 148 | `__rb_erase_color` |

---

## 12. 西游记类比

**rbtree** 就像"天竺国取经的客栈预约表"——

> 唐僧每到一站，需要查找附近最紧急的妖怪事件（最小 deadline）。客栈的预约表按 deadline 排序，后来的事件插到合适的位置。为了防止表变成一条长链（最坏情况），每次插入后都要检查——如果某个分支太长了（超过平衡限制），就需要"旋转"一下，把长链变成平衡的树。客栈掌柜还会在每个节点记录"以这个房间为根的子树里，最紧急的是哪件事"（augmented）。这样要找最紧急事件时，直接看树根记录的就行了，不用每次都遍历整棵树。

---

## 13. 关联文章

- **list_head**（article 01）：VMAs 同时用 list（线性遍历）和 rbtree（快速查找）
- **CFS 调度器**（article 37）：cfs_rq.tasks_timeline 使用 rbtree 按 vruntime 排序
- **epoll**（article 80）：epoll 内部用 rbtree 索引 fd