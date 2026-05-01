# 08-mutex — 互斥锁深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**mutex** 是内核最基本的互斥锁。设计原则：无竞争时走 CAS 快速路径（O(1)），有竞争时走慢速路径（MCS spinning → 睡眠等待）。

---

## 1. 数据结构

```c
struct mutex {
    atomic_long_t       owner;          // 持有者+标志位（waiters/handoff）
    spinlock_t          wait_lock;      // 保护 wait_list
    struct list_head    wait_list;      // 等待者 FIFO 队列
};
```

owner 编码：bit 0 = WAITERS，bit 1 = HANDOFF，bit 63:2 = task_struct 指针。

---

## 2. 数据流

```
mutex_lock(lock)
  ├─ __mutex_trylock_fast()       ← CAS(owner, 0, current)
  │    └─ 成功 → 返回
  └─ __mutex_lock_slowpath()
       └─ __mutex_lock_common()
            ├─ 乐观自旋（mutex_optimistic_spin + osq_lock）
            ├─ 加入 wait_list
            └─ schedule() → 睡眠

mutex_unlock(lock)
  ├─ __mutex_unlock_fast()        ← CAS(owner, current, 0)
  └─ __mutex_unlock_slowpath()    ← 有等待者
```

---

*分析工具：doom-lsp（clangd LSP）*
