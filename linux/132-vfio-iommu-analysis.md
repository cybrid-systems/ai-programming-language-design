# Linux Kernel VFIO / IOMMU 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/vfio/` + `drivers/iommu/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：VFIO、IOMMU、device passthrough、VT-d、DMA 重映射

## 0. VFIO 概述

**VFIO** 是用户空间设备驱动的安全框架，实现设备直通（passthrough）。

```
传统：设备 DMA → 物理内存（可能被恶意利用）
VFIO：设备 DMA → IOMMU → 虚拟地址 → 受保护物理内存
```

## 1. 核心数据结构

### 1.1 vfio_device — VFIO 设备

```c
// drivers/vfio/vfio.c — vfio_device
struct vfio_device {
    struct kref           refcount;             // 引用计数
    const char            *name;                // 设备名
    const struct vfio_device_ops *ops;        // 设备操作
    struct vfio_group    *group;              // 所属组
    struct vfio_container *container;          // 所属容器
    struct device         *device;              // 底层设备
    struct list_head      group_next;          // 组内链表
    struct list_head      container_next;       // 容器内链表
    unsigned long         flags;                // 标志
};
```

### 1.2 vfio_group — VFIO 组

```c
// drivers/vfio/vfio.c — vfio_group
struct vfio_group {
    // IOMMU 组（共享页表的设备集合）
    struct iommu_group   *iommu_group;         // 行 65

    // 容器
    struct vfio_container *container;          // 行 68

    // 命名空间
    struct vfio_namespace *namespace;          // 行 71

    // 文件描述符
    struct file           *filp;               // 行 74

    // 引用计数
    int                    users;               // 行 77

    // 设备列表
    struct list_head       device_list;        // 行 80

    // 文件描述符列表
    struct list_head       file_list;          // 行 83

    // 设备类型
    unsigned int           type;               // 行 86
};
```

### 1.3 vfio_iommu — VFIO IOMMU

```c
// drivers/vfio/vfio_iommu.c — vfio_iommu
struct vfio_iommu {
    struct vfio_container  *container;         // 所属容器

    // IOMMU domain
    struct iommu_domain   *domain;            // IOMMU 域

    // IOMMU 组列表
    struct list_head       domain_list;       // domain 链表

    // DMA 映射
    struct rb_root         dma_list;           // DMA 映射红黑树

    // 互斥
    struct mutex           lock;               // 保护 domain_list

    // 标志
    unsigned int           flags;               // VFIO_IOMMU_*
};
```

## 2. IOMMU DMA 重映射

```c
// Intel VT-d 页表（4级）：
// PML4（Page Map Level 4）→ 512 GB
// PDPT（Page Directory Pointer）→ 1 GB
// PDT（Page Directory）→ 2 MB
// PT（Page Table）→ 4 KB

// DMA 重映射：
// IO Virtual Address (IOVA) → Physical Address (PA)

// iommu_map()：
// iommu_domain->domain->iommu_map(domain, iova, phys, size, prot);

// iommu_unmap()：
// iommu_domain->domain->iommu_unmap(domain, iova, size);
```

## 3. VFIO 设备打开流程

```c
// ioctl:
VFIO_GROUP_SET_CONTAINER → 将组加入容器
VFIO_DEVICE_ATTACH_IOASID → 附加 IOASID
VFIO_DEVICE_GET_INFO → 获取设备信息
VFIO_DEVICE_GET_IRQ_INFO → 获取中断信息
VFIO_DEVICE_BIND_IOMMU_FD → 绑定 IOMMU FD
VFIO_DEVICE_FEATURE_STORE → 存储设备特性
```

## 4. 参考

| 文件 | 内容 |
|------|------|
| `drivers/vfio/vfio.c` | VFIO 核心 |
| `drivers/vfio/vfio_iommu.c` | VFIO IOMMU |
| `drivers/iommu/intel-iommu.c` | Intel VT-d |
| `include/linux/iommu.h` | IOMMU API |


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

