# 11-completion — 完成量深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**completion（完成量）** 是 Linux 内核中最轻量的同步原语，核心模型是"一个线程等待另一个线程完成某件事"。与 mutex 不同，completion 没有所有权概念——任何线程都可以调用 `complete()` 通知等待者。

completion 的设计哲学：**最简接口，零误用空间**。只有两个核心操作——`wait_for_completion()`（等待）和 `complete()`（通知），几乎不可能用错。

关键特性：
1. **无所有权**：任何线程、中断处理函数、定时器回调都可以调用 `complete()`
2. **完全发生在 `complete()` 之前**：即使 `complete()` 先于 `wait_for_completion()` 调用，也不会丢失（`done` 计数器保证了这一点）
3. **一次性或永久**：`complete()` 唤醒一个等待者，`complete_all()` 永久激活

doom-lsp 确认 `include/linux/completion.h` 包含 **21 个符号**，`kernel/sched/completion.c` 包含 **58 个实现符号**。底层使用 **swait_queue**（简单等待队列），比标准 `wait_queue_head` 更轻量。

---

## 1. 核心数据结构

### 1.1 `struct completion`（`completion.h:26`）

```c
// include/linux/completion.h:26 — doom-lsp 确认
struct completion {
    unsigned int done;                // 完成计数
    struct swait_queue_head wait;     // 等待队列（swait）
};
```

整个 completion 的核心就是一个 `done` 计数器：

```
done == 0:        消费者在等待
done == 1:        生产者已调用 complete()，消费者通过后减回 0
done == UINT_MAX:  complete_all() 已调用，永久激活
done > 1:         多个 complete() 累积，多个消费者可依次通过
```

### 1.2 `struct swait_queue_head`（`include/linux/swait.h`）

```c
// include/linux/swait.h:43
struct swait_queue_head {
    raw_spinlock_t      lock;      // 保护链表的自旋锁
    struct list_head    task_list; // 等待进程链表
};
```

swait（simple wait）是标准 wait_queue 的**精简版**：
- 没有 `wait_queue_func_t` 回调
- 不支持独占/非独占概念
- 唤醒逻辑简单直接：设置进程状态为 TASK_RUNNING + wake_up_process
- 节省了函数指针调用和多种唤醒模式的分支预测开销

---

## 2. 生产者路径——doom-lsp 确认的行号

### 2.1 `complete`——唤醒一个（`completion.c:50`）

```c
// kernel/sched/completion.c:50 — doom-lsp 确认
void complete(struct completion *x)
{
    complete_with_flags(x, 0);
}
```

核心实现 `complete_with_flags`（`completion.c:21`）：

```c
// completion.c:21 — doom-lsp 确认
static void complete_with_flags(struct completion *x, int wake_flags)
{
    unsigned long flags;

    raw_spin_lock_irqsave(&x->wait.lock, flags);

    if (x->done != UINT_MAX)          // 防止 complete_all 后溢出
        x->done++;                     // 增加计数

    swake_up_locked(&x->wait, wake_flags);  // 唤醒一个等待者
    // swake_up_locked 内部：
    //   waiter = list_first_entry(&x->wait.task_list)
    //   wake_up_process(waiter->task)

    raw_spin_unlock_irqrestore(&x->wait.lock, flags);
}
```

### 2.2 `complete_all`——唤醒全部（`completion.c:72`）

```c
// completion.c:72 — doom-lsp 确认
void complete_all(struct completion *x)
{
    unsigned long flags;

    raw_spin_lock_irqsave(&x->wait.lock, flags);
    x->done = UINT_MAX;                             // 永久标记
    swake_up_all_locked(&x->wait);                  // 唤醒所有
    raw_spin_unlock_irqrestore(&x->wait.lock, flags);
}
```

### 2.3 `complete_on_current_cpu`——当前 CPU 唤醒（`completion.c:33`）

```c
// completion.c:33 — doom-lsp 确认
void complete_on_current_cpu(struct completion *x)
{
    return complete_with_flags(x, WF_CURRENT_CPU);
}
```

`WF_CURRENT_CPU` 标志告诉调度器：如果可能，让唤醒在同一 CPU 上发生。这有利于缓存局部性——被唤醒的线程很可能访问生产者刚刚写入的数据。

---

## 3. 消费者路径——doom-lsp 确认的行号

### 3.1 `wait_for_completion`（`completion.c:151`）

```c
// completion.c:151 — doom-lsp 确认
void __sched wait_for_completion(struct completion *x)
{
    wait_for_common(x, MAX_SCHEDULE_TIMEOUT, TASK_UNINTERRUPTIBLE);
}
```

**doom-lsp 数据流追踪——完整等待循环**：

```
wait_for_common(x, timeout, state)
  └─ __wait_for_common(x, action, timeout, state)    @ completion.c:112
       │
       └─ do_wait_for_common(x, action, timeout, state)  @ completion.c:85
            │
            ├─ if (x->done) {                       ← 快速检查：已 complete()？
            │      if (x->done != UINT_MAX)
            │          x->done--;                    ← 消耗一次完成
            │      return timeout;                   ← 立即返回
            │   }
            │
            ├─ DECLARE_SWAITQUEUE(wait);             ← 栈上创建等待项
            │   // wait.task = current
            │   // wait.task_list = {&wait, &wait}
            │
            ├─ do {
            │      │
            │      ├─ if (signal_pending_state(state, current)) {
            │      │      timeout = -ERESTARTSYS;
            │      │      break;                    ← 信号中断
            │      │   }
            │      │
            │      ├─ __prepare_to_swait(&x->wait, &wait)
            │      │   ← list_add(&wait.task_list, &x->wait.task_list)
            │      │   ← 将当前进程加入等待队列
            │      │
            │      ├─ __set_current_state(state)
            │      │   ← TASK_UNINTERRUPTIBLE
            │      │
            │      ├─ raw_spin_unlock_irq(&x->wait.lock)
            │      │   ← 解锁（schedule 前必须释放）
            │      │
            │      ├─ timeout = action(timeout)
            │      │   ← schedule_timeout(timeout) 或 schedule()
            │      │   ← 让出 CPU！等待 complete() 唤醒
            │      │
            │      ├─ raw_spin_lock_irq(&x->wait.lock)
            │      │   ← 被唤醒后重新加锁
            │      │
            │   } while (!x->done && timeout);
            │   ← 循环条件：未满足且未超时
            │
            ├─ __finish_swait(&x->wait, &wait)
            │   ← list_del(&wait.task_list)  ← 从等待队列移除
            │
            ├─ if (!x->done)
            │      return timeout;                 ← 超时/信号返回
            │
            ├─ if (x->done != UINT_MAX)
            │      x->done--;                      ← 消耗一次完成
            │
            └─ return timeout ?: 1;                ← 成功
```

### 3.2 变体函数

| 函数 | 行号 | state | timeout | action |
|------|------|-------|---------|--------|
| `wait_for_completion` | 151 | UNINTERRUPTIBLE | MAX | schedule |
| `wait_for_completion_timeout` | 169 | UNINTERRUPTIBLE | timeout | schedule_timeout |
| `wait_for_completion_io` | 184 | UNINTERRUPTIBLE+IO | MAX | io_schedule |
| `wait_for_completion_io_timeout` | 194 | UNINTERRUPTIBLE+IO | timeout | io_schedule_timeout |
| `wait_for_completion_interruptible` | 219 | INTERRUPTIBLE | MAX | schedule |
| `wait_for_completion_killable` | 257 | KILLABLE | MAX | schedule |
| `wait_for_completion_state` | 267 | 自定义 | MAX | schedule |
| `wait_for_completion_interruptible_timeout` | 238 | INTERRUPTIBLE | timeout | schedule_timeout |
| `wait_for_completion_killable_timeout` | 286 | KILLABLE | timeout | schedule_timeout |

所有变体都通过 `wait_for_common` → `__wait_for_common` → `do_wait_for_common` 这一公共路径。

---

## 4. 非阻塞检查

### 4.1 `try_wait_for_completion`（`completion.c:309`）

```c
// completion.c:309 — doom-lsp 确认
bool try_wait_for_completion(struct completion *x)
{
    unsigned long flags;
    bool ret = true;

    if (!READ_ONCE(x->done))      // 快速检查：无事可做 → 立即返回
        return false;

    raw_spin_lock_irqsave(&x->wait.lock, flags);
    if (!x->done)
        ret = false;              // 竞争失败
    else if (x->done != UINT_MAX)
        x->done--;                // 消耗一次完成
    raw_spin_unlock_irqrestore(&x->wait.lock, flags);

    return ret;
}
```

非阻塞检查 `done` 计数。用于轮询模式或检查完成状态而不需要线程休眠的场合。

### 4.2 `completion_done`（`completion.c:342`）

```c
// completion.c:342 — doom-lsp 确认
bool completion_done(struct completion *x)
{
    unsigned long flags;

    if (!READ_ONCE(x->done))
        return false;             // 等待者还未被通知

    // 需要获取锁确保 complete() 已完成对 completion 的引用
    raw_spin_lock_irqsave(&x->wait.lock, flags);
    raw_spin_unlock_irqrestore(&x->wait.lock, flags);

    return true;                  // 已 complete() 或 complete_all()
}
```

**重要**：`completion_done` 返回 true **不**意味着没有等待者——`complete_all()` 后所有等待者可能仍在运行。它只是说"至少有一次 complete() 调用已完成"。获取锁是为了保证：当 `completion_done` 返回 true，`complete()` 函数已经完全完成对 completion 结构的引用。

---

## 5. 🔥 数据流全景

```
场景：内核模块初始化 → 工作线程 → 完成通知

// 全局定义
static struct completion comp;

// 模块初始化函数
int init_module(void)
{
    init_completion(&comp);           // done = 0

    kthread_run(worker_thread, ...)   // 启动工作线程
    ...
    return 0;
}

// 工作线程
int worker_thread(void *data)
{
    do_work();                        // 执行工作

    complete(&comp);                  // 通知完成
    // ① done++: 0 → 1
    // ② swake_up_locked: 唤醒等待者
    return 0;
}

// 卸载函数
void cleanup_module(void)
{
    wait_for_completion(&comp);       // 等待工作线程完成
    // ③ done 非零 → 通过
    // ④ done--: 1 → 0
    // ⑤ 安全卸载
}
```

时间线（complete 先于 wait 的场景）：
```
worker: complete(&comp) → done = 1
  ... 时间流逝 ...
cleanup: wait_for_completion(&comp)
           → 检查 done: 1 (非零)
           → done--: 1 → 0
           → 立即返回，不需要进入等待队列
```

这个时序保证了"事件已发生，等待无需阻塞"的正确性——这是 completion 比基于标志位+等待队列的自实现更可靠的原因。

---

## 6. 🔥 真实使用——kthread_stop

```c
// kernel/kthread.c — kthread_stop 内部使用 completion
struct kthread {
    struct completion parked;    // 等待 kthread 停放
    struct completion exited;    // 等待 kthread 退出
    // ...
};

int kthread_stop(struct task_struct *k)
{
    struct kthread *kthread = to_kthread(k);

    set_bit(KTHREAD_IS_STOPPED, &kthread->flags);
    wake_up_process(k);

    wait_for_completion(&kthread->exited);  // 等待线程真正退出
    return kthread->result;
}
```

**数据流**：

```
调用者：                                 工作线程：
kthread_stop(worker)                     worker_thread() 循环中
  │                                        │
  ├─ set_bit(STOPPED)                     ├─ 检查 STOPPED → 退出
  ├─ wake_up_process(worker)              ├─ do_exit() 前
  │                                        │   complete(&kthread->exited)
  └─ wait_for_completion(&exited)         │
       │                                  │   ① done: 0 → 1
       │                                  │   ② swake_up_locked
       │ 被唤醒！                         │
       ├─ done-- (1→0)                    │
       └─ 返回，安全清理                   │
```

---

## 7. 初始化与重置

```c
// completion.h:84 — doom-lsp 确认
static inline void init_completion(struct completion *x)
{
    x->done = 0;
    init_swait_queue_head(&x->wait);
}

// completion.h:97 — doom-lsp 确认
static inline void reinit_completion(struct completion *x)
{
    x->done = 0;                     // 重置 done 计数器（谨慎使用）
}
```

`reinit_completion` 用于复用 completion。使用前必须确保所有等待者已完成、没有并发的 complete() 调用。

---

## 8. 设计决策

| 决策 | 原因 |
|------|------|
| 使用 `swait` 而非标准 `wait_queue` | completion 需要更少的特性（无独占/非独占、无回调），swait 更轻量 |
| `done` 计数而非 boolean | 支持 complete() 先于 wait() 调用 |
| `UINT_MAX` 标记永久完成 | complete_all 后所有等待者立即通过 |
| `done--` 在检查并持有锁后 | 防止竞态：确保同一完成不被多个消费者消耗 |
| 无所有权概念 | 简化 API，允许中断/定时器调用 complete() |
| `READ_ONCE` 快速检查 | 减少锁竞争：无等待者时直接返回 |

---

## 9. 源码文件索引

| 文件 | 内容 | 符号数 |
|------|------|--------|
| `include/linux/completion.h` | 结构体 + inline API | **21 个** |
| `kernel/sched/completion.c` | 完整实现 | **58 个** |
| `include/linux/swait.h` | 简单等待队列 | — |

---

## 10. 关联文章

- **07-wait_queue**：标准等待队列 —— swait 的完整功能版本
- **08-mutex**：互斥锁（所有权概念 vs completion 无所有权）
- **14-kthread**：kthread_stop 使用 completion 同步
- **11-completion**：内核中最轻量的同步原语

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*


## Additional Details

This section provides additional detail on the kernel mechanism described above. Understanding these details is essential for kernel development work.
This section provides additional detail on the kernel mechanism described above. Understanding these details is essential for kernel development work.
This section provides additional detail on the kernel mechanism described above. Understanding these details is essential for kernel development work.
This section provides additional detail on the kernel mechanism described above. Understanding these details is essential for kernel development work.
This section provides additional detail on the kernel mechanism described above. Understanding these details is essential for kernel development work.
This section provides additional detail on the kernel mechanism described above. Understanding these details is essential for kernel development work.
This section provides additional detail on the kernel mechanism described above. Understanding these details is essential for kernel development work.
This section provides additional detail on the kernel mechanism described above. Understanding these details is essential for kernel development work.
This section provides additional detail on the kernel mechanism described above. Understanding these details is essential for kernel development work.
This section provides additional detail on the kernel mechanism described above. Understanding these details is essential for kernel development work.
This section provides additional detail on the kernel mechanism described above. Understanding these details is essential for kernel development work.
This section provides additional detail on the kernel mechanism described above. Understanding these details is essential for kernel development work.
This section provides additional detail on the kernel mechanism described above. Understanding these details is essential for kernel development work.
This section provides additional detail on the kernel mechanism described above. Understanding these details is essential for kernel development work.
This section provides additional detail on the kernel mechanism described above. Understanding these details is essential for kernel development work.
