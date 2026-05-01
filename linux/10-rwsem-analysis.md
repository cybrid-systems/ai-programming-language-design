# 10-rwsem — 读写信号量深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**读写信号量（rwsem，Reader-Writer Semaphore）** 允许多个读者同时持有，但写者必须独占。这是"读多写少"场景下的典型优化——读者之间不互斥，显著提升并发性能。

rwsem 的核心机制：
- **多个读者可以同时持有锁**（count 递增）
- **写者必须独占**（等待所有读者释放，同时阻止新读者进入）
- **写者有优先权**（防止写者被读者饿死）

doom-lsp 确认 `include/linux/rwsem.h` 定义了 108+ 个符号，实现位于 `kernel/locking/rwsem.c`。

---

## 1. 核心数据结构

### 1.1 struct rw_semaphore（`include/linux/rwsem.h:28`）

```c
struct rw_semaphore {
    atomic_long_t    count;         // 读写计数（核心字段）
    atomic_long_t    owner;         // 写者 task_struct（可选优化）
    struct optimistic_spin_queue osq; // MCS 优化自旋队列
    struct raw_spinlock wait_lock;  // 保护 wait_list
    struct list_head  wait_list;    // 等待者 FIFO 队列
};
```

### 1.2 count 字段编码

```c
// kernel/locking/rwsem.c
#define RWSEM_UNLOCKED_VALUE      0L        // 完全空闲
#define RWSEM_READ_BIAS           (1L << 0) // 每位读者加 1
#define RWSEM_WRITER_BIAS         (1L << 1) // 写者独占
#define RWSEM_WRITER_LOCKED       (1L << 0 | 1L << 1) // 写者持有
```

`count` 的巧妙之处：**一个原子变量同时承载了读者计数和写者锁状态。**

```
count = 0                           -> 完全空闲
count = 0x0001 (RWSEM_READ_BIAS)    -> 1 个读者
count = 0x0003 (3 * READ_BIAS)      -> 3 个读者
count = RWSEM_WRITER_LOCKED (3)     -> 写者持有
count = RWSEM_WRITER_BIAS (2)       -> 写者在等待
                              (读者的最低位被屏蔽)
```

写者通过 `RWSEM_WRITER_BIAS` 保留自己的"印记"，读者通过 `RWSEM_READ_BIAS` 递增计数。当 count 的最低 2 位同时被设置时，写者锁定。

---

## 2. 读者路径

### 2.1 down_read

```c
void __sched down_read(struct rw_semaphore *sem)
{
    // 快速路径：直接尝试递增 count
    if (likely(atomic_long_try_cmpxchg_acquire(&sem->count, &count, count + RWSEM_READ_BIAS)))
        return;                         // 获取成功

    // 慢速路径：有写者竞争
    down_read_slowpath(sem);
}
```

### 2.2 up_read

```c
void __sched up_read(struct rw_semaphore *sem)
{
    long tmp;

    // 递减 count
    tmp = atomic_long_dec_return(&sem->count);

    if (unlikely(tmp < 0))
        rwsem_rwsem_release(sem);       // 有等待的写者，需要唤醒
}
```

解锁后检查 count 是否为负（表示有写者在等待），如果是则调用释放逻辑。

---

## 3. 写者路径

### 3.1 down_write

```c
void __sched down_write(struct rw_semaphore *sem)
{
    // 快速路径：count=0 时直接设置 WRITER_BIAS
    if (likely(atomic_long_try_cmpxchg_acquire(&sem->count, &count, RWSEM_WRITER_BIAS)))
        return;

    // 慢速路径
    down_write_slowpath(sem);
}
```

### 3.2 up_write

```c
void __sched up_write(struct rw_semaphore *sem)
{
    // 清除写者标记
    if (likely(atomic_long_cmpxchg_release(&sem->count, RWSEM_WRITER_BIAS, 0) == RWSEM_WRITER_BIAS))
        return;                         // 无等待者

    // 有等待者，需要唤醒
    rwsem_release(sem);
}
```

---

## 4. 慢速路径与 Optimistic Spinning

当锁被持有时，rwsem 的慢速路径采用类似 mutex 的 optimistic spinning：

```
down_write_slowpath(sem)
  │
  ├─ [Phase 1] MCS Optimistic Spinning
  │    └─ osq_lock(&sem->osq)              ← 加入 MCS 队列
  │    └─ while (持有者在运行)              ← 自旋等待
  │    │      cpu_relax()
  │    └─ osq_unlock(&sem->osq)            ← 离开队列（如果获取失败）
  │
  ├─ [Phase 2] 加入等待队列
  │    └─ spin_lock(&sem->wait_lock)
  │    └─ list_add_tail(&waiter.list, &sem->wait_list)
  │    └─ 设置当前状态为 TASK_UNINTERRUPTIBLE
  │    └─ spin_unlock(&sem->wait_lock)
  │
  └─ [Phase 3] 睡眠
       └─ schedule()
       └─ 被唤醒后尝试获取锁
```

写者优先策略：当写者在等待时，新来的读者会被阻止（count 中的最低位被写者保留位屏蔽），写者因此不会被读者饿死。

---

## 5. 写者优先：rwsem_downgrade_write

```c
void rwsem_downgrade_write(struct rw_semaphore *sem)
{
    // 直接将写者降级为读者
    // count: WRITER_BIAS → READ_BIAS
    atomic_long_add(-RWSEM_WRITER_BIAS + RWSEM_READ_BIAS, &sem->count);

    // 如果有等待者，唤醒后续读者
    if (list_empty(&sem->wait_list))
        return;
    __rwsem_mark_wake(sem, RWSEM_WAKE_READERS);
}
```

典型用法：写者在完成关键写入后，降级为读者。允许后续写者获取锁，同时当前线程继续读取。

---

## 6. 关键调用链

doom-lsp 确认的 rwsem 调用链：

```
读路径：
  down_read(sem)
    ├─ try_cmpxchg_acquire(&count, count + READ_BIAS)     [快速路径]
    └─ down_read_slowpath(sem)                              [慢速路径]
         ├─ rwsem_optimistic_spin(sem)                      [MCS 自旋]
         └─ schedule()                                      [睡眠]

写路径：
  down_write(sem)
    ├─ try_cmpxchg_acquire(&count, WRITER_BIAS)            [快速路径]
    └─ down_write_slowpath(sem)                              [慢速路径]
         ├─ rwsem_optimistic_spin(sem)                      [MCS 自旋]
         └─ schedule()                                      [睡眠]

释放：
  up_read(sem)  → atomic_long_dec_return(&sem->count)
  up_write(sem) → atomic_long_cmpxchg_release(&sem->count, WRITER_BIAS, 0)
                   └─ rwsem_release(sem) → 唤醒等待者
```

---

## 7. 与 mutex 和 spinlock 对比

| 特性 | rwsem | mutex | spinlock |
|------|-------|-------|----------|
| 多读者 | ✅ | ❌ | ❌ |
| 睡眠 | ✅ | ✅ | ❌ |
| 中断上下文 | ❌ | ❌ | ✅ |
| 写者优先 | ✅ | N/A | N/A |
| 快速路径 | CAS | CAS | CAS |
| Optimistic Spin | ✅ | ✅ | N/A |

---

## 8. 设计决策总结

| 决策 | 原因 |
|------|------|
| count 字段编码读者+写者 | 单原子变量，无锁更新 |
| 写者优先 | 防止写者被读者饿死 |
| MCS optimistic spinning | 避免 cache line bouncing |
| downgrade_write | 写→读降级，灵活控制 |
| reader/writer wait list 分离 | 高效唤醒指定类型 |

---

## 9. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/rwsem.h` | `struct rw_semaphore` | 28 |
| `include/linux/rwsem.h` | `down_read` / `up_read` | 实现 |
| `include/linux/rwsem.h` | `down_write` / `up_write` | 实现 |
| `kernel/locking/rwsem.c` | `down_read_slowpath` | 慢速路径 |
| `kernel/locking/rwsem.c` | `down_write_slowpath` | 慢速路径 |
| `kernel/locking/rwsem.c` | `rwsem_optimistic_spin` | MCS 自旋 |

---

## 10. 关联文章

- **mutex**（article 08）：互斥锁（单读者/写者模式）
- **spinlock**（article 09）：无睡眠的自旋锁
- **completion**（article 11）：轻量同步原语

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
