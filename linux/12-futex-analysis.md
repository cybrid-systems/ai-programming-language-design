# 12-futex — 快速用户空间互斥锁深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**futex**（Fast Userspace Mutex）是 Linux 中"快速用户空间互斥"的实现基础。绝大多数线程同步原语——mutex、条件变量、读写锁、屏障——在 glibc 层都基于 futex 实现。

futex 的核心思想：**大部分锁操作没有竞争，可以在用户空间直接完成（原子指令），只有发生竞争时才通过系统调用进入内核。**

futex 涉及两个层面：
1. **用户空间**：通过原子指令（cmpxchg）操作共享变量，无竞争时零系统调用
2. **内核空间**：管理等待队列，在竞争时挂起/唤醒线程

---

## 1. 核心数据结构

### 1.1 futex_key——在内核中标识一个 futex

```c
struct futex_key {
    union {
        struct {
            unsigned long pointer;  // 地址
            unsigned long offset;   // 页内偏移
        };
        struct inode *inode;        // 基于 inode 的 key（共享映射）
    };
};
```

每个 futex 在内核中通过 `futex_key` 唯一标识。它由：
- **私有 futex**：`current->mm + 地址`（线程间，进程内）
- **共享 futex**：`inode + offset`（进程间，基于文件映射）

### 1.2 struct futex_q——等待队列项

```c
struct futex_q {
    struct plist_node  list;       // 优先级排序链表节点
    struct task_struct *task;      // 等待的线程
    spinlock_t         *lock_ptr;  // 保护该 q 的自旋锁
    union futex_key    key;        // 标识哪个 futex
    struct futex_pi_state *pi_state; // PI 提升状态
    ...
};
```

---

## 2. 核心系统调用

### 2.1 futex_wait

用户空间线程在发现锁被持有时，调用 `futex_wait`：

```c
// kernel/futex/core.c
static int futex_wait(u32 __user *uaddr, unsigned int flags,
                      u32 val, ktime_t *timeout, u32 bitset)
```

```
futex_wait(uaddr, expected_val)
  │
  ├─ 检查用户空间值是否仍为 expected_val
  │    └─ 如果不是 → 返回 EAGAIN（锁已经被释放了）
  │
  ├─ 创建 futex_q
  ├─ 将 futex_q 加入哈希冲突链的等待队列
  │
  ├─ set_current_state(TASK_INTERRUPTIBLE)
  │
  ├─ 再检查一次用户空间值（避免丢失唤醒）
  │
  ├─ if (值没变) schedule()         ← 让出 CPU
  │
  └─ 被唤醒后 → 清理 futex_q → 返回 0
```

### 2.2 futex_wake

锁持有者释放锁后调用 `futex_wake`：

```c
// kernel/futex/core.c
static int futex_wake(u32 __user *uaddr, unsigned int flags, int nr_wake)
```

```
futex_wake(uaddr, nr_wake)
  │
  ├─ 通过 uaddr 计算 futex_key
  ├─ 在哈希表中找到对应的等待队列
  │
  └─ 唤醒队列中的前 nr_wake 个线程
       └─ wake_up_q(&wake_q)        ← 批量唤醒
```

---

## 3. 无竞争路径（纯用户空间）

```
锁空闲时，Pthread mutex 的 lock 操作：
  ┌────────────────────────────┐
  │ 用户空间：                  │
  │ atomic_cmpxchg(&lock, 0, 1)│  ← 无系统调用！
  │ 成功 → 获取锁              │
  └────────────────────────────┘

锁被持有时：
  ┌────────────────────────────┐
  │ 用户空间：                  │
  │ atomic_cmpxchg(&lock, 0, 1)│  ← 失败
  │ → 调用 futex_wait(uaddr)   │
  │     ↓                      │
  │ 内核层：                    │
  │ schedule()                 │  ← 进入内核，睡眠
  └────────────────────────────┘

释放锁时：
  ┌────────────────────────────┐
  │ 用户空间：                  │
  │ lock = 0                  │
  │ → 调用 futex_wake(uaddr)   │
  │     ↓                      │
  │ 内核层：                    │
  │ wake_up_queue()            │  ← 唤醒等待者
  └────────────────────────────┘
```

**关键性能指标**：无竞争时一次锁操作 = 0 次系统调用（仅用户空间 CAS）。

---

## 4. PI-futex（优先级继承）

PI-futex 解决了**优先级反转**问题（低优先级线程持有锁，高优先级线程等待）。通过向持有锁的线程临时提升优先级来避免反转。

```
常规场景：
  低优先级线程持有 futex
  高优先级线程等待 futex → 被阻塞
  中优先级线程抢占了低优先级线程 → 高优先级仍被阻塞（反转！）

PI-futex 解决：
  高优先级线程等待 futex
  → 内核发现持有者是低优先级
  → 临时将持有者提升到高优先级
  → 持有者快速执行、释放锁、恢复原优先级
  → 高优先级线程获取锁
```

PI-futex 使用 `struct futex_pi_state` 跟踪锁的所有权，支持将 rt_mutex 用作底层锁。

---

## 5. 哈希冲突链

futex 在内核中不独占等待队列，而是通过哈希表共享：

```
futex_hash_table[]
  │
  ├─ bucket[0] → futex_q → futex_q → ...
  ├─ bucket[1] → futex_q → ...
  ├─ ...
  └─ bucket[n] → futex_q → ...

每个 bucket 对应一个哈希链
哈希键 = hash(futex_key)
```

doom-lsp 确认 `kernel/futex/core.c` 中 `hash_futex` 函数负责计算哈希值。

---

## 6. 设计决策总结

| 决策 | 原因 |
|------|------|
| 用户空间 CAS | 无竞争时零系统调用 |
| 哈希冲突链 | 共享等待队列，节省内存 |
| PI-futex | 解决优先级反转 |
| futex_key（inode+offset）| 支持进程间 futex |
| 两次检查+schedule 模式 | 避免丢失唤醒 |

---

## 7. 源码文件索引

| 文件 | 功能 |
|------|------|
| `kernel/futex/core.c` | futex_wait / futex_wake 核心实现 |
| `kernel/futex/futex.h` | 内部数据结构 |
| `kernel/futex/pi.c` | PI-futex 实现 |
| `kernel/futex/requeue.c` | requeue 操作 |

---

## 8. 关联文章

- **mutex**（article 08）：Pthread mutex 在非竞争时使用 futex 作为底层

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
