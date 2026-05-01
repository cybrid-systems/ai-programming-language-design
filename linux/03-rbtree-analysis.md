# 03-rbtree — 红黑树深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**红黑树（Red-Black Tree）** 是 Linux 内核最核心的有序数据结构，用于 CFS 调度器、虚拟内存管理（VMA 区间树）、epoll 等关键路径。与常规的二叉搜索树不同，红黑树通过 5 条不变的着色规则保证树高不超过 `2*log₂(n+1)`，所有操作均为 O(log n)。

Linux 的实现位于 `include/linux/rbtree.h`（函数声明）和 `lib/rbtree.c`（实��）。doom-lsp 确认这两个文件共包含约 30+ 符号，其中核心增删查改操作 20+。

---

## 1. 核心数据结构

### 1.1 struct rb_node（`include/linux/rbtree.h:24`）

```c
struct rb_node {
    unsigned long  __rb_parent_color;  // 父节点指针 + 颜色位
    struct rb_node *rb_right;          // 右孩子
    struct rb_node *rb_left;           // 左孩子
} __attribute__((aligned(sizeof(long))));
```

**关键设计：`__rb_parent_color` 将父节点指针和颜色合并到一个 `unsigned long` 中。**

```
  bit 0    = RB_RED (0) / RB_BLACK (1)    ← 颜色
  bit 1    = 保留（用于缓存行对齐）
  bit 63:2 = 父节点指针（整型地址的倒数第三位）
```

指针对齐后的地址最低 2-3 位总是 0，所以这些位可以被复用。这节省了一个 `unsigned long`，使每个 `rb_node` 从 32 字节降为 24 字节（64 位系统）。

### 1.2 struct rb_root（`include/linux/rbtree.h:34`）

```c
struct rb_root {
    struct rb_node *rb_node;  // 指向根节点，NULL = 空树
};
```

简单包装：仅包含根节点指针。

### 1.3 struct rb_root_cached（`include/linux/rbtree.h:37`）

```c
struct rb_root_cached {
    struct rb_root rb_root;    // 根节点
    struct rb_node *rb_leftmost;  // 最左节点（即最小值）的缓存
};
```

`rb_leftmost` 缓存使 O(1) 取最小值成为可能——这对 CFS 调度器的 `pick_next_entity` 非常关键。

---

## 2. 辅助宏

### 2.1 container_of 与 rb_entry

```c
#define rb_entry(ptr, type, member) container_of(ptr, type, member)
```

与 list_head 相同的套路——从 `rb_node*` 通过偏移量逆向得到父结构。

### 2.2 颜色与父指针的编码/解码

```c
// lib/rbtree.c — 内核实现使用的宏
#define RB_RED       0
#define RB_BLACK     1

// 提取父节点指针（清除颜色位）
#define rb_parent(r)   ((struct rb_node *)((r)->__rb_parent_color & ~3))

// 提取颜色
#define rb_color(r)    ((r)->__rb_parent_color & 1)

// 设置红色
#define rb_set_red(r)  do { (r)->__rb_parent_color &= ~1; } while (0)
```

---

## 3. 核心操作

### 3.1 插入（`lib/rbtree.c`）

插入流程：

```
rb_insert(struct rb_root *root, struct rb_node *node)
  │
  1. 二叉搜索定位
  │    └─ 从 root 开始，比较 key，找到 NULL 位置插入
  │
  2. 插入节点着红色
  │    └─ 红色不改变黑高，只可能违反"不能有连续红节点"规则
  │
  3. 修正（__rb_insert）
  │    └─ 情况 1：叔叔是红色 → 父叔变黑，爷变红，向上递归
  │    └─ 情况 2：叔叔是黑色 + LL/RR → 爷右/左旋 + 变色
  │    └─ 情况 3：叔叔是黑色 + LR/RL → 父左/右旋 → 转情况 2
```

doom-lsp 确认 `lib/rbtree.c` 中 `__rb_insert` 为插入修复的核心实现，约 80 行。

### 3.2 删除（`lib/rbtree.c`）

删除更复杂，因为可能删除的是黑色节点（会破坏"每条路径黑节点数相同"规则）。修复通过 `__rb_erase_color` 实现，涉及双黑色、旋转和颜色调整。

```
rb_erase(node, root)
  │
  1. 找到实际要删除的节点
  │    └─ 被删节点有 2 个子节点 → 用 inorder successor 替换
  │    └─ 被删节点 ≤ 1 个子节点 → 直接删除
  │
  2. 如果删的是黑色节点 → 调整（__rb_erase_color）
  │    └─ 兄弟是红色 → 父旋转变色 → 转其他情况
  │    └─ 兄弟是黑色 + 侄子都是黑色 → 兄弟变红，向上递归
  │    └─ 兄弟是黑色 + 远侄子红色 → 父旋转变色
  │    └─ 兄弟是黑色 + 近侄子红色 → 兄弟旋转变色 → 转上一情况
```

### 3.3 查找（`lib/rbtree.c`）

```c
struct rb_node *rb_find(struct rb_root *root, const void *key,
                        bool (*cmp)(const void *key, const struct rb_node *))
```

传入自定义比较函数，标准的二叉搜索树查找。若使用 `rb_root_cached`，最小值可通过 `root->rb_leftmost` 直接获取。

---

## 4. 增强 API

### 4.1 Augmented rbtree

`include/linux/rbtree_augmented.h` 定义了带"增强信息"的红黑树。节点存储子树聚合信息（如区间最大值），用于高效查询：

```c
struct rb_augment_callbacks {
    void (*propagate)(struct rb_node *node, struct rb_node *stop);
    void (*copy)(struct rb_node *old, struct rb_node *new);
    void (*rotate)(struct rb_node *old, struct rb_node *new);
};
```

典型应用：VMA 区间树在 `subtree_last` 存储子树的最大结束地址，实现 `vma_interval_tree` 和 `mm/filemap.c` 的区域查找。

---

## 5. 内核中的使用案例

| 子系统 | 用途 | 结构 |
|--------|------|------|
| CFS 调度器 | `task_struct` → `vruntime` 排序 | `rb_root_cached` |
| VMA | 进程虚拟地址区间管理 | 增强红黑树 |
| epoll | 监听 fd 的红黑树组织 | `rb_root` |
| timer | `timerfd` 超时管理 | `rb_root` |
| ext4 | 磁盘块映射 | 区间树 |

---

## 6. 数据类型流

```
rb_node (24 bytes)
  ├─ __rb_parent_color ─── 父指针 + 颜色 (bit 0)
  ├─ rb_right ───────────── 右子树
  └─ rb_left ────────────── 左子树

rb_root (8 bytes)
  └─ rb_node ────────────── 根节点指针

rb_augment_callbacks      增强操作回调
  ├─ propagate ──────────── 向上更新增强信息
  ├─ copy ───────────────── 赋值增强信息
  └─ rotate ─────────────── 旋转时更新增强信息
```

---

## 7. 设计决策总结

| 决策 | 原因 |
|------|------|
| 颜色位嵌入父指针 | 节省空间，每节点省 8 字节 |
| `rb_root_cached` 带 leftmost | O(1) 取最小值，调度器关键优化 |
| 增强 API | 支持区间树等高级查询 |
| 非递归实现 | 内核栈空间有限 |
| `void*` 键值 | 通用性，比较函数由调用者提供 |

---

## 8. 源码文件索引

| 文件 | 功能 | 符号数 |
|------|------|--------|
| `include/linux/rbtree.h` | 数据结构定义 + 内联函数 | ~30 |
| `include/linux/rbtree_augmented.h` | 增强 API | ~16 |
| `lib/rbtree.c` | 插入/删除/查找实现 | ~20 fn |

---

## 9. 关联文章

- **MM**（article 16-17）：VMA 使用增强红黑树，page allocator 使用 rb_tree_cached
- **CFS 调度器**（article 37）：使用 rb_root_cached 组织运行队列
- **AVL 树参考**：红黑树 vs AVL 的平衡策略对比

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
