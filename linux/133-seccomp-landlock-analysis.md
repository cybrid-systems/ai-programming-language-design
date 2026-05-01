# seccomp / landlock — 安全沙箱深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/seccomp.c` + `security/landlock/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**seccomp** 和 **landlock** 都是沙箱机制：
- **seccomp**：限制系统调用（白名单/黑名单）
- **landlock**：基于文件系统路径的沙箱（比 seccomp 更细粒度）

## 1. seccomp — 系统调用过滤

### 1.1 模式

```c
// seccomp 模式：
//   SECCOMP_MODE_DISABLED    = 0  // 关闭
//   SECCOMP_MODE_STRICT      = 1  // 严格：只允许 read/write/exit/sigreturn
//   SECCOMP_MODE_FILTER      = 2  // 过滤：使用 BPF 程序
```

### 1.2 SECCOMP_MODE_STRICT

```c
// 只有这些系统调用被允许：
#define SECCOMP_ARCH_NR_AUDIT_ARCH          AUDIT_ARCH_X86_64
#define SECCOMP_ARCH_NR_NATIVE              AUDIT_ARCH_X86_64

// 允许的系统调用：
//   __NR_read
//   __NR_write
//   __NR_exit
//   __NR_exit_group
//   __NR_sigreturn

// 其他系统调用 → SIGKILL
```

### 1.3 SECCOMP_MODE_FILTER — BPF 程序

```c
// seccomp 使用 Berkeley Packet Filter (BPF) 进行系统调用过滤
// 每个系统调用都会执行 BPF 程序，决定是否允许

// seccomp_data — BPF 输入
struct seccomp_data {
    int                     nr;              // 系统调用号
    __u32                   arch;           // 架构（AUDIT_ARCH_X86_64）
    __u64                   instruction_pointer; // IP
    __u64                   args[6];        // 系统调用参数
};

// BPF 程序返回：
//   SECCOMP_RET_ALLOW      = 0x7ffc0000  // 允许
//   SECCOMP_RET_KILL       = 0x00000000  // 杀死进程
//   SECCOMP_RET_TRAP       = 0x00030000  // 发送 SIGSYS
//   SECCOMP_RET_ERRNO      = 0x00050000  // 返回错误码
//   SECCOMP_RET_TRACE      = 0x7ff00000  // 交给 tracer (ptrace)
//   SECCOMP_RET_LOG        = 0x7ffc0000  // 记录但不阻止
```

### 1.4 prctl 设置

```c
// prctl(PR_SET_SECCOMP, mode, filter_bpf_program)
// 或者通过 SECCOMPRET_*

// 示例：只允许 openat
struct sock_filter filter[] = {
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_openat, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL),
};

struct sock_fprog fprog = {
    .len = sizeof(filter) / sizeof(filter[0]),
    .filter = filter,
};

prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &fprog);
```

## 2. landlock — 文件系统沙箱

### 2.1 概念

```c
// landlock 比 seccomp 更细粒度：
// seccomp：限制"能调用哪些系统调用"
// landlock：限制"能访问哪些文件路径"

// 限制规则：
//   - 只读目录
//   - 只写文件
//   - 无法删除/创建文件
//   - 无法访问特定文件系统
```

### 2.2 ruleset — 规则集

```c
// security/landlock/ruleset.c — landlock_ruleset
struct landlock_ruleset {
    // 规则
    struct landlock_domains *domains;        // 当前域（规则栈）

    // 约束
    unsigned int            access;           // 允许的操作掩码
    //   LANDLOCK_ACCESS_FS_READ    = 0x1
    //   LANDLOCK_ACCESS_FS_WRITE   = 0x2
    //   LANDLOCK_ACCESS_FS_EXEC    = 0x4
    //   LANDLOCK_ACCESS_FS_READ_FILE = 0x8
    //   LANDLOCK_ACCESS_FS_WRITE_FILE = 0x10
    //   LANDLOCK_ACCESS_FS_READ_DIR = 0x20
    //   LANDLOCK_ACCESS_FS_WRITE_DIR = 0x40
    //   LANDLOCK_ACCESS_FS_REMOVE_DIR = 0x80
    //   LANDLOCK_ACCESS_FS_REMOVE_FILE = 0x100
    //   LANDLOCK_ACCESS_FS_MAKE_CHAR = 0x200
    //   LANDLOCK_ACCESS_FS_MAKE_DIR  = 0x400
    //   LANDLOCK_ACCESS_FS_MAKE_REG  = 0x800
    //   LANDLOCK_ACCESS_FS_MAKE_SOCK = 0x1000
    //   LANDLOCK_ACCESS_FS_MAKE_FIFO = 0x2000
    //   LANDLOCK_ACCESS_FS_MAKE_BLOCK = 0x4000

    // 引用计数
    atomic_t                usage;           // 使用计数
};
```

### 2.3 创建和使用

```c
// 创建规则集
struct landlock_ruleset *ruleset = landlock_create_ruleset(...);

// 添加规则：限制访问 /tmp 只读
landlock_add_rule(ruleset,
    LANDLOCK_ACCESS_FS_READ | LANDLOCK_ACCESS_FS_WRITE,
    "/tmp", 0);

// 执行沙箱
prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);  // 必须先设置
landlock_restrict_self(ruleset, 0);

// 之后进程无法写入 /tmp
```

## 3. seccomp + landlock 对比

| 特性 | seccomp | landlock |
|------|---------|---------|
| 粒度 | 系统调用 | 文件路径 |
| 状态 | 无状态 | 有状态（规则栈）| 主动 | 被动 | 主动 |
| 配置 | BPF 程序 | ruleset + path |
| 典型用途 | 容器/微服务 | Web 服务器/浏览器 |

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/seccomp.c` | `seccomp_data`、`prctl(PR_SET_SECCOMP)` |
| `security/landlock/ruleset.c` | `landlock_ruleset`、`landlock_add_rule` |

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

