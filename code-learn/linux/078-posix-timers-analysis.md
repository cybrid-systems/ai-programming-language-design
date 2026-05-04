# 078-posix-timers — Linux POSIX 定时器框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码 | 使用 doom-lsp 进行逐行符号解析

---

## 0. 概述

**POSIX 定时器**（`timer_create`/`timer_settime`/`timer_gettime`/`timer_delete`）是 Linux 为用户空间提供的高精度定时器 API。每个定时器使用一个 `struct k_itimer` 表示，底层基于 **hrtimer**（高精度定时器）实现，支持 CLOCK_REALTIME、CLOCK_MONOTONIC、CLOCK_BOOTTIME 等时钟源。

**doom-lsp 确认**：`kernel/time/posix-timers.c`（307 个符号，核心实现），`include/linux/posix-timers.h`（数据结构）。

---

## 1. 核心数据结构

### 1.1 `struct k_itimer`——POSIX 定时器

```c
struct k_itimer {
    spinlock_t              it_lock;        // 保护定时器的自旋锁
    struct list_head        list;           // 进程定时器链表节点
    clockid_t               it_clock;       // 时钟 ID
    timer_t                 it_id;          // 定时器 ID（进程内唯一）
    int                     it_overrun;     // 超限计数（信号排队溢出）
    int                     it_overrun_last;// 上次报告的超限

    /* 定时器类型 */
    int                     it_requeue_pending; // 重新排队挂起

    /* 定时器值 */
    struct itimerspec64     it_interval;    // 周期（0 = 单次定时器）
    struct itimerspec64     it_value;       // 首次到期时间

    /* 通知方式 */
    union {
        struct sigqueue     *sigq;          // 信号通知（SIGEV_SIGNAL）
        struct task_struct  *task;          // 线程通知（SIGEV_THREAD）
        struct hrtimer      timer;          // hrtimer 实例
    } it;

    struct pid              *it_pid;        // 通知目标进程
    struct signal_struct    *it_signal;     // 所属进程的信号状态
};
```

---

## 2. 完整数据流

### 2.1 timer_create

```
timer_create(clockid, evp, timerid)
  └─ do_timer_create(clockid, evp, timerid)
       ├─ alloc_posix_timer()               // 分配 k_itimer
       ├─ k_itimer->it_clock = clockid
       ├─ k_itimer->it_id = idr_alloc()     // 分配 timer ID
       ├─ 设置通知方式：
       │    SIGEV_SIGNAL: 绑定 sigqueue
       │    SIGEV_THREAD: 绑定 task_struct（创建信号处理线程）
       │    SIGEV_NONE:   不通知（轮询）
       └─ 加入 current->signal->posix_timers 链表
```

### 2.2 timer_settime

```
timer_settime(timerid, flags, new_value, old_value)
  └─ do_timer_settime(timerid, flags, new_value, old_value)
       └─ k_itimer = idr_find(&timer_idr, timerid)
       └─ 设置 k_itimer->it_value / it_interval
       └─ hrtimer_start(&k_itimer->it.timer, expiry, mode)  // 启动 hrtimer
```

### 2.3 定时器到期

```
hrtimer_interrupt → __hrtimer_run_queues
  └─ hrtimer_callback = k_itimer->it.timer.function
       → posix_timer_fn()
            └─ 如果 it_interval != 0 → 重新调度（周期定时器）
            └─ 通知方式：
                 SIGEV_SIGNAL: send_sigqueue(ksig, pid)  ← 实时信号排队
                 SIGEV_THREAD: wake_up_process(task)      ← 唤醒处理线程
                 SIGEV_NONE:   更新 it_overrun 计数（用户轮询）
```

### 2.4 timer_delete

```
timer_delete(timerid)
  └─ do_timer_delete(timerid)
       └─ hrtimer_cancel(&k_itimer->it.timer)  // 取消 hrtimer
       └─ release_posix_timer(k_itimer, IT_ID_SET)
```

---

## 3. POSIX 定时器 vs hrtimer

| 特性 | POSIX 定时器 | hrtimer |
|------|-------------|---------|
| 使用者 | 用户空间（libc） | 内核驱动/子系统 |
| 精度 | 纳秒 | 纳秒 |
| 通知 | 信号/线程 | 回调函数 |
| 队列 | 进程 prlimit 限制 | 无限制 |
| 时钟选择 | 多种 clockid | CLOCK_MONOTONIC/REALTIME/BOOTTIME |
| 超限检测 | 自动（it_overrun） | 需手动 |

---

## 4. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct k_itimer` | include/linux/posix-timers.h | 核心 |
| `do_timer_create()` | kernel/time/posix-timers.c | 相关 |
| `do_timer_settime()` | kernel/time/posix-timers.c | 相关 |
| `posix_timer_fn()` | kernel/time/posix-timers.c | 定时器到期回调 |
| `do_timer_delete()` | kernel/time/posix-timers.c | 相关 |
| `alloc_posix_timer()` | kernel/time/posix-timers.c | 相关 |
| `hrtimer_start()` | kernel/time/hrtimer.c | 底层实现 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04 | 内核版本：Linux 7.0-rc1*
