# 37-CFS — 完全公平调度器深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**CFS（Completely Fair Scheduler）** 是 Linux 默认的 CPU 调度器（自 2.6.23）。核心思想：**虚拟运行时间（vruntime）**——每个进程获得一个公平的 CPU 时间份额。

doom-lsp 确认 `kernel/sched/fair.c` 包含约 1174+ 个符号。

---

## 1. 核心结构

### 1.1 struct sched_entity

```c
struct sched_entity {
    struct load_weight      load;         // 调度权重
    struct rb_node          run_node;     // 红黑树节点
    struct list_head        group_node;   // 组调度链表
    unsigned int            on_rq;        // 是否在运行队列

    u64                     vruntime;     // 虚拟运行时间
    u64                     prev_sum_exec_runtime; // 上次执行总时间

    struct sched_entity     *parent;      // 父调度实体（组调度）
    struct cfs_rq           *cfs_rq;      // 所属 cfs_rq
    struct cfs_rq           *my_q;        // 若为组调度：子 cfs_rq
    ...
};
```

### 1.2 struct cfs_rq

```c
struct cfs_rq {
    struct load_weight      load;         // 队列总权重
    unsigned int            nr_running;   // 运行进程数

    struct rb_root_cached   tasks_timeline; // vruntime 红黑树

    struct sched_entity     *curr;        // 当前运行的进程
    struct sched_entity     *next;        // 将要运行的进程
    struct sched_entity     *last;        // 最后运行的进程

    struct rq               *rq;          // 所属 runqueue
    ...
};
```

---

## 2. 调度流程

```
周期性调度 tick：
  scheduler_tick()
    └─ task_tick_fair(rq, curr)
         ├─ update_curr(cfs_rq)
         │    ├─ delta_exec = now - curr->exec_start
         │    ├─ curr->vruntime += delta_exec * (NICE_0_LOAD / curr->load.weight)
         │    └─ 更新当前进程的 vruntime
         │
         ├─ if (curr->vruntime > leftmost->vruntime)
         │    └─ resched_curr(rq)         ← 标记需要重新调度
         │
         └─ check_preempt_tick(cfs_rq, curr)
              └─ 如果当前进程运行时间超过理想时间片
                   └─ resched_curr(rq)

选择下一个进程：
  pick_next_task_fair(rq, prev)
    └─ pick_next_entity(cfs_rq)
         └─ 从红黑树中取出 vruntime 最小的进程
              └─ __dequeue_entity(cfs_rq, se)   ← 从树中移除
              └─ set_next_entity(cfs_rq, se)    ← 设置下一个运行
```

---

## 3. 虚拟运行时间计算

```c
// vruntime = 实际运行时间 / 权重比
// NICE_0_LOAD = 1024（nice=0 的权重）

vruntime = delta_exec * NICE0_LOAD / se->load.weight

// 例子：
//   nice=0 (weight=1024): vruntime = delta_exec
//   nice=5 (weight=335):  vruntime ≈ delta_exec * 3
//                         (运行同样时间，nice=5 的 vruntime 增长 3x)
//                         (所以更少被调度到，CPU 份额更少)
```

| nice 值 | 权重 | CPU 份额比例 |
|---------|------|-------------|
| -20 | 88761 | ×86.6 |
| -10 | 9548 | ×9.3 |
| 0 | 1024 | ×1.0 |
| 10 | 304 | ×0.3 |
| 19 | 15 | ×0.01 |

---

## 4. 源码文件索引

| 文件 | 关键符号 |
|------|---------|
| `kernel/sched/fair.c` | pick_next_entity / enqueue_task_fair |
| `kernel/sched/sched.h` | struct cfs_rq / struct sched_entity |

---

*分析工具：doom-lsp（clangd LSP）*
