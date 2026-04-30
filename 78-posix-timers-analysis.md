# Linux Kernel POSIX Timers / clock_gettime 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/time/posix-timers.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. POSIX Timer 概述

**POSIX Timer** 提供比 `alarm()` 更灵活的定时机制，支持：
- 多种时钟源（CLOCK_REALTIME / CLOCK_MONOTONIC / CLOCK_BOOTTIME）
- 一次性或周期性触发
- 信号或线程通知

---

## 1. 核心数据结构

```c
// kernel/time/posix-timers.c — k_clock
struct k_clock {
    int (*clock_getres)(const clockid_t which, struct timespec64 *tp);
    int (*clock_set)(const clockid_t which, const struct timespec64 *tp);
    int (*clock_get)(const clockid_t which, struct timespec64 *tp);
    int (*clock_adj)(const clockid_t which, struct timex *tx);
    int (*timer_create)(struct k_clock *kc, clockid_t which, struct sigevent *ev, timer_t *timer_id);
    int (*timer_del)(struct k_itimer *timr, timer_t timer_id);
    void (*timer_get)(struct k_itimer *timr, struct itimerspec64 *cur_setting);
};

// kernel/time/posix-timers.c — k_itimer
struct k_itimer {
    struct list_head    list;           // 全局链表
    timer_t             tm_id;          // 用户空间 timer ID
    struct k_clock     *kclock;         // 时钟操作
    struct signal_struct *sigq;       // 信号队列
    clockid_t          clockid;         // 时钟类型
    struct hrtimer      *it_clock;     // 底层 hrtimer
    struct {
        struct timespec64 it_value;
        struct timespec64 it_interval;
    } it_real;
};
```

---

## 2. timer_create

```c
// kernel/time/posix-timers.c — common_timer_create
static int common_timer_create(struct k_clock *kc, clockid_t clockid,
                struct sigevent *ev, timer_t *new_timer_id)
{
    struct k_itimer *new_timer;

    // 1. 分配 timer
    new_timer = kzalloc(sizeof(*new_timer), GFP_KERNEL);

    // 2. 注册到全局 timer 链表（idr）
    spin_lock(&itimer_is_lock);
    new_timer->tm_id = idr_alloc(&posix_timers_idr, new_timer, ...);
    spin_unlock(&itimer_is_lock);

    // 3. 初始化 hrtimer
    hrtimer_init(&new_timer->it_clock->function, clockid, ...);

    // 4. 设置到期处理（信号或线程）
    if (ev->sigev_notify == SIGEV_THREAD_ID)
        new_timer->sigq->info.si_signo = ev->sigev_signo;

    *new_timer_id = new_timer->tm_id;
    return 0;
}
```

---

## 3. clock_gettime

```c
// kernel/time/posix-timers.c — posix_clock_get
static int posix_clock_get(clockid_t which, struct timespec64 *tp)
{
    switch (which) {
    case CLOCK_REALTIME:
        *tp = ktime_to_timespec64(ktime_get_real());
        break;
    case CLOCK_MONOTONIC:
        *tp = ktime_to_timespec64(ktime_get());
        break;
    case CLOCK_BOOTTIME:
        *tp = ktime_to_timespec64(ktime_get_boottime());
        break;
    case CLOCK_PROCESS_CPUTIME_ID:
        *tp = ktime_to_timespec64(clock_get_proctime());
        break;
    }
    return 0;
}
```

---

## 4. hrtimer 作为底层

```c
// 所有 POSIX 定时器的底层都是 hrtimer
// hrtimer 到期时调用：
//   timer->it_clock->function(timer->it_timer.expires)
```

---

## 5. 参考

| 文件 | 内容 |
|------|------|
| `kernel/time/posix-timers.c` | `timer_create`、`timer_gettime`、`clock_gettime` |
| `kernel/time/hrtimer.c` | hrtimer 底层实现 |
| `include/linux/posix-timers.h` | `struct k_itimer`、`struct k_clock` |
