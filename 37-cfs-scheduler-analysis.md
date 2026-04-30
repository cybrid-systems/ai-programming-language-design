# CFS — 完全公平调度器深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/sched/fair.c` + `kernel/sched/sched.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**CFS（Completely Fair Scheduler）** 是 Linux 2.6.23+ 的默认调度器，核心思想：
- **虚拟运行时间（vruntime）**：每个任务按"应得 CPU 时间"运行
- **红黑树**：vruntime 最小的任务在树最左端，最先被调度
- **权重**：nice 值决定权重，权重越高 vruntime 增长越慢

---

## 1. 核心数据结构

### 1.1 sched_entity — 调度实体

```c
// kernel/sched/sched.h:460 — sched_entity
struct sched_entity {
    // 嵌入的红黑树节点（接入 cfs_rq 的树）
    struct rb_node          run_node;         // 行 472

    // 时间记账
    u64                     exec_start;       // 本次执行开始时间
    u64                     sum_exec_runtime; // 总执行时间
    u64                     vruntime;         // 虚拟运行时间（CFS 键！）
    u64                     prev_sum_exec_runtime; // 上次总执行时间
    u64                     nr_migrations;     // 迁移次数

    // 在运行队列中的信息
    struct list_head        group_node;       // 接入组调度的链表
    unsigned int            on_rq;            // 是否在运行队列

    // 父子关系
    struct sched_entity     *parent;          // 父调度实体（CFS 层）

    // 权重（来自 nice 值）
    unsigned long           weight;            // 权重（1024 * 1.25^nice）
    unsigned long           load_weight;       // 负载权重
};
```

### 1.2 cfs_rq — CFS 运行队列

```c
// kernel/sched/sched.h:440 — cfs_rq
struct cfs_rq {
    // 红黑树根（所有可运行任务按 vruntime 排序）
    struct rb_root_cached   tasks_timeline;  // 行 445

    /* 树中最左节点 = 最需要调度的任务 */
    struct rb_node          *rb_leftmost;     // 缓存最左节点（O(1) 查找）

    // 运行时统计
    u64                     exec_clock;       // 执行时钟
    u64                     min_vruntime;      // 基准 vruntime（防止饿死）

    // 任务链表
    struct sched_entity     *curr;            // 当前正在运行的任务
    struct task_struct      *tg;              // 任务组

    // 负载信息
    struct load_weight      load;             // 总负载
    unsigned long           nr_running;        // 可运行任务数
    unsigned long           h_nr_running;     // 层次运行任务数

    // 无延迟的 idle
    struct sched_entity     *min_vruntime_fair; // 最小 vruntime
};
```

### 1.3 权重计算

```c
// kernel/sched/core.c — se_weight
static unsigned long se_weight(struct sched_entity *se)
{
    // nice 值权重：weight = 1024 * 1.25^(nice - 1024)
    // nice = 0  → weight = 1024
    // nice = -20 → weight = 88761 (最高优先级)
    // nice = +20 → weight = 78 (最低优先级)
    return scale_load(se->load.weight);
}
```

---

## 2. pick_next_entity — 选择下一个任务

```c
// kernel/sched/fair.c:4720 — pick_next_entity
struct sched_entity *pick_next_entity(struct cfs_rq *cfs_rq)
{
    struct sched_entity *se = NULL;

    // 取树中最左节点（vruntime 最小）
    se = rb_entry(rb_leftmost(&cfs_rq->tasks_timeline), struct sched_entity, run_node);

    return se;
}
```

---

## 3. enqueue_entity — 加入运行队列

```c
// kernel/sched/fair.c:4683 — enqueue_entity
void enqueue_entity(struct cfs_rq *cfs_rq, struct sched_entity *se, int flags)
{
    // 1. 更新执行时间
    update_curr(cfs_rq);

    // 2. 如果已在运行（flags=ENQUEUE_WAKEUP），更新 vruntime
    if (flags & ENQUEUE_WAKEUP)
        place_entity(cfs_rq, se, flags);

    // 3. 更新运行队列统计
    account_enqueue_entity(cfs_rq, se);

    // 4. 加入红黑树（key = vruntime）
    __enqueue_entity(cfs_rq, se);
}

static void __enqueue_entity(struct cfs_rq *cfs_rq, struct sched_entity *se)
{
    // 插入红黑树
    rb_link_node(&se->run_node, parent, link);
    rb_insert_color_cached(&se->run_node, &cfs_rq->tasks_timeline, leftmost);

    // 如果是最左节点，更新缓存
    if (leftmost)
        cfs_rq->rb_leftmost = &se->run_node;
}
```

---

## 4. vruntime 计算

```c
// kernel/sched/fair.c:764 — update_curr
void update_curr(struct cfs_rq *cfs_rq)
{
    u64 now = rq_clock_task(rq_of(cfs_rq));
    u64 delta_exec = now - se->exec_start;

    // 更新 vruntime
    // delta_exec * 1024 / weight（高权重 = vruntime 增长慢）
    se->vruntime += calc_delta_fair(delta_exec, se);

    // 更新 min_vruntime（防止所有任务 vruntime 无限增长）
    cfs_rq->min_vruntime = max(cfs_rq->min_vruntime, se->vruntime);
}

static inline u64 calc_delta_fair(u64 delta_exec, struct sched_entity *se)
{
    // 公平调度：vruntime 增长速率与权重成反比
    // 高权重任务 → vruntime 增长慢 → 被调度更多
    // 低权重任务 → vruntime 增长快 → 被调度更少
    return mul_div64(delta_exec, NICE_0_LOAD, se->load.weight);
}
```

---

## 5. entity_key — 红黑树 key

```c
// kernel/sched/fair.c:726 — entity_key
static inline s64 entity_key(struct cfs_rq *cfs_rq, struct sched_entity *se)
{
    // vruntime 作为 key，最小的在树最左
    return se->vruntime - cfs_rq->min_vruntime;
}
```

---

## 6. 调度周期（sched_slice）

```c
// kernel/sched/fair.c:460 — sched_slice
static u64 sched_slice(struct cfs_rq *cfs_rq, struct sched_entity *se)
{
    // 每个任务在其调度周期内应得的时间
    // slice = period * (weight / total_weight)
    // period 默认 4ms
    u64 period = sysctl_sched_latency;  // 4ms
    u64 slice = period * se->load.weight;

    do_div(slice, cfs_rq->load.weight);

    return slice;
}
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/sched/sched.h` | `struct sched_entity`（行460）、`struct cfs_rq`（行440）|
| `kernel/sched/fair.c` | `pick_next_entity`（行4720）、`enqueue_entity`（行4683）、`update_curr`（行764）|
| `kernel/sched/core.c` | `se_weight` 权重计算 |