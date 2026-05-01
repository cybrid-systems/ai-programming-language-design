# 181-lockdep — 锁依赖追踪深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/locking/lockdep.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**lockdep** 是 Linux 内核的死锁检测器，通过追踪锁的获取顺序，构建有向图，检测循环等待、非法递归等死锁场景。

## 1. 锁分类

```c
// 锁类型（lock_class）：
//   .raw_spinlock_t    — 原始自旋锁
//   .spinlock_t        — 自旋锁（禁用抢占）
//   .rwlock_t          — 读写锁
//   .mutex             — 互斥锁
//   .rwsem            — 读写信号量
//   .ww_mutex         — 写时拥有互斥锁
```

## 2. lock_chain — 锁链

```c
// lockdep 追踪每个 CPU 的锁获取序列：
// lock_chain[cpu_id][depth] = lock_class_id

// 例如 CPU0 的锁获取序列：
//   spin_lock(&lock_A)      → depth 0
//   spin_lock(&lock_B)      → depth 1
//   spin_lock(&lock_C)      → depth 2
//   unlock(&lock_C)          → depth 1
//   unlock(&lock_B)          → depth 0
```

## 3. 死锁检测

```
lockdep 检测的死锁类型：

1. 递归死锁（不可重入）：
   spin_lock(&lock); spin_lock(&lock);  // 同一锁两次

2. 顺序死锁（A→B，B→A）：
   CPU0: lock_A → lock_B
   CPU1: lock_B → lock_A

3. 链式死锁（A→B→C→A）：
   每个 CPU 按不同顺序获取 A、B、C
```

## 4. proc 接口

```bash
# 查看锁依赖：
cat /proc/lock_stat

# 启用锁统计：
echo 1 > /proc/sys/kernel/lock_stat

# 查看死锁可能性：
cat /proc/lockdep/chains

# 锁统计：
cat /proc/lock_stat | head -20
```

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/locking/lockdep.c` | `check_chain_key`、`validate_chain` |
| `kernel/locking/lockdep_states.c` | 锁统计 |

## 6. 西游记类喻

**lockdep** 就像"天庭的锁具管理员"——

> lockdep 像天庭的锁具管理员，记录每个锁匠（CPU）每次取锁的顺序（lock_chain）。如果管理员发现某天有人按 A→B 顺序取了锁，另一天有人按 B→A 顺序取了锁，就知道这样迟早会出问题（A 持有着 A 等待 B，B 持有着 B 等待 A）。lockdep 在死锁发生前就能检测到潜在的死锁风险。

## 7. 关联文章

- **spinlock**（article 09）：spinlock 是 lockdep 的主要追踪对象
- **mutex**（article 08）：mutex 也被 lockdep 追踪

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

