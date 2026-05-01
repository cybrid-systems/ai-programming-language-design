# 184-sched_domain — 调度域深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/sched/topology.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**sched_domain** 是 CFS 负载均衡的基础，通过分层的调度域（Core → LLC → Die → NUMA）实现跨 CPU 核心的负载均衡。

## 1. 调度域层级

```
典型 x86_64 NUMA 拓扑：
  NUMA Node 0                     NUMA Node 1
  ┌─────────────┐                  ┌─────────────┐
  │  Die 0     │                  │  Die 1     │
  │  ┌───────┐ │                  │  ┌───────┐ │
  │  │Core 0 │Core 1│            │  │Core 4 │Core 5│
  │  │ L1 L2 │ L1 L2│            │  │ L1 L2 │ L1 L2│
  │  └───────┘ │ │            │  └───────┘ │ │
  │    L3 Cache│ │            │    L3 Cache│ │
  │  ───────── │ │            │  ───────── │ │
  └─────────────┘ │            └─────────────┘ │
        ↑ SD_BOUNDS│                    ↑ SD_BOUNDS│
        │SD_SHARE_PKG_RESOURCES│        │
        └────────────────────┘

每个层级都是一个 sched_domain：
  - SD_LV_SIBLING  — 同一核心的兄弟调度域
  - SD_LV_DIE     — 同一 CPU Die
  - SD_LV_NUMA    — 同一 NUMA 节点
```

## 2. struct sched_domain

```c
// kernel/sched/topology.c — sched_domain
struct sched_domain {
    struct sched_domain *parent;  // 父域
    struct sched_domain *child;    // 子域

    // 包含的 CPU
    unsigned long span[NR_CPUS];

    // 标志
    unsigned int flags;
    #define SD_LOAD_BALANCE       0x0001  // 负载均衡
    #define SD_BALANCE_NEWIDLE    0x0002  // 空闲时均衡
    #define SD_SHARE_PKG_RESOURCES 0x1000  // 共享资源（缓存）

    // 层级
    int level;                     // 域层级

    // 负载均衡
    struct balance_callback *balance_callback;
};
```

## 3. load_balance

```c
// kernel/sched/fair.c — load_balance
// 当 CPU 空闲或超时，调用 load_balance
// 1. 找到最繁忙的调度域
// 2. 从该域的繁忙组迁移任务到当前 CPU
```

## 4. 西游记类喻

**sched_domain** 就像"天庭的分区调度"——

> sched_domain 像天庭分成了多个区：每个小营房（L1/L2 缓存）、每个宿舍楼（L3 缓存）、每栋楼（Die）、每个院子（NUMA 节点）。负载均衡就是在每个层级内，让工作量均匀分布——不能让某个营房特别忙，而其他营房闲置。调度域的层级关系决定了负载均衡的范围——同一 Die 的妖怪可以互相帮忙（共享 L3），但跨院子（NUMA）就需要更大的协调代价。

## 5. 关联文章

- **CFS**（article 37）：sched_domain 是 CFS 负载均衡的基础
- **cpuset**（article 183）：cpuset 限制调度域范围

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

