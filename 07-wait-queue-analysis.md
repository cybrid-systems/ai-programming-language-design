# Linux Kernel wait_queue_head 等待队列 — 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/wait.h` + `kernel/sched/wait.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 更新：整合 2026-04-20 学习笔记

---

## 0. 什么是 wait_queue_head？

**wait_queue_head** 是内核"睡眠/唤醒"机制的标准实现。任何任务可以等待某个条件，条件满足时被唤醒——所有驱动、调度器、文件系统、网络子系统的同步基础。

**核心思想**：
- 任务主动睡眠（`schedule()` 让出 CPU）
- 另一个代码路径在条件满足时唤醒（`wake_up()`）
- 双方通过 `wait_queue_head` 链表交互

---

## 1. 核心数据结构

### 1.1 `struct wait_queue_head` — 等待队列头

```c
// include/linux/wait.h:35
struct wait_queue_head {
    spinlock_t        lock;   // 保护 head 链表
    struct list_head  head;   // 双向循环链表（挂 wait_queue_entry）
};

typedef struct wait_queue_head wait_queue_head_t;

// 静态声明（最常用）
#define DECLARE_WAIT_QUEUE_HEAD(name) \
    wait_queue_head_t name = __WAIT_QUEUE_HEAD_INITIALIZER(name)

#define __WAIT_QUEUE_HEAD_INITIALIZER(name) {               \
    .lock = __SPIN_LOCK_UNLOCKED(name.lock),             \
    .head = { &name.head, &name.head } }                 // 空链表（head 自指）
```

### 1.2 `struct wait_queue_entry` — 等待队列节点

```c
// include/linux/wait.h:28
struct wait_queue_entry {
    unsigned int         flags;      // WQ_FLAG_xxx
    void                *private;    // 通常指向 task_struct
    wait_queue_func_t    func;       // 唤醒回调函数
    struct list_head     entry;      // 挂在 wait_queue_head->head 上
};

// 标志位
#define WQ_FLAG_EXCLUSIVE   0x01  // 独占等待（唤醒时只唤醒一个）
#define WQ_FLAG_WOKEN       0x02  // 已被唤醒
#define WQ_FLAG_CUSTOM      0x04  // 自定义唤醒函数
```

### 1.3 `wait_queue_func_t` — 唤醒回调

```c
// include/linux/wait.h:15
typedef int (*wait_queue_func_t)(struct wait_queue_entry *wq_entry,
                                 unsigned mode, int flags, void *key);

// 默认唤醒函数（大多数情况使用）
int default_wake_function(struct wait_queue_entry *wq_entry,
                          unsigned mode, int flags, void *key)
{
    return default_wake_function(wq_entry->private, mode, flags, key);
}
```

---

## 2. 内存布局图

```
wait_queue_head 完整结构：

wait_queue_head
├── lock (spinlock_t)
└── head (list_head)
    ├── next ──→ wait_queue_entry[0] ──→ wait_queue_entry[1] ──→ ...
    │           └── entry.next              └── entry.next
    └── prev ──→ ... ←─────────────── ←──────────────────────────

wait_queue_entry[N]：
├── flags = WQ_FLAG_EXCLUSIVE | WQ_FLAG_WOKEN
├── private = current  (task_struct*)
├── func = default_wake_function
└── entry
    ├── next ──→ next wait_queue_entry（或回到 head）
    └── prev ──→ prev wait_queue_entry（或 head）
```

---

## 3. 核心 API

### 3.1 初始化

```c
// 动态初始化
void init_waitqueue_head(struct wait_queue_head *wq_head)
{
    spin_lock_init(&wq_head->lock);
    INIT_LIST_HEAD(&wq_head->head);
}

// 静态初始化（DECLARE_WAIT_QUEUE_HEAD 已包含初始化）
```

### 3.2 添加/移除等待者

```c
// 添加到等待队列
void add_wait_queue(struct wait_queue_head *wq_head,
                   struct wait_queue_entry *wq_entry)
{
    unsigned long flags;
    spin_lock_irqsave(&wq_head->lock, flags);
    list_add(&wq_entry->entry, &wq_head->head);  // 头插（唤醒时先处理先排队的）
    spin_unlock_irqrestore(&wq_head->lock, flags);
}

// 添加独占等待者（WQX_FLAG_EXCLUSIVE）— 插到链表尾部
void add_wait_queue_exclusive(struct wait_queue_head *wq_head,
                              struct wait_queue_entry *wq_entry)
{
    unsigned long flags;
    spin_lock_irqsave(&wq_head->lock, flags);
    list_add_tail(&wq_entry->entry, &wq_head->head);  // 尾插
    spin_unlock_irqrestore(&wq_head->lock, flags);
}

// 移除
void remove_wait_queue(struct wait_queue_head *wq_head,
                      struct wait_queue_entry *wq_entry)
{
    unsigned long flags;
    spin_lock_irqsave(&wq_head->lock, flags);
    list_del(&wq_entry->entry);
    spin_unlock_irqrestore(&wq_head->lock, flags);
}
```

### 3.3 准备等待（`prepare_to_wait`）

```c
// kernel/sched/wait.c
void prepare_to_wait(struct wait_queue_head *wq_head,
                    struct wait_queue_entry *wq_entry, int state)
{
    unsigned long flags;
    spin_lock_irqsave(&wq_head->lock, flags);
    if (list_empty(&wq_entry->entry))
        list_add(&wq_entry->entry, &wq_head->head);
    set_current_state(state);  // state = TASK_INTERRUPTIBLE / TASK_UNINTERRUPTIBLE
    spin_unlock_irqrestore(&wq_head->lock, flags);
}

// 完成后清理
void finish_wait(struct wait_queue_head *wq_head,
                 struct wait_queue_entry *wq_entry)
{
    unsigned long flags;
    __set_current_state(TASK_RUNNING);
    spin_lock_irqsave(&wq_head->lock, flags);
    list_del_init(&wq_entry->entry);  // 从链表移除
    spin_unlock_irqrestore(&wq_head->lock, flags);
}
```

### 3.4 唤醒（`wake_up`）

```c
// kernel/sched/wait.c — 核心唤醒逻辑
void wake_up(struct wait_queue_head *wq_head)
{
    __wake_up(wq_head, TASK_NORMAL, 0, NULL);
}

// __wake_up — 遍历所有等待者，调用 func
// WQ_FLAG_EXCLUSIVE 的处理：
//   - 遇到第一个独占等待者就停止遍历（避免惊群效应）
//   - 只唤醒一个独占等待者，其他等待者继续睡眠
```

---

## 4. 等待/唤醒流程

```
线程A（等待者）:
  1. DEFINE_WAIT(wait);
  2. add_wait_queue(&wq_head, &wait);
  3. for (;;) {
         set_current_state(TASK_INTERRUPTIBLE);
         if (condition)    // 条件满足
             break;
         schedule();      // 让出 CPU，睡眠
     }
  4. finish_wait(&wq_head, &wait);

线程B（唤醒者）:
  wake_up(&wq_head);
    → __wake_up()
      → 遍历 wait_queue_head->head
      → 对每个 entry 调用 func(wait_entry)
        → default_wake_function(wait_entry->private) → try_to_wake_up()
          → 将等待进程设为 TASK_RUNNING
          → 放入运行队列
```

---

## 5. `wait_event` 宏 — 简化等待

```c
// include/linux/wait.h — 经典等待宏
#define wait_event(wq_head, condition) \
    do { \
        DEFINE_WAIT(__wait); \
        for (;;) { \
            prepare_to_wait(&wq_head, &__wait, TASK_UNINTERRUPTIBLE); \
            if (condition) \        // 条件满足则退出
                break; \
            schedule(); \
        } \
        finish_wait(&wq_head, &__wait); \
    } while (0)

// 可中断版本
#define wait_event_interruptible(wq_head, condition) \
    do { \
        DEFINE_WAIT(__wait); \
        for (;;) { \
            prepare_to_wait(&wq_head, &__wait, TASK_INTERRUPTIBLE); \
            if (condition) \
                break; \
            if (signal_pending(current)) { \
                ret = -ERESTARTSYS; \
                break; \
            } \
            schedule(); \
        } \
        finish_wait(&wq_head, &__wait); \
    } while (0)
```

---

## 6. 独占等待（Exclusive）与惊群效应避免

```
场景：多个进程等待同一个条件（accept、read 等）

非独占等待：wake_up 唤醒所有 → 惊群效应（所有进程被唤醒但只有一个能成功）

独占等待：
  所有等待者调用 add_wait_queue_exclusive() 尾插到队列尾部
  
  wake_up 时：
  遍历链表，遇到第一个 EXCLUSIVE 标记就停止，并只唤醒那一个
  → 其他 EXCLUSIVE 等待者继续睡眠 → 避免惊群

链表顺序：
  head → 普通等待者1 → 普通等待者2 → [EXCLUSIVE] → [EXCLUSIVE] → ...
                      ↑ 停止点 ↑
```

---

## 7. 真实内核使用案例

### 7.1 进程退出等待（`kernel/exit.c`）

```c
// wait() 系统调用
wait_event_interruptible(child->wait, !thread_group_exited(p));
```

### 7.2 驱动的 poll/等待（`fs/read_write.c`）

```c
// 文件读取等待数据到达
wait_event_interruptible(file->f_dentry->d_inode->i_sb->s_waiters, ...)
```

### 7.3 完成量（`kernel/sched/completion.c`）

```c
// 完成量（completion）基于 wait_queue_head
struct completion {
    unsigned int done;
    wait_queue_head_t wait;
};

wait_for_completion(&comp);    // 睡眠
complete(&comp);               // 唤醒
```

---

## 8. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| spinlock 保护链表 | 唤醒可能在中断上下文，必须用不可睡眠锁 |
| list_head 双向循环 | O(1) 添加/删除/遍历 |
| func 回调函数 | 灵活的唤醒逻辑（default_wake + 自定义） |
| EXCLUSIVE 尾插 | 独占等待者最后被唤醒，只唤醒一个 → 避免惊群 |
| private = task_struct | 唤醒时直接操作目标进程 |

---

## 9. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/wait.h` | wait_queue_head / wait_queue_entry 定义、宏 |
| `kernel/sched/wait.c` | prepare_to_wait / wake_up / wait_event 实现 |
| `kernel/sched/completion.c` | completion 基于 wait_queue 的实现 |
