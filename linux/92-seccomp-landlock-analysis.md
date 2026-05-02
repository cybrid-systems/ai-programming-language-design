# 92-seccomp-landlock — Linux seccomp 和 Landlock 沙盒机制深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**seccomp**（secure computing）通过 BPF 过滤器拦截系统调用，**Landlock** 通过规则集限制文件系统访问。seccomp 作用于系统调用层，Landlock 作用于文件访问层，两者可叠加使用构建多层沙盒。

**doom-lsp 确认**：seccomp @ `kernel/seccomp.c`（2,569 行），Landlock @ `security/landlock/`。

---

## 1. seccomp 核心

### 1.1 核心数据结构

```c
// kernel/seccomp.c:189
struct seccomp_filter {
    struct seccomp_filter *prev;             // 前一个过滤器（链表）
    struct bpf_prog *prog;                   // BPF 程序（编译后的指令）
    struct notification *notif;              // 用户通知（SECCOMP_USER_NOTIF_FLAG）
    bool log;                                // 是否记录日志
    struct seccomp_cache_filter cache;       // 缓存
};

// seccomp 配置（task_struct->seccomp）：
struct seccomp {
    int mode;                                // DISABLED / FILTER / STRICT
    struct seccomp_filter *filter;           // 过滤器链表头
};
```

### 1.2 struct seccomp_data——BPF 程序输入

```c
// BPF 程序看到的输入结构：
struct seccomp_data {
    int nr;                                  // 系统调用号
    __u32 arch;                               // 架构 AUDIT_ARCH_X86_64
    __u64 instruction_pointer;                // 指令指针
    __u64 args[6];                            // 前 6 个参数
};
```

### 1.3 seccomp_run_filters @ :404——过滤器执行

```c
// 每次系统调用触发：
// syscall_trace_enter() → __secure_computing() → seccomp_run_filters()

static u32 seccomp_run_filters(const struct seccomp_data *sd,
                               struct seccomp_filter **match)
{
    u32 ret = SECCOMP_RET_ALLOW;
    struct seccomp_filter *f;

    // 遍历过滤器链表（从最新到最旧叠加）
    for (f = current->seccomp.filter; f; f = f->prev) {
        u32 action = bpf_prog_run_pin_on_cpu(f->prog, sd);
        // 执行 BPF 字节码，返回动作 + 数据

        switch (action & SECCOMP_RET_ACTION_FULL) {
        case SECCOMP_RET_KILL_PROCESS:   // 终止进程
            do_exit(SIGSYS);
        case SECCOMP_RET_KILL_THREAD:    // 终止线程
            do_exit(SIGSYS);
        case SECCOMP_RET_TRAP:           // 发送 SIGSYS
            force_sig(SIGSYS);
        case SECCOMP_RET_ERRNO:          // 返回错误码
            return action & SECCOMP_RET_DATA;
        case SECCOMP_RET_TRACE:          // ptrace 通知
        case SECCOMP_RET_USER_NOTIF:     // seccomp 用户通知
        case SECCOMP_RET_LOG:            // 记录日志
        case SECCOMP_RET_ALLOW:          // 允许
            break;
        }
    }
    return ret;
}
```

### 1.4 SECCOMP_RET_ACTION 动作表

```c
// 动作优先级从高到低：
SECCOMP_RET_KILL_PROCESS   // 立即杀进程
SECCOMP_RET_KILL_THREAD    // 杀线程
SECCOMP_RET_TRAP           // SIGSYS
SECCOMP_RET_ERRNO          // 返回 errno（arg & SECCOMP_RET_DATA）
SECCOMP_RET_TRACE          // 通知 ptrace 追踪器
SECCOMP_RET_USER_NOTIF     // 通知用户空间管理器（SECCOMP_FILTER_FLAG_NEW_LISTENER）
SECCOMP_RET_LOG            // 记录审计日志
SECCOMP_RET_ALLOW          // 允许（默认）
```

### 1.5 用户通知机制（SECCOMP_USER_NOTIF_FLAG）

```c
// SECCOMP_FILTER_FLAG_NEW_LISTENER 允许将 seccomp 决策委托给用户空间管理器：
// 1. 设置过滤器时指定 NEW_LISTENER → 获取通知 fd
// 2. 管理进程通过 ioctl(SECCOMP_IOCTL_NOTIF_RECV) 接收系统调用通知
// 3. 通过 ioctl(SECCOMP_IOCTL_NOTIF_SEND) 返回决策

struct seccomp_knotif {                  // 用户空间通知 @ :61
    struct task_struct *task;
    u64 id;
    struct seccomp_data data;            // 系统调用数据
    enum notify_state state;             // INIT / SENT / REPLIED
    s32 error;
    s32 val;
    struct completion ready;
};
```

---

## 2. Landlock 安全

### 2.1 数据结构

```c
// security/landlock/ruleset.h
struct landlock_ruleset {
    refcount_t usage;
    struct list_head root_rule;           // 规则链表
    u32 num_layers;                       // 层级数
};

// 文件访问权限位：
// LANDLOCK_ACCESS_FS_EXECUTE       — 执行
// LANDLOCK_ACCESS_FS_WRITE_FILE    — 写文件
// LANDLOCK_ACCESS_FS_READ_FILE     — 读文件
// LANDLOCK_ACCESS_FS_READ_DIR      — 读目录
// LANDLOCK_ACCESS_FS_REMOVE_FILE   — 删除文件
// LANDLOCK_ACCESS_FS_MAKE_FILE     — 创建文件
// ... 共 13 种
```

### 2.2 hook_file_open——文件打开检查

```c
// 每次文件 open 时调用：
// security_file_open() → landlock_hook_file_open()
// → 遍历当前进程的 ruleset
// → 对路径的每个组件检查是否有 LANDLOCK_ACCESS_FS_READ_FILE
```

---

## 3. 构建沙盒示例

```c
// seccomp: 限制系统调用
struct sock_fprog prog = { ... };
prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog);

// Landlock: 限制文件访问
int ruleset_fd = landlock_create_ruleset(...);
landlock_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, &rule, 0);
landlock_restrict_self(ruleset_fd, 0);
```

---

## 4. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `seccomp_run_filters` | `:404` | 遍历 BPF 过滤器 |
| `__secure_computing` | — | seccomp 检查入口 |
| `seccomp_set_mode_filter` | — | 安装 BPF 过滤器 |
| `populate_seccomp_data` | `:244` | 填充 seccomp_data |
| `landlock_append_fs_rule` | — | 添加文件规则 |

---

## 5. 调试

```bash
# seccomp
cat /proc/<pid>/status | grep Seccomp
strace -e seccomp ls

# Landlock
cat /proc/<pid>/status | grep Landlock
```

---

## 6. 总结

seccomp 通过 `seccomp_run_filters`（`:404`）执行 BPF 过滤器，按优先级返回 `SECCOMP_RET_KILL`→`ALLOW` 决策。Landlock 通过 `landlock_ruleset` + `hook_file_open` 在文件打开时检查路径权限。两者可叠加构建 seccomp（系统调用层）+ Landlock（文件访问层）的多层沙盒。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
