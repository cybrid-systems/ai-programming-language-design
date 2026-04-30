# RT scheduler — 实时调度器深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/sched/rt.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**RT scheduler** 是 Linux 的实时调度器（SCHED_FIFO / SCHED_RR），保证高优先级任务永远先于低优先级任务运行。

---

## 1. 调度策略

```c
// include/linux/sched.h
#define SCHED_FIFO        0x01  // 先进先出（无时间片）
#define SCHED_RR          0x02  // 轮转（有时间片）
#define SCHED_DEADLINE    0x03  // 期限驱动（最高优先级）

// 优先级范围：1（最低）~ 99（最高）
#define MAX_RT_PRIO       100
#define MAX_DL_PRIO       0
```

---

## 2. 核心数据结构

### 2.1 rt_rq — RT 运行队列

```c
// kernel/sched/rt.h — rt_rq
struct rt_rq {
    // 优先级数组（100 个桶）
    struct rt_prio_array {
        unsigned long       bitmap[16];  // 16 * 64 = 1024 位 → 覆盖 100 优先级
        struct list_head    queue[100];  // 每优先级一个链表
    } active;

    unsigned int           rt_nr_running;   // 可运行的 RT 任务数
    unsigned int           rt_nr_migratory; // 可迁移的 RT 任务数
    unsigned long          rt_throttled;    // 是否被节流

    // 时间片（RR）
    unsigned int           time_slice;      // 剩余时间片
    unsigned int           rt_queued;       // 是否在队列中

    // Deadline
    struct dl_rq          *dl;            // 链接到 dl_rq
};
```

### 2.2 sched_rt_entity — RT 调度实体

```c
// kernel/sched/rt.h — sched_rt_entity
struct sched_rt_entity {
    struct sched_entity    se;             // 基类

    // RR 时间片
    unsigned int           time_slice;     // RR 的剩余时间片

    // 优先级（nice 值映射）
    unsigned int           rt_priority;    // 1~99（越高越先）

    // 链表
    struct list_head        run_list;       // 接入队列

    unsigned char           on_rq;         // 是否在运行队列
};
```

---

## 3. 调度逻辑

### 3.1 pick_next_task_rt — 选择下一个 RT 任务

```c
// kernel/sched/rt.c — pick_next_task_rt
static struct task_struct *pick_next_task_rt(struct rq *rq)
{
    struct sched_rt_entity *rt_se;
    struct rt_rq *rt_rq = &rq->rt;

    // 1. 找最高优先级桶
    int idx = sched_find_first_bit(rt_rq->active.bitmap);

    // 2. 取链表第一个
    rt_se = list_entry(rt_rq->active.queue[idx].next, struct sched_rt_entity, run_list);

    return rt_se ? task_of(rt_se) : NULL;
}
```

### 3.2 enqueue_task_rt — 入队 RT 任务

```c
// kernel/sched/rt.c — enqueue_task_rt
static void enqueue_task_rt(struct rq *rq, struct task_struct *p, int flags)
{
    struct sched_rt_entity *rt_se = &p->rt;
    struct rt_rq *rt_rq = &rq->rt;

    // 1. 设置 on_rq
    rt_se->on_rq = 1;

    // 2. 加入优先级链表
    list_add(&rt_se->run_list, rt_rq->active.queue[rt_se->rt_priority].next);

    // 3. 设置优先级位图
    set_bit(rt_se->rt_priority, rt_rq->active.bitmap);

    // 4. 更新计数
    rt_rq->rt_nr_running++;
}
```

---

## 4. RR 时间片轮转

```c
// kernel/sched/rt.c — sched_rt_rr_interval
unsigned int sched_rt_rr_interval(struct task_struct *p)
{
    // RT 任务的时间片（默认 100ms）
    // SCHED_FIFO：无时间片限制，一直运行直到阻塞或被更高优先级抢断
    // SCHED_RR：每个时间片后重新入队

    if (p->policy == SCHED_FIFO)
        return 0;  // 无限制

    if (p->policy == SCHED_RR)
        return sysctl_sched_rr_timeslice;  // 默认 100ms

    return 0;
}
```

---

## 5. 优先级继承（PI）

```c
// kernel/sched/rt.c — rt_mutex_adjust_pi
static void rt_mutex_adjust_pi(struct task_struct *p)
{
    // 高优先级任务等待低优先级任务持有的锁
    // → 提升低优先级任务的优先级（等于等待者）
    // → 避免优先级反转

    struct rt_mutex_waiter *waiter;
    unsigned long flags;

    raw_spin_lock_irqsave(&p->pi_lock, flags);

    waiter = p->pi_blocked_on;
    if (!waiter)
        goto out_unlock;

    // 提升持有者的优先级
    if (rt_prio(waiter->prio) < rt_prio(p->rt_priority))
        p->rt_priority = p->rt_priority;  // 继承更高优先级

out_unlock:
    raw_spin_unlock_irqrestore(&p->pi_lock, flags);
}
```

---

## 6. 与 CFS 的区别

| 特性 | RT (FIFO/RR) | CFS |
|------|--------------|-----|
| 调度算法 | 优先级队列 | 红黑树（vruntime）|
| 时间片 | RR 有，FIFO 无 | 有（动态计算）|
| 延迟 | 硬实时保证 | 软实时（可被高优先级抢占）|
| 饥饿 | 可能（低优先级一直等）| 低优先级最终都会运行 |
| 优先级 | 静态（用户指定）| 动态（基于 vruntime）|

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/sched/rt.h` | `struct rt_rq`、`struct sched_rt_entity` |
| `kernel/sched/rt.c` | `pick_next_task_rt`、`enqueue_task_rt` |
| `include/linux/sched.h` | `SCHED_FIFO`、`SCHED_RR`、`SCHED_DEADLINE` |