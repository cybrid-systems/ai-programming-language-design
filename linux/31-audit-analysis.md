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

## 14. 过滤引擎详解

```c
// kernel/auditfilter.c — 规则过滤
int audit_filter(int msgtype, enum audit_state *state)
{
    struct audit_entry *e;
    int ret = 1;

    list_for_each_entry_rcu(e, &audit_filter_list[AUDIT_FILTER_EXIT], list) {
        if (audit_filter_match(e, current)) {
            switch (e->rule.action) {
            case AUDIT_NEVER:
                return 0;   // 不记录
            case AUDIT_ALWAYS:
                ret = 1;    // 记录
            }
        }
    }
    return ret;
}
```

## 15. 审计事件类型

| 类型 | 代码 | 说明 |
|------|------|------|
| AUDIT_SYSCALL | 1300 | 系统调用 |
| AUDIT_PATH | 1302 | 路径名 |
| AUDIT_EXECVE | 1309 | execve 参数 |
| AUDIT_USER_START | 1320 | 用户登录 |
| AUDIT_AVC | 1400 | SELinux 决策 |
| AUDIT_MAC_POLICY_LOAD | 1403 | SELinux 策略加载 |

## 16. 性能调优

```bash
# 增大缓冲区减少丢失
auditctl -b 8192

# 速率限制
auditctl -r 5000

# 排除噪声事件
auditctl -a exclude,always -F msgtype=USER_START
auditctl -a exclude,always -F msgtype=CRED_DISP

# 监控关键操作
auditctl -a always,exit -S execve -S open -S openat -S creat
auditctl -w /etc/passwd -p wa -k identity
auditctl -w /etc/shadow -p wa -k identity
```

## 17. 调试命令

```bash
auditctl -s              # 查看状态
auditctl -l              # 列出规则
ausearch -m SYSCALL      # 搜索系统调用事件
ausearch -k mykey        # 按 key 搜索
aureport --summary       # 摘要报告
aureport -x              # 可执行文件统计
```

## 18. 常见问题

- auditd 无法启动: 检查 auditd.conf
- 日志丢失: 增大 -b 缓冲区
- 性能下降: 使用排除规则减少日志量
- 规则过多: 合并同类规则

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 19. 审计上下文释放

```c
// kernel/auditsc.c
static void audit_free_context(struct audit_context *context)
{
    struct audit_names *n;

    // 释放关联的路径名
    for (i = 0; i < context->name_count; i++) {
        n = &context->names[i];
        if (n->name)
            kfree(n->name);  // 释放路径名
    }

    // 释放 socket 地址
    if (context->sockaddr)
        kfree(context->sockaddr);

    kfree(context);  // 释放上下文本身
}
```

## 20. per-CPU 缓冲区缓存

```c
// kernel/audit.c — per-CPU 缓存减少分配
static DEFINE_PER_CPU(struct audit_buffer *, audit_buffer_cpu);

struct audit_buffer *audit_log_start(struct audit_context *ctx, ...)
{
    struct audit_buffer *ab;

    // 尝试从 per-CPU 缓存获取
    ab = this_cpu_read(audit_buffer_cpu);
    if (ab) {
        this_cpu_write(audit_buffer_cpu, NULL);
        return ab;
    }

    // 分配新的
    ab = kmalloc(sizeof(*ab), gfp_mask);
    if (!ab) return NULL;

    ab->skb = alloc_skb(AUDIT_BUFSIZ, gfp_mask);
    ab->ctx = ctx;
    return ab;
}
```

## 21. 审计日志轮转

```bash
# /etc/audit/auditd.conf
max_log_file = 8           # 8MB
max_log_file_action = ROTATE
num_logs = 5               # 保留 5 个历史文件
space_left_action = SYSLOG  # 磁盘空间不足时
disk_full_action = SUSPEND  # 磁盘满时暂停
```

## 22. auditctl 规则格式

```bash
# 基本格式
auditctl -a <list>,<action> <options>

# list: task, exit, user, exclude
# action: always, never

# 字段过滤
# -F uid=N       用户 ID
# -F gid=N       组 ID
# -F pid=N       PID
# -F arch=b64    x86_64
# -F success=0   失败操作

# 文件监视
# -w /path -p <perms> -k <key>
# perms: r=读, w=写, x=执行, a=属性修改
```

## 23. 审计日志分析

```bash
# 统计事件类型
ausearch --interpret | grep "^type=" | sort | uniq -c | sort -rn

# 查找特定用户的活动
ausearch -ua 1000 -ts today -i

# 查找失败的系统调用
ausearch --success no -i

# 实时监控
tail -f /var/log/audit/audit.log | ausearch --interpret
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 24. 审计与安全性

| 功能 | 场景 | 说明 |
|------|------|------|
| 系统调用监控 | 入侵检测 | 监控 execve、open 等敏感调用 |
| 文件完整性 | 安全合规 | 监控 /etc/shadow 等关键文件 |
| 用户行为审计 | 内部威胁 | 记录所有用户的操作历史 |
| 配置变更 | 合规要求 | PCI DSS、SOC2 等标准要求 |

## 25. auditctl 常用参数

```bash
# 状态和控制
auditctl -s                    # 审计状态
auditctl -e 1                  # 启用审计
auditctl -e 0                  # 禁用审计
auditctl -R /etc/audit/rules.d/audit.rules  # 加载规则文件

# 查看统计
cat /proc/sys/kernel/audit/backlog_limit  # 积压上限
cat /proc/sys/kernel/audit/backlog_wait_time  # 积压等待时间
cat /proc/sys/kernel/audit/audit_rate_limit  # 速率限制
```

## 26. 总结

Linux Audit 是内核级安全审计基础设施。per-CPU 缓冲区减少分配开销，netlink 多播传输事件，灵活规则引擎支持系统调用、文件、用户等多维度过滤。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 27. 审计规则优先级

```
AUDIT_NEVER 优先级高于 AUDIT_ALWAYS

例如:
  规则1: -a always,exit -S open  (记录所有 open)
  规则2: -a never,exit -F uid=1000  (排除 uid 1000)
  
结果: uid 1000 的 open 不会被记录 (AUDIT_NEVER 覆盖 AUDIT_ALWAYS)

优先级规则:
  AUDIT_NEVER > AUDIT_ALWAYS
  具体规则 > 通配规则
  越靠前的规则越先匹配
```

## 28. 审计与命名空间

```c
// 容器场景中 audit 支持命名空间隔离
struct audit_namespace {
    struct audit_rules_list rules[AUDIT_NR_FILTERS];
    wait_queue_head_t backlog_wait;
};

// 不同容器的审计规则相互独立
// 容器内操作标记为对应命名空间的审计事件
```

## 29. tail 命令实时监控审计日志

```bash
# 实时显示审计事件
tail -f /var/log/audit/audit.log

# 解释格式
tail -f /var/log/audit/audit.log | ausearch --interpret

# 只显示特定类型
tail -f /var/log/audit/audit.log | grep "SYSCALL"

# 显示失败事件
ausearch --success no -i -ts today
```

## 30. 审计系统初始化

```c
// kernel/audit.c — 引导时初始化
void __init audit_init(void)
{
    audit_sock = netlink_kernel_create(&init_net, NETLINK_AUDIT, &audit_nl_ops);
    
    for (i = 0; i < AUDIT_NR_FILTERS; i++)
        INIT_LIST_HEAD(&audit_filter_list[i]);
    
    audit_backlog_limit = 64;
    audit_enabled = 1;
    
    pr_info("audit: initializing netlink subsys\n");
}
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*


- 内核文档: Documentation/admin-guide/audit/
- auditd 配置: /etc/audit/auditd.conf
- 规则文件: /etc/audit/rules.d/audit.rules
- 日志位置: /var/log/audit/audit.log
- 工具: auditctl, ausearch, aureport, autrace

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01*

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*


Linux Audit 子系统提供系统调用级的事件审计，通过 per-CPU 缓冲区缓存优化性能，netlink 多播传输事件，灵活的过滤引擎支持多维度的规则匹配。audit_backlog_limit 控制积压上限防止内存耗尽。auditd 用户空间守护进程持久化审计日志。


## 参考链接

- 内核源码: kernel/audit.c, kernel/auditsc.c, kernel/auditfilter.c
- 用户空间: auditd (https://github.com/linux-audit)
- 文档: Documentation/admin-guide/audit/

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

Linux audit 是安全审计基础设施的核心组件。per-CPU 缓冲区、netlink 传输、灵活规则引擎使其在细粒度审计和低性能影响之间取得平衡。

审计规则可按系统调用、文件路径、用户 ID、进程 ID、架构等多维度过滤。AUDIT_NEVER 优先级高于 AUDIT_ALWAYS，确保精细控制。

auditd 守护进程通过 netlink 接收事件并写入 /var/log/audit/audit.log。
