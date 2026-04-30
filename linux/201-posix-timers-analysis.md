# 201-posix_timers — POSIX定时器深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/time/posix-timers.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**POSIX Timers** 提供 `timer_create`、`timer_settime`、`timer_gettime` 等定时器接口，比 `alarm()/setitimer()` 更灵活。

---

## 1. 定时器类型

```c
// timer_create 的时钟源：
CLOCK_REALTIME      // 墙上时间，可设置
CLOCK_MONOTONIC     // 启动后单调递增，不可设置
CLOCK_PROCESS_CPUTIME_ID // 进程 CPU 时间
CLOCK_THREAD_CPU     // 线程 CPU 时间
CLOCK_BOOTTIME      // 包含睡眠时间

// SIGEV 通知：
//   SIGEV_NONE — 不通知
//   SIGEV_SIGNAL — 发信号
//   SIGEV_THREAD — 线程回调
```

---

## 2. 示例

```c
// 创建定时器：
struct sigevent sev = { .sigev_notify = SIGEV_SIGNAL, .sigev_signo = SIGALRM };
timer_t tid;
timer_create(CLOCK_REALTIME, &sev, &tid);

// 设置：
struct itimerspec its = { .it_value = { .tv_sec = 5 } };
timer_settime(tid, 0, &its, NULL);

// 5 秒后收到 SIGALRM
```

---

## 3. 西游记类喻

**POSIX Timers** 就像"天庭的预约时辰官"——

> POSIX timer 像天庭的预约时辰官——可以预约未来的某个时刻（absolute time）叫醒你。比起 alarm 只能叫醒一次，POSIX timer 更灵活，可以定时、循环叫醒，还能用不同的钟（CLOCK_MONOTONIC/REALTIME）。

---

## 4. 关联文章

- **hrtimer**（article 25）：hrtimer 是高精度定时器实现
- **timekeeping**（article 200）：定时器基于 timekeeping 时钟源