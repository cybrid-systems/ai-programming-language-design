# spinlock — 内核自旋锁深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/spinlock.h` + `kernel/locking/spinlock.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**spinlock** 是内核最常用的锁，在**自旋等待**中持有锁：
- **不可抢占**：自旋期间不能被调度
- **用于短临界区**：因为会阻塞其他 CPU
- **用在中断上下文**：使用 `spin_lock_irqsave` 禁用本地中断

---

## 1. 核心数据结构

### 1.1 spinlock_t

```c
// include/linux/spinlock_types.h — spinlock_t
typedef struct {
    arch_spinlock_t      raw_lock;      // 架构相关的锁
#ifdef CONFIG_GENERIC_LOCKDEP
    struct lockdep_map   dep_map;       // 锁依赖调试
#endif
} spinlock_t;

// arch_spinlock_t 在 x86：
// typedef struct { atomic_t val; } arch_spinlock_t;
```

### 1.2 锁状态

```
 unlocked: val = 0
 locked:   val = 1（单向）
```

---

## 2. 架构实现（x86 TSO）

### 2.1 spin_lock — 加锁

```c
// arch/x86/include/asm/spinlock.h
static __always_inline void spin_lock(spinlock_t *lock)
{
    asm volatile(
        "1: lock; xaddl %0, %1\n"   // 原子交换 + 加法
        "   testl %0, %0\n"          // 检测旧值
        "   jnz 2f\n"                // 非零 = 之前是 1，已被持有
        "   .section .text.unlikely\n"
        "2: pause\n"                // CPU 提示：正在自旋
        "   cmpb $0, %2\n"          // 检查 unlock 是否发生
        "   jz 1b\n"                // unlock 发生，重试
        "   rep; nop\n"
        "   jmp 2b\n"
        "   .previous\n"
        : "+m" (lock->raw_lock), "+m" (lock->__padding)
        : "i" (&lock->__padding)   // unlock 标志地址
        : "memory", "cc");
}
```

### 2.2 xadd — 原子加减

```
执行前：lock->val = 0, reg = 1
执行后：old = lock->val, lock->val = 1, reg = old
结果：old = 0（成功），reg = 1

执行前：lock->val = 1, reg = 1
执行后：old = lock->val, lock->val = 2, reg = old
结果：old = 1（失败，自旋等待）
```

---

## 3. 变体

### 3.1 spin_lock_irqsave

```c
// include/linux/spinlock.h
#define spin_lock_irqsave(lock, flags)        \
    do {                                  \
        raw_spin_lock_irqsave(spinlock_check(lock), flags); \
    } while (0)

static __always_inline unsigned long
raw_spin_lock_irqsave(raw_spinlock_t *lock)
{
    unsigned long flags;

    local_irq_save(flags);          // 禁用本地中断
    raw_spin_lock(lock);             // 获取锁

    return flags;                    // 返回中断状态
}
```

### 3.2 spin_lock_bh

```c
// 禁用下半部（softirq），获取锁
#define spin_lock_bh(lock)    local_bh_disable(); spin_lock(lock)
#define spin_unlock_bh(lock)  spin_unlock(lock); local_bh_enable()
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/spinlock.h` | spin_lock / spin_unlock / spin_lock_irqsave |
| `include/linux/spinlock_types.h` | spinlock_t |
| `arch/x86/include/asm/spinlock.h` | x86 架构实现 |
