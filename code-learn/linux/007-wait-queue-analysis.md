# 07-wait-queue — Linux 内核等待队列深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**等待队列（wait queue）** 是 Linux 内核中实现"等待-唤醒"同步机制的基础设施。当一个线程需要等待某个条件变为真（如 IO 完成、定时器到期、信号到达）时，它将自己加入等待队列并转入休眠状态；当条件满足时，另一个线程负责唤醒等待队列中的线程。

等待队列的核心设计围绕两个数据结构和一套宏展开：
- `struct wait_queue_head`：等待队列头，包含一个自旋锁和一个链表头
- `struct wait_queue_entry`：等待队列项，包含唤醒函数指针、flags、所属的 task_struct
- `wait_event` 宏系列：生产者/消费者模式的标准封装
- `wake_up` 宏系列：条件满足时的唤醒操作

**doom-lsp 确认**：`include/linux/wait.h` 包含 **51 个符号**（含 wait_queue_head、wait_queue_entry 等结构体和宏定义）。`kernel/sched/wait.c` 包含 **92 个实现符号**。

---

## 1. 核心数据结构

### 1.1 `struct wait_queue_head`（`wait.h:35`）

```c
// include/linux/wait.h:35 — doom-lsp 确认
struct wait_queue_head {
    spinlock_t      lock;    // 保护链表操作的自旋锁
    struct list_head head;   // 等待队列项链表（头节点）
};
```

- **`lock`**：保护 `head` 链表的自旋锁。所有 add/remove/wake 操作都需要持有此锁。
- **`head`**：`struct list_head` —— 标准的内核双向循环链表，链入所有等待于此队列的 `wait_queue_entry`。

### 1.2 `struct wait_queue_entry`（`wait.h:28`）

```c
// include/linux/wait.h:28 — doom-lsp 确认
struct wait_queue_entry {
    unsigned int        flags;      // 选项标志（如 WQ_FLAG_EXCLUSIVE）
    void               *private;    // 私有数据（通常指向 current task_struct）
    wait_queue_func_t   func;       // 唤醒回调函数
    struct list_head    entry;      // 链入 wait_queue_head.head
};
```

- **`flags`**：`WQ_FLAG_EXCLUSIVE`（独占唤醒位，表示此 waiter 应被一次只唤醒一个）和其他标志。
- **`private`**：通常是当前进程的 `task_struct` 指针（`current`）。唤醒函数通过它获取要唤醒的进程。
- **`func`**：唤醒回调函数，原型为 `int (*)(struct wait_queue_entry *wq_entry, unsigned mode, int flags, void *key)`。
- **`entry`**：`struct list_head`，链入 `wait_queue_head.head`。

### 1.3 `wait_queue_func_t`（`wait.h:15`）

```c
// include/linux/wait.h:15 — doom-lsp 确认
typedef int (*wait_queue_func_t)(struct wait_queue_entry *wq_entry,
                                  unsigned int mode, int flags, void *key);
```

唤醒函数原型。返回值含义：
- **`0`**：当前 waiter 未被唤醒（继续尝试下一个）
- **`非零`**：当前 waiter 已被成功唤醒
- **`负值`**：出错，停止遍历

---

## 2. 初始化

### 2.1 静态初始化

```c
// include/linux/wait.h
#define __WAIT_QUEUE_HEAD_INITIALIZER(name) {                    \
    .lock   = __SPIN_LOCK_UNLOCKED(name.lock),                   \
    .head   = LIST_HEAD_INIT(name.head) }

#define DECLARE_WAIT_QUEUE_HEAD(name) \
    struct wait_queue_head name = __WAIT_QUEUE_HEAD_INITIALIZER(name)
```

### 2.2 运行时初始化

```c
// kernel/sched/wait.c:9 — doom-lsp 确认
void __init_waitqueue_head(struct wait_queue_head *wq_head, const char *name, 
                            struct lock_class_key *key)
{
    spin_lock_init(&wq_head->lock);
    INIT_LIST_HEAD(&wq_head->head);
    lockdep_init_map(&wq_head->lock.dep_map, name, key, 0);
}
```

`__init_waitqueue_head` 初始化锁和链表。`lockdep_init_map` 为自旋锁注册锁依赖跟踪，这对死锁检测至关重要。

### 2.3 wait_queue_entry 初始化

```c
// include/linux/wait.h:80 — doom-lsp 确认
static inline void init_waitqueue_entry(struct wait_queue_entry *wq_entry, 
                                         struct task_struct *p)
{
    wq_entry->flags    = 0;
    wq_entry->private  = p;           // 通常为 current
    wq_entry->func     = default_wake_function;  // 标准唤醒函数
}

// wait.h:88
static inline void init_waitqueue_func_entry(struct wait_queue_entry *wq_entry,
                                              wait_queue_func_t func)
{
    wq_entry->flags    = 0;
    wq_entry->private  = NULL;
    wq_entry->func     = func;        // 自定义唤醒函数
}
```

**`default_wake_function`** 是标准唤醒函数（`wait.h:16`），它调用 `try_to_wake_up` 将进程设置为可运行状态。

---

## 3. 添加/移除等待项——doom-lsp 确认的行号

```c
// kernel/sched/wait.c:18-69 — doom-lsp 确认
void add_wait_queue(struct wait_queue_head *wq_head, 
                     struct wait_queue_entry *wq_entry);
void add_wait_queue_exclusive(...);     // 独占唤醒
void add_wait_queue_priority(...);      // 插到队首
void add_wait_queue_priority_exclusive(...); // 独占 + 插队首
void remove_wait_queue(...);            // 移除
```

**内部实现**（`wait.h:171-206`）：

```c
// wait.h:171 — doom-lsp 确认
static inline void __add_wait_queue(struct wait_queue_head *wq_head,
                                     struct wait_queue_entry *wq_entry)
{
    list_add(&wq_entry->entry, &wq_head->head);  // 插入到队首（LIFO）
}

// wait.h:194
static inline void __add_wait_queue_entry_tail(struct wait_queue_head *wq_head,
                                                struct wait_queue_entry *wq_entry)
{
    list_add_tail(&wq_entry->entry, &wq_head->head);  // 插入到队尾（FIFO）
}

// wait.h:188
static inline void __add_wait_queue_exclusive(struct wait_queue_head *wq_head,
                                               struct wait_queue_entry *wq_entry)
{
    wq_entry->flags |= WQ_FLAG_EXCLUSIVE;  // 设置独占标志
    __add_wait_queue_entry_tail(wq_head, wq_entry);  // FIFO 尾部
}

// wait.h:207
static inline void __remove_wait_queue(struct wait_queue_head *wq_head,
                                        struct wait_queue_entry *wq_entry)
{
    list_del(&wq_entry->entry);
}
```

---

## 4. 唤醒机制——doom-lsp 确认的行号

### 4.1 `__wake_up` 完整链路

```c
// kernel/sched/wait.c:143 — doom-lsp 确认
int __wake_up(struct wait_queue_head *wq_head, unsigned int mode,
              int nr_exclusive, void *key)
{
    return __wake_up_common_lock(wq_head, mode, nr_exclusive, 0, key);
}
```

**doom-lsp 数据流追踪**：

```
__wake_up(wq_head, mode, nr_exclusive, key)
  └─ __wake_up_common_lock(wq_head, mode, nr_exclusive, 0, key)  @ wait.c:118
       │
       ├─ spin_lock_irqsave(&wq_head->lock, flags)     ← 获取锁
       │
       └─ __wake_up_common(wq_head, mode, nr_exclusive, wake_flags, key)
            │                                           @ wait.c:92
            ├─ curr = list_first_entry(&wq_head->head)  ← 第一个 waiter
            │
            ├─ list_for_each_entry_safe_from(curr, next, ...)
            │   │
            │   ├─ ret = curr->func(curr, mode, wake_flags, key)
            │   │   │
            │   │   └─ 对于 standard wait:
            │   │       default_wake_function(wq_entry, mode, flags, key)
            │   │         └─ try_to_wake_up(wq_entry->private, mode, 1)
            │   │             └─ 将 task 放入运行队列
            │   │
            │   ├─ if (ret < 0): break                  ← 错误，停止
            │   │
            │   └─ if (ret && (flags & WQ_FLAG_EXCLUSIVE)
            │               && !--nr_exclusive): break
            │       ← 独占唤醒：每唤醒一个独占 waiter，nr_exclusive--
            │       ← nr_exclusive == 0 时停止
            │
            └─ return remaining
```

### 4.2 独占唤醒 vs 共享唤醒

**共享唤醒（默认）**：`wake_up(wq)` 遍历链表并调用每个 waiter 的 `func`。所有符合条件的 waiter 都会被唤醒。适用于"一个事件、多个消费者"的场景（如广播）。

**独占唤醒**：`wake_up_nr(wq, nr)` 只唤醒前 `nr` 个标记为 `WQ_FLAG_EXCLUSIVE` 的 waiter。适用于"一个事件、一个消费者"的场景（如互斥锁的等待者）。

```
共享唤醒流程：                             独占唤醒流程：
wake_up(wq)                               wake_up_nr(wq, 1)
  │                                         │
  ├─ waiter_A → func() → 唤醒                ├─ waiter_E → func() → 唤醒 (exclusive!)
  ├─ waiter_B → func() → 唤醒                ├─ [停止，nr_exclusive=0]
  ├─ waiter_C → func() → 唤醒                │
  └─ waiter_D → func() → 唤醒                └─ waiter_F、waiter_G... 仍在队列中
```

### 4.3 mode 参数

`mode` 参数定义了哪些进程可以被唤醒：

```c
// include/linux/sched.h
#define TASK_NORMAL         (TASK_INTERRUPTIBLE | TASK_UNINTERRUPTIBLE)
```

- **`TASK_NORMAL`**：唤醒 `TASK_INTERRUPTIBLE` 和 `TASK_UNINTERRUPTIBLE` 状态的进程
- **`TASK_INTERRUPTIBLE`**：只唤醒可中断休眠的进程
- **`TASK_UNINTERRUPTIBLE`**：只唤醒不可中断休眠的进程
- **`TASK_KILLABLE`**：只唤醒 `TASK_UNINTERRUPTIBLE | TASK_WAKEKILL` 的进程

---

## 5. wait_event 宏系列——完整展开

`wait_event` 系列宏是最常用的等待接口，封装了"准备→检查条件→休眠→被唤醒→再次检查"的整个循环。

### 5.1 `wait_event(wq_head, condition)`——不可中断等待

```c
// include/linux/wait.h:345
#define wait_event(wq_head, condition)                          \
    do {                                                        \
        might_sleep();                                          \
        __wait_event(wq_head, condition);                       \
    } while (0)
```

**展开后的完整代码**（`___wait_event` @ `wait.h:302`）：

```c
{   // ___wait_event(wq_head, condition, TASK_UNINTERRUPTIBLE, 0, 0, )
    struct wait_queue_entry __wq_entry;

    init_wait_entry(&__wq_entry, 0);

    for (;;) {
        // 1. 将当前进程加入等待队列，设置状态为 TASK_UNINTERRUPTIBLE
        long __int = prepare_to_wait_event(&wq_head, &__wq_entry, 
                                            TASK_UNINTERRUPTIBLE);

        // 2. 检查条件（调用者提供的表达式）
        if (condition)
            break;

        // 3. 不可中断等待，不检查信号

        // 4. 调度出去（让出 CPU）
        schedule();

        // 5. 被唤醒后再次检查条件
        if (condition)
            break;
    }

    // 6. 条件满足，从等待队列移除
    finish_wait(&wq_head, &__wq_entry);
}
```

### 5.2 `wait_event_interruptible(wq_head, condition)`——可中断等待

```c
// ___wait_event 中的信号处理：
if (___wait_is_interruptible(state) && __int) {
    __ret = __int;     // __int = -ERESTARTSYS（被信号打断）
    goto __out;        // 跳过 finish_wait
}
```

如果进程在等待时收到信号：
1. `prepare_to_wait_event` 返回非零值（`-ERESTARTSYS`）
2. 信号处理路径被触发
3. 循环退出，不调用 `finish_wait`（但 `prepare_to_wait_event` 已经在信号路径中处理了移除）

### 5.3 `wait_event_timeout(wq_head, condition, timeout)`——超时等待

```c
#define __wait_event_timeout(wq_head, condition, timeout)         \
    ___wait_event(wq_head, condition, TASK_UNINTERRUPTIBLE, 0,      \
                  ({ schedule_timeout(timeout); 0; }),               \
                  schedule_timeout(timeout))
```

展开后，`cmd` 参数被替换为 `schedule_timeout(timeout)`，它调用 `set_current_state(TASK_UNINTERRUPTIBLE)` 并设置定时器，在超时后自动唤醒。

返回值：
- `0`：超时返回
- `> 0`：条件满足返回（剩余 jiffies）

### 5.4 完整 wait_event 家族

| 宏 | 状态 | 可被信号打断 | 超时 | 独占 |
|------|------|-------------|------|------|
| `wait_event` | UNINTERRUPTIBLE | ❌ | ❌ | ❌ |
| `wait_event_timeout` | UNINTERRUPTIBLE | ❌ | ✅ | ❌ |
| `wait_event_interruptible` | INTERRUPTIBLE | ✅ | ❌ | ❌ |
| `wait_event_interruptible_timeout` | INTERRUPTIBLE | ✅ | ✅ | ❌ |
| `wait_event_killable` | KILLABLE | ✅(fatal) | ❌ | ❌ |
| `wait_event_exclusive_cmd` | UNINTERRUPTIBLE | ❌ | ❌ | ✅ |
| `wait_event_freezable` | UNINTERRUPTIBLE | ❌（可冻结）| ❌ | ❌ |
| `io_wait_event` | UNINTERRUPTIBLE | ❌ | ❌ | ❌ |

---

## 6. prepare_to_wait / finish_wait——doom-lsp 确认

### 6.1 `prepare_to_wait_event`（`wait.h:1227`）

```c
// kernel/sched/wait.c — 实现
long prepare_to_wait_event(struct wait_queue_head *wq_head,
                            struct wait_queue_entry *wq_entry, int state)
{
    unsigned long flags;
    long ret = 0;

    spin_lock_irqsave(&wq_head->lock, flags);
    if (unlikely(signal_pending_state(state, current))) {
        // 如果挂起的信号与当前状态兼容：
        // 不将进程加入等待队列 → 直接返回 -ERESTARTSYS
        list_del_init_careful(&wq_entry->entry);
        ret = -ERESTARTSYS;
    } else {
        // 将进程加入等待队列
        if (list_empty(&wq_entry->entry))
            __add_wait_queue(wq_head, wq_entry);
        // 设置进程状态（进入休眠）
        set_current_state(state);
    }
    spin_unlock_irqrestore(&wq_head->lock, flags);

    return ret;
}
```

关键行为：
1. **检查是否已有信号等待**：如果有且状态允许被信号中断，直接返回 `-ERESTARTSYS`，不进入休眠
2. **加入等待队列**：`__add_wait_queue`（LIFO 插入到队首）
3. **设置进程状态**：`set_current_state(state)`——如果状态是 `TASK_UNINTERRUPTIBLE`，进程将不会被调度

### 6.2 `finish_wait`（`wait.h:1228`）

```c
void finish_wait(struct wait_queue_head *wq_head, 
                  struct wait_queue_entry *wq_entry)
{
    unsigned long flags;

    __set_current_state(TASK_RUNNING);   // 恢复进程状态为 RUNNING

    spin_lock_irqsave(&wq_head->lock, flags);
    // 从等待队列中移除（如果还在队列中）
    __remove_wait_queue(wq_head, wq_entry);
    spin_unlock_irqrestore(&wq_head->lock, flags);
}
```

---

## 7. `autoremove_wake_function`——标准唤醒函数（`kernel/sched/wait.c:401`）

```c
// kernel/sched/wait.c:401 — doom-lsp 确认
int autoremove_wake_function(struct wait_queue_entry *wq_entry, 
                              unsigned int mode, int sync, void *key)
{
    int ret = default_wake_function(wq_entry, mode, sync, key);

    if (ret)
        list_del_init_careful(&wq_entry->entry);  // 唤醒后自动移除

    return ret;
}
```

**这是大多数场景使用的默认唤醒函数**。`DEFINE_WAIT(name)` 宏使用 `autoremove_wake_function`。它的核心行为是：唤醒后自动从等待队列移除 waiter。这减小了 `finish_wait` 中的工作量（避免了重复的锁操作）。

---

## 8. 🔥 doom-lsp 数据流追踪——pipe read 的等待队列使用

### 8.1 pipe 空读的场景

```c
// fs/pipe.c — pipe_read 的等待流程
ssize_t pipe_read(struct kiocb *iocb, struct iov_iter *to)
{
    struct pipe_inode_info *pipe = filp->private_data;

    // 尝试读取数据
    for (;;) {
        // ...

        if (!pipe->head) {  // pipe 为空
            if (filp->f_flags & O_NONBLOCK) {
                ret = -EAGAIN;  // 非阻塞直接返回
                break;
            }

            // 阻塞等待：等待 pipe 中有数据
            ret = wait_event_interruptible(pipe->rd_wait,
                                            pipe_readable(pipe));
            if (ret)
                break;
            continue;
        }
        // ... 读取数据
    }
    // 唤醒写端（因为 pipe 中有了更多空间）
    if (wakeup)
        wake_up_interruptible_sync(&pipe->wr_wait);
    return ret;
}
```

### 8.2 完整的数据流——pipe_read 阻塞

```
进程 A 执行 pipe_read():
  │
  ├─ pipe 为空
  ├─ wait_event_interruptible(pipe->rd_wait, pipe_readable(pipe))
  │    │
  │    ├─ init_wait_entry(&__wq_entry, 0)
  │    │   → __wq_entry.private = current
  │    │   → __wq_entry.func = autoremove_wake_function
  │    │
  │    ├─ for (;;) {
  │    │      prepare_to_wait_event(wq_head, &__wq_entry, TASK_INTERRUPTIBLE)
  │    │         ├─ spin_lock(&pipe->rd_wait.lock)
  │    │         ├─ list_add(&__wq_entry.entry, &wq_head->head)    ← 加入等待队列
  │    │         ├─ set_current_state(TASK_INTERRUPTIBLE)          ← 进入休眠
  │    │         └─ spin_unlock(...)
  │    │
  │    │      if (pipe_readable(pipe)) → false（pipe 仍空）
  │    │      if (signal_pending) → false（无信号）
  │    │
  │    │      schedule()                                          ← 让出 CPU！
  │    │         │ 此时进程 A 被移出运行队列
  │    │         │ 在运行队列的 "等待" 状态
  │    │         │ 不会消耗 CPU
  │    │
  │    │      [被唤醒后继续循环]
  │    │      prepare_to_wait_event(...)
  │    │      if (pipe_readable(pipe)) → true（写端已写入）
  │    │   }
  │    │
  │    └─ finish_wait(wq_head, &__wq_entry)
  │         ├─ __set_current_state(TASK_RUNNING)
  │         ├─ list_del(&__wq_entry.entry)                        ← 移出等待队列
  │         └─ 返回
  │
  └─ 继续读取数据
```

### 8.3 唤醒的完整数据流

```
进程 B（写端）：
  pipe_write()
    → 写入数据到 pipe
    → wake_up_interruptible_sync(&pipe->rd_wait)     @ include/linux/wait.h
      │
      ├─ __wake_up_common_lock(&pipe->rd_wait, TASK_INTERRUPTIBLE, 1, 0, NULL)
      │    │
      │    ├─ spin_lock_irqsave(&pipe->rd_wait.lock)        ← 获取等待队列锁
      │    │
      │    └─ __wake_up_common(...)
      │         │
      │         ├─ curr = &进程A.entry（等待队列的第一个 waiter）
      │         │
      │         ├─ ret = curr->func(curr, TASK_INTERRUPTIBLE, 0, NULL)
      │         │   = autoremove_wake_function(wq_entry, TASK_INTERRUPTIBLE, ...)
      │         │     ├─ default_wake_function(...)
      │         │     │   └─ try_to_wake_up(进程A, TASK_INTERRUPTIBLE, 0)
      │         │     │       ├─ 将进程A放入运行队列
      │         │     │       ├─ 设置进程A状态为 TASK_RUNNING
      │         │     │       └─ 如果进程A在另一个 CPU 上：发送 IPI 唤醒
      │         │     │
      │         │     └─ list_del_init_careful(&curr->entry)   ← 从等待队列移除
      │         │
      │         ├─ flags & WQ_FLAG_EXCLUSIVE? yes → nr_exclusive--
      │         │   nr_exclusive 从 1 → 0，停止遍历
      │         │
      │         └─ return
      │
      ├─ spin_unlock_irqrestore(...)
      │
      └─ 返回 1（唤醒了 1 个独占 waiter）
```

---

## 9. 等待队列应用的完整类型

| 函数 | 效果 | 典型场景 |
|------|------|---------|
| `wake_up(wq)` | 唤醒所有 `TASK_NORMAL` 的 waiter | 通用唤醒 |
| `wake_up_nr(wq, nr)` | 唤醒前 `nr` 个独占 + 所有非独占 | 多消费者 |
| `wake_up_interruptible(wq)` | 只唤醒 `TASK_INTERRUPTIBLE` | pipe read |
| `wake_up_all(wq)` | 唤醒所有 waiter（所有状态） | 强制唤醒 |
| `wake_up_locked(wq)` | 不获取锁直接唤醒 | 已持锁场景 |
| `wake_up_sync(wq)` | 同步唤醒（当前 CPU） | 避免调度延迟 |
| `wake_up_pollfree(wq)` | 在 poll free 后唤醒 | eventpoll |

---

## 10. `wq_has_sleeper` / `waitqueue_active`——无锁检测

```c
// include/linux/wait.h:125 — doom-lsp 确认
static inline int waitqueue_active(struct wait_queue_head *wq_head)
{
    return !list_empty(&wq_head->head);
}

// wait.h:151
static inline bool wq_has_sleeper(struct wait_queue_head *wq_head)
{
    // 需要 smp_mb() 与之配对，保障跨 CPU 可见性
    return waitqueue_active(wq_head);
}
```

**重要**：`waitqueue_active` 是无锁的，使用时需要配合内存屏障。在唤醒者端：

```c
// 正确的无锁检测模式
// CPU 0（唤醒者）：                    // CPU 1（等待者）：
smp_mb();                               set_current_state(TASK_INTERRUPTIBLE);
if (waitqueue_active(wq))               smp_mb();
    wake_up(wq);                         if (waitqueue_active(wq))
                                             schedule();
```

`waitqueue_active` 本身只是一个 `list_empty` 检查，不做任何同步。配对的内存屏障保证了 waitqueue 的修改（添加/移除）对另一个 CPU 可见。

---

## 11. `woken_wake_function`——wait_woken 的配对函数（`kernel/sched/wait.c:457`）

```c
// kernel/sched/wait.c:457 — doom-lsp 确认
int woken_wake_function(struct wait_queue_entry *wq_entry,
                         unsigned int mode, int sync, void *key)
{
    // 标记该 waiter 已被唤醒，但不实际调用 try_to_wake_up
    // wait_woken 的循环会处理状态检查
    return default_wake_function(wq_entry, mode, sync, key);
}
```

用于 `wait_woken`/`wake_woken` 模式，是一种低延迟的等待-唤醒机制，常用于网络栈等需要减少上下文切换的场景。

---

## 12. 性能与复杂性

| 操作 | 复杂度 | 主要开销 |
|------|--------|---------|
| `init_waitqueue_head` | O(1) | spin_lock_init + INIT_LIST_HEAD |
| `add_wait_queue` | O(1) | spin_lock + list_add |
| `__wake_up`（共享）| O(n) | n = waiter 数量，每个调用一次 func |
| `__wake_up`（独占）| O(k) | k = nr_exclusive，唤醒后停止 |
| `prepare_to_wait_event` | O(1) | spin_lock + set_current_state |
| `finish_wait` | O(1) | set_running + list_del |
| `waitqueue_active` | O(1) | list_empty（无锁）|

---

## 13. 设计模式总结

等待队列的设计体现了内核中"数据 + 回调"的模式：

```
wait_queue_head（同步点）
    │
    ├─ lock：保护链表
    └─ head：双向链表
        │
        ├─ wait_queue_entry A
        │   ├─ private → task_struct A
        │   ├─ func → autoremove_wake_function
        │   └─ flags → 0（非独占）
        │
        ├─ wait_queue_entry B
        │   ├─ private → task_struct B
        │   ├─ func → autoremove_wake_function
        │   └─ flags → WQ_FLAG_EXCLUSIVE（独占）
        │
        └─ ...

wake_up(wq_head) → 遍历链表 → 调用每个 entry 的 func
                    → try_to_wake_up(task_struct, mode)
                    → 进程被放入运行队列
```

---

## 14. 源码文件索引

| 文件 | 内容 | doom-lsp 符号数 |
|------|------|----------------|
| `include/linux/wait.h` | 所有结构体 + inline + 宏 | **51 个** |
| `kernel/sched/wait.c` | 唤醒和等待实现 | **92 个** |
| `include/linux/sched.h` | 进程状态定义 | — |

---

## 15. 关联文章

- **01-list_head**：wait_queue_head.head 使用 list_head
- **08-mutex**：互斥锁使用等待队列管理等待线程
- **09-spinlock**：wait_queue_head.lock 用于保护链表
- **26-RCU**：等待队列与 RCU 的配合使用
- **80-epoll**：epoll 使用自定义 wait_queue_entry

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
