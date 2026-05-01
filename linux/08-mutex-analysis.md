# 08-mutex — 互斥锁深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**mutex** 是 Linux 内核中最基础的互斥锁原语，用在进程上下文中保护共享资源。与 spinlock 不同，mutex 允许持有者在等待时睡眠（`might_sleep()`），因此适用于临界区较长的场景。

整个 mutex 的实现围绕一个核心原则设计：**无竞争时走快速路径，有竞争时走慢速路径**。快速路径只有一条 CAS 指令，慢速路径则涉及等待队列、MCS 自旋锁和进程调度。

---

## 1. 核心数据结构

### 1.1 struct mutex（`include/linux/mutex.h:67`）

```c
// include/linux/mutex.h:67
struct mutex {
    atomic_long_t       owner;          // 持有者+标志位，0=空闲
    spinlock_t          wait_lock;      // 保护 wait_list 的自旋锁
    struct list_head    wait_list;      // 等待者链表（FIFO）
#ifdef CONFIG_DEBUG_MUTEXES
    struct task_struct  *magic;         // 调试：指向持有者
    struct lockdep_map  dep_map;        // 死锁检测
#endif
};
```

`owner` 字段是整个 mutex 的核心。它的编码方式非常巧妙：

```
  bit 0     = MUTEX_FLAG_WAITERS  (1)     — 有进程在等待
  bit 1     = MUTEX_FLAG_HANDOFF  (2)     — 交接模式（避免饥饿）
  bit 63:2  = task_struct 指针            — 当前持有者
```

这样设计的好处是：**一条 `atomic_long_t` 就同时记录了持有者和锁状态**。通过 `__mutex_owner()`（`mutex.c:58`）提取真正的持有者指针，通过 `__owner_flags()`（同上）提取标志位。

---

## 2. 数据流全景

```
mutex_lock(lock)                     ← mutex.c:314（用户入口）
  │
  ├─ __mutex_trylock_fast(lock)      ← mutex.c:153
  │    └─ atomic_long_try_cmpxchg_acquire(&owner, 0, current)
  │        成功 → 直接返回（O(1)，无竞争路径）
  │        失败 → 进入慢速路径
  │
  └─ __mutex_lock_slowpath(lock)     ← mutex.c:290
       └─ __mutex_lock_common(lock, TASK_UNINTERRUPTIBLE, ...)  ← mutex.c:608
            
            ├─ [Phase 1] Optimistic Spinning
            │    └─ mutex_optimistic_spin(lock)           ← mutex.c:473
            │         └─ osq_lock(&lock->osq)              ← 加入 MCS 队列
            │         └─ mutex_spin_on_owner(lock)          ← mutex.c:384
            │              └─ 自旋检查 owner 是否释放
            │         └─ osq_unlock(&lock->osq)             ← 离开 MCS 队列
            │    → 如果 spinning 期间锁释放了，直接获取并返回
            │
            ├─ [Phase 2] Add to Wait Queue
            │    └─ __mutex_add_waiter(lock, &waiter)     ← mutex.c:207
            │    └─ list_add_tail(&waiter.list, &lock->wait_list)
            │    └─ __mutex_set_flag(lock, MUTEX_FLAG_WAITERS)  ← mutex.c:190
            │
            └─ [Phase 3] Sleep
                 └─ set_current_state(TASK_UNINTERRUPTIBLE)
                 └─ schedule()  ← 让出 CPU
                 └─ 被唤醒后尝试获取锁
```

这个数据流清晰展示了 mutex 的三级降级策略：
1. **CAS 快速路径**（~10ns 级别）
2. **Optimistic spinning**（~us 级别，不 sleep）
3. **睡眠等待**（ms 级别，上下文切换）

---

## 3. 快速路径（无竞争场景）

### 3.1 __mutex_trylock_fast（`mutex.c:153`）

```c
// kernel/locking/mutex.c:153
static __always_inline bool __mutex_trylock_fast(struct mutex *lock)
{
    unsigned long curr = (unsigned long)current;
    unsigned long zero = 0UL;

    if (atomic_long_try_cmpxchg_acquire(&lock->owner, &zero, curr))
        return true;

    return false;
}
```

核心逻辑：用一条 **CAS 指令** 原子的比较 `owner == 0`（锁空闲），如果是则设置 `owner = current`。

doom-lsp 调用链分析：
```
__mutex_trylock_fast 被以下函数调用:
- mutex_lock @ mutex.c:314      ← 最常用的获取路径
- __mutex_lock_common @ mutex.c:608  ← 慢速路径中也会再试一次
```

clangd 确认该函数是 `static __always_inline`，展开后直接嵌入调用者，没有函数调用开销。

### 3.2 mutex_trylock（`mutex.c:1166`）

```c
int __sched mutex_trylock(struct mutex *lock)
{
    return __mutex_trylock(lock);
}
```

非阻塞版本。不管是否成功都立刻返回。doom-lsp 显示 `mutex_trylock` 在 `mutex.h:245` 也有声明，实际实现在 `mutex.c:1166`。

---

## 4. 慢速路径（竞争场景）

### 4.1 mutex_lock 入口（`mutex.c:314`）

```c
void __sched mutex_lock(struct mutex *lock)
{
    might_sleep();
    if (!__mutex_trylock_fast(lock))
        __mutex_lock_slowpath(lock);
}
```

`might_sleep()` 是关键检查——在原子上下文（如中断处理程序）中调用 `mutex_lock()` 会触发告警，因为 mutex 允许睡眠。clangd 确认 `might_sleep()` 展开后会检查 `preempt_count()` 和 `in_atomic()`。

### 4.2 __mutex_lock_slowpath（`mutex.c:290`）

doom-lsp 追踪显示，该函数的主要调用链：

```
mutex_lock @ 314
  └─ __mutex_lock_slowpath @ 290  (实际上是个 wrapper)
       └─ __mutex_lock_common @ 608  (真正的实现)
```

`__mutex_lock_common@608` 是整个 mutex 最复杂的函数，包含了 optimistic spinning、等待队列管理和进程睡眠。

### 4.3 Optimistic Spinning

乐观自旋（Optimistic Spinning）是 Linux mutex 区别于传统 mutex 的关键设计。

```c
// kernel/locking/mutex.c:473
static int mutex_optimistic_spin(struct mutex *lock)
{
    struct optimistic_spin_queue *osq = &lock->osq;

    if (!osq_lock(osq))        // 加入 MCS 队列
        return 0;

    while (true) {
        struct task_struct *owner;

        owner = __mutex_owner(lock);
        if (owner && owner_on_cpu(owner)) {
            mutex_spin_on_owner(lock, owner);  // 自旋等待
            continue;
        }

        if (__mutex_trylock(lock)) {  // 锁释放了，尝试获取
            osq_unlock(osq);
            return 1;
        }
    }
}
```

MCS 锁（MCS Queue Spinlock）的引入是为了解决 **cache line bouncing** 问题。传统自旋锁中所有 CPU 在同一个变量上自旋，每次锁状态变化都会导致所有 CPU 的 cache line 失效。MCS 锁让每个 CPU 在自己的本地节点上自旋，只有队首的 CPU 真正轮询 `lock->owner`。

doom-lsp 确认的调用链：
```
mutex_optimistic_spin @ 473
  ├─ osq_lock @ (kernel/locking/osq_lock.c)  ← 加入 MCS 队列
  ├─ mutex_spin_on_owner @ 384               ← 检查 owner 是否在运行
  └─ osq_unlock @ (kernel/locking/osq_lock.c) ← 离开 MCS 队列
```

### 4.4 等待队列管理

当 optimistic spinning 也失败时（锁被持有者长期持有，或持有者进入了睡眠），进程需要真正地睡眠等待：

```c
// kernel/locking/mutex.c:207
static void __mutex_add_waiter(struct mutex *lock, struct mutex_waiter *waiter)
{
    debug_mutex_add_waiter(lock, waiter, current);
    list_add_tail(&waiter->list, &lock->wait_list);
    waiter->task = current;
}
```

FIFO 队列保证了 **公平性**：先等待的进程先获得锁，不会出现饥饿。

`__mutex_set_flag(MUTEX_FLAG_WAITERS)`（`mutex.c:190`）在 owner 中设置等待者标志，这样解锁时就能知道需要唤醒后继者。

---

## 5. 解锁路径（mutex_unlock）

```c
// kernel/locking/mutex.c:576
void __sched mutex_unlock(struct mutex *lock)
{
#ifndef CONFIG_DEBUG_LOCK_ALLOC
    if (__mutex_unlock_fast(lock))
        return;
#endif
    __mutex_unlock_slowpath(lock, _RET_IP_);
}
```

解锁同样有快速/慢速两条路径：

**快速路径**（`__mutex_unlock_fast @ 167`）：
```c
static __always_inline bool __mutex_unlock_fast(struct mutex *lock)
{
    unsigned long curr = (unsigned long)current;

    if (atomic_long_try_cmpxchg_release(&lock->owner, &curr, 0UL))
        return true;

    return false;
}
```
CAS 将 `owner` 从 `current` 重置为 0。如果成功说明没有等待者，直接返回。

**慢速路径**（`__mutex_unlock_slowpath @ 557`）：
当 `owner` 中有 `MUTEX_FLAG_WAITERS` 标志时，CAS 会失败。解锁函数需要：
1. 清除 owner（或传递给下一个等待者）
2. 唤醒等待队列中的第一个进程

---

## 6. 关键设计决策

| 设计 | 位置 | 动机 |
|------|------|------|
| `owner = task_struct_ptr \| flags` | `mutex.h:67` | 单原子变量同时记录持有者和状态 |
| 快速路径 CAS | `mutex.c:153` | 无竞争时 O(1)，一条指令完成 |
| MCS optimistic spinning | `mutex.c:473` | 避免 cache line bouncing |
| FIFO wait_list | `mutex.c:207` | 公平锁，防止饥饿 |
| `TASK_UNINTERRUPTIBLE` | `__mutex_lock_common` | 持有 mutex 时不能被信号打断 |
| `MUTEX_FLAG_HANDOFF` | bit 1 | 减少锁移交时的竞争 |

---

## 7. 与 spinlock 对比

| 特性 | mutex | spinlock |
|------|-------|----------|
| 睡眠 | ✅ 允许 | ❌ 禁止 |
| 上下文 | 进程上下文 | 任意（含中断） |
| 临界区 | 长临界区 | 短临界区 |
| 快速路径 | CAS (O(1)) | 自旋 |
| 慢速路径 | MCS + 调度 | 自旋 |
| 典型延迟 | 上下文切换 (us) | 自旋 (ns) |

---

## 8. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/mutex.h` | `struct mutex` | 67 |
| `kernel/locking/mutex.c` | `__mutex_trylock_fast` | 153 |
| `kernel/locking/mutex.c` | `__mutex_lock_slowpath` | 290 |
| `kernel/locking/mutex.c` | `mutex_lock` | 314 |
| `kernel/locking/mutex.c` | `mutex_optimistic_spin` | 473 |
| `kernel/locking/mutex.c` | `__mutex_unlock_slowpath` | 557 |
| `kernel/locking/mutex.c` | `mutex_unlock` | 576 |
| `kernel/locking/mutex.c` | `__mutex_lock_common` | 608 |
| `kernel/locking/mutex.c` | `mutex_trylock` | 1166 |

---

## 9. 关联文章

- **wait_queue**（article 07）：mutex 内部使用 wait_queue 管理等待进程
- **spinlock**（article 09）：另一种锁原语，适用于不同场景
- **list_head**（article 01）：wait_list 和 MCS 队列的底层数据结构

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
