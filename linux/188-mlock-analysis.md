# 188-mlock — 内存锁定深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/mlock.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**mlock** 将进程的虚拟地址范围锁定到物理内存，防止被换出（swap out）。常用于高性能和实时应用。

## 1. mlock 系统调用

```c
// mm/mlock.c — sys_mlock
long sys_mlock(unsigned long start, size_t len)
{
    unsigned long locked;
    struct vm_area_struct *vma;

    // 1. 锁定限制检查
    locked = (current->mm->locked_vm + len) >> PAGE_SHIFT;
    if (locked > rlimit(RLIMIT_MEMLOCK))
        return -EAGAIN;

    // 2. 设置 VM_LOCKED 标志
    vma = find_vma(current->mm, start);
    vma->vm_flags |= VM_LOCKED;

    // 3. 调用 make_pages_present
    make_pages_present(start, start + len);

    return 0;
}
```

## 2. make_pages_present

```c
// mm/mlock.c — make_pages_present
int make_pages_present(unsigned long start, unsigned long end)
{
    int ret;

    // 逐页调用 get_user_pages
    while (start < end) {
        ret = get_user_pages(start, 1, FOLL_TOUCH | FOLL_WRITE, &page);
        put_page(page);
        start += PAGE_SIZE;
    }
}
```

## 3. munlock

```c
// munlock 系统调用
// 清除 VM_LOCKED 标志，允许页被换出
// 但不会立即换出，页仍然在内存中
```

## 4. mlockall / munlockall

```bash
# 锁定所有内存：
mlockall(MCL_CURRENT | MCL_FUTURE);

# MCL_CURRENT — 锁定已映射的页
# MCL_FUTURE — 锁定未来映射的页
```

## 5. 西游记类喻

**mlock** 就像"天庭的常驻营地"——

> 普通营地（普通内存）可能被天庭收回（换出到 swap），但标记为"常驻"（mlock）的营地不会被收回，妖怪永远占着这个位置。好处是取东西（访问）永远很快（无页面 fault），坏处是常驻营地有限，天庭不能把地盘给其他妖怪。

## 6. 关联文章

- **get_user_pages**（article 15）：mlock 底层调用 get_user_pages
- **swap**（相关）：mlock 防止页被 swap out

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

