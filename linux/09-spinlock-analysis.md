# 09-spinlock — 自旋锁深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**自旋锁（spinlock）** 是 Linux 内核中最底层的锁机制。与 mutex 不同，自旋锁在获取失败时会**原地自旋转**（busy-wait），不会睡眠。这使得自旋锁可以在中断上下文和进程上下文使用，但临界区必须极短。

spinlock 的发展经历了三代演变：
1. **原始 ticket spinlock** — 公平但 cache line bouncing 严重
2. **MCS queued spinlock** — 减少 cache 竞争（x86 默认）
3. **Generic qspinlock** — 架构无关的队列自旋锁

本文分析的是当前 64 位架构默认使用的 **qspinlock（queued spinlock）**。

---

## 1. 核心数据结构

### 1.1 struct spinlock——用户接口

```c
// include/linux/spinlock_types.h
typedef struct spinlock {
    union {
        struct raw_spinlock rlock;    // 底层实现
    };
} spinlock_t;

typedef struct raw_spinlock {
    arch_spinlock_t raw_lock;         // 架构特定实现
} raw_spinlock_t;
```

### 1.2 arch_spinlock_t——qspinlock（`include/asm-generic/qspinlock_types.h`）

```c
typedef struct qspinlock {
    union {
        atomic_t val;                 // 32 位原子值

        struct {
            u16    locked;            // bit 0: 锁持有者
            u16    pending;           // 等待获取锁的任务数
        };
    };
} arch_spinlock_t;
```

`val` 的编码方式：

```
  bit  0    = locked  (1 = 锁被持有)
  bit  1    = pending (1 = 有等待者正在试图获取)
  bit 2-7   = index   (在 MCS 数组中的索引)
  bit 8-31  = tail    (MCS 队列尾部)
```

---

## 2. 快速路径（无竞争）

### 2.1 spin_lock（`include/linux/spinlock.h:363`）

```c
static __always_inline void spin_lock(spinlock_t *lock)
{
    raw_spin_lock(&lock->rlock);
}
```

`raw_spin_lock` 最终调用架构特定的快速路径：

```c
// qspinlock 快速路径
static __always_inline void queued_spin_lock(struct qspinlock *lock)
{
    u32 val = atomic_read(&lock->val);

    // 快速路径：锁空闲时直接尝试获取
    if (likely(val == 0)) {                    // val == 0 = 空闲
        if (atomic_try_cmpxchg_acquire(&lock->val, &val, _Q_LOCKED_VAL))
            return;                            // 获取成功！一条 CAS 搞定
    }

    // 慢速路径：有竞争
    queued_spin_lock_slowpath(lock, val);
}
```

**快速路径只有一条 CAS 指令**——在无竞争场景下效率极高。

---

## 3. 慢速路径（qspinlock_slowpath）

当锁已被持有时，`queued_spin_lock_slowpath` 负责管理等待者。它是自旋锁的核心：

```
queued_spin_lock_slowpath(lock, val)
  │
  ├─ [Phase 1] Pending 位争取
  │    └─ 如果只有 locked=1，没有 pending，没有队列
  │         └─ 尝试设置 pending=1
  │         └─ 成功 → 等待 locked 清零 → 获取锁
  │
  ├─ [Phase 2] 加入 MCS 队列
  │    └─ 在 MCS 数组中分配一个节点
  │    └─ 通过 CAS 将自己链接到队列尾部
  │    └─ 在本地 MCS 节点上自旋（无 cache line 竞争）
  │
  ├─ [Phase 3] 排队自旋
  │    └─ 读取前驱节点的 next 指针
  │    └─ 前驱释放后，自己的节点被置为 locked
  │
  └─ [Phase 4] 获取锁
       └─ 从 MCS 队列头部获取锁
       └─ 设置 locked=1
```

---

## 4. 解锁路径

```c
static __always_inline void queued_spin_unlock(struct qspinlock *lock)
{
    smp_store_release(&lock->locked, 0);  // 清零 locked 位
}
```

一次 release store 即可完成。如果队列中有等待者，MCS 机制会自动将锁传递给下一个节点。

---

## 5. spin_lock_irqsave

```c
static __always_inline unsigned long spin_lock_irqsave(spinlock_t *lock)
{
    unsigned long flags;

    local_irq_save(flags);     // 关闭本地中断
    raw_spin_lock(&lock->rlock);

    return flags;              // flags 在 spin_unlock_irqrestore 中使用
}
```

关闭中断+获取锁——防止中断处理程序和进程上下文之间的死锁。解锁时用 `spin_unlock_irqrestore` 恢复中断状态。

---

## 6. 关键 API 族

| API | 中断状态 | 适用场景 |
|-----|---------|---------|
| `spin_lock` / `spin_unlock` | 不影响 | 进程上下文，无中断竞争 |
| `spin_lock_irq` / `spin_unlock_irq` | 关开中断 | 知道中断之前是开的 |
| `spin_lock_irqsave` / `spin_unlock_irqrestore` | 保存/恢复 | 不知道中断状态 |
| `spin_lock_bh` / `spin_unlock_bh` | 关开 softirq | 防止 softirq 竞争 |

---

## 7. 数据类型流

```
lock-free fastpath:
  spin_lock(lock)
    └─ CAS(lock->val, 0, _Q_LOCKED_VAL)    ← 一条指令
    └─ memory barrier (acquire)

lock-contended slowpath:
  spin_lock(lock)
    └─ CAS(lock->val, owner, pending+tail)  ← 加入 MCS 队列
    └─ while (my_node->locked == 0)         ← 本地自旋
    │      cpu_relax()
    └─ 获取锁

unlock:
  spin_unlock(lock)
    └─ smp_store_release(&lock->locked, 0)   ← release 语义
    └─ MCS 队列中下一个节点被唤醒
```

---

## 8. MCS vs Ticket 对比

| 特性 | Ticket spinlock | MCS qspinlock |
|------|----------------|---------------|
| 公平性 | ✅ FIFO | ✅ FIFO |
| cache bouncing | ❌ 全局变量 | ✅ 本地节点 |
| 空间开销 | 低 | 中（MCS 数组）|
| 64 位支持 | 差 | 好 |

每个 CPU 在 MCS 数组中有预分配的本地节点，自旋在自己的节点上，不会触发全局 cache line 失效。

---

## 9. 设计决策总结

| 决策 | 原因 |
|------|------|
| 快速路径 CAS | 无竞争时 O(1) |
| MCS 队列 | 避免 cache line bouncing |
| pending 位 | 减少不必要队列操作 |
| smp_store_release 解锁 | 保证 memory ordering |
| local_irq_save | 防止中断上下文死锁 |

---

## 10. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/spinlock.h` | `spin_lock` 宏族 | ~363 |
| `include/linux/spinlock_types.h` | `struct spinlock` | |
| `include/asm-generic/qspinlock.h` | `queued_spin_lock` | |
| `include/asm-generic/qspinlock_types.h` | `struct qspinlock` | |
| `kernel/locking/qspinlock.c` | `queued_spin_lock_slowpath` | |

---

## 11. 关联文章

- **mutex**（article 08）：另一种锁，允许持有者睡眠
- **rwsem**（article 10）：读写信号量，使用类似的自旋锁思路
- **MCS lock**：自旋锁的底层契约

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
