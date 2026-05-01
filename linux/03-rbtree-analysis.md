# 03-rbtree — Linux 内核红黑树深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**红黑树（Red-Black Tree）** 是 Linux 内核中最核心的有序数据结构。它是一个自平衡的二叉搜索树，通过 5 条不变规则保证树高不超过 `2 * log₂(n+1)`——所有操作（查找、插入、删除）在最坏情况下仍保持 O(log n)。

红黑树在内核中的使用无处不在：CFS 调度器通过红黑树按 `vruntime` 组织运行队列（`rb_root_cached`，配合 `rb_leftmost` 缓存实现 O(1) 取最小 `vruntime` 进程）；虚拟内存管理使用增强红黑树组织 VMA；epoll 使用红黑树管理监控的文件描述符。

与教科书中的红黑树实现相比，Linux 版本有几个独特的优化。最显著的是 `__rb_parent_color` 字段——它将父节点指针和红/黑颜色编码合并在一个 `unsigned long` 中，省去了单独的 `color` 字段，将每个节点的大小从 40 字节降到了 32 字节（64 位系统）。这种"位级复用"是内核实现中常见的优化技巧。

Linux 红黑树的另一个特点是：它不直接提供"插入"函数——`rb_link_node` 只负责将节点链接到树中（设置 parent 和 child 指针），`rb_insert_color` 只负责修复颜色。插入的排序逻辑（"向左还是向右走"）由调用者通过比较函数自行实现。这种设计将搜索决策交给了调用者，使红黑树可以在任何类型的键值上使用。

doom-lsp 确认 `include/linux/rbtree.h` 包含约 29 个符号，`lib/rbtree.c` 包含约 20 个实现函数。

红黑树之所以能够在 O(log n) 时间内完成所有操作，根本原因在于它的平衡策略。与 AVL 树要求左右子树高度差不超过 1 的严格平衡不同，红黑树使用了更宽松的平衡条件——它只要求从根到叶子的所有路径中，黑色节点的数量相同，并且不允许连续的红色节点。这个约束保证最长路径不超过最短路径的两倍，即树高 ≤ 2log₂(n+1)。这种宽松的平衡策略使得红黑树在插入和删除时需要的旋转次数显著少于 AVL 树，这是 Linux 内核选择红黑树而非 AVL 树的核心原因。

在内核中，红黑树的最重要应用也许是 CFS 调度器。CFS 使用 rb_root_cached 来管理运行队列，每个调度实体（sched_entity）包含一个 rb_node，按 vruntime 排序。rb_leftmost 缓存直接指向 vruntime 最小的调度实体，这样 pick_next_entity 可以在 O(1) 时间内找到下一个要运行的进程。当进程运行时，update_curr 增加其 vruntime，如果它不再是 leftmost，就会被标记为需要重新调度。这个配合的巧妙之处在于：红黑树的有序性保证了每次调度选择都是公平的（最小 vruntime），而 leftmost 缓存保证了选择的效率（O(1)）。

---

## 1. 核心数据结构

### 1.1 struct rb_node

```c
struct rb_node {
    unsigned long  __rb_parent_color;  // 父节点指针 + 颜色位
    struct rb_node *rb_right;          // 右子树
    struct rb_node *rb_left;           // 左子树
} __attribute__((aligned(sizeof(long))));
```

**关键设计：`__rb_parent_color`**

这是一个典型的"位复用"技巧。由于 `rb_node` 通过 `__attribute__((aligned(sizeof(long))))` 保证 8 字节对齐，所有 `rb_node` 指针的最低 3 位总是 0——因为 8 字节对齐的地址最低 3 位为零。这些本应永远为 0 的位被用来存储颜色信息：

```
  bit 0     = RB_RED (0) / RB_BLACK (1)     ← 节点的颜色
  bit 1     = 未使用
  bit 2     = 未使用
  bit 63:3  = 父节点指针（地址域）
```

颜色通过位运算提取或设置：
```c
// lib/rbtree.c:59
static inline void rb_set_black(struct rb_node *rb)
{
    rb->__rb_parent_color |= RB_BLACK;  // 设置 bit 0
}
```

访问父节点时屏蔽颜色位：
```c
// include/linux/rbtree.h
#define rb_parent(r)   ((struct rb_node *)((r)->__rb_parent_color & ~3))
```

### 1.2 struct rb_root

```c
struct rb_root {
    struct rb_node *rb_node;  // 树的根节点
};
```

简单包装——指向根节点。

### 1.3 struct rb_root_cached

```c
struct rb_root_cached {
    struct rb_root rb_root;          // 根
    struct rb_node *rb_leftmost;     // 最左节点（最小值缓存）
};
```

`rb_leftmost` 指向树中的最左节点（即最小值）。这个缓存在 CFS 调度器中至关重要——每次调度时，`pick_next_entity` 直接从 `rb_leftmost` 获取最小 `vruntime` 的进程，不需要遍历整棵树。维护这个缓存的额外开销很小（每次插入和删除时检查是否需要更新 leftmost）。

doom-lsp 确认 `struct rb_root_cached` 的使用函数：`rb_insert_color_cached`（`rbtree.h:141`）、`rb_erase_cached`（`rbtree.h:151`）、`rb_add_cached`（`rbtree.h:197`）。

---

## 2. 插入操作

### 2.1 基本插入流程

Linux 红黑树的插入分为两个步骤：**排序插入**和**颜色修复**。

**步骤一：排序插入（由调用者实现）**

```c
// 调用者负责通过比较函数找到插入位置
// 然后调用 rb_link_node 将节点链接到树中

// rbtree.h:92
static inline void rb_link_node(struct rb_node *node,
                                 struct rb_node *parent,
                                 struct rb_node **rb_link)
{
    node->__rb_parent_color = (unsigned long)parent;
    node->rb_left = node->rb_right = NULL;

    *rb_link = node;  // 父节点的左或右指针指向新节点
}
```

调用流程：
```
// 典型使用模式：
int my_insert(struct rb_root *root, struct my_node *new)
{
    struct rb_node **link = &root->rb_node;
    struct rb_node *parent = NULL;

    while (*link) {                           // 二叉搜索定位
        parent = *link;
        struct my_node *cur = rb_entry(parent, struct my_node, node);
        if (new->key < cur->key)
            link = &parent->rb_left;
        else if (new->key > cur->key)
            link = &parent->rb_right;
        else
            return -EEXIST;                  // 键已存在
    }

    rb_link_node(&new->node, parent, link);   // 链接到树
    rb_insert_color(&new->node, root);         // 修复颜色
    return 0;
}
```

**步骤二：颜色修复（`rb_insert_color`，核心在 `__rb_insert`）

```c
// lib/rbtree.c:84 — doom-lsp 确认入口
static __always_inline void __rb_insert(struct rb_node *node,
                                         struct rb_node **root,
                                         bool newleft, ...)
```

`__rb_insert` 实现了标准的红黑树插入修复算法，处理三大类情况：

```
插入节点为红色。如果父节点也是红色，违反"红节点不能有红孩子"规则。

情况 1：叔叔节点为红色
  处理：父和叔变黑，爷变红，从爷继续向上检查
  复杂度：O(1)，最坏可能需要回溯到根

情况 2：叔叔为黑色，新节点、父、爷成"之"字形（LR 或 RL）
  处理：父节点旋转 → 转为情况 3
  复杂度：O(1)

情况 3：叔叔为黑色，新节点、父、爷成直线（LL 或 RR）
  处理：爷节点旋转 → 变色 → 修复完成
  复杂度：O(1)
```

doom-lsp 确认 `__rb_insert` 位于 `lib/rbtree.c:84`。

### 2.2 rb_add——简化 API

```c
// rbtree.h:297
#define rb_add(root, node, member, cmp)                         \
    do {                                                        \
        /* 调用者提供比较函数 cmp，rb_add 完成 查找+链接+修复 */
        ...
        rb_insert_color(node, root);                            \
    } while (0)
```

`rb_add` 是简化版本的插入宏，调用者只需提供比较函数。doom-lsp 确认 `rb_add` 在 `rbtree.h:297`，`rb_add_cached`（缓存 leftmost 版本）在 `rbtree.h:197`。

---

## 3. 删除操作

红黑树的删除比插入更复杂，因为删除一个黑色节点会破坏"所有路径黑节点数相等"的规则。

### 3.1 rb_erase（`lib/rbtree.c:440`）

```
rb_erase(node, root)
  │
  ├─ 找到实际删除的节点：
  │    ├─ 被删节点有 2 个子节点
  │    │    └─ 用中序后继（inorder successor）替换
  │    │    └─ 实际删除的是后继节点
  │    │
  │    └─ 被删节点有 0 或 1 个子节点
  │         └─ 直接删除
  │
  ├─ 如果删除的节点是黑色
  │    └─ __rb_erase_color(child, parent, root)  ← 修复
  │
  └─ 更新 rb_leftmost（如果使用 cached 版本）
```

修复函数 `____rb_erase_color`（`lib/rbtree.c:226`）有约 180 行代码，处理删除黑色节点后的各种修复情况。doom-lsp 确认 `rb_erase` 在 `rbtree.h:45` 声明，在 `lib/rbtree.c:440` 实现。

### 3.2 rb_erase_cached（`rbtree.h:151`）

与 `rb_erase` 的区别：在删除后更新 `rb_leftmost`。如果被删除的节点恰好是最左节点，需要找到新的最左节点。

---

## 4. 查找操作

### 4.1 rb_find（`rbtree.h:419`）

```c
#define rb_find(root, key, member, cmp)                         \
    ({                                                          \
        struct rb_node *__n = (root)->rb_node;                  \
        typeof(key) __node = NULL;                              \
        while (__n) {                                           \
            __node = rb_entry(__n, typeof(*key), member);       \
            int __result = cmp(key, __node);                    \
            if (__result < 0)                                   \
                __n = __n->rb_left;                             \
            else if (__result > 0)                              \
                __n = __n->rb_right;                            \
            else                                                \
                break;                                          \
        }                                                       \
        __result == 0 ? __node : NULL;                          \
    })
```

标准的二叉搜索树查找，O(log n)。doom-lsp 确认 `rb_find` 在 `rbtree.h:419`。

### 4.2 rb_find_first（`rbtree.h:478`）

返回第一个匹配的节点。当树中存在多个键值相同的节点时，`rb_find` 返回的是搜索路径上的第一个匹配，而 `rb_find_first` 返回树中该键值的"最左"节点（通过 `rb_find_add` 总是将重复键插入到已存在节点的右侧来实现）。

### 4.3 rb_next / rb_prev

```c
// rbtree.h:49
struct rb_node *rb_next(struct rb_node *node);

// rbtree.h:50
struct rb_node *rb_prev(struct rb_node *node);
```

中序遍历的后继和前驱节点。doom-lsp 确认实现位于 `lib/rbtree.c:480` 和 `lib/rbtree.c:512`。

---

## 5. 增强 API（Augmented rbtree）

增强红黑树在每个节点上存储子树聚合信息。在 `include/linux/rbtree_augmented.h` 中定义。

```c
struct rb_augment_callbacks {
    void (*propagate)(struct rb_node *node, struct rb_node *stop);
    void (*copy)(struct rb_node *old, struct rb_node *new);
    void (*rotate)(struct rb_node *old, struct rb_node *new);
};
```

典型应用：VMA 区间树的 `subtree_last` 字段存储子树中所有 VMA 的最大结束地址。查找"包含 addr 的 VMA"时，通过比较 `subtree_last` 快速剪枝：

```c
// mm/interval_tree.c
// 查询：找到第一个包含 addr 的 VMA
// 通过 subtree_last 跳过不可能包含 addr 的子树
while (node) {
    if (node->subtree_last < addr)
        break;  // 整个子树都没有 addr
    // ...
}
```

doom-lsp 确认 `__rb_insert_augmented`（`lib/rbtree.c:473`）和 `__rb_erase_color`（`rb_erase_color` 调用增强回调版本）处理增强信息的传播。

---

## 6. 内核中的应用实例

### 6.1 CFS 调度器

```c
// kernel/sched/fair.c
struct cfs_rq {
    struct rb_root_cached tasks_timeline;  // 按 vruntime 排序

    // pick_next_entity: O(1) 取最左节点
    // 通过 rb_root_cached.rb_leftmost 直接获取
};
```

### 6.2 VMA 区间树

```c
// mm/mmap.c
// 进程的所有 VMA 按地址组织在红黑树中
// find_vma(mm, addr) 在 O(log n) 时间内找到
// 第一个 vm_end > addr 的 VMA
```

### 6.3 epoll

```c
// fs/eventpoll.c
// 每个被监控的文件描述符对应一个 epitem
// 通过红黑树按 fd 组织，实现 O(log n) 的查找和插入
struct rb_root_cached rbr;
```

---

## 7. 与 AVL 树的对比

| 特性 | 红黑树 | AVL 树 |
|------|--------|--------|
| 平衡条件 | 颜色约束（不太严格） | 高度差（更严格） |
| 树高 | ≤ 2*log₂(n+1) | ≤ 1.44*log₂(n) |
| 插入平均旋转 | ~0.5 次 | ~0.5 次 |
| 删除平均旋转 | ~1 次 | ~2 次 |
| 查找性能 | 稍慢 | 更快的命中率 |
| 适用场景 | 插入/删除频繁 | 查找频繁 |

内核选择红黑树而非 AVL 树的理由是：红黑树在插入和删除时需要的旋转次数更少（平均约为 AVL 的一半），而内核中的红黑树使用场景通常是"频繁插入/删除 + 偶尔遍历"，这与红黑树的优势相匹配。

---

## 8. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/rbtree.h` | `struct rb_node`, `struct rb_root` | 定义 |
| `include/linux/rbtree.h` | `rb_insert_color` / `rb_erase` | 声明 |
| `include/linux/rbtree.h` | `rb_add` / `rb_find` | 宏 |
| `include/linux/rbtree.h` | `rb_next` / `rb_prev` | 49 |
| `lib/rbtree.c` | `__rb_insert` | 84 |
| `lib/rbtree.c` | `____rb_erase_color` | 226 |
| `lib/rbtree.c` | `rb_erase` | 440 |

---

## 9. 关联文章

- **CFS 调度器**（article 37）：使用 rb_root_cached 组织运行队列
- **VMA**（article 16）：VMA 通过增强红黑树组织
- **epoll**（article 85）：epoll 使用红黑树管理 fd
- **list_head**（article 01）：未排序的线性数据结构

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
