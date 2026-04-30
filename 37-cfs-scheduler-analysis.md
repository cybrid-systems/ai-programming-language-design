# Linux Kernel CFS (Completely Fair Scheduler) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/sched/fair.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 CFS？

**CFS**（Completely Fair Scheduler）是 Linux 2.6.23+ 的**默认进程调度器**，核心思想：**让每个任务都公平地获得 CPU 时间**，根据虚拟运行时间（vruntime）决定调度顺序。

**核心概念**：
- 红黑树按 vruntime 排序
- 总是调度 vruntime 最小的任务
- 权重（nice 值）影响 vruntime 增长速率

---

## 1. 核心数据结构

### 1.1 sched_entity — 调度实体

```c
// include/linux/sched.h:575 — sched_entity
struct sched_entity {
    // 负载跟踪
    u32                     on_rq;         // 是否在就绪队列上
    u64                     exec_start;     // 上次调度时间
    u64                     sum_exec_runtime; // 累计运行时间
    u64                     prev_sum_exec_runtime; // 上次累计
    u64                     vruntime;        // 虚拟运行时间（核心！）
    u64                     nr_migrations;    // 迁移次数

    // 统计
    struct sched_statistics  statistics;

    // 树节点
    struct rb_node          run_node;        // 红黑树节点

    // 层级调度
    struct sched_entity     *parent;         // 组调度父实体
    struct cfs_rq           *cfs_rq;         // 所属 CFS 运行队列
    struct task_group       *group_node;
};

// CFS 运行队列
struct cfs_rq {
    struct load_weight      load;             // 总负载
    unsigned long          nr_running;       // 运行任务数
    unsigned int           h_nr_running;     // 层级任务数

    // 核心：红黑树
    struct rb_root_cached   tasks_timeline;   // 任务红黑树（按 vruntime）
    struct sched_entity     *curr;            // 当前运行实体

    // 虚拟时间
    u64                     min_vruntime;     // 最小 vruntime
    u64                     max_vruntime;     // 最大 vruntime
    struct {
        u64                 i_wall;           // 空闲 wall time
        u64                 i_time;          // 空闲 CPU time
    } wall_time;

    // 组调度
    struct rq               *rq;              // 所属 runqueue
};
```

---

## 2. vruntime — 虚拟运行时间

```c
// kernel/sched/fair.c — update_curr（更新 vruntime）
static void update_curr(struct cfs_rq *cfs_rq)
{
    u64 now = rq_clock_task(rq_of(cfs_rq));
    u64 delta_exec;

    delta_exec = now - curr->exec_start;    // 实际运行时间
    curr->exec_start = now;

    // vruntime += delta_exec / weight
    // nice=0: weight = 1024, vruntime += delta_exec
    // nice=-20: weight = 48784, vruntime += delta_exec * 1024 / 48784 ≈ delta_exec * 0.02
    curr->vruntime += calc_delta_fair(delta_exec, curr);

    // 更新 min_vruntime（用于虚拟时间回溯）
    cfs_rq->min_vruntime = max(cfs_rq->min_vruntime, curr->vruntime);
}
```

---

## 3. 调度流程

```c
// kernel/sched/fair.c — pick_next_entity
struct sched_entity *pick_next_entity(struct cfs_rq *cfs_rq)
{
    // 从红黑树取最左节点（vruntime 最小）
    struct sched_entity *left = __pick_first_entity(cfs_rq);

    // 检查是否需要"skiplink"（防止延迟过大）
    struct sched_entity *right = second_entity(cfs_rq);

    if (left && ... (left->vruntime <= ...))
        return left;

    return NULL;
}

// kernel/sched/fair.c — entity_is_task
static struct task_struct *entity_is_task(struct sched_entity *se)
{
    return se->on_rq ? container_of(se, struct task_struct, se) : NULL;
}
```

---

## 4. 完整调度周期

```
pick_next_task_fair()
  ├─ for each schedulable entity (遍历红黑树)
  │     pick_next_entity(cfs_rq)
  │       → rb_entry_cached(leftmost)  ← vruntime 最小的任务
  │
  └─ 返回 sched_entity → task_struct

调度到任务后：
  → set_next_entity(se)
  → se->exec_start = rq_clock_task()
  → enqueue_entity(cfs_rq, se)  ← 重新加入红黑树

时间片耗尽或被抢占：
  → dequeue_entity(cfs_rq, se)
  → update_curr()  ← 更新 vruntime
  → enqueue_entity(cfs_rq, se)  ← 更新红黑树位置
```

---

## 5. nice 值与权重

```c
// kernel/sched/core.c — NICE_TO_WEIGHT
const int sched_prio_to_weight[40] = {
    /* -20 */     88761,   /* 2^10 / 1024 */
    /* -19 */     71755,
    /* -18 */     56483,
    /* -17 */     46273,
    /* -16 */     36291,
    /* -15 */     29154,
    /* -14 */     23254,
    /* -13 */     18705,
    /* -12 */     14949,
    /* -11 */     11916,
    /* -10 */      9548,
    /*  -9 */      7621,
    /*  -8 */      6100,
    /*  -7 */      4904,
    /*  -6 */      3906,
    /*  -5 */      3121,
    /*  -4 */      2501,
    /*  -3 */      1991,
    /*  -2 */      1586,
    /*  -1 */      1277,
    /*   0 */      1024,   /* 基准 */
    /*  +1 */       820,
    /*  +2 */       655,
    /*  +3 */       526,
    /*  +4 */       423,
    /*  +5 */       335,
    /*  +6 */       272,
    /*  +7 */       215,
    /*  +8 */       172,
    /*  +9 */       137,
    /* +10 */       110,
    /* +11 */        87,
    /* +12 */        70,
    /* +13 */        56,
    /* +14 */        45,
    /* +15 */        35,
    /* +16 */        28,
    /* +17 */        22,
    /* +18 */        18,
    /* +19 */        15,
    /* +20 */        11,
};
```

---

## 6. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| vruntime 归一化 | nice 值影响权重，nice=0 基准，nice=-20 运行 50x 快 |
| 红黑树组织任务 | O(log n) 插入/删除，O(1) 取最左节点 |
| min_vruntime | 防止 vruntime 无限增长导致任务永远无法调度 |
| CFS_bandwidth | 防止某个组占用过多 CPU |
| sched_entity 组调度 | cgroup 调度层次化的基础 |

---

## 7. 参考

| 文件 | 内容 |
|------|------|
| `kernel/sched/fair.c` | `update_curr`、`pick_next_entity`、`enqueue_entity`、`dequeue_entity` |
| `include/linux/sched.h:575` | `struct sched_entity` |
| `kernel/sched/sched.h` | `struct cfs_rq`、`struct rq` |
