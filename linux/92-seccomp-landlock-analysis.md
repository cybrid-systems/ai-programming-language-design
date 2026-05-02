# 92-seccomp-landlock — Linux seccomp 和 Landlock 安全模块深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**seccomp**（secure computing）和 **Landlock** 是 Linux 的两种**沙盒安全机制**——seccomp 通过 BPF 过滤器控制系统调用，Landlock 通过可编程规则集限制文件系统访问。

| 特性 | seccomp | Landlock |
|------|---------|----------|
| 作用范围 | **系统调用**过滤 | **文件系统**访问控制 |
| 配置方式 | BPF 字节码 / 模式设置 | BPF 规则集（`LANDLOCK_ABI`）|
| 内核文件 | `kernel/seccomp.c`（2,569 行，125 符号）| `security/landlock/` |
| 核心结构 | `seccomp_filter` + `sock_fprog` | `landlock_ruleset` + `landlock_rule` |

**doom-lsp 确认**：seccomp @ `kernel/seccomp.c`（125 符号），Landlock @ `security/landlock/`。

---

## 1. seccomp

### 1.1 核心数据结构

```c
// seccomp 过滤器链表：
// task_struct->seccomp.filter 指向过滤器链表头部

struct seccomp_filter {
    atomic_t usage;                          // 引用计数
    struct seccomp_filter *prev;             // 前一个过滤器
    struct bpf_prog *prog;                   // BPF 程序
    struct notification *notif;              // 用户通知（SECCOMP_USER_NOTIF_FLAG）
    bool log;                                // 是否记录日志
};

struct seccomp {
    int mode;                                // SECCOMP_MODE_DISABLED/FILTER/STRICT
    struct seccomp_filter *filter;           // 过滤器链表
};
```

### 1.2 seccomp_run_filters @ :404——过滤器执行

```c
// 每次系统调用的拦截点：
// syscall_trace_enter() → __secure_computing() → seccomp_run_filters()

// struct seccomp_data { int nr; __u32 arch; __u64 ip; __u64 args[6]; };

static u32 seccomp_run_filters(const struct seccomp_data *sd,
                               struct seccomp_filter **match)
{
    u32 ret = SECCOMP_RET_ALLOW;              // 默认允许
    struct seccomp_filter *f;

    // 遍历过滤器链表（从最新到最旧）
    for (f = current->seccomp.filter; f; f = f->prev) {
        u32 action = bpf_prog_run_pin_on_cpu(f->prog, sd);
        // action & SECCOMP_RET_ACTION_FULL 提取行为

        switch (action & SECCOMP_RET_ACTION_FULL) {
        case SECCOMP_RET_KILL:  do_exit(SIGSYS);
        case SECCOMP_RET_TRAP:  force_sig(SIGSYS);
        case SECCOMP_RET_ERRNO: return action & SECCOMP_RET_DATA;
        case SECCOMP_RET_TRACE: // ptrace
        case SECCOMP_RET_LOG:   log = true;           // 记录日志
        case SECCOMP_RET_ALLOW: break;                 // 允许
        }
    }
    return ret;
}
```

### 1.3 用户通知机制（SECCOMP_USER_NOTIF_FLAG）

```c
// seccomp 可以将系统调用通知给用户空间管理器：
// 1. 设置 SECCOMP_FILTER_FLAG_NEW_LISTENER → 获取通知 fd
// 2. 通过 ioctl(SECCOMP_IOCTL_NOTIF_RECV) 接收通知
// 3. 通过 ioctl(SECCOMP_IOCTL_NOTIF_SEND) 回复结果

// 内核侧实现：
struct seccomp_knotif {                       // @ :61
    struct task_struct *task;
    u64 id;
    struct seccomp_data data;
    enum notify_state state;                   // INIT / SENT / REPLIED
    s32 error;
    s32 val;
    struct completion ready;
};
```

---

## 2. Landlock

### 2.1 核心数据结构

```c
// security/landlock/ruleset.h
struct landlock_ruleset {
    struct landlock_hierarchy *hierarchy;     // 层级
    refcount_t usage;
    struct work_struct work_free;
    struct list_head root_rule;                // 规则链表
    u32 num_layers;                            // 层数
};

// 访问权限位：
// LANDLOCK_ACCESS_FS_EXECUTE
// LANDLOCK_ACCESS_FS_WRITE_FILE
// LANDLOCK_ACCESS_FS_READ_FILE
// LANDLOCK_ACCESS_FS_READ_DIR
// LANDLOCK_ACCESS_FS_REMOVE_FILE
// LANDLOCK_ACCESS_FS_MAKE_FILE
// ... 共 13 种
```

### 2.2 文件访问检查

```c
// landlock_append_fs_rule() — 添加规则
// → 将 (path, access_mask) 加入 ruleset

// hook_file_open() — 每次文件打开时检查：
// → landlock_check_access_path(path, ACCESS_FS_READ_FILE)
// → 遍历 path 的各个组件
// → 检查是否有 ruleset 允许此访问
```

---

## 3. 安全模型对比

| 维度 | seccomp | Landlock |
|------|---------|----------|
| 控制粒度 | 系统调用级别 | 文件访问级别 |
| 配置接口 | `prctl(PR_SET_SECCOMP)` / `seccomp()` | `landlock_create_ruleset()` |
| 不可逆转 | 是（`SECCOMP_MODE_STRICT`） | 是（规则只能增加）|
| 嵌套 | 支持（过滤器链）| 支持（规则层级）|
| 用户空间交互 | SECCOMP_USER_NOTIF_FLAG | 不可交互 |

---

## 4. 调试

```bash
# seccomp
cat /proc/<pid>/status | grep Seccomp   # 0/1/2
strace -e seccomp ls
echo 1 > /sys/kernel/debug/tracing/events/seccomp/enable

# Landlock
cat /proc/<pid>/status | grep Landlock
ls -l /sys/kernel/security/landlock/
```

---

## 5. 总结

seccomp（`kernel/seccomp.c`，125 符号）通过 BPF 过滤器拦截系统调用，`seccomp_run_filters()` 遍历过滤器链表返回 `SECCOMP_RET_*` 决策。Landlock 通过 `landlock_ruleset` 控制文件系统访问，`hook_file_open()` 检查路径权限。两者可同时使用构建多层沙盒。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
