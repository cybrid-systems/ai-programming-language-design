# 091-seccomp-landlock — Linux seccomp 和 Landlock 安全框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码 | 使用 doom-lsp 逐行解析

## 0. 概述

**seccomp**（Secure Computing）通过 BPF 程序过滤系统调用，**Landlock** 提供文件系统沙箱。seccomp 限制进程可以执行的系统调用，Landlock 限制进程可以访问的文件系统路径。

---

## 1. seccomp

### 1.1 `struct seccomp`——task_struct 中的 seccomp 状态

```c
struct seccomp {
    int mode;                               // SECCOMP_MODE_NONE / FILTER / TRACE
    struct seccomp_filter *filter;          // BPF 过滤器链表
};
```

### 1.2 系统调用过滤

```
prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, prog)
  └─ seccomp_set_mode_filter()
       └─ seccomp_prepare_filter(prog)     // 验证 BPF 程序
       └─ seccomp_attach_filter(tsk, filter) // 安装过滤器

每次系统调用入口：
  syscall_trace_enter()
    └─ secure_computing()
         └─ seccomp_run_filters()
              └─ BPF_PROG_RUN(filter->prog, &sd)  // 执行 BPF 过滤器
                   └─ SECCOMP_RET_KILL / TRAP / ALLOW / TRACE / LOG
```

## 2. Landlock

```
Landlock 规则：
  struct landlock_ruleset {
      struct landlock_object **objects;
      access_mask_t access[LANDLOCK_NUM_ACCESS_FS];
  };

文件系统访问检查：
  security_file_open(file)
    └─ hook_file_open()
         └─ landlock_check_access(file, LANDLOCK_ACCESS_FS_READ_FILE)
```

## 3. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct seccomp` | include/linux/seccomp.h | task_struct 内嵌 |
| `seccomp_set_mode_filter()` | kernel/seccomp.c | 相关 |
| `seccomp_run_filters()` | kernel/seccomp.c | BPF 执行 |
| `struct landlock_ruleset` | security/landlock/ | 相关 |
