# 182-sched_entity — CFS调度实体深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/sched/fair.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**sched_entity** 是 CFS（Completely Fair Scheduler）的调度实体，每个 task_struct 都有一个 sched_entity，代表其在 CPU 上的调度单元。

---

## 1. struct sched_entity

```c
// include/linux/sched/sched.h — sched_entity
struct sched_entity {
    // 负载
    struct load_weight      load;               // 权重
    u64                   exec_start;           // 上次执行时间
    u64                   sum_exec_runtime;     // 总执行时间
    u64                   vruntime;             // 虚拟运行时间（CFS 核心）
    u64                   prev_sum_exec_runtime; // 上次累计执行

    // 树节点
    struct rb_node          run_node;            // 红黑树节点

    // 层级
    unsigned int           on_rq:1;             // 是否在就绪队列

    // 组调度
    struct sched_entity   *parent;             // 父实体（组调度）
    struct cfs_rq          *cfs_rq;           // 所属 CFS 就绪队列
};
```

---

## 2. vruntime（虚拟运行时间）

```
CFS 核心思想：每个实体按 vruntime 排序，vruntime 越小，越优先执行

vruntime 计算：
  vruntime += delta_exec * (NICE_0_LOAD / load)
  - delta_exec = 实际执行时间
  - load = 调度实体权重

优先级影响：
  nice -20 → weight 大 → vruntime 增长慢 → 更多 CPU
  nice +19 → weight 小 → vruntime 增长快 → 更少 CPU
```

---

## 3. 实体入队/出队

### 3.1 enqueue_entity

```c
// kernel/sched/fair.c — enqueue_entity
void enqueue_entity(struct cfs_rq *cfs_rq, struct sched_entity *se, int flags)
{
    // 1. 更新执行时间
    update_curr(cfs_rq);

    // 2. 更新 vruntime
    place_entity(cfs_rq, se, 0);

    // 3. 加入红黑树（按 vruntime 排序）
    __enqueue_entity(cfs_rq, se);
    se->on_rq = 1;

    // 4. 更新负载
    update_load_avg(cfs_rq, se);
}
```

---

## 4. pick_next_entity

```c
// kernel/sched/fair.c — pick_next_entity
struct sched_entity *pick_next_entity(struct cfs_rq *cfs_rq)
{
    // 从红黑树最左节点（最小 vruntime）
    struct rb_node *left = cfs_rq->tasks_timeline.rb_node;
    struct sched_entity *se = rb_entry(left, struct sched_entity, run_node);
    return se;
}
```

---

## 5. 权重与 NICE 值

```
NICE 值与权重：
  nice -20: weight = 1024 * 1.2^20 ≈ 62761
  nice   0: weight = 1024
  nice +19: weight = 1024 / 1.2^19 ≈ 33

权重影响：
  高优先级（nice -20）：weight 大 → vruntime 增长慢 → 获得更多 CPU 时间
  低优先级（nice +19）：weight 小 → vruntime 增长快 → 获得更少 CPU 时间
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/sched/fair.c` | `enqueue_entity`、`pick_next_entity`、`update_curr` |
| `include/linux/sched/sched.h` | `struct sched_entity` |

---

## 7. 西游记类喻

**sched_entity** 就像"取经队伍的沙漏"——

> CFS 的调度就像一个精确的沙漏，每个妖怪（sched_entity）有一个沙漏（vruntime）。沙漏装满（vruntime 累积到一定程度），就要让位给沙漏更空的妖怪。每个妖怪的沙漏流速由权重决定——级别高的妖怪（nice -20）沙漏流得慢，所以同样的时间后沙漏还比较满；级别低的妖怪（nice +19）沙漏流得快，很快就要让位。这就是"公平调度"——每个妖怪消耗的沙漏时间是一样的，但优先级决定了沙漏的流速。

---

## 8. 关联文章

- **CFS**（article 37）：CFS 调度器
- **pick_next_task**（相关）：CFS 选择下一个调度实体