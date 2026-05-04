# 096-capabilities-prctl — Linux 能力（capabilities）系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码 | 使用 doom-lsp 进行逐行符号解析

---

## 0. 概述

**Linux Capabilities** 是将传统超级用户（root）权限拆分为独立单元的机制。一个进程拥有 `CAP_NET_RAW` 可以打开 raw socket，拥有 `CAP_SYS_ADMIN` 可以挂载文件系统——而不需要 full root。每个进程有三组 capability 集：**effective**（当前生效）、**permitted**（允许使用）、**inheritable**（可被子进程继承）。

---

## 1. 核心数据结构

### 1.1 `struct cred` 中的 capability 字段

（`include/linux/cred.h` — doom-lsp 确认）

```c
struct cred {
    ...
    struct user_namespace *user_ns;     // 用户命名空间的 capability 边界
    
    /* 传统 POSIX capabilities */
    kernel_cap_t    cap_effective;      // 当前生效的能力
    kernel_cap_t    cap_permitted;      // 允许使用的能力
    kernel_cap_t    cap_inheritable;    // 可继承的能力
    kernel_cap_t    cap_bset;           // 边界集（限制子进程）
    kernel_cap_t    cap_ambient;        // 环境集（capabilities 持久化）
    ...
};
```

### 1.2 `kernel_cap_t` 结构

```c
typedef struct {
    __u32 cap[_CAP_LAST_U32 + 1];      // 位图：每位对应一个 capability
} kernel_cap_t;
// _CAP_LAST_U32 在 x86-64 上 = 1（共 64 位）
// 当前定义了 ~40 个 capability（CAP_CHOWN, CAP_NET_RAW, CAP_SYS_ADMIN...）
```

---

## 2. 关键执行路径

### 2.1 execve 时的 capability 转换

```
execve() 时的 capability 计算（security_compute_effective()）：
  P'(permitted)  = (P(inheritable) & F(inheritable)) |
                     (F(permitted) & cap_bset)
  P'(effective)  = F(effective) ? P'(permitted) : 0
  P'(inheritable)= P(inheritable)

  P = exec 前进程的 capabilities
  P' = exec 后进程的 capabilities
  F = 可执行文件的 capabilities（file capabilities）
  
  如果文件没有设置 capabilities：
    P'(permitted) = cap_bset（边界集限制了 root 能力的继承）
    P'(effective) = 0（传统 suid 程序除外）
```

### 2.2 prctl 操作

```
prctl(PR_SET_KEEPCAPS, 1)   // 保持 capabilities（setuid 后不丢弃）
prctl(PR_SET_SECCOMP, ...)  // 设置 seccomp 过滤
prctl(PR_SET_NO_NEW_PRIVS, 1) // 禁止提权（execve 也不获得新权限）
capget() / capset()         // 获取/设置 capabilities
```

### 2.3 安全检查

```c
// security/commoncap.c
// 每次权限检查调用 cap_capable():
int cap_capable(const struct cred *cred, struct user_ns *targ_ns,
                int cap, unsigned int opts)
{
    // 1. 如果 cap 在当前 ns 的 effective 集中 → 通过
    if (cap_raised(cred->cap_effective, cap))
        return 0;

    // 2. 如果不是 root → 返回 -EPERM
    if (!uid_eq(cred->euid, GLOBAL_ROOT_UID) ||
        !ns_capable(targ_ns, cap))
        return -EPERM;

    return 0;
}
```

---

## 3. capability 种类（部分）

| 能力 | 编号 | 用途 |
|------|------|------|
| CAP_CHOWN | 0 | 更改文件所有者 |
| CAP_NET_RAW | 13 | 打开 raw socket |
| CAP_NET_ADMIN | 12 | 网络管理（路由、防火墙） |
| CAP_SYS_ADMIN | 21 | 系统管理（挂载、命名空间） |
| CAP_SYS_PTRACE | 19 | ptrace 其他进程 |
| CAP_DAC_OVERRIDE | 1 | 绕过文件权限检查 |
| CAP_SETUID | 6 | 任意设置 UID |

---

## 4. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct cred` | include/linux/cred.h | 核心结构 |
| `kernel_cap_t` | include/linux/capability.h | 类型定义 |
| `cap_capable()` | security/commoncap.c | 安全检查 |
| `capget()` | kernel/capability.c | syscall |
| `capset()` | kernel/capability.c | syscall |
| `prctl()` | kernel/sys.c | PR_SET_KEEPCAPS 等 |
| `security_compute_effective()` | security/commoncap.c | execve 时转换 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04 | 内核版本：Linux 7.0-rc1*
