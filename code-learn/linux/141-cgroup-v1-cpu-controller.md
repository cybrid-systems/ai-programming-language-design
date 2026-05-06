# 094-cgroup-v1-cpu — Linux cgroup v1 CPU 控制器深度源码分析：cpu.shares / cpu.cfs_quota_us / cpuacct

> 基于 Linux 7.0-rc1 主线源码  
> 全程使用 doom-lsp（clangd LSP）定位函数与符号  
> 分析日期：2026-05-06

---

## 0. 概述

cgroup v1 的 CPU 控制器由 **`CONFIG_FAIR_GROUP_SCHED`** 编译开关控制，是实际生产中使用最频繁的控制器之一。OceanBase 等数据库依赖它来实现 CPU 资源的软权重分配、硬限额限制以及使用量监控。

CPU 控制器的内核架构可拆为 **三层数据结构**：

```
struct task_group (调度组)
  ├── struct sched_entity **se          (per-CPU 调度实体)
  └── struct cfs_rq **cfs_rq            (per-CPU CFS 运行队列)
        └── sched_entity->load.weight → CFS 时间片分配依据
```

OceanBase 调用的三个 cgroup 接口分别对应 kernel 里的三条独立路径：

| 接口文件 | 内核路径 | 效果 |
|----------|----------|------|
| `cpu.shares` | CFS 权重分配 | 相对比例，不做硬限流 |
| `cpu.cfs_quota_us` | 带宽控制（throttle） | 硬限额，超额直接冻结 |
| `cpuacct.usage` / `cpuacct.stat` | CPU 记账 | 纯统计，树形汇总 |

---

## 1. 核心数据结构

### 1.1 struct task_group — 调度组

`struct task_group` 是 CPU 控制器的 per-cgroup 核心结构，定义在 `kernel/sched/sched.h:474`：

```c
// kernel/sched/sched.h:474 — doom-lsp 确认
struct task_group {
    struct cgroup_subsys_state css;          // cgroup 控制器状态（父类）
    struct sched_entity      **se;           // per-CPU 调度实体（指向每个 CPU 的 se）
    struct cfs_rq            **cfs_rq;       // per-CPU CFS 运行队列
    unsigned long            shares;         // cpu.shares 写入的值
    atomic_long_t            load_avg;       // 所有 CPU 的总负载（cacheline 对齐）

    struct task_group *parent;
    struct list_head  siblings;
    struct list_head  children;              // 子 task_group 链表

    struct cfs_bandwidth cfs_bandwidth;      // 带宽控制（cpu.cfs_quota_us）

#ifdef CONFIG_UCLAMP_TASK_GROUP
    unsigned int uclamp_pct[UCLAMP_CNT];
    struct uclamp_se uclamp_req[UCLAMP_CNT];
    struct uclamp_se uclamp[UCLAMP_CNT];
#endif
};
```

**关键字段：**

- **`css`**：cgroup 子系统的通用状态，通过 `container_of(css, struct task_group, css)` 互换
- **`se[]` / `cfs_rq[]`**：per-CPU 数组。`se[cpu]` 是该组在 CPU `cpu` 上的调度实体；`cfs_rq[cpu]` 是运行队列
- **`shares`**：用户通过 `cpu.shares` 设置的权重值（默认 1024）
- **`load_avg`**：所有 CPU 上 `sched_entity` 的 PELT 负载总和，用于 `calc_group_shares()` 比例计算
- **`cfs_bandwidth`**：带宽控制子结构

### 1.2 struct cfs_bandwidth — 带宽控制

```c
// kernel/sched/sched.h:447 — doom-lsp 确认
struct cfs_bandwidth {
    raw_spinlock_t   lock;
    ktime_t          period;                  // cpu.cfs_period_us（默认 100ms）
    u64              quota;                   // cpu.cfs_quota_us
    u64              runtime;                 // 当前周期剩余的可用总时间
    u64              burst;                   // cpu.cfs_burst_us（v1 也支持了）
    u64              runtime_snap;            // 上次 snapshot，用于 burst 统计

    u8               idle;
    u8               period_active;           // period_timer 是否已启动
    u8               slack_started;

    struct hrtimer   period_timer;            // 周期定时器（到期补充配额）
    struct hrtimer   slack_timer;             // 松弛定时器（回收未用完配额）

    struct list_head throttled_cfs_rq;        // 被限流的 cfs_rq 链表

    /* 统计 */
    int  nr_periods;
    int  nr_throttled;
    int  nr_burst;
    u64  throttled_time;
    u64  burst_time;
};
```

**核心逻辑：**

- `period` 是记账周期（默认 100ms），`quota` 是每周期允许的总 CPU 时间
- `runtime` 在 `period_timer` 到期时被补充（`__refill_cfs_bandwidth_runtime`），然后在各 `cfs_rq` 之间分配
- `throttled_cfs_rq` 链表记录了所有被限流的运行队列

### 1.3 struct cpuacct — CPU 记账

```c
// kernel/sched/cpuacct.c:26 — doom-lsp 确认
struct cpuacct {
    struct cgroup_subsys_state css;
    u64 __percpu                *cpuusage;   // per-CPU 累计 CPU 使用时间（ns）
    struct kernel_cpustat __percpu *cpustat; // per-CPU 细粒度统计（user/system）
};
```

每个 `cpuacct` 对应一个 `cpuacct` 控制器的 cgroup 节点。`cpuusage` 记录总 CPU 时间，`cpustat` 区分 user/system/irq 等。

```c
// 辅助函数 — 获取任务所属的 cpuacct
static inline struct cpuacct *task_ca(struct task_struct *tsk)
{
    return css_ca(task_css(tsk, cpuacct_cgrp_id));
}

static inline struct cpuacct *parent_ca(struct cpuacct *ca)
{
    return css_ca(ca->css.parent);
}
```

---

## 2. 路径一：cpu.shares → CFS 权重分配

### 2.1 写入入口

```
用户态：echo 1024 > /sys/fs/cgroup/cpu/mygroup/cpu.shares
→ cgroup_file_write()
→ cpu_shares_write_u64()          @ kernel/sched/core.c:9752
  → sched_group_set_shares()       @ kernel/sched/fair.c:14071
    → __sched_group_set_shares()   @ kernel/sched/fair.c:14035
```

#### cpu_shares_write_u64 — cgroup 文件回调

```c
// kernel/sched/core.c:9752 — doom-lsp 确认
static int cpu_shares_write_u64(struct cgroup_subsys_state *css,
                                struct cftype *cftype, u64 shareval)
{
    int ret;

    if (shareval > scale_load_down(ULONG_MAX))
        shareval = MAX_SHARES;

    ret = sched_group_set_shares(css_tg(css), scale_load(shareval));
    if (!ret)
        scx_group_set_weight(css_tg(css),
                             sched_weight_to_cgroup(shareval));
    return ret;
}
```

注意 `scale_load()` 宏：在内核内部，shares 以 `SCHED_FIXEDPOINT_SHIFT` 缩放存储（通常 ×1024），这是为了避免整数除法的精度损失。`css_tg(css)` 从 `cgroup_subsys_state` 反推出 `task_group` 指针。

#### sched_group_set_shares — 调度组权重入口

```c
// kernel/sched/fair.c:14071 — doom-lsp 确认
int sched_group_set_shares(struct task_group *tg, unsigned long shares)
{
    int ret;

    mutex_lock(&shares_mutex);
    if (tg_is_idle(tg))
        ret = -EINVAL;
    else
        ret = __sched_group_set_shares(tg, shares);
    mutex_unlock(&shares_mutex);

    return ret;
}
```

此处有 `SCHED_IDLE` 组的保护：idle 组的 shares 不可被直接修改。

### 2.2 __sched_group_set_shares — shares 的真正读写点

```c
// kernel/sched/fair.c:14035 — doom-lsp 确认
static int __sched_group_set_shares(struct task_group *tg, unsigned long shares)
{
    int i;

    lockdep_assert_held(&shares_mutex);

    if (!tg->se[0])
        return -EINVAL;

    shares = clamp(shares, scale_load(MIN_SHARES), scale_load(MAX_SHARES));

    if (tg->shares == shares)
        return 0;

    tg->shares = shares;
    for_each_possible_cpu(i) {
        struct rq *rq = cpu_rq(i);
        struct sched_entity *se = tg->se[i];
        struct rq_flags rf;

        rq_lock_irqsave(rq, &rf);
        update_rq_clock(rq);
        for_each_sched_entity(se) {
            update_load_avg(cfs_rq_of(se), se, UPDATE_TG);
            update_cfs_group(se);
        }
        rq_unlock_irqrestore(rq, &rf);
    }

    return 0;
}
```

**核心逻辑：**

1. **clamp**：值限制在 `MIN_SHARES`（2）和 `MAX_SHARES`（262144）之间
2. **写 `tg->shares`**：更新 per-task_group 的权重
3. **per-CPU 传播**：对每个 CPU，遍历该 task_group 的调度实体层级树：
   - `update_load_avg()` — 更新 PELT（Per-Entity Load Tracking）负载
   - `update_cfs_group()` — 重新计算 `sched_entity->load.weight`

**传播层级**：`for_each_sched_entity(se)` 沿着 `se->parent` 向上遍历，确保父组的 shares 变化也反映到祖父组的权重中。

### 2.3 calc_group_shares — 权重计算公式

```c
// kernel/sched/fair.c:4176 — doom-lsp 确认
static long calc_group_shares(struct cfs_rq *cfs_rq)
{
    long tg_weight, tg_shares, load, shares;
    struct task_group *tg = cfs_rq->tg;

    tg_shares = READ_ONCE(tg->shares);          // 用户设置的 shares（缩放后）

    load = max(scale_load_down(cfs_rq->load.weight),
               cfs_rq->avg.load_avg);          // 该 CPU 上的运行负载

    tg_weight = atomic_long_read(&tg->load_avg); // 所有 CPU 的总负载

    /* 减去本 CPU 的贡献，再加回精确值 */
    tg_weight -= cfs_rq->tg_load_avg_contrib;
    tg_weight += load;

    shares = (tg_shares * load);
    if (tg_weight)
        shares /= tg_weight;                   // 按负载比例分配

    return clamp_t(long, shares, MIN_SHARES, tg_shares);
}
```

**公式**：`shares_per_cpu = total_shares * cpu_load / total_load`

这是一个 **按 CPU 负载比例** 的权重分配。如果 4 核系统上 `total_shares = 1024`，CPU0 负载是总负载的 1/4，那么 CPU0 获得 `1024 / 4 = 256` shares。

**特殊情况**：如果某个 CPU 没任务（`load = 0`），返回 `MIN_SHARES`（2），避免完全得不到时间片。

### 2.4 update_cfs_group — 将 shares 写入选中的 se

```c
// kernel/sched/fair.c:4214 — doom-lsp 确认
static void update_cfs_group(struct sched_entity *se)
{
    struct cfs_rq *gcfs_rq = group_cfs_rq(se);
    long shares;

    if (!gcfs_rq || !gcfs_rq->load.weight)
        return;

    shares = calc_group_shares(gcfs_rq);
    if (unlikely(se->load.weight != shares))
        reweight_entity(cfs_rq_of(se), se, shares);
}
```

`reweight_entity()` 更新 `se->load.weight`，这个权重直接影响 CFS 的时间片计算。`weight` 越大，在 CFS 红黑树中被选中的概率越高。

### 2.5 CFS 调度时如何消费 shares

在 `pick_next_task_fair()` 中，CFS 通过 `sched_entity->load.weight` 确定时间片比例：

```c
// CFS 的时间片计算（简化的调度 tick 路径）
// entity_tick() → update_curr() → 累积 vruntime
// vruntime += delta_exec * NICE_0_LOAD / se->load.weight

// se->load.weight 越大 → vruntime 增长越慢 → 获得更多 CPU 时间
```

换句话说，shares 不直接等于 CPU 时间，而是通过影响 `vruntime` 的增速来间接控制。
`se->load.weight = 2048` 的进程，其 `vruntime` 增速是 `weight = 1024` 进程的一半，因此获得两倍的 CPU 时间。

### 2.6 load_balance 中的 shares 更新

负载均衡路径也会触发 shares 重新计算：

```c
// load_balance() 在发现 CPU 间负载不均时：
// → update_group_shares() → 重新计算所有 task_group 的 shares
// → 将任务从高负载 CPU 迁移到低负载 CPU

// 在 find_busiest_group() 中，使用 shares 折算后的权重
// 来判断负载是否 "均衡"
```

`update_group_shares()` 通过 `walk_tg_tree()` 遍历整个 task_group 树，为每个组的每个 CPU 调用 `update_cfs_group()`。这确保了在进程迁移后权重分布的正确性。

---

## 3. 路径二：cpu.cfs_quota_us → 带宽控制（throttle / unthrottle）

### 3.1 写入入口

```
用户态：echo 250000 > /sys/fs/cgroup/cpu/mygroup/cpu.cfs_quota_us
→ cpu_quota_write_s64()          @ kernel/sched/core.c:10127
  → tg_set_bandwidth()           @ kernel/sched/core.c:10049
    → tg_set_cfs_bandwidth()     @ kernel/sched/core.c:9778

用户态：echo 100000 > /sys/fs/cgroup/cpu/mygroup/cpu.cfs_period_us
→ cpu_period_write_u64()         @ kernel/sched/core.c:10117
  → tg_set_bandwidth()           @ kernel/sched/core.c:10049
    → tg_set_cfs_bandwidth()     @ kernel/sched/core.c:9778
```

`cpu_quota_write_s64` 与 `cpu_period_write_u64` 都调用共同的 `tg_set_bandwidth()` 做边界检查，然后调用 `tg_set_cfs_bandwidth()`：

```c
// kernel/sched/core.c:10127 — doom-lsp 确认
static int cpu_quota_write_s64(struct cgroup_subsys_state *css,
                               struct cftype *cftype, s64 quota_us)
{
    struct task_group *tg = css_tg(css);
    u64 period_us, burst_us;

    if (quota_us < 0)
        quota_us = RUNTIME_INF;   // -1 表示无穷（不限流）

    tg_bandwidth(tg, &period_us, NULL, &burst_us);
    return tg_set_bandwidth(tg, period_us, quota_us, burst_us);
}
```

### 3.2 tg_set_cfs_bandwidth — 核心配置函数

```c
// kernel/sched/core.c:9778 — doom-lsp 确认
static int tg_set_cfs_bandwidth(struct task_group *tg,
                                u64 period_us, u64 quota_us, u64 burst_us)
{
    int i, ret = 0, runtime_enabled, runtime_was_enabled;
    struct cfs_bandwidth *cfs_b = &tg->cfs_bandwidth;
    u64 period, quota, burst;

    period = (u64)period_us * NSEC_PER_USEC;

    if (quota_us == RUNTIME_INF)
        quota = RUNTIME_INF;
    else
        quota = (u64)quota_us * NSEC_PER_USEC;

    burst = (u64)burst_us * NSEC_PER_USEC;

    guard(cpus_read_lock)();
    guard(mutex)(&cfs_constraints_mutex);

    // 验证新的配置不会造成次级组超出父级限制
    ret = __cfs_schedulable(tg, period, quota);
    if (ret)
        return ret;

    runtime_enabled = quota != RUNTIME_INF;
    runtime_was_enabled = cfs_b->quota != RUNTIME_INF;

    // 从禁用→启用时，递增全局计数器
    if (runtime_enabled && !runtime_was_enabled)
        cfs_bandwidth_usage_inc();

    scoped_guard (raw_spinlock_irq, &cfs_b->lock) {
        cfs_b->period = ns_to_ktime(period);
        cfs_b->quota = quota;
        cfs_b->burst = burst;

        __refill_cfs_bandwidth_runtime(cfs_b);

        if (runtime_enabled)
            start_cfs_bandwidth(cfs_b);    // 启动 hrtimer
    }

    // 对每个 CPU 的 cfs_rq 生效
    for_each_online_cpu(i) {
        struct cfs_rq *cfs_rq = tg->cfs_rq[i];
        struct rq *rq = cfs_rq->rq;

        guard(rq_lock_irq)(rq);
        cfs_rq->runtime_enabled = runtime_enabled;
        cfs_rq->runtime_remaining = 1;     // 初始化为 1ns，避免立即 throttle

        if (cfs_rq->throttled)
            unthrottle_cfs_rq(cfs_rq);     // 如果之前被限流，恢复
    }

    if (runtime_was_enabled && !runtime_enabled)
        cfs_bandwidth_usage_dec();

    return 0;
}
```

**关键步骤：**

1. **纳米秒转换**：`period_us` 和 `quota_us` 从微秒转为纳秒内部表示
2. **层次校验**：`__cfs_schedulable()` 确保子组的 quota 不超过父组
3. **补充 runtime**：新配置写入后立即调用 `__refill_cfs_bandwidth_runtime()` 补充一次
4. **启动定时器**：`start_cfs_bandwidth()` 启动 hrtimer
5. **per-CPU 生效**：遍历所有 CPU，更新标志位并处理 throttle 状态

### 3.3 核心变量

```
cfs_b->period     = 100000μs = 100ms   (cpu.cfs_period_us, 默认)
cfs_b->quota      = 250000μs = 250ms   (cpu.cfs_quota_us)
                 → 每 100ms 周期中，最多可运行 250ms（即 2.5 核）
cfs_b->runtime    = 当前周期剩余可分配的时间（全局池）
cfs_rq->runtime_remaining = 该运行队列剩余的时间（per-CPU）
cfs_rq->throttled = 该运行队列是否被限流
```

### 3.4 定时补充 — hrtimer + __refill_cfs_bandwidth_runtime

```c
// kernel/sched/fair.c:5864 — doom-lsp 确认
void __refill_cfs_bandwidth_runtime(struct cfs_bandwidth *cfs_b)
{
    s64 runtime;

    if (unlikely(cfs_b->quota == RUNTIME_INF))
        return;

    cfs_b->runtime += cfs_b->quota;              // 补充配额

    runtime = cfs_b->runtime_snap - cfs_b->runtime;
    if (runtime > 0) {
        cfs_b->burst_time += runtime;            // 记录 burst 使用
        cfs_b->nr_burst++;
    }

    cfs_b->runtime = min(cfs_b->runtime,
                         cfs_b->quota + cfs_b->burst);  // 上限（quota + burst）
    cfs_b->runtime_snap = cfs_b->runtime;
}
```

`start_cfs_bandwidth()` 启动 hrtimer `period_timer`。到期时调用 `sched_cfs_period_timer()` → `do_sched_cfs_period_timer()`：

```c
// kernel/sched/fair.c:6794 — doom-lsp 确认
void start_cfs_bandwidth(struct cfs_bandwidth *cfs_b)
{
    lockdep_assert_held(&cfs_b->lock);

    if (cfs_b->period_active)
        return;

    cfs_b->period_active = 1;
    hrtimer_forward_now(&cfs_b->period_timer, cfs_b->period);
    hrtimer_start_expires(&cfs_b->period_timer, HRTIMER_MODE_ABS_PINNED);
}
```

#### do_sched_cfs_period_timer — 周期定时器回调

```c
// kernel/sched/fair.c:6462 — doom-lsp 确认
static int do_sched_cfs_period_timer(struct cfs_bandwidth *cfs_b,
                                     int overrun, unsigned long flags)
{
    int throttled;

    if (cfs_b->quota == RUNTIME_INF)
        goto out_deactivate;

    throttled = !list_empty(&cfs_b->throttled_cfs_rq);
    cfs_b->nr_periods += overrun;

    // 补充新一轮的 quota runtime
    __refill_cfs_bandwidth_runtime(cfs_b);

    if (cfs_b->idle && !throttled)
        goto out_deactivate;

    if (!throttled) {
        cfs_b->idle = 1;           // 标记可能进入 idle
        return 0;
    }

    cfs_b->nr_throttled += overrun;

    // 分发 runtime 给 throttled 的 cfs_rq
    while (throttled && cfs_b->runtime > 0) {
        raw_spin_unlock_irqrestore(&cfs_b->lock, flags);
        throttled = distribute_cfs_runtime(cfs_b);
        raw_spin_lock_irqsave(&cfs_b->lock, flags);
    }

    cfs_b->idle = 0;
    return 0;

out_deactivate:
    return 1;   // 停止定时器（无限制或无人被限流时）
}
```

当没有 throttled cfs_rq 时，定时器自我标记 idle，如果持续 idle 则最终 `out_deactivate` 停止定时器（节省功耗）。

### 3.5 运行时扣减 — update_curr 中的 bandwidth 检查

每个调度 tick 都会调用 `update_curr()`，它同时服务两个任务：更新 vruntime 和扣减 bandwidth。

```c
// kernel/sched/fair.c:1378 — doom-lsp 确认
static void update_curr(struct cfs_rq *cfs_rq)
{
    struct sched_entity *curr = cfs_rq->curr;
    struct rq *rq = rq_of(cfs_rq);
    s64 delta_exec;

    if (unlikely(!curr))
        return;

    delta_exec = update_se(rq, curr);          // 计算本次执行时间
    if (unlikely(delta_exec <= 0))
        return;

    curr->vruntime += calc_delta_fair(delta_exec, curr);  // 更新 vruntime

    // ... friend_server 更新 ...

    account_cfs_rq_runtime(cfs_rq, delta_exec); // ← 带宽扣减在这里

    if (cfs_rq->nr_queued == 1)
        return;

    // ... 是否需要重新调度 ...
}
```

`account_cfs_rq_runtime()` 调用 `__account_cfs_rq_runtime()`：

```c
// kernel/sched/fair.c:5928 — doom-lsp 确认
static void __account_cfs_rq_runtime(struct cfs_rq *cfs_rq, u64 delta_exec)
{
    cfs_rq->runtime_remaining -= delta_exec;   // 扣减（delta_exec 是执行时间）

    if (likely(cfs_rq->runtime_remaining > 0))
        return;                                // 还有余量，继续运行

    if (cfs_rq->throttled)
        return;                                // 已经被限流了

    // 尝试申请更多 runtime
    if (!assign_cfs_rq_runtime(cfs_rq) && likely(cfs_rq->curr))
        resched_curr(rq_of(cfs_rq));           // 申请失败 → 触发限流
}
```

**流程图：**

```
update_curr() 每个调度 tick 触发
  │
  ├── vruntime 更新（权重相关）
  │
  └── account_cfs_rq_runtime()
        │
        ├── cfs_rq->runtime_remaining -= delta_exec
        │
        ├── runtime_remaining > 0  →  继续运行
        │
        └── runtime_remaining <= 0
              │
              ├── assign_cfs_rq_runtime() → 从 cfs_b->runtime 申请
              │     ├── 成功 → 继续
              │     └── 失败 → resched_curr() → 下一个调度点触发 throttle
              │
              └── throttle_cfs_rq()
```

### 3.6 assign_cfs_rq_runtime — 从全局池申请 runtime

```c
// kernel/sched/fair.c:5888 — doom-lsp 确认
static int __assign_cfs_rq_runtime(struct cfs_bandwidth *cfs_b,
                                   struct cfs_rq *cfs_rq, u64 target_runtime)
{
    u64 min_amount, amount = 0;

    lockdep_assert_held(&cfs_b->lock);

    min_amount = target_runtime - cfs_rq->runtime_remaining;

    if (cfs_b->quota == RUNTIME_INF)
        amount = min_amount;
    else {
        start_cfs_bandwidth(cfs_b);            // 确保定时器在运行

        if (cfs_b->runtime > 0) {
            amount = min(cfs_b->runtime, min_amount);
            cfs_b->runtime -= amount;
            cfs_b->idle = 0;
        }
    }

    cfs_rq->runtime_remaining += amount;

    return cfs_rq->runtime_remaining > 0;
}
```

`target_runtime` 默认为 `sched_cfs_bandwidth_slice()`（通常 5ms）。若全局池 `cfs_b->runtime` 不足，返回 0，触发 `resched_curr`。

### 3.7 throttle_cfs_rq — 限流实现

```c
// kernel/sched/fair.c:6210 — doom-lsp 确认
static bool throttle_cfs_rq(struct cfs_rq *cfs_rq)
{
    struct rq *rq = rq_of(cfs_rq);
    struct cfs_bandwidth *cfs_b = tg_cfs_bandwidth(cfs_rq->tg);
    int dequeue = 1;

    raw_spin_lock(&cfs_b->lock);
    // 最后尝试申请 1ns —— 处理竞态：刚好有 runtime 释放
    if (__assign_cfs_rq_runtime(cfs_b, cfs_rq, 1)) {
        dequeue = 0;     // 申请到了，不限流
    } else {
        list_add_tail_rcu(&cfs_rq->throttled_list,
                          &cfs_b->throttled_cfs_rq);
    }
    raw_spin_unlock(&cfs_b->lock);

    if (!dequeue)
        return false;    // 不需要限流

    // 冻结整个层级树的 PELT runnable average
    rcu_read_lock();
    walk_tg_tree_from(cfs_rq->tg, tg_throttle_down, tg_nop, (void *)rq);
    rcu_read_unlock();

    cfs_rq->throttled = 1;              // ← 限流标记
    return true;
}
```

**throttle 做了三件事：**

1. **加入 `throttled_list`**：让 `do_sched_cfs_period_timer()` 能在下一个周期找到它
2. **冻结 PELT 时钟**：`tg_throttle_down` 冻结层级数的 PELT 统计，避免限流期间错误衰减
3. **设置 `throttled = 1`**：CFS 的 `pick_next_task_fair()` 和 `enqueue_task_fair()` 会跳过标记的 `cfs_rq`

### 3.8 CFS 调度器如何跳过 throttled cfs_rq

```c
// 在 pick_next_task_fair() 中：
// for_each_sched_entity(se) 会调用：
static inline int cfs_rq_throttled(struct cfs_rq *cfs_rq)
{
    return cfs_bandwidth_used() && cfs_rq->throttled;
}

// 如果 cfs_rq->throttled，则 pick_next_task_fair() 跳过
// 该 cfs_rq 及其所有子 cfs_rq。
// 效果：属于该组的进程不再获得 CPU。
```

### 3.9 unthrottle_cfs_rq — 恢复运行

```c
// kernel/sched/fair.c:6251 — doom-lsp 确认
void unthrottle_cfs_rq(struct cfs_rq *cfs_rq)
{
    struct rq *rq = rq_of(cfs_rq);
    struct cfs_bandwidth *cfs_b = tg_cfs_bandwidth(cfs_rq->tg);
    struct sched_entity *se = cfs_rq->tg->se[cpu_of(rq)];

    // 没有 runtime 不能恢复——否则立刻又被 throttle
    if (cfs_rq->runtime_enabled && cfs_rq->runtime_remaining <= 0)
        return;

    cfs_rq->throttled = 0;
    update_rq_clock(rq);

    raw_spin_lock(&cfs_b->lock);
    if (cfs_rq->throttled_clock) {
        cfs_b->throttled_time += rq_clock(rq) - cfs_rq->throttled_clock;
        cfs_rq->throttled_clock = 0;
    }
    list_del_rcu(&cfs_rq->throttled_list);
    raw_spin_unlock(&cfs_b->lock);

    // 恢复层级树的 throttle 状态
    walk_tg_tree_from(cfs_rq->tg, tg_nop, tg_unthrottle_up, (void *)rq);

    // 如果 idle CPU 上有任务，唤醒它
    if (rq->curr == rq->idle && rq->cfs.nr_queued)
        resched_curr(rq);
}
```

**unthrottle 做了四件事：**

1. **防御检查**：`runtime_remaining <= 0` 时拒绝恢复，防止立即再次 throttle
2. **清除标记**：`cfs_rq->throttled = 0`
3. **记录统计**：计算 throttle 持续时间，累加到 `cfs_b->throttled_time`
4. **唤醒 CPU**：如果 CPU 空闲且有排队任务，触发重新调度

### 3.10 distribute_cfs_runtime — 配额分发

```c
// kernel/sched/fair.c:6374 — doom-lsp 确认
static bool distribute_cfs_runtime(struct cfs_bandwidth *cfs_b)
{
    struct cfs_rq *cfs_rq;
    u64 runtime, remaining = 1;
    bool throttled = false;

    rcu_read_lock();
    list_for_each_entry_rcu(cfs_rq, &cfs_b->throttled_cfs_rq,
                            throttled_list) {
        struct rq *rq = rq_of(cfs_rq);
        struct rq_flags rf;

        rq_lock_irqsave(rq, &rf);
        if (!cfs_rq_throttled(cfs_rq))
            goto next;

        raw_spin_lock(&cfs_b->lock);
        // 从全局池分配（最多切片大小）
        runtime = min(cfs_b->runtime, min_cfs_rq_runtime);
        cfs_b->runtime -= runtime;
        remaining = cfs_b->runtime;
        raw_spin_unlock(&cfs_b->lock);

        cfs_rq->runtime_remaining += runtime;

        if (cfs_rq->runtime_remaining > 0) {
            // runtime 为正 → 尝试 unthrottle
            // （将在调度器中执行实际的 unthrottle）
            __unthrottle_cfs_rq_async(cfs_rq);
        } else {
            throttled = true;
        }
next:
        rq_unlock_irqrestore(rq, &rf);
        if (!remaining)
            break;
    }
    rcu_read_unlock();

    return throttled;
}
```

`distribute_cfs_runtime()` 遍历 `throttled_cfs_rq` 链表，为每个限流的 `cfs_rq` 分配 runtime（最多 `min_cfs_rq_runtime = 1ms`），并尝试通过 `__unthrottle_cfs_rq_async()` 异步恢复。

### 3.11 用户态观测

```bash
cat /sys/fs/cgroup/cpu/mygroup/cpu.stat
# nr_periods: 100       # 总周期数（hrtimer 到期次数）
# nr_throttled: 5       # 被限流的周期数
# throttled_time: 1234  # 累计限流时间（ns）
# nr_bursts: 0          # burst 次数
# burst_time: 0         # burst 总时间（ns）
```

这些统计由 `cpu_cfs_stat_show()` 输出：

```c
// kernel/sched/core.c:9964 — doom-lsp 确认
static int cpu_cfs_stat_show(struct seq_file *sf, void *v)
{
    struct task_group *tg = css_tg(seq_css(sf));
    struct cfs_bandwidth *cfs_b = &tg->cfs_bandwidth;

    seq_printf(sf, "nr_periods %d\n", cfs_b->nr_periods);
    seq_printf(sf, "nr_throttled %d\n", cfs_b->nr_throttled);
    seq_printf(sf, "throttled_time %llu\n", cfs_b->throttled_time);

    if (schedstat_enabled() && tg != &root_task_group) {
        struct sched_statistics *stats;
        u64 ws = 0;
        int i;
        for_each_possible_cpu(i) {
            stats = __schedstats_from_se(tg->se[i]);
            ws += schedstat_val(stats->wait_sum);
        }
        seq_printf(sf, "wait_sum %llu\n", ws);
    }

    seq_printf(sf, "nr_bursts %d\n", cfs_b->nr_burst);
    seq_printf(sf, "burst_time %llu\n", cfs_b->burst_time);

    return 0;
}
```

---

## 4. 路径三：cpuacct — CPU 记账（纯统计）

### 4.1 数据结构回顾

```c
// kernel/sched/cpuacct.c:26
struct cpuacct {
    struct cgroup_subsys_state css;
    u64 __percpu                *cpuusage;   // per-CPU 累计 CPU 时间（ns）
    struct kernel_cpustat __percpu *cpustat; // per-CPU 细粒度统计（user/system/irq）
};
```

每个 CPU 维护一个独立的 `cpuusage` 和 `cpustat` 计数器，避免跨 CPU 的 cache bouncing。

### 4.2 cpuacct_charge — 累计 CPU 时间

```c
// kernel/sched/cpuacct.c:336 — doom-lsp 确认
void cpuacct_charge(struct task_struct *tsk, u64 cputime)
{
    unsigned int cpu = task_cpu(tsk);
    struct cpuacct *ca;

    lockdep_assert_rq_held(cpu_rq(cpu));

    for (ca = task_ca(tsk); ca; ca = parent_ca(ca))
        *per_cpu_ptr(ca->cpuusage, cpu) += cputime;
}
```

**调用关系：**

```
update_curr()
  → account_cfs_rq_runtime()   // 带宽扣减
  → cpuacct_charge()            // CPU 记账 ← 同一位置触发
```

**逐级向上累加：** 从任务所属的 `cpuacct` 开始，沿 `css.parent` 一直累加到根节点。这意味着 `cpuacct.usage` 包含了所有子组的累计时间——树形汇总。

### 4.3 cpuacct_account_field — user/system 区分

```c
// kernel/sched/cpuacct.c:352 — doom-lsp 确认
void cpuacct_account_field(struct task_struct *tsk, int index, u64 val)
{
    struct cpuacct *ca;

    for (ca = task_ca(tsk); ca != &root_cpuacct; ca = parent_ca(ca))
        __this_cpu_add(ca->cpustat->cpustat[index], val);
}
```

**调用者：** `account_user_time()` 和 `account_system_time()`（位于 `kernel/sched/cputime.c`）。

**注意：不累加到 root**。root `cpuacct` 的 `cpustat` 由调用者直接更新（全局 `kernel_cpustat`），避免双重累加。这是与 `cpuacct_charge()` 的一个关键区别。

- `index = CPUTIME_USER`：用户态时间
- `index = CPUTIME_SYSTEM`：内核态时间（含 `CPUTIME_IRQ` 和 `CPUTIME_SOFTIRQ`）

### 4.4 cpuacct.usage / cpuacct.usage_user / cpuacct.usage_sys 读取

```c
// kernel/sched/cpuacct.c:96 — doom-lsp 确认
static u64 cpuacct_cpuusage_read(struct cpuacct *ca, int cpu,
                                 enum cpuacct_stat_index index)
{
    u64 *cpuusage = per_cpu_ptr(ca->cpuusage, cpu);
    u64 *cpustat = per_cpu_ptr(ca->cpustat, cpu)->cpustat;
    u64 data;

    switch (index) {
    case CPUACCT_STAT_USER:
        data = cpustat[CPUTIME_USER] + cpustat[CPUTIME_NICE];
        break;
    case CPUACCT_STAT_SYSTEM:
        data = cpustat[CPUTIME_SYSTEM] + cpustat[CPUTIME_IRQ] +
               cpustat[CPUTIME_SOFTIRQ];
        break;
    case CPUACCT_STAT_NSTATS:
        data = *cpuusage;           // 总时间（user + system）
        break;
    }

    return data;
}

static u64 __cpuusage_read(struct cgroup_subsys_state *css,
                           enum cpuacct_stat_index index)
{
    struct cpuacct *ca = css_ca(css);
    u64 totalcpuusage = 0;
    int i;

    for_each_possible_cpu(i)
        totalcpuusage += cpuacct_cpuusage_read(ca, i, index);

    return totalcpuusage;
}
```

**注意：** 遍历 `for_each_possible_cpu` 而非 `for_each_online_cpu`，确保 hotplug 后离线 CPU 的累计时间也被包含。

### 4.5 cpuacct 的完整 cftype 注册

```c
// kernel/sched/cpuacct.c — cftype 文件注册（从代码提取）
static struct cftype files[] = {
    {
        .name = "cpuacct.usage",
        .read_u64 = cpuusage_read,           // CPUACCT_STAT_NSTATS（总时间）
    },
    {
        .name = "cpuacct.usage_user",
        .read_u64 = cpuusage_user_read,      // CPUACCT_STAT_USER
    },
    {
        .name = "cpuacct.usage_sys",
        .read_u64 = cpuusage_sys_read,       // CPUACCT_STAT_SYSTEM
    },
    {
        .name = "cpuacct.usage_percpu",
        .seq_show = cpuacct_all_stat_show,   // per-CPU 逐核输出
    },
    {
        .name = "cpuacct.stat",
        .seq_show = cpuacct_stats_show,      // user/system 汇总
    },
    { }     // 终止
};
```

`cpuacct.stat` 的输出格式为：

```bash
cat /sys/fs/cgroup/cpuacct/mygroup/cpuacct.stat
# user 1234567       # 用户态时间（USER_HZ 单位）
# system 7654321     # 内核态时间（USER_HZ 单位）
```

---

## 5. 三条路径的关系与完整数据流

### 5.1 整体架构图

```
OceanBase 写文件             内核处理路径                           调度器效果
────────────────────────────────────────────────────────────────────────────────
write(cpu.shares, 1024)  →  cpu_shares_write_u64()               CFS 按权重分时间片
                             → __sched_group_set_shares()          (vruntime 增速调整)
                               → update_cfs_group()
                                 → calc_group_shares()
                                   → reweight_entity()

write(cpu.cfs_quota, N)  →  cpu_quota_write_s64()                超额线程被限流
                             → tg_set_bandwidth()
                               → tg_set_cfs_bandwidth()
                                 → __refill_cfs_bandwidth_runtime()
                                 → start_cfs_bandwidth()
                         运行中:
                             update_curr() 每个 tick 触发
                               → account_cfs_rq_runtime()
                                 → __account_cfs_rq_runtime()
                                   → runtime_remaining -= delta
                                   → 超额 → throttle_cfs_rq()
                         周期恢复:
                             period_timer 到期
                               → do_sched_cfs_period_timer()
                                 → __refill_cfs_bandwidth_runtime()
                                 → distribute_cfs_runtime()
                                   → unthrottle_cfs_rq()

read(cpuacct.usage)      →  cpuacct_cpuusage_read()              读取累计 CPU 时间
                             → 遍历所有 CPU 求和
                         记账:
                             update_curr()
                               → cpuacct_charge()                 逐级向上累加
                             account_user/system_time()
                               → cpuacct_account_field()          向上累加（不含 root）

write(cgroup.procs, PID) →  cgroup_attach_task()                 进程迁移到新调度组
                             → cpu_cgroup_attach()
                               → sched_move_task()
```

### 5.2 三条路径的同步与互斥

| 特性 | cpu.shares | cpu.cfs_quota_us | cpuacct |
|------|-----------|------------------|---------|
| 类型 | 软限制（相对权重） | 硬限制（绝对配额） | 纯统计（只读） |
| 互斥 | 多组之间相对 | 组内绝对上限 | 无互斥，累加 |
| 限流 | 不会 limit | 超额则 throttle | 不涉及 |
| 累加方式 | 按 CPU 负载比例 | 全局池 per-CPU 分发 | 逐级向上累加 |
| 精度 | PELT 负载（ms 级） | hrtimer（ns 级） | ns 级 |
| 是否受 load_balance 影响 | 是（均衡后重算 shares） | 否（throttle 独立于均衡） | 否 |

### 5.3 并发场景分析

**场景：cpu.shares 和 cpu.cfs_quota_us 同时使用**

当 `cpu.shares` 和 `cpu.cfs_quota_us` 同时设置时：

- `cpu.shares` 控制组内进程之间的相对比例
- `cpu.cfs_quota_us` 控制组整体的绝对上限
- 先验证限额（quota），再按权重分配（shares）

```
实际 CPU 时间 = min(quota 限制下的可用时间, shares 分配的权重时间)
```

**场景：cpuacct 读取一致性**

- `cpuacct_charge()` 在 `rq->lock` 保护下调用
- `cpuacct_cpuusage_read()` 在没有 `rq->lock` 的情况下读取（64-bit 平台上）
- 可能存在读取时累加未完成的不一致——但在统计场景下可接受（eventual consistency）

---

## 6. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct task_group` | kernel/sched/sched.h | 474 |
| `struct cfs_bandwidth` | kernel/sched/sched.h | 447 |
| `struct cpuacct` | kernel/sched/cpuacct.c | 26 |
| `cpu_shares_write_u64` | kernel/sched/core.c | 9752 |
| `sched_group_set_shares` | kernel/sched/fair.c | 14071 |
| `__sched_group_set_shares` | kernel/sched/fair.c | 14035 |
| `calc_group_shares` | kernel/sched/fair.c | 4176 |
| `update_cfs_group` | kernel/sched/fair.c | 4214 |
| `update_curr` | kernel/sched/fair.c | 1378 |
| `account_cfs_rq_runtime` | kernel/sched/fair.c | 5947 |
| `__account_cfs_rq_runtime` | kernel/sched/fair.c | 5928 |
| `__assign_cfs_rq_runtime` | kernel/sched/fair.c | 5888 |
| `tg_set_cfs_bandwidth` | kernel/sched/core.c | 9778 |
| `__refill_cfs_bandwidth_runtime` | kernel/sched/fair.c | 5864 |
| `start_cfs_bandwidth` | kernel/sched/fair.c | 6794 |
| `do_sched_cfs_period_timer` | kernel/sched/fair.c | 6462 |
| `distribute_cfs_runtime` | kernel/sched/fair.c | 6374 |
| `throttle_cfs_rq` | kernel/sched/fair.c | 6210 |
| `unthrottle_cfs_rq` | kernel/sched/fair.c | 6251 |
| `cpu_cfs_stat_show` | kernel/sched/core.c | 9964 |
| `cpu_quota_write_s64` | kernel/sched/core.c | 10127 |
| `cpu_period_write_u64` | kernel/sched/core.c | 10117 |
| `cpuacct_charge` | kernel/sched/cpuacct.c | 336 |
| `cpuacct_account_field` | kernel/sched/cpuacct.c | 352 |
| `cpuacct_cpuusage_read` | kernel/sched/cpuacct.c | 96 |
| `cpuacct.all_cftype` | kernel/sched/cpuacct.c | ~300-327 |
| `cpu_legacy_files`（cftype 注册） | kernel/sched/core.c | 10196 |

---

## 7. 总结

**cpu.shares** 是 CFS 的权重分配机制。通过 `__sched_group_set_shares()` → `update_cfs_group()` → `calc_group_shares()`，将用户设定的 shares 按实际 CPU 负载比例分配到每个 CPU。最终影响 `sched_entity->load.weight`，通过 CFS 的 vruntime 计算间接控制时间片分配。它不会限流，只是优先级的差异。

**cpu.cfs_quota_us** 是 hrtimer 驱动的硬限流。`tg_set_cfs_bandwidth()` 配置 period + quota，`start_cfs_bandwidth()` 启动周期定时器。每调度 tick 通过 `update_curr()` → `account_cfs_rq_runtime()` 扣减 runtime，超额时由 `throttle_cfs_rq()` 限流。下个周期 `do_sched_cfs_period_timer()` → `__refill_cfs_bandwidth_runtime()` 补充配额，`distribute_cfs_runtime()` 遍历 `throttled_list` 恢复。

**cpuacct** 是纯统计子系统。`cpuacct_charge()` 在 `update_curr()` 中触发，沿 css 层级逐级向上累加 CPU 时间。`cpuacct_account_field()` 区分 user/system 时间。每个 `cpuacct` 保存的是自己和所有子组的累计值——树形汇总。

三条路径独立但协同：shares 控制比例，quota 设置上限，cpuacct 提供监控数据。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-06 | 内核版本：Linux 7.0-rc1*
