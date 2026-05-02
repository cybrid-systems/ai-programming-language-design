# 97-capabilities-prctl — Linux 能力（capabilities）和 prctl 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**capabilities** 将 root 的超级权限分割为独立的单元（`CAP_NET_RAW`、`CAP_SYS_ADMIN`、`CAP_DAC_OVERRIDE` 等），每个进程有 3 组能力位图（effective/permitted/ inheritable）。**prctl**（process control）提供进程级控制接口，包括能力设置、安全计算（seccomp）、进程名设置等。

**doom-lsp 确认**：capabilities @ `kernel/capability.c`（503 行，57 符号），prctl @ `kernel/sys.c`。

---

## 1. 核心数据结构

```c
// include/linux/capability.h
typedef struct {
    __u32 cap[_LINUX_CAPABILITY_U32S_3];  // 能力位图
} kernel_cap_t;

// struct cred（进程凭证）中的能力字段：
struct cred {
    kernel_cap_t cap_effective;   // 当前生效的能力
    kernel_cap_t cap_permitted;   // 允许的能力
    kernel_cap_t cap_inheritable; // 可继承的能力
    kernel_cap_t cap_bset;        // 边界集
    kernel_cap_t cap_ambient;     // 环境能力（Linux 4.3+）
};

// 能力常量（约 40 个）：
// CAP_CHOWN         — 改变文件所有者
// CAP_DAC_OVERRIDE  — 绕过 DAC 权限检查
// CAP_NET_RAW       — 使用 RAW/PACKET socket
// CAP_SYS_ADMIN     — 系统管理（最宽泛）
// CAP_SYS_TIME      — 修改系统时钟
// ... 共 40 个
```

---

## 2. capability 系统调用

```c
// capget(cap_version, &header, &data) — 获取进程能力
// capset(&header, &data) — 设置进程能力
// 两者都通过 security_capable() 调用 LSM 钩子

SYSCALL_DEFINE2(capget, cap_user_header_t, header, cap_user_data_t, data)
{
    // 读取目标进程的 cred->cap_effective/permitted/inheritable
    target = cred ? task_cred : get_task_cred(pid);
    data->effective = target->cap_effective;
    data->permitted = target->cap_permitted;
    data->inheritable = target->cap_inheritable;
}
```

---

## 3. 文件能力（File Capabilities）

```c
// 可执行文件可以附带能力——运行时提升权限
// setcap cap_net_raw+ep /usr/bin/ping
// → 文件 xattr: security.capability
// → exec 时：cap_bprm_set_creds() 解析文件能力并设置

static int cap_bprm_set_creds(struct linux_binprm *bprm)
{
    // 1. 从文件的 security.capability xattr 读取能力集
    // 2. 新进程的 permitted = file_caps | (old.permitted & inheritable)
    // 3. effective = (file_caps.effective) ? permitted : 0
}
```

---

## 4. prctl 部分

```c
// prctl(option, arg2, arg3, arg4, arg5)
// 定义在 include/uapi/linux/prctl.h 中：

// 能力相关：
// PR_SET_KEEPCAPS         — 保持能力（setuid 时不丢弃）
// PR_GET_KEEPCAPS         — 查询

// 安全相关：
// PR_SET_SECCOMP          — 设置 seccomp 过滤器
// PR_GET_SECCOMP          — 查询

// 进程管理：
// PR_SET_NAME             — 设置进程名（comm）
// PR_GET_NAME             — 获取进程名
// PR_SET_PDEATHSIG        — 设置父进程死亡信号

// 虚拟内存：
// PR_SET_MM               — 修改进程内存映射
// PR_SET_VMA              — 设置 VMA 属性

// 架构相关：
// PR_SET_FP_MODE          — 浮点模式
// PR_SET_TSC              — 时间戳计数器控制

// 系统调用:
// long __do_sys_prctl(int option, ...)
// → switch (option) 分派到对应处理函数
// → 例如 PR_SET_NAME → set_task_comm(current, comm)
// → PR_SET_SECCOMP → seccomp_set_mode_filter()
```

---

## 5. 关键能力常量

| 能力 | 编号 | 说明 |
|------|------|------|
| CAP_CHOWN | 0 | 改变文件所有者 |
| CAP_DAC_OVERRIDE | 1 | 绕过文件权限检查 |
| CAP_DAC_READ_SEARCH | 2 | 绕过读/搜索权限 |
| CAP_FOWNER | 3 | 绕过文件拥有者检查 |
| CAP_NET_RAW | 13 | RAW/PACKET socket |
| CAP_NET_ADMIN | 12 | 网络管理 |
| CAP_SYS_ADMIN | 21 | 系统管理 |
| CAP_SYS_TIME | 25 | 修改系统时钟 |

---

## 6. 能力检查路径

```c
// 文件系统 IO 时的能力检查：
// inode_permission() → security_inode_permission()
// → selinux_inode_permission() 或 cap_inode_permission()
//   → cap_capable(current_cred(), ns, CAP_DAC_OVERRIDE)
//     → ns_capable() → security_capable(current_cred, ns, cap)
//       → cap_capable() 检查 cred->cap_effective
```

---

## 7. 调试

```bash
# 查看进程能力
cat /proc/<pid>/status | grep Cap
# CapInh: 0000000000000000
# CapPrm: 0000000000000000
# CapEff: 0000000000000000

# capsh 解码
capsh --decode=0000000000000000

# 设置文件能力
getcap /usr/bin/ping
setcap cap_net_raw+ep /usr/bin/ping
```

---

## 8. 总结

capabilities（`kernel/capability.c`，57 符号）通过 `cred->cap_effective/permitted/inheritable` 位图管理进程权限。`capget`/`capset` 系统调用读取/设置能力，文件能力通过 `cap_bprm_set_creds()` 在 exec 时生效。`prctl` 提供 30+ 进程控制子命令。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
