# 09-spinlock — 自旋锁深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**自旋锁（spinlock）** 在获取失败时原地自旋等待。适用于短临界区，可在中断上下文中使用。

x86_64 默认使用 qspinlock（queued spinlock）：快速路径 CAS，慢速路径 MCS 队列自旋。

---

## 1. 数据结构

```c
typedef struct qspinlock {
    union {
        atomic_t val;       // locked(bit0) + pending(bit1) + tail(bit2-31)
    };
} arch_spinlock_t;
```

---

## 2. 数据流

```
spin_lock(lock)
  ├─ 快速路径：CAS(val, 0, _Q_LOCKED_VAL)
  └─ 慢速路径：queued_spin_lock_slowpath()
       ├─ pending 位尝试
       └─ MCS 队列 → 本地自旋

spin_unlock(lock)
  └─ smp_store_release(&lock->locked, 0)
       └─ MCS 队列传递锁
```

---

*分析工具：doom-lsp（clangd LSP）*
