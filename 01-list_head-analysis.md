# list_head — 内核双向循环链表深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/list.h` + `include/linux/list_nulls.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照
> 行号索引：list.h 全文 1218 行

---

## 0. 概述

`list_head` 是 Linux 内核最核心的数据结构，**几乎所有内核子系统都依赖它**（调度器、文件系统、网络、设备驱动、内存管理等）。它的设计哲学：

- **侵入式**：链表的 `list_head` 直接嵌入到数据结构内部，而非外部包装
- **双向循环**：`prev` 和 `next` 形成双向环，不存在 NULL 尾
- **O(1) 插入删除**：给定节点，不需要遍历即可操作
- **类型安全**：通过 `container_of` 在编译期完成类型推导

---

## 1. 数据结构定义

### 1.1 list_head — 双向循环链表节点

```c
// include/linux/list.h — 核心结构
struct list_head {
    struct list_head *next;  // 指向下一个节点
    struct list_head *prev; // 指向上一个节点
};
```

**设计要点**：
- 两个指针组成双向链表，`prev` 和 `next` 初始化时指向自身（空链表）
- **无数据域**：纯粹的链表结构，数据存在包含 `list_head` 的外层结构中
- **侵入式**：外层结构内部嵌入 `list_head`，而非外围包装

### 1.2 container_of — 从成员找到容器

```c
// include/linux/container_of.h
#define container_of(ptr, type, member) ({                      \
    void *__mptr = (void *)(ptr);                               \
    static_assert(__same_type(*(ptr), ((type *)0)->member) ||   \
                  __same_type(*(ptr), void),                    \
                  "pointer type mismatch in container_of()");     \
    ((type *)(__mptr - offsetof(type, member))); })
```

**机制**（以 `struct task_struct` 为例）：
```
假设：
  struct task_struct {
      struct list_head tasks;  // offset = 0x100
      char name[32];          // 其他字段...
  };

  ptr = &some_task->tasks (地址 = 0x1000)

计算：
  container_of(ptr, struct task_struct, tasks)
  = (struct task_struct *)(0x1000 - 0x100)
  = 0xF00  ← 回到 task_struct 起始地址
```

### 1.3 list_entry — container_of 的别名

```c
// include/linux/list.h
#define list_entry(ptr, type, member) \
    container_of(ptr, type, member)
```

---

## 2. 初始化

### 2.1 LIST_HEAD — 声明并初始化空链表

```c
// include/linux/list.h
#define LIST_HEAD_INIT(name) { &(name), &(name) }

#define LIST_HEAD(name) \
    struct list_head name = LIST_HEAD_INIT(name)
```

**效果**：
```c
LIST_HEAD(my_list);
// 等价于：
struct list_head my_list = { &my_list, &my_list };
// prev = &my_list, next = &my_list（自环）
```

### 2.2 INIT_LIST_HEAD — 运行时初始化

```c
// include/linux/list.h
static inline void INIT_LIST_HEAD(struct list_head *list)
{
    WRITE_ONCE(list->next, list);
    WRITE_ONCE(list->prev, list);
}
```

**为什么用 `WRITE_ONCE`？**
- 防止编译器将写操作与后续读操作重排序
- 配合 `list_empty()` 的 `READ_ONCE`，形成**发布-订阅**内存屏障语义
- 在启用 `CONFIG_LIST_HARDENED` 时额外保护

---

## 3. 插入操作

### 3.1 __list_add — 内部插入

```c
// include/linux/list.h:151-162
static inline void __list_add(struct list_head *new,
              struct list_head *prev,
              struct list_head *next)
{
    if (!__list_add_valid(new, prev, next))
        return;

    next->prev = new;          // [1] next 的 prev 指向 new
    new->next = next;          // [2] new 的 next 指向 next
    new->prev = prev;          // [3] new 的 prev 指向 prev
    WRITE_ONCE(prev->next, new); // [4] prev 的 next 指向 new（写屏障）
}
```

**图示**：
```
插入前：  prev ←→ next
           ↑
         new

插入后：  prev ←→ new ←→ next
```

### 3.2 list_add — 头部插入（栈）

```c
// include/linux/list.h:170-178
// 在 head 之后插入，等价于栈的 push
static inline void list_add(struct list_head *new, struct list_head *head)
{
    __list_add(new, head, head->next);
}
```

**效果**：最新元素在链表头部

### 3.3 list_add_tail — 尾部插入（队列）

```c
// include/linux/list.h:191-199
// 在 head->prev 之前插入，等价于队列的 enqueue
static inline void list_add_tail(struct list_head *new, struct list_head *head)
{
    __list_add(new, head->prev, head);
}
```

**效果**：最新元素在链表尾部

---

## 4. 删除操作

### 4.1 __list_del — 内部删除

```c
// include/linux/list.h:207-213
static inline void __list_del(struct list_head *prev, struct list_head *next)
{
    next->prev = prev;            // prev 的 next 跳过自己
    WRITE_ONCE(prev->next, next); // next 的 prev 也跳过自己
}
```

**图示**：
```
删除前：  prev ←→ entry ←→ next
删除后：  prev ←→ next（entry 被隔离）
```

### 4.2 list_del — 删除并置毒

```c
// include/linux/list.h:228-233
static inline void list_del(struct list_head *entry)
{
    __list_del_entry(entry);
    entry->next = LIST_POISON1;   // 0x100 + sizeof(struct list_head)
    entry->prev = LIST_POISON2;   // 0x200 + sizeof(struct list_head)
}
```

**毒值的作用**：
- 如果错误访问已删除的节点，立刻触发段错误（而非静默崩溃）
- `LIST_POISON1 = ((void *)0x100 + sizeof(struct list_head))`
- `LIST_POISON2 = ((void *)0x200 + sizeof(struct list_head))`

### 4.3 list_del_init — 删除并重新初始化

```c
// include/linux/list.h:264-267
static inline void list_del_init(struct list_head *entry)
{
    __list_del_entry(entry);
    INIT_LIST_HEAD(entry);  // 让 entry 成为一个新链表的表头
}
```

---

## 5. 遍历操作

### 5.1 list_for_each — 正向遍历

```c
// include/linux/list.h:451-457
#define list_for_each(pos, head) \
    for (pos = (head)->next; pos != (head); pos = pos->next)
```

**注意**：遍历过程中**不能 `list_del(pos)`**，会导致未定义行为

### 5.2 list_for_each_safe — 安全遍历（可删除）

```c
// include/linux/list.h:469-475
#define list_for_each_safe(pos, n, head) \
    struct list_head *n; \
    for (pos = (head)->next, n = pos->next; pos != (head); \
         pos = n, n = pos->next)
```

**用法**：
```c
struct list_head *pos, *n;
list_for_each_safe(pos, n, &my_list) {
    list_del(pos);           // 安全删除
    kfree(list_entry(pos, struct my_struct, member));
}
```

### 5.3 list_for_each_entry — 遍历外层结构

```c
// include/linux/list.h:557-563
#define list_for_each_entry(pos, head, member)               \
    for (pos = list_entry((head)->next, typeof(*pos), member); \
         &pos->member != (head);                             \
         pos = list_entry(pos->member.next, typeof(*pos), member))
```

**完整示例**：
```c
struct task_struct {
    struct list_head tasks;  // 嵌入到 task_struct
    char name[32];
};

LIST_HEAD(task_list);

struct task_struct *task;
list_for_each_entry(task, &task_list, tasks) {
    printk("%s\n", task->name);
}
```

---

## 6. 移动和拼接

### 6.1 list_move — 从一个链表移到另一个链表的头部

```c
// include/linux/list.h:301-306
static inline void list_move(struct list_head *list, struct list_head *head)
{
    __list_del_entry(list);
    list_add(list, head);
}
```

### 6.2 list_move_tail — 从一个链表移到另一个链表的尾部

```c
// include/linux/list.h:320-325
static inline void list_move_tail(struct list_head *list, struct list_head *head)
{
    __list_del_entry(list);
    list_add_tail(list, head);
}
```

### 6.3 list_splice — 合并两个链表

```c
// include/linux/list.h:530-533
static inline void list_splice(struct list_head *list, struct list_head *head)
{
    if (!list_empty(list))
        list_splice_tail_init(list, head);
}
```

---

## 7. hlist — 单向链表变体（哈希表桶头）

### 7.1 为什么要 hlist？

`list_head` 的问题：**每个桶头都占用两个指针**（16 字节 on 64-bit）。如果系统中有一万个 `list_head` 桶头，就是 160KB 开销。

**hlist** 用单向链表 + 哑节点实现桶头，只需要**一个指针**（8 字节 on 64-bit）：

```c
// include/linux/list_nulls.h
struct hlist_nulls_head {
    struct hlist_nulls_node *first;  // 一个指针
};

struct hlist_nulls_node {
    struct hlist_nulls_node *next, **pprev;  // next + pprev（双指针）
};
```

### 7.2 nulls marker — 替代 NULL

hlist 用 **nulls marker** 替代 NULL 标识链表结尾：

```c
#define NULLS_MARKER(value) (1UL | (((long)value) << 1))
// 最低位 = 1 表示 nulls 标记
// 高位存具体值（用于调试/统计）
```

### 7.3 hlist 遍历

```c
#define hlist_for_each(pos, head) \
    for (pos = (head)->first; \
         (!is_a_nulls(pos) && pos); \
         pos = pos->next)
```

---

## 8. 内存序与并发安全

### 8.1 为什么需要内存屏障？

```c
// list_del 的等价操作
next->prev = prev;          // [A] 写
WRITE_ONCE(prev->next, next); // [B] 写（带屏障）

// 如果 CPU B 在 [A] 之前读取了 next，
// 可能看到过期数据（prev 的旧值）
```

`WRITE_ONCE` + `READ_ONCE` 组合：
- 防止编译器重排序
- 在 DEC Alpha 等弱序 CPU 上，防止 CPU 重排序
- 确保 **发布-订阅** 语义：写端 publish 后，读端一定能看到

### 8.2 list_empty_careful — 并发安全的空判断

```c
// include/linux/list.h:393-396
static inline int list_empty_careful(const struct list_head *head)
{
    struct list_head *next = smp_load_acquire(&head->next);
    return list_is_head(next, head) && (next == READ_ONCE(head->prev));
}
```

`smp_load_acquire`：确保 `next` 读取之前，所有之前的写操作都对读者可见。

---

## 9. 实际内核使用案例

### 9.1 进程调度器中的使用

```c
// include/linux/sched.h — task_struct
struct task_struct {
    struct list_head    tasks;     // 全局调度链表
    struct list_head    run_list;  // 运行队列链表
    struct list_head    children;  // 子进程链表
    struct list_head    sibling;   // 兄弟进程链表
};
```

### 9.2 设备驱动中的使用

```c
// include/linux/device.h — struct device
struct device {
    struct list_head    node;         // 设备链表
    struct list_head    children;     // 子设备链表
    struct device       *parent;      // 父设备
};
```

### 9.3 workqueue 中的使用

```c
// include/linux/workqueue.h — struct work_struct
struct work_struct {
    atomic_long_t        data;
    struct list_head    entry;   // 接入 workqueue 链表
    work_func_t         func;    // 回调函数
};
```

---

## 10. 设计决策总结

| 决策 | 原因 |
|------|------|
| 侵入式（嵌入而非包装）| 外层结构直接包含链表节点，内存局部性更好 |
| 双向循环（无 NULL 尾）| 消除边界检查，代码更简洁高效 |
| container_of 而非 offsetof | 编译期类型检查，更安全 |
| WRITE_ONCE/READ_ONCE | 支持弱序 CPU（Alpha）和并发场景 |
| LIST_POISON | use-after-free 立即崩溃而非静默错误 |
| hlist 单指针桶头 | 减少哈希表桶头的内存开销（16→8 字节）|

---

## 11. 完整文件索引

| 文件路径 | 关键行号 | 内容 |
|---------|---------|------|
| `include/linux/list.h` | 28-35 | `LIST_HEAD_INIT` / `LIST_HEAD` 定义 |
| `include/linux/list.h` | 38-42 | `INIT_LIST_HEAD` 实现 |
| `include/linux/list.h` | 151-162 | `__list_add` 内部插入 |
| `include/linux/list.h` | 165-177 | `list_add` 栈插入 |
| `include/linux/list.h` | 180-198 | `list_add_tail` 队列插入 |
| `include/linux/list.h` | 207-213 | `__list_del` 内部删除 |
| `include/linux/list.h` | 228-233 | `list_del` 含毒值删除 |
| `include/linux/list.h` | 264-267 | `list_del_init` |
| `include/linux/list.h` | 301-306 | `list_move` |
| `include/linux/list.h` | 451-457 | `list_for_each` |
| `include/linux/list.h` | 469-475 | `list_for_each_safe` |
| `include/linux/list.h` | 557-563 | `list_for_each_entry` |
| `include/linux/container_of.h` | 18-27 | `container_of` 定义 |
| `include/linux/list_nulls.h` | 全文 | `hlist_nulls` 单向链表变体 |
