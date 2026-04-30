# capabilities / prctl — 进程权能深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/capability.c` + `kernel/sys.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**capabilities** 将 root 的"全有或全无"权限细分为独立的权能单元（CAP_SYS_ADMIN、CAP_NET_ADMIN 等）。

---

## 1. 核心数据结构

### 1.1 cred — 凭证

```c
// include/linux/cred.h — cred
struct cred {
    // 用户
    uid_t               uid;            // 真实 UID
    gid_t               gid;            // 真实 GID
    uid_t               suid;           // 保存的 UID
    uid_t               euid;           // 有效 UID
    uid_t               fsuid;          // 文件系统 UID
    gid_t               sgid;           // 保存的 GID
    gid_t               egid;           // 有效 GID
    gid_t               fsgid;          // 文件系统 GID

    // 权能
    kernel_cap_t       cap_inheritable; // 继承权能（容器）
    kernel_cap_t       cap_permitted;   // 可用权能
    kernel_cap_t       cap_effective;   // 有效权能
    kernel_cap_t       cap_bset;        // 边界集合（capabilities bitmap）

    // 安全
    struct security_key  *security;     // 安全模块数据
};
```

### 1.2 kernel_cap_t — 权能集合

```c
// include/linux/capability.h — kernel_cap_t
typedef __u32 kernel_cap_t;

#define CAP_CHOWN         0   // 改变文件所有者
#define CAP_DAC_OVERRIDE  1   // 绕过 DAC 读取检查
#define CAP_DAC_READ_SEARCH 2 // 绕过 DAC 写入/执行检查
#define CAP_FOWNER        3   // 跳过所有者检查
#define CAP_FSETID        4   // 设置 setuid/gid
#define CAP_KILL          5   // 发送信号
#define CAP_SETGID        6   // 改变 GID
#define CAP_SETUID        7   // 改变 UID
#define CAP_SETPCAP       8   // 修改其他进程的权能
#define CAP_LINUX_IMMUTABLE 9 // 设置只读文件属性
#define CAP_NET_BIND_SERVICE 10 // 绑定小于 1024 的端口
#define CAP_NET_BROADCAST  11  // 广播/多播
#define CAP_NET_ADMIN      12  // 网络管理（ifconfig/route）
#define CAP_NET_RAW        13 // 原始套接字
#define CAP_IPC_LOCK       14 // 锁定共享内存
#define CAP_IPC_OWNER       15 // IPC 操作权限
#define CAP_SYS_MODULE     16  // 加载内核模块
#define CAP_SYS_RAWIO      17  // 原始 I/O（/dev/kmem）
#define CAP_SYS_CHROOT     18  // chroot
#define CAP_SYS_PTRACE     19  // ptrace
#define CAP_SYS_PACCT      20  // 进程记账
#define CAP_SYS_ADMIN      21  // 系统管理（mount/shutdown）
#define CAP_SYS_BOOT       22  // reboot
#define CAP_SYS_NICE       23  // 改变调度优先级
#define CAP_SYS_RESOURCE   24  // 资源限制
#define CAP_SYS_TIME       25  // 设置系统时间
#define CAP_SYS_TTY_CONFIG 26  // TTY 配置
#define CAP_MKNOD          27  // 创建设备文件
#define CAP_LEASE          28  // 文件租约
#define CAP_AUDIT_WRITE    29 // 写审计日志
#define CAP_AUDIT_CONTROL  30 // 审计配置
```

---

## 2. 检查权能

### 2.1 capable — 检查有效权能

```c
// kernel/capability.c — capable
int capable(int cap)
{
    struct cred *cred = current_cred();

    // 检查有效权能集合中是否有 cap
    if (cap_raised(cred->cap_effective, cap))
        return 1;

    return 0;
}

// cap_raised 实现：
#define cap_raised(c, cap) \
    (__builtin_choose_expr(sizeof(c) == sizeof(u32), \
        (c).cap[CAP_TO_INDEX(cap)] & CAP_TO_BIT(cap), \
        BUG()))
```

---

## 3. prctl — 进程控制

### 3.1 prctl(PR_CAPBSET_READ, cap, 0, 0, 0)

```c
// kernel/sys.c — prctl
SYSCALL_DEFINE5(prctl, int, option, unsigned long, arg2, unsigned long, arg3,
                unsigned long, arg4, unsigned long, arg5)
{
    switch (option) {
    case PR_CAPBSET_READ:
        // 检查某个权能是否在边界集合中
        if (arg2 >= CAP_LAST_CAP)
            return -EINVAL;
        return !!cap_raised(current_cap_bset(), arg2);

    case PR_CAPBSET_DROP:
        // 从边界集合删除权能（仅 root）
        if (!capable(CAP_SETPCAP))
            return -EPERM;
        cap_lower(current_cap_bset(), arg2);
        return 0;

    case PR_SET_KEEPCAPS:
        // 设置保持权能标志
        if (arg2)
            current->keep_capabilities = 1;
        else
            current->keep_capabilities = 0;
        return 0;

    case PR_SET_SECUREBITS:
        // 设置安全位
        current->securebits = arg2;
        return 0;

    case PR_SET_NO_NEW_PRIVS:
        // 设置 no_new_privs（execve 不能获取新权能）
        current->no_new_privs = arg2;
        return 0;
    }

    return -EINVAL;
}
```

---

## 4. Securebits

```c
// include/linux/securebits.h — securebits
#define SECBIT_KEEP_CAPS       0x00000001  // 保持权能标志
#define SECBIT_NO_SETUID_FIXUP 0x00000002  // 不修复 setuid
#define SECBIT_NOROOT         0x00000004  // 不授予 root 权能
#define SECBIT_NOROOT_SLOCK   0x00000008  // 安全锁
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/cred.h` | `struct cred` |
| `include/linux/capability.h` | `kernel_cap_t`、`CAP_*` 定义 |
| `kernel/capability.c` | `capable` |
| `kernel/sys.c` | `sys_prctl` |