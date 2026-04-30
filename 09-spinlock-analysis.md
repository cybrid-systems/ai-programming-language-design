# Linux Kernel spinlock 自旋锁 — 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/spinlock.h` + `include/linux/spinlock_types.h` + `kernel/locking/spinlock.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 更新：整合 2026-04-22 学习笔记

---

## 0. 什么是 spinlock？

**spinlock** 是内核最轻量的**不可睡眠**互斥锁：
- 持锁期间 CPU 持续自旋（`pause` / `yield` 指令）
- 持有时间极短（< 20μs）
- 专用于**中断上下文**、**不可抢占上下文**、**原子上下文**

**核心约束**：
- 不可睡眠（`schedule()` 不可调用）
- 不可递归
- 持有时间必须极短

---

## 1. 核心数据结构

### 1.1 `spinlock_t` vs `raw_spinlock_t`

```c
// include/linux/spinlock_types.h — Linux 7.0

// 非 PREEMPT_RT：spinlock_t 直接映射到 raw_spinlock
context_lock_struct(spinlock) {
    union {
        struct raw_spinlock rlock;
#ifdef CONFIG_DEBUG_SPINLOCK
        unsigned int magic, owner_cpu;
        void *owner;
#endif
    };
#ifdef CONFIG_DEBUG_LOCK_ALLOC
    struct lockdep_map dep_map;
#endif
};

// raw_spinlock（裸锁）
typedef struct raw_spinlock {
    arch_spinlock_t raw_lock;   // 架构相关实现
#ifdef CONFIG_DEBUG_SPINLOCK
    unsigned int magic, owner_cpu;
    void *owner;
#endif
#ifdef CONFIG_DEBUG_LOCK_ALLOC
    struct lockdep_map dep_map;
#endif
} raw_spinlock_t;
```

### 1.2 `arch_spinlock_t` — qspinlock（ARM64 / x86 现代默认）

```c
// include/asm-generic/qspinlock_types.h
// 队列自旋锁，解决老 ticket lock 的 cacheline 颠簸问题

typedef struct qspinlock {
    union {
        atomic_t val;   // 完整的 32-bit 状态

        struct {
#ifdef __LITTLE_ENDIAN
            u8  locked;       // 锁持有标志（1 = 已锁定）
            u8  pending;     // 待处理标志（有人正在等待）
            u16 tail;        // 队尾（cpu id 编码）
#else
            // 大端序布局
#endif
        };
        struct {
            u16 locked_pending;
            u16 tail;
        };
    };
} arch_spinlock_t;

// qspinlock 编码（CONFIG_NR_CPUS < 16K）：
//  0-7  : locked byte（1 = 有持有者）
//  8    : pending（1 = 有人在等锁）
//  9-15 : (未用)
//  16-17: tail index（4 个候选队尾槽）
//  18-31: tail cpu（cpu id + 1）

// 锁状态：
//   val = 0              → 未锁定
//   locked = 1           → 已锁定（无排队）
//   pending = 1          → 有人在排队
//   tail = cpu_id << 2   → MCS 队列队尾
```

---

## 2. spinlock API 体系

```c
// include/linux/spinlock.h — 完整 API

// 基础加锁/解锁
void spin_lock(spinlock_t *lock);         // 不可中断
void spin_unlock(spinlock_t *lock);
bool spin_trylock(spinlock_t *lock);      // 非阻塞尝试

// 关闭中断版本（最常用，防止死锁）
void spin_lock_irqsave(spinlock_t *lock, unsigned long flags);
void spin_unlock_irqrestore(spinlock_t *lock, unsigned long flags);
void spin_lock_irq(spinlock_t *lock);              // 假设中断已关闭
void spin_unlock_irq(spinlock_t *lock);

// 关闭软中断版本
void spin_lock_bh(spinlock_t *lock);       // 关闭 softirq
void spin_unlock_bh(spinlock_t *lock);

// 初始化
#define DEFINE_SPINLOCK(x) spinlock_t x = __SPIN_LOCK_UNLOCKED(x)
static inline void spin_lock_init(spinlock_t *lock);

// 查询
bool spin_is_locked(spinlock_t *lock);
bool spin_is_contended(spinlock_t *lock);

// raw_spinlock（更底层）
void _raw_spin_lock(raw_spinlock_t *lock);
void _raw_spin_unlock(raw_spinlock_t *lock);
unsigned long _raw_spin_lock_irqsave(raw_spinlock_t *lock);
```

---

## 3. qspinlock 加锁流程

```
无竞争场景（cmpxchg 一次成功）：
  1. atomic_val = 0
  2. cmpxchg(&val, 0, my_ticket) → 成功，locked = 1

单核竞争（Per-CPU MCS 队列）：
  1. atomic_val = 0，CPU-A 抢到锁
  2. CPU-B 也来抢 → atomic_val 已非 0
  3. CPU-B 进入 MCS 队列：
     - 获取 pending 标志（val |= 0x100）
     - 自己设置 locked = 0（表示"待锁定"）
     - 加入队尾链表
  4. CPU-A 释放锁：
     - 检查 pending 标志
     - 发现有人等待 → 唤醒 CPU-B
     - CPU-B 的 locked 被设为 1 → 获得锁

多核 NUMA：
  qspinlock 的 MCS 队列节点是 per-cpu 的
  锁传递通过 next 指针，不产生全局 cacheline 竞争
```

---

## 4. raw_spinlock vs spinlock_t vs rwlock_t

| 类型 | 层级 | 适用场景 |
|------|------|---------|
| `raw_spinlock` | 最底层 | 中断关闭、scheduler、NMI |
| `spinlock_t` | 封装 raw_spinlock | 驱动、通用代码 |
| `rwlock_t` | 读写锁 | 读多写少（见 rwsem） |

---

## 5. spin_lock_irqsave 为什么要保存 flags？

```c
// spin_lock_irqsave 实现：
//   1. 保存当前中断状态到 flags（local_irq_save）
//   2. 加锁
//   3. 解锁时恢复中断状态（local_irq_restore）

void spin_lock_irqsave(spinlock_t *lock, unsigned long *flags)
{
    raw_spin_lock_irqsave(&lock->rlock, *flags);
}

// 为什么必须保存？
// 假设：中断在 A 处打开 → spin_lock(&l) → ... → spin_unlock(&l)
// 如果不加 flags 保存，直接 local_irq_disable()：
//   A 打开中断 → B 关闭中断 → B 加锁 → B 解锁 → B 打开中断
//   结果：原本打开的中断被 B 错误关闭！

// spin_lock_irqsave 保证：加锁前的状态 == 解锁后的状态
```

---

## 6. spinlock vs mutex 对比

| 特性 | spinlock | mutex |
|------|---------|-------|
| 睡眠 | ❌ 不允许 | ✅ 允许 |
| 持有时间 | < 20μs（极短）| 任意长度 |
| 上下文 | 中断、原子、NMI | 进程上下文 |
| 递归 | ❌ 不允许 | ❌ 不允许 |
| 中断内 | ✅ 可用 | ❌ 不可用 |
| 优先级继承 | ❌ 无 | ✅ 支持（RT） |
| owner 跟踪 | ❌ 无 | ✅ 有（调试） |

---

## 7. 真实内核使用案例

### 7.1 中断控制器（`kernel/irq/manage.c`）

```c
// 每个 IRQ 描述符有一把锁
struct irq_desc {
    spinlock_t lock;  // 保护 desc 状态
};

// 关闭中断获取锁
spin_lock_irqsave(&desc->lock, flags);
handle_irq_event(&desc->irq, desc);
spin_unlock_irqrestore(&desc->lock, flags);
```

### 7.2 运行队列（`kernel/sched/core.c`）

```c
// 调度器运行队列的锁
static __lock_used void __lockdep_or_acquire(void)
```

---

## 8. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| qspinlock 替代 ticket lock | ticket lock 在多核下 cacheline 颠簸（所有 CPU 竞争同一 cache line）|
| MCS 队列 per-cpu 节点 | 锁传递只涉及相邻节点，减少 cache bouncing |
| pending 位优化 | 有人排队时不需要立即入队，减少 MCS 节点分配 |
| local_irq_save/restore | 保证锁操作前后中断状态一致 |

---

## 9. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/spinlock.h` | 公开 API、spin_lock/init 等宏 |
| `include/linux/spinlock_types.h` | spinlock_t / raw_spinlock_t 定义 |
| `include/asm-generic/qspinlock_types.h` | qspinlock 架构无关实现 |
| `kernel/locking/spinlock.c` | raw spinlock 底层实现 |
| `arch/arm64/include/asm/spinlock_types.h` | ARM64 使用 qspinlock |
