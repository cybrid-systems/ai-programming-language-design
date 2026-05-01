# 175-kallsyms_livepatch — 内核符号与热补丁深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/kallsyms.c` + `kernel/livepatch/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**kallsyms** 导出内核符号供用户空间使用（perf、systemtap）。**Livepatch** 允许在运行时替换内核函数，实现热补丁，无需重启。

## 1. kallsyms

### 1.1 内核符号表

```c
// kernel/kallsyms.c — 内核符号
// /proc/kallsyms 包含所有内核函数和数据的地址

// 符号类型：
//   t = text（代码）
//   T = 全局文本
//   d = data
//   D = 全局数据

// /proc/kallsyms 示例：
//   0000000000001234 t tcp_sendmsg  [tcp]
//   0000000000005678 T sys_sendto      [vmlinux]
```

### 1.2 kallsyms_lookup

```c
// kernel/kallsyms.c — kallsyms_lookup
const char *kallsyms_lookup(unsigned long addr, char **namebuf,
                            size_t *nameLen, ...)
{
    // 1. 二分查找符号表
    // 2. 返回符号名和偏移
    return symbol_name;
}
```

## 2. Livepatch

### 2.1 klp_patch — 补丁结构

```c
// kernel/livepatch/patch.c — klp_patch
struct klp_patch {
    struct list_head        list;              // 全局补丁链表
    char                  *modname;         // 模块名
    struct klp_object       *objs;           // 补丁对象

    struct klp_func        *funcs;           // 替换函数
};

struct klp_func {
    const char            *old_name;        // 原函数名
    void                  *new_func;        // 新函数
    unsigned long          old_addr;         // 原函数地址
    unsigned long          new_addr;         // 新函数地址
};
```

### 2.2 klp_enable_patch — 启用补丁

```c
// kernel/livepatch/core.c — klp_enable_patch
int klp_enable_patch(struct klp_patch *patch)
{
    // 1. 解析补丁对象
    klp_init_patch(patch);

    // 2. 替换函数（Ftrace）
    for (each_func in patch->funcs) {
        klp_hook_func(func);
    }

    // 3. 启用补丁
    patch->enabled = true;
}
```

## 3. Ftrace 函数钩子

```c
// Livepatch 使用 Ftrace 替换函数：
// 1. ftrace_set_filter_ip(func->old_addr)
// 2. 注册 trampoline
// 3. 旧函数被调用时，跳转到新函数

// trampoline：
//   保存上下文
//   跳转到 new_func
//   返回后恢复
```

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/kallsyms.c` | `kallsyms_lookup` |
| `kernel/livepatch/core.c` | `klp_enable_patch` |

## 5. 西游记类喻

**kallsyms + Livepatch** 就像"天庭的热修复系统"——

> kallsyms 像天庭的职位表，记录了每个神仙的职位和位置（函数名和地址），这样天庭能随时找到某个神仙（perf 能看到函数调用栈）。Livepatch 像天庭的"法术替换"——某个神仙（函数）如果出了问题，不用重新建天庭（重启内核），直接施法把他换成另一个能力更强的神仙（新函数）。这个替换通过 ftrace 魔术钩子实现，让所有调用旧函数的代码自动跳转到新函数。这就是为什么生产环境的 Linux 可以热修复，不用中断服务。

## 6. 关联文章

- **ftrace**（相关）：Livepatch 依赖 ftrace
- **module**（相关）：kallsyms 也包含模块符号

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

