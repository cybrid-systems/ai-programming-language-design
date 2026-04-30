# Linux Kernel Audit (深入) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/audit*.c` + `net/netlink/audit.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. audit 子系统概述

**audit** 记录系统调用的安全相关信息（文件名、UID、返回值），通过 **netlink** 套接字发送给用户空间 `auditd`。

---

## 1. 核心结构

```c
// kernel/audit.h — audit_context
struct audit_context {
    int                 in_syscall;        // 是否在 syscalls 中
    enum audit_state    state;             // AUDIT_STATE_*（记录/不记录）
    unsigned int        major;             // 系统调用号
    unsigned long       argv[6];           // 参数
    long                return_code;        // 返回值
    int                 return_valid;       // 返回值是否有效
    uid_t               uid, euid, suid, fsuid;
    gid_t               gid, egid, sgid, fsgid;
    struct audit_names  names[AUDIT_NAMES];  // 涉及的文件名
    struct audit_aux_data *aux;              // 额外数据
};
```

---

## 2. 系统调用审计流程

```c
// audit_syscall_entry() — 系统调用入口
void audit_syscall_entry(int major, unsigned long a1, unsigned long a2,
                unsigned long a3, unsigned long a4)
{
    struct audit_context *ctx = current->audit_context;
    ctx->in_syscall = 1;
    ctx->major = major;
    ctx->argv[0] = a1; ctx->argv[1] = a2;
    ctx->argv[2] = a3; ctx->argv[3] = a4;
}

// audit_syscall_exit() — 系统调用退出
void audit_syscall_exit(void *pt_regs, long rc)
{
    struct audit_context *ctx = current->audit_context;
    ctx->return_code = rc;
    ctx->return_valid = 1;
    // 发送到 auditd
    audit_send_reply(ctx, AUDIT_SYSCALL, ...);
}
```

---

## 3. auditd 通信（netlink）

```c
// net/netlink/audit.c — audit_receive_msg
// 用户空间通过 netlink 套接字接收审计事件：
// socket(AF_NETLINK, SOCK_RAW, NETLINK_AUDIT)
// bind(fd, &addr, sizeof(addr))
// recvmsg(fd, &msg, 0)
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `kernel/audit*.c` | 审计核心 |
| `net/netlink/audit.c` | netlink 通信 |
| `include/linux/audit.h` | `struct audit_context` |
