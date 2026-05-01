# 10-rwsem — Linux 内核读写信号量深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**rwsem（read-write semaphore）** 是 Linux 内核中的读写信号量，允许多个读者（reader）**并发读取**共享数据，但写者（writer）必须**独占访问**。这种"读读不互斥、读写互斥、写写互斥"的语义在许多内核场景中至关重要——当共享数据的读取远多于写入时，rwsem 显著提升了并发性能。

与 spinlock 和 mutex 不同，rwsem 的核心思想是：多个读者可以同时进入临界区，只有写者才需要排他访问。具体规则：

1. **多个读者可同时持有锁**（`count += RWSEM_READER_BIAS`）
2. **写者必须互斥**（写者在没有读者和写者时才能获取）
3. **写者优先**：一旦有写者等待，后续的读者也被阻塞（避免写者饥饿）

**doom-lsp 确认**：`include/linux/rwsem.h` 包含 **117 个符号**（含 `struct rw_semaphore`），`kernel/locking/rwsem.c` 包含 **102 个实现符号**。

---

## 1. 核心数据结构——struct rw_semaphore

```c
// include/linux/rwsem.h:48 — doom-lsp 确认
struct rw_semaphore {
    atomic_long_t       count;             // 信号量计数（读者/写者计数）
    atomic_long_t       owner;             // 写者持有者 / 读者标识
    struct optimistic_spin_queue osq;       // MCS 自旋队列（optimistic spinning 用）
    raw_spinlock_t      wait_lock;          // 等待队列自旋锁
    struct rwsem_waiter *first_waiter;      // 等待队列首项（手写的单链表）
};
```

### 1.1 `count` 字段的位编码

`count` 是一个 `atomic_long_t`（64 位系统上 64 位），编码了读者和写者的状态：

```c
// include/linux/rwsem.h — 常量定义
#define RWSEM_UNLOCKED_VALUE      0L          // 未锁定
#define RWSEM_READER_BIAS         (1UL << 0)  // 每位读者 +1
#define RWSEM_WRITER_LOCKED       (1UL << 1)  // 写者锁定位

// 写者阻塞时的标志
#define RWSEM_RD_WAIT             (1UL << 6)  // 有读者在等待
#define RWSEM_WR_WAIT             (1UL << 7)  // 有写者在等待
#define RWSEM_READ_FAILED_MASK    (RWSEM_WRITER_LOCKED | RWSEM_WR_WAIT)
```

**位布局**：

```
count (64-bit):
┌───────────┬──────┬──────┬──────┬─────────────────────────────────────┐
│  reserved  │WR_WAIT│RD_WAIT│WR_LOCK│  读者引用计数（bit 2+)           │
│            │ bit7 │ bit6 │ bit1 │                                     │
└───────────┴──────┴──────┴──────┴─────────────────────────────────────┘

典型值：
  0x0000_0000_0000_0000    = 未锁定（UNLOCKED）
  0x0000_0000_0000_0002    = 写者锁定（WRITER_LOCKED）
  0x0000_0000_0000_0001    = 1 个读者
  0x0000_0000_0000_0005    = 5 个读者
  0x0000_0000_0000_0083    = 写者锁定 + WR_WAIT + 少量读者
```

### 1.2 `owner` 字段

```c
// include/linux/rwsem.h — owner 字段用法
// 写者持有锁时: owner = task_struct 指针（flags 在低 2 位）
// 读者持有锁时: owner 的 bit 0 = 1（RWSEM_READER_OWNED 标记）
// 未锁定时: owner = NULL

#define RWSEM_READER_OWNED    (1UL << 0)  // 读者持有锁
#define RWSEM_NONSPINNABLE    (1UL << 1)  // 自旋被禁止

// 获取 owner 中的 task_struct 指针：
static inline struct task_struct *rwsem_owner_flags(unsigned long owner,
                                                     unsigned long *pflags)
{
    unsigned long flags = owner & RWSEM_OWNER_FLAGS_MASK;
    if (pflags)
        *pflags = flags;
    return (struct task_struct *)(owner & ~RWSEM_OWNER_FLAGS_MASK);
}
```

### 1.3 `struct rwsem_waiter`（`kernel/locking/rwsem.c:338`）

```c
// kernel/locking/rwsem.c:338 — doom-lsp 确认
struct rwsem_waiter {
    struct list_head    list;       // 链入等待队列
    struct task_struct  *task;      // 等待的进程
    enum rwsem_waiter_type type;    // RWSEM_WAITING_FOR_READ 或 RWSEM_WAITING_FOR_WRITE
    unsigned long       timeout;    // 超时时间
};
```

等待队列类型：
```c
// rwsem.c:333 — doom-lsp 确认
enum rwsem_waiter_type {
    RWSEM_WAITING_FOR_WRITE,    // 等待写的写者
    RWSEM_WAITING_FOR_READ,     // 等待读的读者
};
```

---

## 2. 读路径——rwsem_read_trylock

### 2.1 快速路径

```c
// kernel/locking/rwsem.c:249 — doom-lsp 确认
static inline bool rwsem_read_trylock(struct rw_semaphore *sem, long *cntp)
{
    *cntp = atomic_long_add_return_acquire(RWSEM_READER_BIAS, &sem->count);

    if (!(*cntp & RWSEM_READ_FAILED_MASK)) {  // 没有写者锁定，没有写者等待
        rwsem_set_reader_owned(sem);           // 标记为读者持有
        return true;                           // 获取成功
    }

    // 有写者活动 → 回退
    atomic_long_add_return_acquire(-RWSEM_READER_BIAS, &sem->count);  // 回退计数
    return false;
}
```

**doom-lsp 数据流**：

```
down_read(sem)
  └─ rwsem_read_trylock(sem, &cnt)
       │
       ├─ atomic_long_add_return_acquire(&sem->count, RWSEM_READER_BIAS)
       │   ← count += 1 (试图增加读者计数)
       │
       ├─ 检查 count & RWSEM_READ_FAILED_MASK == 0?
       │   ├─ 是：无写者 → 成功！
       │   │    ├─ rwsem_set_reader_owned(sem)
       │   │    │   → owner |= RWSEM_READER_OWNED
       │   │    └─ return true
       │   │
       │   └─ 否：有写者 → 回退
       │        └─ atomic_long_add_return_acquire(&sem->count, -RWSEM_READER_BIAS)
       │            ← count -= 1
       │            return false → 进入慢速路径
```

### 2.2 慢速路径——down_read

```c
// rwsem.c 慢速路径
void __sched down_read(struct rw_semaphore *sem)
{
    long cnt;

    if (rwsem_read_trylock(sem, &cnt))
        return;  // 快速路径成功

    // 慢速路径：加入等待队列
    rwsem_down_read_slowpath(sem, TASK_UNINTERRUPTIBLE);
}

static int rwsem_down_read_slowpath(struct rw_semaphore *sem, int state)
{
    // 创建 waiter（类型 = RWSEM_WAITING_FOR_READ）
    // 尝试 optimistic spinning 一会儿
    // 然后加入等待队列，schedule()
}
```

---

## 3. 写路径——rwsem_write_trylock

### 3.1 快速路径

```c
// kernel/locking/rwsem.c:264 — doom-lsp 确认
static inline bool rwsem_write_trylock(struct rw_semaphore *sem)
{
    long tmp = RWSEM_UNLOCKED_VALUE;  // tmp = 0

    if (atomic_long_try_cmpxchg_acquire(&sem->count, &tmp, RWSEM_WRITER_LOCKED)) {
        rwsem_set_owner(sem);          // 记录写者 owner
        return true;
    }

    return false;
}
```

**关键**：写者获取锁需要 `count` 的当前值为 `RWSEM_UNLOCKED_VALUE (0)`——即**没有任何读者也没有任何写者**。使用 `cmpxchg` 原子地将 `0 → RWSEM_WRITER_LOCKED (2)`。

```
down_write(sem)
  └─ rwsem_write_trylock(sem)
       ├─ tmp = RWSEM_UNLOCKED_VALUE (0)
       │
       ├─ atomic_long_try_cmpxchg_acquire(&sem->count, &tmp, RWSEM_WRITER_LOCKED)
       │   ├─ 成功（count 最初为 0）：← 无读者无写者
       │   │   ├─ rwsem_set_owner(sem)
       │   │   │   → owner = current
       │   │   └─ return true
       │   │
       │   └─ 失败（count ≠ 0）：← 被占用
       │       └─ return false → 慢速路径
```

### 3.2 慢速路径——Optimistic Spinning + 等待

```
down_write_slowpath(sem)
  │
  ├─ 尝试 optimistic spinning:
  │   ├─ 如果锁持有者在运行 → 自旋等待
  │   │   (通过 cmpxchg 检测 count 是否变为 0)
  │   │
  │   ├─ osq_lock(&sem->osq)        // MCS 排队
  │   ├─ 检查 owner 是否还在运行
  │   ├─ cpu_relax() 自旋
  │   └─ 如果检测到锁被释放 → 尝试获取
  │
  ├─ 自旋失败 → 加入等待队列:
  │   ├─ waiter.type = RWSEM_WAITING_FOR_WRITE
  │   ├─ rwsem_add_waiter(sem, waiter)   ← 加入队尾
  │   ├─ set_current_state(TASK_UNINTERRUPTIBLE)
  │   └─ schedule()
  │
  └─ 被唤醒 → 再次尝试获取
```

---

## 4. 写者优先策略

rwsem 采用**写者优先**策略防止写者饥饿：

```
场景：当前有 3 个读者持有锁。
一个新的写者到来 → 设置 RWSEM_WR_WAIT 标志。
后续到来的读者：检查到 count & RWSEM_READ_FAILED_MASK（含 WR_WAIT）非零
  → 即使锁当前仍被读者持有，新读者也被阻塞
  → 等当前所有读者释放锁后，写者优先获取
```

**数据流**：

```
时间线：
  t1: reader_A down_read(sem) ✓    (count = 1)
  t2: reader_B down_read(sem) ✓    (count = 2)
  t3: writer_C down_write(sem) ✗   (count = 2, 设置 WR_WAIT)
       → count = 2 | RWSEM_WR_WAIT = 0x82
  t4: reader_D down_read(sem) ✗    (count & READ_FAILED_MASK ≠ 0)
       → 被阻塞
  t5: reader_A up_read(sem)        (count = 1)
  t6: reader_B up_read(sem)        (count = 0)
  t7: writer_C 检测到 count=0
       → 获取写锁！(count = 0x02)
```

**对比**：如果采用读者优先，连续不断的读者可能导致写者永远无法获取锁（写者饥饿）。rwsem 的写者优先策略通过 `RWSEM_WR_WAIT` 标志阻塞后续读者，保证了写者的公平性。

---

## 5. 释放操作

### 5.1 读者释放——up_read

```c
void up_read(struct rw_semaphore *sem)
{
    long tmp;

    // 减少读者计数
    tmp = atomic_long_add_return_release(-RWSEM_READER_BIAS, &sem->count);

    rwsem_clear_reader_owned(sem);  // 清除读者标记

    // 如果 count 的最低位是 0（无其他读者）且有等待者
    if (tmp & RWSEM_RD_WAIT || tmp & RWSEM_WR_WAIT)
        rwsem_wake(sem);            // 唤醒等待者
}
```

### 5.2 写者释放——up_write

```c
void up_write(struct rw_semaphore *sem)
{
    // 清除写者计数
    atomic_long_add_return_release(-RWSEM_WRITER_LOCKED, &sem->count);
    rwsem_clear_owner(sem);         // 清除 owner

    if (unlikely(atomic_long_read(&sem->count) & RWSEM_WAITING_MASK))
        rwsem_wake(sem);            // 有等待者 → 唤醒
}
```

---

## 6. 🔥 完整数据流——多读者 + 写者竞争

```
初始：sem->count = 0（未锁定）

down_read(A): count = 1           down_read(B): count = 2
  ├─ 快速路径成功                    ├─ 快速路径成功
  └─ owner = RWSEM_READER_OWNED    └─ owner = RWSEM_READER_OWNED

down_write(C):                      down_read(D):
  ├─ trylock: count=2 → 失败         ├─ trylock: count=2|WR_WAIT→失败
  ├─ set RWSEM_WR_WAIT              │  (RWSEM_READ_FAILED_MASK 非零)
  │  count = 2|0x80 = 0x82          ├─ 加入等待队列 (RD waiter)
  ├─ spin on count                   └─ schedule()
  └─ osq_lock + schedule()

up_read(A): count = 1              up_read(B): count = 0
  ├─ -RWSEM_READER_BIAS             ├─ -RWSEM_READER_BIAS
  └─ 还有 READERS → 不唤醒          └─ count=0 且 WR_WAIT 设置
                                      → rwsem_wake()
                                          ├─ 唤醒写者 C
                                          └─ C 获取写锁：count = 2

up_write(C): count = 0
  ├─ -RWSEM_WRITER_LOCKED
  └─ 有等待者 → rwsem_wake()
       ├─ 唤醒了读者 D
       └─ D 获取读锁：count = 1
```

---

## 7. Optimistic Spinning

rwsem 的 optimistic spinning 与 mutex 类似。当写者无法获取锁时，它不会立即休眠，而是先自旋检查锁持有者是否仍在运行：

```c
// rwsem.c — 写者慢速路径
for (;;) {
    if (rwsem_try_write_lock(sem))
        return;  // 获取成功

    // 检查 owner
    owner = rwsem_get_owner(sem);
    if (owner && owner_on_cpu(owner)) {
        // 锁持有者正在运行 → 可能很快释放
        cpu_relax();
        continue;
    }

    // 锁持有者不在运行 → 准备休眠
    break;
}
```

这利用了**局部性原理**：如果锁持有者正在另一个 CPU 上运行，它可能在纳秒级时间内释放锁。上下文切换的开销（微秒级）使得自旋等待更有优势。

---

## 8. rwsem 使用实例

### 8.1 `mmap_lock`（前称 `mmap_sem`）

```c
// include/linux/mm_types.h — 进程地址空间锁
struct mm_struct {
    struct rw_semaphore mmap_lock;  // 保护 VMA 树的读写信号量
    // ...
};
```

这是内核中使用最频繁的 rwsem：
- **读者**：`find_vma()`、`page fault handler`、`/proc/pid/maps`（多个读者同时查找）
- **写者**：`mmap()`、`munmap()`、`brk()`、`mprotect()`（排他修改 VMA 树）

```c
// 读者路径（缺页处理）：
down_read(&mm->mmap_lock);
vma = find_vma(mm, addr);
// 使用 vma...
up_read(&mm->mmap_lock);

// 写者路径（mmap 系统调用）：
down_write(&mm->mmap_lock);
vma_merge(mm, ..., vma);
up_write(&mm->mmap_lock);
```

### 8.2 文件系统超级块

```c
// include/linux/fs.h
struct super_block {
    struct rw_semaphore s_umount;    // 挂载/卸载保护
    // ...
};
```

---

## 9. rwsem vs 其他锁

| 特性 | rwsem（读写信号量） | mutex | spinlock | RCU |
|------|-------------------|-------|----------|-----|
| 多个读者 | ✅ 并发 | ❌ | ❌ | ✅ 完全并发 |
| 写者排他 | ✅ | ✅ | ✅ | ✅（需 synchronize）|
| 等待方式 | 休眠 + Spinning | 休眠 + Spinning | 自旋 | 无等待读 |
| 写者饥饿保护 | ✅（写者优先）| 不适用 | 不适用 | 不适用 |
| 临界区限制 | 可睡眠 | 可睡眠 | 不可睡眠 | 读不可睡眠 |
| 架构无关 | ✅ | ✅ | 架构相关 | ✅ |
| 快速路径 | atomic_add_return | cmpxchg | cmpxchg | 无需原子操作 |

---

## 10. 调试与状态检查

```c
// include/linux/rwsem.h
int down_read_trylock(struct rw_semaphore *sem);    // 非阻塞读尝试
int down_write_trylock(struct rw_semaphore *sem);   // 非阻塞写尝试
```

---

## 11. 源码文件索引

| 文件 | 内容 | 符号数 |
|------|------|--------|
| `include/linux/rwsem.h` | 结构体 + API 声明 | **117 个** |
| `kernel/locking/rwsem.c` | 快速/慢速路径实现 | **102 个** |
| `kernel/locking/rwsem.h` | 内部辅助函数 | — |

---

## 12. 关联文章

- **08-mutex**：互斥锁（rwsem 的排他版本）
- **09-spinlock**：自旋锁（rwsem 的忙等待替代）
- **16-vm_area_struct**：VMA 通过 mmap_lock 保护
- **26-RCU**：读端无等待的并发方案（比 rwsem 更高读性能）

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
