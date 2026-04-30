# audit — 内核审计子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/audit*.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**audit** 记录系统调用的安全相关信息（文件名、UID、返回值），通过 **netlink** 套接字发送给用户空间 `auditd`。

---

## 1. 核心数据结构

### 1.1 audit_context — 审计上下文

```c
// kernel/audit.h — audit_context
struct audit_context {
    // 类型
    enum audit_state     state;         // AUDIT_STATE_*（记录/不记录）
    unsigned int        in_syscall;        // 是否在系统调用中

    // 系统调用信息
    unsigned int        major;             // 系统调用号
    unsigned long       argv[6];           // 参数
    long               return_code;        // 返回值
    int                 return_valid;       // 返回值是否有效

    // 身份
    uid_t               uid, euid, suid, fsuid;
    gid_t               gid, egid, sgid, fsgid;
    pid_t               pid, ppid;         // 进程/父进程 ID

    // 文件名
    struct audit_names  *names;           // 涉及的文件名
    int                 name_count;        // 文件名数量

    // 辅助数据
    struct list_head    * Auxiliary_data;   // 额外数据
    // ...
};
```

### 1.2 audit_buffer — 审计缓冲

```c
// kernel/audit.h — audit_buffer
struct audit_buffer {
    struct nlmsgerr     *nlh;              // netlink 消息头
    int                 abap;               // 当前写位置
    int                 len;               // 总长度
    struct audit_context *ctx;             // 审计上下文
};
```

### 1.3 audit_info — 审计信息

```c
// include/linux/audit.h — audit_info
struct audit_info {
    const char          *name;             // 对象名
    unsigned int        name_len;          // 名称长度
    struct dentry       *dentry;          // 目录项
    struct inode        *inode;            // inode
    unsigned int        flags;             // 标志
};
```

---

## 2. 系统调用入口审计

### 2.1 audit_syscall_entry

```c
// kernel/audit.c — audit_syscall_entry
void audit_syscall_entry(int major, unsigned long a1, unsigned long a2,
                unsigned long a3, unsigned long a4)
{
    struct audit_context *ctx = current->audit_context;

    ctx->in_syscall = 1;
    ctx->major = major;
    ctx->argv[0] = a1; ctx->argv[1] = a2;
    ctx->argv[2] = a3; ctx->argv[3] = a4;

    // 记录进程身份
    ctx->uid = current_uid();
    ctx->euid = current_euid();
    ctx->pid = current->pid;
}
```

### 2.2 audit_syscall_exit

```c
// kernel/audit.c — audit_syscall_exit
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

## 3. 文件名审计

### 3.1 audit_getname

```c
// kernel/audit.c — audit_getname
void audit_getname(const struct qstr *name)
{
    struct audit_names *n;

    n = kmalloc(sizeof(*n), GFP_KERNEL);
    n->name = name->name;
    n->name_len = name->len;

    // 加入 audit_context->names 链表
    list_add(&n->list, &ctx->names_list);
}
```

---

## 4. netlink 通信

### 4.1 audit_receive

```c
// kernel/audit.c — audit_receive
static int audit_receive_msg(struct sk_buff *skb, struct nlmsghdr *nlh)
{
    switch (nlh->nlmsg_type) {
    case AUDIT_GET:
        audit_send_reply(AUDIT_GET, ...);
        break;
    case AUDIT_SET:
        audit_set_rules(nlh);
        break;
    }
    return 0;
}
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/audit.h` | `struct audit_context`、`struct audit_buffer` |
| `kernel/audit.c` | `audit_syscall_entry/exit`、`audit_receive` |
| `kernel/auditfilter.c` | 过滤规则 |