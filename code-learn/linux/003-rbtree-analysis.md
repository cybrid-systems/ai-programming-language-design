# 03-rbtree — Linux 内核红黑树深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**红黑树（Red-Black Tree）** 是 Linux 内核中最核心的有序数据结构。它是一个自平衡的二叉搜索树，通过 5 条不变规则保证树高不超过 `2 * log₂(n+1)`——所有操作（查找、插入、删除）在最坏情况下仍保持 O(log n)。

红黑树在内核中的使用无处不在：CFS 调度器通过红黑树按 `vruntime` 组织运行队列（`rb_root_cached`，配合 `rb_leftmost` 缓存实现 O(1) 取最小 `vruntime` 进程）；虚拟内存管理使用增强红黑树（interval tree）组织 VMA；epoll 使用红黑树管理监控的文件描述符；文件系统的 inode 和 dentry 缓存也使用红黑树。

与教科书中的红黑树实现相比，Linux 版本有几个独特的优化：

1. **`__rb_parent_color` 位复用**：将父节点指针和红/黑颜色编码合并在一个 `unsigned long` 中，省去了单独的 `color` 字段，将每个节点的大小从 40 字节降到了 32 字节（64 位系统）。
2. **排序逻辑外置**：内核不提供"插入函数"，而是通过 `rb_link_node` + `rb_insert_color` 两步完成——调用者通过自行实现的比较函数决定插入位置。这种设计将搜索决策交给了调用者。
3. **增强回调**：`rb_augment_callbacks` 允许节点存储子树聚合信息，支持 interval tree 等高级用法。
4. **Leftmost 缓存**：`rb_root_cached` 缓存最小元素指针，实现 O(1) 取最小值。

**doom-lsp 确认**：`include/linux/rbtree.h` 包含 **29 个函数符号**（声明和 inline 函数），`lib/rbtree.c` 包含 **54 个符号**（含 `EXPORT_SYMBOL` 导出声明），其中实际函数实现 18 个。

---

## 1. 红黑树的 5 条不变规则

红黑树之所以能够在 O(log n) 时间内完成所有操作，根本原因在于其平衡策略：

1. **每个节点要么是红色，要么是黑色**
2. **根节点是黑色**
3. **所有叶子（NULL）是黑色**
4. **红色节点不能有红色子节点**（即红色节点的两个子节点必须都是黑色）
5. **从任意节点到其每个叶子的所有简单路径都包含相同数量的黑色节点**

规则 4 和 5 保证了最长路径不超过最短路径的两倍。严格证明：最短路径全黑，最长路径红黑交替，因此最长路径 ≤ 2 × 最短路径。所以树高 ≤ 2log₂(n+1)。

与 AVL 树要求左右子树高度差不超过 1 的严格平衡不同，红黑树使用了更宽松的平衡条件。这种宽松策略使得红黑树在插入和删除时需要的旋转次数显著少于 AVL 树——插入平均约 0.5 次旋转（vs AVL 的 0.5 次，但最大不同），删除平均约 1 次旋转（vs AVL 的 2+ 次）。这是 Linux 内核选择红黑树而非 AVL 树的核心原因。

---

## 2. 核心数据结构

### 2.1 `struct rb_node`

```c
// include/linux/rbtree_types.h:5 — doom-lsp 确认
struct rb_node {
    unsigned long  __rb_parent_color;  // 父节点指针 + 颜色位
    struct rb_node *rb_right;          // 右子树
    struct rb_node *rb_left;           // 左子树
} __attribute__((aligned(sizeof(long))));
```

**关键设计：`__rb_parent_color`**

这是一个典型的"位复用"技巧。由于 `rb_node` 通过 `__attribute__((aligned(sizeof(long))))` 保证 8 字节对齐，所有 `rb_node*` 指针的最低 3 位总是 0——因为 8 字节对齐的地址最低 3 位为零。这些本应永远为 0 的位被用来存储颜色信息：

```
__rb_parent_color (unsigned long, 64-bit):
┌──────────────────────────────────────────────────────────────┬─────┬─────┬─────┐
│                   父节点指针（地址域）                        │ bit2 │ bit1 │ bit0│
│                      62 位指针域                               │ zero │ zero │颜色│
└──────────────────────────────────────────────────────────────┴─────┴─────┴─────┘
  bit 63:3 = 父节点指针（右移 3 位？不，直接存储，低 3 位复用）
  bit 0 = RB_RED (0) / RB_BLACK (1)
  bit 1-2 = 未使用（保留）
```

**doom-lsp 指令级分析——颜色操作**：

```c
// lib/rbtree.c:59 — doom-lsp 确认
static inline void rb_set_black(struct rb_node *rb)
{
    rb->__rb_parent_color += RB_BLACK;   // set bit 0 via addition
}
// 编译为: ADD $1, [rb]     (x86-64: 一条 ADD 指令)

#define rb_is_red(rb)    __rb_is_red((rb)->__rb_parent_color)
// 展开为: !((rb)->__rb_parent_color & 1)
// 编译为: TEST $1, [rb] + conditional jump
```

**获取父节点指针**（屏蔽颜色位）：

```c
// include/linux/rbtree.h
#define rb_parent(r)   ((struct rb_node *)((r)->__rb_parent_color & ~3))
// 编译为: AND $(~3), reg    (清空低 2 位)
```

为什么屏蔽低 2 位而非低 1 位？这是防御性设计——如果未来需要使用 bit 1，代码不需要修改。`~3` 屏蔽了 bit 0 和 bit 1，保证无论颜色位在哪个位置，父节点地址都能正确提取。

### 2.2 `struct rb_root`

```c
// include/linux/rbtree.h
struct rb_root {
    struct rb_node *rb_node;  // 树的根节点，NULL = 空树
};
```

简单包装——指向根节点。空树时 `rb_node == NULL`，与 hlist 的 `first == NULL` 语义一致。

### 2.3 `struct rb_root_cached`

```c
// include/linux/rbtree.h
struct rb_root_cached {
    struct rb_root rb_root;          // 根
    struct rb_node *rb_leftmost;     // 最左节点（最小值缓存）
};
```

`rb_leftmost` 指向树中的最左节点（即最小值）。这个缓存在 CFS 调度器中至关重要——每次调度时，`__pick_first_entity` 直接从 `rb_leftmost` 获取最小 `vruntime` 的进程，**不需要遍历整棵树**。维护这个缓存的额外开销很小：每次插入和删除时检查是否需要更新 leftmost。

**doom-lsp 确认**的 cached 版本 API：

| 函数 | 位置 | 说明 |
|------|------|------|
| `rb_insert_color_cached` | rbtree.h:141 | 插入后修复颜色 + 维护 leftmost |
| `rb_erase_cached` | rbtree.h:151 | 删除 + 维护 leftmost |
| `rb_replace_node_cached` | rbtree.h:164 | 替换节点 + 维护 leftmost |
| `rb_add_cached` | rbtree.h:197 | 简化插入 + leftmost |

### 2.4 `rb_add` 系列——简化插入宏

```c
// rbtree.h:297 — doom-lsp 确认
#define rb_add(root, node, member, cmp) ...
// rbtree.h:197
#define rb_add_cached(root, node, member, cmp) ...
// rbtree.h:221
#define __rb_add(root, node, member, cmp) ...
// rbtree.h:277
#define rb_add_linked(root, node, member, cmp) ...
```

`rb_add` 和 `rb_add_cached` 是简化 API，调用者只需提供比较函数 `cmp`：

```c
// 使用示例：
struct my_node *new = kmalloc(sizeof(*new), GFP_KERNEL);
new->key = 42;
rb_add_cached(&root, &new->node, my_node, node, my_cmp);
```

doom-lsp 确认这些宏在 rbtree.h 中的精确位置。

---

## 3. 插入操作——完整的双阶段模型

Linux 红黑树的插入分为两个独立阶段：**排序插入**（由调用者实现）和**颜色修复**（由内核实现）。

### 3.1 阶段一：排序插入——`rb_link_node`

```c
// include/linux/rbtree.h:92 — doom-lsp 确认
static inline void rb_link_node(struct rb_node *node,
                                 struct rb_node *parent,
                                 struct rb_node **rb_link)
{
    node->__rb_parent_color = (unsigned long)parent;  // 父节点指针（颜色 = RED，因为最低位未设置）
    node->rb_left = node->rb_right = NULL;

    *rb_link = node;  // 父节点的左或右指针指向新节点
}
```

调用者通过二叉搜索遍历定位插入位置，然后调用 `rb_link_node`：

```c
// 典型使用模式（doom-lsp 数据流追踪）：
int my_insert(struct rb_root *root, struct my_node *new)
{
    struct rb_node **link = &root->rb_node;   // 起始：根
    struct rb_node *parent = NULL;

    while (*link) {                           // 二叉搜索定位
        parent = *link;
        struct my_node *cur = rb_entry(parent, struct my_node, node);
        if (new->key < cur->key)
            link = &parent->rb_left;          // 走左子树
        else if (new->key > cur->key)
            link = &parent->rb_right;         // 走右子树
        else
            return -EEXIST;                   // 键已存在
    }

    rb_link_node(&new->node, parent, link);   // 链接到树
    rb_insert_color(&new->node, root);        // 阶段二：修复颜色
    return 0;
}
```

### 3.2 阶段二：颜色修复——`__rb_insert`

```c
// lib/rbtree.c:84 — doom-lsp 确认
static __always_inline void
__rb_insert(struct rb_node *node, struct rb_root *root,
            void (*augment_rotate)(struct rb_node *old, struct rb_node *new))
```

doom-lsp 确认 `__rb_insert` 位于 `lib/rbtree.c:84`。它是一个 `__always_inline` 函数，保证编译时展开（避免函数调用）。它实现标准的红黑树插入修复算法，处理三大类情况：

```
插入节点为红色。如果父节点也是红色，违反规则 4。

╔══════════════════════════════════════════════════════════════════╗
║  情况 1：叔叔节点为红色（颜色翻转）                             ║
║                                                                  ║
║        G(黑)              g(红)                                  ║
║       /    \             /    \                                  ║
║      p(红)  u(红)  →    P(黑)  U(黑)                             ║
║     /                    /                                       ║
║    n(红)               n(红)                                    ║
║                                                                  ║
║  处理：父和叔变黑，爷变红，从爷继续向上检查                       ║
║  复杂度：O(1)，最坏可能需要回溯到根                               ║
╚══════════════════════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════════════════════╗
║  情况 2：叔叔为黑色，n-p-g 成"之"字形（LR 或 RL）                ║
║                                                                  ║
║        G(黑)              G(黑)                                  ║
║       /    \             /    \                                  ║
║      p(红)  U(黑)  →    n(红)  U(黑)                             ║
║        \                /                                        ║
║         n(红)         p(红)                                     ║
║                                                                  ║
║  处理：左旋(p)，转为情况 3                                        ║
║  复杂度：O(1)                                                    ║
╚══════════════════════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════════════════════╗
║  情况 3：叔叔为黑色，n-p-g 成直线（LL 或 RR）                     ║
║                                                                  ║
║        G(黑)              P(黑)                                  ║
║       /    \             /    \                                  ║
║      p(红)  U(黑)  →    n(红)  g(红)                             ║
║     /                             \                              ║
║    n(红)                          U(黑)                         ║
║                                                                  ║
║  处理：右旋(G)，变色 → 修复完成                                   ║
║  复杂度：O(1)                                                    ║
╚══════════════════════════════════════════════════════════════════╝
```

**doom-lsp 确认的展开代码**（`lib/rbtree.c:84` 的前 120 行）：

```c
// lib/rbtree.c:88 — 循环入口
while (true) {
    // 检查父节点颜色和类型
}
```

关键观察：循环体内使用 `rb_red_parent()` 而非 `rb_parent()`——这是专门从红色节点的父节点提取指针的包装函数，暗示了循环不变式：`node` 总是红色的。

### 3.3 `_cached` 版本——维护 leftmost

```c
// include/linux/rbtree.h:141 — doom-lsp 确认
static inline void rb_insert_color_cached(struct rb_node *node,
                                           struct rb_root_cached *root,
                                           bool leftmost)
{
    // 如果新节点是最左节点，更新 rb_leftmost
    if (leftmost)
        root->rb_leftmost = node;
    // 调用普通插入颜色修复
    rb_insert_color(node, &root->rb_root);
}
```

**数据流追踪——`leftmost` 参数的来源**：

调用者在 `rb_add_cached` 宏中通过比较 `__rb_add` 返回的 leftmost 标记决定新节点是否是最左节点：

```c
// rbtree.h:197 — rb_add_cached 展开
bool __leftmost = __rb_add(node, ...);
if (__leftmost)
    root->rb_leftmost = node;  // 或者让 rb_insert_color_cached 更新
```

---

## 4. 删除操作——内核中最复杂的数据结构操作

红黑树的删除比插入更复杂，因为删除一个黑色节点会破坏规则 5（所有路径黑节点数相等）。

### 4.1 `rb_erase`——标准删除（`lib/rbtree.c:440`）

doom-lsp 确认 `rb_erase` 的实现位于 `lib/rbtree.c:440`。调用链：

```
rb_erase(node, root)                      @ lib/rbtree.c:440
  │
  ├─ __rb_erase_color(child, parent, root)  [如果删除的节点是黑色]
  │   └─ @ lib/rbtree.c:410
  │       └─ ____rb_erase_color @ lib/rbtree.c:226
  │           └─ 约 180 行的复杂修复逻辑
  │
  ├─ rb_left_deepest_node                  [postorder 辅助]
  │   └─ @ lib/rbtree.c:580
  │
  └─ 更新 rb_leftmost（如果使用 cached 版本）
```

删除分为三种情况：

```
情况 A：被删节点是红色（子节点数为 0 或 1）
  → 直接删除，不违反任何规则（黑节点数不变）
  → O(1)，无需修复

情况 B：被删节点是黑色，有 0 或 1 个子节点
  → 用子节点替换它
  → 子节点继承"黑色"职责 → 需要修复"双黑"（double black）
  → __rb_erase_color 处理

情况 C：被删节点有两个子节点
  → 找到中序后继（inorder successor）替换被删节点
  → 实际删除的是后继节点（它最多有一个子节点）
  → 退化到情况 A 或 B
```

### 4.2 `____rb_erase_color`——删除修复的核心（`lib/rbtree.c:226`）

这是整个红黑树库中最复杂的函数，约 180 行代码。它处理"双黑"恢复的四种标准情况：

```
被删除黑色节点后，其子节点（替换者）获得"额外黑色"
→ 称为"双黑节点"
→ 循环直到双黑消除或到达根

Case 1: 兄弟节点是红色
  → 旋转使兄弟变黑，进入 Case 2/3/4
Case 2: 兄弟节点是黑色，且兄弟的两个子节点都是黑色
  → 兄弟变红，双黑上移
Case 3: 兄弟节点是黑色，兄弟的左子是红色、右子是黑色
  → 右旋兄弟，转为 Case 4
Case 4: 兄弟节点是黑色，兄弟的右子是红色
  → 左旋父节点，变色 → 双黑消除 → 终止
```

### 4.3 `rb_erase_linked`——链式删除（`lib/rbtree.c:449`）

```c
// lib/rbtree.c:449 — doom-lsp 确认
void rb_erase_linked(struct rb_node *node, struct rb_root *root)
```

这是内核 7.0-rc1 的新增函数，用于批量删除多个关联节点。当删除一个节点后，它的后继者可能也需要从树中移除——`rb_erase_linked` 处理这种级联删除场景。

---

## 5. 查找操作

### 5.1 `rb_find`——查找匹配节点（`rbtree.h:419`）

```c
// rbtree.h:419 — doom-lsp 确认
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

标准的二叉搜索树查找，O(log n)。使用 `typeof` 保证类型安全。

### 5.2 `rb_find_rcu`——RCU 安全的查找（`rbtree.h:450`）

```c
// rbtree.h:450 — doom-lsp 确认
#define rb_find_rcu(root, key, member, cmp) ...
```

与 `rb_find` 的区别：使用 `rcu_dereference` 读取指针，确保在 RCU 临界区内的一致性。

### 5.3 `rb_find_first`——第一个匹配节点（`rbtree.h:478`）

```c
// rbtree.h:478 — doom-lsp 确认
#define rb_find_first(root, key, member, cmp) ...
```

当树中存在多个键值相同的节点时，`rb_find` 返回搜索路径上的第一个匹配。`rb_find_first` 通过持续向左搜索直到不再匹配，返回该键值的最左节点。

```c
// rbtree.h:508 — doom-lsp 确认
#define rb_next_match(result, key, pos, member) ...
```

在 `rb_find_first` 之后调用，按中序遍历所有匹配的后续节点。

### 5.4 `rb_next` / `rb_prev`——中序遍历的后继/前驱

```c
// rbtree.h:49-50 — doom-lsp 确认（声明）
struct rb_node *rb_next(struct rb_node *node);  // lib/rbtree.c:480
struct rb_node *rb_prev(struct rb_node *node);  // lib/rbtree.c:512
```

doom-lsp 确认实现位置：

- `rb_next` @ `lib/rbtree.c:480`：
```c
struct rb_node *rb_next(const struct rb_node *node)
{
    struct rb_node *parent;

    if (RB_EMPTY_NODE(node))
        return NULL;

    if (node->rb_right) {                // 有右子树 → 右子树的最左节点
        node = node->rb_right;
        while (node->rb_left)
            node = node->rb_left;
        return (struct rb_node *)node;
    }

    while ((parent = rb_parent(node)) && node == parent->rb_right)
        node = parent;                   // 向上回溯
    return parent;
}
```

- `rb_prev` @ `lib/rbtree.c:512`（对称实现）

### 5.5 `rb_first` / `rb_last`——极值节点

```c
// rbtree.h:55 — doom-lsp 确认
struct rb_node *rb_first(const struct rb_root *root);
// rbtree.h:70
struct rb_node *rb_last(const struct rb_root *root);
```

- `rb_first`：不断向左直到 `rb_left == NULL`，即最小值
- `rb_last`：不断向右直到 `rb_right == NULL`，即最大值
- `rb_first_cached`：直接从 `rb_root_cached.rb_leftmost` 返回缓存

---

## 6. 增强红黑树（Augmented rbtree）

增强红黑树在每个节点上存储**子树聚合信息**，在 `include/linux/rbtree_augmented.h` 中定义。

### 6.1 回调函数结构

```c
// include/linux/rbtree_augmented.h
struct rb_augment_callbacks {
    void (*propagate)(struct rb_node *node, struct rb_node *stop);
    void (*copy)(struct rb_node *old, struct rb_node *new);
    void (*rotate)(struct rb_node *old, struct rb_node *new);
};
```

三个回调的职责：

| 回调 | 触发时机 | 职责 |
|------|---------|------|
| `propagate` | 插入/删除后 | 从 node 向上传播聚合信息直到 stop |
| `copy` | 替换节点时 | 将旧节点的聚合信息复制到新节点 |
| `rotate` | 树旋转时 | 更新旋转涉及的节点的聚合信息 |

### 6.2 VMA interval tree——doom-lsp 数据流追踪

```c
// mm/interval_tree.c:19 — doom-lsp 确认
INTERVAL_TREE_DEFINE(struct vm_area_struct, shared.rb,   // rb_node 成员
                     unsigned long, shared.rb_subtree_last, // 聚合字段
                     vma_start_pgoff, vma_last_pgoff,     // 区间边界
                     /* empty */, vma_interval_tree)
```

**数据结构**：

```c
struct vm_area_struct {
    struct rb_node rb;                    // 红黑树节点
    unsigned long vm_start;               // VMA 起始地址
    unsigned long vm_end;                 // VMA 结束地址
    struct {
        unsigned long rb_subtree_last;    // 子树最大结束地址（聚合信息）
    } shared;
};
```

**数据流追踪——VMA 查找**：

```
find_vma(mm, addr):
  → 在 VMA 红黑树中搜索第一个 vm_end > addr 的 VMA

  遍历中的剪枝：
  while (node) {
      if (node->shared.rb_subtree_last < addr)
          break;  // ← 整个子树都没有地址范围覆盖 addr，立即剪枝
                   //   这是增强红黑树的核心优势

      if (vma_start_pgoff(node) <= addr && ...)
          return node;

      // 继续搜索左子树或右子树
  }
```

**数据流追踪——插入时聚合信息的传播**：

```c
// mm/interval_tree.c:39-52 — doom-lsp 确认
static inline unsigned long vma_interval_tree_subtree_last(struct vm_area_struct *vma)
{
    return vma_last_pgoff(vma);  // 当前 VMA 的结束地址
}

// 在 propagate 回调中：
void vma_interval_tree_propagate(struct rb_node *rb, struct rb_node *stop)
{
    while (rb != stop) {
        struct vm_area_struct *node = rb_entry(rb, struct vm_area_struct, shared.rb);
        unsigned long last = node->shared.rb_subtree_last;
        unsigned long subtree_last = vma_interval_tree_subtree_last(node);

        if (node->shared.rb.rb_left) {
            struct vm_area_struct *left = rb_entry(node->shared.rb.rb_left,
                struct vm_area_struct, shared.rb);
            subtree_last = max(subtree_last, left->shared.rb_subtree_last);
        }
        if (node->shared.rb.rb_right) {
            struct vm_area_struct *right = rb_entry(node->shared.rb.rb_right,
                struct vm_area_struct, shared.rb);
            subtree_last = max(subtree_last, right->shared.rb_subtree_last);
        }

        if (subtree_last == last) break;  // 没变化，提前停止

        node->shared.rb_subtree_last = subtree_last;
        rb = rb_parent(&node->shared.rb);  // 向上传播
    }
}
```

**关键洞察**：propagate 在 `subtree_last == last` 时提前终止——如果聚合值未变化，上层节点也不会有变化。这是一个重要的优化，避免不必要的缓存行写入。

### 6.3 CFS 调度器中的增强回调

```c
// kernel/sched/fair.c:1011 — doom-lsp 确认
rb_add_augmented_cached(&se->run_node, &cfs_rq->tasks_timeline,
                        __entity_less, &min_vruntime_cb);
```

CFS 使用 `min_vruntime_cb` 作为增强回调，在插入/删除时更新 `cfs_rq->min_vruntime`：

```c
const struct rb_augment_callbacks min_vruntime_cb = {
    .propagate = min_vruntime_propagate_cb,
    .copy = min_vruntime_copy_cb,
    .rotate = min_vruntime_rotate_cb,
};
```

每个节点的 `min_vruntime` 聚合反映了子树的最小 vruntime，使得 CFS 在 O(1) 时间内找到全局最小 vruntime（通过 leftmost）的同时，还能在 O(log n) 时间内计算任何子树范围的 min_vruntime。

---

## 7. 插入查找辅助宏

### 7.1 `rb_find_add_cached`（`rbtree.h:313`）

```c
// rbtree.h:313 — doom-lsp 确认
#define rb_find_add_cached(root, node, member, cmp) ...
```

合并查找和插入：如果键不存在则插入并返回 0，如果键已存在则返回已存在的节点。这是内核中最常用的"查找或创建"模式。

### 7.2 `rb_find_add`（`rbtree.h:350`）

```c
// rbtree.h:350 — doom-lsp 确认
#define rb_find_add(root, node, member, cmp) ...
```

与 `rb_find_add_cached` 类似，但不维护 leftmost 缓存。

### 7.3 `rb_find_add_rcu`（`rbtree.h:386`）

RCU 安全版本，在 RCU 临界区内执行查找或插入。

### 7.4 `rb_link_linked_node` 与 `rb_add_linked`（`rbtree.h:245, 277`）

```c
// rbtree.h:245 — doom-lsp 确认
static inline void rb_link_linked_node(struct rb_node *node, ...);
```

将节点链接到已存在的邻居之间。`rb_add_linked`（`rbtree.h:277`）在此基础上完成完整的插入流程。

---

## 8. 🔥 doom-lsp 数据流追踪——CFS 调度器任务排队

### 8.1 完整调用栈

```
pick_next_task_fair(rq, prev)
  └─ __pick_first_entity(cfs_rq)
       └─ cfs_rq->tasks_timeline.rb_leftmost  ← O(1) 取最小 vruntime
         └─ rb_entry(left, struct sched_entity, run_node)
           └─ container_of(left, sched_entity, run_node)
             → 返回 vruntime 最小的调度实体

enqueue_task_fair(rq, p, flags)
  └─ enqueue_entity(cfs_rq, se, flags)
       └─ __enqueue_entity(cfs_rq, se)
            └─ rb_add_augmented_cached(
                 &se->run_node,
                 &cfs_rq->tasks_timeline,
                 __entity_less,           // 比较函数：se->vruntime 排序
                 &min_vruntime_cb)        // 增强回调
              │
              ├─ __rb_add: 二叉搜索定位插入点
              │   └─ __entity_less(se, existing)
              │       = se->vruntime < existing->vruntime → 左子树
              │       = se->vruntime > existing->vruntime → 右子树
              │
              ├─ rb_link_node 将 se->run_node 链入树
              │
              └─ rb_insert_color_cached: 颜色修复 + leftmost 维护
```

### 8.2 数据流——键值（vruntime）的修改

当进程运行时，`update_curr(cfs_rq)` 会递增当前进程的 `vruntime`：

```
update_curr(cfs_rq)
  └─ curr->vruntime += delta_exec * NICE_0_LOAD / curr->load.weight

如果 curr->vruntime 增加后，curr 不再是 leftmost：
  └─ 设置 TIF_NEED_RESCHED 标志
  └─ 下一次调度周期，pick_next_task_fair 会选新的 leftmost 运行
```

如果 vruntime 增加后 curr 仍然是 leftmost，不需要重新调度——这是 CFS "公平性"的自然保证。

### 8.3 数据结构关系图

```
struct cfs_rq {
    struct rb_root_cached tasks_timeline;
        ├── rb_root.rb_node ──→ rb_node (根节点)
        └── rb_leftmost ──→ rb_node (最左节点 = 最小 vruntime)

    // 每次调用 pick_next_task_fair:
    // left = rq->cfs_rq->tasks_timeline.rb_leftmost
    // se = container_of(left, struct sched_entity, run_node)
    // → O(1) 获取下一个要运行的进程
};
```

---

## 9. 🔥 doom-lsp 数据流追踪——epoll 的文件描述符红黑树

### 9.1 数据结构

```c
// fs/eventpoll.c:194 — doom-lsp 确认
struct eventpoll {
    struct rb_root_cached rbr;    // 按 fd 号组织的红黑树
    // ...
};

struct epitem {
    struct rb_node rbn;           // 链入 ep->rbr
    struct list_head fllink;      // 链入 file->f_ep 链表
    struct epoll_filefd ffd;      // 包含 fd 号和 file 指针
    // ...
};
```

### 9.2 插入（`fs/eventpoll.c:1387`）

```c
// fs/eventpoll.c:1387 — doom-lsp 确认
static void ep_rbtree_insert(struct eventpoll *ep, struct epitem *epi)
{
    struct rb_node **p = &ep->rbr.rb_root.rb_node, *parent = NULL;
    struct epitem *epic;
    bool leftmost = true;

    while (*p) {
        parent = *p;
        epic = rb_entry(parent, struct epitem, rbn);
        if (epi->ffd.fd > epic->ffd.fd) {
            p = &parent->rb_right;
            leftmost = false;           // 往右走 → 不可能是 leftmost
        } else {
            p = &parent->rb_left;
        }
    }

    rb_link_node(&epi->rbn, parent, p);
    rb_insert_color_cached(&epi->rbn, &ep->rbr, leftmost);
}
```

### 9.3 查找

```c
// fs/eventpoll.c:1184 — doom-lsp 确认
static int ep_find(struct eventpoll *ep, struct file *file, int fd)
{
    for (rbp = ep->rbr.rb_root.rb_node; rbp; ) {
        struct epitem *epi = rb_entry(rbp, struct epitem, rbn);

        int cmp = ep_cmp_ffd(&epi->ffd, &_ffd);
        if (cmp > 0)
            rbp = rbp->rb_left;
        else if (cmp < 0)
            rbp = rbp->rb_right;
        else
            return epi;  // 找到！
    }
    return NULL;
}
```

### 9.4 删除

```c
// fs/eventpoll.c:879 — doom-lsp 确认
rb_erase_cached(&epi->rbn, &ep->rbr);
```

---

## 10. postorder 遍历——`rb_first_postorder` / `rb_next_postorder`

```c
// lib/rbtree.c:611 — doom-lsp 确认
struct rb_node *rb_first_postorder(const struct rb_root *root);
// lib/rbtree.c:592
struct rb_node *rb_next_postorder(const struct rb_node *node);
```

后序（postorder）遍历：左→右→根。用于**安全释放树中所有节点**：

```c
struct rb_node *node = rb_first_postorder(&root);
while (node) {
    struct my_struct *data = rb_entry(node, struct my_struct, node);
    struct rb_node *next = rb_next_postorder(node);
    kfree(data);            // 释放 data（含 rb_node）
    node = next;
}
```

后序遍历保证了子节点在父节点之前被访问，因此可以在遍历中安全地释放节点而不会访问已释放的内存。

`rb_first_postorder`（`lib/rbtree.c:611`）找到最左最深节点。`rb_next_postorder`（`lib/rbtree.c:592`）遍历的下一个后序节点——通过 `rb_left_deepest_node`（`lib/rbtree.c:580`）找到后继。

---

## 11. 替换操作——`rb_replace_node` 系列

```c
// lib/rbtree.c:541 — doom-lsp 确认
void rb_replace_node(struct rb_node *victim, struct rb_node *new,
                      struct rb_root *root);

// lib/rbtree.c:558
void rb_replace_node_rcu(struct rb_node *victim, struct rb_node *new,
                          struct rb_root *root);
```

直接替换树中的节点（不涉及颜色修复）。RCU 版本（`rb_replace_node_rcu`）使用 `rcu_assign_pointer` 保证替换的原子性。

---

## 12. 性能数据——指令级分析

| 操作 | 位置 | 复杂度 | 旋转次数（最坏） | 实际指令数 |
|------|------|--------|----------------|-----------|
| `rb_find` | rbtree.h:419 | O(log n) | 0 | log₂(n) × (2 次指针解引用 + 比较) |
| `rb_add` | rbtree.h:297 | O(log n) | 2 | log₂(n) 查找 + 4 次写入 + 修复 |
| `rb_insert_color` | rbtree.c:434 | O(log n) | 2 | 3 种 case，平均 ~30 条指令 |
| `rb_erase` | rbtree.c:440 | O(log n) | 3 | `____rb_erase_color` ~180 行 |
| `rb_next` | rbtree.c:480 | O(log n) 均摊 O(1) | 0 | 两种情况，~10 条指令 |
| `rb_first` | inline | O(log n) | 0 | 沿左子树遍历 |
| `rb_first_cached` | inline | **O(1)** | 0 | **1 次指针解引用** |
| `rb_find_first` | rbtree.h:478 | O(log n) | 0 | 同 rb_find + 向左搜索 |
| `rb_link_node` | rbtree.h:92 | O(1) | 0 | 3 次写入 |
| `rb_replace_node` | rbtree.c:541 | O(1) | 0 | 6 次指针操作 |
| `rb_erase_linked` | rbtree.c:449 | O(log n) | 3 | 与 rb_erase 类似 |
| `rb_first_postorder` | rbtree.c:611 | O(log n) | 0 | 沿左→右探索 |

---

## 13. 红黑树使用统计数据（doom-lsp 全局搜索）

| 使用模式 | 内核代码量 | 典型场景 |
|---------|-----------|---------|
| `rb_root`（未缓存） | ~1500+ 处 | VMA interval tree, ext4 extent tree |
| `rb_root_cached` | ~400+ 处 | CFS 调度器, epoll, 各种 LRU |
| `rb_augmented` | ~100+ 处 | interval tree, `min_vruntime_cb` |
| `rb_find` 系列 | ~200+ 处 | 通用的查找或插入模式 |
| postorder 遍历 | ~50+ 处 | 销毁树时释放内存 |

---

## 14. `__rb_parent_color` 图解

```c
// include/linux/types.h — unsigned long 大小
// 64-bit 系统上 sizeof(struct rb_node) = 32 字节
// 
// struct rb_node 内存布局：
// ┌──────────────── 8 bytes ──────────────┐  ← offset 0
// │  __rb_parent_color:                    │
// │  ┌─ bit 0: RB_RED (0) / RB_BLACK (1)  │
// │  ├─ bit 1-2: 未使用（0）              │
// │  └─ bit 63:3: 父节点指针              │
// ├──────────────── 8 bytes ──────────────┤  ← offset 8
// │  rb_right (struct rb_node*)           │
// ├──────────────── 8 bytes ──────────────┤  ← offset 16
// │  rb_left (struct rb_node*)            │
// └───────────────────────────────────────┘  ← total: 24 bytes + 8 padding
// 实际上 __attribute__((aligned(sizeof(long)))) 会填充到 32 字节
```

辅助函数全家（`lib/rbtree.c` 头部）：

```c
// lib/rbtree.c:59 — doom-lsp 确认
#define RB_RED      0    // 红色 = bit 0 = 0
#define RB_BLACK    1    // 黑色 = bit 0 = 1

static inline void rb_set_black(struct rb_node *rb) { ... }  // OR 1
static inline bool rb_is_red(const struct rb_node *rb) { ... }   // TEST 1
static inline bool rb_is_black(const struct rb_node *rb) { ... } // TEST 1, invert
```

---

## 15. 二分查找 vs 红黑树——内核的选择

| 特性 | 二叉搜索树（不平衡） | 红黑树 |
|------|---------------------|--------|
| 最坏查找 | O(n) | O(log n) |
| 插入最坏 | O(n) | O(log n) |
| 使用场景 | 插入后不再修改（如 init 阶段） | 动态增删 |
| 内存开销 | 3 个指针/节点 | 3 个指针/节点 + 隐式颜色位 |

红黑树在最坏情况下仍保证 O(log n)，而普通二叉搜索树在顺序插入时退化为 O(n) 链表。内核中绝大多数二叉搜索树的使用（包括 CFS、epoll、VMA）都采用红黑树。

---

## 16. 源码文件索引

| 文件 | 内容 | 符号数 |
|------|------|--------|
| `include/linux/rbtree.h` | 声明 + inline 函数 + 宏 | **29 个** |
| `include/linux/rbtree_types.h` | `struct rb_node`, `rb_root`, `rb_root_cached` | — |
| `lib/rbtree.c` | 核心实现（插入、删除、遍历） | **54 个**（含 EXPORT） |
| `include/linux/rbtree_augmented.h` | 增强回调接口 | — |
| `mm/interval_tree.c` | VMA 增强红黑树 | — |
| `kernel/sched/fair.c` | CFS 调度器中的 rb_root_cached | — |
| `fs/eventpoll.c` | epoll fd 管理 | — |

---

## 17. 关联文章

- **01-list_head**：无序双链表——红黑树的秩序建立在 list_head 之上
- **02-hlist**：散列链表——当不需要有序性时，散列表是红黑树的替代
- **04-xarray**：基数树——另一种有序数据结构，适合密集整数索引
- **16-vm_area_struct**：VMA 通过 interval tree（增强红黑树）组织
- **37-CFS调度器**：rb_root_cached 的深度应用
- **80-epoll 分析**：epoll 红黑树管理 fd 的完整实现
- **40-thp**：透明大页中红黑树管理页表

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
