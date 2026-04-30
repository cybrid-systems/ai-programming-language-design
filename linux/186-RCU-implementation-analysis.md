# 186-RCU_implementation — RCU实现深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/rcu/tree.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Tree RCU** 是 Linux 内核的默认 RCU 实现，通过分层（per-CPU）架构实现高效的无锁读。

---

## 1. RCU 分层架构

```
RCU 架构（Tree RCU）：

rcu_state
  └─ rcu_node[0]（根节点）
        ├─ rcu_node[1]（第一层）
        ├─ rcu_node[2]（第一层）
        ├─ rcu_node[3]（第一层）
        └─ ...
              └─ rcu_node[N]（叶子节点，每 CPU 一个）

宽限期传播：
  每个 CPU 在 QS（quiescent state）后报告给叶子节点
  叶子节点累积后报告给父节点
  父节点累积后报告给根节点
  根节点确认所有节点 QS 后，宽限期结束
```

---

## 2. rcu_state

```c
// kernel/rcu/tree.c — rcu_state
struct rcu_state {
    struct rcu_node       *rda;      // rcu_node 数组
    int                   ncpus;      // CPU 数量

    // 活跃宽限期
    unsigned long         completed;   // 当前宽限期编号
    unsigned long         gp_seq;      // 宽限期序列

    // GP 线程
    struct task_struct   *rcu_gp_kthread; // GP 守护线程

    // 等待队列
    wait_queue_head_t    gp_wq;      // 等待者
};
```

---

## 3. rcu_node

```c
// kernel/rcu/tree.c — rcu_node
struct rcu_node {
    raw_spinlock_t       lock;          // 锁
    unsigned long        qsmask;       // 子树中需要报告的 CPU
    unsigned long        exp_qsmask;   // 加速 GP 队列
    unsigned long        gqsmask;      // 子树中已经报告的 CPU

    struct list_head    blkd_tasks;    // 阻塞的任务（宽限期内不能删除的 RCU 读者）
};
```

---

## 4. rcu_read_lock 实现

```c
// preempt_disable + rcu_read_lock_nesting++
// 不需要自旋锁，所以读者之间完全并行
```

---

## 5. synchronize_rcu

```c
// 1. 等待所有 CPU 进入 QS（quiescent state）
//    每个 CPU 在以下情况进入 QS：
//      - 用户态执行
//      - idle 进程
//      - 持有 RCU_READ_LOCK

// 2. 宽限期结束
// 3. 调用注册的回调
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/rcu/tree.c` | `rcu_gp_kthread`、`synchronize_rcu` |
| `kernel/rcu/tree_plugin.c` | `__rcu_read_lock` |

---

## 7. 西游记类喻

**Tree RCU** 就像"天庭的接力通报系统"——

> RCU 的宽限期就像一个接力赛跑。每个小分队（CPU）跑完后要向队长报告（QS）。小队长（叶子节点）收集完所有小分队报告后，向大队长（父节点）报告，大队长一级级往上报告，直到总指挥（根节点）确认所有人都跑完了，才发出"行动开始"信号（回调）。在此之前，正在读天书的妖怪（RCU 读者）不能离开。Tree RCU 的好处是分级管理，队长只管自己手下的小分队，不用所有人都找总指挥。

---

## 8. 关联文章

- **RCU**（article 26）：RCU 基本概念
- **sched_entity**（article 182）：idle 进程进入 QS