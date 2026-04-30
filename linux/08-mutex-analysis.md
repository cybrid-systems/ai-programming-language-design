# 08-mutex — 互斥锁深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/mutex.h` + `kernel/locking/mutex.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**mutex** 是 Linux 内核最简单的互斥锁，用于保护共享资源。特点：同一时刻只允许一个持有者、持有者必须解锁、不可递归。

---

## 1. 核心数据结构

### 1.1 struct mutex — 互斥锁

```c
// include/linux/mutex.h:34 — mutex
struct mutex {
    atomic_long_t           owner;          // 持有者（0=空闲）
    spinlock_t             wait_lock;       // 保护等待者链表的锁
    struct list_head        wait_list;      // 等待者链表（FIFO）
    // ...
};

// owner 编码（CONFIG_DEBUG_MUTEXES 时有调试信息）：
//   正常：owner = 当前 task_struct 的指针
//   最低位：MUTEX_FLAG_WAITERS = 1 表示有等待者
//   其他位：MUTEX_FLAG_DEBUG = 2 调试标志
//   实际存储：(task_struct*) | flags
//   __mutex_owner() 宏提取真正的 owner 指针
```

### 1.2 owner 字段编码

```c
// kernel/locking/mutex.c — __mutex_owner
static inline struct task_struct *__mutex_owner(struct mutex *lock)
{
    return (struct task_struct *)(atomic_long_read(&lock->owner) & ~MUTEX_FLAGS);
}

// MUTEX_FLAGS = 3
// 所以最低两位用于标志：
//   bit 0 = MUTEX_FLAG_WAITERS   (1)
//   bit 1 = MUTEX_FLAG_DEBUG     (2)
```

---

## 2. fastpath — 快速路径（无竞争）

### 2.1 __mutex_trylock_fast

```c
// kernel/locking/mutex.c — __mutex_trylock_fast
static inline bool __mutex_trylock_fast(struct mutex *lock)
{
    unsigned long owner = atomic_long_read(&lock->owner);

    // 检查：没有人持有（owner = 0）且没有等待者
    if (!atomic_long_try_cmpxchg_acquire(&lock->owner, &owner, (long)current)) {
        // CAS 失败，说明有人持有了
        return false;
    }

    return true;  // 成功获取锁
}
```

### 2.2 mutex_trylock — 尝试获取

```c
// kernel/locking/mutex.c — mutex_trylock
bool mutex_trylock(struct mutex *lock)
{
    return __mutex_trylock_fast(lock);
}
// 成功返回 true（锁被持有返回 false）
```

---

## 3. slowpath — 慢速路径（有竞争）

### 3.1 __mutex_lock_slowpath — 获取失败，进入阻塞

```c
// kernel/locking/mutex.c — __mutex_lock_slowpath
void __sched __mutex_lock_slowpath(struct mutex *lock)
{
    // 1. 将当前进程加入等待队列
    struct mutex_waiter waiter;

    waiter.task = current;  // 当前进程
    INIT_LIST_HEAD(&waiter.list);

    spin_lock(&lock->wait_lock);

    // 2. 如果锁已空闲（owner = 0），尝试 fastpath
    if (__mutex_owner(lock) == NULL) {
        atomic_long_set(&lock->owner, (long)current);
        spin_unlock(&lock->wait_lock);
        return;
    }

    // 3. 锁被持有，加入等待队列
    list_add_tail(&waiter.list, &lock->wait_list);
    waiter.task = current;

    // 4. 设置等待者标志（owner 最低位 = 1）
    atomic_long_or(MUTEX_FLAG_WAITERS, &lock->owner);

    // 5. 尝试 MCS 自旋锁（Oscar 的 MCS 锁）
    //    MCS 锁在本地 spinning，避免 cacheline bounce
    __mutex_acquire_slowpath(lock, &waiter);
}

// MCS 锁：每个等待者在本地 CPU 上自旋，避免全局竞争
// 只有一个 CPU 在 MCS 队列头部自旋
```

### 3.2 __mutex_acquire_slowpath — MCS 获取

```c
// kernel/locking/mutex.c — __mutex_acquire_slowpath
static noinline void __mutex_acquire_slowpath(struct mutex *lock, struct mutex_waiter *waiter)
{
    for (;;) {
        // 1. 标记当前进程为睡眠
        set_current_state(TASK_UNINTERRUPTIBLE);

        // 2. 检查锁是否已释放
        if (__mutex_owner(lock) == NULL) {
            atomic_long_set(&lock->owner, (long)current);
            return;  // 获取成功
        }

        // 3. 自旋等待（O(1) MCS 锁）
        osq_lock(&lock->osq);
        osq_unlock(&lock->osq);
    }
}
```

---

## 4. 解锁路径

### 4.1 mutex_unlock — 解锁

```c
// kernel/locking/mutex.c — mutex_unlock
void __sched mutex_unlock(struct mutex *lock)
{
    // 1. fastpath：直接清除 owner（假设没有等待者）
    if (atomic_long_try_cmpxchg_release(&lock->owner, (long)current, 0UL)) {
        // CAS 成功，锁已释放

        // 2. 如果有等待者，唤醒
        if (waitqueue_active(&lock->wait_list))
            __mutex_wake_waiters(lock);
        return;
    }

    // 3. slowpath：有等待者，不能用 fastpath
    __mutex_unlock_slowpath(lock);
}

// waitqueue_active：检查等待队列是否非空
#define waitqueue_active(wq) (!list_empty(&(wq)->head))
```

### 4.2 __mutex_wake_waiters — 唤醒等待者

```c
// kernel/locking/mutex.c — __mutex_wake_waiters
static void __mutex_wake_waiters(struct mutex *lock)
{
    struct mutex_waiter *waiter;

    // 唤醒等待队列中的第一个进程
    waiter = list_first_entry(&lock->wait_list, struct mutex_waiter, list);
    wake_up_process(waiter->task);  // 唤醒进程
}
```

---

## 5. MCS 自旋锁（Oscars MCS）

### 5.1 什么是 MCS 锁

```
传统自旋锁问题：
  所有 CPU 都在一个共享变量（locked）上自旋
  → cacheline 在多个 CPU 间 bouncing
  → 性能差

MCS 锁解决方案：
  每个 CPU 有一个本地自旋变量
  形成链：CPU1 → CPU2 → CPU3
  只有队列尾部的 CPU 在自旋
  → 最多只有一个 CPU 在某个 cacheline 上自旋

Linux 实现：osq（optimistic spinning queue）
```

### 5.2 osq_lock / osq_unlock

```c
// kernel/locking/mutex.c — osq_lock
struct optimistic_spin_node *osq_lock(struct optimistic_spin_queue *osq)
{
    struct optimistic_spin_node *node, *prev;

    node = this_cpu_ptr(osq->nodes);  // 本地节点
    node->locked = false;  // 未获得锁
    node->next = NULL;

    // 加入队列（prev 是原尾部）
    prev = atomic_long_xchg(&osq->tail, (long)node);
    if (prev) {
        prev->next = node;  // prev 的 next 指向 node
        // 自旋等待 node->locked 变为 true
        while (!READ_ONCE(node->locked))
            cpu_relax();
    }

    // 如果 prev = NULL（队列原来为空），直接获得锁
    return prev;
}
```

---

## 6. 调度属性

### 6.1 __sched

```c
// mutex_lock() = __sched mutex_lock()
// __sched 表示此函数可能引起调度（schedule）
// 自旋时如果遇到更高优先级进程，可以被抢占

// __mutex_lock_slowpath 会调用 schedule()
// 导致当前进程让出 CPU
```

---

## 7. 与 spinlock 的对比

| 特性 | mutex | spinlock |
|------|-------|---------|
| 持有锁时睡眠 | ✓（必须）| ✗（禁止）|
| 上下文 | 进程上下文 | 任意上下文 |
| 抢占 | 可以 | 不可以（禁抢占）|
| 延迟 | 上下文切换开销 | 自旋开销 |
| 适用 | 长临界区 | 短临界区 |

---

## 8. 内核使用案例

### 8.1 文件系统锁

```c
// fs/inode.c — struct inode
struct mutex i_mutex;  // 保护 inode 的某些操作
// 用于：mkdir, rmdir, rename 等目录操作
```

### 8.2 进程退出锁

```c
// kernel/exit.c — cred_guard_mutex
// 防止凭证被 concurrent 修改
```

---

## 9. 设计决策总结

| 设计决策 | 原因 |
|---------|------|
| owner = task_struct* + flags | 节省空间，同时记录持有者和状态 |
| MCS 自旋锁 | 避免 cacheline bounce |
| TASK_UNINTERRUPTIBLE | 持有互斥锁时不可被信号打断（否则会导致死锁）|
| wait_list FIFO | 公平锁（谁先等谁先得）|

---

## 10. 完整文件索引

| 文件 | 函数/结构 | 行 |
|------|----------|-----|
| `include/linux/mutex.h` | `struct mutex` | 34 |
| `include/linux/mutex.h` | `__MUTEX_INITIALIZER`、`DEFINE_MUTEX` | 79 / 86 |
| `kernel/locking/mutex.c` | `__mutex_owner` | 函数 |
| `kernel/locking/mutex.c` | `__mutex_trylock_fast` | 函数 |
| `kernel/locking/mutex.c` | `__mutex_lock_slowpath` | 函数 |
| `kernel/locking/mutex.c` | `mutex_unlock` | 函数 |
| `kernel/locking/mutex.c` | `osq_lock`、`osq_unlock` | MCS 锁 |

---

## 11. 西游记类比

**mutex** 就像"取经路上的山洞门禁"——

> 悟空要进一个山洞（临界区），先看看门是否开着（owner = NULL）。如果开着，悟空刷卡进入（CAS 设置 owner =悟空），其他人看到门关了就不进来了（trylock 失败）。如果门已经关了，悟空就在门口排队（加入 wait_list），并告诉门卫"有等待者"（MUTEX_FLAG_WAITERS）。洞口有 MCS 自旋锁，只有排第一的悟空能在门口自旋等（减少 cacheline bounce）。门开的时候，悟空先进去，其他排队的人继续等。出来时，悟空把门卡清零（owner = 0），然后叫醒下一个人（MCS 自旋 + wake_up）。注意：拿着钥匙睡觉的人不能被信号打断（ TASK_UNINTERRUPTIBLE），否则山洞就永远锁着了。

---

## 12. 关联文章

- **wait_queue**（article 07）：mutex 内部使用 wait_queue 管理等待者
- **spinlock**（article 09）：另一种锁机制，适用于不同场景
- **MCS lock**（OS concepts）：optimistic spinning queue 的理论基础