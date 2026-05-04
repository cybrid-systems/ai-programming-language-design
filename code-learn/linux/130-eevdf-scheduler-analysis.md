# Linux EEVDF 调度器深度分析

## 概述

EEVDF（Earliest Eligible Virtual Deadline First）是 Linux 6.6 引入的调度器，替代了使用了近 20 年的 CFS（Completely Fair Scheduler）。EEVDF 由 Peter Zijlstra 实现，基于学术论文 "Earliest Eligible Virtual Deadline First: A Flexible and Accurate Mechanism for Proportional Share Resource Allocation"（Stoica et al., 1996）。

EEVDF 与 CFS 的核心区别：

| 特性 | CFS (O(1)/BFS tree) | EEVDF (since Linux 6.6) |
|------|---------------------|-------------------------|
| 选择标准 | min vruntime（最小虚拟运行时间） | eligibility + deadline（最小截止时间） |
| 调度切片 | `sched_slice()` 动态计算 | `sysctl_sched_base_slice` 固定基准（~3ms） |
| 权重更新 | 仅影响 next slice 分配 | 实时调整 lag + 重算 deadline |
| 保护机制 | buddy 提示（next/last） | `protect_slice()` — 最小执行时间保护 |
| 延迟跟踪 | 无需 lag 计算 | `vlag`（virtual lag）精确量化不公平度 |
| 唤醒抢占比 | `wakeup_preempt_entity` vruntime 比较 | `entity_eligible()` + deadline 比较 |

## 核心数据结构

### sched_entity — EEVDF 关键字段

（`include/linux/sched.h` L575~611）

```c
struct sched_entity {
    struct load_weight  load;           // L577 — 权重（nice 值）
    struct rb_node      run_node;       // L578 — EEVDF 红黑树节点（按 deadline 排序）
    u64                 deadline;       // L579 — 虚拟截止时间（EEVDF 选择依据）
    u64                 min_vruntime;   // L580 — 子实体最小 vruntime（用于 group 调度）
    u64                 min_slice;      // L581 — 最小切片（近似 1ms）
    u64                 max_slice;      // L582 — 最大切片（约 100ms）
    struct list_head    group_node;     // L584 — group 链表节点
    unsigned char       on_rq;          // L585 — 是否在运行队列中
    unsigned char       sched_delayed;  // L586 — 是否延迟 dequeued
    unsigned char       rel_deadline;   // L587 — 截止时间是否相对
    unsigned char       custom_slice;   // L588 — 是否自定义切片（sched_setattr）
    u64                 exec_start;     // L591 — 当前执行开始时间
    u64                 sum_exec_runtime; // L592 — 总执行时间
    u64                 prev_sum_exec_runtime; // L593 — 上次统计的总执行时间
    u64                 vruntime;       // L594 — 虚拟运行时间
    s64                 vlag;           // L596 — 虚拟滞后（lag = 实际服务 - 应得服务）
    u64                 vprot;          // L598 — 保护截止时间（protected deadline）
    u64                 slice;          // L599 — 调度切片（请求时间 r_i）
    u64                 nr_migrations;  // L601 — 跨 CPU 迁移次数
    ...
};
```

**EEVDF 特有字段**（对比 CFS 的新增或语义变化）：

- `deadline`：替代 CFS 的 vruntime-min 选择标准。每次 slice 用完时计算 `deadline = vruntime + r_i / w_i`
- `vlag`：虚拟滞后，正值表示欠服务（eligible），负值表示过服务（欠其他实体）
- `vprot`：保护截止时间，确保刚唤醒的实体至少有 `min_slice` 的执行时间
- `min_slice` / `max_slice`：每个实体在其组权重下的最小/最大切片约束
- `custom_slice`：通过 `sched_setattr` 设置的自定义切片（SCHED_FLAG_DSQ_*）
- `sched_delayed`：新标志——调度延迟时实体保持 `on_rq=1` 但不在红黑树中

### cfs_rq — CFS 运行队列

（`kernel/sched/sched.h` L678~）

```c
struct cfs_rq {
    struct load_weight  load;           // L679
    unsigned int        nr_queued;      // L680 — 排队实体数
    unsigned int        h_nr_queued;    // L681 — SCHED_NORMAL/BATCH/IDLE
    unsigned int        h_nr_runnable;  // L682 — 可运行计数
    unsigned int        h_nr_idle;      // L683 — SCHED_IDLE 计数
    s64                 sum_w_vruntime; // L685 — 加权平均 vruntime 的分子
    u64                 sum_weight;     // L686 — 加权平均 vruntime 的分母
    u64                 zero_vruntime;  // L787 — 平均值的基准偏移
    unsigned int        sum_shift;      // L788 — 精度调整参数
    struct rb_root_cached tasks_timeline; // L695 — EEVDF 红黑树（按 deadline 排序）
    struct sched_entity *curr;          // 当前运行的实体
    struct sched_entity *next;          // 下一个候选（buddy 提示）
    ... // PELT 相关字段
};
```

EEVDF 的 `tasks_timeline` 是按 **虚拟截止时间（deadline）** 排序的（CFS 按 vruntime）。红黑树的最小节点是 deadline 最小的实体。

`sum_w_vruntime`、`sum_weight` 和 `zero_vruntime` 用于计算加权平均 vruntime，这是 eligibility 判定的数学基础。

## EEVDF 调度算法详解

### 理论基础

EEVDF 的核心数学概念：

```
每个实体 i 的参数：
  w_i    — 权重（从 nice 值映射）
  r_i    — 请求时间（slice，由 sysctl_sched_base_slice 控制）
  ve_i   — 虚拟开始时间（virtual eligible time）
  vd_i   — 虚拟截止时间（virtual deadline time）

关系：
  vd_i = ve_i + r_i / w_i

滞后（lag）定义：
  lag_i = 服务_i - 应得服务 = w_i × (V - v_i)
  
  其中 V = 加权平均 vruntime（avg_vruntime）
        v_i = 实体的 vruntime

Eligibility 条件：
  lag_i >= 0   ↔   V >= v_i   ↔   实体获得的服务不超过它应得的
  
  换句话说：只有"欠服务"的实体才有资格被调度
```

### 算法流程

```
1. 调度 tick 到来（entity_tick / update_curr）
   └─ update_curr(cfs_rq)
        └─ 更新 exec_start / sum_exec_runtime / vruntime
        └─ update_deadline(cfs_rq, curr)
             │ 如果 vruntime >= deadline（slice 用完）:
             │   └─ 设置新 deadline: vd = vruntime + r_i / w_i
             │   └─ 返回 true (需要重调度)
             │ 否则:
             │   └─ 返回 false (继续运行)
             
2. 需要调度时（__schedule）
   └─ pick_next_task_fair()
        └─ pick_next_entity(rq, cfs_rq)
             └─ pick_eevdf(cfs_rq)
                  └─ __pick_eevdf(cfs_rq, protect=true)

3. __pick_eevdf 的选择逻辑
   a. 单实体快速路径：nr_queued == 1，直接返回
   
   b. Buddy 提示（next）优先：如果设置了 next 且 eligible
   
   c. 执行中实体保护：如果 curr 正在运行且未用完保护切片
      (protect_slice())，留在 CPU 上

   d. 红黑树搜索：
      1) 取最左节点（deadline 最小）
      2) 检查 eligibility：如果最左节点不可调度
         → 搜索右子树，找到第一个 eligible 的 deadline 最小实体
      3) eligibility 通过 avg_vruntime 检查：
         avg_vruntime 的含义：所有实体 vruntime 的加权平均
         一个实体 "eligible" 当且仅当它的 vruntime ≤ 加权平均
         
   e. 比较 curr 和 best：选 deadline 更小的
```

### 直方图搜索算法

`__pick_eevdf` 中的红黑树搜索是 EEVDF 的核心创新：

```
    root
    /   \
 left   right

从根节点开始，depth-first：
1. 如果 left 子树存在且 vruntime_eligible(left 子树中最小 vruntime)：
   → 进入 left（left 中 deadline 最小的实体一定可调度）
   
2. 否则检查当前节点：
   → 如果 entity_eligible(当前节点) → 这是最佳选择（best found）
   
3. 否则进入 right 子树

这个搜索保证找到 deadline 最小且 eligible 的实体，
搜索复杂度 O(log n)，最坏情况 O(n) 但极少达到。
```

## 关键执行路径

### update_curr() — 时间簿记

（`kernel/sched/fair.c` 附近）

```c
static void update_curr(struct cfs_rq *cfs_rq)
{
    struct sched_entity *curr = cfs_rq->curr;
    u64 now = rq_clock_task(rq_of(cfs_rq));
    u64 delta_exec;

    if (unlikely(!curr))
        return;

    delta_exec = now - curr->exec_start;
    if (unlikely(!delta_exec))
        return;

    curr->exec_start = now;
    curr->sum_exec_runtime += delta_exec;

    // 按权重更新 vruntime
    curr->vruntime += calc_delta_fair(delta_exec, curr);

    update_entity_lag(cfs_rq, curr);   // 更新 vlag
    update_deadline(cfs_rq, curr);      // 检查 slice 是否用完

    update_cfs_group(curr);
    // ...
}
```

注意：`update_entity_lag()` 在每次更新 vruntime 后调整 vlag，确保 lag 反应当前的公平度。

### update_deadline() — 截止时间重新计算

（`kernel/sched/fair.c` L1209~1235）

```c
static bool update_deadline(struct cfs_rq *cfs_rq, struct sched_entity *se)
{
    // 如果 vruntime 还没超过 deadline，继续运行
    if (vruntime_cmp(se->vruntime, "<", se->deadline))
        return false;

    // 计算新 slice（默认 sysctl_sched_base_slice ≈ 3ms）
    if (!se->custom_slice)
        se->slice = sysctl_sched_base_slice;

    // EEVDF 核心：vd_i = ve_i + r_i / w_i
    // ve_i ≈ vruntime（实体累积到当前已经使用了的虚拟时间就是它的开始时间）
    se->deadline = se->vruntime + calc_delta_fair(se->slice, se);
    avg_vruntime(cfs_rq);  // 更新加权平均 vruntime

    return true;  // slice 用完，需要重调度
}
```

`calc_delta_fair(slice, se)` 将物理时间按权重缩放到虚拟时间：

```
calc_delta_fair(slice, se) = slice * NICE_0_LOAD / se->load.weight
```

其中 `NICE_0_LOAD = 1024`（nice 0 的默认权重）。所以 nice = 0 的实体：虚拟切片 = 物理切片。权重更高的（nice 值更小）拥有更短的虚拟切片。

### protect_slice() — 最小执行时间保护

（`kernel/sched/fair.c` 附近）

```c
static bool protect_slice(struct sched_entity *se)
{
    u64 delta = se->sum_exec_runtime - se->prev_sum_exec_runtime;

    // 如果当前实体的执行时间还没达到 min_slice，它应该继续运行
    return delta < se->min_slice;
}
```

避免了频繁上下文切换：一个实体必须至少执行 `min_slice`（通常约 1ms）才能被抢占。这解决了 CFS 在某些工作负载下调度抖动的问题。

### place_entity() — 新实体的初始位置

当新进程创建或从睡眠中唤醒时，需要为其计算初始 vruntime、deadline 和 vlag：

```c
static void place_entity(struct cfs_rq *cfs_rq, struct sched_entity *se, int flags)
{
    u64 vruntime = avg_vruntime(cfs_rq);

    // 新创建的进程：从当前平均开始
    se->vruntime = vruntime;
    
    // 唤醒的进程：补偿睡眠时间
    if (flags & ENQUEUE_WAKEUP) {
        // vlag 调整：睡眠期间不积累 lag
        se->vlag = ...;
        se->vruntime = vruntime - se->vlag;
    }

    // 设置初始 deadline
    se->deadline = se->vruntime + calc_delta_fair(se->slice, se);
}
```

新创建的进程从 `avg_vruntime` 开始（不是像 CFS 那样从当前 `cfs_rq->min_vruntime` 减去一定值），这使得新进程立即拥有正常的调度优先级。

## 抢占与唤醒

### 唤醒抢占判定

（`kernel/sched/fair.c` L8961~9155 附近）

当运行队列上的实体被新唤醒的实体抢占时，由 `wakeup_preempt_entity()` 判定：

```c
// 简化逻辑
bool should_preempt(struct cfs_rq *cfs_rq, struct sched_entity *curr, 
                    struct sched_entity *pse)
{
    // 如果 pse（唤醒实体）不是 eligible → 不抢占
    if (__pick_eevdf(cfs_rq, preempt_action != PREEMPT_WAKEUP_SHORT) != pse)
        return false;
    
    // 检查 curr 的 deadline 是否比 pse 更晚
    // 如果没有保护切片，抢占
    return !protect_slice(curr) || curr->deadline > pse->deadline;
}
```

EEVDF 的抢占判定比 CFS 更严格：
1. 唤醒实体必须 eligible（欠服务的才能抢占）
2. 当前实体必须已用完保护切片，或 deadline 确实更晚

### buddy 机制

EEVDF 保留了 CFS 的 buddy 提示，但语义简化：

```c
// PICK_BUDDY feature 控制
if (sched_feat(PICK_BUDDY) && protect &&
    cfs_rq->next && entity_eligible(cfs_rq, cfs_rq->next)) {
    return cfs_rq->next;
}
```

`cfs_rq->next` 由 `set_next_buddy()` 设置，通常指示"哪个实体应该接下来运行"。这在 yield 和某些组调度场景中使用。

## 从 CFS 到 EEVDF 的变化

### 变化一：选择标准

| 标准 | CFS | EEVDF |
|------|-----|-------|
| 红黑树排列 | 按 vruntime | 按 deadline |
| 选择 | 最左节点（最小 vruntime） | 最小 deadline 且 eligible |
| 唤醒抢占 | vruntime 比较 | eligibility + deadline 比较 |

### 变化二：buddy 系统简化

CFS 有 `next`/`last`/`skip` 三个 buddy，EEVDF 大幅简化：
- `skip` 被移除
- `next` 的功能保留但仅生效于 `PICK_BUDDY` 特性启用时
- `last` 效果通过 `protect_slice()` 自然实现

### 变化三：调频接口统一

EEVDF 与 `schedutil` 调频器协作更紧密，`update_deadline()` 返回的调度信号被调频器用来预测 CPU 需求。

### 变化四：sched_delayed 机制

新引入的 `sched_delayed` 状态介于 `on_rq=1` 和 `on_rq=0` 之间：

```
状态迁移：
  ACTIVE  → DELAYED (dequeue delayed)
  DELAYED → ACTIVE  (re-enqueue)
  DELAYED → SLEEP   (dequeue sleep → on_rq=0)
```

`sched_delayed` 意味着实体的 vruntime 已更新但资源仍在清理中（例如，上下文切换的开销尚未完全计入）。EEVDF 的 `pick_next_entity` 会跳过 `sched_delayed` 的实体，返回 NULL 让调度器选择其他实体。

## EEVDF 参数调优

### 可调参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `sysctl_sched_base_slice` | 3ms（桌面）/ 6ms（服务器） | 基准时间片 |
| `sysctl_sched_min_granularity` | 0.75ms | 最小调度粒度 |
| `sysctl_sched_wakeup_granularity` | 1.0ms | 唤醒抢占粒度 |
| `sysctl_sched_migration_cost` | 500μs | 迁移成本预估 |
| `sysctl_sched_nr_migrate` | 32 | 负载均衡单次迁移数 |

### 可通过 sched_setattr 设置的 per-task 参数

```c
struct sched_attr {
    u32 size;
    u32 sched_policy;          // SCHED_OTHER / SCHED_BATCH / SCHED_IDLE
    u64 sched_flags;           // SCHED_FLAG_CUSTOM_SLICE 等
    s32 sched_nice;            // nice 值（-20~19）
    u32 sched_priority;        // RT 优先级
    u64 sched_runtime;         // 自定义 slice（ns）
    u64 sched_deadline;        // deadline 参数（DEADLINE 调度）
    u64 sched_period;          // period 参数（DEADLINE 调度）
};
```

通过 `SCHED_FLAG_CUSTOM_SLICE` 可以为特定进程设置非默认时间片。

## 与 CFS 的性能对比

EEVDF 学术论文和内核测试报告的主要发现：

1. **延迟更可预测**：通过 slice 保护（`protect_slice`），交互式任务响应更稳定
2. **调度抖动减少**：最小执行时间保护减少了短时间内的上下文切换次数（~10% reduction）
3. **公平性量化**：vlag 提供了精确的公平度量，而不是 CFS 的近似
4. **突发负载改善**：EEVDF 的 eligibility 约束避免了 CFS 中"偷跑"问题

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct sched_entity` | include/linux/sched.h | 575 |
| `struct cfs_rq` | kernel/sched/sched.h | 678 |
| `__pick_eevdf()` | kernel/sched/fair.c | 1102 |
| `pick_eevdf()` | kernel/sched/fair.c | 1173 |
| `entity_eligible()` | kernel/sched/fair.c | 905 |
| `vruntime_eligible()` | kernel/sched/fair.c | 889 |
| `update_deadline()` | kernel/sched/fair.c | 1209 |
| `update_entity_lag()` | kernel/sched/fair.c | ~860 |
| `entity_lag()` | kernel/sched/fair.c | ~830 |
| `protect_slice()` | kernel/sched/fair.c | 附近 |
| `place_entity()` | kernel/sched/fair.c | 附近 |
| `avg_vruntime()` | kernel/sched/fair.c | ~800 |
| `update_curr()` | kernel/sched/fair.c | 附近 |
| `entity_tick()` | kernel/sched/fair.c | 5793 |
| `pick_next_entity()` | kernel/sched/fair.c | 5752 |
| `enqueue_task_fair()` | kernel/sched/fair.c | 7168 |
| `dequeue_task_fair()` | kernel/sched/fair.c | 5981 |
| `sysctl_sched_base_slice` | kernel/sched/fair.c | (全局) |
| `sched_setattr()` syscall | kernel/sched/syscalls.c | 附近 |
