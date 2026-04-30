# Linux Audit — 系统安全审计深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/audit/` + `include/linux/audit.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Linux Audit** 记录系统安全相关事件：系统调用、文件访问、用户操作、规则匹配等。审计事件通过 **netlink** 套接字发送到用户空间 `auditd` 守护进程。

---

## 1. 系统调用审计

### 1.1 audit_syscall_entry — 系统调用入口

```c
// kernel/audit.c — audit_syscall_entry
void audit_syscall_entry(unsigned long major, unsigned long a1,
                         unsigned long a2, unsigned long a3, unsigned long a4)
{
    struct audit_context *ctx = current->audit_context;

    // 只在启用时记录
    if (ctx && ctx->state == AUDIT_STATE_BUILD) {
        ctx->major = major;
        ctx->argv[0] = a1;
        ctx->argv[1] = a2;
        ctx->argv[2] = a3;
        ctx->argv[3] = a4;
    }
}
```

### 1.2 audit_syscall_exit — 系统调用退出

```c
// kernel/audit.c — audit_syscall_exit
void audit_syscall_exit(void *pt_regs, long ret_code)
{
    struct audit_context *ctx = current->audit_context;

    if (ctx && ctx->state == AUDIT_STATE_BUILD) {
        ctx->return_code = ret_code;

        // 发送审计事件到 auditd
        __audit_syscall_exit(ctx);

        // 释放上下文
        ctx->dummy = 1;  // 禁用（直到下次系统调用）
    }
}
```

---

## 2. 审计上下文

```c
// kernel/audit.h — audit_context
struct audit_context {
    // 状态
    enum audit_state    state;         // DISABLED / RECORD / BUILD
    int                 dummy;         // 禁用标志

    // 系统调用
    int                 major;          // 系统调用号
    unsigned long       argv[6];        // 参数
    long                return_code;    // 返回值

    // 进程身份
    uid_t               uid, euid, suid, fsuid;
    gid_t               gid, egid, sgid, fsgid;
    pid_t               pid, ppid;       // 进程/父进程 ID

    // 文件名列表（系统调用期间访问的文件）
    int                 name_count;     // 文件名数量
    struct audit_names  names[AUDIT_NAMES];
    char                *filterkey;      // 过滤关键字

    // 辅助数据
    struct list_head    *auxiliary_data; // 额外数据
};
```

---

## 3. 文件名审计

### 3.1 __audit_getname — 记录文件名

```c
// kernel/audit.c — __audit_getname
void __audit_getname(const struct qstr *name)
{
    struct audit_context *ctx = current->audit_context;

    if (ctx->name_count >= AUDIT_NAMES)
        return;

    // 添加到 names 数组
    ctx->names[ctx->name_count].name = name->name;
    ctx->names[ctx->name_count].name_len = name->len;
    ctx->name_count++;
}
```

### 3.2 自动记录文件名

```c
// openat 系统调用 → __audit_openat → __audit_getname
// mkdir 系统调用 → __audit_mkdir → __audit_getname
// bind 系统调用 → __audit_bind → __audit_getname
// connect 系统调用 → __audit_connect → __audit_getname
```

---

## 4. netlink 通信

### 4.1 审计消息格式

```c
// include/uapi/linux/audit.h — AUDIT_* 消息类型
#define AUDIT_SYSCALL      1304  // 系统调用事件
#define AUDIT_PATH         1305  // 文件路径事件
#define AUDIT_IPC          1307  // IPC 事件
#define AUDIT_SOCKADDR     1308  // socket 地址
#define AUDIT_FS_WATCH     1313  // 文件系统 watch
#define AUDIT_NETFILTER_PKT 1301 // netfilter 包事件

// 消息格式：
struct nlmsghdr {
    __u32 nlmsg_type = AUDIT_SYSCALL;  // 审计消息类型
    __u32 nlmsg_seq;                    // 序列号
    __u32 nlmsg_pid;                    // 发送者 PID
};
struct audit_header {
    __u32 type;                         // AUDIT_* 类型
    __u32 size;                         // 消息大小
    __u64 timestamp;                    // 时间戳
    __u32 serial;                       // 序列号
    __u32 rev;                          // 审计规则版本
};
```

### 4.2 发送审计事件

```c
// kernel/audit.c — audit_log_start
struct audit_buffer *audit_log_start(struct audit_context *ctx, gfp_t gfp_mask, int type)
{
    struct audit_buffer *ab;

    // 1. 分配 audit_buffer
    ab = kmalloc(sizeof(*ab), gfp_mask);
    if (!ab)
        return NULL;

    // 2. 通过 netlink 发送到 auditd
    ab->skb = nlmsg_alloc();
    nlmsg_put(ab->skb, 0, 0, type, 0);

    return ab;
}
```

---

## 5. 过滤规则

```c
// kernel/auditfilter.c — audit_filter_task
int audit_filter_task(struct task_struct *tsk, int type)
{
    struct audit_entry *e;

    // 遍历过滤规则链表
    list_for_each_entry(e, &audit_filter_list[AUDIT_FILTER_TASK], list) {
        if (audit_match_rule(e, NULL, tsk))
            return 1;  // 匹配，忽略此事件
    }
    return 0;
}
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/audit.h` | `struct audit_context`、`struct audit_names` |
| `kernel/audit.c` | `audit_syscall_entry/exit`、`audit_log_start` |
| `kernel/auditfilter.c` | `audit_filter_task`、`audit_add_rule` |
| `include/uapi/linux/audit.h` | `AUDIT_*` 消息类型常量 |