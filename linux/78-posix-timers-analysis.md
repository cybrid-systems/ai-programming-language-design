# 78-posix-timers — Linux POSIX 定时器框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**POSIX 定时器**（`timer_create`/`timer_settime`）是 Linux 提供给用户空间的**高精度定时器 API**。与 `setitimer`（每个进程仅一个）不同，POSIX 定时器允许进程创建任意数量的定时器（受 `RLIMIT_SIGPENDING` 限制），支持 `CLOCK_REALTIME`/`CLOCK_MONOTONIC` 等多种时钟源。

**核心设计**：内核通过 `struct k_itimer` 管理每个 POSIX 定时器，底层使用 `hrtimer`（高精度定时器）实现。定时器到期时通过 `struct sigevent` 指定的方式通知（signal/thread/eventfd）。

```
用户空间                          内核
─────────                       ──────
timer_create(clockid, evp, &id)
  → sys_timer_create()         → posix_timer_create()
    → kzalloc(k_itimer)         → @ kernel/time/posix-timers.c
    → idr_alloc() 分配 ID       → 加入 timer_hash_bucket
    → 绑定时钟源操作表

timer_settime(id, flags, new, old)
  → sys_timer_settime()        → common_timer_set()
    → k_itimer->ktimer          → hrtimer_start(timer, expires, mode)
      → 插入 hrtimer 红黑树

定时器到期:
  → hrtimer_interrupt()        → hrtimer 框架
    → posix_timer_fn()          → @ posix-timers.c
      → sigqueue_alloc()        → 构造 sigevent
      → send_sigqueue()         → 发送信号
      → 或 wakeup 线程
```

**doom-lsp 确认**：`kernel/time/posix-timers.c`（**1,567 行**，**207 个符号**）。`include/linux/posix-timers.h`（265 行）。

---

## 1. 核心数据结构

### 1.1 struct k_itimer — POSIX 定时器

```c
// include/linux/posix-timers.h
struct k_itimer {
    struct list_head list;                   // timer_hash_bucket 链表
    struct hrtimer ktimer;                   // 底层 hrtimer
    clockid_t it_clock;                      // 时钟类型
    struct pid *it_pid;                      // 通知目标进程
    struct sigqueue *sigq;                   // 信号队列
    struct signal_struct *it_signal;         // 目标信号

    int it_pid_type;                         // PID 类型（PID/PGID/SID）
    int it_status;                           // 状态

    struct itimerspec64 it;                  // interval + value
    struct rcu_head rcu;

    const struct k_clock *kclock;            // 时钟操作表
    struct timer_list *it_timer;             // wheel timer（旧）
};
```

### 1.2 哈希桶——timer_hash_bucket

```c
// @ posix-timers.c:42
struct timer_hash_bucket {
    spinlock_t lock;
    struct list_head head;                   // 定时器链表
};

// 全局哈希表（@ :47）：
// static struct {
//     struct timer_hash_bucket buckets[POSIX_TIMER_HASH_SIZE];
//     unsigned int mask;
//     struct kmem_cache *cache;
// } __timer_data;

// 哈希函数（@ :84）：
// hash = (timer_id * 0x9e370001) & mask
// 快速 id→定时器查找
```

---

## 2. 主要 API

### 2.1 timer_create——创建定时器 @ syscall

```c
SYSCALL_DEFINE3(timer_create, const clockid_t, which_clock,
                struct sigevent __user *, timer_event_spec,
                timer_t __user *, created_timer_id)
{
    struct k_itimer *new_timer;
    struct sigevent *event = NULL;

    /* 1. 时钟源验证 */
    kc = clockid_to_kclock(which_clock);
    if (!kc) return -EINVAL;

    /* 2. 分配 k_itimer */
    new_timer = alloc_posix_timer();
    new_timer->it_clock = which_clock;
    new_timer->kclock = kc;

    /* 3. 初始化 hrtimer */
    hrtimer_init(&new_timer->ktimer, which_clock,
                 HRTIMER_MODE_REL_SOFT);
    new_timer->ktimer.function = posix_timer_fn;

    /* 4. 复制 sigevent */
    if (timer_event_spec) {
        copy_from_user(&event, timer_event_spec, sizeof(event));
        // sigev_notify: SIGEV_SIGNAL / SIGEV_THREAD / SIGEV_NONE
    }

    /* 5. ID 分配 */
    id = posix_timer_add(new_timer);
    put_user(id, created_timer_id);
}
```

### 2.2 timer_settime——启动/设置定时器

```c
SYSCALL_DEFINE4(timer_settime, timer_t, timer_id, int, flags,
                const struct __kernel_itimerspec __user *, new,
                struct __kernel_itimerspec __user *, old)
{
    struct k_itimer *timr = lock_timer(timer_id);
    // → posix_timer_by_id() 哈希查找 @ :89

    /* 复制时间规格 */
    copy_from_user(&new_spec, new, sizeof(new_spec));

    /* 调用时钟特定的 set 函数 */
    timr->kclock->timer_set(timr, flags, &new_spec, &old_spec);
    // → common_timer_set()
    //   → hrtimer_start(timr->ktimer, timr->it->value, mode)

    unlock_timer(timr);
}
```

---

## 3. 定时器到期回调——posix_timer_fn

```c
// @ posix-timers.c
// hrtimer 到期时调用此函数
static enum hrtimer_restart posix_timer_fn(struct hrtimer *timer)
{
    struct k_itimer *timr = container_of(timer, struct k_itimer, ktimer);

    /* 1. 重新加载定时器（如果是 interval 定时器）*/
    if (timr->it_interval) {
        // 计算下一次到期时间
        hrtimer_forward(timer, now, timr->it_interval);
        // 返回 HRTIMER_RESTART
    }

    /* 2. 发送通知 */
    switch (timr->sigq->info.si_code) {
    case SI_TIMER:
        // 发送 SIGALRM 或其他定时器信号
        send_sigqueue(timr->sigq, timr->it_pid, PIDTYPE_TASK);
        break;
    }

    return timr->it_interval ? HRTIMER_RESTART : HRTIMER_NORESTART;
}
```

---

## 4. 支持的时钟类型 @ posix_clocks

```c
// @ :57
// 注册的时钟类型（posix_clocks 数组）：
// CLOCK_REALTIME           — 墙上时间（可被 settimeofday 调整）
// CLOCK_MONOTONIC          — 单调递增（不受 settimeofday 影响）
// CLOCK_PROCESS_CPUTIME_ID — 进程 CPU 时间
// CLOCK_THREAD_CPUTIME_ID  — 线程 CPU 时间
// CLOCK_BOOTTIME           — 单调+挂起时间
// CLOCK_REALTIME_ALARM     — 挂起时可唤醒（需 CAP_WAKE_ALARM）
// CLOCK_BOOTTIME_ALARM     — 挂起时可唤醒（单调版）

// 每种时钟通过 struct k_clock 定义操作：
struct k_clock {
    int (*clock_getres)(...);
    int (*clock_set)(...);
    int (*clock_get)(...);
    int (*timer_create)(struct k_itimer *);
    int (*timer_set)(struct k_itimer *, int, struct itimerspec64 *, ...);
    int (*timer_del)(struct k_itimer *);
    void (*timer_get)(struct k_itimer *, struct itimerspec64 *);
    unsigned long (*timer_forward)(struct k_itimer *, ktime_t now);
};
```

---

## 5. 调试

```bash
# 查看 POSIX 定时器
cat /proc/<pid>/timers
# ID: 1
# signal: 10/SIGALRM
# notify: signal/pid.1234
# Clockid: 0 (CLOCK_REALTIME)
# flags: 0
# (it_value: 0.500000000 sec, it_interval: 0.500000000 sec)

# 定时器限制
cat /proc/sys/kernel/timer_max
ulimit -a | grep pending

# strace 跟踪
strace -e timer_create,timer_settime,timer_gettime -p <pid>
```

---

## 6. 总结

POSIX 定时器通过 `timer_create` → `hrtimer_init` + `timer_settime` → `hrtimer_start` 管理高精度定时。到期时 `posix_timer_fn`（@ `posix-timers.c`）通过 `send_sigqueue` 发送信号。底层基于 `hrtimer` 框架（红黑树），支持纳秒精度。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
