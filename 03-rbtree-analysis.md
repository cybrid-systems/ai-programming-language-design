# Linux Kernel rbtree 红黑树 — 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`lib/rbtree.c` + `include/linux/rbtree.h` + `include/linux/rbtree_augmented.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 更新：整合 2026-04-16 学习笔记

---

## 0. 为什么需要红黑树？

**链表的问题**：O(n) 查找，有序场景下退化成线性扫描。

**红黑树的核心价值**：O(log n) 插入/删除/查找，同时保证**近似平衡**（最多 2 倍路径长度），无需像 AVL 树那样频繁旋转。

**内核使用量**（Linux 7.0 源码）：
```
grep -rn "rb_insert_color\|rb_erase" --include="*.c" | wc -l  →  698 处
```

---

## 1. 核心数据结构

### 1.1 `rb_node` — 节点（含颜色压缩）

```c
// include/linux/rbtree_types.h
struct rb_node {
    unsigned long  __rb_parent_color;  // 低 1 位存颜色，其余位存 parent 指针
    struct rb_node *rb_right;          // 右子树
    struct rb_node *rb_left;           // 左子树
} __attribute__((aligned(sizeof(long))));  // 按 long 对齐，保证指针低位可用
```

**颜色压缩设计**（`include/linux/rbtree_augmented.h:171-182`）：

```c
#define RB_RED       0
#define RB_BLACK     1

// 从 __rb_parent_color 中提取 parent 指针（清除低 2 位）
#define __rb_parent(pc)    ((struct rb_node *)(pc & ~3))

// 从 __rb_parent_color 中提取颜色（取最低 1 位）
#define __rb_color(pc)     ((pc) & 1)

// parent 指针和颜色共用了同一个存储空间：
//  parent 地址必然是 4 或 8 字节对齐 → 二进制最后 2 位为 00
//  低 1 位存颜色 → color 要么是 RB_RED(0) 要么是 RB_BLACK(1)
//  存储时：(__rb_parent_color) = parent_address + color
//  提取时：parent = __rb_parent_color & ~3，color = __rb_parent_color & 1
```

**为什么 `aligned(sizeof(long))`**：在 64 位系统上 `sizeof(long) = 8`，`rb_node` 按 8 字节对齐后，其地址最低 3 位必为 0，所以可以用其中 1 位存颜色而不损失地址空间。

### 1.2 `rb_root` — 树根

```c
// include/linux/rbtree_types.h
struct rb_root {
    struct rb_node *rb_node;  // 指向根节点，空树为 NULL
};

#define RB_ROOT (struct rb_root) { NULL, }  // 空树常量
```

### 1.3 `rb_root_cached` — 带最左节点缓存

```c
// include/linux/rbtree_types.h
struct rb_root_cached {
    struct rb_root rb_root;
    struct rb_node *rb_leftmost;  // 缓存树中最左（最小）节点 → O(1) 找最小
};

#define RB_ROOT_CACHED (struct rb_root_cached) { {NULL, }, NULL }
```

---

## 2. 红黑树的 5 大性质

```c
// lib/rbtree.c — 注释原文
/*
 * red-black trees properties:
 *
 *  1) A node is either red or black
 *  2) The root is black
 *  3) All leaves (NULL) are black
 *  4) Both children of every red node are black  // 不允许两个红节点连续
 *  5) Every simple path from root to leaves contains the same number
 *     of black nodes.                            // 每条路径黑高相同
 */
```

**性质 4 + 5 → O(log n) 保证**：

```
从根到任一叶的路径长度 ≤ 2 × 其他路径长度

设黑高 = B（每条路径的黑节点数相同）
最短路径：全黑 → 长度 ≤ B
最长路径：黑-红-黑-红-... → 长度 ≤ 2B

因此最长路径 = O(log n)，查找再差也是 2×最优
```

---

## 3. 内存布局图

```
红黑树节点布局：

struct rb_node {
    unsigned long  __rb_parent_color;  // parent_pointer + color_bit
    struct rb_node *rb_right;          // 右子树
    struct rb_node *rb_left;           // 左子树
}

示例树（key: 8 根黑、11 红、6 黑、13 红）：

              8(B)                         颜色 = (__rb_parent_color & 1)
             /    \                        parent = __rb_parent_color & ~3
           6(B)    13(R)
                  /   \
               11(R)   15(B)

__rb_parent_color 存储示例（假设 8 的地址 = 0x1000）：
  8.__rb_parent_color = 0x1000 + 1 = 0x1001  (地址 + RB_BLACK)
  验证：parent = 0x1001 & ~3 = 0x1000 ✓
        color  = 0x1001 & 1 = 1 = RB_BLACK ✓
```

---

## 4. 旋转操作（图解）

旋转是红黑树保持平衡的核心操作，不改变中序遍历顺序，只改变树的形状。

### 4.1 左旋（以 P 为轴心）

```
左旋 (rotate left at P)：

      P                    R
     / \                  / \
    PL  R      →        P   RR
       / \             / \
      RL  RR          PL  RL

步骤（P 的右子 R 变成 P 的父）：
1. R 的左子 RL 变成 P 的右子
2. P 变成 R 的左子
3. R 变成新的子树根
```

### 4.2 右旋（以 P 为轴心）

```
右旋 (rotate right at P)：

      P                    L
     / \                  / \
    L   PR      →       LL   P
   / \                       / \
  LL  LR                   LR  PR

步骤（P 的左子 L 变成 P 的父）：
1. L 的右子 LR 变成 P 的左子
2. P 变成 L 的右子
3. L 变成新的子树根
```

---

## 5. 插入操作（`__rb_insert`）

### 5.1 标准二叉搜索树插入

```c
// include/linux/rbtree.h:92 — 将 node 链接到树中（不含平衡）
static inline void rb_link_node(struct rb_node *node,
                                struct rb_node *parent,
                                struct rb_node **rb_link)
{
    node->__rb_parent_color = (unsigned long)parent;  // 只存 parent，颜色=0（红）
    node->rb_left = node->rb_right = NULL;
    *rb_link = node;  // parent->left/right = node
}
```

新插入节点**默认红色**，然后调用 `rb_insert_color()` 做平衡修复。

### 5.2 平衡修复（3 种情况）

**Case 1：叔叔节点是红色**

```
插入 n（红），父 p（红），叔 u（红）→ 颜色翻转

  G(B)                  G(R)
 /    \                /    \
p(R)   u(R)    →     p(B)   u(B)
 |
n(R)

修复：p 和 u 变黑，G 变红（如果 G 是根则保持黑）
递归：node = G（可能违反情况 4，继续向上修复）
```

**Case 2：叔叔节点是黑色 + node 是右子（左旋 parent）**

```
      G(B)                   G(B)
     /    \                /    \
   p(R)    u(B)    →    n(R)    u(B)
     \                  /
      n(R)            p(R)

修复：左旋 parent → 变成 Case 3
```

**Case 3：叔叔节点是黑色 + node 是左子（右旋 G）**

```
      G(B)                   p(B)
     /    \                /    \
   p(R)    u(B)    →    n(R)    G(R)
   /                            /  \
 n(R)                          u(B)  u(B)

修复：右旋 G，颜色交换（p 变黑，G 变红）
完成！不需要继续向上递归
```

---

## 6. 删除操作（`____rb_erase_color`）

删除比插入复杂，因为需要处理**双重黑**（black height 不平衡）问题。

**核心思路**：通过旋转和颜色调整，把双重黑向上推，直到根节点或可以消除。

### 6.1 删除节点的 3 种情况

```
1. 被删节点无子节点 → 直接删除，调整父节点
2. 被删节点只有一棵子树 → 用子树节点替换被删节点
3. 被删节点有两棵子树 → 找后继节点（rb_next）替换，然后转情况 1 或 2
```

### 6.2 双黑修复（4 种情况）

```
设被删节点的兄弟节点 = S，父节点 = P

Case 1：S 是红色 → 左/右旋 P，S 变黑，P 变红 → 变成 Case 2/3/4

Case 2：S 是黑色，两个子节点都是黑色
  → S 变红，P 变黑（或双重黑上传）

Case 3：S 是黑色，兄的远端子是红色，近端子是黑色
  → 旋转 S → 变成 Case 4

Case 4：S 是黑色，兄的远端子是红色
  → 旋转 P，远端红变黑，完成！树已平衡
```

---

## 7. 遍历操作

### 7.1 最小 / 最大

```c
// include/linux/rbtree.h:55 — 最左节点（最小 key）
static inline struct rb_node *rb_first(const struct rb_root *root)
{
    struct rb_node *n;
    n = root->rb_node;
    if (!n) return NULL;
    while (n->rb_left)
        n = n->rb_left;
    return n;
}

// 最右节点（最大 key）
static inline struct rb_node *rb_last(const struct rb_root *root)
{
    struct rb_node *n;
    n = root->rb_node;
    if (!n) return NULL;
    while (n->rb_right)
        n = n->rb_right;
    return n;
}
```

### 7.2 后继 / 前驱

```c
// lib/rbtree.c:480 — rb_next
extern struct rb_node *rb_next(const struct rb_node *);
extern struct rb_node *rb_prev(const struct rb_node *);
```

`rb_next`：右子树不为空 → 右子树最左；否则向上找到第一个它是左子的祖先。

---

## 8. 增强版红黑树：`rb_root_cached` + `rb_root_augmented`

### 8.1 `rb_root_cached` — 最左节点缓存

```c
// 适用场景：频繁 rb_first()（找最小）操作
struct rb_root_cached {
    struct rb_root rb_root;
    struct rb_node *rb_leftmost;  // O(1) 获取最小节点
};
```

### 8.2 `rb_augment_callbacks` — 旋转时维护额外数据

```c
// include/linux/rbtree_augmented.h
struct rb_augment_callbacks {
    void (*propagate)(struct rb_node *node, struct rb_node *stop);  // 向上传播更新
    void (*copy)(struct rb_node *old, struct rb_node *new);          // 节点替换时复制
    void (*rotate)(struct rb_node *old, struct rb_node *new);       // 旋转后更新
};
```

**为什么需要 augment**：
- CFS 调度器需要维护 `min_vruntime`
- 旋转后子树的 `min_vruntime` 可能变化
- augment 回调在每次旋转后自动更新这些派生数据

---

## 9. 真实内核使用案例

### 9.1 CFS 调度器（`kernel/sched/fair.c`）

```c
// include/linux/sched.h:575 — 调度实体
struct sched_entity {
    struct load_weight      load;
    struct rb_node           run_node;    // 接入 CFS 红黑树
    u64                      deadline;
    u64                      min_vruntime;
    u64                      vruntime;    // 虚拟运行时间，红黑树的 key
    ...
};

// CFS 调度队列（关键结构）
struct cfs_rq {
    struct rb_root_cached    tasks_timeline;  // 按 vruntime 有序的红黑树
    // 树最左节点 = 当前运行实体（最小 vruntime）
};

// 取最小 vruntime 的实体（O(1)）
static inline struct sched_entity *__pick_first_entity(struct cfs_rq *cfs_rq)
{
    return rb_entry_safe(cfs_rq->tasks_timeline.rb_leftmost,
                          struct sched_entity, run_node);
}

// 实体插入时用 vruntime 作为 key
// 内核保证 vruntim 越小越先调度 → 完全公平调度
```

**CFS 红黑树工作原理**：
- key = `vruntime`
- 每次调度选最左节点（最小 vruntime）
- 被调度后 vruntime 增加，重新插入树
- 完全公平：通过 vruntime 增长速率实现

### 9.2 虚拟内存区域（`mm/mmap.c`）

```c
// include/linux/mm_types.h:705 — VMA 节点
struct vm_area_struct {
    struct rb_node       vm_rb;     // 按 start addr 有序的红黑树
    unsigned long        vm_start;
    unsigned long        vm_end;
    struct anon_vma_name *anon_name;
    ...
};

// 全局 VMA 树
struct mm_struct {
    struct rb_root       mm_mt;     // 所有 VMA 按地址有序
    ...
};

// 查找包含 addr 的 VMA：O(log n) 红黑树查找
// 合并相邻 VMA：利用树的中序遍历性质
```

### 9.3 hrtimer 高精度定时器

```c
// kernel/time/hrtimer.c
struct hrtimer {
    struct rb_node          node;   // 按到期时间有序
    ktime_t                expires; // 到期时间（key）
    ...
};
```

---

## 10. 算法复杂度分析

| 操作 | 时间复杂度 | 说明 |
|------|----------|------|
| `rb_link_node` | O(1) | 直接链接，无平衡 |
| `rb_insert_color` | O(log n) | 最多 3 次旋转 |
| `rb_erase` | O(log n) | 最多 3 次旋转 |
| `rb_first` | O(1)（缓存）/ O(log n) | `rb_root_cached` 时 O(1) |
| `rb_next` / `rb_prev` | O(log n) | 树高 |
| 查找 | O(log n) | 二叉搜索 |
| `rb_root_cached` 维护 | O(1) | 插入/删除时更新最左缓存 |

---

## 11. vs 其他数据结构

| 特性 | 链表 | 跳转表 | 哈希表 | **红黑树** |
|------|------|--------|--------|-----------|
| 查找 | O(n) | O(log n) | O(1) 均摊 | **O(log n)** |
| 有序遍历 | ✅ | ✅ | ❌ | **✅** |
| 范围查询 | O(n) | O(log n) | ❌ | **O(log n + k)** |
| 插入/删除 | O(1) | O(log n) | O(1) | **O(log n)** |
| 内存开销 | 最低 | 高 | 高 | **中等（3 指针+颜色）** |
| 典型场景 | 短列表 | 替代树 | 字典 | **有序映射、CFS、vma** |

---

## 12. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| `__rb_parent_color` 合并存储 | 省 8 字节（一个指针的宽度），内核极度内存敏感 |
| `aligned(sizeof(long))` | 确保指针低 2 位为 0，可用 1 位存颜色 |
| 增强版回调 `rb_augment` | 旋转后自动维护派生数据（如 min_vruntime），用户无感知 |
| `rb_root_cached` 最左缓存 | CFS 等高频取最小场景，O(1) 而非 O(log n) |
| 空树 = `rb_node = NULL` | 不需要哨兵节点 |

---

## 13. 参考

| 文件 | 内容 |
|------|------|
| `lib/rbtree.c` | 旋转、插入、删除完整实现（~300 行） |
| `include/linux/rbtree.h` | 头文件宏、遍历函数 |
| `include/linux/rbtree_types.h` | `rb_node` / `rb_root` / `rb_root_cached` 定义 |
| `include/linux/rbtree_augmented.h` | 增强版红黑树（旋转回调） |
| `include/linux/sched.h:575` | `sched_entity`（CFS 使用） |
| `include/linux/mm_types.h:705` | `vm_area_struct`（vma 使用） |
| `kernel/sched/fair.c` | CFS 红黑树具体使用（`tasks_timeline`） |

---

## 附录：doom-lsp 分析记录

```
lib/rbtree.c — 54 symbols：
  rb_set_black, rb_red_parent, __rb_rotate_set_parents
  __rb_insert @ 84
  ____rb_erase_color @ 226
  rb_insert_color @ 434, rb_erase @ 440
  rb_next @ 480, rb_prev @ 539
  rb_replace_node @ 541, rb_replace_node_rcu @ 558
  rb_left_deepest_node @ 580

include/linux/rbtree.h — 29 symbols：
  rb_insert_color @ 44, rb_erase @ 45
  rb_next @ 49, rb_prev @ 50
  rb_first @ 55, rb_last @ 70
  rb_link_node @ 92
  rb_add_cached @ 197, rb_erase_cached @ 151
  rb_find_add_cached @ 313, rb_find @ 419
```
