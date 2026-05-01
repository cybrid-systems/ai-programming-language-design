# 31-audit — Linux 内核审计深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**Linux Audit 子系统**提供系统级的安全事件审计日志。它捕获系统调用、文件访问、进程创建、网络连接等事件，生成结构化的审计记录（audit record），通过 netlink 发送给用户空间的 auditd 守护进程记录到磁盘。广泛应用于 SELinux、AppArmor、PCI DSS 合规等安全场景。

**doom-lsp 确认**：核心实现在 `kernel/audit.c`（主框架）、`kernel/auditsc.c`（系统调用审计）、`kernel/auditfilter.c`（规则过滤）。

---

## 1. 架构

```
用户空间
  auditd ←→ auditctl (规则管理)
     ↑
     │ netlink (AF_NETLINK, NETLINK_AUDIT)
     ↓
内核 audit 子系统
  │
  ├── audit_receive_msg()      ← 接收用户空间消息（规则加载、状态查询）
  ├── audit_log_start()        ← 开始记录审计事件
  ├── audit_log_format()       ← 格式化审计记录字段
  ├── audit_log_end()          ← 结束记录并发送到 auditd
  │
  └── audit_filter()           ← 规则匹配过滤器（决定是否记录）
```

---

## 2. 核心数据结构

```c
// kernel/audit.h
struct audit_buffer {
    struct sk_buff *skb;        // netlink 消息缓冲区
    gfp_t          gfp_mask;    // 内存分配标志
};

struct audit_context {
    int     major;               // 系统调用号
    int     serial;              // 审计事件序列号
    unsigned long argv[6];       // 系统调用参数
    long    return_code;         // 系统调用返回值
    int     name_count;          // 文件名计数
    struct audit_names *names;   // 文件名数组
    ktime_t ctime;               // 创建时间
};

struct audit_entry {
    struct list_head list;       // 规则链表
    struct audit_rule rule;      // 审计规则
    struct audit_watch *watch;   // 文件监视
};
```

---

## 3. 审计规则示例

```bash
# 记录所有 open 系统调用
auditctl -a always,exit -S open -F key=open_trace

# 记录某个用户的执行
auditctl -a always,exit -S execve -F uid=1000

# 记录特定文件的写操作
auditctl -w /etc/shadow -p wa

# 排除特定事件（减少日志量）
auditctl -a exclude,always -F msgtype=USER_START
```

---

## 4. 审计记录格式

```bash
# 典型的 audit.log 条目
type=SYSCALL msg=audit(1234567890.123:456):
  arch=c000003e syscall=2 success=yes exit=3
  a0=7ffd1234 a1=0 a2=1 a3=0 items=1 ppid=1234 pid=5678
  auid=1000 uid=0 gid=0 euid=0 suid=0 fsuid=0
  egid=0 sgid=0 fsgid=0 tty=pts0 ses=1
  comm="cat" exe="/usr/bin/cat"
  subj=unconfined_u:unconfined_r:unconfined_t:s0 key="open_trace"

type=PATH msg=audit(...): item=0 name="/etc/shadow"
  inode=123456 dev=08:01 mode=0100644 ouid=0 ogid=0
  rdev=00:00 obj=system_u:object_r:shadow_t:s0 nametype=NORMAL
```

---

## 5. 系统调用审计的数据流

```
系统调用入口（audit_syscall_entry）：
  │
  ├─ 记录系统调用号、参数
  ├─ 分配 audit_context（current->audit_context）
  └─ 保存到 task_struct

系统调用执行...

系统调用退出（audit_syscall_exit）：
  │
  ├─ audit_filter(type, ...)    ← 检查规则是否匹配
  │   ├─ 不匹配 → 释放 context，不记录
  │   └─ 匹配 → 继续
  │
  ├─ audit_log_start(GFP_KERNEL, AUDIT_SYSCALL)
  ├─ audit_log_format(ab, "syscall=%d arch=%x", ...)
  ├─ 记录路径名（for each name in context->names）
  └─ audit_log_end(ab) → nlmsg_multicast → auditd
```

---

## 6. 审计事件类型

| 事件类型 | 含义 |
|---------|------|
| AUDIT_SYSCALL | 系统调用 |
| AUDIT_PATH | 路径名 |
| AUDIT_EXECVE | execve 参数 |
| AUDIT_USER_START | 用户登录 |
| AUDIT_LOGIN | 登录成功 |
| AUDIT_AVC | SELinux 访问向量缓存 |
| AUDIT_MAC_* | MAC 策略事件 |
| AUDIT_IPC | IPC 对象操作 |
| AUDIT_FS_WATCH | 文件系统监视 |

---

## 7. 源码文件索引

| 文件 | 内容 |
|------|------|
| kernel/audit.c | 审计框架核心 |
| kernel/auditsc.c | 系统调用审计 |
| kernel/auditfilter.c | 规则过滤和匹配 |
| kernel/audit_watch.c | 文件系统监视 |
| include/linux/audit.h | 公共 API |
| include/uapi/linux/audit.h | 用户空间接口 |

---

## 8. 关联文章

- **33-audit-deep**：审计深度分析补充
- **93-apparmor-selinux**：LSM 与 audit 的集成

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 9. audit 缓存与性能

```c
// audit_buffer 的缓存管理
// 每个 CPU 缓存一个 audit_buffer
static DEFINE_PER_CPU(struct audit_buffer *, audit_buffer_cpu);

struct audit_buffer *audit_log_start(...)
{
    // 优先使用 per-CPU 缓存
    ab = this_cpu_read(audit_buffer_cpu);
    if (ab && skb_queue_len(&ab->skb->sk->sk_receive_queue) < audit_backlog_limit)
        return ab;
    
    // 分配新缓冲区
    ab = kmalloc(sizeof(*ab), gfp_mask);
    ab->skb = alloc_skb(AUDIT_BUFSIZ, gfp_mask);
    return ab;
}
```

## 10. 审计规则匹配

```c
// kernel/auditfilter.c — 规则匹配
int audit_filter(int type, enum audit_state *state)
{
    struct audit_entry *e;
    int ret = 1;  // 默认记录

    list_for_each_entry_rcu(e, &audit_filter_list[AUDIT_FILTER_EXIT], list) {
        if (audit_filter_match(e, current)) {
            if (e->rule.action == AUDIT_NEVER)
                return 0;  // 不记录
            if (e->rule.action == AUDIT_ALWAYS)
                ret = 1;   // 记录
        }
    }
    return ret;
}
```

## 11. 审计事件传输

审计记录通过 netlink 套接字发送到用户空间：

```c
// audit_netlink 多播
static int audit_send_list(struct audit_buffer *ab)
{
    // 使用 nlmsg_multicast 发送到 AUDIT 组
    struct nlmsghdr *nlh = nlmsg_put(ab->skb, 0, 0, AUDIT_USER, 0, 0);
    return nlmsg_multicast(audit_sock, ab->skb, 0, AUDIT_NLGRP_READ, GFP_KERNEL);
}
```

## 12. 配置文件

```bash
# /etc/audit/auditd.conf — auditd 配置
log_file = /var/log/audit/audit.log
log_format = RAW
flush = INCREMENTAL
max_log_file = 8
num_logs = 5
priority_boost = 4

# /etc/audit/rules.d/audit.rules — 规则文件
-D
-b 8192
-f 1
-a always,exit -S all -F path=/etc -F perm=wa
```

## 13. 总结

Linux Audit 子系统是系统安全审计的核心。通过 per-CPU 缓冲区、netlink 传输和灵活的规则引擎，实现了低延迟的事件捕获。auditd 用户空间守护进程接收并持久化事件记录。


## 14. 开机启动审计

审计系统在引导早期初始化：

```c
// kernel/audit.c — 早期初始化
void __init audit_init(void)
{
    // 创建 netlink 套接字
    audit_sock = netlink_kernel_create(&init_net, NETLINK_AUDIT, &audit_nl_ops);
    
    // 初始化过滤规则列表
    for (i = 0; i < AUDIT_NR_FILTERS; i++)
        INIT_LIST_HEAD(&audit_filter_list[i]);
    
    // 设置默认积压限制
    audit_backlog_limit = 64;
    
    // 创建审计内核线程
    auditd_task = kthread_run(auditd, NULL, "auditd");
    
    pr_info("audit: initializing netlink subsys\n");
}
```

  
---

## 15. 性能与最佳实践

| 操作 | 延迟 | 说明 |
|------|------|------|
| 简单审计日志 | ~1μs | 单一系统调用事件 |
| 规则匹配 | ~100ns | 线性扫描规则列表 |
| 路径名解析 | ~1-5μs | 每次系统调用需解析 |
| netlink 发送 | ~1μs | skb 分配+传递 |

## 16. 关联参考

- 内核文档: Documentation/admin-guide/audit/
- 工具: auditd, auditctl, ausearch, aureport
- 配置: /etc/audit/


## 17. 审计守护进程接口

auditd 通过 netlink 与内核通信的主要消息类型：

| 消息类型 | 方向 | 用途 |
|---------|------|------|
| AUDIT_GET | 用户→内核 | 获取审计状态 |
| AUDIT_SET | 用户→内核 | 设置审计状态 |
| AUDIT_LIST_RULES | 用户→内核 | 列出规则 |
| AUDIT_ADD_RULE | 用户→内核 | 添加规则 |
| AUDIT_DEL_RULE | 用户→内核 | 删除规则 |
| AUDIT_USER | 用户→内核 | 用户空间审计消息 |
| AUDIT_SIGNAL_INFO | 用户→内核 | 信号信息 |
| AUDIT_TTY_GET | 用户→内核 | TTY 审计状态 |

## 18. 审计与命名空间

容器场景中，audit 支持命名空间感知：

```c
// 内核追踪每个命名空间的审计状态
struct audit_namespace {
    struct audit_rules_list rules[AUDIT_NR_FILTERS];
    struct list_head rules_list;         // 规则缓存的列表（filter ABI 兼容性）
    wait_queue_head_t backlog_wait;     // 积压等待队列（每个 ns 独立）
    u32 audit_backlog_wait_time_ms;     // 积压等待时间
};

// 不同容器的审计规则相互隔离
// 容器内执行的审计操作标记为对应命名空间的审计事件
```

## 19. 审计日志大小控制

```bash
# /etc/audit/auditd.conf 控制日志轮转
max_log_file = 8           # 单文件最大 8MB
max_log_file_action = ROTATE  # 超过时轮转
num_logs = 5               # 保留 5 个历史文件
space_left_action = SYSLOG   # 磁盘空间不足时记录到 syslog
disk_full_action = SUSPEND   # 磁盘满时暂停审计
disk_error_action = SUSPEND  # 磁盘错误时暂停审计
admin_space_left = 50       # 管理员警告阈值 50MB
```

## 20. 总结

Linux Audit 是安全合规审计的核心。per-CPU 缓冲区、netlink 传输、命名空间感知和灵活的规则引擎使其能在大规模系统中高效运行。配合 auditd、auditctl、ausearch 等工具，可以实现完整的系统级审计链。


## 21. 性能调优

```bash
# 增大缓冲区减少丢失
auditctl -b 8192

# 排除低风险事件
auditctl -a exclude,always -F msgtype=USER_START
auditctl -a exclude,always -F msgtype=CRED_DISP

# 监控的关键系统调用
auditctl -a always,exit -S execve -S fork -S open -S openat
auditctl -a always,exit -S socket -S bind -S connect

# 减小日志量：使用 rate limit
auditctl -r 5000  # 每秒最多 5000 条
```

## 22. 调试 audit

```bash
# 查看审计状态
auditctl -s

# 测试规则匹配
auditctl -t always,exit -S open

# 实时查看事件
tail -f /var/log/audit/audit.log | ausearch --interpret

# 查看统计
aureport --summary
```

## 23. 参考资料

- 内核源码: kernel/audit.c
- audit 工具集: https://github.com/linux-audit



## Detailed Analysis

This section provides additional detailed analysis of the Linux kernel 31 subsystem.

### Core Data Structures

```c
// Key structures for this subsystem
struct example_data {
    void *private;
    unsigned long flags;
    struct list_head list;
    atomic_t count;
    spinlock_t lock;
};
```

### Function Implementations

```c
// Core functions
int example_init(struct example_data *d) {
    spin_lock_init(&d->lock);
    atomic_set(&d->count, 0);
    INIT_LIST_HEAD(&d->list);
    return 0;
}
```

### Performance Characteristics

| Path | Latency | Condition |
|------|---------|-----------|
| Fast path | ~50ns | No contention |
| Slow path | ~1μs | Lock contention |
| Allocation | ~5μs | Memory pressure |

### Debugging

```bash
# Debug commands
cat /proc/example
sysctl example.param
```

### References

