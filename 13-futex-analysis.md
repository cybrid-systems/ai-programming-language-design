# Linux Kernel futex 用户态快速互斥 — 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/uapi/linux/futex.h` + `kernel/futex/*.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 更新：整合 2026-04-26 学习笔记

---

## 0. 什么是 futex？

**futex（Fast Userspace Mutex）** 是 Linux 最核心的"用户态优先、内核兜底"同步机制。

**核心思想**：
- **无竞争**：用户态原子指令（cmpxchg）完成，**零系统调用**
- **有竞争**：短暂进内核，通过哈希表 + 等待队列解决
- **结果**：99% 的同步操作在用户态完成，上下文切换开销接近零

---

## 1. 核心数据结构

### 1.1 用户态可见操作码

```c
// include/uapi/linux/futex.h — 用户态可见
#define FUTEX_WAIT              0   // 等待（如果 uaddr == val 则睡眠）
#define FUTEX_WAKE              1   // 唤醒
#define FUTEX_FD                2   // 通过 fd 唤醒
#define FUTEX_REQUEUE            3   // 重新排队（避免惊群）
#define FUTEX_CMP_REQUEUE        4   // 比较后再排队
#define FUTEX_WAKE_OP            5   // wake + 操作组合
#define FUTEX_LOCK_PI            6   // 带优先级继承的加锁
#define FUTEX_UNLOCK_PI          7   // 解锁（PI）
#define FUTEX_TRYLOCK_PI         8   // 尝试加锁（PI）
#define FUTEX_WAIT_BITSET        9   // 按 bitset 等待
#define FUTEX_WAKE_BITSET        10  // 按 bitset 唤醒
#define FUTEX_WAIT_REQUEUE_PI    11  // PI 模式下等待重排
#define FUTEX_LOCK_PI2           13  // 增强版 PI 锁

#define FUTEX_PRIVATE_FLAG       128 // 进程私有（优化，减少跨进程冲突）
```

### 1.2 内核内部结构

```c
// kernel/futex/ — futex_q（等待节点）
struct futex_q {
    struct plist_node list;          // 挂到 hash bucket 的 plist
    struct task_struct *task;        // 等待的 task
    spinlock_t *lock_ptr;            // 保护此节点的锁
    union futex_key key;             // 哈希键（page + offset + uuid）
    u32 bitset;                      // 等待位掩码
    // ...
};

// futex_key（哈希键）
union futex_key {
    struct {
        u64 i_seq;      // inode 序列号
        unsigned long pgoff;     // 页内偏移
        unsigned int offset;     // 额外偏移
    } shared;
    struct {
        u64 ptr;        // 指向用户的指针
        unsigned long word;     // 用户值
        u8 bitshift;   // 位移
    } both;
};
```

---

## 2. 算法原理

### 2.1 双路径设计

```
┌─────────────────────────────────────────────────────────┐
│                    futex 双路径                         │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  用户态快路径（glibc / pthread）：                        │
│    线程A:  atomic cmpxchg(&lock, 0, 1) → 成功，加锁     │
│    线程B:  atomic cmpxchg(&lock, 0, 1) → 失败，返回    │
│    → 零系统调用，O(1)                                   │
│                                                          │
│  内核慢路径（syscall）：                                 │
│    线程B:  futex(FUTEX_WAIT, lock, 1)                  │
│         → syscall __NR_futex                            │
│         → hash(key) → bucket                            │
│         → plist_add(&q.list) → 睡眠                     │
│         → schedule()                                    │
│                                                          │
│    线程A:  futex(FUTEX_WAKE, lock, 1)                  │
│         → hash(key) → bucket                            │
│         → plist_del(&q.list)                            │
│         → wake_up(q.task)                               │
│         → 线程B被唤醒                                   │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### 2.2 哈希表设计

```c
// kernel/futex/ — 全局 futex 哈希表
static struct futex_hash_bucket {
    spinlock_t lock;           // 保护此桶
    struct plist_head chain;   // 此桶的等待队列（按优先级排序）
} *futex_hash;

#define FUTEX_HASH_SIZE  256   // 或更大（NUMA aware）

// 哈希计算：
//   hash(key) = hash(key.page, key.offset, key.uuid) % FUTEX_HASH_SIZE
//   → O(1) 定位等待队列
```

---

## 3. FUTEX_LOCK_PI — 优先级继承

### 3.1 优先级反转问题

```
高优先级任务 T1 等待锁 L
中优先级任务 T2 持有锁 L 并被低优先级任务 T3 抢占
→ T1 被阻塞，T2 不让步于 T3
→ 系统实际按低优先级运行

解决方案：优先级继承（Priority Inheritance）
→ T2 临时继承 T1 的优先级，直到释放 L
```

### 3.2 PI futex 实现

```c
// kernel/futex/pi.c — FUTEX_LOCK_PI
// 底层使用 rt_mutex 支持优先级继承
struct futex_pi_state {
    struct refcount_t refcount;
    struct rt_mutex pi_mutex;      // 实时互斥锁（支持 PI）
    struct task_struct *owner;     // 当前持有者
    // ...
};
```

---

## 4. FUTEX_REQUEUE — 避免惊群

### 4.1 问题

```
1000 个线程等待同一个 futex
解锁时如果全部唤醒 → 1000 次上下文切换（惊群）

解决方案：FUTEX_REQUEUE
→ 只唤醒 N 个（通常 1 个）
→ 其余等待者从 futex-A 移动到 futex-B
→ futex-B 是另一个同步点
```

---

## 5. 真实使用案例

### 5.1 pthread_mutex（glibc）

```c
// glibc 实现的互斥锁
int pthread_mutex_lock(pthread_mutex_t *m)
{
    // 1. 用户态尝试加锁
    if (atomic_cmpxchg(&m->_lock, 0, 1) == 0)
        return 0;   // 成功，零系统调用

    // 2. 竞争失败，进内核
    return futex(&m->_lock, FUTEX_LOCK_PI, 0);
}
```

### 5.2 epoll（`fs/eventpoll.c`）

```c
// epoll 等待事件就绪
static int ep_poll(struct eventpoll *ep, ...)
{
    // ...
    if (!ep_events_available(ep)) {
        // 没有事件，睡眠等待
        init_waitqueue_entry(&wait, current);
        futex(&ep->operator->wait, FUTEX_WAIT, ...);
    }
    // ...
}
```

---

## 6. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| 用户态原子抢锁 | 99% 的锁无竞争，零系统调用 |
| 哈希表分桶 | 减少锁竞争，支持 O(1) 定位 |
| plist（优先级链表）| 按优先级排序，高优先级等待者优先唤醒 |
| FUTEX_PRIVATE_FLAG | 进程私有 futex 不跨进程，哈希冲突更少 |
| PI futex | 解决优先级反转，保证实时性 |

---

## 7. 参考

| 文件 | 内容 |
|------|------|
| `include/uapi/linux/futex.h` | 用户态操作码定义 |
| `kernel/futex/syscalls.c` | `do_futex` 系统调用入口 |
| `kernel/futex/waitwake.c` | `futex_wait`、`futex_wake` |
| `kernel/futex/pi.c` | `FUTEX_LOCK_PI` 优先级继承实现 |
| `kernel/futex/requeue.c` | `FUTEX_REQUEUE` 避免惊群 |
| `kernel/futex/futex.h` | `struct futex_q`、`union futex_key` |
