# Linux 内核学习打卡 Day 1（2026-04-13）

> 主题：list_head 双向循环链表（Linux 7.0 主线最新版）

## 1. 为什么先学 list_head？

它是整个内核的"胶水"：进程链表、内存页链表、文件 dentry 缓存、设备链表、IRQ 链表……几乎所有子系统都在用它。

- 经典双向循环链表，实现 O(1) 插入/删除/遍历
- 源码极简却精妙：不到 400 行，却支撑了上百万行内核代码
- 学习它 = 掌握"数据结构 + 算法 + 业务使用 + 架构思想"的完美起点

## 2. 源码位置

`include/linux/list.h`

核心数据结构（直接来自最新源码）：

```c
struct list_head {
    struct list_head *next;
    struct list_head *prev;
};
```

就是两个指针！简单到极致，却能形成循环双向链表。

## 3. 关键宏和函数

```c
// 初始化一个 list_head，让它指向自己 → 空链表
#define LIST_HEAD_INIT(name) { &(name), &(name) }
#define LIST_HEAD(name) \
    struct list_head name = LIST_HEAD_INIT(name)

// 运行时初始化
static inline void INIT_LIST_HEAD(struct list_head *list)
{
    WRITE_ONCE(list->next, list);
    WRITE_ONCE(list->prev, list);
}

// 内部插入
static inline void __list_add(struct list_head *new,
    struct list_head *prev,
    struct list_head *next)
{
    next->prev = new;
    new->next = next;
    new->prev = prev;
    WRITE_ONCE(prev->next, new);
}
```

**公开接口（每天背熟这 4 个）：**

```c
list_add(struct list_head *new, struct list_head *head);       // 头部插入（栈）
list_add_tail(struct list_head *new, struct list_head *head); // 尾部插入（队列）
list_del(struct list_head *entry);                            // 删除（不初始化）
list_del_init(struct list_head *entry);                        // 删除并初始化为空
```

**遍历宏（最常用！）：**

```c
// 普通遍历（不安全删除）
#define list_for_each(pos, head) \
    for (pos = (head)->next; pos != (head); pos = pos->next)

// 安全遍历（可在循环中删除当前节点）
#define list_for_each_safe(pos, n, head) \
    for (pos = (head)->next, n = pos->next; pos != (head); \
        pos = n, n = pos->next)

// 最推荐：带容器结构的遍历
#define list_for_each_entry(pos, head, member) \
    for (pos = list_entry((head)->next, typeof(*pos), member); \
        &pos->member != (head); \
        pos = list_entry(pos->member.next, typeof(*pos), member))
```

**list_entry 宏（魔法！）：**

```c
#define list_entry(ptr, type, member) \
    container_of(ptr, type, member)
```

把 `struct list_head` 指针反推出整个结构体（内核到处都在用这个技巧）。

## 4. 数据结构图

```
+-------------------+     +-------------------+
|      head         |<--->|     entry1         |
+-------------------+     +-------------------+
| next = entry1     |     | next = entry2     |
| prev = last       |<--->| prev = head       |
+-------------------+     +-------------------+
        ^                           |
        |                           v
+-------------------+     +-------------------+
|      entry3       |<--->|      entry2       |
+-------------------+     +-------------------+
| next = head       |     | prev = entry1     |
| prev = entry2     |<---| next = entry3     |
+-------------------+     +-------------------+
```

特点：
- 循环：head->next 指向第一个，head->prev 指向最后一个
- 双向：正向、反向遍历都 O(1)
- 无头节点：head 本身也是链表的一部分（空链表时 head 指向自己）

## 5. 真实内核使用案例

```c
// kernel/fork.c - 新进程加入全局进程链表
list_add(&p->tasks, &init_task.tasks);
```

- **进程管理**：`tasks` 链表（所有 `task_struct` 通过 `struct list_head tasks` 串起来）
- **内存管理**：每个 zone 的 `free_area` 用 list_head 管理空闲页
- **文件系统**：dentry 缓存、inode 缓存、superblock 链表
- **设备驱动**：`platform_device` 链表、`driver` 链表
- **网络**：`skb`（socket buffer）链表
- **中断**：`irqaction` 链表

## 6. 小练习

- [ ] 手写 `list_add_tail` 的 mini 版本（不用内核宏）
- [ ] 用户态测试程序：用 list_head 管理 10 个学生结构体（学号+姓名），实现增删改查
- [ ] 用 `grep -r "list_add" --include="*.c" kernel/` 找 3 个真实使用场景

## 7. 打卡总结

- **日期**：2026-04-13
- **今日主题**：list_head 双向循环链表
- **关键收获**：O(1) 插入删除 + `list_for_each_entry` 容器遍历技巧 + `container_of` 魔法
- **业务场景**：进程链表、内存 free_area、dentry 缓存、device 链表...
- **遇到问题**：—
- **明天想学**：hlist（哈希链表，比 list_head 更省内存，常用于 hash 表）

---

> 明天（第 2 天）：hlist（哈希链表，比 list_head 更省内存，常用于 hash 表）
