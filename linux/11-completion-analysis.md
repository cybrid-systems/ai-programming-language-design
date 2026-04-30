# 11-completion — 一次性完成信号量深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/completion.h` + `kernel/sched/completion.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**completion** 是 Linux 内核的"一次性同步原语"：一个线程等待另一个线程完成某个操作（一次性，不可重用）。典型场景：线程退出同步（kthread_stop）、设备驱动请求-完成。

---

## 1. 核心数据结构

### 1.1 struct completion — 完成结构

```c
// include/linux/completion.h:26 — completion
struct completion {
    unsigned int            done;      // 完成计数（0=未完成，>0=已完成）
    wait_queue_head_t       wait;     // 等待队列
};

// 初始化宏：
#define DECLARE_COMPLETION(name) \
    struct completion name = { .done = 0, .wait = __WAIT_QUEUE_HEAD_INITIALIZER(name.wait) }

// 动态初始化：
static inline void init_completion(struct completion *x)
{
    x->done = 0;
    init_waitqueue_head(&x->wait);
}
```

---

## 2. wait_for_completion — 等待完成

### 2.1 wait_for_completion

```c
// kernel/sched/completion.c — wait_for_completion
void wait_for_completion(struct completion *x)
{
    // 快速路径：done > 0 时直接返回（自旋）
    do {
        if (x->done > 0)
            return;
        wait_for_common(x, MAX_SCHEDULE_TIMEOUT, TASK_UNINTERRUPTIBLE);
    } while (!x->done);
}
```

### 2.2 wait_for_common — 通用等待

```c
// kernel/sched/completion.c — wait_for_common
static long wait_for_common(struct completion *x, unsigned long timeout, int state)
{
    struct wait_queue_entry wait;

    // 1. 快速路径：done > 0 直接返回
    if (x->done > 0)
        return timeout;

    // 2. 加入等待队列
    init_wait_entry(&wait, current);

    for (;;) {
        if (x->done > 0)
            break;  // 已完成，退出

        if (signal_pending_state(state, current))
            break;  // 被信号打断

        // 让出 CPU
        timeout = schedule_timeout(timeout);
        if (!timeout)
            break;  // 超时
    }

    finish_wait(&x->wait, &wait);
    return timeout;
}
```

### 2.3 wait_for_completion_timeout — 超时版本

```c
// include/linux/completion.h — wait_for_completion_timeout
static inline unsigned long wait_for_completion_timeout(struct completion *x, unsigned long timeout)
{
    return wait_for_common(x, timeout, TASK_UNINTERRUPTIBLE);
}
```

### 2.4 wait_for_completion_interruptible — 可中断版本

```c
// include/linux/completion.h — wait_for_completion_interruptible
static inline long wait_for_completion_interruptible_timeout(struct completion *x, unsigned long timeout)
{
    return wait_for_common(x, timeout, TASK_INTERRUPTIBLE);
}
```

---

## 3. complete — 发送完成信号

### 3.1 complete — 单次完成

```c
// kernel/sched/completion.c — complete
void complete(struct completion *x)
{
    unsigned long flags;

    raw_spin_lock_irqsave(&x->wait.lock, flags);

    // 增加 done 计数
    x->done++;

    // 唤醒所有等待者
    wake_up_all_no_lock(&x->wait);

    raw_spin_unlock_irqrestore(&x->wait.lock, flags);
}
```

### 3.2 complete_all — 标记永久完成

```c
// kernel/sched/completion.c — complete_all
void complete_all(struct completion *x)
{
    unsigned long flags;

    raw_spin_lock_irqsave(&x->wait.lock, flags);

    // done = UINT_MAX 表示永久完成
    // 后续任何 wait_for_completion 都立即返回
    x->done = UINT_MAX;

    // 唤醒所有等待者
    wake_up_all_no_lock(&x->wait);

    raw_spin_unlock_irqrestore(&x->wait.lock, flags);
}
```

---

## 4. reinit_completion — 重新初始化

```c
// include/linux/completion.h:47 — reinit_completion
static inline void reinit_completion(struct completion *x)
{
    x->done = 0;  // 重置计数器（不能用 complete_all）
}
```

---

## 5. 流程图

```
线程 A（等待者）：
  init_completion(&done);
  wait_for_completion(&done);
  ↓
  (睡眠在 wait_queue)
  ↓
  被 wake_up 唤醒
  ↓
  检查 done > 0
  ↓
  继续执行


线程 B（完成者）：
  ... 做完了 ...
  complete(&done);   // done++
  ↓
  wake_up_all(&done->wait)
  ↓
  唤醒所有等待者
```

---

## 6. completion vs semaphore 对比

| 特性 | completion | semaphore |
|------|-----------|-----------|
| 语义 | 一次性完成 | 计数资源 |
| done 计数 | 单调递增 | 可增可减 |
| 等待者唤醒 | 全部（complete）| 由计数决定 |
| 重置 | reinit_completion | V 操作 |
| 典型用途 | 线程退出、请求完成 | 资源计数 |

---

## 7. 内核实际使用案例

### 7.1 kthread_stop

```c
// kernel/kthread.c — kthread_stop
int kthread_stop(struct task_struct *k)
{
    struct completion done;

    // 1. 初始化 completion
    init_completion(&done);
    k->exit_completion = &done;

    // 2. 设置停止标志
    k->should_stop = 1;

    // 3. 唤醒线程（如果正在睡眠）
    wake_up_process(k);

    // 4. 等待线程退出
    wait_for_completion(&done);  // 线程调用 complete() 时唤醒

    return 0;
}

// kthread 线程函数结束时：
void __noreturn kthread_exit(long result)
{
    complete(k->exit_completion);  // 唤醒 kthread_stop
    do_exit(result);
}
```

### 7.2 device driver 请求-完成

```c
// 驱动发起异步请求：
init_completion(&dev->done);
queue_request(dev->req);
wait_for_completion_timeout(&dev->done, HZ);  // 最多等 1 秒

// 中断处理程序：
irq_handler() {
    complete(&dev->done);  // 请求完成，唤醒等待者
}
```

---

## 8. 设计决策总结

| 设计决策 | 原因 |
|---------|------|
| done 计数器 | 支持多次 complete（每个 complete 唤醒一次）|
| complete_all 设置 UINT_MAX | 永久标记，避免遗漏 |
| swait 队列 | 比完整 wait_queue 更轻量（用于短时等待）|
| 自旋快速路径 | done > 0 时无需调度，零开销 |

---

## 9. 完整文件索引

| 文件 | 函数/结构 | 行 |
|------|----------|-----|
| `include/linux/completion.h` | `struct completion` | 26 |
| `include/linux/completion.h` | `init_completion` | 24 |
| `include/linux/completion.h` | `DECLARE_COMPLETION` | 52 |
| `kernel/sched/completion.c` | `wait_for_completion` | 函数 |
| `kernel/sched/completion.c` | `wait_for_common` | 函数 |
| `kernel/sched/completion.c` | `complete` | 函数 |
| `kernel/sched/completion.c` | `complete_all` | 函数 |

---

## 10. 西游记类比

**completion** 就像"取经队伍的任务完成表"——

> 唐僧（等待者）发起一个任务（比如"悟空去找水"），在任务表上登记（init_completion）。悟空去执行任务，悟空走了之后（schedule），唐僧就在旁边等着（wait_for_completion）。等悟空找到水回来，在任务表上打勾（complete），然后叫醒唐僧（wake_up_all）。唐僧检查任务完成了，就继续取经。如果唐僧用的是 complete_all（永久完成），那这个任务表就被永久封存了，以后任何人都不用再做了。

---

## 11. 关联文章

- **wait_queue**（article 07）：completion 底层使用 wait_queue
- **kthread**（article 14）：kthread_stop 使用 completion 同步