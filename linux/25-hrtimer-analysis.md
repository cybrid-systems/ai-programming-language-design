# hrtimer — 高精度定时器深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/time/hrtimer.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**hrtimer（High-Resolution Timer）** 是 Linux 的高精度定时器（纳秒级），基于红黑树管理，替代传统的低精度 timer_list。

---

## 1. 核心数据结构

### 1.1 hrtimer — 高精度定时器

```c
// include/linux/hrtimer.h — hrtimer
struct hrtimer {
    struct rb_node          node;         // 红黑树节点（接入 hrtreem）
    ktime_t                expires;     // 到期时间（绝对时间）
    ktime_t                soft;        // 软到期时间（可延迟）
    void                   (*function)(struct hrtimer *); // 回调函数
    struct hrtimer_clock_base *base;    // 所属的 clock base
    unsigned long           state;       // HRTIMER_STATE_* 状态
    int                    start_pid;    // 启动进程 PID
    void                   *start_site; // 启动位置
};
```

### 1.2 hrtimer_clock_base — 时钟基

```c
// include/linux/hrtimer.h — hrtimer_clock_base
struct hrtimer_clock_base {
    struct hrtimer_cpu_base *cpu_base;  // CPU 基
    clockid_t              clockid;     // 时钟类型（CLOCK_REALTIME 等）
    struct rb_root_cached   root;        // 红黑树根（缓存最左节点）
    struct rb_node          *leftmost;   // 最近到期的定时器
    // ...
};
```

### 1.3 hrtimer_cpu_base — 每 CPU 状态

```c
// kernel/time/hrtimer.c — hrtimer_cpu_base
struct hrtimer_cpu_base {
    raw_spinlock_t          lock;        // 保护
    unsigned int            cpu;         // CPU 编号
    struct hrtimer_clock_base clock_base[CLOCK_TAI]; // 两种时钟基
    struct timer_list       schedule_timer; // 调度定时器（触发下一个）
    unsigned long           nr_events;    // 事件计数
    // ...
};
```

---

## 2. 时间表示（ktime）

```c
// include/linux/ktime.h
typedef s64             ktime_t;

static inline ktime_t ktime_set(long secs, unsigned long nsecs)
{
    return (ktime_t)secs * NSEC_PER_SEC + nsecs;
}

// ktime_t 转 nanoseconds
static inline u64 ktime_to_ns(const ktime_t kt)
{
    return (u64)kt;
}
```

---

## 3. hrtimer_start — 启动定时器

```c
// kernel/time/hrtimer.c — hrtimer_start
void hrtimer_start(struct hrtimer *timer, ktime_t expires, const enum hrtimer_mode mode)
{
    struct hrtimer_clock_base *base;
    unsigned long flags;

    base = hrtimer_clock_base(timer);

    spin_lock_irqsave(&base->cpu_base->lock, flags);

    // 如果已在红黑树中，先移除
    if (hrtimer_is_queued(timer))
        __hrtimer_remove(timer);

    // 设置到期时间
    timer->expires = expires;

    // 加入红黑树
    __hrtimer_add(timer, base, mode);

    spin_unlock_irqrestore(&base->cpu_base->lock, flags);
}
```

---

## 4. __hrtimer_add — 加入红黑树

```c
// kernel/time/hrtimer.c — __hrtimer_add
static void __hrtimer_add(struct hrtimer *timer, struct hrtimer_clock_base *base, ...)
{
    struct rb_node **node = &base->root.rb_node;
    struct rb_node *parent = NULL;
    bool leftmost = true;

    // 找到插入位置
    while (*node) {
        parent = *node;
        if (hrtimer_less(timer, rb_entry(*node, struct hrtimer, node))) {
            node = &(*node)->rb_left;
        } else {
            node = &(*node)->rb_right;
            leftmost = false;
        }
    }

    // 插入节点
    rb_link_node(&timer->node, parent, node);
    rb_insert(&timer->node, &base->root);

    // 如果是最左节点，缓存
    if (leftmost)
        base->leftmost = &timer->node;

    // 如果这个定时器比当前 schedule_timer 更早，重新调度
    if (leftmost && timer->expires < base->cpu_base->schedule_timer.expires)
        hrtimer_update_softirq_timer(base, leftmost);
}
```

---

## 5. hrtimer_interrupt — 定时器中断处理

```c
// kernel/time/hrtimer.c — hrtimer_interrupt
void hrtimer_interrupt(struct hrtimer_cpu_base *cpu_base)
{
    struct hrtimer_clock_base *base = &cpu_base->clock_base[0];
    struct rb_node *node;

    spin_lock(&cpu_base->lock);

    // 处理到期的定时器
    while (node = base->leftmost) {
        struct hrtimer *timer = rb_entry(node, struct hrtimer, node);

        if (timer->expires > ktime_get())
            break;  // 未到期，停止

        // 移除定时器
        __hrtimer_remove(timer);

        // 调用回调
        expire_hrtimer(timer);
    }

    spin_unlock(&cpu_base->lock);
}
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/hrtimer.h` | `struct hrtimer`、`struct hrtimer_clock_base` |
| `kernel/time/hrtimer.c` | `hrtimer_start`、`__hrtimer_add`、`hrtimer_interrupt` |
| `include/linux/ktime.h` | `ktime_t` 运算 |