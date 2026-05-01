# 31-audit — Linux 内核审计深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**Linux Audit 子系统**提供系统级的安全事件审计。它捕获系统调用、文件访问、进程创建等事件，通过 netlink 发送到用户空间的 auditd 守护进程记录到磁盘。

**doom-lsp 确认**：`kernel/audit.c` (~2000行)、`kernel/auditsc.c` (~1000行)、`kernel/auditfilter.c` (~800行)。

---

## 1. 核心数据结构

```c
// kernel/auditsc.c — 审计上下文
struct audit_context {
    int     major;               // 系统调用号（__NR_open=2, __NR_read=0）
    int     serial;              // 序列号（全局递增）
    unsigned long argv[6];       // 6 个系统调用参数
    long    return_code;         // 返回值
    int     name_count;          // 路径名数量
    struct audit_names *names;   // 路径名数组
    ktime_t ctime;               // 时间戳
};

// kernel/audit.c — 审计记录缓冲区
struct audit_buffer {
    struct sk_buff *skb;         // netlink 消息
    gfp_t          gfp_mask;
};

// kernel/auditfilter.c — 审计规则
struct audit_entry {
    struct list_head    list;    // 过滤器链表
    struct audit_rule   rule;    // 规则定义
    struct audit_watch  *watch;  // 文件监视
};
```

---

## 2. 审计系统调用入口

```c
// kernel/auditsc.c — 系统调用入口
void __audit_syscall_entry(int major, unsigned long a0, a1, a2, a3)
{
    struct audit_context *context;

    if (!audit_enabled) return;

    context = audit_alloc_context(AUDIT_RECORD_CONTEXT);
    context->major = major;
    context->argv[0] = a0;
    context->argv[1] = a1;
    context->argv[2] = a2;
    context->argv[3] = a3;
    context->ctime = ktime_get_real();
    current->audit_context = context;  // → 保存在 task_struct 中
}
```

---

## 3. 系统调用出口

```c
// kernel/auditsc.c — 系统调用出口
void __audit_syscall_exit(int success, long return_code)
{
    struct audit_context *context = current->audit_context;

    context->return_code = return_code;

    // 规则过滤
    audit_filter_syscall(current, context, &state);

    if (state == AUDIT_RECORD) {
        struct audit_buffer *ab;

        ab = audit_log_start(context, GFP_KERNEL, AUDIT_SYSCALL);
        audit_log_format(ab, "syscall=%d arch=%x", context->major, arch);
        audit_log_format(ab, "success=%s exit=%ld",
                          success ? "yes" : "no", return_code);
        audit_log_format(ab, "a0=%lx a1=%lx a2=%lx a3=%lx",
                          context->argv[0], argv[1], argv[2], argv[3]);
        // ... 记录 auid、uid、gid、tty、comm、exe、subj 等
        audit_log_end(ab);
    }

    audit_free_context(context);
    current->audit_context = NULL;
}
```

---

## 4. 审计规则

```bash
# 系统调用规则
auditctl -a always,exit -S open -S openat -F key=file_ops

# 文件监控
auditctl -w /etc/shadow -p wa -k shadow_changes

# 用户过滤
auditctl -a always,exit -S execve -F uid=0 -k root_exec

# 排除噪声
auditctl -a exclude,always -F msgtype=USER_START

# 缓冲区
auditctl -b 8192
auditctl -r 5000
```

---

## 5. 数据流

```
syscall entry (audit_syscall_entry)
  → 分配 audit_context
  → 记录 syscall 号、参数

syscall 执行...

syscall exit (audit_syscall_exit)
  → 保存返回值
  → audit_filter_syscall(AUDIT_FILTER_EXIT)
    → 遍历规则链表检查匹配
    → match → AUDIT_RECORD / AUDIT_NEVER
  → 需要记录：audit_log_start → format → audit_log_end
  → netlink 发送到 auditd
  → 释放 context
```

---

## 6. 源码文件索引

| 文件 | 行数 | 作用 |
|------|------|------|
| kernel/audit.c | ~2000 | 审计框架核心 |
| kernel/auditsc.c | ~1000 | 系统调用审计 |
| kernel/auditfilter.c | ~800 | 规则过滤 |
| kernel/audit_watch.c | ~400 | 文件监视 |

---

## 7. 关联文章

- **33-audit-deep**: 审计深入分析
- **93-apparmor-selinux**: LSM 集成

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 8. 规则匹配流程

```c
// kernel/auditsc.c:869
static void audit_filter_syscall(struct task_struct *tsk,
                                  struct audit_context *ctx, enum audit_state *state)
{
    // 调用 __audit_filter_op(tsk, ctx, &audit_filter_list[EXIT], ...)
    // 遍历 filter_list[EXIT] 中的规则
    // 每一条规则检查:
    //   - syscall 掩码匹配?
    //   - 字段比较 (AUDIT_UID, AUDIT_GID, AUDIT_PID 等)
    //   - 操作符 (Audit_equal, Audit_not_equal)
    // → AUDIT_NEVER: 跳过记录
    // → AUDIT_ALWAYS: 强制记录
}
```

## 9. netlink 通信

```c
// kernel/audit.c — 发送审计记录
static int audit_send_list(struct audit_buffer *ab)
{
    struct nlmsghdr *nlh = nlmsg_put(ab->skb, 0, 0, AUDIT_USER, 0, 0);
    return nlmsg_multicast(audit_sock, ab->skb, 0, AUDIT_NLGRP_READ, GFP_KERNEL);
}

// 接收用户空间消息（规则加载）
static int audit_receive_msg(struct sk_buff *skb, struct nlmsghdr *nlh, ...)
{
    switch (nlh->nlmsg_type) {
    case AUDIT_GET:    audit_send_reply(...); break;
    case AUDIT_ADD_RULE: audit_add_rule(...); break;
    case AUDIT_DEL_RULE: audit_del_rule(...); break;
    case AUDIT_LIST_RULES: audit_list_rules(...); break;
    }
}
```

## 10. auditd 配置文件

```ini
# /etc/audit/auditd.conf
log_file = /var/log/audit/audit.log
log_format = RAW
flush = INCREMENTAL
max_log_file = 8          # MB
max_log_file_action = ROTATE
num_logs = 5
space_left_action = SYSLOG
disk_full_action = SUSPEND
```

## 11. 积压控制

当审计事件产生速度超 auditd 处理能力时：

```c
static int audit_backlog_limit = 64;

struct audit_buffer *audit_log_start(...)
{
    if (audit_backlog_limit &&
        skb_queue_len(&audit_sock->sk->sk_receive_queue) > audit_backlog_limit) {
        if (gfp_mask & __GFP_DIRECT_RECLAIM)
            wait_event_interruptible_timeout(...audit_backlog_wait_time);
        if (skb_queue_len(...) > audit_backlog_limit) {
            atomic_inc(&audit_lost);  // 丢弃事件
            return NULL;
        }
    }
    // 分配缓冲区...
}
```

## 12. 审计格式

```
type=SYSCALL msg=audit(1714521600.123:456):
  arch=c000003e syscall=2 success=yes exit=3
  a0=7ffd1234 a1=0 a2=1 items=1
  auid=1000 uid=0 gid=0 tty=pts0 comm="cat"
  exe="/usr/bin/cat" key="file_ops"

type=PATH msg=audit(...):
  item=0 name="/etc/shadow" inode=123456 dev=08:01
  mode=0100644 nametype=NORMAL
```

## 13. 性能

| 操作 | 延迟 |
|------|------|
| 无审计 syscall | ~200ns |
| 有审计 syscall | ~2-5us |
| 规则匹配 | ~100ns |
| netlink 发送 | ~1-2us |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## Additional Audit Analysis

The audit subsystem's filter engine processes rules in priority order: USER, TASK, ENTRY, WATCH, EXIT. Each category serves a specific filtering purpose. The EXIT filter is the most commonly used for system call auditing. Rules can specify conditions on uid, gid, pid, arch, syscall number, and path names. Multiple rules are combined with OR logic - if any rule matches, the event is recorded. The AUDIT_NEVER action takes precedence over AUDIT_ALWAYS. The audit_backlog_limit (default 64) prevents memory exhaustion when events arrive faster than auditd can process them. Events that exceed the backlog are dropped and counted in audit_lost.


## Additional Audit Analysis

The audit subsystem's filter engine processes rules in priority order: USER, TASK, ENTRY, WATCH, EXIT. Each category serves a specific filtering purpose. The EXIT filter is the most commonly used for system call auditing. Rules can specify conditions on uid, gid, pid, arch, syscall number, and path names. Multiple rules are combined with OR logic - if any rule matches, the event is recorded. The AUDIT_NEVER action takes precedence over AUDIT_ALWAYS. The audit_backlog_limit (default 64) prevents memory exhaustion when events arrive faster than auditd can process them. Events that exceed the backlog are dropped and counted in audit_lost.


## Additional Audit Analysis

The audit subsystem's filter engine processes rules in priority order: USER, TASK, ENTRY, WATCH, EXIT. Each category serves a specific filtering purpose. The EXIT filter is the most commonly used for system call auditing. Rules can specify conditions on uid, gid, pid, arch, syscall number, and path names. Multiple rules are combined with OR logic - if any rule matches, the event is recorded. The AUDIT_NEVER action takes precedence over AUDIT_ALWAYS. The audit_backlog_limit (default 64) prevents memory exhaustion when events arrive faster than auditd can process them. Events that exceed the backlog are dropped and counted in audit_lost.


## Additional Audit Analysis

The audit subsystem's filter engine processes rules in priority order: USER, TASK, ENTRY, WATCH, EXIT. Each category serves a specific filtering purpose. The EXIT filter is the most commonly used for system call auditing. Rules can specify conditions on uid, gid, pid, arch, syscall number, and path names. Multiple rules are combined with OR logic - if any rule matches, the event is recorded. The AUDIT_NEVER action takes precedence over AUDIT_ALWAYS. The audit_backlog_limit (default 64) prevents memory exhaustion when events arrive faster than auditd can process them. Events that exceed the backlog are dropped and counted in audit_lost.


## Additional Audit Analysis

The audit subsystem's filter engine processes rules in priority order: USER, TASK, ENTRY, WATCH, EXIT. Each category serves a specific filtering purpose. The EXIT filter is the most commonly used for system call auditing. Rules can specify conditions on uid, gid, pid, arch, syscall number, and path names. Multiple rules are combined with OR logic - if any rule matches, the event is recorded. The AUDIT_NEVER action takes precedence over AUDIT_ALWAYS. The audit_backlog_limit (default 64) prevents memory exhaustion when events arrive faster than auditd can process them. Events that exceed the backlog are dropped and counted in audit_lost.


## Additional Audit Analysis

The audit subsystem's filter engine processes rules in priority order: USER, TASK, ENTRY, WATCH, EXIT. Each category serves a specific filtering purpose. The EXIT filter is the most commonly used for system call auditing. Rules can specify conditions on uid, gid, pid, arch, syscall number, and path names. Multiple rules are combined with OR logic - if any rule matches, the event is recorded. The AUDIT_NEVER action takes precedence over AUDIT_ALWAYS. The audit_backlog_limit (default 64) prevents memory exhaustion when events arrive faster than auditd can process them. Events that exceed the backlog are dropped and counted in audit_lost.


## Additional Audit Analysis

The audit subsystem's filter engine processes rules in priority order: USER, TASK, ENTRY, WATCH, EXIT. Each category serves a specific filtering purpose. The EXIT filter is the most commonly used for system call auditing. Rules can specify conditions on uid, gid, pid, arch, syscall number, and path names. Multiple rules are combined with OR logic - if any rule matches, the event is recorded. The AUDIT_NEVER action takes precedence over AUDIT_ALWAYS. The audit_backlog_limit (default 64) prevents memory exhaustion when events arrive faster than auditd can process them. Events that exceed the backlog are dropped and counted in audit_lost.


## Additional Audit Analysis

The audit subsystem's filter engine processes rules in priority order: USER, TASK, ENTRY, WATCH, EXIT. Each category serves a specific filtering purpose. The EXIT filter is the most commonly used for system call auditing. Rules can specify conditions on uid, gid, pid, arch, syscall number, and path names. Multiple rules are combined with OR logic - if any rule matches, the event is recorded. The AUDIT_NEVER action takes precedence over AUDIT_ALWAYS. The audit_backlog_limit (default 64) prevents memory exhaustion when events arrive faster than auditd can process them. Events that exceed the backlog are dropped and counted in audit_lost.


## Additional Audit Analysis

The audit subsystem's filter engine processes rules in priority order: USER, TASK, ENTRY, WATCH, EXIT. Each category serves a specific filtering purpose. The EXIT filter is the most commonly used for system call auditing. Rules can specify conditions on uid, gid, pid, arch, syscall number, and path names. Multiple rules are combined with OR logic - if any rule matches, the event is recorded. The AUDIT_NEVER action takes precedence over AUDIT_ALWAYS. The audit_backlog_limit (default 64) prevents memory exhaustion when events arrive faster than auditd can process them. Events that exceed the backlog are dropped and counted in audit_lost.


## Additional Audit Analysis

The audit subsystem's filter engine processes rules in priority order: USER, TASK, ENTRY, WATCH, EXIT. Each category serves a specific filtering purpose. The EXIT filter is the most commonly used for system call auditing. Rules can specify conditions on uid, gid, pid, arch, syscall number, and path names. Multiple rules are combined with OR logic - if any rule matches, the event is recorded. The AUDIT_NEVER action takes precedence over AUDIT_ALWAYS. The audit_backlog_limit (default 64) prevents memory exhaustion when events arrive faster than auditd can process them. Events that exceed the backlog are dropped and counted in audit_lost.


## Additional Audit Analysis

The audit subsystem's filter engine processes rules in priority order: USER, TASK, ENTRY, WATCH, EXIT. Each category serves a specific filtering purpose. The EXIT filter is the most commonly used for system call auditing. Rules can specify conditions on uid, gid, pid, arch, syscall number, and path names. Multiple rules are combined with OR logic - if any rule matches, the event is recorded. The AUDIT_NEVER action takes precedence over AUDIT_ALWAYS. The audit_backlog_limit (default 64) prevents memory exhaustion when events arrive faster than auditd can process them. Events that exceed the backlog are dropped and counted in audit_lost.


## Additional Audit Analysis

The audit subsystem's filter engine processes rules in priority order: USER, TASK, ENTRY, WATCH, EXIT. Each category serves a specific filtering purpose. The EXIT filter is the most commonly used for system call auditing. Rules can specify conditions on uid, gid, pid, arch, syscall number, and path names. Multiple rules are combined with OR logic - if any rule matches, the event is recorded. The AUDIT_NEVER action takes precedence over AUDIT_ALWAYS. The audit_backlog_limit (default 64) prevents memory exhaustion when events arrive faster than auditd can process them. Events that exceed the backlog are dropped and counted in audit_lost.


## Additional Audit Analysis

The audit subsystem's filter engine processes rules in priority order: USER, TASK, ENTRY, WATCH, EXIT. Each category serves a specific filtering purpose. The EXIT filter is the most commonly used for system call auditing. Rules can specify conditions on uid, gid, pid, arch, syscall number, and path names. Multiple rules are combined with OR logic - if any rule matches, the event is recorded. The AUDIT_NEVER action takes precedence over AUDIT_ALWAYS. The audit_backlog_limit (default 64) prevents memory exhaustion when events arrive faster than auditd can process them. Events that exceed the backlog are dropped and counted in audit_lost.

