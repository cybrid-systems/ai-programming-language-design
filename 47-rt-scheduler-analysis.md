# Linux Kernel RT 调度器 (SCHED_FIFO / SCHED_RR) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/sched/deadline.c` + `kernel/sched/rt.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 RT 调度器？

Linux 支持三种实时调度策略：
- `SCHED_FIFO`：先进先出，无时间片
- `SCHED_RR`：轮转，同优先级轮换
- `SCHED_DEADLINE`：EDF 最早截止时间优先

RT 任务是**优先级最高**的任务，抢占所有普通任务（CFS）。

---

## 1. 调度策略

```c
// include/uapi/linux/sched.h
#define SCHED_NORMAL    0    // CFS
#define SCHED_FIFO      1    // RT FIFO
#define SCHED_RR        2    // RT Round Robin
#define SCHED_BATCH     3    // Batch
#define SCHED_IDLE      5    // Idle
#define SCHED_DEADLINE  6    // EDF

// include/linux/sched/rt.h
struct sched_rt_entity {
    struct list_head run_list;         // RT 运行链表
    unsigned long        timeout;        // 时间片超时
    unsigned int        time_slice;     // RR 时间片（RR 专用）
    unsigned int        nr_cpus_allowed; // 允许的 CPU
    int                 nr_overruns;    // 累计超限次数
};

// RT 优先级：1（最低）~ 99（最高）
#define MAX_RT_PRIO     100
#define MAX_DL_PRIO     (MAX_RT_PRIO - 1)
```

---

## 2. SCHED_FIFO

```c
// kernel/sched/rt.c — enqueue_rt_entity
static void enqueue_rt_entity(struct sched_rt_entity *rt_se, unsigned int flags)
{
    for_each_sched_rt_entity(rt_se) {
        struct rt_rq *rt_rq = rt_rq_of_se(rt_se);

        // 插入对应优先级的链表（rt_rq->queue[prio]）
        list_add_tail(&rt_se->run_list, &rt_rq->queue[rt_se->prio]);

        // 更新 curr 和 highest
        if (rt_se->prio < rt_rq->highest_prio)
            rt_rq->highest_prio = rt_se->prio;
    }
}

// kernel/sched/rt.c — pick_next_rt_entity
static struct task_struct *pick_next_rt_task(struct rq *rq)
{
    // 从最高优先级链表中取第一个任务
    for (prio = 0; prio < MAX_RT_PRIO; prio++) {
        struct rt_rq *rt_rq = &rq->rt;
        struct list_head *queue = &rt_rq->queue[prio];

        if (!list_empty(queue)) {
            rt_entity = list_entry(queue->next, struct sched_rt_entity, run_list);
            return rt_task_of(rt_entity);
        }
    }
    return NULL;  // 没有 RT 任务
}
```

---

## 3. SCHED_RR — 轮转

```c
// kernel/sched/rt.c — enqueue_rt_entity
// SCHED_RR 与 FIFO 的区别：SCHED_RR 有时间片

// pick_next_rt_task
static struct task_struct *pick_next_rt_task(struct rq *rq)
{
    // 遍历方式同 FIFO
    // SCHED_RR：每次从链表头部取
}

// 时间片耗尽时：
static void sched_rt_rr_period_timer(struct timer_list *timer)
{
    // 1. 当前任务放回链表尾部
    if (rq->rt.rr_nr_running > 1) {
        list_for_each_entry(task, &rq->rt.queue[prio], run_list) {
            // 轮换：放到链表尾部
            list_move_tail(&task->rt.run_list, &rq->rt.queue[prio]);
            break;
        }
    }

    // 2. 重置时间片
    for_each_sched_rt_entity(rt_se)
        rt_se->time_slice = RR_TIMESLICE;
}
```

---

## 4. RT 抢占 CFS

```c
// kernel/sched/rt.c — check_preempt_curr_rt
static void check_preempt_curr_rt(struct rq *rq, struct task_struct *p, int flags)
{
    // 如果有 RT 任务就绪，立即抢占 CFS
    if (rt_task(p) && rq->rt_nr_running > 0)
        resched_task(rq->curr);  // 设置 TIF_NEED_RESCHED
}
```

---

## 5. SCHED_DEADLINE — EDF

```c
// kernel/sched/deadline.c — EDF (Earliest Deadline First)
struct sched_dl_entity {
    u64             dl_runtime;       // 最大运行时间
    u64             dl_deadline;       // 截止时间
    u64             dl_period;         // 周期
    u64             runtime;           // 剩余运行时间
    u64             deadline;          // 当前截止时间
    struct hrtimer  dl_timer;         // 调度定时器
};

// pick_next_dl_entity — 最早截止时间优先
static void pick_next_dl_entity(struct rq *rq, struct dl_rq *dl_rq)
{
    // 按 deadline 排序的红黑树
    // 最左节点 = deadline 最近的任务
    struct rb_node *left = rb_first_cached(&dl_rq->root);

    // 返回 deadline 最近的任务
}
```

---

## 6. 参考

| 文件 | 内容 |
|------|------|
| `kernel/sched/rt.c` | `enqueue_rt_entity`、`pick_next_rt_task`、`sched_rt_rr_period_timer` |
| `include/linux/sched/rt.h` | `struct sched_rt_entity` |
| `kernel/sched/deadline.c` | `EDF`、`struct sched_dl_entity` |
| `include/uapi/linux/sched.h` | `SCHED_FIFO`、`SCHED_RR`、`SCHED_DEADLINE` |
