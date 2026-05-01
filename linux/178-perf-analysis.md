# 178-perf — 性能事件分析深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/events/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**perf** 是 Linux 的性能分析工具，基于硬件 PMU（Performance Monitoring Unit），支持硬件/软件性能事件采样、热点函数分析、缓存分析。

## 1. perf_event_open 系统调用

```c
// perf_event_open — 创建性能监控事件
// SYSCALL_DEFINE5(perf_event_open, ...)
struct perf_event_attr {
    __u32 type;                // PERF_TYPE_*
    __u64 config;             // 事件配置
    __u64 sample_period;       // 采样周期
    __u64 sample_type;        // 采样类型
    int  pid;                  // 监控进程
    int  cpu;                 // 监控 CPU
};

// 类型：
//   PERF_TYPE_HARDWARE  — 硬件事件（CPU 周期、指令等）
//   PERF_TYPE_SOFTWARE — 软件事件（上下文切换、页面错误等）
//   PERF_TYPE_TRACEPOINT — tracepoint
//   PERF_TYPE_HW_CACHE — 硬件缓存事件
```

## 2. 硬件事件

```bash
# perf list 查看可用事件：
perf list

# 常用硬件事件：
#   cycles        — CPU 周期
#   instructions — 指令数
#   cache-references — 缓存引用
#   cache-misses  — 缓存未命中
#   branches     — 分支
#   branch-misses — 分支预测失败

# 使用：
perf stat -e cycles,instructions,cache-misses ls
perf record -g -e cycles ./myprogram
perf report
```

## 3. perf record

```c
// perf record 使用：
// 1. mmap() 创建采样缓冲区
// 2. 每次事件触发，perf 采样程序计数器（IP）
// 3. 保存到 ring buffer
// 4. 数据写入 perf.data

// -g 选项启用栈回溯（DWARF unwind）
// -a 全系统
// -C cpu 指定 CPU
```

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/events/core.c` | `perf_event_open`、`perf_read` |
| `kernel/perf_event.c` | 事件监控核心 |

## 5. 西游记类喻

**perf** 就像"天庭的计时官"——

> perf 像天庭的计时官（PMU），记录每个神仙（CPU）在每个时刻在做什么。cycles 记录走了多少步（时钟周期），instructions 记录念了多少咒（执行的指令），cache-misses 记录念咒时忘词的次数（缓存未命中）。perf stat 就像看整个天庭的统计数据，perf record 像在每个关键步骤做笔记，perf report 像看完笔记后画出一个热力图，告诉玉帝哪些环节最耗时。

## 6. 关联文章

- **ftrace**（相关）：ftrace 更多用于内核追踪
- **eBPF**（article 177）：perf 与 BPF 结合

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

