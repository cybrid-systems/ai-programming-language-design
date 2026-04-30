# rbtree — 内核红黑树深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/rbtree.h` + `include/linux/rbtree_types.h` + `lib/rbtree.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照
> 行号索引：rbtree.h 全文、rbtree.c 全文

---

## 0. 概述

**红黑树（R-B Tree）** 是 Linux 内核最核心的搜索树结构，用于：
- **调度器**：CFS 用红黑树管理 vruntime
- **内存管理**：vm_area_struct 按地址组织
- **文件系统**：dentry 缓存、ext4 inode extent
- **网络**：路由表（fib）、neighbour 表
- **设备驱动**：GPIO 引脚、PCI BAR

**核心保证**：O(log n) 查找/插入/删除，且**不需要额外平衡操作**（不像 AVL 树）。

---

## 1. 红黑树性质

根据 Wikipedia 和内核注释：

```
1) 节点非红即黑
2) 根节点为黑
3) 所有叶子（NIL/NULL）为黑
4) 红节点的两个子节点都为黑（不能有连续红节点）
5) 从根到所有叶子路径上的黑节点数相同（黑高）
```

**O(log n) 证明**：
- 性质 4 限制了红节点不能连续 → 最长路径 ≤ 2 × 最短路径
- 性质 5 保证所有路径黑高相同 → 最短路径 ≥ log₂(n+1)
- 综合：最长路径 ≤ 2 × log₂(n+1) = O(log n)

---

## 2. 核心数据结构

### 2.1 rb_node — 红黑树节点

```c
// include/linux/rbtree_types.h
struct rb_node {
    unsigned long  __rb_parent_color;  // 父指针 + 颜色（合并存储）
    struct rb_node *rb_right;         // 右子树
    struct rb_node *rb_left;          // 左子树
} __attribute__((aligned(sizeof(long))));
    // 对齐到 sizeof(long) — 确保指针低位可用于存颜色
```

**`__rb_parent_color` 编码**：

```
64-bit 系统（8 字节指针）：
  低 2 位存颜色（00=红，01=黑）
  高 62 位存父节点指针（地址对齐到 4 字节，所以最低 2 位肯定为 0）

提取父指针：
  #define rb_parent(r) ((struct rb_node *)((r)->__rb_parent_color & ~3))

提取颜色：
  #define __rb_color(pc) ((pc) & 1)
  #define RB_BLACK 1
  #define RB_RED   0
```

### 2.2 rb_root — 树的根

```c
// include/linux/rbtree_types.h
struct rb_root {
    struct rb_node *rb_node;  // 根节点，NULL 表示空树
};

#define RB_ROOT (struct rb_root) { NULL }
```

### 2.3 rb_root_cached — 缓存最左节点

```c
// include/linux/rbtree_types.h
struct rb_root_cached {
    struct rb_root  rb_root;   // 红黑树根
    struct rb_node *rb_leftmost; // 最左（最小）节点缓存 → O(1) 找最小
};

#define RB_ROOT_CACHED (struct rb_root_cached) { {NULL, }, NULL }
```

**为什么要缓存最左节点？**
- 很多场景要找最小值（如调度器的 vruntime 最小任务）
- `rb_first()` 需要从根一直向左下走，O(log n)
- 缓存 `rb_leftmost` 后，`rb_first_cached()` = O(1)

---

## 3. rb_node 链接操作

### 3.1 rb_link_node — 插入节点（未着色/平衡）

```c
// include/linux/rbtree.h
static inline void rb_link_node(struct rb_node *node, struct rb_node *parent,
                struct rb_node **rb_link)
{
    node->__rb_parent_color = (unsigned long)parent;  // [1] 设置父指针（默认红色）
    node->rb_left = node->rb_right = NULL;           // [2] 左右子设为 NULL

    *rb_link = node;                                   // [3] parent->{left/right} = node
}
```

**参数**：
- `parent`：新节点的父节点
- `rb_link`：指向父节点的左或右指针的地址（即 `&parent->rb_left` 或 `&parent->rb_right`）

### 3.2 rb_link_node_rcu — RCU 版本

```c
// include/linux/rbtree.h
static inline void rb_link_node_rcu(struct rb_node *node, struct rb_node *parent,
                    struct rb_node **rb_link)
{
    node->__rb_parent_color = (unsigned long)parent;
    node->rb_left = node->rb_right = NULL;

    rcu_assign_pointer(*rb_link, node);  // RCU 安全赋值
}
```

---

## 4. 着色操作

### 4.1 颜色相关宏

```c
// lib/rbtree.c
#define __rb_parent(pc)   ((struct rb_node *)(pc & ~3UL))
#define __rb_color(pc)    ((pc) & 1UL)
#define __rb_set_parent_color(rb, parent, color) \
    (((rb)->__rb_parent_color = (unsigned long)(parent) | (color)))

// 着色操作
#define rb_set_parent_color(rb, parent, color) \
    __rb_set_parent_color(rb, parent, color)

#define rb_set_black(rb)  do { (rb)->__rb_parent_color |= RB_BLACK; } while(0)
#define rb_is_red(rb)     (!rb_is_black(rb))
#define rb_is_black(rb)   ((rb)->__rb_parent_color & RB_BLACK)
```

---

## 5. 插入与再平衡（核心算法）

### 5.1 __rb_insert — 插入主循环

```c
// lib/rbtree.c — 完整插入再平衡算法
// 伪代码（配合内核注释）：

__rb_insert(node, root):
    parent = node.__rb_parent_color & ~3  // 父节点
    gparent = parent.__rb_parent_color & ~3  // 祖父节点

    while (true):
        if parent == NULL:
            // Case 1: 插入根节点 → 染黑，完成
            node 染黑
            break

        if parent 是黑色:
            // Case 2: 父节点为黑，插入红节点不违反性质 4
            break

        // 父节点为红（违反性质 4），需要修复
        gparent = rb_red_parent(parent)  // 祖父（必然存在，因为父为红）

        if parent == gparent.rb_left:
            uncle = gparent.rb_right

            if uncle 存在且为红色:
                // Case 1: Uncle 为红
                // → 父、叔染黑，祖父染红
                // → node = gparent，继续向上检查
                continue

            if node == parent.rb_right:
                // Case 2: Node 是右子 → 左旋 parent
                // → 变成 Case 3
                rotate_left(parent)
                swap(node, parent)

            // Case 3: Node 是左子 → 右旋 gparent
            // → 父染黑，祖父染红
            rotate_right(gparent)

        else:  // parent == gparent.rb_right，对称处理
            ...
```

### 5.2 旋转操作详解

**左旋（rotate_left）**：
```
旋转前：                旋转后：
    g                    p
   / \                 / \
  p   U    ←左旋→     n   g
 / \                     / \
n   ?                     ?   U
```

**右旋（rotate_right）**：
```
旋转前：                旋转后：
    g                    p
   / \                 / \
  U   p      ←右旋→   g   n
     / \               / \
    ?   n               U   ?
```

### 5.3 三种情况图解

**Case 1 — Uncle 为红（颜色翻转）**：
```
       [g=B]                [g=R]
      /      \            /      \
  [p=R]      [u=R]  →  [p=B]    [u=B]
     ↓                    ↓
   [n=R]              [n=R]
```
处理后：g 变红，p、u 变黑，node = g（向上继续检查）

**Case 2 — Node 为右子（左旋变 Case 3）**：
```
       [g=B]                [g=B]
      /      \            /      \
  [p=R]      [u=B]  →  [n=R]    [u=B]
       \                    ↑
      [n=R]              变左子
```

**Case 3 — Node 为左子（右旋）**：
```
       [g=B]                [p=B]
      /      \            /      \
  [p=R]      [u=B]  →  [n=R]    [g=R]
     ↓                            ↓
   [n=R]                        [u=B]
```

---

## 6. 删除操作

### 6.1 rb_erase — 删除并再平衡

```c
// lib/rbtree.c
void rb_erase(struct rb_node *node, struct rb_root *root)
{
    struct rb_node *rebalance;
    struct rb_node *child;

    // 1. 处理最多两个子节点的情况
    if (node->rb_left && node->rb_right)
        // 有两个子节点：找后继替换，然后删除后继（最多一个子节点）
        goto two_children;

    child = node->rb_right ?: node->rb_left;  // C 语法：右存在用右，否则用左

    if (child):
        // 替换 node
        __rb_replace(node, child, root)
        rebalance = child
    else:
        rebalance = NULL

two_children:
    // 删除 node，child 替代其位置
    // rebalance 节点可能需要再平衡

    if (rebalance):
        __rb_erase(rebalance, root)
}
```

### 6.2 删除再平衡关键路径

删除红色节点：**不需要再平衡**（不影响黑高）

删除黑色节点：**需要修复**，因为经过它的路径黑高减少 1

---

## 7. 遍历操作

### 7.1 rb_first / rb_last — 最值

```c
// include/linux/rbtree.h
static inline struct rb_node *rb_first(const struct rb_root *root)
{
    struct rb_node *n;

    n = root->rb_node;
    if (!n)
        return NULL;

    while (n->rb_left)   // 一直向左下走
        n = n->rb_left;

    return n;
}
```

### 7.2 rb_next / rb_prev — 中序后继/前驱

```c
// lib/rbtree.c
struct rb_node *rb_next(const struct rb_node *node)
{
    if (node->rb_right) {
        // 有右子树：后继是最右子树的最小（最左）
        node = node->rb_right;
        while (node->rb_left)
            node = node->rb_left;
        return node;
    }

    // 无右子树：向上找第一个"自己是左子"的祖先
    while (node->rb_parent && node == node->rb_parent->rb_right)
        node = node->rb_parent;

    return node->rb_parent;
}
```

### 7.3 rb_first_cached — O(1) 版本

```c
// include/linux/rbtree.h
#define rb_first_cached(root) (root)->rb_leftmost
// 直接返回缓存的最小节点，O(1)
```

---

## 8. 实际内核使用案例

### 8.1 CFS 调度器（vmlinux_tracing_state）

```c
// kernel/sched/fair.c — vruntime 红黑树
struct cfs_rq {
    struct rb_root_cached   tasks_timeline;
    // tasks_timeline.rb_root = 红黑树根
    // tasks_timeline.rb_leftmost = vruntime 最小的任务
};

// 取最左节点（最小 vruntime）
struct sched_entity *se = rb_entry(
    rb_first_cached(&cfs_rq->tasks_timeline),
    struct sched_entity, run_node
);
```

### 8.2 vm_area_struct（虚拟内存区域）

```c
// mm/mmap.c — VMA 红黑树
struct mm_struct {
    struct rb_root  mm_rb;        // VMA 红黑树
    struct vm_area_struct *mmap; // 链表（额外组织）
};

// 查找覆盖 addr 的 VMA
struct vm_area_struct *vma = vma_lookup(mm, addr);
```

### 8.3 ext4 extent 树

```c
// fs/ext4/inode.c — extent 树
struct ext4_extent {
    struct rb_node    rb_node;   // 嵌入到 extent 树
    __u32           ee_block;   // 起始块号（排序 key）
    __u16           ee_len;     // 长度
    __u16           ee_start_hi; // 物理块号高 16 位
    __u32           ee_start_lo; // 物理块号低 32 位
};
```

---

## 9. 设计决策总结

| 决策 | 原因 |
|------|------|
| `__rb_parent_color` 合并存储 | 节省一个指针的存储空间（指针对齐时低位无用）|
| `aligned(sizeof(long))` | 确保指针低位可用于存颜色 |
| `rb_leftmost` 缓存 | 大多数场景需要找最小，O(1) > O(log n) |
| 迭代而非递归 | 内核不能栈溢出，递归插入/删除深度 O(log n) 可接受 |
| 着色标记在 parent_color 低位 | 无需额外字段，指针操作天然原子 |

---

## 10. 完整文件索引

| 文件路径 | 关键行 | 内容 |
|---------|-------|------|
| `include/linux/rbtree_types.h` | 全文 | `rb_node`、`rb_root`、`rb_root_cached` |
| `include/linux/rbtree.h` | `rb_link_node` | 链接节点 |
| `include/linux/rbtree.h` | `rb_first`、`rb_last` | 最值查找 |
| `include/linux/rbtree.h` | `rb_first_cached` | O(1) 最左节点 |
| `lib/rbtree.c` | `__rb_insert` | 插入+再平衡 |
| `lib/rbtree.c` | `rb_erase` | 删除+再平衡 |
| `lib/rbtree.c` | `rb_next`、`rb_prev` | 中序遍历 |
| `lib/rbtree.c` | 注释 | 红黑树 5 性质详解 |
