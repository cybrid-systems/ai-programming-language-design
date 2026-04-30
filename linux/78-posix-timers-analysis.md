# posix timers — POSIX 定时器深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/time/posix-timers.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**posix timers** 是 POSIX 标准的进程级定时器，通过 `timer_create()` 创建，`timer_settime()` 触发。

---

## 1. 核心数据结构

### 1.1 posix_timer — 定时器

```c
// kernel/time/posix-timers.c — posix_timer
struct posix_timer {
    struct clock_event_device *cldev;     // 时钟事件设备
    struct k_itimer           *it;         // 内核定时器
    int                       tid;          // 线程 ID
    int                       clock_id;    // 时钟类型
    int                       node_id;     // 节点 ID
    struct list_head          list;        // 链表
};
```

### 1.2 k_itimer — 内核定时器

```c
// include/linux/sched.h — k_itimer
struct k_itimer {
    struct list_head        list;           // 链表
    struct task_struct      *proc;          // 所属进程
    struct sighand          *sighand;     // 信号处理
    struct signal_struct    *sig;           // 信号

    // 定时器类型
    clockid_t               it_clock;     // 时钟类型
    timer_t                 timer_id;      // 定时器 ID

    // 配置
    struct itimerspec64     it_interval;   // 重复间隔
    struct itimerspec64     it_value;      // 下次到期时间

    // sigevent
    struct sigevent         sigev;         // 信号事件
    struct callback_head    *container;     // 回调

    // CPU 定时器（ITIMER_PROF 等）
    struct cpu_timer        cpu;
};
```

---

## 2. timer_create — 创建定时器

```c
// kernel/time/posix-timers.c — sys_timer_create
SYSCALL_DEFINE2(timer_create, clockid_t, which_clock,
                struct sigevent *, event, timer_t *, created_id)
{
    struct posix_timer *pt;
    timer_t id;
    int err;

    // 1. 分配 posix_timer
    pt = kzalloc(sizeof(*pt), GFP_KERNEL);

    // 2. 分配 timer_id（类似 idr）
    id = allocator_alloc(...);

    // 3. 初始化定时器
    if (event && event->sigev_notify == SIGEV_THREAD)
        // 创建线程通知
        pt->tid = create_singlethread(event->sigev_value.sival_ptr);
    else
        // 信号通知
        pt->it->sigev.sigev_notify = event->sigev_notify;

    // 4. 绑定到 clock
    pt->it_clock = which_clock;
    posix_clock_register(pt, which_clock);

    *created_id = id;
    return 0;
}
```

---

## 3. timer_settime — 设置定时器

```c
// kernel/time/posix-timers.c — sys_timer_settime
SYSCALL_DEFINE4(timer_settime, timer_t, timer_id, int, flags,
                const struct itimerspec64 *, new, struct itimerspec64 *, old)
{
    struct posix_timer *pt = get_posix_timer(timer_id);

    // 1. 清除旧的
    timer_delete(timer_id);

    // 2. 如果设置了 new_value，启动定时器
    if (new_value.it_value.tv_sec || new_value.it_value.tv_nsec) {
        // 计算到期时间
        expires = timespec64_to_ktime(new_value.it_value);

        // 如果是绝对时间
        if (flags & TIMER_ABSTIME)
            expires = expires;

        // 调度
        posix_timer_schedule(pt, expires);
    }

    // 3. 保存旧的 (if old != NULL)
    if (old)
        *old = pt->it_value;

    return 0;
}
```

---

## 4. 时钟类型

```c
// include/linux/time.h — clockid
#define CLOCK_REALTIME          0    // 系统时钟
#define CLOCK_MONOTONIC         1    // 单调时钟
#define CLOCK_PROCESS_CPUTIME_ID 2   // 进程 CPU 时间
#define CLOCK_THREAD_CPUTIME_ID  3    // 线程 CPU 时间
#define CLOCK_BOOTTIME          7    // 启动后单调时钟（包括休眠）
#define CLOCK_REALTIME_ALARM    8    // 实时闹钟（系统可唤醒）
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/time/posix-timers.c` | `sys_timer_create`、`sys_timer_settime` |
| `include/linux/sched.h` | `struct k_itimer` |