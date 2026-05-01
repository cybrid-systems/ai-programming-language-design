# 01-list_head — 双向链表深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**list_head** 是 Linux 内核使用最广泛的数据结构，没有之一。它是一个**双向循环链表**，所有节点通过内嵌 `struct list_head` 的方式被组织起来。链表操作通过 `container_of` 宏从链表节点逆向推导出父结构体——这是内核中"通用数据结构"设计的典范。

内核中的 list_head 代码量不大（`include/linux/list.h` 约 750 行，包含 50+ 个内联函数），但设计极其精巧：所有插入、删除、替换、拼接操作都是 **O(1)** 的，且通过 `LIST_POISON` 和 `READ_ONCE/WRITE_ONCE` 保证调试和并发安全性。

---

## 1. 核心数据结构

### 1.1 struct list_head（`include/linux/list.h:23`）

```c
struct list_head {
    struct list_head *next;     // 指向下一个节点
    struct list_head *prev;     // 指向上一个节点
};
```

就这么简单——只有 `next` 和 `prev` 两个指针。它的巧劲在于使用方式：

```c
// 空链表：指向自己
#define LIST_HEAD_INIT(name) { &(name), &(name) }

// 用户数据结构内嵌
struct task_struct {
    // ... 很多字段 ...
    struct list_head tasks;   // 指向 prev/next task
    struct list_head children; // 子进程链表
    // ...
};

// 通过 container_of 从 list_head 找到父结构
#define list_entry(ptr, type, member) \
    container_of(ptr, type, member)
```

`container_of` 利用编译器在结构体中成员偏移量固定的特性，通过 `list_head*` 的地址减去 `member` 在 `type` 中的偏移量，得到父结构的地址。这是内核最基础也最精妙的技巧。

---

## 2. 数据流：插入与删除

### 2.1 list_add（`include/linux/list.h:175`）

```c
static inline void list_add(struct list_head *new, struct list_head *head)
{
    __list_add(new, head, head->next);
}
```

doom-lsp 追踪的调用链：

```
list_add @ 175
  └─ __list_add @ 154        （核心实现）
       ├─ new->prev = prev
       ├─ new->next = next
       ├─── WRITE_ONCE(prev->next, new)  ← 关键：内存序保证
       └─── next->prev = new
```

`list_add_tail` 则是 `__list_add(new, head->prev, head)`——插在 head 之前，即链表尾部。

### 2.2 list_del（`include/linux/list.h:235`）

```c
static inline void list_del(struct list_head *entry)
{
    __list_del(entry->prev, entry->next);
    entry->next = LIST_POISON1;  // 毒化指针，便于调试
    entry->prev = LIST_POISON2;
}
```

删除后将指针设为 `LIST_POISON`（已删除的特殊地址），这样后续误操作该节点会导致页错误，方便调试。安全遍历接口 `list_for_each_safe` 通过 `n = pos->next` 预存下一个节点来处理并发删除。

---

## 3. 遍历宏

### 3.1 基本遍历

```c
// include/linux/list.h:311
#define list_for_each(pos, head) \
    for (pos = (head)->next; pos != (head); pos = pos->next)

// 直接遍历数据节点（最常用）
// include/linux/list.h:328
#define list_for_each_entry(pos, head, member)                    \
    for (pos = list_entry((head)->next, typeof(*pos), member);     \
         &pos->member != (head);                                  \
         pos = list_entry(pos->member.next, typeof(*pos), member))
```

### 3.2 RCU 安全遍历

```c
// include/linux/rculist.h:38
#define list_for_each_entry_rcu(pos, head, member)                \
    for (pos = list_entry_rcu((head)->next, typeof(*pos), member); \
         &pos->member != (head);                                  \
         pos = list_entry_rcu(pos->member.next, typeof(*pos), member))
```

RCU 版本使用 `rcu_dereference()` 读取指针，保证在遍历过程中对指针的读取不会被编译器和 CPU 重排。

### 3.3 完整遍历宏族

doom-lsp 确认 `list.h` 中包含以下遍历宏：

| 宏 | 行 | 用途 |
|----|-----|------|
| `list_for_each` | 311 | 基本正向遍历 |
| `list_for_each_continue` | ~336 | 从指定位置继续 |
| `list_for_each_safe` | 317 | 安全遍历（可删除）|
| `list_for_each_entry` | 328 | 正向遍历数据节点 |
| `list_for_each_entry_reverse` | 346 | 反向遍历 |
| `list_for_each_entry_safe` | 364 | 安全遍历数据节点 |
| `list_for_each_entry_continue` | ~391 | 继续遍历 |
| `list_for_each_entry_from` | ~408 | 从指定节点开始 |
| `list_for_each_entry_rcu` | rculist.h | RCU 安全遍历 |

---

## 4. 拼接与裁剪

### 4.1 list_splice（`include/linux/list.h:550`）

```c
static inline void list_splice(struct list_head *list, struct list_head *head)
{
    if (!list_empty(list))
        __list_splice(list, head, head->next);
}
```

内核开发中常用的模式：先批量收集多个元素到临时链表（O(n)），再整体拼接到目标链表中（O(1)），而不是一个一个插入（O(n)）。`list_splice` 的核心 `__list_splice` 只操作 4 个指针，无论拼接多少个元素都是常数时间。

---

## 5. 完整操作 API

doom-lsp 确认 `include/linux/list.h` 中的全部操作函数：

| 操作 | 函数 | 行 | 复杂度 |
|------|------|-----|--------|
| 初始化 | `INIT_LIST_HEAD` | 43 | O(1) |
| 插入头部 | `list_add` | 175 | O(1) |
| 插入尾部 | `list_add_tail` | 189 | O(1) |
| 删除 | `list_del` | 235 | O(1) |
| 删除并初始化 | `list_del_init` | 293 | O(1) |
| 替换 | `list_replace` | 249 | O(1) |
| 移动到头部 | `list_move` | 304 | O(1) |
| 移动到尾部 | `list_move_tail` | 315 | O(1) |
| 批量移动 | `list_bulk_move_tail` | 331 | O(n) |
| 拼接 | `list_splice` | 550 | O(1) |
| 拼接+初始化 | `list_splice_init` | 576 | O(1) |
| 裁剪 | `list_cut_position` | 488 | O(n) |
| 旋转 | `list_rotate_left` | 425 | O(1) |
| 统计 | `list_count_nodes` | 755 | O(n) |
| 判空 | `list_empty` | 379 | O(1) |
| 判空（careful） | `list_empty_careful` | 415 | O(1) |
| 判单节点 | `list_is_singular` | 457 | O(1) |
| 判头 | `list_is_head` | 370 | O(1) |

---

## 6. 数据类型流

```
list_head 的使用模式：

struct parent {              每个父结构内嵌 list_head
    int data;
    struct list_head node;   ← 链表节点
};

LIST_HEAD(head);             初始化头节点（指向自己）

list_add(&obj.node, &head);   添加 —— O(1)
list_del(&obj.node);          删除 —— O(1)

list_for_each_entry(pos, &head, node) {  遍历 —— O(n)
    // pos 自动类型转换为 struct parent*
    // 内部通过 container_of(list_head*, parent, node) 完成
}
```

---

## 7. 核心设计原则

| 原则 | 体现 |
|------|------|
| **循环哨兵** | 头节点 head 既是起点也是终点，`head->next == head && head->prev == head` 表示空链表 |
| **container_of** | 链表不感知数据类型，用户需要时自行转换 |
| **内联化** | 所有操作都是 `static inline` 函数，没有调用开销 |
| **毒化指针** | 删除后将指针设为 `LIST_POISON1/2`，便于调试 |
| **PER CPU** | 每个 CPU 有自己独立的 list_head，避免锁竞争 |

---

## 8. 源码文件索引

| 文件 | 关键行号范围 | 说明 |
|------|------------|------|
| `include/linux/list.h` | 23-755 | 核心链表操作 API |
| `include/linux/rculist.h` | 38 | RCU 安全遍历变体 |
| `include/linux/poison.h` | — | LIST_POISON 定义 |

---

## 9. 关联文章

- **hlist**（article 02）：适用于 hash 表的单向链表变体
- **RCU**（article 26）：list_for_each_entry_rcu 的并发机制
- **container_of**：所有链表逆向推导父结构的数学基础

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
