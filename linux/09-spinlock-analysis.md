# 09-spinlock — 自旋锁深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/spinlock.h` + `kernel/locking/spinlock.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**spinlock** 是最轻量的锁：自旋等待（忙等），适用于临界区很短、不能睡眠的场景（如中断处理）。

---

## 1. 核心数据结构

### 1.1 raw_spinlock_t — 自旋锁

```c
// include/linux/spinlock_types.h — raw_spinlock_t
typedef struct {
    arch_spinlock_t        lock;   // 架构相关的锁
} raw_spinlock_t;

// x86 的实现：
// include/asm-generic/qspinlock.h — arch_spinlock_t
typedef struct {
    u32 slock;   // 0 = 未锁，1 = 已锁
} arch_spinlock_t;
```

### 1.2 spinlock_t — 自旋锁（可睡眠变体）

```c
// include/linux/spinlock_types.h — spinlock_t
#ifdef CONFIG_PREEMPT_RT
// RT 内核：spinlock 变成 sleepable 锁
typedef struct {
    raw_spinlock_t        raw_lock;
    // ...
} spinlock_t;
#else
// 普通内核：spinlock = raw_spinlock
typedef raw_spinlock_t spinlock_t;
#endif
```

---

## 2. x86 TSO 模型下的实现

### 2.1 arch_spin_lock — 加锁

```c
// include/asm-generic/qspinlock.h — arch_spin_lock
static __always_inline void arch_spin_lock(arch_spinlock_t *lock)
{
    // x86 TSO（Total Store Order）模型下：
    // 所有 store 按程序顺序执行
    // 所有 load 可以 reorder

    // 方式一：test-and-set
    // while (atomic_xchg(&lock->slock, 1) == 1)
    //     cpu_relax();

    // 方式二：更优化的 queued spinlock（MCS 的变体）
    // 减少 cacheline bounce
}

static __always_inline void arch_spin_lock(arch_spinlock_t *lock)
{
    int val = 1;

    // TSO：x86 保证 lock 前缀的指令不会 reorder
    // 所以下面的代码在 x86 上是正确的
    asm volatile(
        "1: lock xaddl %0, %1\n"   // xaddl = atomic exchange + add
        "   testl %0, %0\n"         // 检查旧值
        "   jz 3f\n"                // 如果是 0（原值），说明锁空闲，跳到 3
        "2: pause\n"               // cpu_relax 的 x86 实现：降低功耗、提高调度
        "   cmpl %2, %1\n"         // 检查锁是否释放（load 当前值）
        "   je 1b\n"               // 如果已释放，重试
        "   jmp 2b\n"              // 继续自旋
        "3:\n"
        : "+r"(val), "+m"(lock->slock)
        : "i"(0)
        : "memory", "cc");
}
```

### 2.2 xaddl 指令详解

```c
// lock xaddl %0, %1 的语义：
//   temp = *lock;    // 原子读取
//   *lock = temp + val; // 原子写入
//   %0 = temp;         // 输出：返回原值

// 所以：
//   lock xaddl $1, %slock
//   如果原值 = 0（空闲），返回 0
//   如果原值 = 1（已锁），返回 1
//   同时 slock = 1（已被锁定）

// 自旋逻辑：
//   如果返回 0 → 锁空闲 → 成功
//   如果返回 1 → 锁被持有 → 继续自旋
```

### 2.3 pause 指令

```c
// cpu_relax() 在 x86 上的实现：
// 实际上是 "pause" 指令
// pause 的作用：
//   1. 降低 CPU 功耗
//   2. 提示 CPU 这是一个自旋锁场景
//   3. 减少 memory order 冲突（pause 会清空 store buffer 的部分）
//   4. 让超线程（Hyperthread）的资源更多分配给对等线程
```

---

## 3. 解锁

### 3.1 arch_spin_unlock

```c
// include/asm-generic/qspinlock.h — arch_spin_unlock
static __always_inline void arch_spin_unlock(arch_spinlock_t *lock)
{
    // 简单：直接写 0
    // x86 TSO 下不需要 memory barrier
    // 因为所有之前的 store 都已经按顺序执行
    // 但完整代码会有 barrier
    __release(lock);
    lock->slock = 0;
}

// __release 展开为：
//   asm volatile("" : : "i"(lock) : "memory")
// 告诉编译器：在这一点之前的所有内存访问都不能 reorder 到之后
// 实际上是 compiler barrier + aarch64 的 explicit barrier
```

---

## 4. 读写自旋锁

### 4.1 rwlock_t — 读写锁

```c
// include/linux/rwlock.h — rwlock_t
typedef struct {
    arch_rwlock_t        lock;   // 0 = 未锁，正数 = 读锁计数
} rwlock_t;

// x86 实现：
typedef struct {
    int lock;   // bit[31] = 写锁标记，bit[30:0] = 读锁计数
} arch_rwlock_t;

// 读锁：atomic_inc(&lock->lock)  （加到计数上）
// 写锁：atomic_xchg(&lock->lock, -1)（设为 -1 表示写锁）
```

---

## 5. spin_lock_irqsave — 禁用中断的加锁

```c
// include/linux/spinlock.h — spin_lock_irqsave
#define spin_lock_irqsave(lock, flags) \
do { \
    flags = 0; \
    spin_lock(lock); \
} while (0)

// 实际实现：
//   1. 保存当前中断状态（FLAGS）
//   2. 禁用本地中断（CLI）
//   3. 获取锁

// 解锁时：
#define spin_unlock_irqrestore(lock, flags) \
do { \
    spin_unlock(lock); \
    local_irq_restore(flags); \
} while (0)

// 必须用 irqsave/irqrestore，不能用 irq_disable/enable
// 因为其他代码可能已经开了中断
```

---

## 6. 内存屏障（Memory Barrier）

### 6.1 为什么需要 barrier

```
x86 TSO 模型：

CPU0:           CPU1:
store x=1       load y
store y=1       ???

如果 CPU0 先执行 store x，后执行 store y：
x86 TSO 保证：store 到 y 不会越过 store 到 x

但是，如果 CPU0 和 CPU1 之间有锁：
CPU0:           CPU1:
spin_lock       spin_lock
store x=1       load y    ← 这里能看到 x=1
store y=1
spin_unlock     spin_unlock

spin_lock/unlock 提供了隐含的 barrier：
- 进入锁之前的 store 不能 reorder 到锁之后
- 锁之后的 load 不能 reorder 到锁之前
```

---

## 7. 与 mutex 的对比

| 特性 | spinlock | mutex |
|------|----------|-------|
| 自旋等待 | ✓ | ✗（睡眠）|
| 持有时睡眠 | ✗ | ✓ |
| 中断上下文 | ✓ | ✗ |
| 临界区时长 | 极短（us级）| 较长（可ms级）|
| 优先级继承 | 无 | 有（PI-mutex）|

---

## 8. 内核使用案例

### 8.1 中断处理

```c
// 软中断（softirq）
spin_lock(&irq_desc->lock);  // 保护中断描述符
// 处理...
spin_unlock(&irq_desc->lock);
```

### 8.2 定时器

```c
// 内核数据结构中的自旋锁
struct timer_list {
    spinlock_t      lock;
    // ...
};
```

---

## 9. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/spinlock_types.h` | `raw_spinlock_t`、`spinlock_t` |
| `include/asm-generic/qspinlock.h` | `arch_spin_lock`、`arch_spin_unlock` |
| `include/linux/spinlock.h` | `spin_lock_irqsave` |
| `kernel/locking/spinlock.c` | spinlock 核心实现 |