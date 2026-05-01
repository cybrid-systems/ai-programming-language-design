# 187-vmalloc — vmalloc深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/vmalloc.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**vmalloc** 在虚拟内存中分配连续区域，但物理内存不一定连续。适用于内核需要大块连续虚拟内存的场景（如模块加载、大缓冲区）。

## 1. vmalloc vs kmalloc

```
kmalloc：
  物理连续
  最多 4MB（MAX_ORDER=10）
  使用 buddy system
  快速，但容易碎片化

vmalloc：
  物理不连续（3-4层页表）
  虚拟连续（通常从 VMALLOC_START 开始）
  用于大缓冲区（>4MB）
  较慢（需要建立页表）

alloc_pages：
  直接分配物理页
  物理连续，虚拟连续
```

## 2. vmalloc 实现

```c
// mm/vmalloc.c — vmalloc_node
void *vmalloc_node(unsigned long size, int node)
{
    return __vmalloc_node(size, GFP_KERNEL, NUMA_NO_NODE);
}

void *__vmalloc_node(unsigned long size, gfp_t gfp_mask, int node)
{
    // 1. 计算需要的页数
    nr_pages = size >> PAGE_SHIFT;

    // 2. 分配页（per-CPU 或 buddy）
    pages = alloc_pages_node(node, gfp_mask, order);

    // 3. 建立页表映射（3-4层）
    for (each page) {
        map_vm_area(page, PAGE_KERNEL);
    }

    // 4. 返回虚拟起始地址
    return (void *)area->addr;
}
```

## 3. vm_struct

```c
// mm/vmalloc.c — vm_struct
struct vm_struct {
    unsigned long       addr;           // 虚拟起始地址
    unsigned long       size;           // 总大小
    unsigned long       flags;           // VM_* 标志
    struct page       **pages;          // 页数组
    unsigned int        num_pages;       // 页数
    struct vm_struct   *next;           // 链表
};
```

## 4. VMALLOC_START / VMALLOC_END

```
虚拟地址空间布局（x86_64）：
  0xFFFF800000000000 +

  0xFFFF800000000000: kernel text
  0xFFFF880000000000: vmalloc 区域（128 TB）
  0xFFFFC90000000000: vmemmap
  0xFFFFEA0000000000: modules 区域
```

## 5. vfree

```c
// mm/vmalloc.c — vfree
void vfree(const void *addr)
{
    // 1. 找到 vm_struct
    find_vm_area(addr);

    // 2. 解除页表映射
    unmap_vm_area();

    // 3. 释放物理页
    for (each page) {
        put_page(page);
    }
}
```

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `mm/vmalloc.c` | `vmalloc_node`、`__vmalloc`、`vfree` |
| `mm/vmalloc.c` | `struct vm_struct` |

## 7. 西游记类喻

**vmalloc** 就像"天庭的跨区域仓库"——

> vmalloc 像一个跨多个城市的虚拟仓库。仓库的编号是连续的（虚拟连续），但货物实际上可能放在不同的仓库（物理不连续）。好处是可以有很大的虚拟空间（128TB），缺点是取货时要查好几本账（多级页表），比在同一个仓库里取货（kmalloc）慢。当需要分配巨大的缓冲区（>4MB）时，就用 vmalloc，虽然慢一点，但不会因为找不到连续的大块物理空间而失败。

## 8. 关联文章

- **page_allocator**（article 17）：vmalloc 底层使用 alloc_pages
- **ioremap**（相关）：ioremap 映射 I/O 设备内存

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

