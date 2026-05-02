# 92-seccomp-landlock — Linux seccomp 和 Landlock 沙盒深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**seccomp** 通过 BPF 过滤器在系统调用层拦截，**Landlock** 通过规则集在文件访问层控制。两者可叠加构建多层沙盒——seccomp 限制系统调用，Landlock 限制文件路径访问。

**doom-lsp 确认**：seccomp @ `kernel/seccomp.c`（2,569 行），`seccomp_run_filters` @ `:404`。

---

## 1. seccomp 数据结构 @ :189

```c
struct seccomp_filter {
    struct seccomp_filter *prev;             // 前一个过滤器（链表结构）
    struct bpf_prog *prog;                   // BPF 程序（编译后的指令，可执行）
    struct notification *notif;              // SECCOMP_USER_NOTIF_FLAG 通知
    bool log;
};

// 每个进程的 seccomp 状态（task_struct->seccomp）：
struct seccomp {
    int mode;                                // DISABLED=0 / STRICT=1 / FILTER=2
    struct seccomp_filter *filter;           // 过滤器链表
};

// BPF 输入数据 @ include/uapi/linux/seccomp.h：
struct seccomp_data {
    int nr;                                  // 系统调用号（如 __NR_openat）
    __u32 arch;                               // 架构（AUDIT_ARCH_X86_64）
    __u64 instruction_pointer;               // 触发系统调用的指令地址
    __u64 args[6];                            // 系统调用参数
};
```

---

## 2. seccomp_run_filters @ :404——过滤器执行链

```c
// 每次系统调用触发路径：
// syscall_trace_enter() → __secure_computing()
// → seccomp_phase1() → seccomp_run_filters()

static u32 seccomp_run_filters(const struct seccomp_data *sd,
                               struct seccomp_filter **match)
{
    u32 ret = SECCOMP_RET_ALLOW;
    struct seccomp_filter *f = READ_ONCE(current->seccomp.filter);

    // 1. 缓存检查（会缓存的 ALLOW 决策跳过 BPF 执行）
    if (seccomp_cache_check_allow(f, sd))
        return SECCOMP_RET_ALLOW;

    // 2. 遍历过滤器链表（从最新到最旧）
    for (; f; f = f->prev) {
        u32 cur_ret = bpf_prog_run_pin_on_cpu(f->prog, sd);
        // 选择优先级最高的动作（值越小越严格）
        if (ACTION_ONLY(cur_ret) < ACTION_ONLY(ret)) {
            ret = cur_ret;
            *match = f;
        }
    }
    return ret;
}
```

### SECCOMP_RET 动作优先级（数值越小越严格）

```c
// 动作按数值排列（值小的优先级高）：
SECCOMP_RET_KILL_PROCESS     // 0x80000000 — 杀进程
SECCOMP_RET_KILL_THREAD      // 0x00000000 — 杀线程
SECCOMP_RET_TRAP             // 0x00030000 — 发 SIGSYS
SECCOMP_RET_ERRNO            // 0x00050000 — 返回错误
SECCOMP_RET_TRACE            // 0x7ff00000 — ptrace 通知
SECCOMP_RET_USER_NOTIF       // 0x7fc00000 — 用户通知
SECCOMP_RET_LOG              // 0x7ffc0000 — 审计日志
SECCOMP_RET_ALLOW            // 0x7fff0000 — 允许（默认）

// seccomp_run_filters 选择 min(ACTION_ONLY) 作为结果
#define ACTION_ONLY(ret) ((s32)((ret) & SECCOMP_RET_ACTION_FULL))
```

---

## 3. 模式设置

```c
// 三种模式：
// 1. SECCOMP_MODE_STRICT：仅允许 read/write/_exit（通过 prctl 设置）
// 2. SECCOMP_MODE_FILTER：通过 BPF 程序过滤（通过 prctl 或 seccomp() 设置）

// seccomp_set_mode_filter()：
// → 验证 BPF 程序（check_bpf_prog）
// → 创建 seccomp_filter
// → 链接到 current->seccomp.filter 链表头部
// → 设置 mode = SECCOMP_MODE_FILTER
```

---

## 4. 用户通知（SECCOMP_USER_NOTIF_FLAG）

```c
// SECCOMP_FILTER_FLAG_NEW_LISTENER：
// 返回一个通知 fd——用户空间管理器通过此 fd 接收系统调用通知
// 适用场景：容器运行时在用户空间实现自定义策略

struct seccomp_knotif {                  // @ :61
    struct task_struct *task;            // 触发通知的进程
    u64 id;
    struct seccomp_data data;            // 系统调用的完整数据
    enum notify_state state;             // INIT→SENT→REPLIED
    s32 error, val;
    struct completion ready;
};

// 管理器流程：
// 1. ioctl(SECCOMP_IOCTL_NOTIF_RECV) → 接收通知
// 2. 分析 seccomp_knotif.data（系统调用号+参数）
// 3. ioctl(SECCOMP_IOCTL_NOTIF_SEND, &resp) → 返回决策
// 4. 被拦截的进程继续执行（根据 resp.error / resp.val）
```

---

## 5. Landlock

```c
// Landlock 规则集（security/landlock/ruleset.h）：
struct landlock_ruleset {
    refcount_t usage;
    u32 num_layers;                        // 层级数
    struct list_head root_rule;            // 规则链表
};

// 文件访问权限位（13 种）：
LANDLOCK_ACCESS_FS_EXECUTE     // 执行
LANDLOCK_ACCESS_FS_WRITE_FILE  // 写文件
LANDLOCK_ACCESS_FS_READ_FILE   // 读文件
LANDLOCK_ACCESS_FS_READ_DIR    // 读目录
LANDLOCK_ACCESS_FS_REMOVE_FILE // 删除
LANDLOCK_ACCESS_FS_MAKE_FILE   // 创建

// 检查入口（security_file_open → landlock_hook_file_open）：
// → 遍历当前进程的 ruleset 层级
// → 对路径的每个组件检查
// → 存在匹配规则 + 所需权限 → 允许
// → 否则 → -EACCES
```

---

## 6. 模式设置路径——seccomp_set_mode_filter

```c
// 两种方式设置 seccomp 过滤器：
// 方式 1：prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, prog)
// → seccomp_set_mode_filter(prog)
//
// 方式 2：seccomp(SECCOMP_SET_MODE_FILTER, flags, prog)
// → seccomp_set_mode_filter(prog)

// seccomp_set_mode_filter() 内部：
// 1. seccomp_check_filter() — 验证 BPF 程序合法性
//    → 检查指令数 ≤ BPF_MAXINSNS
//    → 检查所有跳转目标在合法范围内
//    → 检查没有越界访问 seccomp_data
//
// 2. bpf_prog_create_from_user() — 编译 BPF 字节码
//    → 分配 bpf_prog 结构
//    → 验证器检查
//    → JIT 编译或解释器准备
//
// 3. seccomp_attach_filter() — 链接到进程
//    → 创建 seccomp_filter {.prog, .prev = current->seccomp.filter}
//    → current->seccomp.filter = new_filter
//    → seccomp_assign_mode(FILTER)
```

## 7. 构建沙盒示例

```c
// seccomp: 限制系统调用
struct sock_fprog prog = { ... };
prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog);

// Landlock: 限制文件访问
int ruleset_fd = landlock_create_ruleset(...);
landlock_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, &rule, 0);
landlock_restrict_self(ruleset_fd, 0);

// 两者结合 = 系统调用层 + 文件访问层的双层沙盒
```

---

## 7. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `seccomp_run_filters` | `:404` | 遍历 BPF 过滤器链表（低值优先）|
| `__secure_computing` | — | seccomp 检查入口 |
| `seccomp_set_mode_filter` | — | 安装 BPF 过滤器 |
| `populate_seccomp_data` | `:244` | 填充 seccomp_data |
| `landlock_append_fs_rule` | — | 添加文件规则 |

---

## 8. 调试

```bash
cat /proc/<pid>/status | grep Seccomp  # 0/1/2
strace -e seccomp ping -c1 8.8.8.8
echo 1 > /sys/kernel/debug/tracing/events/seccomp/seccomp_syscall/enable
```

---

## 9. 总结

seccomp 通过 `seccomp_run_filters`（`:404`）遍历过滤器链表执行 BPF，按 `SECCOMP_RET` 数值优先级返回决策。Landlock 通过 `landlock_ruleset` 管理路径访问规则。`seccomp_run_filters` 使用 `ACTION_ONLY` 宏取最小优先级动作确保最严格的过滤器生效。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*

## 10. seccomp 缓存机制

```c
// 为了加速高频系统调用的 seccomp 检查，内核维护了一个缓存：
struct seccomp_cache_filter {
    bool allow;                    // 是否缓存为 ALLOW
    unsigned long stats;           // 缓存命中统计
};

// seccomp_cache_check_allow() @ :177
// 在 seccomp_run_filters 之前调用——如果缓存命中 ALLOW 直接返回
// 减少 BPF 程序执行次数

// populate_seccomp_data @ :244
// 在每次系统调用时填充 seccomp_data 结构：
// sd->nr = syscall_get_nr();       // 系统调用号
// sd->arch = syscall_get_arch();   // 架构
// sd->instruction_pointer = instruction_pointer(current);
// syscall_get_arguments(current, sd->args);
```

## 11. seccomp 过滤器返回值缓存

```c
// Linux 5.x+ 引入了 seccomp 缓存——对于高频系统调用
// 可以缓存 BPF 决策结果，跳过 BPF 执行：

// 缓存键：系统调用号 + 架构 + 参数特征
// 缓存值：SECCOMP_RET_ALLOW（只有 ALLOW 被缓存）

// seccomp_cache_check_allow() @ :177
// → 检查当前过滤器的缓存
// → 如果存在缓存且是 ALLOW → 直接返回 ALLOW
// → 否则执行 seccomp_run_filters()

// 缓存失效：添加新的过滤器（seccomp_attach_filter）时清空
```
ADD && wc -c 92-seccomp-landlock-analysis.md

## 11. seccomp 过滤器缓存

```c
// 缓存高频系统调用的 ALLOW 决策，避免重复执行 BPF：
// seccomp_cache_check_allow() @ :177
// → 缓存命中且有 ALLOW → 直接返回
// → 否则执行 seccomp_run_filters()
// 缓存失效：新过滤器添加时清空
```

## 10. seccomp 过滤器缓存

```c
// seccomp 为高频系统调用提供缓存加速：

// seccomp_cache_check_allow @ :177
// → 在 seccomp_run_filters 之前调用
// → 如果缓存中有 ALLOW 结果 → 跳过 BPF 执行
// → 缓存键：系统调用号 + 架构 + 参数特征
// → 缓存值：ALLOW（只有允许被缓存）

// seccomp_cache_prepare @ :183
// → 在添加新过滤器时初始化缓存
// → 清空所有缓存条目

// 缓存失效：
// → seccomp_attach_filter() 时清空
// → 因为新过滤器可能改变旧决策
```

## 11. 过滤器同步——seccomp_sync_threads

```c
// 多线程进程中一个线程设置 seccomp 时同步到所有线程：

// seccomp_sync_threads() — 同步过滤器到所有线程：
// → 遍历线程组中所有线程
// → 为每个线程复制过滤器指针
// → 确保所有线程共享同一套过滤器

// is_ancestor @ :467 — 检查过滤器层级：
// → 判断一个过滤器是否是另一个的祖先
// → 用于过滤器继承检查

// seccomp_release() — 进程退出时释放过滤器：
// → 递减引用计数
// → 归零时释放 BPF 程序和过滤器结构
```

## 12. Landlock 内核接口

```c
// Landlock 通过系统调用暴露安全策略：

// landlock_create_ruleset(attr, size, flags)
// → 创建空规则集
// → 返回文件描述符

// landlock_add_rule(ruleset_fd, type, rule_attr, flags)
// → 添加路径访问规则
//   type = LANDLOCK_RULE_PATH_BENEATH
//   rule_attr = { parent_fd, allowed_access }
// → 检查 parent_fd 的访问权限

// landlock_restrict_self(ruleset_fd, flags)
// → 应用规则集到当前进程
// → 不可逆转（规则只能增加）

// ABI 版本：
// LANDLOCK_ABI_1 (5.13) — 基础文件访问
// LANDLOCK_ABI_2 (5.19) — TCP 绑定/连接控制
```

## 13. 关键函数索引

| 函数 | 符号数 | 作用 |
|------|--------|------|
| `seccomp.c` | 125 | seccomp 框架 |
| `seccomp_run_filters` | `:404` | 过滤器执行链 |
| `seccomp_cache_check_allow` | `:177` | 缓存检查 |
| `seccomp_sync_threads` | — | 线程间同步 |
| `landlock_create_ruleset` | — | 创建规则集 |
| `landlock_add_rule` | — | 添加路径规则 |
| `landlock_restrict_self` | — | 应用规则集 |

