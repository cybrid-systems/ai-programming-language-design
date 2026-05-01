# 182-sched_entity — CFS调度实体深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/sched/fair.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**sched_entity** 是 CFS（Completely Fair Scheduler）的调度实体，每个 task_struct 都有一个 sched_entity，代表其在 CPU 上的调度单元。

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

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/sched/fair.c` | `enqueue_entity`、`pick_next_entity`、`update_curr` |
| `include/linux/sched/sched.h` | `struct sched_entity` |

## 7. 西游记类喻

**sched_entity** 就像"取经队伍的沙漏"——

> CFS 的调度就像一个精确的沙漏，每个妖怪（sched_entity）有一个沙漏（vruntime）。沙漏装满（vruntime 累积到一定程度），就要让位给沙漏更空的妖怪。每个妖怪的沙漏流速由权重决定——级别高的妖怪（nice -20）沙漏流得慢，所以同样的时间后沙漏还比较满；级别低的妖怪（nice +19）沙漏流得快，很快就要让位。这就是"公平调度"——每个妖怪消耗的沙漏时间是一样的，但优先级决定了沙漏的流速。

## 8. 关联文章

- **CFS**（article 37）：CFS 调度器
- **pick_next_task**（相关）：CFS 选择下一个调度实体

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

