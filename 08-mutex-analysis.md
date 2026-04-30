# mutex — 内核互斥锁深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/mutex.h` + `include/linux/mutex_types.h` + `kernel/locking/mutex.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**mutex** 是内核最简单的互斥锁，语义：
- **同一时刻只有一个持有者**
- **只有持有者才能解锁**
- **不允许递归**
- **不允许在中断上下文使用**

---

## 1. 核心数据结构

### 1.1 mutex — 互斥锁

```c
// include/linux/mutex_types.h — mutex (非 RT)
context_lock_struct(mutex) {
    atomic_long_t       owner;         // 持有者（task_struct* + 标志）
    raw_spinlock_t     wait_lock;     // 保护等待链表
#ifdef CONFIG_MUTEX_SPIN_ON_OWNER
    struct optimistic_spin_queue osq;   // MCS 自旋锁（optimistic spinning）
#endif
    struct mutex_waiter *first_waiter; // 等待者链表头
#ifdef CONFIG_DEBUG_MUTEXES
    void               *magic;        // 调试：魔数
#endif
#ifdef CONFIG_DEBUG_LOCK_ALLOC
    struct lockdep_map  dep_map;        // 调试：锁依赖图
#endif
};
```

### 1.2 owner 字段编码

```c
// kernel/locking/mutex.h — owner 编码
// owner = task_struct* + MUTEX_FLAGS（低 3 位）

struct task_struct *owner = (struct task_struct *)(owner_raw & ~MUTEX_FLAGS);
unsigned long flags = owner_raw & MUTEX_FLAGS;

// MUTEX_FLAGS 定义：
#define MUTEX_FLAG_WAITERS  0x01  // 有等待者（解锁时需要 wakeup）
#define MUTEX_FLAG_HANDOFF  0x02  // 互斥模式
#define MUTEX_FLAG_PICKUP   0x04  // 快速拾取
```

**owner == 0**：锁空闲

---

## 2. fastpath — 快速路径（乐观自旋）

### 2.1 __mutex_trylock_fast — O(1) 获取

```c
// kernel/locking/mutex.c
static inline bool __mutex_trylock_fast(struct mutex *lock)
{
    unsigned long owner = atomic_long_read(&lock->owner);

    // 如果 owner == 0（空闲），尝试原子交换
    if (owner)  // 非零 = 已被持有
        return false;

    return atomic_long_try_cmpxchg_acquire(&lock->owner, &owner, (long)current) != 0;
}
```

**原理**：
- 使用 `try_cmpxchg` 原子指令
- 如果 `lock->owner == 0`，设置为 `current`
- 成功 → 获取锁；失败 → 走慢路径

### 2.2 osq — MCS 自旋锁

**MCS（Michael-Scott）队列锁**：解决自旋锁的缓存一致性（cache bouncing）问题。

```
传统自旋：所有自旋线程竞争同一个变量 → 缓存行 ping-pong
MCS 自旋：每个线程在自己本地变量上自旋 → 只需一次写入
```

```
lock = &osq->queue
node = get_local_node()

// 加入队列
node->next = NULL
prev = atomic_xchg(lock, node)  // 原子替换，返回旧值
if (prev)
    prev->next = node           // 前驱指向自己

// 自旋等待
while (node->locked == 0)       // 本地变量，自旋
    cpu_relax();

// 锁持有者 unlock 时设置 node->locked = 1
```

---

## 3. slowpath — 慢路径（阻塞）

### 3.1 __mutex_lock_slowpath

```c
// kernel/locking/mutex.c
__mutex_lock_slowpath(lock)
{
    // 1. 加入等待队列
    mutex_waiter = alloc_mutex_waiter();
    mutex_waiter->task = current;

    spin_lock(&lock->wait_lock);
    // 插入到等待者链表（按 FIFO 顺序）
    if (lock->first_waiter == NULL)
        lock->first_waiter = mutex_waiter;
    else
        list_add_tail(&mutex_waiter->list, &lock->first_waiter->list);

    // 2. 设置 MUTEX_FLAG_WAITERS（告诉 unlock 需要 wakeup）
    atomic_long_or(MUTEX_FLAG_WAITERS, &lock->owner);

    // 3. 尝试乐观自旋（如果在等待队列）
    if (can_spin_on_owner(lock))
        optimistic_spin(lock);

    // 4. 阻塞等待
    for (;;) {
        set_current_state(TASK_UNINTERRUPTIBLE);
        if (__mutex_trylock(lock))
            break;
        schedule();
    }
    __set_current_state(TASK_RUNNING);

    // 5. 从等待队列移除
    spin_lock(&lock->wait_lock);
    list_del(&mutex_waiter->list);
    spin_unlock(&lock->wait_lock);
}
```

---

## 4. unlock — 解锁

### 4.1 mutex_unlock

```c
// kernel/locking/mutex.c
void __mutex_unlock(struct mutex *lock)
{
    // 1. 如果没有等待者，直接释放
    if (atomic_long_read(&lock->owner) & MUTEX_FLAG_WAITERS) {
        // 有等待者，走慢路径
        __mutex_unlock_slowpath(lock);
    } else {
        // 快速释放
        atomic_long_set(&lock->owner, 0);
    }
}
```

### 4.2 __mutex_unlock_slowpath

```c
// kernel/locking/mutex.c
__mutex_unlock_slowpath()
{
    // 1. 获取第一个等待者
    waiter = lock->first_waiter;

    // 2. 清除 MUTEX_FLAG_WAITERS
    atomic_long_andnot(MUTEX_FLAG_WAITERS, &lock->owner);

    // 3. 设置 HANDOFF（将锁交给等待者）
    atomic_long_or(MUTEX_FLAG_HANDOFF, &lock->owner);

    // 4. 唤醒等待者
    wake_up_process(waiter->task);
}
```

---

## 5. 状态转换图

```
锁空闲: owner = 0
    ↓
try_cmpxchg(current) 成功
    ↓
持有中: owner = current | 0
    ↓
有线程等待: owner |= MUTEX_FLAG_WAITERS
    ↓
解锁时检测到 WAITERS
    ↓
owner |= MUTEX_FLAG_HANDOFF
    ↓
wake_up_process(等待者)
    ↓
新持有者: owner = new_task | 0
```

---

## 6. 完整文件索引

| 文件 | 函数 |
|------|------|
| `include/linux/mutex_types.h` | `struct mutex` |
| `include/linux/mutex.h` | `__MUTEX_INITIALIZER`、`DEFINE_MUTEX` |
| `kernel/locking/mutex.h` | owner 编码、`__mutex_owner` |
| `kernel/locking/mutex.c` | `__mutex_trylock_fast`、`__mutex_lock_slowpath`、`__mutex_unlock_slowpath` |
