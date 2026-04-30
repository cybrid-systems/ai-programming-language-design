# 01-list_head — 双向链表深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/list.h` + `include/linux/rculist.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照
> 关键词：双向链表、container_of、RCU、LIST_POISON、西游记

---

## 0. 概述

**list_head** 是 Linux 内核最核心的数据结构之一，采用**双向循环链表**设计，所有节点结构都要内嵌 `struct list_head`。其精妙之处在于 `container_of` 宏——通过链表节点逆向找到父结构体。

---

## 1. 核心数据结构

### 1.1 struct list_head — 链表节点

```c
// include/linux/list.h:35 — 链表节点定义
struct list_head {
    struct list_head  *next;   // 指向下一个节点
    struct list_head  *prev;   // 指向上一个节点
};
```

**两种初始化方式：**

```c
// 方式一：静态初始化（编译时）
struct list_head my_list = LIST_HEAD_INIT(my_list);
// 展开为：
//   struct list_head my_list = { &my_list, &my_list }; // 指向自己 = 空链表

// 方式二：宏初始化
LIST_HEAD(my_list);
// 效果同上，但更简洁
```

**内存布局：**

```
struct list_head 节点：
  [prev指针 | next指针]
    8字节(64位) | 8字节(64位)
    = 16字节

注意：prev 和 next 指向类型是 struct list_head*，不是具体结构！
```

### 1.2 链表类型分类

```c
// list_head 作为"哨兵"（头节点），不携带数据
struct list_head {
    struct list_head *next;  // 指向第一个真实数据节点
    struct list_head *prev;  // 指向最后一个真实数据节点（形成循环）
};

// 使用时，将 list_head 作为成员嵌入到真实数据结构中：
struct task_struct {
    struct list_head  tasks;   // 所有进程串成链表
    struct list_head  children; // 子进程链表
    struct list_head  sibling;  // 加入兄弟链表
    // ...
};
```

---

## 2. 核心操作函数

### 2.1 list_add — 头部插入

```c
// include/linux/list.h:32
static inline void __list_add(struct list_head *new,
                              struct list_head *prev,
                              struct list_head *next)
{
    if (!__list_add_valid(new, prev, next))
        return;

    next->prev = new;
    new->next = next;
    new->prev = prev;
    WRITE_ONCE(prev->next, new);
}
```

**图解 list_add(new, head, head->next)：**

```
插入前（空链表示意）：
  head ──→ [A] ──→ [B] ──→ head
  ↑_____________________________↓（循环）

插入 new 到 head 后面：
  head ──→ [new] ──→ [A] ──→ [B] ──→ head
          ↑_____________________________↓
```

### 2.2 list_add_tail — 尾部插入

```c
// include/linux/list.h:43
static inline void list_add_tail(struct list_head *new, struct list_head *head)
{
    __list_add(new, head->prev, head);
}
// 等价于：插入到 head->prev 之后（即 head 之前）
// 循环链表尾插 = 插入到 head 前面
```

### 2.3 list_del — 删除节点

```c
// include/linux/list.h:207
static inline void __list_del(struct list_head *prev, struct list_head *next)
{
    next->prev = prev;
    WRITE_ONCE(prev->next, next);
}

// 对外接口：list_del
static inline void list_del(struct list_head *entry)
{
    __list_del(entry->prev, entry->next);
    entry->next = LIST_POISON1;  // 0x00100100
    entry->prev = LIST_POISON2;  // 0x00200200
}

// LIST_POISON1 和 LIST_POISON2 是故意设为无效指针地址
// 如果错误访问已删除节点，立即触发 page fault（调试用）
```

### 2.4 list_replace — 替换节点

```c
// include/linux/list.h:226
static inline void list_replace(struct list_head *old,
                               struct list_head *new)
{
    new->next = old->next;
    new->next->prev = new;
    new->prev = old->prev;
    new->prev->next = new;
}
```

### 2.5 list_move / list_move_tail

```c
// include/linux/list.h:263
static inline void list_move(struct list_head *list, struct list_head *head)
{
    __list_del(list->prev, list->next);
    list_add(list, head);
}

static inline void list_move_tail(struct list_head *list,
                                  struct list_head *head)
{
    __list_del(list->prev, list->next);
    list_add_tail(list, head);
}
```

### 2.6 list_is_first / list_is_last

```c
// include/linux/list.h:289
static inline int list_is_first(const struct list_head *list,
                                const struct list_head *head)
{
    return list->prev == head;
}

static inline int list_is_last(const struct list_head *list,
                                const struct list_head *head)
{
    return list->next == head;
}
```

### 2.7 list_empty — 链表判空

```c
// include/linux/list.h:284
static inline int list_empty(const struct list_head *head)
{
    return READ_ONCE(head->next) == head;
}
// 注意：使用 READ_ONCE 是为了防止 CPU 乱序执行导致的误判
```

### 2.8 list_rotate_left — 旋转链表

```c
// include/linux/list.h:271
static inline void list_rotate_left(struct list_head *head)
{
    struct list_head *first;

    if (!list_empty(head)) {
        first = head->next;
        __list_del(first->prev, first->next);
        list_add_tail(first, head);
    }
}
```

---

## 3. 遍历宏

### 3.1 list_for_each — 正向遍历

```c
// include/linux/list.h:311
#define list_for_each(pos, head) \
    for (pos = (head)->next; pos != (head); pos = pos->next)
// 语义：for (pos = head->next; pos != head; pos = pos->next)

// 缺陷：pos 是 struct list_head*，不是具体数据
//       每次迭代需要用 container_of 转换
```

### 3.2 list_for_each_entry — 直接遍历数据节点

```c
// include/linux/list.h:328
#define list_for_each_entry(pos, head, member) \
    for (pos = list_entry((head)->next, typeof(*pos), member); \
         &pos->member != (head); \
         pos = list_entry(pos->member.next, typeof(*pos), member))

// 示例：遍历所有进程
struct task_struct *task;
list_for_each_entry(task, &init_task.tasks, tasks) {
    printk("%s\n", task->comm);
}
// 自动将 list_head* 转换为 task_struct*
```

### 3.3 list_for_each_entry_reverse — 反向遍历

```c
// include/linux/list.h:346
#define list_for_each_entry_reverse(pos, head, member) \
    for (pos = list_entry((head)->prev, typeof(*pos), member); \
         &pos->member != (head); \
         pos = list_entry(pos->member.prev, typeof(*pos), member))
```

### 3.4 list_for_each_safe — 安全遍历（删除时用）

```c
// include/linux/list.h:317
#define list_for_each_safe(pos, n, head) \
    for (pos = (head)->next, n = pos->next; pos != (head); \
         pos = n, n = pos->next)
// n 是下一个节点的备份，允许安全删除当前 pos
```

### 3.5 list_for_each_entry_safe — 安全遍历数据节点

```c
// include/linux/list.h:372
#define list_for_each_entry_safe(pos, n, head, member) \
    for (pos = list_entry((head)->next, typeof(*pos), member), \
         n = list_entry(pos->member.next, typeof(*pos), member); \
         &pos->member != (head); \
         pos = n, n = list_entry(n->member.next, typeof(*pos), member))
```

---

## 4. container_of — 链表节点到父结构体的转换

### 4.1 原理

```c
// include/linux/container_of.h:14
#define container_of(ptr, type, member) \
    ((type *)((char *)(void *)(ptr) - offsetof(type, member)))

// offsetof：计算 member 在 type 中的偏移量
// ptr - offset = 父结构体的起始地址
```

### 4.2 list_entry — container_of 的别名

```c
// include/linux/list.h:23
#define list_entry(ptr, type, member) \
    container_of(ptr, type, member)
// list_entry = container_of，功能完全相同
```

### 4.3 图解

```
struct task_struct {
    char name[20];     // offset 0
    int  pid;         // offset 20
    struct list_head tasks; // offset 24 (假设)
};

假设 &task->tasks = 0x1000a8
offsetof(task_struct, tasks) = 24
则 task 的起始地址 = 0x1000a8 - 24 = 0x100090

验证：
task->tasks.next 访问的地址 = 0x100090 + 24 = 0x1000a8 ✓
```

---

## 5. RCU 遍历（读写分离）

### 5.1 list_for_each_entry_rcu

```c
// include/linux/rculist.h:38
#define list_for_each_entry_rcu(pos, head, member...) \
    for (pos = list_entry(rcu_dereference_raw((head)->next), \
                typeof(*pos), member); \
         list_entry_is_head(pos, head, member) || \
         ({ rcu_lock_trace(pos, head); 0; }); \
         pos = list_entry(rcu_dereference_raw(pos->member.next), \
                  typeof(*pos), member))
```

### 5.2 list_splice_rcu — RCU 安全拼接

```c
// include/linux/rculist.h:179
static inline void list_splice_rcu(struct list_head *list,
                                   struct list_head *head,
                                   bool (*cond)(const struct list_head *))
{
    if (cond && !cond(list))
        return;

    if (!list_empty(list)) {
        struct list_head *first = list->next;
        struct list_head *last = list->prev;
        struct list_head *at = head->next;

        first->prev = head;
        WRITE_ONCE(head->next, first);
        last->next = at;
        at->prev = last;
    }
}
```

---

## 6. Linux 内核使用案例

### 6.1 进程链表

```c
// kernel/fork.c — copy_process
// 每个进程的 task_struct.tasks 将所有进程串成链表

struct task_struct *task;
list_for_each_entry(task, &init_task.tasks, tasks) {
    // 遍历系统中的所有进程
}

// 链表头 init_task 是 swapper 进程（PID 0）
// init_task.tasks 是系统进程链表的入口
```

### 6.2 VFS inode链表

```c
// include/linux/fs.h — inode
struct inode {
    struct list_head  i_list;    // inode 链表（inod_hashtable）
    struct list_head  i_sb_list; // 超级块链表
    struct hlist_node i_hash;   // hash 链表节点
    // ...
};
// 磁盘缓存中的 inode 通过 i_list 链接
```

### 6.3 模块链表

```c
// kernel/module/main.c — module
struct module {
    enum module_state state;     // MODULE_STATE_LIVE / MODULE_STATE_COMING / GOING
    struct list_head  list;     // 所有模块的链表
    char              name[MODULE_NAME_LEN];
    // ...
};

// 全局模块链表：
static LIST_HEAD(modules);
// 通过 list_for_each_entry(mod, &modules, list) 遍历所有模块
```

---

## 7. 设计决策总结

| 设计决策 | 原因 |
|---------|------|
| 双向循环链表 | O(1) 插入/删除，头尾操作等价 |
| 循环结构 | 无需特殊处理空链表 |
| list_head 嵌入数据内 | 通用链表节点，可挂任意结构 |
| container_of | 无需维护独立节点结构，节省内存 |
| LIST_POISON | 删除后访问触发 page fault，快速发现 bug |
| WRITE_ONCE/READ_ONCE | 防止 CPU 乱序执行导致的数据竞争 |
| RCU 变体 | 读写可以真正并行（读不加锁） |

---

## 8. 内存布局图

```
循环链表完整结构：

  head（哨兵节点）
    │
    ├──prev─┐
    │       │
    │      [A] ──prev──→ [A]的prev ──→ ... ──→ [Z]的prev
    │       │                                     │
    │       ↓                                     ↓
    │      [A] ←─next── [A]的next ──→ ... ──→ [Z] ──next──┘
    │                                                   │
    └───────────────────────────────────────────────────┘
    
注意：prev 指向链表中前一个节点的 next 指针的地址（不是节点本身）
     next 指向链表中后一个节点的 prev 指针的地址（不是节点本身）
```

---

## 9. 完整文件索引

| 文件 | 行号 | 内容 |
|------|------|------|
| `include/linux/list.h` | 35 | `struct list_head` 定义 |
| `include/linux/list.h` | 32 | `__list_add` |
| `include/linux/list.h` | 43 | `list_add_tail` |
| `include/linux/list.h` | 207 | `__list_del` |
| `include/linux/list.h` | 213 | `list_del` |
| `include/linux/list.h` | 226 | `list_replace` |
| `include/linux/list.h` | 263 | `list_move` |
| `include/linux/list.h` | 284 | `list_empty` |
| `include/linux/list.h` | 289 | `list_is_first/last` |
| `include/linux/list.h` | 311 | `list_for_each` |
| `include/linux/list.h` | 328 | `list_for_each_entry` |
| `include/linux/container_of.h` | 14 | `container_of` |
| `include/linux/rculist.h` | 38 | `list_for_each_entry_rcu` |
| `include/linux/list.h` | 23 | `list_entry` |

---

## 10. 西游记类比

**list_head** 就像"取经路上妖怪的报名簿"——

> 唐僧（head 哨兵）走在最前面，八戒（节点 A）、悟空（节点 B）、沙僧（节点 C）依次跟在后面。八戒的"prev"指向唐僧，"next"指向悟空；悟空的"prev"指向八戒的 name 字段所在位置（container_of 魔法），"next"指向沙僧……最后沙僧的"next"又指向唐僧，形成一个循环。只要知道其中任何一个妖怪在报名簿上的位置（`struct list_head*`），就能反推出这个妖怪是谁（`container_of`）。这比每次点名时从队伍头开始数要快得多——O(1) 定位。

---

## 11. 关联文章

- **hlist**（article 02）：适用于 hash table 的单向链表变体
- **RCU**（article 26）：list_for_each_entry_rcu 的读写分离并发机制
- **container_of**（本文）：所有链表逆向推导父结构的数学基础