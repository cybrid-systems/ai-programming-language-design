# Linux SCHED_DEADLINE 调度器深度分析

## 概述

SCHED_DEADLINE（`dl_sched_class`）是 Linux 内核的硬实时调度器，实现 **Earliest Deadline First（EDF）** 算法与 **Constant Bandwidth Server（CBS）** 机制的结合。自 Linux 3.14 合入主线以来，它为嵌入式、音视频和工业控制系统提供确定性的实时调度保证。

SCHED_DEADLINE 为每个任务指定三个参数：
- `sched_runtime`：每个周期的最大执行时间
- `sched_deadline`：相对截止时间（周期内必须完成）
- `sched_period`：周期长度

核心保证：如果一个周期内任务执行时间不超过 `runtime`，调度器保证在 `deadline` 前完成。

## 核心数据结构

### struct sched_dl_entity — 实时调度实体

（`include/linux/sched.h` L644~720）

```c
struct sched_dl_entity {
    struct rb_node          rb_node;            // 按 absolute deadline 排序的红黑树节点

    /* 原始参数（用户设置的，不会变） */
    u64                     dl_runtime;         // 每周期最大执行时间（ns）
    u64                     dl_deadline;        // 相对截止时间（ns）
    u64                     dl_period;          // 周期（ns）
    u64                     dl_bw;              // 带宽 = dl_runtime / dl_period
    u64                     dl_density;         // 密度 = dl_runtime / dl_deadline

    /* 当前运行参数（动态更新） */
    s64                     runtime;            // 当前周期的剩余执行时间
    u64                     deadline;           // 当前周期的绝对截止时间
    unsigned int            flags;              // 调度器行为标志

    /* 布尔状态位 */
    unsigned int            dl_throttled      : 1;  // 时间已耗尽，等待 replenish
    unsigned int            dl_yielded        : 1;  // 主动让出 CPU
    unsigned int            dl_non_contending : 1;  // 任务不活跃但仍在贡献带宽
    unsigned int            dl_overrun        : 1;  // 溢出通知
    unsigned int            dl_server         : 1;  // 这是一个 server 实体（用于公平调度）

    /* 定时器 */
    struct hrtimer          dl_timer;           // replenishment 定时器
    struct hrtimer          inactive_timer;     // 非竞争状态定时器
};
```

**关键概念**：
- `dl_runtime / dl_period` 定义了任务的 CPU 带宽利用率
- 如果所有 DL 任务的带宽总和 <= 100%，scheduleability 保证成立
- `dl_density = dl_runtime / dl_deadline` 比带宽更精确的调度判定标准

### struct dl_rq — DL 运行队列

（`kernel/sched/sched.h` L873~895）

```c
struct dl_rq {
    struct rb_root_cached   root;               // 按 absolute deadline 排序的红黑树
    unsigned int            dl_nr_running;      // 正在运行的 DL 任务数

    struct {
        u64                 curr;               // 当前运行任务的 deadline
        u64                 next;               // 最早就绪任务的 deadline
    } earliest_dl;                              // 缓存最新 deadline，避免树遍历

    unsigned int            dl_nr_migratory;    // 可迁移的任务数
    unsigned long           dl_bw_idle;         // idle 带宽
    ...
};
```

### sched_dl_entity 的标志位含义

| 标志 | 意义 | 触发 | 清除 |
|------|------|------|------|
| `dl_throttled` | 已耗尽时间，被节流 | `runtime ≤ 0` | `dl_task_timer()` replenish |
| `dl_yielded` | 主动让出 | `sched_yield()` DL 任务 | 下一个周期 |
| `dl_non_contending` | 不运行但带宽未释放 | `put_prev_task_dl()` | 下一个唤醒或 inactive 定时器到期 |
| `dl_overrun` | 运行时间超限 | `runtime < 0` | 通知用户空间 |
| `dl_server` | 作为 fair server | 由 fair 调度器创建 | 销毁 |

## CBS 算法详解

Constant Bandwidth Server 是 SCHED_DEADLINE 的核心机制。它将任务抽象为一个"服务器"，该服务器在每个周期获得固定预算的执行时间。

### 正常运行（任务在 deadline 前完成）

```
   runtime ↑
     │      ┌────────────────┐
   r0 │     │                │
     │     │  执行任务       │
     │     │                 │
     │     │    runtime 递减  │
     └─────┴────────────────┴───────────→ time
           │                │
         周期开始         下个周期
         deadline=d0       deadline=d0+period
```

### 时间耗尽（dl_throttled）

```
   runtime ↑
     │      ┌───────┐
   r0 │     │ 执行  │
     │     │       │
     │     │       │← runtime=0, dl_throttled=1
     │     │       │
     └─────┴───────┴─────────────────────→ time
           │               │
          deadline        replenish at
                          deadline + period
```

### 提前完成（dl_non_contending）

```
   runtime ↑
     │      ┌────────┐
   r0 │     │ 执行    │
     │     │        │
     │     │        │← 任务阻塞（如I/O等待）
     │     │        │  dl_non_contending=1
     │     │        │  inactive_timer 启动
     └─────┴────────┴────────────────────→ time
           │                │
         如果 inactive_timer 到期前任务被唤醒 → 继续当前周期
         如果到期 → bandwidth 释放，下个周期重新开始
```

### CBS 核心规则

```
每个周期（deadline）开始：
  runtime = dl_runtime
  deadline = 当前时间 + dl_deadline

运行时（update_curr_dl）:
  runtime -= delta_exec
  如果 runtime ≤ 0:
    dl_throttled = 1
    start_dl_timer() — 在 deadline + period 时 replenish

replenish（dl_task_timer）:
  if dl_throttled:
    runtime += dl_runtime
    deadline += dl_period
    dl_throttled = 0
    if task 仍然可运行 → 重新入队
```

## 关键执行路径

### enqueue_task_dl()

（`kernel/sched/deadline.c` L720 附近）

```c
static void enqueue_task_dl(struct rq *rq, struct task_struct *p, int flags)
{
    struct sched_dl_entity *dl_se = &p->dl;

    // 1. 如果被节流（dl_throttled）且不是直接被定时器唤醒 → 不入队
    if (dl_se->dl_throttled && !(flags & ENQUEUE_REPLENISH))
        return;

    // 2. 如果不是第一个周期（之前运行过）
    if (!(flags & ENQUEUE_INITIAL)) {
        if (dl_se->dl_non_contending) {
            // 从非竞争状态唤醒 → 取消 inactive_timer
            // 继续使用当前周期的 deadline
            ...
        }
    }

    // 3. 更新带宽统计
    add_rq_bw(dl_se, &rq->dl);
    add_running_bw(dl_se, &rq->dl);

    // 4. 入队到红黑树
    __enqueue_dl_entity(dl_se);

    // 5. 如果可迁移（!p->nr_cpus_allowed == 1），加入 pushable 列表
    if (!dl_task_is_migratable(p))
        enqueue_pushable_dl_task(rq, p);
}
```

### dequeue_task_dl()

（L778 附近）

```c
static void dequeue_task_dl(struct rq *rq, struct task_struct *p, int flags)
{
    struct sched_dl_entity *dl_se = &p->dl;

    // 1. 从红黑树移除
    __dequeue_dl_entity(dl_se);

    // 2. 从 pushable 列表移除
    dequeue_pushable_dl_task(rq, p);

    // 3. 更新带宽统计
    sub_running_bw(dl_se, &rq->dl);
    sub_rq_bw(dl_se, &rq->dl);

    // 4. 如果任务主动睡眠且是最后一个周期 → 启动 inactive_timer
    if (flags & DEQUEUE_SLEEP) {
        // 不是第一个周期且时间没用完 → 非竞争状态
        if (!dl_se->dl_non_contending) {
            dl_se->dl_non_contending = 1;
            // 启动 inactive_timer：周期剩余时间
            start_hrtimer(&dl_se->inactive_timer,
                         deadline - now, HRTIMER_MODE_REL);
        }
    }

    // 5. 从 DL 运行队列移除
    __dequeue_task_dl(rq, p, flags);
}
```

### pick_next_task_dl()

（通过 `dl_sched_class.pick_next_task`）

选择 deadline 最早的就绪任务：

```c
static struct task_struct *pick_next_task_dl(struct rq *rq)
{
    struct sched_dl_entity *dl_se;
    struct dl_rq *dl_rq = &rq->dl;

    if (!dl_rq->dl_nr_running)
        return NULL;

    // 从红黑树取最左节点（deadline 最小）
    dl_se = __pick_next_dl_entity(dl_rq);

    // ... 更新 earliest_dl.curr 缓存
    dl_rq->earliest_dl.curr = dl_se->deadline;

    return dl_task_of(dl_se);
}
```

### update_curr_dl() — 运行时会计

（`kernel/sched/deadline.c` 附近）

```c
static void update_curr_dl(struct rq *rq)
{
    struct task_struct *curr = rq->curr;
    struct sched_dl_entity *dl_se = &curr->dl;
    s64 delta_exec, new_exec;

    if (!dl_task(curr) || !on_dl_rq(dl_se))
        return;

    delta_exec = rq_clock_task(rq) - curr->se.exec_start;
    if (unlikely(!delta_exec))
        return;

    schedstat_set(curr->se.statistics.exec_max,
                  max(delta_exec, curr->se.statistics.exec_max));

    curr->se.exec_start = rq_clock_task(rq);
    curr->se.sum_exec_runtime += delta_exec;
    account_group_exec_runtime(curr, delta_exec);

    // CBS：剩余运行时间递减
    dl_se->runtime -= delta_exec;
    new_exec = curr->se.sum_exec_runtime - curr->se.prev_sum_exec_runtime;

    if (dl_se->runtime <= 0) {
        // 时间耗尽！检查溢出
        dl_se->dl_throttled = 1;

        // 如果超出时间太多 → 通知内核/用户
        if (unlikely(dl_se->runtime < -new_exec))
            dl_se->dl_overrun = 1;

        // 如果不能继续运行
        if (!dl_se->dl_throttled && !is_dl_boosted(dl_se)) {
            // 从运行队列移除
            dequeue_task_dl(rq, curr, 0);
            // 启动 replenishment 定时器
            start_dl_timer(dl_se);
        }
        resched_curr(rq);
    }
}
```

### start_dl_timer() — Replenishment 定时器

（`kernel/sched/deadline.c` L1061）

```c
static int start_dl_timer(struct sched_dl_entity *dl_se)
{
    struct hrtimer *timer = &dl_se->dl_timer;
    ktime_t now, act;
    ktime_t soft;

    // 计算唤醒时间：deadline + period（下次 replenish）
    // 但考虑 deferred server 的 soft/hard 时间
    now = hrtimer_cb_get_time(timer);
    soft = ns_to_ktime(dl_se->deadline);
    act = ns_to_ktime(dl_se->deadline + dl_se->dl_deadline);

    // 设置 hrtimer
    hrtimer_set_expires(timer, act);

    // 启动
    return hrtimer_start(timer, act, HRTIMER_MODE_ABS_HARD);
}
```

### dl_task_timer() — Replenishment 处理

（`kernel/sched/deadline.c` L1210）

```c
static enum hrtimer_restart dl_task_timer(struct hrtimer *timer)
{
    struct sched_dl_entity *dl_se = container_of(timer, ...);
    struct task_struct *p = dl_task_of(dl_se);
    struct rq_flags rf;
    struct rq *rq;

    rq = task_rq_lock(p, &rf);

    // 1. 检测竞争（定时器被重新设置了）
    if (hrtimer_is_queued(timer)) {
        task_rq_unlock(rq, p, &rf);
        return HRTIMER_NORESTART;
    }

    // 2. 更新带宽
    update_curr_dl(rq);

    // 3. CBS replenish
    dl_se->runtime += dl_se->dl_runtime;
    dl_se->deadline += dl_se->dl_period;
    dl_se->dl_throttled = 0;

    // 4. 如果任务可运行，重新入队
    if (p->on_rq) {
        enqueue_task_dl(rq, p, ENQUEUE_REPLENISH);
        resched_curr(rq);
    }

    task_rq_unlock(rq, p, &rf);
    return HRTIMER_NORESTART;
}
```

## 带宽管理与准入控制

SCHED_DEADLINE 的核心调度保证通过**准入控制**（admission control）实现：

```c
// kernel/sched/core.c — dl_bw_manage()
int dl_bw_manage(struct task_struct *p, const struct sched_attr *attr)
{
    struct dl_bw *dl_b;
    u64 new_bw = to_ratio(attr->sched_period, attr->sched_runtime);

    dl_b = &rq->rd->dl_bw;

    if (dl_b->total_bw + new_bw > dl_b->bw) {
        // 带宽不够！拒绝
        return -EBUSY;
    }

    dl_b->total_bw += new_bw;
    return 0;
}
```

带宽控制有两个层面：

### 1. CPU 级别带宽

每个 CPU 组的最大带宽由 `cpu.cfs_quota_us` / `cpu.cfs_period_us` 决定。SCHED_DEADLINE 的带宽不能超过这个限制。

### 2. 全局/根域带宽

```c
struct dl_bw {
    u64             total_bw;       // 已分配的总带宽
    u64             bw;             // 最大可分配带宽
    raw_spinlock_t  lock;
};
```

默认 `bw = 1 << 20`（100% CPU）。可通过 `/proc/sys/kernel/sched_rt_runtime_us` 和 `sched_rt_period_us` 间接控制。

### 可调度性测试

```
CBS 可调度性条件（简化）：
  Σ (dl_runtime_i / dl_period_i) ≤ U_max

其中 U_max：
  - 单核：≤ 1（100% CPU）
  - 多核：≤ nr_cpus × 1
  - 需要预留一部分带宽给 RT 和 fair 类
```

## 迁移与推拉（Push-Pull）

### push_dl_task()

当高优先级 DL 任务被唤醒时，如果本地 CPU 的 DL 任务已满（带宽不够），调度器尝试将低优先级的 DL 任务推送到其他 CPU：

```c
static int push_dl_task(struct rq *rq)
{
    struct task_struct *next_task;
    struct rb_node *next_node;

    // 找到当前 CPU 上 deadline 最晚的 DL 任务（最容易被 push 出去）
    struct rb_node *leftmost = dl_rq->root.rb_root.rb_node;
    // ... 查找 deadline 最晚的可迁移任务

    // 目标 CPU 选择：找到 deadline 最早且带宽足够的 CPU
    // 通过 dl_find_any_cpu() 或 dl_find_lowest_cpu()
}
```

### pull_dl_task()

当 CPU 变为 idle 时（或者 DL 任务完成），从其他 CPU 拉取 DL 任务：

```c
static void pull_dl_task(struct rq *this_rq)
{
    // 遍历所有 CPU 的 pushable DL 任务
    // 如果某个 DL 任务 deadline 早于本 CPU 的当前 earliest
    // 且目标 CPU 允许该任务运行 → pull
}
```

推拉机制确保了 DL 任务的全局负载平衡，使 deadline 最早的任务总是被优先执行。

## DL Server：支持公平调度类

从 Linux 6.x 开始，SCHED_DEADLINE 增加了 **DL Server** 机制：

```c
// sched_dl_entity 中的 dl_server 标志
unsigned int dl_server:1;        // 这是一个 server 实体
unsigned int dl_server_active:1; // server 是否活跃
```

DL Server 为 CFS/EEVDF 任务提供了"截止时间保障"：当 CFS 运行队列非空时，DL Server 激活，以 EDF 优先级执行 CFS 任务。这实现了：

```
（高）RT 任务 → 最早 deadline 优先
       │
DL Server → 包含所有 CFS 任务，以 EDF 调度
       │
（低）RT 任务（如果带宽没有用完）
```

实际上，DL Server 使 EEVDF 任务在 DL 调度器的保护伞下运行，获得了等同实时任务的 deadline 保障，同时保留了公平调度的 CPU 时间分配。

## SCHED_DEADLINE vs RT 调度器

| 特性 | SCHED_FIFO / SCHED_RR | SCHED_DEADLINE |
|------|----------------------|----------------|
| 调度算法 | 优先级 + FIFO / 时间片轮转 | EDF + CBS |
| 参数 | 优先级 0-99 | runtime, deadline, period |
| 保证 | 最高优先级永远优先 | 带宽保证（CBS 算法） |
| 溢出处理 | 无（可能会饿死） | dl_throttled + replenish |
| 准入控制 | 无（所有 RT 任务都可运行） | dl_bw_manage() 检查带宽 |
| 调度分析 | 基于优先级（难保证截止时间） | 基于可调度性分析 |
| 适用场景 | 传统实时系统 | 硬实时 + 多媒体 + 自动驾驶 |

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct sched_dl_entity` | include/linux/sched.h | 644 |
| `struct dl_rq` | kernel/sched/sched.h | 873 |
| `enqueue_task_dl()` | kernel/sched/deadline.c | 720 |
| `dequeue_task_dl()` | kernel/sched/deadline.c | 778 |
| `pick_next_task_dl()` | kernel/sched/deadline.c | 相关 |
| `update_curr_dl()` | kernel/sched/deadline.c | 相关 |
| `start_dl_timer()` | kernel/sched/deadline.c | 1061 |
| `dl_task_timer()` | kernel/sched/deadline.c | 1210 |
| `push_dl_task()` | kernel/sched/deadline.c | 620 |
| `pull_dl_task()` | kernel/sched/deadline.c | 631 |
| `dl_bw_manage()` | kernel/sched/core.c | 相关 |
| `struct dl_bw` | kernel/sched/sched.h | 相关 |
| `enqueue_pushable_dl_task()` | kernel/sched/deadline.c | 581 |
| `__dequeue_dl_entity()` | kernel/sched/deadline.c | 相关 |
| `grub_replenishment()` | kernel/sched/deadline.c | 相关 |
| `dl_sched_class` | kernel/sched/deadline.c | (调度类全局) |
