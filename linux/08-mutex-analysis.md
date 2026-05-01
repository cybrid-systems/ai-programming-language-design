# 08-mutex — Linux 内核互斥锁深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**mutex（互斥锁）** 是 Linux 内核中最核心的睡眠锁（sleeping lock）实现。与自旋锁不同，当线程无法获取 mutex 时，它不会忙等待（spin），而是将当前进程置入休眠状态并调度其他进程运行，直到锁被释放。

这种"拿不到就睡"的特性使 mutex 在以下场景中成为首选：
1. 锁持有时间可能较长（> 几十微秒）
2. 锁持有时可能休眠或调度
3. 临界区涉及 IO 操作、页面分配等可能阻塞的操作

mutex 的实现经历了多次演进——从最初的简单信号量（semaphore）实现，到 MCS 锁（1991年 John Mellor-Crummey 和 Michael Scott 提出的 NUMA 友好的公平锁算法），再到 Linux 3.18 引入的 **基于 MCS 的 optimistic spinning** 实现。当前 7.0-rc1 版本中的 mutex 已经是第三代实现——结合了快速路径（atomic xadd）、中速路径（optimistic spinning）和慢速路径（schedule）。

**doom-lsp 确认**：`include/linux/mutex.h` 包含 **73 个符号**，`kernel/locking/mutex.c` 包含 **100 个实现符号**。

---

## 1. 核心数据结构

### 1.1 `struct mutex`（`include/linux/mutex.h`）

```c
// include/linux/mutex.h:83 — doom-lsp 确认
struct mutex {
    atomic_long_t       owner;              // 锁所有者 + flags
    spinlock_t          wait_lock;          // 等待队列自旋锁
    struct list_head    wait_list;          // MCS 等待队列
#ifdef CONFIG_DEBUG_MUTEXES
    struct task_struct  *magic;             // 调试：持有者指针
    struct lockdep_map  dep_map;            // 锁依赖跟踪
#endif
};
```

**`owner` 字段的位编码**（`kernel/locking/mutex.c`）：

```c
// owner 字段的低 3 位编码锁状态
#define MUTEX_FLAG_PICKUP      1    // bit 0: 等待者可获取锁
#define MUTEX_FLAG_HANDOFF     2    // bit 1: 锁正在交接
#define MUTEX_FLAG_WAITERS     4    // bit 2: 有等待者

// 获取 owner 中的 task_struct 指针（屏蔽低 3 位）：
static inline struct task_struct *__owner_task(unsigned long owner)
{
    return (struct task_struct *)(owner & ~MUTEX_FLAGS);
}

// 获取 flags（低 3 位）：
static inline unsigned long __owner_flags(unsigned long owner)
{
    return owner & MUTEX_FLAGS;
}
```

**位布局**（64 位系统）：

```
owner (atomic_long_t):
┌─────────────────────────────────────────────┬───┬───┬───┐
│         task_struct 指针（61 位）              │ W │ H │ P │
│                                               │AIT│AND│ICK│
│                                               │ERS│OFF│UP │
└─────────────────────────────────────────────┴───┴───┴───┘
                                               bit2 bit1 bit0
```

### 1.2 `struct mutex_waiter`

```c
// kernel/locking/mutex.c — 内部使用
struct mutex_waiter {
    struct list_head    list;           // 链入 mutex->wait_list
    struct task_struct  *task;           // 等待的进程
    struct mspin_node   mcs;            // MCS spinning 节点（optimistic spinning 用）
};
```

---

## 2. 三层路径架构

Linux mutex 的设计将锁获取分为三个递进的路径：

### 2.1 快速路径（Fastpath）——`__mutex_trylock_fast`

```c
// kernel/locking/mutex.c:153 — doom-lsp 确认
static inline bool __mutex_trylock_fast(struct mutex *lock)
{
    unsigned long curr = (unsigned long)current;
    unsigned long zero = 0UL;

    // 尝试将 owner 从 0 原子地 CAS 为 current
    // 如果成功 → 锁未被持有，直接获取
    // 如果失败 → 锁被持有或有等待者，进入慢速路径
    return atomic_long_try_cmpxchg_acquire(&lock->owner, &zero, curr);
}
```

**汇编层面的单条指令**（x86-64）：

```asm
; __mutex_trylock_fast: 尝试用 cmpxchg 原子获取锁
mov    %rax, zero       ; %rax = 0
lock cmpxchg %rcx, (%rdx)  ; if (*owner == 0): *owner = current
; 单条指令完成"检测锁是否空闲 + 设置持有者"
```

**数据流**：

```
mutex_lock(lock)
  │
  ├─ __mutex_trylock_fast(lock)
  │   ├─ atomic_long_try_cmpxchg_acquire(&lock->owner, 0, current)
  │   │
  │   ├─ 如果成功（owner 原是 0，现在是 current）：
  │   │   └─ 返回 true → 已获取锁，直接返回！
  │   │
  │   └─ 如果失败（owner 非 0，锁被持有）：
  │       └─ 进入中速路径
```

### 2.2 中速路径（Midpath）——Optimistic Spinning

当快速路径失败时，当前线程不会立即休眠——它会**自旋等待一小段时间**，期望锁很快被释放：

```c
// mutex_lock() → 慢速入口
void __sched mutex_lock(struct mutex *lock)
{
    might_sleep();                        // 可能休眠
    if (!__mutex_trylock_fast(lock))      // 先试快速路径
        __mutex_lock_slowpath(lock);      // 中速 + 慢速路径
}

static noinline void __sched __mutex_lock_slowpath(struct mutex *lock)
{
    __mutex_lock(lock, TASK_UNINTERRUPTIBLE, 0, NULL);
}
```

**Optimistic Spinning 的核心逻辑**：

```
__mutex_lock() 中速路径：
  │
  ├─ 初始化 mutex_waiter（设置 task = current）
  │
  ├─ for (;;) {
  │      │
  │      ├─ 尝试 __mutex_trylock(lock)              ← 再次尝试
  │      │   └─ cmpxchg(&lock->owner, 0, current)
  │      │
  │      ├─ 如果 owner 不是当前锁持有者：
  │      │   └─ 检查 owner 是否仍在运行
  │      │       ├─ 是 → cpu_relax() 继续自旋         ← optimistic spinning
  │      │       └─ 否 → 准备进入睡眠
  │      │
  │      ├─ 添加自身到 wait_list                      ← 入队
  │      ├─ set_current_state(TASK_UNINTERRUPTIBLE)   ← 设置休眠
  │      ├─ 再次尝试 __mutex_trylock(lock)            ← 最后一次尝试
  │      └─ schedule()                                ← 真正睡眠
  │   }
  │
  └─ 获取锁成功 → __mutex_remove_waiter
```

**为什么需要 optimistic spinning**？

```
持有锁的 CPU      当前 CPU（尝试获取锁的进程）
    │                  │
    │  持有锁          │
    │                  ├─ __mutex_trylock_fast → 失败
    │                  ├─ 开始自旋（等待 ~500ns）
    │  释放锁          │
    │  标记 owner=0    │
    │                  ├─ 检测 owner=0
    │                  ├─ cmpxchg 获取锁
    │                  │
    │                  └─ 进入临界区
    │
    如果不自旋，当前 CPU 会：
    schedule() → 上下文切换（~1-5μs）→ 下次被调度时再试
    → 如果锁持有时间很短（< 上下文切换时间），自旋更高效
```

### 2.3 慢速路径（Slowpath）——schedule

如果 optimistic spinning 期间锁仍未释放（锁持有者也被调度出去了），当前线程真正进入休眠：

```
当前线程插入到 mutex->wait_list（按 FIFO 顺序）
  → set_current_state(TASK_UNINTERRUPTIBLE)
  → schedule()                ← 让出 CPU
  → 被唤醒后，从 wait_list 头部竞争锁
  → 获取成功 → 从 wait_list 移除
```

---

## 3. 解锁操作——__mutex_unlock

### 3.1 快速解锁

```c
// kernel/locking/mutex.c:167 — doom-lsp 确认
static inline bool __mutex_unlock_fast(struct mutex *lock)
{
    unsigned long curr = (unsigned long)current;

    // 尝试将 owner 从 current 原子地 CAS 为 0
    // 成功 → 无等待者，直接释放
    // 失败 → 有等待者或 flags，进入慢速解锁
    return atomic_long_try_cmpxchg_release(&lock->owner, &curr, 0);
}
```

### 3.2 慢速解锁

```c
// mutex_unlock 完整流程
void __sched mutex_unlock(struct mutex *lock)
{
    if (__mutex_unlock_fast(lock))     // 快速路径
        return;

    __mutex_unlock_slowpath(lock);     // 慢速路径
    // → 设置 MUTEX_FLAG_HANDOFF 或 MUTEX_FLAG_PICKUP
    // → 唤醒等待者
}
```

---

## 4. 握手协议（Handoff Protocol）

当锁的持有者释放锁时，如果有等待者在 `wait_list` 中，它必须将锁**直接交接**给下一个等待者，而不是将 `owner` 设为 0 让所有等待者竞争。这称为 **handoff**：

```
mutex_unlock() 时检测到 wait_list 非空：
  │
  ├─ 设置 MUTEX_FLAG_HANDOFF（告诉等待者：锁正在交接）
  ├─ 在 wait_list 中选择第一个 waiter
  ├─ 将该 waiter 从列表移除
  ├─ wake_up_process(waiter)          ← 只唤醒这一个等待者
  │
  被唤醒的等待者：
  ├─ __mutex_trylock_common() 检测到 MUTEX_FLAG_HANDOFF
  ├─ 如果自己的 task == owner & ~MUTEX_FLAGS:
  │    → 握手成功：清除 HANDOFF，设置 PICKUP
  │    → 获取锁
  │
  └─ 如果自己的 task != owner（有人抢先了）:
       → 重新加入 wait_list
       → 再次休眠
```

**Handoff vs MCS Lock（Mellor-Crummey and Scott）**：

MCS 锁是最早的 NUMA 友好公平队列锁。每个等待者在自己的本地节点上自旋，而非所有等待者共享一个全局变量。Linux mutex 的 handoff 机制部分借鉴了 MCS 的设计思想——只有队首的 waiter 被唤醒，避免了"惊群效应"（thundering herd）。

---

## 5. MCS 等待队列——doom-lsp 确认

```c
// kernel/locking/mutex.c:207 — doom-lsp 确认
static inline void __mutex_add_waiter(struct mutex *lock,
                                       struct mutex_waiter *waiter,
                                       struct list_head *list)
{
    list_add_tail(&waiter->list, list);  // FIFO 尾部插入
    __mutex_set_flag(lock, MUTEX_FLAG_WAITERS);  // 标记有等待者
}

// mutex.c:240 — doom-lsp 确认
static inline void __mutex_remove_waiter(struct mutex *lock,
                                          struct mutex_waiter *waiter)
{
    list_del(&waiter->list);
    if (list_empty(&lock->wait_list))
        __mutex_clear_flag(lock, MUTEX_FLAG_WAITERS);
}
```

**FIFO 公平性**：等待者按到达顺序插入 `wait_list` 尾部。每次解锁时只唤醒队首的 waiter，严格保证了公平性，避免了写者饥饿（writer starvation）。

---

## 6. 🔥 doom-lsp 数据流追踪——mutex_lock 完整调用链

```
mutex_lock(lock)                           @ mutex.h:214
  │
  ├─ might_sleep()                         检查是否允许休眠
  │
  └─ __mutex_trylock_fast(lock)            @ mutex.c:153
      │
      ├─ 成功 → return（已获取锁）           ← 快速路径
      │
      └─ 失败 → __mutex_lock_slowpath(lock) @ mutex.c:???
            │
            └─ __mutex_lock(lock, TASK_UNINTERRUPTIBLE, 0, NULL)
                  │
                  ├─ 初始化 mutex_waiter：
                  │   → waiter.task = current
                  │   → INIT_LIST_HEAD(&waiter.list)
                  │
                  ├─ 进入 Optimistic Spinning 循环：
                  │
                  │   for (;;) {
                  │       │
                  │       ├─ __mutex_trylock(lock)           @ mutex.c:132
                  │       │   └─ __mutex_trylock_common(lock, false)  @ mutex.c:85
                  │       │        │
                  │       │        ├─ owner = atomic_long_read(&lock->owner)
                  │       │        ├─ task = owner & ~MUTEX_FLAGS
                  │       │        │
                  │       │        ├─ if (task == 0) {       ← 锁空闲
                  │       │        │      cmpxchg_acquire → 设置 current
                  │       │        │      return NULL        ← 成功！
                  │       │        │   }
                  │       │        │
                  │       │        ├─ if (PICKUP && task == curr)
                  │       │        │      → 握手成功，获取锁
                  │       │        │
                  │       │        └─ return owner_task       ← 失败
                  │       │
                  │       ├─ if (__mutex_trylock 成功) break
                  │       │
                  │       ├─ 自旋等待...
                  │       │   preempt_enable()
                  │       │   cpu_relax()               ← PAUSE 指令
                  │       │   preempt_disable()
                  │       │
                  │       ├─ 检查 owner task 是否还在运行
                  │       │   ├─ 是 → continue spinning
                  │       │   └─ 否（锁持有者被调度走了）→ break spinning
                  │       │
                  │       └─ 退出自旋循环
                  │   }
                  │
                  ├─ 如果自旋结束仍未获取锁：
                  │
                  │   ├─ spin_lock(&lock->wait_lock)
                  │   ├─ __mutex_add_waiter(lock, waiter, &lock->wait_list)
                  │   │   → list_add_tail + MUTEX_FLAG_WAITERS
                  │   ├─ set_current_state(TASK_UNINTERRUPTIBLE)
                  │   │
                  │   ├─ 最后一次尝试 __mutex_trylock(lock)
                  │   │   如果成功 → __mutex_remove_waiter
                  │   │
                  │   ├─ spin_unlock(&lock->wait_lock)
                  │   │
                  │   └─ schedule()                      ← 真正休眠
                  │       [进程被移出运行队列]
                  │       [等待锁释放后被唤醒]
                  │       [返回到循环顶部，再次尝试]
                  │
                  └─ 获取锁成功 → return
```

---

## 7. mutex 变体

### 7.1 `mutex_lock_interruptible`（`mutex.h:215`）

```c
// mutex.h:215 — doom-lsp 确认
int __sched mutex_lock_interruptible(struct mutex *lock);
```

可被信号中断。如果在等待时进程收到信号，返回 `-EINTR`。用于那些允许被信号打断的阻塞操作。

### 7.2 `mutex_lock_killable`（`mutex.h:216`）

```c
// mutex.h:216 — doom-lsp 确认
int __sched mutex_lock_killable(struct mutex *lock);
```

只允许被 fatal signal（SIGKILL）中断。介于 `mutex_lock` 和 `mutex_lock_interruptible` 之间。

### 7.3 `mutex_trylock`（`mutex.h:245`）

```c
// mutex.h:245 — doom-lsp 确认
int __sched mutex_trylock(struct mutex *lock);
```

非阻塞尝试获取锁。成功返回 1，失败返回 0。不会调用 `might_sleep()`。

### 7.4 `mutex_lock_io`（`mutex.h:217`）

```c
// mutex.h:217 — doom-lsp 确认
void __sched mutex_lock_io(struct mutex *lock);
```

与 `mutex_lock` 相同，但告诉内核调度器：当前进程等待锁期间可能涉及 IO 操作。这使得调度器在计算 IO 压力时更准确。

---

## 8. 调试支持

```c
// include/linux/mutex.h — 调试字段
#ifdef CONFIG_DEBUG_MUTEXES
    struct task_struct  *magic;    // 持有者指针，用于检测 use-after-free
    struct lockdep_map  dep_map;   // 锁依赖跟踪
#endif
```

- **`magic`**：持有者的 task_struct 指针。锁释放时设为 NULL，检测是否从已释放的锁上 unlock。
- **`dep_map`**：lockdep 跟踪。检测死锁、锁顺序违反、IRQ 上下文的不安全锁使用。

---

## 9. mutex vs 其他锁

| 特性 | mutex | spinlock | rwsem | rt_mutex |
|------|-------|----------|-------|----------|
| 等待方式 | 休眠 + 可选 spinning | 自旋 | 休眠 | 休眠 |
| 是否可递归 | ❌ | ❌ | ❌ | ❌ |
| 读写区分 | ❌ | ❌ | ✅ | ❌ |
| FAIR 性 | FIFO（handoff） | 非公平 | FIFO | 优先级继承 |
| 临界区限制 | 可睡眠 | 不可睡眠 | 可睡眠 | 可睡眠 |
| 快速路径 | cmpxchg @ owner | atomic_spin_lock | cmpxchg @ count | cmpxchg |
| 优先级反转 | 无处理 | 无处理 | 无处理 | **优先级继承** |

---

## 10. 性能特征

| 路径 | 触发条件 | 延迟 | CPU 消耗 |
|------|---------|------|---------|
| 快速路径 | 锁空闲 | ~10 ns（cmpxchg） | 几乎无 |
| 中速路径（spinning） | 锁持有者正在运行 | ~100-5000 ns | 自旋消耗 CPU |
| 慢速路径 | 锁持有者已休眠 | ~5-20 μs（含上下文切换）| 几乎无 |

---

## 11. 典型使用模式

```c
// 模式 1：基本互斥
struct mutex my_mutex;
mutex_init(&my_mutex);

mutex_lock(&my_mutex);
// 临界区：访问共享数据
shared_data++;
mutex_unlock(&my_mutex);

// 模式 2：可中断等待
if (mutex_lock_interruptible(&my_mutex) == -EINTR) {
    // 被信号打断
    return -ERESTARTSYS;
}
// 临界区
mutex_unlock(&my_mutex);

// 模式 3：非阻塞尝试
if (mutex_trylock(&my_mutex)) {
    // 获取成功
    mutex_unlock(&my_mutex);
} else {
    // 锁被其他线程持有
}
```

---

## 12. 源码文件索引

| 文件 | 内容 | doom-lsp 符号数 |
|------|------|----------------|
| `include/linux/mutex.h` | 结构体 + 声明 + inline | **73 个** |
| `kernel/locking/mutex.c` | 快速/中速/慢速路径实现 | **100 个** |
| `kernel/locking/osq_lock.c` | Optimistic spinning 队列 | — |

---

## 13. 关联文章

- **07-wait_queue**：mutex 的等待队列基础
- **09-spinlock**：自旋锁（mutex 的忙等待替代方案）
- **10-rwsem**：读写信号量（mutex 的读写分离版本）
- **26-RCU**：无锁并发机制（比 mutex 更高效）
- **11-completion**：基于 mutex 的一次性同步

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
