# Linux Futex 子系统深度分析（futex2 + PI + waitv）

## 概述

futex（Fast Userspace Mutex）是 Linux 中所有线程同步的内核基础设施。其核心理念是：**无竞争时在用户空间完成，有竞争时才陷入内核**。自 2019 年起，futex 子系统经历了一次重大重构（futex2 系列补丁），将原本 5000+ 行的单一文件拆分为 `core.c`、`syscalls.c`、`waitwake.c`、`requeue.c`、`pi.c`，并新增了 `futex_waitv` 等基于 vaddr 的接口。

## 架构

```
系统调用入口（syscalls.c）
  ├── futex()          — 传统接口（futex2 前的向后兼容入口）
  ├── futex_waitv()    — futex2: 等待多个 futex（类似 Windows WaitForMultipleObjects）
  ├── futex_wait()     — futex2: 等待单个
  ├── futex_wake()     — futex2: 唤醒
  ├── futex_requeue()  — futex2: 重新排队
  ├── set_robust_list() / get_robust_list()
  └──（compat 变体）

内核实现（4 个模块）：
  waitwake.c    — futex_wait / futex_wake / futex_waitwake 核心逻辑
  requeue.c     — futex_requeue / futex_cmp_requeue
  pi.c          — PI futex、优先级继承、hash bucket 管理
  core.c        — hash bucket 管理、futex_q 生命周期、状态管理等
```

## 核心数据结构

### struct futex_q — 等待队列条目

（`kernel/futex/futex.h` L192）

```c
struct futex_q {
    struct plist_node       list;           // L193 — 优先级排序链表节点
    struct task_struct      *task;          // L195 — 等待的任务
    spinlock_t              *lock_ptr;      // L196 — hash bucket 锁
    futex_wake_fn           *wake;          // L197 — 唤醒回调函数（普通/PI 不同）
    void                    *wake_data;     // L198 — 唤醒回调数据
    union futex_key         key;            // L199 — futex 的哈希键
    struct futex_pi_state   *pi_state;      // L200 — PI 状态（PI futex 使用）
    struct rt_mutex_waiter  *rt_waiter;     // L201 — rt_mutex 等待者存储
    union futex_key         *requeue_pi_key;// L202 — requeue_pi 目标 futex 键
    u32                     bitset;         // L203 — 位掩码唤醒
    atomic_t                requeue_state;  // L204 — requeue_pi 状态
    bool                    drop_hb_ref;    // L205 — 是否释放额外 hash bucket 引用
};
```

关键设计：`plist_node`（优先级链表）而不是普通 `list_head`。这意味着 futex 等待者按优先级排序，高优先级任务在唤醒时优先被选择。

### struct futex_hash_bucket — 哈希桶

（`kernel/futex/futex.h` L134）

```c
struct futex_hash_bucket {
    atomic_t                waiters;        // L135 — 等待者计数
    spinlock_t              lock;           // L136 — 保护 chain 的自旋锁
    struct plist_head       chain;          // L137 — futex_q 的优先级链表
    struct futex_private_hash *priv;        // L138 — 私有哈希（futex2）
} ____cacheline_aligned_in_smp; // L139
```

futex 通过 `struct futex_key`（地址+inode/offset）哈希到 256 个桶之一（可配置）。同一个 futex 上的所有等待者挂在同一个 hash bucket 的 chain 上。

### struct futex_pi_state — PI 状态

（`kernel/futex/futex.h` L144）

```c
struct futex_pi_state {
    struct list_head        list;           // L149 — 拥有的 pi_state 列表
    struct rt_mutex_base    pi_mutex;       // L153 — 底层的 RT mutex
    struct task_struct      *owner;         // L156 — 当前持有者
    refcount_t              refcount;       // L157 — 引用计数
    union futex_key         key;            // L158 — 对应的 futex 键
};
```

PI futex 通过 `pi_mutex`（`struct rt_mutex_base`）实现优先级继承。当低优先级任务持有 futex，高优先级任务等待时，内核临时提升持有者的优先级。

## 核心流程

### futex_wait() — 等待 futex

（`kernel/futex/syscalls.c` L398，实现分发到 `kernel/futex/waitwake.c`）

```c
// syscalls.c L398
SYSCALL_DEFINE6(futex_wait, u32 __user *, uaddr, unsigned int, flags,
                u32, val, ktime_t *, abs_timeout, u32 __user *, uaddr2,
                u32, val3)
{
    // 1. 验证参数
    // 2. 通过 futex_wait_setup() 检查条件
    // 3. 调用 futex_do_wait() 睡眠
}
```

完整等待路径：

```
futex_wait(uaddr, val)
  │
  ├─ 1. futex_get_key()
  │     根据 uaddr 获取 futex_key：
  │       私有映射：mm + 虚拟地址
  │       共享映射：inode + offset
  │
  ├─ 2. futex_wait_setup(uaddr, val, q)      // waitwake.c
  │     ├─ get_futex_key(uaddr, FLAGS_READ, &key, hb)
  │     ├─ futex_hash(key) → hash bucket
  │     ├─ lock hb
  │     ├─ 检查 *uaddr == val？
  │     │   ├─ 不相等 → 返回（futex 值已变，直接返回）
  │     │   └─ 相等 → 初始化 futex_q，插入 hb.chain
  │     └─ unlock hb
  │
  ├─ 3. futex_do_wait(q, timeout)            // waitwake.c
  │     ├─ 设置 task 状态为 TASK_INTERRUPTIBLE
  │     ├─ schedule() 让出 CPU
  │     └─ 醒来时检查唤醒原因（超时/信号/futex_wake）
  │
  └─ 4. futex_unqueue_q(q)                   // core.c
        └─ 从 hb.chain 移除
```

### futex_wake() — 唤醒等待者

（`kernel/futex/syscalls.c` L366）

```
futex_wake(uaddr, flags, nr_wake)
  │
  ├─ get_futex_key(uaddr, FLAGS_WRITE, &key, hb)
  ├─ lock hb
  ├─ 遍历 hb.chain，找到所有 key 匹配的 futex_q
  ├─ for (i = 0; i < nr_wake; i++)
  │     └─ __futex_wake_mark(q)              // 标记并放到 wake_q
  ├─ unlock hb
  └─ wake_up_q(&wake_q)                      // 批量唤醒
```

`__futex_wake_mark()`（`kernel/futex/core.c`）:
```c
bool __futex_wake_mark(struct futex_q *q)
{
    struct task_struct *task = q->task;

    get_task_struct(task);
    plist_del(&q->list, &q->lock_ptr->chain);  // 从优先级链表移除
    q->lock_ptr = NULL;                        // 标记为已唤醒

    q->wake(q, wake_q);  // 调用具体的唤醒函数（普通 wake 或 PI wake）
    return true;
}
```

### futex_waitv() — 等待多个 futex

（`kernel/futex/syscalls.c` L318）

这是 futex2 新增的关键能力——一次等待多个 futex（类似 `WaitForMultipleObjects`）：

```c
SYSCALL_DEFINE5(futex_waitv, struct futex_waitv __user *, waiters,
                unsigned int, nr_futexes, unsigned int, flags,
                struct __kernel_timespec __user *, timeout,
                unsigned int, clockid)
{
    struct futex_vector *futexes;
    int ret;

    // 1. 复制用户空间 waiters 数组到内核
    futexes = kcalloc(nr_futexes, sizeof(*futexes), ...);
    ret = futexv_fetch_waitv(futexes, waiters, nr_futexes);

    // 2. 对所有 futex 执行 wait_setup
    ret = futex_wait_multiple_setup(futexes, nr_futexes, ...);

    // 3. 等待直到任意一个 futex 满足条件
    ret = futex_wait_multiple(futexes, nr_futexes, ...);

    // 4. 清理
    kfree(futexes);
    return ret;
}
```

`futex_wait_multiple_setup()` 的实现关键：
- 对 `nr_futexes` 个 futex 逐个执行 `futex_wait_setup()`
- 如果某个 futex 值已经不等于期望值，返回该 futex 的索引
- 否则所有 futex 都没有满足条件，进入等待

这个机制使得 epoll + eventfd 模式被替代为更直接的同步原语。

## 优先级继承（PI）futex

PI futex 是解决优先级反转问题的关键机制。当低优先级线程持有锁、中优先级线程在运行、高优先级线程等待锁时，持有锁的线程被临时提升到等待者的优先级。

### 数据结构关系

```
task_struct
  ├── pi_lock               — PI 操作的自旋锁
  ├── pi_waiters            — rt_mutex_waiter 的红黑树（按优先级排序）
  └── pi_state_list         — 拥有的 futex_pi_state 列表

futex_pi_state
  ├── pi_mutex (rt_mutex)   — 底层 RT mutex
  ├── owner                 — 当前持有者
  └── list                  — 在 owner->pi_state_list 中的节点
```

### futex_lock_pi() 数据流

```
futex_lock_pi(uaddr)
  │
  ├─ 1. 尝试用户空间锁定（原子操作）
  │     cmpxchg(uaddr, 0, tid) → 成功则直接返回（无竞争路径）
  │
  ├─ 2. 用户空间锁定失败 → 需要内核介入
  │     └─ futex_lock_pi_atomic(uaddr, hb, &key, &pi_state, current, 0)
  │          尝试第二次原子锁定
  │
  ├─ 3. 创建/获取 PI 状态
  │     └─ lookup_pi_state(uaddr, key, hb, &pi_state)
  │
  ├─ 4. 优先级继承
  │     └─ rt_mutex_start_proxy_lock(&pi_state->pi_mutex, ...)
  │           → 如果锁被持有：提升持有者优先级
  │           → task_boost_pi(owner, current->prio)
  │           → 将 rt_waiter 插入 owner->pi_waiters 红黑树
  │
  ├─ 5. 等待
  │     └─ futex_do_wait(q, timeout)  // 睡眠
  │
  └─ 6. 锁释放处理
        └─ futex_unlock_pi(uaddr)
             └─ 用户空间 cmpxchg(uaddr, old_tid, 0)
             └─ futex_wake(uaddr, 1)  // 唤醒下一个等待者
             └─ PI 去继承：恢复原始优先级
```

### 优先级继承的传递

```
场景：
  Thread C (prio=90) — 等待锁 L，锁由 Thread B (prio=50) 持有
     → C 的优先级（90）提升 B 到 90
     → 如果 B 还在等待另一个锁，由 Thread A (prio=30) 持有
     → B 的优先级（90）继续向上传递
     → A 被提升到 90，获得 CPU，尽快释放内层锁
     → B 获得内层锁，释放外层锁，优先级降回
     → C 获得锁
```

优先级传递通过 `rt_mutex_adjust_prio_chain()` 实现：每次锁状态变化时，沿着等待链向上传播优先级调整。

## 鲁棒（Robust）futex

鲁棒 futex 解决进程崩溃时锁状态泄露的问题。通过 `set_robust_list()` 注册一个用户空间链表，记录当前进程持有的所有 PI futex：

```c
// kernel/futex/syscalls.c L28
SYSCALL_DEFINE2(set_robust_list,
    struct robust_list_head __user *, head,
    size_t, len)
```

进程退出时（`do_exit`），内核自动扫描 robust_list：
1. 遍历所有记录在链表中的 futex
2. 检查 futex 值是否仍然包含当前线程的 TID
3. 如果是：将 futex 值清零（释放锁），设置 `FUTEX_OWNER_DIED` 位
4. 唤醒等待该 futex 的线程

这保证了即使持有 PI futex 的线程崩溃，等待线程也不会死锁。

## 重新排队（requeue）

futex_requeue 将等待者从一个 futex 移动到另一个，而不需要中间唤醒操作：

```
futex_requeue(uaddr1, uaddr2, nr_wake, nr_requeue)
  │
  ├─ 1. 获取两个 hash bucket
  │     hb1 = futex_hash(key1)
  │     hb2 = futex_hash(key2)
  │     double_lock(hb1, hb2)
  │
  ├─ 2. 从 hb1 唤醒 nr_wake 个等待者
  │
  ├─ 3. 将 hb1 上剩余的 nr_requeue 个等待者移到 hb2
  │     for (i = 0; i < nr_requeue; i++) {
  │         plist_del(&q->list, &hb1->chain);
  │         q->key = key2;              // 更换 futex key
  │         plist_add(&q->list, &hb2->chain);
  │     }
  │
  └─ 4. double_unlock(hb1, hb2)
```

这是 `pthread_cond_broadcast` 的高效实现基础：等待在条件变量上的线程先被唤醒，然后排队到互斥锁上，避免"惊群"效应。

## futex2 的改进

对比传统的 `sys_futex()` 和 futex2：

| 特性 | `sys_futex()`（传统） | futex2（新） |
|------|---------------------|-------------|
| 等待多个 | 需手动 epoll + eventfd | `futex_waitv()` 原生支持 |
| 位掩码唤醒 | 通过 `FUTEX_BITSET_MATCH_ANY` | 内置 bitset 支持 |
| 标志 | 嵌入 op 的低位 | `flags` 参数独立 |
| 时间参数 | 多种格式 | 统一的 `timespec` |
| 扩展性 | 单一巨型 API | 拆分为专用 syscall |
| 架构相关 | 少量 | 与核心分离 |

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct futex_q` | kernel/futex/futex.h | 192 |
| `struct futex_hash_bucket` | kernel/futex/futex.h | 134 |
| `struct futex_pi_state` | kernel/futex/futex.h | 144 |
| `sys_futex()` | kernel/futex/syscalls.c | 188 |
| `futex_waitv()` | kernel/futex/syscalls.c | 318 |
| `futex_wait()` | kernel/futex/syscalls.c | 398 |
| `futex_wake()` | kernel/futex/syscalls.c | 366 |
| `futex_requeue()` | kernel/futex/syscalls.c | 442 |
| `set_robust_list()` | kernel/futex/syscalls.c | 28 |
| `futex_wait_setup()` | kernel/futex/waitwake.c | 592 |
| `futex_do_wait()` | kernel/futex/waitwake.c | 341 |
| `__futex_wake_mark()` | kernel/futex/waitwake.c | 110 |
| `futex_lock_pi()` | kernel/futex/pi.c | 相关 |
| `futex_unlock_pi()` | kernel/futex/pi.c | 相关 |
| `lookup_pi_state()` | kernel/futex/pi.c | 相关 |
| `futex_wait_multiple_setup()` | kernel/futex/waitwake.c | 相关 |
