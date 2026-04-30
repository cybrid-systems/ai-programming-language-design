# completion — 内核完成量深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/completion.h` + `kernel/sched/completion.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**completion** 是内核的**一次性同步机制**，用于一个线程等待另一个线程完成某个操作：
- `wait_for_completion()`：阻塞等待
- `complete()` / `complete_all()`：唤醒等待者
- 与信号量的区别：**completion 默认阻塞，信号量默认非阻塞**

---

## 1. 核心数据结构

### 1.1 completion — 完成量

```c
// include/linux/completion.h — struct completion
struct completion {
    unsigned int                    done;  // 完成计数
    struct swait_queue_head        wait;  // 等待队列
};
```

**`done` 字段含义**：
| 值 | 含义 |
|----|------|
| 0 | 未完成，初始化状态 |
| 1 | 一次完成（`complete()`） |
| >1 | 多次 `complete()` |
| UINT_MAX | `complete_all()`，永久完成 |

---

## 2. 初始化

### 2.1 DECLARE_COMPLETION — 静态声明

```c
// include/linux/completion.h
#define DECLARE_COMPLETION(work) \
    struct completion work = COMPLETION_INITIALIZER(work)

#define COMPLETION_INITIALIZER(work) \
    { 0, __SWAIT_QUEUE_HEAD_INITIALIZER((work).wait) }
```

### 2.2 init_completion — 运行时初始化

```c
// include/linux/completion.h
static inline void init_completion(struct completion *x)
{
    x->done = 0;                       // 计数器归零
    init_swait_queue_head(&x->wait);   // 初始化等待队列
}
```

---

## 3. complete — 唤醒一个等待者

```c
// kernel/sched/completion.c — complete
void complete(struct completion *x)
{
    unsigned long flags;

    raw_spin_lock_irqsave(&x->wait.lock, flags);

    if (x->done != UINT_MAX)          // 如果不是 complete_all
        x->done++;                     // done++（解锁一个等待者）
    swake_up_locked(&x->wait, 1);     // 唤醒一个等待者

    raw_spin_unlock_irqrestore(&x->wait.lock, flags);
}
```

---

## 4. complete_all — 唤醒所有等待者

```c
// kernel/sched/completion.c — complete_all
void complete_all(struct completion *x)
{
    unsigned long flags;

    raw_spin_lock_irqsave(&x->wait.lock, flags);

    x->done = UINT_MAX;               // 永久设置为最大值
    swake_up_all_locked(&x->wait);    // 唤醒所有等待者

    raw_spin_unlock_irqrestore(&x->wait.lock, flags);
}
```

**重要**：使用 `complete_all()` 后，必须调用 `reinit_completion()` 才能重用：

```c
static inline void reinit_completion(struct completion *x)
{
    x->done = 0;                      // 重置计数器
}
```

---

## 5. wait_for_completion — 等待

### 5.1 do_wait_for_common

```c
// kernel/sched/completion.c — do_wait_for_common
static inline long __sched
do_wait_for_common(struct completion *x,
           long (*action)(long), long timeout, int state)
{
    if (!x->done) {
        DECLARE_SWAITQUEUE(wait);      // 声明等待队列条目

        do {
            if (signal_pending_state(state, current))
                return -ERESTARTSYS;

            __prepare_to_swait(&x->wait, &wait);  // 加入等待队列
            __set_current_state(state);           // 设置进程状态
            raw_spin_unlock_irq(&x->wait.lock);   // 解锁
            timeout = action(timeout);             // 调度（睡眠）
        } while (!x->done && timeout > 0);

        raw_spin_lock_irq(&x->wait.lock);
        __finish_swait(&x->wait, &wait);        // 从队列移除
    }

    return timeout ?: -ETIME;
}
```

### 5.2 wait_for_completion — 主接口

```c
// include/linux/completion.h
void wait_for_completion(struct completion *);
```

---

## 6. 典型使用模式

```c
// 线程 A（等待者）：
DECLARE_COMPLETION(done);

void thread_a(void)
{
    wait_for_completion(&done);         // 阻塞等待
    // 继续执行
}

// 线程 B（完成者）：
void thread_b(void)
{
    // ... 做工作 ...
    complete(&done);                    // 唤醒 A
}
```

---

## 7. 完整文件索引

| 文件 | 函数 |
|------|------|
| `include/linux/completion.h` | `struct completion`、`DECLARE_COMPLETION`、`init_completion` |
| `kernel/sched/completion.c` | `complete`、`complete_all`、`do_wait_for_common` |
