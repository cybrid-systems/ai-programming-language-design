# 12-futex — 快速用户空间互斥深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**futex（Fast Userspace Mutex）** 是 Linux 内核为线程同步提供的底层基础设施。它的设计理念是：**大部分锁操作没有竞争，可以在用户空间用一条 CAS 原子指令完成；只有发生竞争时才通过系统调用陷入内核挂起或唤醒线程。**

futex 不直接提供给开发者使用，它是 glibc/pthead mutex、条件变量、屏障、读写锁等同步原语的底层实现。

doom-lsp 确认 `kernel/futex/` 目录包含 core.c、pi.c、requeue.c 等子模块，共约 700+ 符号。

---

## 1. 核心思想

```
无竞争路径（95%+ 的情况）：
  用户空间线程调用 atomic_cmpxchg(&lock, 0, 1)
  → CAS 成功 → 获取锁 → 零系统调用！

有竞争路径：
  CAS 失败 → 调用 futex(FUTEX_WAIT, addr, expected)
  → 系统调用 → 睡眠直到被 FUTEX_WAKE 唤醒
```

这种"用户空间快速路径 + 内核慢速路径"的两层设计，使得 mutex 在低竞争时几乎零开销。

---

## 2. 核心系统调用

### 2.1 futex(FUTEX_WAIT) — 等待

```
futex_wait(uaddr, val, timeout, flags)
  │
  ├─ 从用户空间读取 *uaddr
  ├─ 如果 *uaddr != val → 返回 EAGAIN
  │    └─ （值已变化，不需要等待）
  │
  ├─ 计算 futex_key（标识唯一 futex）
  │    └─ 私有 futex: mm + offset  （hash 到 per-process 桶）
  │    └─ 共享 futex: inode + offset（hash 到全局桶）
  │
  ├─ 将当前线程加入对应的等待队列
  ├─ 设置 TASK_INTERRUPTIBLE
  ├─ 再检查一次 *uaddr（防止丢失唤醒）
  ├─ schedule()                     ← 真正让出 CPU
  └─ 被唤醒后 → 从队列移除 → 返回 0
```

doom-lsp 确认 `kernel/futex/core.c` 中的 `futex_wait` 为核心实现，内部调用 `futex_wait_queue`。

### 2.2 futex(FUTEX_WAKE) — 唤醒

```
futex_wake(uaddr, nr_wake, flags)
  │
  ├─ 计算 futex_key
  ├─ 从哈希表中找到等待队列
  └─ 唤醒队列中前 nr_wake 个等待线程
       └─ 默认 nr_wake=1（只唤醒一个）
```

---

## 3. 哈希散列

futex 在内核中不独占等待队列，而是通过哈希表共享：

```
futex_hash_table 是一个全局数组，每个元素（bucket）包含：
  ┌─────────────────────────────────────┐
  │ spinlock_t lock                      │ ← 保护本桶的链表
  │ struct hlist_head chain              │ ← futex_q 的链表
  └─────────────────────────────────────┘

哈希计算（futex_hash @ core.c:302）：
  hash = jhash2(futex_key, sizeof(futex_key)/4, seed)
  bucket = &futex_hash_table[hash & (HASH_SIZE - 1)]
```

doom-lsp 确认了 `futex_hash` 函数位置为 `kernel/futex/core.c:302`，以及两个哈希函数 `__futex_hash`（分别在 126 和 414）。

---

## 4. futex_key——标识唯一 futex

```c
// futex_key 的构成（kernel/futex/core.c）
union futex_key {
    struct {
        unsigned long pointer;     // 地址（私有 futex）
        unsigned long offset;      // 页内偏移
    };
    struct {
        struct inode *inode;       // inode（共享文件映射 futex）
        unsigned long offset;
    };
};
```

私有 futex vs 共享 futex：
| 场景 | futex_key 组成 | 使用示例 |
|------|---------------|---------|
| **私有** | mm_struct* + 地址 | 线程间（同一进程）|
| **共享** | inode + offset | 进程间（共享内存）|

doom-lsp 确认 `futex_key_is_private`（`core.c:136`）用于区分两种 key 类型。

---

## 5. PI-futex（优先级继承）

PI-futex 解决了**优先级反转**——低优先级线程持有锁，高优先级线程等待时被阻塞，中优先级线程抢占低优先级导致高优先级被间接延迟。

```
正常情况（无 PI）：
  低优先级持有锁 → 中优先级抢占 → 高优先级无限等待

PI-futex：
  高优先级尝试获取锁
  → 发现持有者是低优先级
  → 临时将持有者提升到高优先级
  → 持有者尽快执行 → 释放锁 → 恢复原优先级
  → 高优先级获取锁
```

`kernel/futex/pi.c` 实现了 PI 逻辑，基于 rt_mutex。

---

## 6. futex requeue—条件变量底层

```
pthread_cond_wait 内部操作：
  pthread_mutex_unlock(&mutex)
  futex(FUTEX_REQUEUE, cond_addr, mutex_addr, nr_wake, nr_requeue)
  pthread_mutex_lock(&mutex)

REQUEUE 操作：
  将 cond_addr 队列中的 nr_requeue 个线程
  移动到 mutex_addr 队列中
  → 避免一次 complete FUTEX_WAKE + 一次 FUTEX_WAIT
  → 减少系统调用次数
```

---

## 7. 数据流全景

```
mutex_lock（glic 中的 pthread_mutex_lock）：
  │
  ├─ 用户空间 CAS(&lock, 0, 1)
  │    ├─ 成功 → 获取锁（0 次系统调用）
  │    └─ 失败 → futex(FUTEX_WAIT, &lock, 1)
  │              └─ schedule()
  │
  └─ 被 FUTEX_WAKE 唤醒后重新尝试

mutex_unlock：
  ├─ lock = 0                        ← 用户空间写
  ├─ futex(FUTEX_WAKE, &lock, 1)     ← 唤醒一个等待者
  └─ 如果无人等待 → 不需要系统调用
```

---

## 8. 设计决策总结

| 决策 | 原因 |
|------|------|
| 用户空间 CAS 快速路径 | 无竞争时零系统调用 |
| 哈希冲突链共享队列 | 节省内存，减少内核结构 |
| 私有/共享 futex_key 分离 | 同一进程内更快 |
| PI-futex | 解决优先级反转问题 |
| requeue 机制 | 减少条件变量的系统调用次数 |

---

## 9. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `kernel/futex/core.c` | `futex_wait` | 核心 |
| `kernel/futex/core.c` | `futex_wake` | 核心 |
| `kernel/futex/core.c` | `futex_hash` | 302 |
| `kernel/futex/core.c` | `__futex_hash` | 126/414 |
| `kernel/futex/core.c` | `futex_key_is_private` | 136 |
| `kernel/futex/pi.c` | PI-futex 相关 | |
| `kernel/futex/requeue.c` | requeue 相关 | |

---

## 10. 关联文章

- **mutex**（article 08）：Pthread mutex 在底层通过 futex 实现
- **wait_queue**（article 07）：futex 使用等待队列管理睡眠线程

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
