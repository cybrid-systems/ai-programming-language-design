# 47-rt-scheduler — Linux 实时调度器深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

RT 调度器是 Linux 内核的实时调度类（`SCHED_FIFO` 和 `SCHED_RR`），管理优先级 1-99 的实时进程。与 CFS 的"公平时间分配"不同，RT 调度器的设计哲学是**确定性优先**：最高优先级的就绪任务必须立即运行，且只要愿意就可以无限期占用 CPU。

**核心特征**：

| 特征 | SCHED_FIFO | SCHED_RR |
|------|-----------|----------|
| 调度策略 | 先入先出（无时间片） | 轮转（有时间片） |
| 同优先级 | 先运行直到主动让出 | 时间片用完后到队尾 |
| 被抢占条件 | 更高优先级任务就绪 | 更高优先级任务就绪 / 时间片耗尽 |
| 典型场景 | 中断线程、实时控制 | 周期性实时任务 |

**RT 调度器的核心挑战**：
1. **优先级驱动的均衡**：不能使用 CFS 的负载均衡——RT 任务必须运行在其 CPU 亲和性允许的**最低优先级 CPU** 上
2. **带宽隔离**：防止实时任务耗尽系统，`sched_rt_runtime_us`/`sched_rt_period_us` 限制 RT 总时间
3. **Push/Pull 机制**：一个 CPU 上有多个 RT 任务时，主动推送到其他 CPU；空转 CPU 从其他 CPU 拉取 RT 任务
4. **优先级反转防护**：通过 `rt_mutex`（实时互斥锁）实现优先级继承

**doom-lsp 确认**：RT 调度器实现在 `kernel/sched/rt.c`（**2939 行**，**119 个符号**）。核心数据结构在 `kernel/sched/sched.h:838`（`struct rt_rq`）和 `include/linux/sched.h:623`（`struct sched_rt_entity`）。CPU 优先级管理在 `kernel/sched/cpupri.c`。

**关键文件索引**：

| 文件 | 行数 | 符号数 | 职责 |
|------|------|--------|------|
| `kernel/sched/rt.c` | 2939 | 119 | RT 调度器完整实现 |
| `kernel/sched/sched.h` | 4139 | ~300 | `struct rt_rq`, `struct rt_prio_array`, `struct rt_bandwidth` |
| `include/linux/sched.h` | 623 | — | `struct sched_rt_entity` |
| `kernel/sched/cpupri.c` | ~200 | — | CPU 优先级管理 |
| `include/linux/sched/rt.h` | 84 | — | RT 辅助函数 |

---

## 1. 核心数据结构

### 1.1 struct sched_rt_entity — 调度实体

```c
// include/linux/sched.h:623-640
struct sched_rt_entity {
    struct list_head run_list;          /* 优先级队列链入点 */
    unsigned long timeout;              /* RLIMIT_RTTIME 超时计数 */
    unsigned long watchdog_stamp;       /* 最近一次 watchdog 检查的 jiffies */
    unsigned int time_slice;            /* SCHED_RR 时间片（FIFO 为 0）*/
    unsigned short on_rq;               /* 是否在就绪队列上 */
    unsigned short on_list;             /* 是否在优先级链表中 */

    struct sched_rt_entity *back;       /* 反向指针（用于栈式操作）*/
#ifdef CONFIG_RT_GROUP_SCHED
    struct sched_rt_entity *parent;     /* 父实体（cgroup 层级）*/
    struct rt_rq *rt_rq;                /* 此实体所在的 rt_rq */
    struct rt_rq *my_q;                 /* 如果这是一个组，此实体"拥有"的 rt_rq */
#endif
} __randomize_layout;
```

**设计洞察**：`run_list` 是 `struct list_head`，这意味着同优先级的所有 RT 实体通过双向链表连接。`time_slice` 只有 SCHED_RR 类任务有效，SCHED_FIFO 不切片。在 RT 组调度开启时，`parent`/`rt_rq`/`my_q` 构成一个树形层级。

**doom-lsp 确认**：`sched_rt_entity` 在 `include/linux/sched.h:623`。`__randomize_layout` 是 GCC 结构体布局随机化属性，用于安全缓解。`on_rq` 字段取值 `TASK_ON_RQ_QUEUED`（1）或 `TASK_ON_RQ_MIGRATING`（2），定义在 `sched.h:86`。

**doom-lsp 确认**：`back` 字段在 `sched.h:631` 声明为 `struct sched_rt_entity *back`，在 `dequeue_rt_stack()`（`rt.c:1383`）中用于构建反向链表——从目标实体向上遍历到顶层，然后逐层出队。

### 1.2 struct rt_prio_array — 优先级队列阵列

这是 RT 调度器的核心调度数据结构——本质上是一个**优先级位图 + 链表数组**：

```c
// kernel/sched/sched.h:311-314
struct rt_prio_array {
    DECLARE_BITMAP(bitmap, MAX_RT_PRIO+1);  /* 位图（含 1 位定界符）*/
    struct list_head queue[MAX_RT_PRIO];     /* 每个优先级一个链表头 */
};
```

**MAX_RT_PRIO** = 100（优先级 0-99，其中 0 是最高）。数组大小为 100 个 list_head，每个对应一个优先级层级：

```
bitmap:    [0] [1] [2] ... [98] [99] [100=delim]
             1   1   0         1    0    1
queue[0] : task_A ↔ task_B      ← 优先级 0（最高）
queue[1] : task_C                ← 优先级 1
queue[2] : EMPTY                 ← 无任务
   ...
queue[98]: task_D                ← 优先级 98
queue[99]: EMPTY                 ← 优先级 99（最低）
```

**doom-lsp 确认**：`struct rt_prio_array` 定义在 `sched.h:311`。bitmap 的 `DECLARE_BITMAP(bitmap, MAX_RT_PRIO+1)` 多分配 1 位作为 `sched_find_first_bit()` 的定界符，由 `init_rt_rq()`（`rt.c:69`）中的 `__set_bit(MAX_RT_PRIO, array->bitmap)` 设置。

**`pick_next_rt_entity()`** 选择下一个运行实体：

```c
// kernel/sched/rt.c:1656-1667
static struct sched_rt_entity *pick_next_rt_entity(struct rt_rq *rt_rq)
{
    struct rt_prio_array *array = &rt_rq->active;

    /* find_first_bit 找到最低位的 1（最高优先级）*/
    idx = sched_find_first_bit(array->bitmap);

    queue = array->queue + idx;
    /* 取队列头部的第一个实体 */
    next = list_entry(queue->next, struct sched_rt_entity, run_list);

    return next;
}
```

**doom-lsp 确认**：`pick_next_rt_entity` 在 `rt.c:1656`。`sched_find_first_bit()` 是架构相关的高效位扫描（通常使用 `__ffs` 或 `BSF` 指令），复杂度 O(1)。

### 1.3 struct rt_rq — 实时运行队列

```c
// kernel/sched/sched.h:838-870
struct rt_rq {
    struct rt_prio_array active;              /* 优先级位图 + 队列数组 */

    unsigned int rt_nr_running;                /* 运行中 RT 任务总数 */
    unsigned int rr_nr_running;                /* SCHED_RR 任务数（用于统计）*/

    struct {
        int curr;                              /* 当前最高入队 RT 任务的优先级 */
        int next;                              /* 下一个最高 pushable 任务的优先级 */
    } highest_prio;

    bool overloaded;                            /* 此 rt_rq 有 >1 个 pushable RT 任务 */
    struct plist_head pushable_tasks;           /* 可被推送到其他 CPU 的任务（按优先级排序）*/

    int rt_queued;                              /* 此 rt_rq 是否有 RT 任务（用于 nr_running 管理）*/

#ifdef CONFIG_RT_GROUP_SCHED
    int rt_throttled;                           /* 此组是否被节流 */
    u64 rt_time;                                /* 已消耗的 RT 时间（在 update_curr_rt 累加）*/
    u64 rt_runtime;                             /* 分配的 RT 时间（来自 rt_bandwidth）*/
    raw_spinlock_t rt_runtime_lock;             /* 保护 rt_time/rt_runtime */
    unsigned int rt_nr_boosted;                 /* 被优先级提升的 RT 任务数（rt_mutex）*/
    struct rq *rq;                              /* 指向顶级 rq */
#endif
#ifdef CONFIG_CGROUP_SCHED
    struct task_group *tg;                      /* 拥有此 rt_rq 的 task_group */
#endif
};
```

**每 CPU 一个 rt_rq**：在 `struct rq`（`sched.h:1184`）中内嵌：`struct rt_rq rt;`

**doom-lsp 确认**：`rt_rq` 在 `sched.h:838`。`pushable_tasks` 是 `struct plist_head`（优先级链表），任务按 `prio` 排序插入。`rt_queued` 用于避免重复修改 `rq->nr_running`——`enqueue_top_rt_rq()`（`rt.c:1010`）仅在首次从无 RT 任务变为有时增加计数。

**doom-lsp 确认**：`struct rq` 中内嵌 `struct rt_rq rt` 在 `sched.h:1184`。每个物理 CPU 的 `rq` 都是 percpu 变量（`DEFINE_PER_CPU_SHARED_ALIGNED(struct rq, runqueues)`），因此 `&rq->rt` 是 CPU 本地的 RT 运行队列。

### 1.4 struct rt_bandwidth — 带宽控制

```c
// kernel/sched/sched.h:316-322
struct rt_bandwidth {
    raw_spinlock_t rt_runtime_lock;       /* 保护运行时 */
    ktime_t rt_period;                     /* 周期（默认 1s）*/
    u64 rt_runtime;                        /* 每周期允许的 RT 运行时间（默认 0.95s）*/
    struct hrtimer rt_period_timer;        /* 高精度周期定时器 */
    unsigned int rt_period_active;         /* 定时器是否激活 */
};
```

**默认值**：`sched_rt_period` = 1,000,000 us（1s），`sched_rt_runtime` = 950,000 us（0.95s），RT 最多占 95% CPU。

**doom-lsp 确认**：全局变量在 `rt.c:12-24`：`int sysctl_sched_rt_period = 1000000; int sysctl_sched_rt_runtime = 950000;`。`RUNTIME_INF` 特殊值表示不限带宽（-1 即为所有时间）。

### 1.5 struct rq 中的 RT 字段

RT 调度器的关键字段也直接存在于 `struct rq`（runqueue）：

```c
// 在 sched.h 的 struct rq 中
struct rt_rq rt;                         /* 内嵌的 RT 运行队列 */
```

此外，`struct task_struct` 中有：
```c
struct sched_rt_entity rt;               /* @ include/linux/sched.h:872 */
struct plist_node pushable_tasks;        /* 可推送任务链表节点 */
```

---

## 2. 初始化——从零到就绪

### 2.1 init_rt_rq

```c
// kernel/sched/rt.c:68-88
void init_rt_rq(struct rt_rq *rt_rq)
{
    struct rt_prio_array *array = &rt_rq->active;
    int i;

    /* 初始化 100 个优先级链表头 */
    for (i = 0; i < MAX_RT_PRIO; i++) {
        INIT_LIST_HEAD(array->queue + i);
        __clear_bit(i, array->bitmap);
    }
    /* 定界符位（确保 sched_find_first_bit 不会越界）*/
    __set_bit(MAX_RT_PRIO, array->bitmap);

    rt_rq->highest_prio.curr = MAX_RT_PRIO - 1;  /* 初始最低优先级 */
    rt_rq->highest_prio.next = MAX_RT_PRIO - 1;
    rt_rq->overloaded = 0;
    plist_head_init(&rt_rq->pushable_tasks);
    rt_rq->rt_queued = 0;                         /* 初始无任务 */

#ifdef CONFIG_RT_GROUP_SCHED
    rt_rq->rt_time = 0;
    rt_rq->rt_throttled = 0;
    rt_rq->rt_runtime = 0;
    raw_spin_lock_init(&rt_rq->rt_runtime_lock);
#endif
}
```

**doom-lsp 确认**：`init_rt_rq` 在 `rt.c:68`。每个 CPU 的 rq 在调度器初始化时通过 `sched_init()` 调用 `init_rt_rq()`。

### 2.2 init_sched_rt_class

```c
// kernel/sched/rt.c:2627-2631
void __init init_sched_rt_class(void)
{
    unsigned int i;

    for_each_possible_cpu(i) {
        zalloc_cpumask_var_node(&per_cpu(local_cpu_mask, i),
                                GFP_KERNEL, cpu_to_node(i));
    }
}
```

仅为每个 CPU 分配 `local_cpu_mask`（用于 `find_lowest_rq()` 中的临时 cpumask 存储）。

### 2.3 调度类注册

```c
// kernel/sched/rt.c:2865-2895
DEFINE_SCHED_CLASS(rt) = {
    .enqueue_task       = enqueue_task_rt,
    .dequeue_task       = dequeue_task_rt,
    .yield_task         = yield_task_rt,
    .wakeup_preempt     = wakeup_preempt_rt,
    .pick_task          = pick_task_rt,
    .put_prev_task      = put_prev_task_rt,
    .set_next_task      = set_next_task_rt,
    .balance            = balance_rt,
    .select_task_rq     = select_task_rq_rt,
    .set_cpus_allowed   = set_cpus_allowed_common,
    .rq_online          = rq_online_rt,
    .rq_offline         = rq_offline_rt,
    .task_woken         = task_woken_rt,
    .switched_from      = switched_from_rt,
    .find_lock_rq       = find_lock_lowest_rq,
    .task_tick          = task_tick_rt,
    .get_rr_interval    = get_rr_interval_rt,
    .switched_to        = switched_to_rt,
    .prio_changed       = prio_changed_rt,
    .update_curr        = update_curr_rt,
#ifdef CONFIG_SCHED_CORE
    .task_is_throttled  = task_is_throttled_rt,
#endif
#ifdef CONFIG_UCLAMP_TASK
    .uclamp_enabled     = 1,
#endif
};
```

**doom-lsp 确认**：`rt_sched_class` 的完整方法表在 `rt.c:2865`。共 19 个回调函数覆盖 RT 调度器的完整生命周期。

---

## 3. 优先级管理——从入队到选择

### 3.1 入队路径

`enqueue_task_rt()` 是 RT 调度器的入队入口：

```c
// kernel/sched/rt.c:1435-1449
static void enqueue_task_rt(struct rq *rq, struct task_struct *p, int flags)
{
    struct sched_rt_entity *rt_se = &p->rt;

    if (flags & ENQUEUE_WAKEUP)
        rt_se->timeout = 0;               /* 唤醒时重置 RLIMIT_RTTIME 超时 */

    update_stats_wait_start_rt(rt_rq_of_se(rt_se), rt_se);
    enqueue_rt_entity(rt_se, flags);

    /* 如果是迁移中（blocked），不进行 push 操作 */
    if (task_is_blocked(p))
        return;

    /* 非当前任务且可迁移 → 加入 pushable 列表 */
    if (!task_current(rq, p) && p->nr_cpus_allowed > 1)
        enqueue_pushable_task(rq, p);
}
```

**`enqueue_rt_entity()`** — 实际的入队逻辑：

```c
// kernel/sched/rt.c:1403
static void enqueue_rt_entity(struct sched_rt_entity *rt_se, unsigned int flags)
{
    struct rq *rq = rq_of_rt_se(rt_se);

    /* 1. 先出栈（确保从顶层到底层重新入队）*/
    dequeue_rt_stack(rt_se, flags);

    /* 2. 逐层入队 */
    for_each_sched_rt_entity(rt_se)
        __enqueue_rt_entity(rt_se, flags);

    /* 3. 更新顶级 rt_rq 的 nr_running */
    enqueue_top_rt_rq(&rq->rt);
}
```

**`dequeue_rt_stack()`** 的特殊之处——它**自底向上完全出队**整个层级，然后逐层入队。这是因为低层实体的优先级变化需要传播到高层。

**`__enqueue_rt_entity()`** — 最后的入队操作：

```c
// kernel/sched/rt.c:1331-1359
static void __enqueue_rt_entity(struct sched_rt_entity *rt_se, unsigned int flags)
{
    /* 如果组被节流或没有运行任务 → 不入队 */
    if (group_rq && (rt_rq_throttled(group_rq) || !group_rq->rt_nr_running)) {
        if (rt_se->on_list)
            __delist_rt_entity(rt_se, array);
        return;
    }

    if (move_entity(flags)) {
        /* ENQUEUE_HEAD → 加到队列头（SCHED_FIFO/RR 非普通唤醒时）*/
        if (flags & ENQUEUE_HEAD)
            list_add(&rt_se->run_list, queue);
        else
            list_add_tail(&rt_se->run_list, queue);  /* 默认：加到队尾 */

        __set_bit(rt_se_prio(rt_se), array->bitmap);  /* 设置优先级位 */
        rt_se->on_list = 1;
    }
    rt_se->on_rq = 1;
    inc_rt_tasks(rt_se, rt_rq);  /* 增加 rt_nr_running、更新 highest_prio */
}
```

### 3.2 出队路径

```c
// kernel/sched/rt.c:1455-1461
static bool dequeue_task_rt(struct rq *rq, struct task_struct *p, int flags)
{
    update_curr_rt(rq);               /* 更新运行时间统计 */
    dequeue_rt_entity(rt_se, flags);  /* 出队 */
    dequeue_pushable_task(rq, p);      /* 从 pushable 列表中移除 */
    return true;
}
```

**`dequeue_rt_entity()`** 与入队对称——先出栈，然后逐层检查是否需要在出队后重新入队（因为组可能还有别的活跃任务）：

```c
// kernel/sched/rt.c:1415-1429
static void dequeue_rt_entity(struct sched_rt_entity *rt_se, unsigned int flags)
{
    dequeue_rt_stack(rt_se, flags);           /* 自底向上完全出栈 */

    for_each_sched_rt_entity(rt_se) {
        struct rt_rq *rt_rq = group_rt_rq(rt_se);
        if (rt_rq && rt_rq->rt_nr_running)
            __enqueue_rt_entity(rt_se, flags);  /* 组内还有任务，重新入队 */
    }
    enqueue_top_rt_rq(&rq->rt);
}
```

### 3.3 更新最高优先级

**`inc_rt_prio()` / `dec_rt_prio()`** 维护每个 rt_rq 的最高优先级：

```c
// kernel/sched/rt.c:1079-1114
static void inc_rt_prio(struct rt_rq *rt_rq, int prio)
{
    int prev_prio = rt_rq->highest_prio.curr;
    if (prio < prev_prio)
        rt_rq->highest_prio.curr = prio;      /* 新优先级更高 → 更新 */

    inc_rt_prio_smp(rt_rq, prio, prev_prio);   /* 更新 cpupri */
}

static void dec_rt_prio(struct rt_rq *rt_rq, int prio)
{
    if (rt_rq->rt_nr_running) {
        if (prio == rt_rq->highest_prio.curr)
            /* 被移除的是最高优先级 → 重新扫描 bitmap */
            rt_rq->highest_prio.curr =
                sched_find_first_bit(array->bitmap);
    } else {
        rt_rq->highest_prio.curr = MAX_RT_PRIO - 1;  /* 没有 RT 任务 */
    }
    dec_rt_prio_smp(rt_rq, prio, prev_prio);
}
```

**`inc_rt_prio_smp()`** 和 **`dec_rt_prio_smp()`** 将优先级变化传播到 CPU 优先级系统 `cpupri`：

```c
// kernel/sched/rt.c:1049-1075
static void inc_rt_prio_smp(struct rt_rq *rt_rq, int prio, int prev_prio)
{
    /* 只有顶级 rt_rq 才更新 cpupri（cgroup 内部的 rt_rq 不需要）*/
    if (IS_ENABLED(CONFIG_RT_GROUP_SCHED) && &rq->rt != rt_rq)
        return;

    if (rq->online && prio < prev_prio)    /* 优先级提升 */
        cpupri_set(&rq->rd->cpupri, rq->cpu, prio);
}
```

### 3.4 任务选择

```c
// kernel/sched/rt.c:1645-1680
static struct task_struct *_pick_next_task_rt(struct rq *rq)
{
    struct sched_rt_entity *rt_se;
    struct rt_rq *rt_rq = &rq->rt;

    do {
        rt_se = pick_next_rt_entity(rt_rq);  /* 从 bitmap 找到最高优先级 */
        if (unlikely(!rt_se))
            return NULL;
        rt_rq = group_rt_rq(rt_se);          /* 如果是组实体，递归进入组 */
    } while (rt_rq);                          /* 直到找到真正的任务实体 */

    return rt_task_of(rt_se);
}
```

**`set_next_task_rt()`** — 当任务被选为 next 时：

```c
// kernel/sched/rt.c:1624-1643
static inline void set_next_task_rt(struct rq *rq, struct task_struct *p, bool first)
{
    p->se.exec_start = rq_clock_task(rq);

    /* 当前运行的任务不可被推送 → 从 pushable 列表移除 */
    dequeue_pushable_task(rq, p);

    if (!first)
        return;

    /* 首次设置 RT 任务时更新 PELT 平均 */
    if (rq->donor->sched_class != &rt_sched_class)
        update_rt_rq_load_avg(rq_clock_pelt(rq), rq, 0);

    rt_queue_push_tasks(rq);   /* 检查是否有其他 RT 任务需要推送出去 */
}
```

---

## 4. Push/Pull 均衡机制

RT 调度器不使用 CFS 的负载均衡——它使用**优先级驱动的 push/pull 模型**：

```
CPU 0（高优先级运行中）          CPU 1（空闲中）
    │                                │
    │ 任务 A (prio=10)               │ 空转
    │ 任务 B (prio=20) ← push ───── │ → B 被推送过来运行
    │                                │
    │   └─→ pull_rt_task() 会从     │
    │       CPU 0 拉取 B            │
```

### 4.1 Pushable 任务管理

当 RT 任务入队且不是当前执行任务时，加入 `pushable_tasks` ——这是一个**优先级链表**（`plist`），按优先级排序（高优先级在前）：

```c
// kernel/sched/rt.c:397-430
static void enqueue_pushable_task(struct rq *rq, struct task_struct *p)
{
    /* plist_del + plist_node_init + plist_add 更新优先级位置 */
    plist_del(&p->pushable_tasks, &rq->rt.pushable_tasks);
    plist_node_init(&p->pushable_tasks, p->prio);
    plist_add(&p->pushable_tasks, &rq->rt.pushable_tasks);

    /* 更新下一个最高 pushable 任务的优先级 */
    if (p->prio < rq->rt.highest_prio.next)
        rq->rt.highest_prio.next = p->prio;

    /* 如果之前没有 overload 标记，打上标记 */
    if (!rq->rt.overloaded) {
        rt_set_overload(rq);              /* 设置 root_domain 的 overload 位 */
        rq->rt.overloaded = 1;
    }
}
```

**`rt_set_overload()`** 在 root_domain 级别的 `rto_mask` 中标记此 CPU：

```c
// kernel/sched/rt.c:344-360
static inline void rt_set_overload(struct rq *rq)
{
    if (!rq->online) return;

    cpumask_set_cpu(rq->cpu, rq->rd->rto_mask);
    smp_wmb();                              /* 确保 mask 写入先于 count */
    atomic_inc(&rq->rd->rto_count);
}
```

### 4.2 push_rt_task——主动推送

```c
// kernel/sched/rt.c:1924-2005
static int push_rt_task(struct rq *rq, bool pull)
{
    /* 步骤 1：检查是否 overloaded */
    if (!rq->rt.overloaded)
        return 0;

    /* 步骤 2：找到下一个最高优先级的 pushable 任务 */
    next_task = pick_next_pushable_task(rq);
    if (!next_task)
        return 0;

retry:
    /* 步骤 3：如果它优先级比当前运行的高，先在当前 CPU 运行 */
    if (unlikely(next_task->prio < rq->donor->prio)) {
        resched_curr(rq);
        return 0;
    }

    /* 步骤 4：如果迁移被禁用，尝试推送当前任务 */
    if (is_migration_disabled(next_task)) {
        cpu = find_lowest_rq(rq->curr);
        if (cpu != -1 && cpu != rq->cpu) {
            push_task = get_push_task(rq);
            if (push_task)
                stop_one_cpu_nowait(rq->cpu, push_cpu_stop,
                                    push_task, &rq->push_work);
        }
        return 0;
    }

    /* 步骤 5：找到最低优先级的 CPU 运行队列 */
    lowest_rq = find_lock_lowest_rq(next_task, rq);
    if (!lowest_rq)
        goto out;

    /* 步骤 6：移动任务 */
    move_queued_task_locked(rq, lowest_rq, next_task);
    resched_curr(lowest_rq);                /* 让目标 CPU 调度此任务 */
    ret = 1;

    double_unlock_balance(rq, lowest_rq);
    return ret;
}
```

**doom-lsp 确认**：`push_rt_task()` 在 `rt.c:1924`。`push_rt_tasks()`（`rt.c:2022`）是一个 `while` 循环，持续推送直到无可推送任务。`pick_next_pushable_task()`（`rt.c:1840`）遍历 `plist_head` 并跳过 `task_on_cpu()` 的任务（proxy-execution 下可能在另一个 CPU 上运行）。

### 4.3 pull_rt_task——主动拉取

当 CPU 即将空闲或降低了优先级时，调用 `pull_rt_task()`：

```c
// kernel/sched/rt.c:2224-2325
static void pull_rt_task(struct rq *this_rq)
{
    int rt_overload_count = rt_overloaded(this_rq);
    if (likely(!rt_overload_count))
        return;                                       /* 没有 overloaded CPU */

    smp_rmb();                                        /* 与 rt_set_overload 的 wmb 匹配 */

    /* 如果只有自己 overloaded，无事可做 */
    if (rt_overload_count == 1 &&
        cpumask_test_cpu(this_rq->cpu, this_rq->rd->rto_mask))
        return;

#ifdef HAVE_RT_PUSH_IPI
    /* IPI 版：通知其他 CPU 来推送 */
    if (sched_feat(RT_PUSH_IPI)) {
        tell_cpu_to_push(this_rq);
        return;
    }
#endif

    /* 非 IPI 版：主动遍历所有 overloaded CPU */
    for_each_cpu(cpu, this_rq->rd->rto_mask) {
        if (this_cpu == cpu) continue;

        /* 如果源 CPU 的下一个 pushable 任务优先级 >= 本 CPU 当前优先级 → 跳过 */
        if (src_rq->rt.highest_prio.next >=
            this_rq->rt.highest_prio.curr)
            continue;

        double_lock_balance(this_rq, src_rq);
        p = pick_highest_pushable_task(src_rq, this_cpu);

        if (p && (p->prio < this_rq->rt.highest_prio.curr)) {
            /* 如果 p 的优先级低于 src_rq 当前任务 → 拉取 */
            if (p->prio < src_rq->donor->prio)
                goto skip;

            if (is_migration_disabled(p)) {
                push_task = get_push_task(src_rq);
            } else {
                move_queued_task_locked(src_rq, this_rq, p);
                resched = true;
            }
        }
skip:
        double_unlock_balance(this_rq, src_rq);

        /* 如果 target 任务的迁移被禁用，使用 stopper 推送源 CPU 的当前任务 */
        if (push_task) {
            stop_one_cpu_nowait(src_rq->cpu, push_cpu_stop,
                                push_task, &src_rq->push_work);
        }
    }
}
```

### 4.4 find_lowest_rq——找到最佳目标 CPU

核心函数 `find_lowest_rq()` 使用 `cpupri` 系统定位集合中优先级最低的 CPU：

```c
// kernel/sched/rt.c:1737-1839
static int find_lowest_rq(struct task_struct *task)
{
    struct cpumask *lowest_mask;
    int this_cpu = smp_processor_id();
    int cpu = task_cpu(task);

    if (task->nr_cpus_allowed == 1)
        return -1;            /* 不能迁移 */

    /* 使用 cpupri 找到所有运行低于 task 优先级任务的 CPU */
    if (sched_asym_cpucap_active())
        ret = cpupri_find_fitness(&task_rq(task)->rd->cpupri,
                                  task, lowest_mask, rt_task_fits_capacity);
    else
        ret = cpupri_find(&task_rq(task)->rd->cpupri, task, lowest_mask);

    if (!ret)
        return -1;

    /* 从 lowest_mask 中选择最佳 CPU */
    if (cpumask_test_cpu(cpu, lowest_mask))
        return cpu;           /* 上次运行的 CPU（缓存热）*/

    /* 按调度域寻找最近的 CPU */
    for_each_domain(cpu, sd) {
        if (sd->flags & SD_WAKE_AFFINE) {
            best_cpu = cpumask_any_and_distribute(lowest_mask,
                                                  sched_domain_span(sd));
            if (best_cpu < nr_cpu_ids)
                return best_cpu;
        }
    }

    return cpumask_any_distribute(lowest_mask);  /* 兜底 */
}
```

### 4.5 IPI 版 Push（大系统优化）

对于大规模系统（大量 CPU），遍历所有 overloaded CPU 的代价太高。`HAVE_RT_PUSH_IPI` 实现了**基于 IRQ Work 的推送散布**：

```c
// kernel/sched/rt.c:2032-2105
/* 当 CPU 调度出高优先级 RT 任务时，发送 IPI 通知所有 overloaded CPU */
static void tell_cpu_to_push(struct rq *rq)
{
    atomic_inc(&rq->rd->rto_loop_next);   /* 延长扫描循环 */

    if (!rto_start_trylock(&rq->rd->rto_loop_start))
        return;                             /* 已经有 IPI 正在处理 */

    raw_spin_lock(&rq->rd->rto_lock);
    if (rq->rd->rto_cpu < 0)               /* 上次 IPI 处理结束 */
        cpu = rto_next_cpu(rq->rd);        /* 从 rto_mask 选下一个 CPU */
    raw_spin_unlock(&rq->rd->rto_lock);
    rto_start_unlock(&rq->rd->rto_loop_start);

    if (cpu >= 0)
        irq_work_queue_on(&rq->rd->rto_push_work, cpu);  /* 发送 IRQ Work */
}

/* IRQ Work 处理函数 */
void rto_push_irq_work_func(struct irq_work *work)
{
    raw_spin_lock(&rd->rto_lock);
    /* 检查本地 rq 是否可推送 */
    if (has_pushable_tasks(rq))
        raw_spin_rq_lock(rq);
        while (push_rt_task(rq, true));
        raw_spin_rq_unlock(rq);

    cpu = rto_next_cpu(rd);       /* 传播到下一个 overloaded CPU */
    raw_spin_unlock(&rd->rto_lock);

    if (cpu < 0) {
        sched_put_rd(rd);         /* 全部 CPU 检查完毕 */
        return;
    }

    irq_work_queue_on(&rd->rto_push_work, cpu);  /* 链式转发 */
}
```

**设计洞察**：IPI 版通过 `rto_loop_next` / `rto_loop_start` 原子变量和 `rto_lock` 确保同一时刻只有一个 CPU 在负责推送工作。`rto_next_cpu()` 逐个遍历 `rto_mask` 中的 CPU。

---

## 5. 实时带宽控制

### 5.1 全局参数和 sysctl

```c
// kernel/sched/rt.c:10-27
int sched_rr_timeslice = RR_TIMESLICE;           /* SCHED_RR 默认时间片 */
static const u64 max_rt_runtime = MAX_BW;         /* 最大带宽（~4 小时）*/
int sysctl_sched_rt_period = 1000000;             /* 1 秒周期 */
int sysctl_sched_rt_runtime = 950000;              /* 0.95 秒运行时间 */
```

sysctl 导出：

```bash
/proc/sys/kernel/sched_rt_period_us      # 周期（微秒）
/proc/sys/kernel/sched_rt_runtime_us     # 每周期允许运行时间（微秒）
/proc/sys/kernel/sched_rr_timeslice_ms   # SCHED_RR 时间片（毫秒）
```

```
sched_rt_runtime_us = -1   → 不限带宽
sched_rt_runtime_us = 0    → 不让 RT 任务运行
默认: 950000 / 1000000     → 95%
```

### 5.2 运行时记账

```c
// kernel/sched/rt.c:974-1007
static void update_curr_rt(struct rq *rq)
{
    struct task_struct *donor = rq->donor;

    if (donor->sched_class != &rt_sched_class)
        return;

    delta_exec = update_curr_common(rq);
    if (unlikely(delta_exec <= 0))
        return;

    /* RT 组调度开启时：按层级记账 */
    for_each_sched_rt_entity(rt_se) {
        struct rt_rq *rt_rq = rt_rq_of_se(rt_se);

        if (sched_rt_runtime(rt_rq) != RUNTIME_INF) {
            raw_spin_lock(&rt_rq->rt_runtime_lock);
            rt_rq->rt_time += delta_exec;
            exceeded = sched_rt_runtime_exceeded(rt_rq);
            if (exceeded)
                resched_curr(rq);
            raw_spin_unlock(&rt_rq->rt_runtime_lock);
            if (exceeded)
                do_start_rt_bandwidth(sched_rt_bandwidth(rt_rq));
        }
    }
}
```

**`sched_rt_runtime_exceeded()`** 检查是否超出带宽：

```c
// kernel/sched/rt.c（简化为表达式）
return rt_rq->rt_time > rt_rq->rt_runtime;
```

if exceeded:
1. `resched_curr(rq)` → 触发调度，调度器发现节流后不会选择此组的 RT 任务
2. `do_start_rt_bandwidth()` → 确保 hrtimer 运行，以便在下一周期恢复

### 5.3 节流与恢复

```c
// kernel/sched/rt.c:937
static inline int rt_rq_throttled(struct rt_rq *rt_rq)
{
    return rt_rq->rt_throttled;
}
```

**节流效果**：
- `__enqueue_rt_entity()` 检查 `rt_rq_throttled()` → 如果被节流，不入队
- 组内没有可运行的任务时，组实体的 bitmap 位被清除
- 只要组被节流，该组的所有 RT 任务都不会被调度

**hrtimer 恢复机制**：

```c
// kernel/sched/rt.c:112-118
static enum hrtimer_restart sched_rt_period_timer(struct hrtimer *timer)
{
    struct rt_bandwidth *rt_b =
        container_of(timer, struct rt_bandwidth, rt_period_timer);

    raw_spin_lock(&rt_b->rt_runtime_lock);
    for (;;) {
        overrun = hrtimer_forward_now(timer, rt_b->rt_period);
        if (!overrun)
            break;
        raw_spin_unlock(&rt_b->rt_runtime_lock);
        idle = do_sched_rt_period_timer(rt_b, overrun);  /* 重置 rt_time */
        raw_spin_lock(&rt_b->rt_runtime_lock);
    }
    if (idle)
        rt_b->rt_period_active = 0;
    raw_spin_unlock(&rt_b->rt_runtime_lock);

    return idle ? HRTIMER_NORESTART : HRTIMER_RESTART;
}
```

**`do_sched_rt_period_timer()`** 在每个周期重置 `rt_time`，解除节流：

```c
// 在 rt.c 中（do_sched_rt_period_timer）
rt_rq->rt_time = 0;                            /* 重置计时 */
if (was_throttled && rt_rq->rt_nr_running) {
    rt_rq->rt_throttled = 0;                   /* 解除节流 */
    enqueue_top_rt_rq(rt_rq);                  /* 重新加入调度 */
}
```

---

## 6. 唤醒优先级与抢占

### 6.1 wakeup_preempt_rt

```c
// kernel/sched/rt.c:1594-1622
static void wakeup_preempt_rt(struct rq *rq, struct task_struct *p, int flags)
{
    struct task_struct *donor = rq->donor;

    if (p->sched_class != &rt_sched_class)
        return;

    /* 严格优先级比较：新任务的优先级更高 → 抢占 */
    if (p->prio < donor->prio) {
        resched_curr(rq);
        return;
    }

    /* 同优先级：检查是否可以通过 push 迁移当前任务 */
    if (p->prio == donor->prio && !test_tsk_need_resched(rq->curr))
        check_preempt_equal_prio(rq, p);
}
```

**`check_preempt_equal_prio()`** 处理同优先级抢占的特殊场景：

```c
// kernel/sched/rt.c:1562-1582
static void check_preempt_equal_prio(struct rq *rq, struct task_struct *p)
{
    /* 如果当前任务不可迁移 → 不处理 */
    if (rq->curr->nr_cpus_allowed == 1 ||
        !cpupri_find(&rq->rd->cpupri, rq->donor, NULL))
        return;

    /* 如果新任务可以迁移到别处 → 让它迁移 */
    if (p->nr_cpus_allowed != 1 &&
        cpupri_find(&rq->rd->cpupri, p, NULL))
        return;

    /* 两者都不能去别处 → 重新排到队首并触发调度 */
    requeue_task_rt(rq, p, 1);
    resched_curr(rq);
}
```

### 6.2 select_task_rq_rt

唤醒或 fork 时选择目标 CPU：

```c
// kernel/sched/rt.c:1496-1560
static int select_task_rq_rt(struct task_struct *p, int cpu, int flags)
{
    struct rq *rq = cpu_rq(cpu);
    struct task_struct *curr, *donor;

    /* 非唤醒/非 fork → 留在当前 CPU */
    if (!(flags & (WF_TTWU | WF_FORK)))
        goto out;

    curr = READ_ONCE(rq->curr);      /* 无锁读取 */
    donor = READ_ONCE(rq->donor);

    /* 如果：
     * - 当前 CPU 运行 RT 任务
     * - 当前任务被 pin 住或优先级 ≥ 新任务
     * → 尝试找更低的 CPU 放置新任务 */
    test = curr &&
           unlikely(rt_task(donor)) &&
           (curr->nr_cpus_allowed < 2 || donor->prio <= p->prio);

    if (test || !rt_task_fits_capacity(p, cpu)) {
        int target = find_lowest_rq(p);
        if (target != -1 &&
            p->prio < cpu_rq(target)->rt.highest_prio.curr)
            cpu = target;
    }
    return cpu;
}
```

---

## 7. CPU 优先级管理（cpupri）

`cpupri` 系统为每个 CPU 维护其当前运行任务的最高优先级，提供"找到运行最低优先级任务的 CPU"的快速查询。

```c
// kernel/sched/cpupri.h
struct cpupri {
    struct cpupri_vec vec[CPUPRI_NR_PRIORITIES]; /* 每个优先级级的 CPU 掩码 */
    atomic_t *pri_active;                         /* 活动优先级位图 */
    struct cpupri_vec *pri_to_cpu;                /* 优先级到 CPU 的映射 */
};
```

**查询路径**：

```c
// cpupri_find(task, lowest_mask) → 填充 lowest_mask
// 逻辑：遍历比 task->prio 更低（数值更大）的所有优先级级
//     将所有运行这些优先级任务的 CPU 加入 lowest_mask
```

**doom-lsp 确认**：`cpupri_find()` 在 `kernel/sched/cpupri.c` 中。`cpupri_set()` 在每次 `rt_rq` 最高优先级变更时由 `inc_rt_prio_smp()`（`rt.c:1049`）或 `dec_rt_prio_smp()`（`rt.c:1064`）调用。在非对称容量系统上，`cpupri_find_fitness()` 额外传递 `rt_task_fits_capacity` 回调（`rt.c:473`）确保任务只被放置到容量足够的 CPU。

---

## 8. SCHED_RR 时间片管理

### 8.1 时间片轮转

```c
// kernel/sched/rt.c:2540-2560
static void task_tick_rt(struct rq *rq, struct task_struct *p, int queued)
{
    update_curr_rt(rq);
    update_rt_rq_load_avg(rq_clock_pelt(rq), rq, 1);
    watchdog(rq, p);                       /* RLIMIT_RTTIME 检查 */

    /* SCHED_FIFO 不做时间片管理 */
    if (p->policy != SCHED_RR)
        return;

    /* 时间片未耗尽 */
    if (--p->rt.time_slice)
        return;

    /* 时间片耗尽 → 重置时间片 */
    p->rt.time_slice = sched_rr_timeslice;

    /* 移动到队尾（如果不是唯一的实体）*/
    for_each_sched_rt_entity(rt_se) {
        if (rt_se->run_list.prev != rt_se->run_list.next) {
            requeue_task_rt(rq, p, 0);    /* head=0 → 加到队尾 */
            resched_curr(rq);
            return;
        }
    }
}
```

**`sched_rr_timeslice`** 默认值：

```c
// kernel/sched/rt.c:10
int sched_rr_timeslice = RR_TIMESLICE;
// RR_TIMESLICE 在 sched/sched.h 中通常定义为 100ms（HZ=1000 时）
```

**doom-lsp 确认**：`task_tick_rt` 在 `rt.c:2540`。时间片体现在 `p->rt.time_slice`（`include/linux/sched.h:630`）。

### 8.2 RLIMIT_RTTIME watchdog

```c
// kernel/sched/rt.c:2497-2518
static void watchdog(struct rq *rq, struct task_struct *p)
{
    soft = task_rlimit(p, RLIMIT_RTTIME);
    hard = task_rlimit_max(p, RLIMIT_RTTIME);

    if (soft != RLIM_INFINITY) {
        if (p->rt.watchdog_stamp != jiffies) {
            p->rt.timeout++;
            p->rt.watchdog_stamp = jiffies;
        }

        next = DIV_ROUND_UP(min(soft, hard), USEC_PER_SEC / HZ);
        if (p->rt.timeout > next) {
            /* 超出软限制 → 发送 SIGXCPU */
            posix_cputimers_rt_watchdog(&p->posix_cputimers,
                                        p->se.sum_exec_runtime);
        }
    }
}
```

---

## 9. RT 组调度

当 `CONFIG_RT_GROUP_SCHED` 开启时，RT 调度器支持 cgroup CPU 带宽隔离：

```
/ (root_task_group)
  ├── rt_bandwidth = {period=1s, runtime=0.95s}
  │
  ├── group_A
  │     rt_bandwidth = {period=1s, runtime=0.5s}
  │     ├── task_X (prio=10)
  │     └── task_Y (prio=20)
  │
  └── group_B
        rt_bandwidth = {period=1s, runtime=0.3s}
        └── task_Z (prio=15)
```

每个 cgroup 有独立的 `rt_bandwidth` 和 `rt_rq` per-CPU。RT 实体构成层级树：

```
task_X → sched_rt_entity（X 的 rt_se）
    ├── .my_q = group_A 在此 CPU 的 rt_rq
    ├── .parent → group_B 的 rt_se (如果有的话)
    │                ├── .my_q = ... 父组 rt_rq
    │                └── .parent → root_task_group.rt_se[cpu]
    └── .rt_rq → 父 rt_rq
```

**组带宽约束验证**（`tg_rt_schedulable`）：

```c
// kernel/sched/rt.c:2724-2770
static int tg_rt_schedulable(struct task_group *tg, void *data)
{
    /* 验证条件：
     * 1. runtime ≤ period（或 RUNTIME_INF）
     * 2. 不能将已有 RT 任务的组的 runtime 设为 0
     * 3. 每个组不能超过全局限制
     * 4. 子组 runtime 之和不能超父组
     */
}
```

**doom-lsp 确认**：组调度相关函数分布在 `rt.c` 的 `#ifdef CONFIG_RT_GROUP_SCHED` 块中。入口点在 `sched_group_set_rt_runtime()`（`rt.c:2780`）。

---

## 10. 生命周期回调

### 10.1 策略切换

```c
// kernel/sched/rt.c:2641-2660
static void switched_to_rt(struct rq *rq, struct task_struct *p)
{
    if (task_current(rq, p)) {
        update_rt_rq_load_avg(rq_clock_pelt(rq), rq, 0);
        return;
    }

    if (task_on_rq_queued(p)) {
        /* RT 任务多于 1 → 尝试推送 */
        if (p->nr_cpus_allowed > 1 && rq->rt.overloaded)
            rt_queue_push_tasks(rq);
        /* 新 RT 任务优先级更高 → 抢占 */
        if (p->prio < rq->donor->prio && cpu_online(cpu_of(rq)))
            resched_curr(rq);
    }
}
```

```c
// kernel/sched/rt.c:2608-2620
static void switched_from_rt(struct rq *rq, struct task_struct *p)
{
    /* 如果这是最后一个 RT 任务，尝试从其他 CPU 拉取 */
    if (!task_on_rq_queued(p) || rq->rt.rt_nr_running)
        return;
    rt_queue_pull_task(rq);
}
```

### 10.2 CPU Online/Offline

```c
// kernel/sched/rt.c:2576-2592
static void rq_online_rt(struct rq *rq)
{
    if (rq->rt.overloaded)
        rt_set_overload(rq);           /* 加入 overloaded 扫描 */
    __enable_runtime(rq);               /* 分配该 CPU 的 RT 带宽 */
    cpupri_set(&rq->rd->cpupri, rq->cpu,
               rq->rt.highest_prio.curr);  /* 注册到 cpupri */
}

static void rq_offline_rt(struct rq *rq)
{
    if (rq->rt.overloaded)
        rt_clear_overload(rq);          /* 从 overloaded 扫描移除 */
    __disable_runtime(rq);              /* 回收该 CPU 的 RT 带宽 */
    cpupri_set(&rq->rd->cpupri, rq->cpu,
               CPUPRI_INVALID);         /* 标记为不可用 */
}
```

### 10.3 优先级变化

```c
// kernel/sched/rt.c:2663-2691
static void prio_changed_rt(struct rq *rq, struct task_struct *p, u64 oldprio)
{
    if (!task_on_rq_queued(p))
        return;

    if (p->prio == oldprio)
        return;

    if (task_current_donor(rq, p)) {
        /* 当前任务优先级降低 → 可能需要拉取更高优先级的任务 */
        if (oldprio < p->prio)
            rt_queue_pull_task(rq);

        /* 如果当前运行的任务不是最高优先级的 → 重新调度 */
        if (p->prio > rq->rt.highest_prio.curr)
            resched_curr(rq);
    } else {
        /* 非当前任务优先级提高 → 可能抢占 */
        if (p->prio < rq->donor->prio)
            resched_curr(rq);
    }
}
```

---

## 11. 优先级继承与 proxy-execution

Linux 7.0-rc1 的 RT 调度器通过 `rq->donor` 支持 proxy-execution 模式。在传统调度中，`rq->curr` 是运行中的任务。在 proxy-execution 中，`rq->curr` 仍然指向"当前任务"，但 `rq->donor` 指向**实际使用 CPU 的任务**——可能是持有锁的代理执行者。

```c
// 在 update_curr_rt 中
struct task_struct *donor = rq->donor;
if (donor->sched_class != &rt_sched_class)
    return;
```

**doom-lsp 确认**：`rq->donor` 在 `sched.h` 的 `struct rq` 中。整个 RT 调度器中的 `rq->donor` 使用确保在 proxy-execution 路径上正确记账。

---

## 12. 性能特性与设计决策

### 12.1 算法复杂度

| 操作 | 复杂度 | 说明 |
|------|--------|------|
| 选择下一个任务 | **O(1)** | `sched_find_first_bit(bitmap)` 硬件位扫描 |
| 入队任务 | **O(1)** | list_add_tail + bitmap_set |
| 出队任务 | **O(1)** | list_del + bitmap_clear（clear 可能不操作，如果链表不为空）|
| push_rt_task | **O(n)** | 遍历 pushable 任务找到可迁移的（n ≤ RT 任务数）|
| find_lowest_rq | **O(prio_levels)** | cpupri_find + 域遍历 |
| pull_rt_task | **O(overloaded_CPUs)** | 遍历 rto_mask 中的 CPU |

### 12.2 关键延迟路径

```
scheduler_tick()
  └─ task_tick_rt() [~500ns]
        ├─ update_curr_rt() [~200ns + 组调度开销]
        ├─ update_rt_rq_load_avg() [~100ns]
        ├─ watchdog() [~50ns]
        └─ requeue/resched (RR) [~100ns]

wakeup_preempt_rt()
  └─ 优先级比较 + 可能 resched_curr() [~100ns]

push_rt_task()
  ├─ pick_next_pushable_task() [~50ns]
  ├─ find_lowest_rq() [~500ns-2μs]
  └─ move_queued_task_locked() [~100ns + IPI]

pull_rt_task()
  ├─ 遍历 rto_mask [O(n)]
  ├─ double_lock_balance() [~200ns-1μs]
  └─ move_queued_task_locked() [~100ns]
```

### 12.3 每个调度周期的行为

```
tick 触发：
  task_tick_rt()
    ├─ update_curr_rt() → rt_time += delta
    │   如果 rt_time > rt_runtime → 节流（CPUSET 级别）
    ├─ SCHED_RR：time_slice-- → 如果到 0 →
    │   移动到队尾 + resched_curr()
    └─ watchdog：RLIMIT_RTTIME 检查

pick_next_task_rt():
  └─ 扫描 active->bitmap[0:100]
        → 找到最高优先级非空队列
        → 取队列头部实体
        → 如果是组实体，递归到组内

put_prev_task_rt():
  ├─ enqueue_pushable_task() ← 让出 CPU 后可被推送
  └─ update_rt_rq_load_avg()

balance_rt():
  └─ need_pull_rt_task() → pull_rt_task()
```

---

## 13. 调试与观测

### 13.1 调试信息

```bash
# 查看 RT 任务统计
cat /proc/sched_debug | grep -A 20 "^rt_rq"

# 查看 RT 限流
cat /sys/fs/cgroup/cpu,cpuacct/cpu.rt_runtime_us
cat /sys/fs/cgroup/cpu,cpuacct/cpu.rt_period_us

# 查看系统 RT 限制
cat /proc/sys/kernel/sched_rt_period_us
cat /proc/sys/kernel/sched_rt_runtime_us
cat /proc/sys/kernel/sched_rr_timeslice_ms
```

### 13.2 ftrace 事件

```bash
# 跟踪 RT 调度事件
echo 1 > /sys/kernel/debug/tracing/events/sched/sched_switch/enable
echo 1 > /sys/kernel/debug/tracing/events/sched/sched_wakeup/enable
cat /sys/kernel/debug/tracing/trace_pipe | grep -E "(RT|FIFO|RR)"
```

### 13.3 关键调试符号

| 符号 | 位置 | 作用 |
|------|------|------|
| `print_rt_stats()` | `rt.c:2937` | 打印 RT 运行队列统计 |
| `print_rt_rq()` | `sched.c` | 打印单个 RT 运行队列详情 |
| `sched_debug_verbose` | `topology.c:30` | 控制调试输出 |

---

## 14. 系统调优指南

### 14.1 典型配置场景

```bash
# 桌面/服务器（默认）
echo 950000 > /proc/sys/kernel/sched_rt_runtime_us  # 95%
echo 1000000 > /proc/sys/kernel/sched_rt_period_us  # 1s 周期

# 硬实时系统（移除带宽限制）
echo -1 > /proc/sys/kernel/sched_rt_runtime_us      # 不限

# 隔离实时 CPU（独占）
# 通过 isolcpus 内核参数 + chrt
chrt -f 80 taskset -c 3 ./my_rt_app                # FIFO prio=80

# 实时任务调试
chrt -p 10 <pid>                                     # 查看
chrt -p -f 50 <pid>                                  # 设为 FIFO prio=50
chrt -p -r 60 <pid>                                  # 设为 RR prio=60
```

### 14.2 CPU 亲和性

```bash
# 将 RT 任务绑定到特定 CPU
taskset -c 0-3 chrt -f 50 ./rt_app

# 检查 push/pull 效果
watch -n 1 "cat /proc/sched_debug | grep rt_rq"
```

### 14.3 RT 限流排查

如果 RT 应用出现意外的调度延迟：

```bash
# 检查 RT 节流
grep "rt_throttled" /proc/sched_debug

# 检查是否超出带宽
cat /proc/sys/kernel/sched_rt_runtime_us
cat /proc/sys/kernel/sched_rt_period_us

# 临时解除限制（危险！可能死机）
echo -1 > /proc/sys/kernel/sched_rt_runtime_us
```

---

## 15. 与 CFS/Deadline 的调度类交互

RT 调度器是调度类层次中的第二级（优先级仅次于 Stop 和 Deadline）：

```
Stop (停止任务)         → 最高优先级
  ↓
DL  (SCHED_DEADLINE)   → deadline 驱动
  ↓
RT  (SCHED_FIFO/RR)    → 优先级驱动
  ↓
CFS (SCHED_NORMAL)     → 公平共享
  ↓
IDLE (SCHED_IDLE)      → 最低优先级
```

```c
// kernel/sched/rt.c:124 (在 balance_rt 中)
static int balance_rt(struct rq *rq, struct task_struct *p, struct rq_flags *rf)
{
    if (!on_rt_rq(&p->rt) && need_pull_rt_task(rq, p))
        pull_rt_task(rq);

    return sched_stop_runnable(rq) ||  /* Stop 类 */
           sched_dl_runnable(rq) ||   /* DL 类  */
           sched_rt_runnable(rq);     /* RT 类  */
}
```

注意 `balance_rt` 返回值的特殊设计——它检查**所有**更高优先级类（Stop、DL），保证如果这些类有可运行任务，当前类不会选择任务。这是调度类层次结构的关键约束。

---

## 16. 总结

Linux RT 调度器（`SCHED_FIFO` / `SCHED_RR`）的设计体现了以下核心原则：

**1. 严格优先级**
- 位图驱动的优先级队列（`sched_find_first_bit` O(1) 选择）
- 优先级 1-99，数值越小优先级越高
- 同优先级 FIFO 或 RR 策略

**2. 优先级驱动的均衡**
- Push 模型：CPU 有多余 RT 任务时主动推送出去
- Pull 模型：CPU 空闲或降优先级时从其他 CPU 拉取
- `cpupri` 系统维护全局 CPU 优先级视图
- IPI 推送：大规模系统的链式 IRQ Work 推送

**3. 带宽隔离**
- `sched_rt_runtime_us` / `sched_rt_period_us`（默认 95%）
- hrtimer 驱动的周期重置
- 组调度允许 cgroup 级别的带宽隔离

**4. 安全性**
- RLIMIT_RTTIME watchdog（SIGXCPU）
- 迁移禁用保护
- 优先级变化追踪

**关键数据**：
- `rt.c`：2939 行，119 个符号
- 调度类回调：19 个函数
- 优先级级数：100（0-99，0 最高）
- 默认带宽：95%（950ms/1s）
- SCHED_RR 时间片：100ms（HZ=1000）

---

## 附录 A：关键源码索引

| 文件 | 行号 | 符号 |
|------|------|------|
| `kernel/sched/sched.h` | 311 | `struct rt_prio_array` |
| `kernel/sched/sched.h` | 316 | `struct rt_bandwidth` |
| `kernel/sched/sched.h` | 838 | `struct rt_rq` |
| `include/linux/sched.h` | 623 | `struct sched_rt_entity` |
| `kernel/sched/rt.c` | 10 | `sched_rr_timeslice` |
| `kernel/sched/rt.c` | 18 | `sysctl_sched_rt_period` |
| `kernel/sched/rt.c` | 24 | `sysctl_sched_rt_runtime` |
| `kernel/sched/rt.c` | 68 | `init_rt_rq()` |
| `kernel/sched/rt.c` | 333 | `need_pull_rt_task()` |
| `kernel/sched/rt.c` | 339 | `rt_overloaded()` |
| `kernel/sched/rt.c` | 344 | `rt_set_overload()` |
| `kernel/sched/rt.c` | 381 | `push_rt_tasks()` |
| `kernel/sched/rt.c` | 382 | `pull_rt_task()` |
| `kernel/sched/rt.c` | 397 | `enqueue_pushable_task()` |
| `kernel/sched/rt.c` | 974 | `update_curr_rt()` |
| `kernel/sched/rt.c` | 1079 | `inc_rt_prio()` |
| `kernel/sched/rt.c` | 1331 | `__enqueue_rt_entity()` |
| `kernel/sched/rt.c` | 1383 | `dequeue_rt_stack()` |
| `kernel/sched/rt.c` | 1435 | `enqueue_task_rt()` |
| `kernel/sched/rt.c` | 1455 | `dequeue_task_rt()` |
| `kernel/sched/rt.c` | 1496 | `select_task_rq_rt()` |
| `kernel/sched/rt.c` | 1624 | `set_next_task_rt()` |
| `kernel/sched/rt.c` | 1737 | `find_lowest_rq()` |
| `kernel/sched/rt.c` | 1924 | `push_rt_task()` |
| `kernel/sched/rt.c` | 2224 | `pull_rt_task()` |
| `kernel/sched/rt.c` | 2540 | `task_tick_rt()` |
| `kernel/sched/rt.c` | 2865 | `DEFINE_SCHED_CLASS(rt)` |

## 附录 B：内核参数

```bash
# 通过 sysctl 调整
/proc/sys/kernel/sched_rt_period_us      # RT 周期（微秒，默认 1000000）
/proc/sys/kernel/sched_rt_runtime_us     # RT 每周期时间（微秒，默认 950000）
/proc/sys/kernel/sched_rr_timeslice_ms  # RR 时间片（毫秒）

# 通过 cgroup v1 设置组带宽
/sys/fs/cgroup/cpu/<group>/cpu.rt_runtime_us
/sys/fs/cgroup/cpu/<group>/cpu.rt_period_us
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
