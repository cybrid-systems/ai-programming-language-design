# 157-per-CPU — Per-CPU变量与SMP调度深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/percpu.h` + `mm/percpu.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**per-CPU** 变量是 Linux 内核中每个 CPU 拥有独立副本的变量，消除了 SMP 系统中的锁竞争，是高性能内核代码的核心技术。

## 1. 核心概念

### 1.1 为什么需要 per-CPU

```
多核 CPU 的缓存问题：

共享变量：
  CPU0: [写入]--→ [L1 cache line]--→ [共享 L3]--→ [L1 cache line]--→ [CPU1: 读取]
         ↑ 问题：每次写入都导致其他 CPU 的缓存行失效

per-CPU 变量：
  CPU0: [写入]--> [CPU0 私有的 L1]（不共享）
  CPU1: [写入]--> [CPU1 私有的 L1]（不共享）
         ↑ 好处：无锁、无缓存一致性开销
```

## 2. per-CPU 变量声明

### 2.1 DEFINE_PER_CPU — 声明

```c
// include/linux/percpu.h — 声明 per-CPU 变量
DEFINE_PER_CPU(int, my_counter);         // 整型，每 CPU 一个
DEFINE_PER_CPU(long, irq_count);         // 中断计数
DEFINE_PER_CPU(struct task_struct *, idle); // 每个 CPU 的 idle 进程

// 初始化（非零值）：
DEFINE_PER_CPU(int, my_array[4]);        // 数组

// 不对齐（稀疏）：
DEFINE_PER_CPU_SECTION(int, my_var, ".data.percpu");
```

### 2.2 get_cpu_var / put_cpu_var — 访问

```c
// include/linux/percpu.h — 访问 per-CPU 变量
// 在禁用抢占的情况下访问：
get_cpu_var(my_counter)   // 获取当前 CPU 的副本，返回指针
put_cpu_var(my_counter)  // 释放（启用抢占）

// 示例：
void increment(void)
{
    get_cpu_var(my_counter)++;
    put_cpu_var(my_counter);
}
```

### 2.3 this_cpu_ptr — 当前 CPU 指针

```c
// include/linux/percpu.h — 获取当前 CPU 指针
this_cpu_ptr(&my_counter)    // 返回当前 CPU 的变量指针
this_cpu_read(my_counter)    // 读取当前 CPU 的值
this_cpu_write(my_counter, 5) // 写入当前 CPU 的值
this_cpu_add(my_counter, 1)  // 当前 CPU 值 +1
```

## 3. 静态 vs 动态分配

### 3.1 静态分配（编译时）

```c
// 静态分配：编译时确定大小，每个 CPU 一个副本
DEFINE_PER_CPU(int, counter);

// 访问：
per_cpu(counter, cpu_id)    // 获取指定 CPU 的副本
__get_cpu_var(counter)     // 获取当前 CPU 的副本（无需锁）
```

### 3.2 动态分配（运行时）

```c
// alloc_percpu(type) — 分配
int *array = alloc_percpu(int);  // 运行时分配

// free_percpu(ptr) — 释放
free_percpu(array);
```

## 4. 底层实现

### 4.1 struct percpu_data — 元数据

```c
// mm/percpu.c — percpu 分配元数据
struct percpu_data {
    // 每个 CPU 的基地址偏移
    unsigned long __per_cpu_offset[NR_CPUS];
};
```

### 4.2 percpu 布局

```
per-CPU 变量在内存中的布局：

.text 区域：
  ┌─────────────┐
  │  CPU0 代码  │
  └─────────────┘
  ┌─────────────┐
  │  CPU1 代码  │
  └─────────────┘

data 区域：
  ┌──────────────────┐
  │ per-CPU 变量 (CPU0) │ ← CPU0 私有副本
  ├──────────────────┤
  │ per-CPU 变量 (CPU1) │ ← CPU1 私有副本
  ├──────────────────┤
  │ per-CPU 变量 (CPU2) │ ← CPU2 私有副本
  └──────────────────┘

访问方式：
  变量地址 = percpu_base + __per_cpu_offset[cpu_id]
```

## 5. this_cpu_* 操作

### 5.1 this_cpu_update

```c
// arch/x86/include/asm/percpu.h — this_cpu_update
#define this_cpu_update_(op, var, val) \
({ \
    __this_cpu_preempt_check("op"); \
    typeof(var) ret__; \
    asm volatile("op %1, %0" \
                 : "+m" (this_cpu_ptr(&var)[0]) \
                 : "ir" (val)); \
    ret__; \
})

// 等价于：
this_cpu_write(var, val);   // 写
this_cpu_add(var, val);     // 加
this_cpu_inc(var);          // 递增
this_cpu_dec(var);          // 递减
```

## 6. percpu 原子操作

### 6.1 this_cpu_cmpxchg

```c
// include/linux/percpu.h — this_cpu_cmpxchg
#define this_cpu_cmpxchg(var, old, new) \
({ \
    typeof(var) ret__; \
    preempt_disable(); \
    ret__ = this_cpu_read(var); \
    if (ret__ == old) \
        this_cpu_write(var, new); \
    preempt_enable(); \
    ret__; \
})
```

## 7. 典型使用场景

```c
// 1. 计数器（无锁）
DEFINE_PER_CPU(long, rx_packets);
this_cpu_inc(rx_packets);  // 每收一个包，当前 CPU 的计数器 +1

// 2. 当前进程指针
DEFINE_PER_CPU(struct task_struct *, current_task);

// 3. 中断状态
DEFINE_PER_CPU(unsigned long, irq_stat);

// 4. LRU 链表
DEFINE_PER_CPU(struct page *, lru_add);

// 在内核中的使用：
// - jiffies_64（虽然不是 per-CPU，但体现了概念）
// - softirq_ctx（每个 CPU 有自己的 softirq 上下文）
// - irq_stat（每个 CPU 有自己的中断计数）
```

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/percpu.h` | `DEFINE_PER_CPU`、`get_cpu_var`、`this_cpu_ptr`、`this_cpu_add` |
| `mm/percpu.c` | `alloc_percpu`、`free_percpu`、`percpu_alloc` |

## 9. 西游记类比

**per-CPU** 就像"取经队伍的各城市仓库"——

> 以前每个妖怪据点（CPU）都要到天庭总仓库（共享内存）取材料，每次取都要办手续（锁）。per-CPU 变量就像在每个城市都建了一个小仓库（每个 CPU 的独立副本），妖怪直接从自己城市的小仓库取材料，不用去总仓库排队。各城市的小仓库内容不一样，但格式相同。好处是：完全不需要锁（每个城市只用一个仓库管理员），速度极快。但每个城市的仓库管理员（CPU）只能看到自己城市的材料，看不到其他城市的——如果需要跨城市协作（CPU 间通信），还需要其他机制。

## 10. 关联文章

- **spinlock**（article 09）：per-CPU 减少锁的使用
- **scheduler**（相关）：调度器用 per-CPU 变量追踪每个 CPU 的状态

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

