# seccomp / landlock — 安全沙箱深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/seccomp.c` + `security/landlock/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**seccomp** 限制进程可以调用的系统调用，**Landlock**（4.17+）限制进程的文件系统访问。

---

## 1. seccomp — 系统调用过滤

### 1.1 seccomp_filter — 过滤器

```c
// kernel/seccomp.c — seccomp_filter
struct seccomp_filter {
    // BPF 程序（过滤规则）
    struct sock_fprog           fprog;        // BPF 程序
    atomic_t                    usage;         // 引用计数

    // 模式
    enum seccomp_mode            mode;         // SECCOMP_MODE_FILTER

    // 链表
    struct list_head             list;         // 过滤器链表
};
```

### 1.2 sys_seccomp — 设置过滤

```c
// kernel/seccomp.c — sys_seccomp
SYSCALL_DEFINE3(seccomp, unsigned int, op, unsigned int, flags, void __user *, uargs)
{
    switch (op) {
    case SECCOMP_SET_MODE_STRICT:
        // 白名单：只允许 read/write/exit/_exit/sigreturn
        return seccomp_set_mode_strict(flags);

    case SECCOMP_SET_MODE_FILTER:
        // BPF 过滤：自定义规则
        return seccomp_set_mode_filter(flags, uargs);

    case SECCOMP_GET_ACTION_AVAIL:
        // 查询可用的动作
        return seccomp_get_action_avail(flags);
    }

    return -EINVAL;
}
```

### 1.3 seccomp_run_filters — 执行过滤

```c
// kernel/seccomp.c — seccomp_run_filters
static long seccomp_run_filters(const struct seccomp_data *sd)
{
    struct seccomp_filter *f;
    long ret = SECCOMP_RET_ALLOW;
    long value;

    // 遍历所有过滤器（按优先级）
    for (f = current->seccomp.filter; f; f = f->prev) {
        value = bpf_prog_run(sd, f->prog->filter);

        if (value != SECCOMP_RET_ALLOW)
            ret = value;
    }

    return ret;
}
```

---

## 2. Landlock — 文件系统沙箱

### 2.1 landlock_ruleset — 规则集

```c
// security/landlock/ruleset.c — landlock_ruleset
struct landlock_ruleset {
    // 规则树
    struct landlock_ruleset_domains    *domains;  // 层级规则

    // 访问权限
    unsigned long                      access;    // 可用权限

    // 约束
    unsigned long                      num_rules; // 规则数
    struct landlock_fs_rule            *rules;    // 规则数组
};
```

### 2.2 landlock_create_ruleset — 创建规则集

```c
// security/landlock/syscalls.c — sys_landlock_create_ruleset
SYSCALL_DEFINE2(landlock_create_ruleset, const char __user *, ruleset_ptr,
                size_t, size, unsigned int, flags)
{
    struct landlock_ruleset *ruleset;

    // 1. 解析规则集描述
    ruleset = landlock_alloc_ruleset(ruleset_ptr, size);

    // 2. 创建规则集
    return fd;
}
```

### 2.3 landlock_add_rule — 添加规则

```c
// security/landlock/syscalls.c — sys_landlock_add_rule
SYSCALL_DEFINE3(landlock_add_rule, int, ruleset_fd,
                enum landlock_rule_type, rule_type,
                const void __user *, rule_ptr, unsigned int, flags)
{
    // 添加路径规则到规则集
    // ruleset_fd：规则集 fd
    // rule_ptr：路径和允许的操作
}
```

---

## 3. seccomp vs Landlock

| 特性 | seccomp | Landlock |
|------|---------|----------|
| 限制对象 | 系统调用 | 文件系统访问 |
| 粒度 | 粗（整个 syscall）| 细（read/write/exec）|
| 复杂度 | 低 | 中 |
| 典型用途 | 最小权限 | 容器安全 |

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/seccomp.c` | `sys_seccomp`、`seccomp_run_filters` |
| `security/landlock/ruleset.c` | `landlock_ruleset` |
| `security/landlock/syscalls.c` | `sys_landlock_create_ruleset` |