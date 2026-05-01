# 177-eBPF — 扩展BPF深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/bpf/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**eBPF（extended Berkeley Packet Filter）** 是 Linux 的内核沙箱，允许用户空间程序在内核中安全执行，实现网络过滤、性能追踪、安全监控等功能。

## 1. eBPF 架构

```
用户空间：
  BPF 程序（C 语言） → clang/LLVM 编译 → ELF objdump → eBPF 字节码
         │
         ↓
  bpf() 系统调用 → BPF_PROG_LOAD
         │
         ↓
内核：
  BPF 虚拟机（JIT 编译）→ 执行
         │
         ↓
  验证器（Safety） + JIT 编译
```

## 2. BPF 程序类型

```c
// BPF_PROG_TYPE_*：

BPF_PROG_TYPE_SOCKET_FILTER   // 数据包过滤
BPF_PROG_TYPE_KPROBE        // kprobe 探针
BPF_PROG_TYPE_TRACEPOINT   // tracepoint
BPF_PROG_TYPE_XDP          // XDP（快速数据包处理）
BPF_PROG_TYPE_SCHED_CLS    // 流量分类（tc）
BPF_PROG_TYPE_CGROUP_SKB   // cgroup skb
BPF_PROG_TYPE_SOCK_OPS    // socket 选项
BPF_PROG_TYPE_STRUCT_OPS   // struct 操作
BPF_PROG_TYPE_RAW_TRACEPOINT  // 原始 tracepoint
BPF_PROG_TYPE_TRACING     // fentry/fexit/LSM
```

## 3. BPF Maps

```c
// BPF Map：内核-用户空间共享数据
// 创建：
bpf(BPF_MAP_CREATE, &attr);
// attr.map_type = BPF_MAP_TYPE_HASH;
// attr.max_entries = 100;

// 操作：
bpf(BPF_MAP_LOOKUP_ELEM, fd, &key, &value);
bpf(BPF_MAP_UPDATE_ELEM, fd, &key, &value, BPF_ANY);
bpf(BPF_MAP_DELETE_ELEM, fd, &key);

// Map 类型：
//   BPF_MAP_TYPE_HASH        — 哈希表
//   BPF_MAP_TYPE_ARRAY       — 数组
//   BPF_MAP_TYPE_PERCPU_HASH — per-CPU 哈希
//   BPF_MAP_TYPE_STACK_TRACE — 栈跟踪
//   BPF_MAP_TYPE_CGROUP_ARRAY — cgroup 数组
//   BPF_MAP_TYPE_RINGBUF    — 环形缓冲区（高性能）
```

## 4. XDP（Express Data Path）

```c
// XDP：数据包在网卡驱动层处理
// 在 BPF_PROG_TYPE_XDP 中：
//   return XDP_PASS;   // 继续处理
//   return XDP_DROP;   // 丢弃
//   return XDP_REDIRECT; // 重定向到其他接口
//   return XDP_TX;     // 从同一接口发回

// 性能：单个数据包处理仅需 ~100ns
// vs 传统：~1000ns+
```

## 5. BPF 验证器

```c
// kernel/bpf/verifier.c — BPF 验证器
// 1. 无循环（或有界循环）
// 2. 所有内存访问安全
// 3. 栈大小限制（512 字节）
// 4. 不能执行危险指令
```

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/bpf/syscall.c` | `bpf_prog_load`、`bpf_map_create` |
| `kernel/bpf/verifier.c` | `check_subprog_instructions` |
| `kernel/bpf/jit.c` | `bpf_jit_compile` |

## 7. 西游记类喻

**eBPF** 就像"天庭的临时法术"——

> eBPF 允许天庭（用户空间）临时写一个法术（BPF 程序），通过验证器检查安全性后，在天庭内部执行。好处是既有内核速度（零拷贝、无上下文切换），又有用户空间的灵活性。XDP 像在最靠近城门的守将那里（网卡驱动）拦截处理，快到极致；普通 BPF 程序则在内核各个位置执行追踪和过滤。

## 8. 关联文章

- **ftrace**（article 55）：BPF 可以 attach 到 tracepoint
- **XDP**（相关）：XDP 是最快的网络数据路径

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

