# Linux EEVDF 调度器深度分析

## 概述

EEVDF（Earliest Eligible Virtual Deadline First）是 Linux 6.6 引入的调度器，替代了使用了近 20 年的 CFS（Completely Fair Scheduler）。EEVDF 由 Peter Zijlstra 实现，基于 Stoica et al. 1996 年的学术论文。

EEVDF 与 CFS 的核心区别：

| 特性 | CFS | EEVDF |
|------|-----|-------|
| 选择标准 | min vruntime | eligibility + deadline |
| 调度切片 | `sched_slice()` 动态计算 | `sysctl_sched_base_slice` 固定基准 |
| 公平度量 | vruntime 直接比较 | vlag（虚拟滞后）精确量化 |
| 抢占判定 | vruntime 差值 | eligibility + deadline + protect_slice |

## 核心数据结构

### sched_entity

（`include/linux/sched.h` L575~611）

```c
struct sched_entity {
    struct load_weight  load;           // 权重
    struct rb_node      run_node;       // EEVDF 红黑树（按 deadline 排序）
    u64                 deadline;       // 虚拟截止时间
    u64                 min_vruntime;   // 子实体最小 vruntime
    u64                 min_slice;      // 最小切片
    u64                 max_slice;      // 最大切片
    struct list_head    group_node;
    unsigned char       on_rq;          // 是否在运行队列中
    unsigned char       sched_delayed;  // 延迟 dequeue 状态
    unsigned char       rel_deadline;
    unsigned char       custom_slice;   // 通过 sched_setattr 自定义
    u64                 exec_start;
    u64                 sum_exec_runtime;
    u64                 prev_sum_exec_runtime;
    u64                 vruntime;       // 虚拟运行时间
    s64                 vlag;           // 虚拟滞后（lag = V - v_i）
    u64                 vprot;          // 保护截止时间（min_slice 保护）
    u64                 slice;          // 调度切片（物理时间）
    u64                 nr_migrations;
    ...
};
```

EEVDF 的**新增/语义变化字段**：
- `deadline`：选择标准。每次 slice 用完重算
- `vlag`：虚拟滞后 `= V - v_i`，正值表示欠服务（eligible）
- `vprot`：保护截止时间，当前实体 `vruntime < vprot` 时不被抢占
- `custom_slice`：`sched_setattr(SCHED_FLAG_CUSTOM_SLICE)` 设置

### cfs_rq

（`kernel/sched/sched.h` L678~）

```c
struct cfs_rq {
    struct load_weight  load;
    unsigned int        nr_queued;
    unsigned int        h_nr_queued;
    unsigned int        h_nr_runnable;
    unsigned int        h_nr_idle;
    s64                 sum_w_vruntime;        // 加权平均 vruntime 分子
    u64                 sum_weight;            // 加权平均 vruntime 分母
    u64                 zero_vruntime;         // 基准偏移
    unsigned int        sum_shift;             // 溢出保护移位
    struct rb_root_cached tasks_timeline;      // 按 deadline 排序的红黑树
    struct sched_entity *curr;                 // 当前运行实体
    struct sched_entity *next;                 // buddy 提示
    ...
};
```

`tasks_timeline` 的排序键是 **deadline**（CFS 按 `vruntime - cfs_rq->min_vruntime`）。

## EEVDF 算法详解

### 数学模型

```
每个实体 i 的参数：
  w_i    — 权重（nice → weight 映射）
  r_i    — 请求时间（slice，默认 sysctl_sched_base_slice ≈ 3ms）
  ve_i   — 虚拟开始时间 ≈ vruntime（实际已使用的虚拟时间）
  vd_i   — 虚拟截止时间

核心公式：
  vd_i = ve_i + r_i / w_i

滞后定义：
  lag_i = w_i × (V - v_i)
  其中 V = 加权平均 vruntime = (Σ w_j × v_j) / (Σ w_j)

虚拟滞后（内核实际跟踪的）：
  vl_i = V - v_i    (不需要权重因子的简化量)

Eligibility 条件：
  vl_i >= 0  ↔  V >= v_i  ↔  实体欠服务，有资格运行
```

### avg_vruntime 计算

（`kernel/sched/fair.c` L676~780）

```c
// entity_key = vruntime - zero_vruntime
static inline s64 entity_key(struct cfs_rq *cfs_rq, struct sched_entity *se)
{
    return se->vruntime - cfs_rq->zero_vruntime;
}

// V = sum_w_vruntime / sum_weight
// 实际实现使用定点数除以避免除法
// sum_w_vruntime = Σ entity_key(entity) × weight(entity)
// sum_weight = Σ weight(entity)（经过 sum_shift 缩放）
```

`sum_shift` 是溢出保护机制 — 当 `sum_w_vruntime` 接近 64 位溢出时，逐步右移权重值。

## 认证代码路径

### 时间簿记：update_se + update_curr

（`kernel/sched/fair.c` L1324~1425）

时间簿记被分为两层：底层 `update_se()` 处理物理时间记录，上层 `update_curr()` 处理公平调度逻辑。

```c
// L1324 — 底层时间记录（物理时间）
static s64 update_se(struct rq *rq, struct sched_entity *se)
{
    u64 now = rq_clock_task(rq);
    s64 delta_exec = now - se->exec_start;
    if (unlikely(delta_exec <= 0))
        return delta_exec;

    se->exec_start = now;
    if (entity_is_task(se)) {
        struct task_struct *donor = task_of(se);
        struct task_struct *running = rq->curr;
        // proxy-exec：running 可能是代理执行者，donor 是实际拥有实体的任务
        running->se.exec_start = now;
        running->se.sum_exec_runtime += delta_exec;
        cgroup_account_cputime(donor, delta_exec);
    } else {
        se->sum_exec_runtime += delta_exec;
    }
    return delta_exec;
}

// L1378 — CFS 时间更新（公平调度逻辑）
static void update_curr(struct cfs_rq *cfs_rq)
{
    struct sched_entity *curr = cfs_rq->curr;
    struct rq *rq = rq_of(cfs_rq);
    s64 delta_exec;
    bool resched;

    if (unlikely(!curr))
        return;

    delta_exec = update_se(rq, curr);       // 由 update_se 处理物理时间
    if (unlikely(delta_exec <= 0))
        return;

    curr->vruntime += calc_delta_fair(delta_exec, curr);  // 转换为虚拟时间
    resched = update_deadline(cfs_rq, curr);  // 检查 slice 是否用完

    if (entity_is_task(curr))
        dl_server_update(&rq->fair_server, delta_exec);  // DL server 时间记账

    account_cfs_rq_runtime(cfs_rq, delta_exec);  // CFS bandwidth

    if (cfs_rq->nr_queued == 1)
        return;  // 唯一实体，不需要抢占

    if (resched || !protect_slice(curr)) {
        resched_curr_lazy(rq);      // 设置 TIF_NEED_RESCHED_LAZY
        clear_buddies(cfs_rq, curr);
    }
}
```

**注意**：`resched_curr_lazy()` 使用懒抢占——不立即触发，等到下次调度点检查。只有 `resched_curr()` 才强制立即抢占。

### proxy-exec 的影响

当前 Linux 支持代理执行（proxy-execution）。`rq->donor->se` 是被调度器选择的实体（真正拥有时间配额），而 `rq->curr->se` 是实际在 CPU 上运行的线程。`update_curr` 操作的是 `cfs_rq->curr`（= `rq->donor->se`），而 `update_se` 在实体是任务时同时更新了 `running->se`（= `rq->curr->se`）。

### 切片到期检查：update_deadline()

（`kernel/sched/fair.c` L1209~1235）

```c
static bool update_deadline(struct cfs_rq *cfs_rq, struct sched_entity *se)
{
    // 如果 vruntime 还没超过 deadline，slice 还没用完
    if (vruntime_cmp(se->vruntime, "<", se->deadline))
        return false;

    // 使用默认基准切片或自定义切片
    if (!se->custom_slice)
        se->slice = sysctl_sched_base_slice;

    // EEVDF：vd_i = ve_i + r_i / w_i
    // ve_i ≈ vruntime（累计虚拟时间就是开始时间）
    // r_i / w_i：物理 slice 按权重缩放为虚拟时间
    se->deadline = se->vruntime + calc_delta_fair(se->slice, se);
    avg_vruntime(cfs_rq);  // 更新加权平均

    return true;  // slice 用完 → 需要重调度
}
```

`calc_delta_fair(slice, se)` = `slice * NICE_0_LOAD / se->load.weight`。nice 0 实体：虚拟切片 = 物理切片。高权重实体虚拟切片更短。

### EEVDF 选择：__pick_eevdf()

（`kernel/sched/fair.c` L1102~1171）

这是 EEVDF 的核心。红黑树按 `deadline` 排序，但还受 eligibility 约束：

```c
static struct sched_entity *__pick_eevdf(struct cfs_rq *cfs_rq, bool protect)
{
    struct rb_node *node = cfs_rq->tasks_timeline.rb_root.rb_node;
    struct sched_entity *se = __pick_first_entity(cfs_rq);  // 最左=最小 deadline
    struct sched_entity *curr = cfs_rq->curr;
    struct sched_entity *best = NULL;

    // 快速路径：只有一个实体
    if (cfs_rq->nr_queued == 1)
        return curr && curr->on_rq ? curr : se;

    // Buddy 提示：如果设置了 next 且 eligible，优先选择
    if (sched_feat(PICK_BUDDY) && protect &&
        cfs_rq->next && entity_eligible(cfs_rq, cfs_rq->next))
        return cfs_rq->next;

    // 当前实体不可选的情况
    if (curr && (!curr->on_rq || !entity_eligible(cfs_rq, curr)))
        curr = NULL;

    // protect_slice：当前实体仍在保护切片内，继续运行
    if (curr && protect && protect_slice(curr))
        return curr;

    // 最左节点（deadline 最小）如果 eligible 直接选择
    if (se && entity_eligible(cfs_rq, se)) {
        best = se;
        goto found;
    }

    // 否则：在红黑树中搜索第一个 eligible 且 deadline 最小的实体
    while (node) {
        struct rb_node *left = node->rb_left;

        // 左子树中可能有更小 deadline 且 eligible 的实体
        if (left && vruntime_eligible(cfs_rq,
                    __node_2_se(left)->min_vruntime)) {
            node = left;
            continue;
        }

        se = __node_2_se(node);
        if (entity_eligible(cfs_rq, se)) {
            best = se;
            break;
        }
        node = node->rb_right;
    }

found:
    // 如果当前实体 deadline 更小（早），选当前实体
    if (!best || (curr && entity_before(curr, best)))
        best = curr;

    return best;
}
```

**树搜索的精妙之处**：
1. 左子树的 `min_vruntime` 权限定该子树的 `vruntime` 下限
2. 如果左子树的 `min_vruntime > V`（通过 `vruntime_eligible` 检查），左子树整体不可调度，无需进入
3. 这保证搜索是 O(log n) 的，因为 eligibility 剪枝避免了全树遍历

### 滞后计算：entity_lag + update_entity_lag

（`kernel/sched/fair.c` L832~870）

注意：`update_entity_lag()` **不**在 `update_curr()` 中调用，而是在 enqueue/dequeue 路径中调用。

```c
static s64 entity_lag(struct cfs_rq *cfs_rq, struct sched_entity *se, u64 avruntime)
{
    u64 max_slice = cfs_rq_max_slice(cfs_rq) + TICK_NSEC;
    s64 vlag = avruntime - se->vruntime;     // vl_i = V - v_i
    s64 limit = calc_delta_fair(max_slice, se);

    return clamp(vlag, -limit, limit);       // 夹在 [-limit, +limit] 内
}
```

`entity_lag()` 将滞后限制在 `[-max_slice_weighted, +max_slice_weighted]` 范围内，防止极端情况下的不公平累积。

```c
static __always_inline
bool update_entity_lag(struct cfs_rq *cfs_rq, struct sched_entity *se)
{
    s64 vlag = entity_lag(cfs_rq, se, avg_vruntime(cfs_rq));

    // sched_delayed（延迟 dequeue）的实体滞后不能增加
    if (se->sched_delayed) {
        vlag = max(vlag, se->vlag);      // 只缩小不过期
        if (sched_feat(DELAY_ZERO))
            vlag = min(vlag, 0);         // 负滞后清零
    }
    se->vlag = vlag;
    ...
}
```

**延迟 dequeue**（`sched_delayed`）是 Linux 7.0 的新特性：被 dequeue 的实体不立即移出运行队列，而是标记为 `sched_delayed` 并在一定时间内保持在树中。期间，其滞后不增长（正滞后被截断），等待其他处理。

### 切片保护：protect_slice

（`kernel/sched/fair.c` L1050~1085）

```c
// 设置 vprot = deadline（初始）
// 如果存在 RUN_TO_PARITY 特性，vprot = min(vruntime + min_slice, deadline)
static inline void set_protect_slice(struct cfs_rq *cfs_rq, struct sched_entity *se)
{
    u64 slice = normalized_sysctl_sched_base_slice;
    u64 vprot = se->deadline;

    if (sched_feat(RUN_TO_PARITY))
        slice = cfs_rq_min_slice(cfs_rq);

    slice = min(slice, se->slice);
    if (slice != se->slice)
        vprot = min_vruntime(vprot, se->vruntime + calc_delta_fair(slice, se));

    se->vprot = vprot;
}

// 保护切片检查
static inline bool protect_slice(struct sched_entity *se)
{
    return vruntime_cmp(se->vruntime, "<", se->vprot);
    // 等价于：vruntime < vprot → 仍在保护期内
}
```

**保护切片的作用**：即使新实体有更早的 deadline，当前实体如果仍在保护期内（`vruntime < vprot`），也不会被抢占。防止运行时间过短的上下文切换。

### 滞后保留：place_entity

（`kernel/sched/fair.c` L5352~5420）

当实体从睡眠中醒来时，`place_entity()` 使用 lag 保留算法：

```c
static void place_entity(struct cfs_rq *cfs_rq, struct sched_entity *se, int flags)
{
    u64 avruntime = avg_vruntime(cfs_rq);
    s64 lag = 0;

    // 如果有 vlag（之前运行过），保留 lag
    if (sched_feat(PLACE_LAG) && cfs_rq->nr_queued && se->vlag) {
        lag = se->vlag;
        // 调整：新实体加入会改变加权平均 V 值
        // 需要膨胀 lag 以补偿加权平均的偏移
        // 数学公式见内核注释
        ...
        se->vruntime = avruntime - lag;
    } else {
        // 新创建的实体：从 V 出发
        se->vruntime = avruntime;
    }

    // 设置初始 deadline
    se->deadline = se->vruntime + calc_delta_fair(se->slice, se);
}
```

lag 保留的数学原理（摘自内核注释）：

```
V' = V - w_i × vl_i / (W + w_i)

加入新实体后，V 会偏移。为了让实际 lag 等于期望的 vl_i，
需要在加入前将 vl_i 膨胀：
  vl_i (inflated) > vl_i (target)
  
结果：加入后有效 lag = vl_i (target)
```

## 实体状态机

```
                 enqueue_task_fair()
                    (从不运行→就绪)
[TASK_NEW/SLEEP] ──────────────→ [ACTIVE (on_rq=1, sched_delayed=0)]
     ↑                                   │
     │                            pick_eevdf() 选择
     │                                   │
     │                                   ↓
     │                              [RUNNING]
     │                                   │
     │                            schedule() 被抢占
     │                                   │
     │                    ┌──────────────┴──────────────┐
     │                    │ preempt                     │ sleep
     │                    ↓                             │
     │              [ACTIVE (on_rq=1)]                  │
     │                    │                             │
     │         dequeue_task_fair()                      │
     │         (DEQUEUE_DELAYED)                        │
     │                    │              dequeue_task_fair(DEQUEUE_SLEEP)
     │                    ↓                             │
     │              [DELAYED (on_rq=1,                  │
     │               sched_delayed=1)]                  │
     │                    │                             │
     │         re-enqueue                               │
     │                    │                             │
     └────────────────────┘                             │
                     (ACTIVE → RUNNING)                 │
                                                        │
                        wakeup → enqueue_task_fair() ───┘
```

`DELAYED` 状态是新引入的：实体仍在 `cfs_rq` 上（`on_rq=1`）但标记为 `sched_delayed`，`pick_eevdf` 跳过它。这允许在延迟 period 内调整 lag 而不丢失队列位置。

## 抢占判定

在 tick 处理和唤醒时的抢占判定不同：

```c
// entity_tick() — 周期 tick 触发
// 在 update_curr() 中处理：
//   if (resched || !protect_slice(curr))
//       resched_curr_lazy(rq)

// wakeup_preempt — 唤醒时
// 通过 __pick_eevdf(cfs_rq, preempt_action) 判断
// 如果唤醒实体被 __pick_eevdf 选中 → 抢占
```

抢占判定严格遵循 EEVDF：只有 deadline 更早且 eligible 的实体才能抢占当前实体，且当前实体有保护切片豁免。

## 设计特点

### 与 CFS 的差异

| 维度 | CFS | EEVDF |
|------|-----|-------|
| 选择标准 | min vruntime | EEVDF（eligibility + deadline） |
| 公平度量 | vruntime 差值的近似 | vlag 精确计算 |
| 切片 | 动态（sched_slice） | 固定基准（可自定义） |
| 保护 | wakeup/preempt 粒度 | protect_slice（最小执行时间） |
| 滞后 | 无显式概念 | vlag + entity_lag 夹持 |
| 延迟 dequeue | 无 | sched_delayed 状态 |
| proxy-exec | 不支持 | rq->donor vs rq->curr |
| 抢占信号 | resched_curr | resched_curr_lazy（懒模式） |

### 性能特性

- **切片保护减少上下文切换**：高频 tick 下，短运行实体不会反复被抢占
- **eligibility 约束消除 CFS 的"偷跑"问题**：CFS 中 vruntime 最小的实体被选择，但新唤醒实体的 lag 补偿可能不准确
- **vlag 夹持防止滞后无限增长**：`[-max_slice_weighted, +max_slice_weighted]` 限制了极端场景
- **懒抢占（TIF_NEED_RESCHED_LAZY）** 延迟抢占决策，减少调度器调用次数

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct sched_entity` | include/linux/sched.h | 575 |
| `struct cfs_rq` | kernel/sched/sched.h | 678 |
| `update_se()` | kernel/sched/fair.c | 1324 |
| `update_curr()` | kernel/sched/fair.c | 1378 |
| `update_deadline()` | kernel/sched/fair.c | 1209 |
| `__pick_eevdf()` | kernel/sched/fair.c | 1102 |
| `pick_eevdf()` | kernel/sched/fair.c | 1173 |
| `entity_eligible()` | kernel/sched/fair.c | 905 |
| `vruntime_eligible()` | kernel/sched/fair.c | 889 |
| `entity_lag()` | kernel/sched/fair.c | 832 |
| `update_entity_lag()` | kernel/sched/fair.c | 852 |
| `avg_vruntime()` | kernel/sched/fair.c | 676 附近 |
| `protect_slice()` | kernel/sched/fair.c | 1072 |
| `set_protect_slice()` | kernel/sched/fair.c | 1050 |
| `place_entity()` | kernel/sched/fair.c | 5351 |
| `entity_tick()` | kernel/sched/fair.c | 5792 |
| `pick_next_entity()` | kernel/sched/fair.c | 5751 |
| `enqueue_task_fair()` | kernel/sched/fair.c | 7167 |
| `dequeue_task_fair()` | kernel/sched/fair.c | 7402 (2nd def) |
| `sysctl_sched_base_slice` | kernel/sched/fair.c | (全局) |
| `calc_delta_fair()` | kernel/sched/fair.c | (内联) |
| `entity_before()` | kernel/sched/fair.c | 589 |
| `entity_key()` | kernel/sched/fair.c | 附近 |
