# 97-capabilities-prctl — Linux 能力（capabilities）和 prctl 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**capabilities** 将 root 超级权限分割为 40 个独立单元（`CAP_NET_RAW`、`CAP_DAC_OVERRIDE` 等），每个进程通过 `struct cred` 中的 3 组 64 位能力位图控制。**prctl**（process control）提供 30+ 进程级控制命令。

**doom-lsp 确认**：capabilities @ `kernel/capability.c`（503 行，57 符号），prctl @ `kernel/sys.c`。

---

## 1. 核心数据结构

```c
// include/linux/capability.h
typedef struct {
    __u32 cap[_LINUX_CAPABILITY_U32S_3];
} kernel_cap_t;                         // 64 位能力位图

// struct cred（进程凭证）：
struct cred {
    kernel_cap_t cap_effective;   // 当前生效的能力（内核真正检查的位图）
    kernel_cap_t cap_permitted;   // 允许拥有的能力（superior set）
    kernel_cap_t cap_inheritable; // 可被子进程继承的能力
    kernel_cap_t cap_bset;        // 边界集（限制子进程获得的能力）
    kernel_cap_t cap_ambient;     // 环境能力（Linux 4.3+，非特权用户可用）
};
```

---

## 2. capget 系统调用 @ :137

```c
SYSCALL_DEFINE2(capget, cap_user_header_t, header, cap_user_data_t, dataptr)
{
    // 1. 验证版本
    ret = cap_validate_magic(header, &tocopy);

    // 2. 获取目标进程 PID
    get_user(pid, &header->pid);

    // 3. 读取目标进程能力
    ret = cap_get_target_pid(pid, &pE, &pI, &pP);
    // → lock_task_sighand(target, &flags)
    // → pE = target->cred->cap_effective
    // → pP = target->cred->cap_permitted
    // → pI = target->cred->cap_inheritable

    // 4. 64 位能力拆分为两个 32 位字段（兼容老 libcap）
    kdata[0].effective   = pE.val;      // 低 32 位
    kdata[1].effective   = pE.val >> 32; // 高 32 位

    copy_to_user(dataptr, kdata, tocopy * sizeof(kdata[0]));
}
```

---

## 3. capset 系统调用——设置能力

```c
SYSCALL_DEFINE2(capset, cap_user_header_t, header, const cap_user_data_t, data)
{
    // 设置规则：
    // 1. 新 permitted ⊆ 旧 permitted（不能获得未拥有的能力）
    // 2. 新 inheritable ⊆ 旧 permitted
    // 3. 新 effective ⊆ 新 permitted
    // 4. setuid 程序的安全转换规则也适用
}
```

---

## 4. 文件能力——exec 时的能力提升

```c
// setcap cap_net_raw+ep /usr/bin/ping 设置了文件的 security.capability xattr

// exec 时 bprm_set_creds() 处理文件能力：
static int cap_bprm_set_creds(struct linux_binprm *bprm)
{
    // 1. 从文件的 security.capability xattr 读取能力
    // 2. 新 permitted = file_caps | (old_permitted & old_inheritable)
    // 3. 新 effective = file_effective ? new_permitted : 0
    // 4. 新 inheritable = old_inheritable
    // 5. 新 ambient = 0（exec 后重置）
}
```

---

## 5. 能力检查路径——cap_capable

```c
// 内核中每次能力检查：
// capable(CAP_NET_RAW) → ns_capable(ns, cap)
// → security_capable(cred, ns, cap, opts)
//   → cap_capable(cred, ns, cap, opts)
//     → 检查 cred->cap_effective 是否包含请求的能力
//     → 如果是 → 返回 0（允许）
//     → 否则 → 返回 -EPERM（拒绝）

// 网络 socket 创建时的检查：
// sock_create() → security_socket_create()
// → selinux_socket_create() 或 cap_socket_create()
// → ns_capable(current_cred(), net_ns, CAP_NET_RAW)
```

---

## 6. prctl——进程控制

```c
// SYSCALL_DEFINE5(prctl, int, option, unsigned long, arg2, ...)
// → __do_sys_prctl() 通过 switch(option) 分发：

// 安全相关：
// PR_SET_SECCOMP( arg2 == SECCOMP_MODE_FILTER, arg3 = prog_ptr )
//   → seccomp_set_mode_filter(prog) → 安装 BPF 过滤器
// PR_GET_SECCOMP → seccomp_get_mode()

// 进程标识：
// PR_SET_NAME(arg2) → set_task_comm(current, comm) → /proc/self/comm
// PR_GET_NAME → get_task_comm()

// 父进程死亡信号：
// PR_SET_PDEATHSIG(arg2)
//   → current->pdeath_signal = arg2
//   → 父进程退出时发送此信号

// 能力保持：
// PR_SET_KEEPCAPS(arg2)
//   → current->mm->flags = arg2 ? MMF_HAS_MLOCKED : 0
//   用于 setuid 程序——setuid 后保持能力

// 内存映射修改：
// PR_SET_MM(PR_SET_MM_START_CODE, addr)
//   → 修改进程的 mm_struct 字段
//   需要 CAP_SYS_RESOURCE
```

---

## 7. 调试

```bash
# 查看进程能力
cat /proc/<pid>/status | grep Cap
# CapInh: 0000000000000000   — inheritable
# CapPrm: 0000000000000400   — permitted
# CapEff: 0000000000000400   — effective
# CapBnd: 0000003fffffffff   — bounding set
# CapAmb: 0000000000000000   — ambient

capsh --decode=0000000000000400  # → cap_net_raw

# 查看文件能力
getcap /usr/bin/ping
setcap cap_net_raw+ep /usr/bin/ping

# strace prctl
strace -e prctl ls
```

---

## 8. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `SYSCALL_DEFINE2(capget)` | `:137` | 获取进程能力 |
| `SYSCALL_DEFINE2(capset)` | `:217` | 设置进程能力 |
| `cap_get_target_pid` | `:105` | 读取目标进程能力 |
| `cap_bprm_set_creds` | — | 文件能力 exec 处理 |
| `cap_capable` | — | 能力检查 |
| `SYSCALL_DEFINE5(prctl)` | `kernel/sys.c` | prctl 入口 |

---

## 9. 总结

capabilities（`kernel/capability.c`，57 符号）通过 `cred->cap_effective` 64 位位图管理 40 种权限。`capget`（`:137`）读取、`capset`（`:217`）写入、文件能力在 `cap_bprm_set_creds` exec 时生效、`cap_capable` 运行时检查。`prctl` 通过 `__do_sys_prctl` 分发 30+ 子命令。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
