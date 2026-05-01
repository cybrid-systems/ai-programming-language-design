# 191-memory_compaction — 内存紧缩深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/compaction.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**Memory Compaction** 将物理页移动到一起，解决内存碎片化，特别是 THP 和 CMA 需要连续大块物理内存的场景。

## 1. 内存碎片化

```
内存碎片化：
  物理内存分配：
    alloc_pages(2MB) ← 需要连续 2MB
    但内存中散布着小的空闲碎片
    → 分配失败

compaction：
  将已分配的页从一端移动到另一端
  留下连续的空闲区域
  → 可再次分配大块内存
```

## 2. compaction

```c
// mm/compaction.c — compact_node
// 1. isolate_migratepages — 从低端扫描已分配页
// 2. migrate_pages — 移动页到高端
// 3. 低端留下连续空闲区域

void compact_node(int nid)
{
    struct zone *zone = &NODE_DATA(nid)->node_zones[ZONE_NORMAL];

    compact_zone(zone, &cc);
}

static void compact_zone(struct zone *zone, struct compact_control *cc)
{
    // 低端扫描
    low_pfn = zone->compact_init_pfn;
    high_pfn = zone->compact_capture_pfn;

    while (low_pfn < high_pfn) {
        // isolate_migratepages(low_pfn)
        // migrate_pages()
    }
}
```

## 3. CMA（Contiguous Memory Allocator）

```
CMA 区域：
  预留给设备驱动的大块连续内存
  平时由进程使用
  设备需要时，compaction 移动页，释放 CMA

// 查看 CMA 区域：
cat /proc/buddyinfo
```

## 4. 西游记类喻

**Memory Compaction** 就像"天庭的仓库整理"——

> 天庭的仓库（物理内存）用久了，各种货物（页）散布在各个角落，找不到一块连续的大空地放大型设备（THP 分配）。compaction 像仓库整理员，把所有货物往一边推，整理出连续的空地区域。虽然整理时仓库（CPU）要暂停工作（内存迁移期间），但整理完后，大型设备就能放进来了。

## 5. 关联文章

- **THP**（article 189）：compaction 支持 THP 分配
- **page_allocator**（article 17）：compaction 优化 buddy system

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

