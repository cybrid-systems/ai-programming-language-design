# Linux Kernel hrtimer (高精度定时器) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/time/hrtimer.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 hrtimer？

**hrtimer**（High-Resolution Timer）是 Linux 的**高精度定时器**，精度可达微秒甚至纳秒级。相比旧的 `timer_list`（jiffies 精度），hrtimer 基于红黑树管理，支持多个 CPU 并行。

---

## 1. hrtimer 核心结构

```c
// include/linux/hrtimer.h — hrtimer
struct hrtimer {
    union {
        struct rb_node     node;           // 红黑树节点
        struct list_head   cpu_base_next;  // per-CPU 链表
    };
    ktime_t                 expires;        // 到期时间（绝对时间）
    ktime_t                 soft;           // 软到期时间（RT 下可延迟）
    enum hrtimer_restart   (*function)(struct hrtimer *);
    struct hrtimer_clock_base *base;
    u8                      state;          // ACTIVE / INACTIVE / QUEUED
    u8                      is_rel;
    u8                      is_soft;
    u8                      is_hard;
};

// clock_base — 每个 CPU 每个时钟基准一个
struct hrtimer_clock_base {
    struct hrtimer_cpu_base   *cpu_base;
    clockid_t                  clock_id;     // CLOCK_REALTIME / CLOCK_MONOTONIC
    struct rb_root            active;        // 红黑树根（按时序排列）
    struct rb_node            *leftmost;      // 最近到期的时间（缓存）
    struct timerqueue_head    *offset;
};
```

---

## 2. hrtimer_enqueue — 定时器入队

```c
// kernel/time/hrtimer.c — enqueue_hrtimer
static void enqueue_hrtimer(struct hrtimer *timer,
                struct hrtimer_clock_base *base, int reprogram)
{
    // 插入红黑树（按时序）
    rb_insert(&timer->node, &base->active);

    // 更新 leftmost（缓存最近到期的时间）
    if (timerqueue_get_next_event(&base->active) == &timer->node)
        base->leftmost = &timer->node;

    // 如果是最早到期的，重新编程 clock_event_device
    if (reprogram && base->cpu_base->hres_active)
        hrtimer_force_reprogram(base->cpu_base, 0);
}
```

---

## 3. __hrtimer_run_queues — 到期处理

```c
// kernel/time/hrtimer.c — __hrtimer_run_queues
static void __hrtimer_run_queues(struct hrtimer_cpu_base *cpu_base, ...)
{
    struct hrtimer_clock_base *base;
    ktime_t now;

    // 遍历每个时钟基准
    for (each_clock_base(cpu_base, base)) {
        // 获取当前时间
        now = base->clock_id == CLOCK_MONOTONIC ?
              ktime_get() : ktime_get_real();

        // 遍历所有到期的定时器
        while ((timer = timerqueue_get_next(&base->active)) &&
               timer->expires <= now + *leftmost) {
            // 移除
            rb_erase(&timer->node, &base->active);
            timer->state &= ~HRTIMER_STATE_QUEUED;

            // 调用回调
            fn = timer->function;
            restart = fn(timer);

            // 如果是周期定时器，重新入队
            if (restart != HRTIMER_NORESTART)
                hrtimer_forward(timer, now, timer->interval);
        }
    }
}
```

---

## 4. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| 红黑树组织定时器 | O(log n) 插入/删除，适合大量定时器 |
| leftmost 缓存 | O(1) 获取最近到期，避免遍历整棵树 |
| per-CPU clock_base | 每个 CPU 管理自己的定时器，无锁竞争 |
| is_soft / is_hard | 支持软到期（RT 下可延迟）和硬到期 |

---

## 5. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/hrtimer.h` | `struct hrtimer` |
| `kernel/time/hrtimer.c` | `enqueue_hrtimer`、`__hrtimer_run_queues`、`hrtimer_forward` |
