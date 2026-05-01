# 186-RCU_implementation — RCU实现深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/rcu/tree.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**Tree RCU** 是 Linux 内核的默认 RCU 实现，通过分层（per-CPU）架构实现高效的无锁读。

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

## 4. rcu_read_lock 实现

```c
// preempt_disable + rcu_read_lock_nesting++
// 不需要自旋锁，所以读者之间完全并行
```

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

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/rcu/tree.c` | `rcu_gp_kthread`、`synchronize_rcu` |
| `kernel/rcu/tree_plugin.c` | `__rcu_read_lock` |

## 7. 西游记类喻

**Tree RCU** 就像"天庭的接力通报系统"——

> RCU 的宽限期就像一个接力赛跑。每个小分队（CPU）跑完后要向队长报告（QS）。小队长（叶子节点）收集完所有小分队报告后，向大队长（父节点）报告，大队长一级级往上报告，直到总指挥（根节点）确认所有人都跑完了，才发出"行动开始"信号（回调）。在此之前，正在读天书的妖怪（RCU 读者）不能离开。Tree RCU 的好处是分级管理，队长只管自己手下的小分队，不用所有人都找总指挥。

## 8. 关联文章

- **RCU**（article 26）：RCU 基本概念
- **sched_entity**（article 182）：idle 进程进入 QS

---

## doom-lsp 源码分析

> 以下分析基于 Linux 7.0 主线源码，使用 doom-lsp (clangd LSP) 进行深度符号分析

### 文件分析摘要

| 源文件 | 符号数 | 结构体 | 函数 | 变量 |
|--------|--------|--------|------|------|
| `include/linux/list.h` | 51 | 0 | 51 | 0 |
| `include/linux/sched.h` | 567 | 70 | 134 | 7 |
| `include/linux/mm.h` | 793 | 24 | 527 | 18 |

### 核心数据结构

- **audit_context** `sched.h:58`
- **bio_list** `sched.h:59`
- **blk_plug** `sched.h:60`
- **bpf_local_storage** `sched.h:61`
- **bpf_run_ctx** `sched.h:62`
- **bpf_net_context** `sched.h:63`
- **capture_control** `sched.h:64`
- **cfs_rq** `sched.h:65`
- **fs_struct** `sched.h:66`
- **futex_pi_state** `sched.h:67`
- **io_context** `sched.h:68`
- **io_uring_task** `sched.h:69`
- **mempolicy** `sched.h:70`
- **nameidata** `sched.h:71`
- **nsproxy** `sched.h:72`
- **perf_event_context** `sched.h:73`
- **perf_ctx_data** `sched.h:74`
- **pid_namespace** `sched.h:75`
- **pipe_inode_info** `sched.h:76`
- **rcu_node** `sched.h:77`
- **reclaim_state** `sched.h:78`
- **robust_list_head** `sched.h:79`
- **root_domain** `sched.h:80`
- **rq** `sched.h:81`
- **sched_attr** `sched.h:82`

### 关键函数

- **INIT_LIST_HEAD** `list.h:43`
- **__list_add_valid** `list.h:136`
- **__list_del_entry_valid** `list.h:142`
- **__list_add** `list.h:154`
- **list_add** `list.h:175`
- **list_add_tail** `list.h:189`
- **__list_del** `list.h:201`
- **__list_del_clearprev** `list.h:215`
- **__list_del_entry** `list.h:221`
- **list_del** `list.h:235`
- **list_replace** `list.h:249`
- **list_replace_init** `list.h:265`
- **list_swap** `list.h:277`
- **list_del_init** `list.h:293`
- **list_move** `list.h:304`
- **list_move_tail** `list.h:315`
- **list_bulk_move_tail** `list.h:331`
- **list_is_first** `list.h:350`
- **list_is_last** `list.h:360`
- **list_is_head** `list.h:370`
- **list_empty** `list.h:379`
- **list_del_init_careful** `list.h:395`
- **list_empty_careful** `list.h:415`
- **list_rotate_left** `list.h:425`
- **list_rotate_to_front** `list.h:442`
- **list_is_singular** `list.h:457`
- **__list_cut_position** `list.h:462`
- **list_cut_position** `list.h:488`
- **list_cut_before** `list.h:515`
- **__list_splice** `list.h:531`
- **list_splice** `list.h:550`
- **list_splice_tail** `list.h:562`
- **list_splice_init** `list.h:576`
- **list_splice_tail_init** `list.h:593`
- **list_count_nodes** `list.h:755`

### 全局变量

- **__tracepoint_sched_set_state_tp** `sched.h:350`
- **__tracepoint_sched_set_need_resched_tp** `sched.h:352`
- **def_root_domain** `sched.h:407`
- **sched_domains_mutex** `sched.h:408`
- **cad_pid** `sched.h:1749`
- **init_stack** `sched.h:1964`
- **class_migrate_is_conditional** `sched.h:2519`
- **_totalram_pages** `mm.h:53`
- **high_memory** `mm.h:74`
- **sysctl_legacy_va_layout** `mm.h:86`
- **mmap_rnd_bits_min** `mm.h:92`
- **mmap_rnd_bits_max** `mm.h:93`
- **mmap_rnd_bits** `mm.h:94`
- **sysctl_user_reserve_kbytes** `mm.h:210`
- **sysctl_admin_reserve_kbytes** `mm.h:211`

### 成员/枚举

- **utime** `sched.h:366`
- **stime** `sched.h:367`
- **lock** `sched.h:368`
- **seqcount** `sched.h:386`
- **starttime** `sched.h:387`
- **state** `sched.h:388`
- **cpu** `sched.h:389`
- **utime** `sched.h:390`
- **stime** `sched.h:391`
- **gtime** `sched.h:392`
- **sched_priority** `sched.h:413`
- **pcount** `sched.h:421`
- **run_delay** `sched.h:424`
- **max_run_delay** `sched.h:427`
- **min_run_delay** `sched.h:430`
- **last_arrival** `sched.h:435`
- **last_queued** `sched.h:438`
- **max_run_delay_ts** `sched.h:441`
- **weight** `sched.h:461`
- **inv_weight** `sched.h:462`

