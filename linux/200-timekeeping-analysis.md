# 200-timekeeping — 内核时间管理深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/time/timekeeping.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**timekeeping** 管理内核的时间源和墙上时间，提供 `gettimeofday`、`clock_gettime` 等系统调用的底层支持。

---

## 1. 时间源

```
Linux 时间源（clocksource）：
  jiffies — 基于 tick（低精度）
  clocksource_jiffies — 基于 jiffies
  tsc — Time Stamp Counter（x86）
  arch_sys_counter — 架构相关的高精度计数器

切换：
  cat /sys/devices/system/clocksource/clocksource0/current_clocksource
  echo tsc > /sys/devices/system/clocksource/clocksource0/available_clocksource
```

---

## 2. timekeeper

```c
// kernel/time/timekeeping.c — tk_core
struct timekeeper {
    struct clocksource       *clock;    // 当前时钟源
    u64                     raw_time;   // 原始时间（无漂移修正）
    struct timespec64        wall_time;   // 墙上时间
    struct timespec64        offs_real;   // 偏移
    u64                     cycle_interval; // 周期
};
```

---

## 3. 西游记类喻

**timekeeping** 就像"天庭的时辰钟"——

> timekeeping 像天庭的大钟，墙上时间（wall_time）是天庭对外报告的时间，原始时间（raw_time）是钟的机械走动（不受闰秒等影响）。timekeeper 负责保持大钟的准确性，同步 NTP 或处理闰秒。

---

## 4. 关联文章

- **hrtimer**（article 25）：timekeeping 提供时钟基准
- **posix-timers**（相关）：基于 timekeeping 实现