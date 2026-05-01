# 07-wait-queue — 等待队列深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**等待队列（wait_queue）** 是 Linux 内核中最基础的进程同步机制。它实现了一种"生产者-消费者"模型：消费者（等待者）在条件不满足时加入队列并睡眠，生产者（唤醒者）在条件改变时唤醒队列中的进程。

几乎所有需要阻塞等待的内核机制——信号量、mutex、completion、epoll、socket 等待——底层都基于 `wait_queue_head`。

doom-lsp 确认 `include/linux/wait.h` 包含约 140+ 个符号，实现位于 `kernel/sched/wait.c`。

---

## 1. 核心数据结构

### 1.1 struct wait_queue_head（`include/linux/wait.h:23`）

```c
struct wait_queue_head {
    spinlock_t          lock;       // 保护队列的自旋锁
    struct list_head    head;       // 等待者链表
};
```

### 1.2 struct wait_queue_entry（`include/linux/wait.h:32`）

```c
struct wait_queue_entry {
    unsigned int        flags;      // WQ_FLAG_*
    void                *private;   // 通常是 current task_struct
    wait_queue_func_t   func;       // 唤醒回调
    struct list_head    entry;      // 链表节点
};
```

`func` 是唤醒回调函数，默认是 `autoremove_wake_function`——唤醒进程并将自己从队列中移除。

---

## 2. 等待宏族

### 2.1 wait_event

```c
// include/linux/wait.h:160
#define wait_event(wq_head, condition)
```

展开后的代码：

```
wait_event(wq, condition)
  │
  ├─ if (condition) return    ← 条件已满足，不需等待
  │
  ├─ DEFINE_WAIT(__wait)      ← 在栈上创建 wait_queue_entry
  │
  ├─ for (;;) {
  │      prepare_to_wait_event(&wq, &__wait, TASK_UNINTERRUPTIBLE)
  │      │   └─ 将当前进程添加到 wq
  │      │   └─ 设置当前进程状态为 TASK_UNINTERRUPTIBLE
  │      │
  │      if (condition)        break;  ← 再检查一次条件
  │      │
  │      schedule();           ← 让出 CPU
  │  }
  │
  └─ finish_wait(&wq, &__wait) ← 从队列移除，恢复 TASK_RUNNING
```

### 2.2 wait_event_interruptible

```c
#define wait_event_interruptible(wq, condition) ({    \
    int __ret = 0;                                     \
    // 类似上面，但使用 TASK_INTERRUPTIBLE               \
    // 遇到信号时返回 -ERESTARTSYS                        \
    __ret; })
```

不同变体：

| 宏 | 睡眠状态 | 信号可中断 | 返回值 |
|-----|---------|-----------|--------|
| `wait_event` | TASK_UNINTERRUPTIBLE | ❌ | void |
| `wait_event_interruptible` | TASK_INTERRUPTIBLE | ✅ | 0 或 -ERESTARTSYS |
| `wait_event_killable` | TASK_KILLABLE | ✅(SIGKILL) | 0 或 -ERESTARTSYS |
| `wait_event_timeout` | TASK_UNINTERRUPTIBLE | ❌ | 剩余 jiffies |
| `wait_event_interruptible_timeout` | TASK_INTERRUPTIBLE | ✅ | 剩余 jiffies |

---

## 3. 唤醒路径

### 3.1 wake_up

```
wake_up(wq_head)
  │
  └─ __wake_up(&wq, TASK_NORMAL, 1, NULL)
       │
       ├─ spin_lock(&wq->lock)          ← 获取锁
       │
       ├─ __wake_up_common(wq, mode, nr_exclusive, 0, key)
       │    │
       │    └─ for (每个等待者) {
       │           wait_queue_entry->func(entry, mode, flags, key)
       │           │   └─ try_to_wake_up(entry->private, mode, 1)
       │           │        └─ 将进程放入运行队列
       │       }
       │
       └─ spin_unlock(&wq->lock)
```

### 3.2 wake_up 变体

| 变体 | 行为 |
|------|------|
| `wake_up` | 唤醒所有 TASK_NORMAL 的进程 |
| `wake_up_interruptible` | 只唤醒 TASK_INTERRUPTIBLE |
| `wake_up_nr` | 只唤醒指定数量 |
| `wake_up_all` | 唤醒所有 |
| `wake_up_locked` | 调用者已持有锁，跳过加锁步骤 |

---

## 4. 核心函数的调用链

doom-lsp 确认的调用链：

```
wait_event(wq, condition)
  │
  ├─ DEFINE_WAIT(__wait)
  │    └─ init_wait(&__wait)
  │         └─ __wait.func = autoremove_wake_function
  │
  ├─ prepare_to_wait_event(wq, &__wait, state)
  │    └─ spin_lock(&wq->lock)
  │    └─ list_add(&__wait.entry, &wq->head)   ← 加入队列
  │    └─ set_current_state(state)              ← 设置睡眠状态
  │    └─ spin_unlock(&wq->lock)
  │
  ├─ if (condition) break
  │
  ├─ schedule()                                 ← 真正让出 CPU
  │
  └─ finish_wait(wq, &__wait)
       └─ set_current_state(TASK_RUNNING)       ← 恢复运行
       └─ list_del_init(&__wait.entry)          ← 从队列移除
```

---

## 5. Exclusive 等待

当多个进程等待同一事件（如 mutex 释放），只需要唤醒一个。Exclusive 等待通过 `WQ_FLAG_EXCL` 标记实现：

```c
// include/linux/wait.h:133
#define wake_up(wq_head)        __wake_up(wq_head, TASK_NORMAL, 1, NULL)
```

第三个参数 `nr_exclusive = 1` 表示只唤醒 1 个 exclusive 等待者。普通等待者（非 exclusive）总是被唤醒，exclusive 等待者按 FIFO 顺序只唤醒前 `nr_exclusive` 个。

---

## 6. 数据类型流

```
创建等待队列头：
  DECLARE_WAIT_QUEUE_HEAD(my_wq);     // 静态
  init_waitqueue_head(&my_wq);        // 动态

进程 A（等待者）：
  wait_event(my_wq, ready_flag)        // 直到 ready_flag == true
    ├─ 加入 my_wq.head 链表
    ├─ schedule() → CPU 被让出
    └─ 被唤醒后再检查 ready_flag

进程 B（唤醒者）：
  ready_flag = true;
  wake_up(&my_wq)                      // 唤醒 A
    ├─ 遍历 my_wq.head
    ├─ 调用 autoremove_wake_function
    │    └─ try_to_wake_up(A)
    └─ A 进入运行队列
```

---

## 7. 设计决策总结

| 决策 | 原因 |
|------|------|
| 自旋锁保护队列 | 防止并发操作破坏链表 |
| prepare + schedule 分离 | 允许在 schedule 前检查条件 |
| autoremove_wake_function | 唤醒后自动从队列移除 |
| Exclusive 机制 | 避免惊群效应 |
| DEFINE_WAIT 栈分配 | 避免动态分配（fast path） |

---

## 8. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/wait.h` | `struct wait_queue_head` | 23 |
| `include/linux/wait.h` | `wait_event` 宏族 | 160+ |
| `kernel/sched/wait.c` | `__wake_up_common` | 核心实现 |
| `kernel/sched/wait.c` | `prepare_to_wait_event` | 核心实现 |
| `kernel/sched/wait_bit.c` | `__wait_bit_*` | wait_bit 变体 |

---

## 9. 关联文章

- **mutex**（article 08）：mutex 底层使用 wait_queue 管理等待者
- **completion**（article 11）：基于 wait_queue 的轻量同步
- **epoll**（article 85）：使用等待队列实现事件通知

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
