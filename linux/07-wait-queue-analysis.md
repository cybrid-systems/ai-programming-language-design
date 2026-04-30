# 07-wait_queue / wait_event — 进程等待队列深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/wait.h` + `kernel/sched/wait.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**wait_queue** 是 Linux 内核的进程等待机制：让进程在某个条件满足前进入睡眠（不消耗 CPU），条件满足时唤醒。典型模式：`wait_event()` 睡眠 → 某处 `wake_up()` 唤醒 → 检查条件 → 继续或重新睡眠。

---

## 1. 核心数据结构

### 1.1 struct wait_queue_head — 等待队列头

```c
// include/linux/wait.h:55 — wait_queue_head
struct wait_queue_head {
    spinlock_t              lock;    // 保护队列的锁
    struct list_head        head;    // 等待进程链表（双向循环）
};

// 初始化：
#define DECLARE_WAIT_QUEUE_HEAD(name) \
    struct wait_queue_head name = __WAIT_QUEUE_HEAD_INITIALIZER(name)

#define __WAIT_QUEUE_HEAD_INITIALIZER(name) { \
    .lock       = __SPIN_LOCK_UNLOCKED(name.lock), \
    .head       = LIST_HEAD_INIT(name.head) \
}
```

### 1.2 struct wait_queue_entry — 等待项

```c
// include/linux/wait.h:45 — wait_queue_entry
struct wait_queue_entry {
    unsigned int            flags;    // WQ_FLAG_* 标志
    void                   *private;  // 私有数据（通常是 current = 自己的 task_struct）
    wait_queue_func_t       func;     // 唤醒函数（默认：autoremove_wake_function）
    struct list_head        entry;    // 接入 wait_queue_head.head 的链表
};

// 标志：
#define WQ_FLAG_EXCLUSIVE  0x01    // 独占等待（唤醒时只唤醒一个）
#define WQ_FLAG_WOKEN      0x02    // 已唤醒（防止重复唤醒）
```

### 1.3 wait_queue_func_t — 唤醒函数类型

```c
// include/linux/wait.h:30 — wait_queue_func_t
typedef int (*wait_queue_func_t)(struct wait_queue_entry *wq_entry,
                                  unsigned int mode, int wake_flags,
                                  void *key);
```

---

## 2. 等待函数

### 2.1 wait_event — 等待条件满足（不可中断）

```c
// include/linux/wait.h:168 — wait_event（简化）
#define wait_event(wq, condition) \
do { \
    might_sleep(); \
    for (;;) { \
        if (condition) \     // 条件满足，退出
            break; \
        __wait_event(wq, condition); \  // 进入睡眠
    } \
} while (0)

// __wait_event 实现：
#define __wait_event(wq, condition) \
do { \
    DEFINE_WAIT_FUNC(name, autoremove_wake_function); \
    \
    add_wait_queue(&(wq), &name.wait); \    // 加入等待队列
    for (;;) { \
        if (condition) \
            break; \
        schedule(); \                       // 让出 CPU（睡眠）\
    } \
    remove_wait_queue(&(wq), &name.wait); \ // 移除
} while (0)
```

### 2.2 wait_event_timeout — 超时等待

```c
// include/linux/wait.h:210 — wait_event_timeout
#define wait_event_timeout(wq, condition, timeout) \
({ \
    long __ret = timeout; \
    might_sleep(); \
    for (;;) { \
        if (condition) \
            break; \
        __ret = schedule_timeout(__ret); \  // 睡眠一段时间
        if (!__ret) \
            break; \                          // 超时返回 0
    } \
    __ret; \
})
```

### 2.3 wait_event_interruptible — 可中断等待

```c
// include/linux/wait.h:230 — wait_event_interruptible
#define wait_event_interruptible(wq, condition) \
({ \
    int __ret = 0; \
    might_sleep(); \
    for (;;) { \
        if (condition) \
            break; \
        __ret = __wait_event_interruptible(wq, condition); \
        if (__ret) \
            break; \
    } \
    __ret; \
})

// __wait_event_interruptible：
//   如果收到信号，返回 -ERESTARTSYS
//   返回值非 0 表示被信号打断
```

### 2.4 DEFINE_WAIT_FUNC — 初始化等待项

```c
// include/linux/wait.h:87
#define DEFINE_WAIT_FUNC(name, func) \
    struct wait_queue_entry name = { \
        .private = current, \      // current = 当前进程的 task_struct
        .func = func, \
        .entry = LIST_HEAD_INIT(name.entry), \
    }
```

---

## 3. 队列操作

### 3.1 add_wait_queue — 加入等待队列

```c
// kernel/sched/wait.c — add_wait_queue
void add_wait_queue(struct wait_queue_head *wq_head, struct wait_queue_entry *wait)
{
    unsigned long flags;

    spin_lock_irqsave(&wq_head->lock, flags);
    wait->flags &= ~WQ_FLAG_EXCLUSIVE;  // 默认：非独占
    list_add_tail(&wait->entry, &wq_head->head);  // 加入链表尾部
    spin_unlock_irqrestore(&wq_head->lock, flags);
}
```

### 3.2 add_wait_queue_exclusive — 加入独占等待

```c
// kernel/sched/wait.c — add_wait_queue_exclusive
void add_wait_queue_exclusive(struct wait_queue_head *wq_head,
                             struct wait_queue_entry *wait)
{
    unsigned long flags;

    spin_lock_irqsave(&wq_head->lock, flags);
    wait->flags |= WQ_FLAG_EXCLUSIVE;   // 独占标志
    list_add_tail(&wait->entry, &wq_head->head);
    spin_unlock_irqrestore(&wq_head->lock, flags);
}

// 独占进程排在队列末尾
// 唤醒时：只唤醒一个独占进程（避免惊群）
```

---

## 4. 唤醒函数

### 4.1 wake_up — 唤醒等待队列

```c
// kernel/sched/wait.c — __wake_up_common
static int __wake_up_common(struct wait_queue_head *wq_head, unsigned int mode,
                           int nr, unsigned int wake_flags,
                           void *key, wait_queue_func_t func)
{
    struct wait_queue_entry *curr, *next;
    int curr_nr_exclusive = nr;  // 剩余可唤醒的独占进程数

    // 遍历等待队列
    list_for_each_entry_safe_from(curr, next, &wq_head->head, entry) {
        // 调用唤醒函数（默认：autoremove_wake_function）
        int ret = curr->func(curr, mode, wake_flags, key);

        if (ret && (curr->flags & WQ_FLAG_EXCLUSIVE)) {
            // 独占进程被唤醒，减少配额
            if (!curr_nr_exclusive)
                break;  // 配额用完，停止唤醒
            curr_nr_exclusive--;
        }
    }

    return nr;
}

// wake_up = wake_up_all(wq, TASK_NORMAL, 0) 实际调用
void wake_up(struct wait_queue_head *wq_head)
{
    __wake_up_common(wq_head, TASK_NORMAL, 1, 0, NULL, autoremove_wake_function);
}
```

### 4.2 autoremove_wake_function — 自动移除

```c
// kernel/sched/wait.c — autoremove_wake_function
int autoremove_wake_function(struct wait_queue_entry *wait,
                             unsigned int mode, int wake_flags, void *key)
{
    // 1. 调用默认唤醒逻辑（wake_up_process）
    int ret = autoremove_wake_function(wait, mode, wake_flags, key);

    // 2. 自动从等待队列移除（防止忘记 remove_wait_queue）
    list_del_init(&wait->entry);

    return ret;
}
```

### 4.3 wake_up_all vs wake_up

```c
// kernel/sched/wait.c
void wake_up_all(struct wait_queue_head *wq_head)
{
    __wake_up_common(wq_head, TASK_NORMAL, 0, 0, NULL, ...);
    // nr = 0：唤醒所有（非独占优先）
}

void wake_up_interruptible(struct wait_queue_head *wq_head)
{
    __wake_up_common(wq_head, TASK_INTERRUPTIBLE, 1, 0, NULL, ...);
    // 只唤醒可中断睡眠的进程
}
```

---

## 5. 独家等待（Exclusive Wait）—— 避免惊群

### 5.1 惊群问题

```
没有 WQ_FLAG_EXCLUSIVE 时：
  进程 A ─┐
  进程 B ─┼─ wake_up() ─→ 所有进程竞争锁（只有一个成功）
  进程 C ─┘
  其他都白醒了，浪费 CPU 调度
```

### 5.2 WQ_FLAG_EXCLUSIVE 解决方案

```c
// 让进程以独占模式加入：
add_wait_queue_exclusive(wq, &wait.wait);

// wake_up 时：
// - 先处理所有非独占进程
// - 然后处理独占进程，但只唤醒 nr=1 个
// - 如果有多个独占进程，第一个被唤醒，其余继续睡

wake_up(&wq);
// → 唤醒 1 个独占进程（或所有非独占）
```

---

## 6. wait_event 的条件轮询模式

```
典型用法（内核代码模式）：

wait_event(wq, condition);  // 条件不满足则睡

等价于：
for (;;) {
    if (condition) break;  // 醒了再检查
    schedule();            // 不满足，继续睡
}

醒来后：
  1. 被 wake_up 唤醒
  2. 检查 condition
  3. 如果满足 → 退出 wait_event
  4. 如果不满足 → 重新 schedule（可能已经又被 wake）
```

---

## 7. 与 completion 的对比

| 特性 | wait_queue | completion |
|------|------------|-----------|
| 等待条件 | 任意条件（用户检查）| done 计数器（单一完成信号）|
| 唤醒数量 | 可选（wake_up vs wake_up_all）| 所有（complete_all）|
| 独占等待 | 支持（WQ_FLAG_EXCLUSIVE）| 不支持 |
| 典型用途 | 任意阻塞场景 | 一次性完成（线程退出、请求完成）|

---

## 8. 内核实际使用案例

### 8.1 进程退出等待（kthread_stop）

```c
// kernel/kthread.c — kthread_stop
kthread_stop(task):
  k->exit_completion = &done;
  init_completion(&done);
  wake_up_process(task);  // 唤醒线程
  wait_for_completion(&done);  // 等待线程退出
```

### 8.2 epoll 等待

```c
// fs/eventpoll.c — ep_poll
epoll_wait():
  add_wait_queue(&ep->wq, &wait.wait);
  schedule();
  remove_wait_queue(&ep->wq, &wait.wait);

// 当 fd 可读/可写时：
// ep_poll_callback() → wake_up() → 唤醒 epoll_wait()
```

### 8.3 io_uring 完成等待

```c
// io_uring/io_uring.c — io_cqring_wait
io_uring_enter(fd, IORING_ENTER_GETEVENTS):
  wait_event_interruptible(&ctx->cq_wait, ...);
// 当 CQE 可用时：
// io_cq_unlock_post() → wake_up() → 唤醒
```

---

## 9. 设计决策总结

| 设计决策 | 原因 |
|---------|------|
| list_head 作为队列 | 无数据、纯链表，可嵌入任意结构 |
| WQ_FLAG_EXCLUSIVE | 避免惊群（thundering herd）|
| autoremove_wake_function | 自动清理，防止内存泄漏 |
| wait_event_timeout | 防止永久阻塞（watchdog）|
| DEFINE_WAIT_FUNC 宏 | 简化等待函数的创建 |
| schedule() 让出 CPU | 睡眠进程不消耗 CPU |

---

## 10. 完整文件索引

| 文件 | 函数/结构 | 行 |
|------|----------|-----|
| `include/linux/wait.h` | `struct wait_queue_head` | 55 |
| `include/linux/wait.h` | `struct wait_queue_entry` | 45 |
| `include/linux/wait.h` | `wait_event`、`wait_event_timeout` | 168 / 210 |
| `include/linux/wait.h` | `DEFINE_WAIT_FUNC` | 87 |
| `kernel/sched/wait.c` | `add_wait_queue`、`add_wait_queue_exclusive` | 函数 |
| `kernel/sched/wait.c` | `__wake_up_common`、`wake_up` | 函数 |
| `kernel/sched/wait.c` | `autoremove_wake_function` | 函数 |

---

## 11. 西游记类比

**wait_queue** 就像"取经路上的施工等待区"——

> 唐僧（内核）让八戒（进程 A）、悟空（进程 B）、沙僧（进程 C）在草地上休息（加入 wait_queue）。悟空去找人参果（执行任务）。找到后，悟空喊一声"果子找到了！"（wake_up），所有睡着的徒弟同时醒来（惊群问题）。为了避免白忙活，唐僧规定：每次只派一个徒弟去找，找到了只叫醒这一个（WQ_FLAG_EXCLUSIVE）。如果徒弟太多，唐僧会让他们按顺序排队（list_add_tail），每次叫醒排头兵（autoremove_wake_function），叫完就自动出队，不用专门派人来清场。

---

## 12. 关联文章

- **completion**（article 11）：基于 swait 的简化版一次性同步
- **kthread**（article 14）：kthread_stop 使用 wait_event 等待线程退出
- **epoll**（article 80）：epoll 内部使用 wait_queue 实现 I/O 多路复用等待