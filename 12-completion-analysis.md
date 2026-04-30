# Linux Kernel completion 一次性完成信号 — 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/completion.h` + `kernel/sched/completion.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 更新：整合 2026-04-24 学习笔记

---

## 0. 什么是 completion？

**completion** 是内核最简洁的一次性同步原语——一个任务等待另一个任务"完成"一次，之后自动唤醒。

**核心设计哲学**："生产者和消费者都只需要两个函数"
- 等待者：`wait_for_completion()`
- 生产者：`complete()` 或 `complete_all()`

---

## 1. 核心数据结构

```c
// include/linux/completion.h:26 — Linux 7.0
struct completion {
    unsigned int done;              // 0=未完成，>0=已完成（支持多次 complete）
    struct swait_queue_head wait;   // 等待队列（复用 swait — sleeping wait queue）
};

#define COMPLETION_INITIALIZER(work) \
    { .done = 0, .wait = __SWAIT_QUEUE_HEAD_INITIALIZER((work).wait) }

#define DECLARE_COMPLETION(work) \
    struct completion work = COMPLETION_INITIALIZER(work)
```

**注意**：Linux 7.0 的 completion 使用 `swait_queue_head`（sleeping wait queue），而不是 `wait_queue_head`。这是 RT-MUTEX 架构的一部分，用于支持优先级继承。

---

## 2. 等待流程

```c
// kernel/sched/completion.c:151 — wait_for_completion
void __sched wait_for_completion(struct completion *x)
{
    wait_for_common(x, MAX_SCHEDULE_TIMEOUT, TASK_UNINTERRUPTIBLE);
}

// kernel/sched/completion.c:85 — do_wait_for_common
static inline long
do_wait_for_common(struct completion *x,
                   int (*condition)(void *),  // 检查 done > 0
                   unsigned long timeout)
{
    if (!condition())
        __schedule();   // 睡眠，直到被唤醒
    return timeout - len;
}
```

**等待状态机**：
```
done = 0:
  wait_for_completion()
    → condition() 返回 false
    → __schedule() 睡眠

done > 0:
  wait_for_completion()
    → condition() 返回 true
    → 立即返回（不睡眠）
```

---

## 3. 完成流程

```c
// kernel/sched/completion.c:50 — complete（唤醒一个）
void complete(struct completion *x)
{
    complete_with_flags(x, 0);
}

// kernel/sched/completion.c:21 — complete_with_flags
static void complete_with_flags(struct completion *x, int wake_flags)
{
    unsigned long flags;
    raw_spin_lock_irqsave(&x->wait.lock, flags);

    if (x->done != UINT_MAX)    // 检查是否已 complete_all
        x->done++;              // done++
    swake_up_locked(&x->wait, wake_flags);  // 唤醒一个
    raw_spin_unlock_irqrestore(&x->wait.lock, flags);
}

// kernel/sched/completion.c:72 — complete_all（唤醒全部）
void complete_all(struct completion *x)
{
    unsigned long flags;

    lockdep_assert_RT_in_threaded_ctx();   // RT 下必须在线程上下文

    raw_spin_lock_irqsave(&x->wait.lock, flags);
    x->done = UINT_MAX;   // 设为最大值，所有后续 wait 都立即返回
    swake_up_all_locked(&x->wait);   // 唤醒全部
    raw_spin_unlock_irqrestore(&x->wait.lock, flags);
}
```

---

## 4. complete vs complete_all

| 特性 | `complete()` | `complete_all()` |
|------|-------------|-----------------|
| done 变化 | `done++` | `done = UINT_MAX` |
| 唤醒数量 | 1 个等待者 | **所有**等待者 |
| 后续 wait | 如果还有等待者，继续阻塞 | 所有 wait 立即返回 |
| 典型场景 | 一次性的"等一次" | 需要所有等待者都完成的场景 |
| 可重用 | 可配合 `reinit_completion()` | 必须 `reinit_completion()` 才能重用 |

---

## 5. 真实内核使用案例

### 5.1 模块加载（`kernel/module.c`）

```c
// module loading — 主线程等待模块初始化完成
static int load_module(struct load_info *info, const char __user *uargs)
{
    struct completion static_call_done;
    DECLARE_COMPLETION(done);

    init_completion(&done);
    // 异步初始化线程完成后调用 complete(&done)
    wait_for_completion(&done);
}
```

### 5.2 kthread（`kernel/kthread.c`）

```c
// kthread 等待创建完成
struct task_struct *kthread_create_on_node(...);
kthread_bind(p, cpu);
wake_up_process(p);
    // 等待者：kthread_stop()
    // complete() 在 kthread 中调用
```

---

## 6. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| `done` 用 `unsigned int` | 原子递增简单，`UINT_MAX` 可作为 "infinite" 标记 |
| `swait_queue_head` 替代 `wait_queue_head` | RT-MUTEX 优先级继承需要，支持 PI |
| `complete()` 只唤醒一个 | "一次性"语义：只通知一个等待者 |
| `complete_all()` 唤醒所有 | 多个消费者必须全部通知 |
| `reinit_completion()` | `complete_all` 后必须重置才能重用 |

---

## 7. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/completion.h` | `struct completion`、宏定义 |
| `kernel/sched/completion.c` | `complete`、`wait_for_completion`、`do_wait_for_common` |
| `include/linux/swait.h` | `swait_queue_head`（sleeping wait queue）|
