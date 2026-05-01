# 25-hrtimer — 高精度定时器深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**hrtimer（High-Resolution Timer）** 是 Linux 高精度定时器子系统。与传统的 `timer_list`（基于 jiffies，通常 1-10ms 精度）不同，hrtimer 基于 **ktime**（纳秒精度），由硬件高精度事件定时器（如 TSC、HPET、ARM Generic Timer）驱动。

hrtimer 使用**红黑树**组织定时器，而非传统的时间轮（time wheel）。

doom-lsp 确认 `kernel/time/hrtimer.c` 包含约 230+ 个符号。

---

## 1. 核心数据结构

### 1.1 struct hrtimer

```c
struct hrtimer {
    struct timerqueue_node  node;        // 红黑树节点
    ktime_t                 _softexpires;// 最早到期时间
    ktime_t                 expires;     // 最迟到���时间
    enum hrtimer_restart   (*function)(struct hrtimer *); // 回调
    struct hrtimer_clock_base *base;     // 时钟基
    u8                      state;       // 状态：HRTIMER_STATE_*
    ...
};
```

### 1.2 struct hrtimer_clock_base

每个 CPU 维护两种时钟基：

```
clock_base[HRTIMER_MAX_CLOCK_BASES]:
  [0] = CLOCK_MONOTONIC     （单调时间，系统启动后递增）
  [1] = CLOCK_REALTIME      （实时时间，可能回退）
  [2] = CLOCK_BOOTTIME      （单调+休眠时间）
  [3] = CLOCK_TAI           （TAI 时间）
```

每个 clock_base 包含一个 `timerqueue_head`（红黑树根），按过期时间排序。

---

## 2. 核心操作

### 2.1 hrtimer_start

```c
void hrtimer_start(struct hrtimer *timer, ktime_t tim, const enum hrtimer_mode mode)
```

```
hrtimer_start(timer, expires, HRTIMER_MODE_REL)
  │
  ├─ ktime_add(now, expires)          ← 将相对时间转为绝对时间
  │
  ├─ 从红黑树移除旧的定时器（如果已插入）
  │
  ├─ 插入到 clock_base 的红黑树
  │    └─ timerqueue_add(&base->active, &timer->node)  ← O(log n)
  │
  ├─ 如果新定时器是树中最早到期的
  │    └─ hrtimer_reprogram(timer, base) ← 设置硬件定时器
  │
  └─ 更新定时器状态
```

### 2.2 hrtimer_run_queues（到期检查）

在以下时机检查：

```
hrtimer_run_queues()
  │
  ├─ 每个 tick（传统方式）
  └─ 硬件中断（高精度模式）
       │
       ├─ __hrtimer_run_queues(base, now)
       │    │
       │    ├─ 遍历红黑树中所有到期的定时器
       │    │    └─ timerqueue_getnext(&base->active)
       │    │
       │    ├─ 对每个到期的定时器：
       │    │    ├─ 从红黑树移除
       │    │    ├─ 设置状态 HRTIMER_STATE_CALLBACK
       │    │    ├─ timer->function(timer)     ← 执行回调
       │    │    └─ 检查返回类型：
       │    │         └─ HRTIMER_RESTART → 重新插入
       │    │         └─ HRTIMER_NORESTART → 不做处理
       │    │
       │    └─ 如果还有未到期定时器：
       │         └─ hrtimer_reprogram() → 设置下一个到期时间
```

---

## 3. 高精度模式切换

hrtimer 支持两种运行模式：

| 模式 | 触发方式 | 精度 | 功耗 |
|------|---------|------|------|
| 低精度（legacy） | 基于 tick | jiffies (~4ms) | 低 |
| 高精度（HR） | 硬件事件 | 纳秒 | 高 |

切换条件：`hrtimer_hres_enabled` + 硬件支持（arch_timer/HPET/LAPIC timer）。

---

## 4. 数据类型流

```
应用程序：
  timerfd_create(CLOCK_MONOTONIC)
  timerfd_settime(fd, 0, &its, NULL)

内核：
  do_timerfd_settime()
    └─ hrtimer_start(&ctx->tmr, expires, mode)

到期时：
  __hrtimer_run_queues()
    └─ timer->function(timer) = hrtimer_wakeup
         └─ wake_up(&ctx->wqh)          ← 唤醒等待的进程

用户空间：
  read(fd, buf, 8)                      ← 接收到期通知
```

---

## 5. 源码文件索引

| 文件 | 关键符号 |
|------|---------|
| `kernel/time/hrtimer.c` | `hrtimer_start` / `hrtimer_run_queues` / `hrtimer_reprogram` |
| `include/linux/hrtimer.h` | `struct hrtimer` 定义 |

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
