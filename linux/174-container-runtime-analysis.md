# 174-container_runtime — 容器运行时深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/cgroup/cpuset.c` + `kernel/ns/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

Linux 容器依赖 namespace（资源隔离）和 cgroup（资源限制）。容器运行时（Docker/runc/containerd）通过这些内核机制创建隔离环境。

## 1. Namespace 隔离

```c
// 6种Namespace：

CLONE_NEWUTS    // UTS（主机名/域名）
CLONE_NEWIPC     // IPC（System V IPC）
CLONE_NEWPID     // PID（进程ID）
CLONE_NEWNET     // NET（网络）
CLONE_NEWNS      // MNT（挂载）
CLONE_NEWUSER    // USER（用户ID）

// unshare 系统调用创建新 namespace
// clone(CLONE_NEWNS|CLONE_NEWUTS|...) 创建新进程并加入 namespace
```

## 2. Cgroup 资源限制

```
容器典型的 cgroup 限制：

cpu:/docker/abc123
  cpu.shares=1024
  cpu.cfs_quota=100000  // 100ms/100ms = 1 CPU

memory:/docker/abc123
  memory.limit_in_bytes=1G
  memory.soft_limit_in_bytes=512M

blkio:/docker/abc123
  blkio.weight=500
```

## 3. seccomp

```
seccomp 限制系统调用：

// Docker 默认 seccomp 配置：
{
//   "defaultAction": "SCMP_ACT_ERRNO",
//   "syscalls": [
//     { "names": ["open", "read", ...], "action": "SCMP_ACT_ALLOW" }
//   ]
// }
```

## 4. runc 启动流程

```
runc create container
    │
    ├─ clone(CLONE_NEWNS|CLONE_NEWPID|...) → 新进程
    │
    ├─ 设置 cgroup
    │
    ├─ pivot_root() → 切换根文件系统
    │
    ├─ mount() → 挂载容器文件系统
    │
    ├─ seccomp() → 设置系统调用限制
    │
    └─ execve("/bin/sh") → 运行容器进程
```

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/ns/proc.c` | `create_new_namespaces` |
| `kernel/cgroup/cpuset.c` | cpuset 配置 |

## 6. 西游记类喻

**Container** 就像"取经队伍的独立营地"——

> 营地（容器）建在独立的岛上（namespace），每个营地的妖怪看不到其他营地的人（PID/UTS隔离），但营地的大小（CPU/内存限制）被天庭规定死了（cgroup）。如果妖怪想偷偷使用超过限制的资源（系统调用），门口的守将就会拦住（seccomp）。runc 像管理营地的官员，负责按照规定（镜像配置）建立营地、分配资源、设置守卫。

## 7. 关联文章

- **namespace**（article 134）：Linux namespace
- **cgroup**（article 135）：资源限制

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

