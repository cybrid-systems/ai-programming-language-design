# wait_queue — 内核等待队列深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/wait.h` + `kernel/sched/wait.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**wait_queue** 是内核线程/进程**阻塞等待事件**的核心机制，用于：
- 进程/线程同步
- I/O 完成通知
- 资源可用性等待

---

## 1. 核心数据结构

### 1.1 wait_queue_head — 等待队列头

```c
// include/linux/wait.h — wait_queue_head_t
struct wait_queue_head {
    spinlock_t              lock;           // 保护队列的自旋锁
    struct list_head         head;           // 等待者链表
};

typedef struct wait_queue_head wait_queue_head_t;
```

### 1.2 wait_queue_entry — 等待者条目

```c
// include/linux/wait.h — wait_queue_entry_t
struct wait_queue_entry {
    unsigned int            flags;          // WQ_FLAG_EXCLUSIVE 等
    void                  *private;       // 通常是当前 task_struct
    wait_queue_func_t       func;           // 唤醒函数
    struct list_head        entry;          // 接入队列
};

typedef struct wait_queue_entry wait_queue_entry_t;
```

---

## 2. 初始化

### 2.1 DECLARE_WAIT_QUEUE_HEAD — 静态声明

```c
// include/linux/wait.h
#define DECLARE_WAIT_QUEUE_HEAD(name) \
    struct wait_queue_head name = __WAIT_QUEUE_HEAD_INITIALIZER(name)

#define __WAIT_QUEUE_HEAD_INITIALIZER(name) {   \
    .lock       = __SPIN_LOCK_UNLOCKED(name.lock),  \
    .head       = LIST_HEAD_INIT(name.head),         \
}
```

### 2.2 init_waitqueue_head — 运行时初始化

```c
// kernel/sched/wait.c
void init_waitqueue_head(struct wait_queue_head *q)
{
    spin_lock_init(&q->lock);
    INIT_LIST_HEAD(&q->head);
}
```

---

## 3. 等待操作

### 3.1 prepare_to_wait — 添加到等待队列

```c
// kernel/sched/wait.c
void prepare_to_wait(struct wait_queue_head *q,
           struct wait_queue_entry *wq, int state)
{
    unsigned long flags;

    spin_lock_irqsave(&q->lock, flags);
    if (list_empty(&wq->entry))
        __add_wait_queue(q, wq);           // 添加到队列
    set_current_state(state);                 // 设置进程状态（TASK_RUNNING/TASK_INTERRUPTIBLE）
    spin_unlock_irqrestore(&q->lock, flags);
}
```

### 3.2 finish_wait — 从等待队列移除

```c
// kernel/sched/wait.c
void finish_wait(struct wait_queue_head *q,
         struct wait_queue_entry *wq)
{
    unsigned long flags;

    __set_current_state(TASK_RUNNING);       // 恢复状态

    spin_lock_irqsave(&q->lock, flags);
    if (!list_empty(&wq->entry))
        list_del_init(&wq->entry);          // 从队列移除
    spin_unlock_irqrestore(&q->lock, flags);
}
```

---

## 4. 唤醒操作

### 4.1 wake_up — 唤醒一个等待者

```c
// include/linux/wait.h
#define wake_up(x)                  __wake_up(x, TASK_NORMAL, 1, NULL)
#define wake_up_nr(x, nr)          __wake_up(x, TASK_NORMAL, nr, NULL)
#define wake_up_all(x)              __wake_up(x, TASK_ALL, 0, NULL)
#define wake_up_interruptible(x)     __wake_up(x, TASK_INTERRUPTIBLE, 1, NULL)
```

### 4.2 __wake_up — 核心唤醒函数

```c
// kernel/sched/wait.c
void __wake_up(struct wait_queue_head *q, unsigned int mode, int nr, void *key)
{
    spin_lock(&q->lock);
    // 遍历等待队列
    list_for_each_entry(wq, &q->head, entry) {
        if (wq->flags & WQ_FLAG_EXCLUSIVE) {
            // 互斥等待者：只唤醒一个
            if (nr > 0) {
                wq->func(wq, mode, 0, key);
                nr--;
            }
            break;
        } else {
            // 非互斥：唤醒所有
            wq->func(wq, mode, 0, key);
        }
    }
    spin_unlock(&q->lock);
}
```

---

## 5. 完整使用模式

```c
// 内核代码中使用等待队列：

wait_queue_head_t wq;
init_waitqueue_head(&wq);

// 等待者线程：
DEFINE_WAIT(wait);

prepare_to_wait(&wq, &wait, TASK_INTERRUPTIBLE);
if (!condition)
    schedule();                    // 睡眠
finish_wait(&wq, &wait);

// 唤醒者线程：
condition = true;
wake_up_interruptible(&wq);
```

---

## 6. 完整文件索引

| 文件 | 函数 |
|------|------|
| `include/linux/wait.h` | `DECLARE_WAIT_QUEUE_HEAD`、`prepare_to_wait`、`wake_up` |
| `kernel/sched/wait.c` | `init_waitqueue_head`、`__wake_up`、`finish_wait` |
