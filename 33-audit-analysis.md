# Linux Kernel Audit 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/audit/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 Audit？

**Linux Audit** 是内核的安全审计子系统，记录系统调用、文件访问、用户操作等事件，供安全分析使用。

---

## 1. 核心数据结构

```c
// kernel/audit.h — audit_buffer
struct audit_buffer {
    struct sk_buff      *skb;      // 发送 netlink 消息
    struct audit_context *ctx;     // audit 上下文
    gfp_t              gfp_mask;
};

// audit_context — 系统调用审计上下文
struct audit_context {
    int                 dummy;     // 禁用时为 1
    enum audit_state    state;     // AUDIT_STATE_DISABLED / RECORD / BUILD
    int                 major;      // 系统调用号
    long                return_code; // 返回值
    unsigned long       argv[6];    // 系统调用参数
    struct audit_names {
        const char  *name;
        unsigned long ino;
        dev_t         dev;
        umode_t       mode;
    } names[AUDIT_NAMES];
};
```

---

## 2. 系统调用审计

```c
// kernel/auditsc.c — audit_syscall_exit
void audit_syscall_exit(struct task_struct *task, long ret)
{
    struct audit_context *ctx = audit_context();

    ctx->return_code = ret;  // 记录返回值

    // 发送 netlink 消息给用户空间 auditd
    audit_log_exit(ctx, task);
}
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `kernel/audit/audit.c` | `audit_log`、`audit_log_end` |
| `kernel/auditsc.c` | `audit_syscall_entry`、`audit_syscall_exit` |
