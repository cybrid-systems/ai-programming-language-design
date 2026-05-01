# 07-wait_queue — 等待队列深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**等待队列（wait_queue）** 是 Linux 内核中最底层的进程阻塞/唤醒机制。几乎所有需要阻塞等待的内核设施——信号量、mutex、completion、epoll、socket IO——底层都基于 wait_queue_head。

核心模型：消费者（等待者）加入队列并睡眠，生产者（唤醒者）改变条件后唤醒队列中的进程。

---

## 1. 核心结构

```c
struct wait_queue_head {
    spinlock_t          lock;
    struct list_head    head;          // 等待者链表
};

struct wait_queue_entry {
    unsigned int        flags;         // WQ_FLAG_EXCL
    void                *private;      // 当前 task_struct
    wait_queue_func_t   func;          // 唤醒回调（默认 autoremove_wake_function）
    struct list_head    entry;
};
```

---

## 2. 数据流

```
wait_event(wq, condition)
  ├─ if (condition) return
  ├─ DEFINE_WAIT(__wait)
  ├─ for (;;) {
  │      prepare_to_wait_event(&wq, &__wait, TASK_UNINTERRUPTIBLE)
  │      if (condition) break;
  │      schedule();
  │  }
  └─ finish_wait(&wq, &__wait)

wake_up(wq_head)
  └─ __wake_up(&wq, TASK_NORMAL, 1, NULL)
       └─ __wake_up_common(wq, mode, nr_exclusive, 0, key)
            └─ 遍历等待者，调用 ->func(wait, mode, flags, key)
                 └─ autoremove_wake_function → try_to_wake_up
```

---

*分析工具：doom-lsp（clangd LSP）*
