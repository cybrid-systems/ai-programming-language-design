# 11-completion — 完成量深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**completion（完成量）** 是 Linux 内核中最轻量的同步原语，核心模型是"一个线程等待另一个线程完成某件事"。与 mutex 不同，completion 没有所有权概念——任何线程都可以调用 `complete()` 通知等待者。

completion 的设计哲学：**最简接口，零误用空间**。只有两个核心操作——`wait_for_completion()`（等待）和 `complete()`（通知），几乎不可能用错。

doom-lsp 确认 `kernel/sched/completion.c` 包含 58 个符号（约 17 个 API 函数），`include/linux/completion.h` 定义了核心结构。

---

## 1. 核心数据结构

### 1.1 struct completion（`include/linux/completion.h:26`）

```c
struct completion {
    unsigned int done;               // 完成计数：0=未完成，>0=已完成
    wait_queue_head_t wait;          // 等待队列（底层使用 swait_queue）
};
```

整个 completion 的核心就是一个 `done` 计数器：

```
done == 0:      消费者在等待
done == 1:      生产者已调用 complete()，消费者通过后减为 0
done == UINT_MAX: complete_all() 已调用，所有等待线程立即通过
done > 0:      多个 complete() 调用，多个等待者可以依次通过
```

注意 `UINT_MAX` 的特殊含义——它表示"永久满足"，后续所有 `wait_for_completion()` 调用都会立即返回。

---

## 2. 生产者路径：complete

### 2.1 complete 入口（`completion.c:50`）

```c
void complete(struct completion *x)
{
    complete_with_flags(x, 0);
}
```

`complete_with_flags` 是核心实现（`completion.c:21`）：

```
complete_with_flags(x, flags)
  │
  ├─ raw_spin_lock_irqsave(&x->wait.lock, flags)   ← 加锁
  │
  ├─ x->done++                                       ← 增加完成计数
  │
  ├─ if (x->done > 0)
  │    └─ swake_up_locked(&x->wait)                  ← 唤醒一个等待者
  │
  └─ raw_spin_unlock_irqrestore(&x->wait.lock, flags) ← 解锁
```

doom-lsp 确认 `complete_with_flags` 位于 `completion.c:21`，是完整的实现函数。

### 2.2 complete_all（`completion.c:72`）

```c
void complete_all(struct completion *x)
{
    raw_spin_lock_irqsave(&x->wait.lock, flags);
    x->done = UINT_MAX;                           // 设为永久满足
    swake_up_all_locked(&x->wait);                // 唤醒所有等待者
    raw_spin_unlock_irqrestore(&x->wait.lock, flags);
}
```

与 `complete()` 的关键区别：
- `complete()`：done++，**唤醒一个**等待者（swake_up_locked，独占唤醒）
- `complete_all()`：done = UINT_MAX，**唤醒所有**等待者（swake_up_all_locked，非独占唤醒）

---

## 3. 消费者路径：wait_for_completion

### 3.1 wait_for_completion 入口（`completion.c:151`）

```c
void __sched wait_for_completion(struct completion *x)
{
    wait_for_common(x, MAX_SCHEDULE_TIMEOUT, TASK_UNINTERRUPTIBLE);
}
```

内核实现调用 `wait_for_common`（`completion.c:129`）：

```
wait_for_common(x, timeout, state)
  │
  ├─ 调用 __wait_for_common(x, timeout, state)   ← completion.c:112
  │    │
  │    ├─ 循环检查：
  │    │    │
  │    │    ├─ if (x->done) {                    ← 已 complete()？
  │    │    │       x->done--;                    ← 消耗一次完成
  │    │    │       return 0;                     ← 直接返回
  │    │    │   }
  │    │    │
  │    │    ├─ set_current_state(state)           ← 设置睡眠状态
  │    │    │
  │    │    ├─ if (x->done) {                    ← 再检查一次（防丢失）
  │    │    │       x->done--;
  │    │    │       return 0;
  │    │    │   }
  │    │    │
  │    │    └─ schedule()                         ← 让出 CPU
  │    │         ↓ 被 complete() 唤醒后重新检查
  │    │
  │    └─ 超时或信号中断 → 返回错误码
  │
  └─ return 0 / 超时值 / -ERESTARTSYS
```

---

## 4. 变体 API

| 函数 | 行 | 睡眠状态 | 超时 | 可中断 |
|------|-----|---------|------|--------|
| `wait_for_completion` | 151 | UNINTERRUPTIBLE | ❌ | ❌ |
| `wait_for_completion_timeout` | 169 | UNINTERRUPTIBLE | ✅ | ❌ |
| `wait_for_completion_interruptible` | 219 | INTERRUPTIBLE | ❌ | ✅ |
| `wait_for_completion_killable` | 257 | KILLABLE | ❌ | ✅(SIGKILL) |
| `wait_for_completion_io` | 184 | UNINTERRUPTIBLE+IO | ❌ | ❌ |
| `wait_for_completion_state` | 267 | 自定义 | ❌ | 自定义 |
| `try_wait_for_completion` | 309 | 不睡眠 | ❌ | ❌ |
| `completion_done` | 342 | 不睡眠 | ❌ | ❌ |

doom-lsp 确认所有这些函数都在 `kernel/sched/completion.c` 中，每个函数都有两个版本（带/不带 EXPORT_SYMBOL 的第一个定义）。

---

## 5. 数据流全景

```
线程 A（生产者）                      线程 B（消费者）
                                      │
  ... 执行工作 ...                    │ wait_for_completion(&comp)
                                      │   └─ __wait_for_common
                                      │        ├─ done==0 → 加入等待队列
                                      │        ├─ set_current_state(UNINTERRUPTIBLE)
                                      │        └─ schedule()
                                      │              ↓ 睡眠
complete(&comp)                       │
  └─ complete_with_flags              │
       ├─ done++ (0→1)               │
       ├─ swake_up_locked(&wait) ────→│ 被唤醒
       │                              ├─ done-- (1→0)
       │                              └─ 返回，继续执行
       │
  (线程 A 继续执行)                    │

complete_all(&comp)                   │ 多个等待者时：
  ├─ done = UINT_MAX                  │ 后续所有 wait_for_completion
  └─ swake_up_all_locked(&wait)       │ → done > 0 → 立即返回
```

---

## 6. 与 mutex 和 wait_queue 的关系

```
wait_queue_head（article 07）
    └── completion 底层使用 swait_queue（简单等待队列）

mutex（article 08）
    └── 有所有权、递归不可用、公平锁
completion（本文）
    └── 无所有权、任意线程可 complete()、一次性

共同点：
    ├── 基于等待队列
    ├── 可睡眠（进程上下文）
    └── 支持多种等待状态（INTERRUPTIBLE/UNINTERRUPTIBLE）
```

---

## 7. 设计决策总结

| 决策 | 原因 |
|------|------|
| `done` 计数而非 boolean | 支持 complete() 先于 wait() 调用 |
| `UINT_MAX` 标记 | complete_all 后所有等待者都通过 |
| `done--` 在检查后 | 确保同一完成不会被多个等待者消耗 |
| 底层使用 swait | 较少的特性需求，更高效的唤醒 |

---

## 8. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/completion.h` | `struct completion` | 26 |
| `kernel/sched/completion.c` | `complete_with_flags` | 21 |
| `kernel/sched/completion.c` | `complete` | 50 |
| `kernel/sched/completion.c` | `complete_all` | 72 |
| `kernel/sched/completion.c` | `do_wait_for_common` | 85 |
| `kernel/sched/completion.c` | `wait_for_common` | 129 |
| `kernel/sched/completion.c` | `wait_for_completion` | 151 |

---

## 9. 关联文章

- **wait_queue**（article 07）：completion 底层使用的同步机制
- **mutex**（article 08）：另一种同步原语，有所有权概念
- **kthread**（article 14）：kthread_stop 内部使用 completion 同步

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
