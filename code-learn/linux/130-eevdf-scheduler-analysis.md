# 130-eevdf — 读 kernel/sched/fair.c 的 EEVDF 实现

CPU 调度器是 Linux 内核中最常被误解的子系统之一。不是因为它太难，而是因为关于它的文章往往引用论文而非代码。本文只从 `kernel/sched/fair.c` 出发。

---

## avg_vruntime——EEVDF 的数学基础

（`kernel/sched/fair.c` L780）

EEVDF 的 eligiblity 判定的核心是**加权平均虚拟运行时间** V：

```
V = (Σ w_i * v_i) / (Σ w_i) = sum_w_vruntime / sum_weight
```

在代码中：

```c
u64 avg_vruntime(struct cfs_rq *cfs_rq)
{
    long weight = cfs_rq->sum_weight;         // Σ w_i
    s64 runtime = cfs_rq->sum_w_vruntime;     // Σ w_i * (v_i - zero_vruntime) + 当前实体修正

    if (curr) {  // 当前运行实体有一个特殊修正
        runtime += entity_key(cfs_rq, curr) * avg_vruntime_weight(cfs_rq, curr->load.weight);
        weight += avg_vruntime_weight(cfs_rq, curr->load.weight);
    }

    return div_s64(runtime, weight);          // V = sum / weight
}
```

但文件头注释指出："avg_vruntime() + 0 must result in entity_eligible() := true"——这句话的意思是：**如果一个实体的 vruntime 恰好等于 V，它必须是 eligible 的**。校验这个条件是 `vruntime_eligible()` 的出发点。

```c
int entity_eligible(struct cfs_rq *cfs_rq, struct sched_entity *se)
{
    // v_i <= V  ↔  lag_i >= 0  ↔  eligible
    return vruntime_eligible(cfs_rq, se->vruntime);
}
```

"Lag"（滞后）定义为：

```
lag_i = w_i * (V - v_i)
```

lag >= 0 表示欠服务（eligible），lag < 0 表示过服务（不应被调度）。

---

## protect_slice——保护机制的真实语义

（`kernel/sched/fair.c` L1050）

我之前的文章将 `protect_slice` 描述为"最小执行时间保护"，这是错的。实际代码：

```c
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

static inline bool protect_slice(struct sched_entity *se)
{
    return vruntime_cmp(se->vruntime, "<", se->vprot);
}
```

`vprot` 是 `deadline` 和 `vruntime + min_slice_weighted` 中的较小者。保护的含义是：**当前实体的 vruntime 还没到达 vprot，就还不能被抢占**。这不保证运行了多长时间，只保证它的 vruntime 不超过 deadline（除非 slice 被缩短了）。

`update_protect_slice` 在 tick 中更新这个值——每次 tick 都会将 vprot 向前推进 `min_slice` 的虚拟时间量，直到追上 deadline。

---

## __pick_eevdf——选择算法

（`kernel/sched/fair.c` L1102）

红黑树按 deadline 排序。但 eligible 的实体可能不是 deadline 最早的——一个 deadline 很晚但 lag 很大的实体可能比一个 deadline 较早但 lag 为负的实体更值得被调度。

算法：

```c
// 1. 快速路径：只有一个实体 → 直接返回
if (cfs_rq->nr_queued == 1)
    return curr && curr->on_rq ? curr : se;

// 2. Buddy 提示（PICK_BUDDY 特性）：
//    如果 cfs_rq->next 被设置了且 eligible，优先返回
if (sched_feat(PICK_BUDDY) && protect && entity_eligible(cfs_rq, cfs_rq->next))
    return cfs_rq->next;

// 3. 当前实体保护：仍在保护期内 → 返回当前实体
if (curr && protect && protect_slice(curr))
    return curr;

// 4. 遍历红黑树：
//    取最左节点（deadline 最小）
//    check entity_eligible()
//    如果不 eligible → 搜索右子树
//    利用 min_vruntime 增强字段剪枝：
//      如果左子树的 min_vruntime > V，整个左子树都不 eligible
```

第 4 步利用了增强红黑树（augmented rbtree）的特性。每个节点维护了其子树中的 `min_vruntime`。通过这个增强字段，`__pick_eevdf` 避免了全树遍历——如果左子树的整体最小 vruntime 都大于 V，左子树中不可能有 eligible 的实体。

---

## update_se——时间会计

（`kernel/sched/fair.c` L1324）

```c
static s64 update_se(struct rq *rq, struct sched_entity *se)
{
    delta_exec = now - se->exec_start;
    se->exec_start = now;

    if (entity_is_task(se)) {
        // proxy-exec 支持：running 和 donor 可能不同
        running->se.exec_start = now;
        running->se.sum_exec_runtime += delta_exec;
    }
    return delta_exec;
}
```

`proxy-exec` 的注释 "running 和 donor 可能不同" 说明这不是普通的上下文切换——当一个任务为另一个任务代理执行时（priority inheritance 的极端情况），被代理的 donor 拥有 CPU 时间，但实际在 CPU 上跑的是 running。

---

## 总结

| 概念 | 代码位置 | 实意 |
|------|---------|------|
| avg_vruntime | L780 | 加权平均 vruntime，一个 tick 滞后 |
| entity_eligible | L905 | vruntime <= V |
| entity_lag | L832 | V - vruntime，限制在 ±max_slice 内 |
| set_protect_slice | L1050 | vprot = min(deadline, vruntime + min_slice) |
| __pick_eevdf | L1102 | 增强红黑树 + eligibility 剪枝 |
| update_se | L1324 | 物理时间会计，支持 proxy-exec |
| update_deadline | L1209 | vruntime + slice/weight |
