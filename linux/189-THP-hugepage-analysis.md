# 189-THP_hugepage — 透明大页深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/huge_memory.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**THP（Transparent HugePages）** 自动将多个 4KB 页合并成 2MB 大页，减少页表开销，提升 TLB 命中率。

## 1. THP vs 普通页

```
普通页：4KB
THP：2MB（512个普通页）

TLB 条目：
  4KB 页面：每个条目覆盖 4KB
  2MB THP：每个条目覆盖 2MB = 512x 覆盖

性能收益：
  - TLB 命中率提高（减少 TLB miss）
  - 页表占用减少（一个 PTE → 一个 PMD）
  - 内存带宽提升（一次预取 2MB）
```

## 2. khugepaged

```c
// mm/huge_memory.c — khugepaged
// 后台守护进程，自动将符合条件的匿名页合并成 THP

// 扫描条件：
//   - 是匿名映射（file-backed 不合并）
//   - VMA 足够大（>VMA_MIN_SIZE）
//   - 页都是干净的、连续的

// collapse_huge_page() 核心：
//   1. 分配 2MB 连续物理页
//   2. 将 512 个 4KB 页内容复制到 2MB 页
//   3. 替换页表（PMD 级别）
//   4. 释放原来的 512 个 4KB 页
```

## 3. MADV_HUGEPAGE / MADV_NOHUGEPAGE

```c
// 建议内核启用 THP：
madvise(addr, len, MADV_HUGEPAGE);

// 建议内核禁用 THP：
madvise(addr, len, MADV_NOHUGEPAGE);
```

## 4. 西游记类喻

**THP** 就像"天庭的集装箱化仓储"——

> 以前每个小妖怪住一个小营房（4KB 页），天庭要找妖怪，得查 512 个营房地址（T  B miss）。THP 像把 512 个小营房合并成一个大连排房（2MB THP），天庭只需要记住一个地址，就能找到所有人。好处是找妖怪快（TLB 高命中率），坏处是如果某个小妖怪搬走了（页被换出），整个大连排房都要动一下。

## 5. 关联文章

- **page_allocator**（article 17）：THP 底层使用 page allocator
- **KSM**（相关）：THP 和 KSM 都管理大页

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

