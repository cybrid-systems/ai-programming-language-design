# Linux Kernel list_head 双向循环链表 — 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/list.h`）
> 工具：doom-lsp（clangd LSP） + 原始源码对照
> 更新：整合 2026-04-14 学习笔记强化内容

---

## 0. 为什么要先学 list_head？

**"一切皆链表"** 是 Linux 内核最核心的设计哲学之一：

- 进程调度：所有 `task_struct` 通过 `tasks` 节点串成全局链表
- 内存管理：`struct page` 通过 `lru` 链表接入 zone 的 `free_area`
- 文件系统：dentry 缓存、inode 缓存、superblock 链表
- 设备模型：`kset` / `kobject` 的孩子、引用链表
- 等待队列：`wait_queue_head` 底层就是 `list_head`
- 网络：sk_buff 链表、netdevice 列表
- 中断：`irqaction` 链表

**比通用容器的优势**：
- 节点就是两个指针，零额外开销（不单独分配节点，把指针嵌入业务结构体）
- O(1) 插入/删除（纯指针操作，无拷贝）
- RCU 加持下实现无锁并发遍历（读端无锁，写端 RCU 同步）

---

## 1. 核心数据结构

```c
// include/linux/list.h — 循环双向链表
// 整个链表实现只有两个指针，嵌入到任意业务结构体里
struct list_head {
    struct list_head *next;  // 指向下一个节点
    struct list_head *prev;  // 指向上一个节点
};
```

**极简设计**：没有数据字段，没有 size，没有头节点标记——所有信息都编码在指针的指向关系里。

---

## 2. 内存布局图

```
空链表（head 自指）：
    head.next ──→ head
    head.prev ──→ head

三元素循环链表（完整视图）：

    head ───────────────────────────┐
    │                               │
    │ head.next = &node1            │
    │ head.prev = &node3            │
    ▼                               │
  node1 ◄───────────────────────► node3
  │ node1.next = &node2            │ node3.prev = &node1
  │ node1.prev = &head             │ node3.next = &head
  │                               ▲
  ▼                               │
  node2                            │
  │ node2.next = &head            │
  │ node2.prev = &node1           │
  └────────────────────────────────┘

等价视图（环形）：
  head ↔ node1 ↔ node2 ↔ node3 ↔ head
```

**关键性质**：
- head 本身也是链表的一部分（不是哨兵节点）
- 空链表 = head.next == head == head.prev（三者相等）
- 循环链表无头尾之分，任何节点都可以作为链表头

---

## 3. 初始化（4种方式）

### 3.1 静态初始化（编译期）

```c
// LIST_HEAD_INIT：展开为结构体字面量，next 和 prev 都指向自己
#define LIST_HEAD_INIT(name) { &(name), &(name) }

// LIST_HEAD：定义 + 初始化一步完成
#define LIST_HEAD(name) \
    struct list_head name = LIST_HEAD_INIT(name)

// 用法：
LIST_HEAD(my_list);    // 声明一条名为 my_list 的空链表
```

### 3.2 运行时初始化

```c
static inline void INIT_LIST_HEAD(struct list_head *list)
{
    WRITE_ONCE(list->next, list);  // 内存屏障安全写
    WRITE_ONCE(list->prev, list);
}
```

### 3.3 为什么要 `WRITE_ONCE`？

```c
// include/linux/list.h:45-46
WRITE_ONCE(list->next, list);
WRITE_ONCE(list->prev, list);
```

`WRITE_ONCE` 是内核的编译器屏障：
- **防止编译优化重排写指令顺序**
- **防止写操作被合并或消除**（例如两次写相同值可能被优化掉一次）
- 配合 `READ_ONCE`，在 SMP 内核中保证多核间操作可见性

在内核这种高度并发的环境里，`list_head` 是被多个 CPU 同时读写的共享结构，即使两个"赋值"操作的先后顺序也不应该被编译器打乱。

---

## 4. 插入操作

### 4.1 内部原语 `__list_add`

```c
// include/linux/list.h:154-163
static inline void __list_add(struct list_head *new,
                              struct list_head *prev,
                              struct list_head *next)
{
    if (!__list_add_valid(new, prev, next))  // CONFIG_LIST_HARDENED 安全检查
        return;

    next->prev = new;
    new->next = next;
    new->prev = prev;
    WRITE_ONCE(prev->next, new);  // 最后写，保证可见性
}
```

**4 步操作顺序**：
1. `next->prev = new` — 先让后继节点指回新节点
2. `new->next = next` — 新节点指向后继
3. `new->prev = prev` — 新节点指向前驱
4. `prev->next = new` — **最后**前驱指向新节点（完成环）

### 4.2 栈（LIFO）— `list_add`

```c
// include/linux/list.h:175
// 插入 head 之后 → 新元素在链表头部 → 栈行为
static inline void list_add(struct list_head *new, struct list_head *head)
{
    __list_add(new, head, head->next);
}
```

### 4.3 队列（FIFO）— `list_add_tail`

```c
// include/linux/list.h:189
// 插入 head->prev 之前（即链表尾部）→ 队列行为
static inline void list_add_tail(struct list_head *new, struct list_head *head)
{
    __list_add(new, head->prev, head);
}
```

---

## 5. 删除操作

### 5.1 内部原语 `__list_del`

```c
// include/linux/list.h:201-204
static inline void __list_del(struct list_head *prev, struct list_head *next)
{
    next->prev = prev;
    WRITE_ONCE(prev->next, next);
}
```

### 5.2 `list_del` — 删除并置毒

```c
// include/linux/list.h:235-240
static inline void list_del(struct list_head *entry)
{
    __list_del_entry(entry);
    entry->next = LIST_POISON1;   // 0x100 + POISON_POINTER_DELTA
    entry->prev = LIST_POISON2;   // 0x122 + POISON_POINTER_DELTA
}
```

**置毒值设计**（`include/linux/poison.h`）：

```c
#define LIST_POISON1  ((void *) 0x100 + POISON_POINTER_DELTA)
#define LIST_POISON2  ((void *) 0x122 + POISON_POINTER_DELTA)
```

- `POISON_POINTER_DELTA` 由 `CONFIG_ILLEGAL_POINTER_VALUE` 决定（架构相关）
- x86_64 上约为 `0xdead000000000000`，所以 LIST_POISON1 约为 `0xdead000000000100`
- **任何对已删除节点的访问都会触发页面错误**，实现 fail-fast 安全机制
- 避免 `use-after-free` 被静默忽略，快速暴露 bugs

### 5.3 `list_del_init` — 删除并重新初始化

```c
// include/linux/list.h:293-297
static inline void list_del_init(struct list_head *entry)
{
    __list_del_entry(entry);
    INIT_LIST_HEAD(entry);  // next=prev=self，可安全重新加入链表
}
```

---

## 6. `container_of` — 魔法黑科技

```c
// include/linux/container_of.h
#define container_of(ptr, type, member) ({                              \
    void *__mptr = (void *)(ptr);                                      \
    static_assert(__same_type(*(ptr), ((type *)0)->member) ||         \
                  __same_type(*(ptr), void),                           \
                  "pointer type mismatch in container_of()");          \
    ((type *)(__mptr - offsetof(type, member))); })
```

**数学原理**（已知 2 个，求 1 个）：

```
已知：
  - ptr      = &container_struct->member（成员地址）
  - member   = 在 type 中的偏移量（编译期常量 offsetof）
  - __mptr   = (void *)ptr

求：
  container_struct = ?

公式：
  __mptr - offsetof(type, member) = container_struct 地址
```

**为什么存成员的地址可以反推容器地址？**

因为成员在容器中的偏移量是编译期常量（`offsetof`），不依赖运行时数据。只要知道成员地址，减去偏移量就是容器首地址。

**`list_entry` 就是 `container_of` 的别名**：

```c
// include/linux/list.h:608
#define list_entry(ptr, type, member) \
    container_of(ptr, type, member)
```

---

## 7. 遍历宏家族

### 7.1 `list_for_each` — 基础遍历

```c
// include/linux/list.h:708
#define list_for_each(pos, head) \
    for (pos = (head)->next; !list_is_head(pos, (head)); pos = pos->next)
```

- `pos` 是 `struct list_head *`（链表节点指针）
- `list_is_head` 检查 pos 是否等于 head（链表结束标志）
- 空链表时 `head->next == head`，循环体不执行

### 7.2 `list_for_each_safe` — 可删除当前节点

```c
#define list_for_each_safe(pos, n, head) \
    for (pos = (head)->next, n = pos->next; \
         !list_is_head(pos, (head)); \
         pos = n, n = pos->next)
```

- `n` 提前保存 `pos->next`，删除 pos 后仍能用 n 继续遍历

### 7.3 `list_for_each_entry` — **最常用**（类型安全）

```c
// include/linux/list.h:781-783
#define list_for_each_entry(pos, head, member)              \
    for (pos = list_first_entry(head, typeof(*pos), member); \
         !list_entry_is_head(pos, head, member);           \
         pos = list_next_entry(pos, member))
```

**优点**：`pos` 直接是外层结构体指针，不再需要每次手动 `list_entry()` 转换。

### 7.4 `list_count_nodes` — 计数

```c
// include/linux/list.h:755
static inline size_t list_count_nodes(struct list_head *head)
{
    struct list_head *pos;
    size_t count = 0;
    list_for_each(pos, head)
        count++;
    return count;
}
```

---

## 8. `list_is_head` 与遍历终止条件

```c
// include/linux/list.h:370
static inline int list_is_head(const struct list_head *list,
                               const struct list_head *head)
{
    return list == head;
}
```

**为什么 list_head 需要 `list_is_head` 而不是 `pos != head`？**

因为 `list_for_each` 的循环条件是 `!list_is_head(pos, head)`，而 `pos` 是从 `head->next` 开始的。在循环中我们需要判断是否遍历回 `head` 本身。由于循环链表特性，当 `pos == head` 时说明完成了一圈，终止遍历。

---

## 9. 安全加固：`CONFIG_LIST_HARDENED` + `CONFIG_DEBUG_LIST`

```c
// include/linux/list.h:49-52
#ifdef CONFIG_LIST_HARDENED
#ifdef CONFIG_DEBUG_LIST
// 完整验证版本（慢路径，崩溃时打印详细信息）
bool __list_add_valid_or_report(struct list_head *new,
                                struct list_head *prev,
                                struct list_head *next);
#endif

// 快速检查版本（内联，只返回 false，不打印）
static __always_inline bool __list_add_valid(struct list_head *new,
                                             struct list_head *prev,
                                             struct list_head *next)
{
    if (!IS_ENABLED(CONFIG_DEBUG_LIST)) {
        /* minimal check: prev->next 和 next->prev 是否自指 */
        return list_empty(head);  // ...
    }
    return __list_add_valid_or_report(new, prev, next);
}
#endif
```

**三级安全策略**：

| 配置 | 检查内容 | 性能影响 |
|------|---------|---------|
| `CONFIG_LIST_HARDENED` only | `prev->next == self` 等基础检查 | 极小（内联） |
| `CONFIG_DEBUG_LIST` | 完整链表完整性验证 + 打印 | 大（函数调用） |
| 两者都关 | 无检查 | 零开销 |

---

## 10. RCU + list_head：无锁并发读

```c
// include/linux/rculist.h — RCU 保护的链表变体

// list_add_rcu：写端原子插入（需配合 rcu_read_lock）
static inline void list_add_rcu(struct list_head *new, struct list_head *head)
{
    __list_add_rcu(new, head, head->next);
}

// list_del_rcu：删除节点（ tombstone 方式，不立即释放）
static inline void list_del_rcu(struct list_head *entry)
{
    __list_del(entry);
    entry->prev = LIST_POISON2;  // 不是 NULL，保持链表完整性
}
```

**RCU 读取端**：不需要锁，只需要在 `rcu_read_lock()` / `rcu_read_unlock()` 之间遍历，保证遍历期间节点不会被释放。

**这是现代内核高并发的基础**：读端无锁、无原子操作、无 cache bouncing，只有写端需要全局同步。

---

## 11. task_struct 中的 list_head 成员

```c
// include/linux/sched.h — task_struct 的链表成员（Linux 7.0）

struct task_struct {
    // 进程调度相关
    struct list_head tasks;         // 行 958 — 全局进程链表（init_task.tasks）
    struct list_head rt.run_list;   // 行 624 — RT 调度链表

    // 进程树结构
    struct list_head children;      // 行 1082 — 父进程的子进程链表
    struct list_head sibling;       // 行 1083 — 兄弟链表（链接进 parent->children）
    struct list_head group_leader;  // 行 584 — 线程组组长

    // 其他
    struct list_head ptrace_children;  // 被调试的子进程
    struct list_head ptrace_entry;     // 链接进调试器的 ptrace_children
    struct list_head thread_node;   // 行 1098 — 线程组链表（同一线程组的所有 thread_struct）
    struct list_head cg_list;       // 行 1325 — cgroup 链表
};
```

---

## 12. 真实内核使用案例

### 12.1 `fork.c:2494-2495` — 新进程加入链表

```c
// kernel/fork.c:2494-2495
// 新进程通过 sibling 节点加入父进程的 children 链表（尾插，队列行为）
list_add_tail(&p->sibling, &p->real_parent->children);
// 新进程通过 tasks 节点加入 init_task 全局进程链表（RCU 安全版本）
list_add_tail_rcu(&p->tasks, &init_task.tasks);
```

### 12.2 `fork.c:3039` — 遍历所有子进程

```c
// kernel/fork.c:3039
list_for_each_entry(child, &parent->children, sibling) {
    res = visitor(child, data);
    if (res < 0)
        goto out;
    // ...
}
```

### 12.3 `kernel/workqueue.c` — 工作队列

```c
// kernel/workqueue.c
list_add(&worker->entry, &pool->idle_list);           // 1065：工人加入空闲列表
list_add_tail(&pwq->pending_node, &nna->pending_pwqs); // 1785：工作队列节点入队
list_add_tail(&work->entry, head);                     // 2230：工作项入队
list_add_tail(&worker->node, &pool->workers);          // 2734：工人加入 workers 链表
```

### 12.4 `net/core/dev.c` — 网络设备链表

```c
// net/core/dev.c
list_add_tail_rcu(&dev->dev_list, &net->dev_base_head);  // 414：设备加入网络命名空间
list_add_rcu(&pt->list, head);                            // 632：协议类型注册
```

---

## 13. 算法复杂度分析

| 操作 | 时间复杂度 | 说明 |
|------|----------|------|
| `INIT_LIST_HEAD` | O(1) | 两个写操作 |
| `list_add` | O(1) | 四个指针赋值 |
| `list_add_tail` | O(1) | 四个指针赋值 |
| `list_del` | O(1) | 四个指针赋值 + 置毒 |
| `list_del_init` | O(1) | 四个指针赋值 + 重初始化 |
| `list_move` | O(1) | 删除 + 插入 |
| 遍历（n 个节点） | O(n) | 单次 for 循环 |
| 查找特定节点 | O(n) | 线性遍历 |

**核心：所有链表操作都是 O(1) 指针操作，无任何动态内存分配或拷贝！**

---

## 14. 架构意义总结

```
list_head + RCU = Linux 高并发基石

读端路径（RCU read-side）：
  rcu_read_lock()
  list_for_each_entry_rcu(pos, head, member)
      // 无锁遍历，零原子操作，零 cache bouncing
  rcu_read_unlock()

写端路径（RCU update-side）：
  spin_lock(&lock)
  list_del_rcu(entry)    // 只做赋值，不释放内存
  spin_unlock(&lock)
  synchronize_rcu()        // 等所有读端读者退出
  kfree(entry)            // 安全释放

优势：
  - 读端性能接近无锁（只有 compiler barrier）
  - 写端只需要锁住数据结构的修改部分
  - 多核扩展性极佳（读端无 cache contention）
```

---

## 15. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/list.h` | 完整链表实现（51 个符号） |
| `include/linux/container_of.h` | `container_of` 定义 |
| `include/linux/poison.h` | `LIST_POISON1/2` 定义 |
| `include/linux/rculist.h` | RCU 保护版本 |
| `include/linux/sched.h:820` | `task_struct` 定义 |
| `kernel/fork.c` | 进程链表真实用例 |
| `kernel/workqueue.c` | 工作队列链表用例 |
| `net/core/dev.c` | 网络设备链表用例 |

---

## 附录：doom-lsp 分析记录

```
项目路径：~/code/linux
编译数据库：compile_commands.json（bear 生成）
clangd：/usr/local/bin/clangd ✓

include/linux/list.h — 51 个符号：
  INIT_LIST_HEAD @ 43
  __list_add_valid @ 136
  __list_add @ 154
  list_add @ 175
  list_add_tail @ 189
  __list_del @ 201
  list_del @ 235
  list_replace @ 249
  list_del_init @ 293
  list_move @ 304
  list_count_nodes @ 755
  hlist_* @ 946-1206（哈希链表）
```
