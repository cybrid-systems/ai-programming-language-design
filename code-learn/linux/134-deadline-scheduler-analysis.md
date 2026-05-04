# 134-deadline — 读 kernel/sched/deadline.c：CBS 算法

---

## CBS（Constant Bandwidth Server）的代码形态

SCHED_DEADLINE 的核心是 CBS 算法——每个任务有一个周期（period）、预算（runtime）和截止时间（deadline）。内核保证在每个周期内，任务至少获得 runtime 的执行时间，且在 deadline 前完成。

在代码中，这三个参数存储在 `struct sched_dl_entity` 中：

```c
// include/linux/sched.h L644
struct sched_dl_entity {
    u64  dl_runtime;    // 每周期最大执行时间
    u64  dl_deadline;   // 相对截止时间
    u64  dl_period;     // 周期

    // 当前运行状态
    s64  runtime;       // 当前周期的剩余预算（递减）
    u64  deadline;      // 当前周期的绝对截止时间（递增）
};
```

---

## update_curr_dl——预算消耗

（`kernel/sched/deadline.c` L1936）

```c
static void update_curr_dl(struct rq *rq)
{
    struct task_struct *donor = rq->donor;     // proxy-exec: donor != curr
    struct sched_dl_entity *dl_se = &donor->dl;

    delta_exec = update_curr_common(rq);        // 物理时间增量
    update_curr_dl_se(rq, dl_se, delta_exec);   // 预算递减 + 超限检测
}
```

`update_curr_dl_se` 递减 `dl_se->runtime`。当 `runtime <= 0` 时：

```c
if (dl_se->runtime <= 0) {
    dl_se->dl_throttled = 1;    // 标记为节流
    // 如果超时过多，记录 overrun
    if (unlikely(dl_se->runtime < -dl_se->dl_bw))
        dl_se->dl_overrun = 1;
    // 启动 replenishment 定时器
    start_dl_timer(dl_se);
}
```

`dl_throttled = 1` 意味着该任务在当前周期不能再运行——它的预算已经用完了。任务不会被调度（`enqueue_task_dl` 跳过 `dl_throttled` 的任务）。

---

## dl_task_timer——预算重置

（`kernel/sched/deadline.c` L1210）

当一个 DL 任务的周期到期时，hrtimer 回调重新填充预算：

```c
static enum hrtimer_restart dl_task_timer(struct hrtimer *timer)
{
    dl_se->runtime += dl_se->dl_runtime;    // 重新填充预算
    dl_se->deadline += dl_se->dl_period;    // 推进截止时间
    dl_se->dl_throttled = 0;                // 解除节流

    if (p->on_rq) {
        enqueue_task_dl(rq, p, ENQUEUE_REPLENISH);  // 重新入队
        resched_curr(rq);                            // 触发重调度
    }
}
```

这就是 CBS 的完整实现。没有复杂的公式——每次 tick 递减预算，预算耗尽时停用，定时器到期时重置。

---

## push_dl_task——负载均衡

（`kernel/sched/deadline.c` L2921）

DL 任务的特殊之处：它们必须满足截止时间。如果本 CPU 的 DL 任务过多，push 机制将 deadline 最晚的任务推送到其他 CPU：

```c
static int push_dl_task(struct rq *rq)
{
    // 找到本 CPU 上 deadline 最晚的可迁移 DL 任务
    // 找到目标 CPU（deadline 最早且带宽足够的）
    // 如果目标 CPU 的 earliest_deadline.curr > 任务 deadline
    //   迁移任务到目标 CPU
}
```

pull 机制相反：当 CPU 变为 idle 时，从其他 CPU 拉取 deadline 最早的任务。
