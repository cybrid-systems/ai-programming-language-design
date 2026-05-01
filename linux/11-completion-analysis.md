# 11-completion — 完成量深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**completion（完成量）** 是 Linux 内核中最轻量的同步原语。它用于"一个线程等待另一个线程完成某件事"的场景——两个线程之间的一次性同步。

与 mutex 和 semaphore 相比，completion 的设计极为简洁：
- **没有计��������**——只有"完成"和"未完成"两种状态
- **没有递归**——一次性使用（虽然可以重新初始化）
- **单生产者-单消费者**模型——一个线程等待，另一个线程通知

doom-lsp 确认 `include/linux/completion.h` 定义了约 40+ 个符号，实现位于 `kernel/sched/completion.c`。

---

## 1. 核心数据结构

### 1.1 struct completion

```c
struct completion {
    unsigned int done;          // 完成计数：0=等待中，>0=已完成
    wait_queue_head_t wait;     // 等待队列
};
```

整个 completion 的核心就是这个 `done` 字段：
- **`done == 0`**：消费者正在等待，生产者尚未完成
- **`done >= 1`**：已完成，等待者直接通过
- **`done > 1`**：多个 complete() 调用，多个等待者依次通过

---

## 2. 等待路径

### 2.1 wait_for_completion

```c
// kernel/sched/completion.c
void __sched wait_for_completion(struct completion *x)
{
    wait_for_common(x, MAX_SCHEDULE_TIMEOUT, TASK_UNINTERRUPTIBLE);
}
```

内部流程：

```
wait_for_completion(x)
  └─ wait_for_common(x, MAX_SCHEDULE_TIMEOUT, TASK_UNINTERRUPTIBLE)
       │
       ├─ spin_lock_irq(&x->wait.lock)
       │
       ├─ if (x->done > 0) {          ← 已完成？直接返回
       │       x->done--;
       │       spin_unlock_irq(&x->wait.lock);
       │       return 0;
       │   }
       │
       ├─ 创建等待者加入 wait queue
       ├─ set_current_state(TASK_UNINTERRUPTIBLE)  ← 准备睡眠
       │
       ├─ spin_unlock_irq(&x->wait.lock)
       │
       ├─ schedule()                   ← 让出 CPU
       │
       └─ 被唤醒后 → 获取锁 → done-- → 返回
```

### 2.2 变体

| 函数 | 超时 | 信号 | 返回值 |
|------|------|------|--------|
| `wait_for_completion` | 无 | ❌ | void |
| `wait_for_completion_timeout` | ✅ | ❌ | 剩余 jiffies |
| `wait_for_completion_interruptible` | 无 | ✅ | 0 或 -ERESTARTSYS |
| `wait_for_completion_killable` | 无 | ✅(SIGKILL) | 0 或 -ERESTARTSYS |
| `try_wait_for_completion` | ❌ | ❌ | bool（不等待）|

---

## 3. 通知路径

### 3.1 complete

```c
// kernel/sched/completion.c
void __sched complete(struct completion *x)
{
    // 增加计数
    if (x->done > 0) {
        x->done++;                     // 已经 done > 0，继续增加
        return;
    }

    // 有人正在等待
    x->done++;                         // count = 1
    __wake_up_locked(&x->wait, TASK_NORMAL, 1);
}
```

### 3.2 complete_all

```c
void __sched complete_all(struct completion *x)
{
    // 计数设置为 UINT_MAX / 2（代表"永久满足"）
    x->done += UINT_MAX / 2;
    __wake_up_locked(&x->wait, TASK_NORMAL, 0);  // 唤醒所有等待者
}
```

`complete_all` 让所有正在等待和将来等待的线程都通过——done 被设为一个大值，后续的 wait_for_completion 都会立即返回。

---

## 4. 数据流

```
线程 A（生产者）                      线程 B（消费者）
                                      │
                                      │ wait_for_completion(&comp)
                                      │   ├─ done == 0 ? 是
                                      │   ├─ 加入 wait queue
                                      │   └─ schedule()
完成工作                              │
  │                                    │
complete(&comp)                       │
  ├─ done = 1                         │
  └─ wake_up(&comp.wait) ────────────→ │ 被唤醒
                                       │   ├─ done--
                                       │   └─ 返回，继续执行
```

---

## 5. 设计决策总结

| 决策 | 原因 |
|------|------|
| `done` 计数设计 | 支持提前 complete()，等待者不会丢失唤醒 |
| 基于 wait_queue | 复用成熟的等待/唤醒基础设施 |
| `complete_all` UINT_MAX/2 | 永久满足，不会溢出 |
| 简单接口 | wait_for + complete，使用者几乎不可能用错 |

---

## 6. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/completion.h` | `struct completion` | 定义 |
| `kernel/sched/completion.c` | `wait_for_common` | 核心实现 |
| `kernel/sched/completion.c` | `complete` | 通知实现 |

---

## 7. 关联文章

- **wait_queue**（article 07）：completion 底层使用 wait_queue
- **kthread**（article 14）：kthread_stop 使用 completion 同步

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
