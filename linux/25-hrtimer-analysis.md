# 25-hrtimer — 高精度定时器深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/time/hrtimer.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**hrtimer（High-Resolution Timer）** 是 Linux 的高精度定时器（微秒/纳秒级），替代了传统的低精度定时器（jiffies）。

---

## 1. 核心数据结构

### 1.1 struct hrtimer — 高精度定时器

```c
// include/linux/hrtimer.h — hrtimer
struct hrtimer {
    struct timerqueue_node      node;       // 红黑树节点
    ktime_t                    expires;     // 到期时间（绝对时间）
    ktime_t                    softexpires; // 软件到期时间
    enum hrtimer_restart       (*function)(struct hrtimer *); // 到期回调
    struct hrtimer_clock_base *base;        // 所属时钟基
    void                      *data;        // 传递给回调的数据
    unsigned long              state;        // HRTIMER_STATE_* 状态
    unsigned int              is_rel;       // 是否是相对时间
};
```

### 1.2 struct hrtimer_cpu_base — per-CPU 时钟基

```c
// kernel/time/hrtimer.c — hrtimer_cpu_base
struct hrtimer_cpu_base {
    raw_spinlock_t              lock;           // 保护
    ktime_t                    expires_next;   // 最近到期时间
    int                         nr_events;       // 到期事件数
    int                         nr_retries;     // 重试次数

    // per-CPU 时钟基（不同 CLOCK_*）
    struct hrtimer_clock_base   clock_base[4];
    //   clock_base[0] = CLOCK_REALTIME
    //   clock_base[1] = CLOCK_MONOTONIC
    //   clock_base[2] = CLOCK_BOOTTIME
    //   clock_base[3] = CLOCK_TAI
};
```

### 1.3 timerqueue_node — 红黑树节点

```c
// include/linux/timerqueue.h — timerqueue_node
struct timerqueue_node {
    struct rb_node              node;           // 红黑树节点
    ktime_t                    expires;         // 到期时间
};
```

---

## 2. hrtimer_start — 启动定时器

### 2.1 hrtimer_start

```c
// kernel/time/hrtimer.c — hrtimer_start
void hrtimer_start(struct hrtimer *timer, ktime_t tim, const enum hrtimer_mode mode)
{
    struct hrtimer_cpu_base *base = this_cpu_ptr(&hrtimer_bases);

    // 1. 绝对/相对时间转换
    if (mode == HRTIMER_MODE_ABS)
        timer->expires = tim;
    else
        timer->expires = ktime_add(tim, base->clock_base[...].get_time());

    // 2. 加入红黑树
    enqueue_hrtimer(timer, base);

    // 3. 如果是最早到期的，更新 expires_next
    if (timer->expires < base->expires_next)
        base->expires_next = timer->expires;
}
```

---

## 3. hrtimer_interrupt — tick 中断处理

### 3.1 hrtimer_interrupt

```c
// kernel/time/hrtimer.c — hrtimer_interrupt
void hrtimer_interrupt(struct clock_event_device *dev)
{
    struct hrtimer_cpu_base *base = this_cpu_ptr(&hrtimer_bases);
    ktime_t now, expires_next;

    base->expires_next = KTIME_MAX;

    // 遍历所有到期的定时器
    while (ktime_compare(base->clock_base[0].expires_next, now) <= 0) {
        struct hrtimer *timer;
        struct timerqueue_node *next;

        next = timerqueue_getnext(&base->clock_base[0].active);
        timer = container_of(next, struct hrtimer, node);

        // 移除
        timerqueue_del(&base->clock_base[0].active, &timer->node);

        // 重启或移除
        restart = timer->function(timer);
        if (restart != HRTIMER_NORESTART) {
            timer->expires = ktime_add(timer->expires, ...);
            timerqueue_add(&base->clock_base[0].active, &timer->node);
        }
    }
}
```

---

## 4. ktime_t — 时间表示

```c
// include/linux/ktime.h — ktime_t
typedef union {
    s64 tv64;              // 64位纳秒
} ktime_t;

// 转换函数：
#define ktime_to_ns(t)       ((t).tv64)
#define ns_to_ktime(ns)     ((ktime_t) { .tv64 = (ns) })

// 算术运算：
ktime_t ktime_add(ktime_t a, ktime_t b);
ktime_t ktime_sub(ktime_t a, ktime_t b);
ktime_t ktime_add_ns(ktime_t a, u64 ns);
```

---

## 5. 红黑树存储

```
hrtimer的红黑树（per-CPU per-clock_base）：

expires_next（最近到期时间）
      │
      ├── timerqueue_node (timer A) ←── expires最小
      ├── timerqueue_node (timer B)
      └── timerqueue_node (timer C) ←── expires最大

rb_root:
  按 expires 排序
  最左 = 最早到期 = expires_next
```

---

## 6. 与传统定时器的对比

| 特性 | hrtimer | 传统 timer_list |
|------|---------|----------------|
| 精度 | 纳秒（CLOCK_MONOTONIC）| jiffies（毫秒级）|
| 定时器数量 | 无限制（红黑树 O(log n)）| 无限制 |
| per-CPU | ✓ | ✓ |
| tickless | 支持 | 受 jiffies 限制 |

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/hrtimer.h` | `struct hrtimer`、`ktime_t` |
| `include/linux/timerqueue.h` | `struct timerqueue_node` |
| `kernel/time/hrtimer.c` | `hrtimer_start`、`hrtimer_interrupt` |

---

## 8. 西游记类比

**hrtimer** 就像"取经路上的精准沙漏"——

> 每个需要计时的任务（hrtimer）都往沙漏堆（红黑树）里放一个沙漏，倒过来开始计时。每个沙漏（node）有精确的到期时间（expires）。最小的沙漏（expires_next）放在最左边，玉帝（CPU）每次看时间（tick 中断）时，只需要看最左边的沙漏就知道下一个要处理的任务。每个沙漏到期时（hrtimer_interrupt），就调用沙漏上附带的处理函数。如果要继续计时（restart），就把新的到期时间加入沙漏堆。这就是 hrtimer 为什么比传统 jiffies 定时器精度高的原因——不依赖系统的 jiffy 节拍，而是用 CPU 的 tick 中断和红黑树精确管理。

---

## 9. 关联文章

- **softirq**（article 24）：hrtimer 触发 HRTIMER_SOFTIRQ
- **timer_list**（相关）：传统低精度定时器