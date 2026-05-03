# 31-audit — Linux 内核审计深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**Linux Audit 子系统**提供系统调用级的安全事件审计。捕获系统调用、文件访问、进程创建等事件，通过 netlink 送到 auditd。

**doom-lsp 确认**：`kernel/audit.c`、`kernel/auditsc.c`、`kernel/auditfilter.c`。

---

## 1. 核心数据结构

```c
struct audit_context {
    int     major;               // 系统调用号
    int     serial;              // 序列号
    unsigned long argv[6];       // 6 个参数
    long    return_code;         // 返回值
    struct audit_names *names;   // 路径名
    ktime_t ctime;               // 时间戳
};

struct audit_buffer {
    struct sk_buff *skb;         // netlink 消息
    gfp_t          gfp_mask;
};

struct audit_entry {
    struct list_head    list;
    struct audit_rule   rule;
    struct audit_watch  *watch;
};
```

---

## 2. 系统调用审计数据流

```
syscall entry: __audit_syscall_entry(major, a0..a3)
  → audit_alloc_context() → current->audit_context = ctx

[系统调用执行]

syscall exit: __audit_syscall_exit(success, return_code)
  → audit_filter_syscall() 遍历 filter_list[EXIT]
    → AUDIT_NEVER: 跳过（优先级高于 ALWAYS）
    → AUDIT_ALWAYS: 记录
  → audit_log_start → format（syscall/arch/success/exit/auid/uid/comm/exe）
  → audit_log_end → nlmsg_multicast → auditd
  → audit_free_context()
```

---

## 3. 过滤引擎

```c
int audit_filter(int msgtype, enum audit_state *state)
{
    list_for_each_entry_rcu(e, &audit_filter_list[AUDIT_FILTER_EXIT], list) {
        if (audit_filter_rules(tsk, &e->rule, ctx, ...)) {
            if (e->rule.action == AUDIT_NEVER) return 0;
            if (e->rule.action == AUDIT_ALWAYS) ret = 1;
        }
    }
    return ret;
}
```

8 种过滤类型（AUDIT_NR_FILTERS=8）：USER → TASK → ENTRY → WATCH → EXIT → EXCLUDE → FS → URING_EXIT

---

## 4. 审计规则

```bash
# 系统调用规则
auditctl -a always,exit -S open -S openat -F key=file_ops
auditctl -a always,exit -S execve -F uid=0 -k root_exec

# 文件监控
auditctl -w /etc/shadow -p wa -k shadow_changes

# 排除噪声
auditctl -a exclude,always -F msgtype=USER_START
```

---

## 5. netlink 通信

```c
static int audit_send_list(struct audit_buffer *ab)
{
    return nlmsg_multicast(audit_sock, ab->skb, 0, AUDIT_NLGRP_READ, GFP_KERNEL);
}
```

---

## 6. 积压控制

```c
static u32 audit_backlog_limit = 64;

if (skb_queue_len(...) > audit_backlog_limit) {
    // 等待或丢弃
    atomic_inc(&audit_lost);
}
```

---

## 7. 审计日志格式

```
type=SYSCALL msg=audit(...): arch=c000003e syscall=2 success=yes
  a0=7ffd1234 a1=0 items=1 auid=1000 uid=0 comm="cat"
  exe="/usr/bin/cat" key="file_ops"

type=PATH msg=audit(...): item=0 name="/etc/shadow"
```

---

## 8. 事件类型

| 代码 | 类型 | 说明 |
|------|------|------|
| 1300 | AUDIT_SYSCALL | 系统调用 |
| 1302 | AUDIT_PATH | 路径名 |
| 1309 | AUDIT_EXECVE | execve 参数 |
| 1320 | AUDIT_USER_START | 用户登录 |
| 1400 | AUDIT_AVC | SELinux 决策 |

---

## 9. 性能

| 操作 | 延迟 |
|------|------|
| 无审计 syscall | ~200ns |
| 有审计 syscall | ~2-5us |
| netlink 发送 | ~1-2us |

---

## 10. 常用命令

```bash
auditctl -s              # 状态
auditctl -l              # 规则
auditctl -b 8192         # 缓冲区
auditctl -r 5000         # 速率限制
ausearch -m SYSCALL      # 搜索
ausearch -k mykey -i     # 按 key
aureport --summary       # 报告
```

---

## 11. 配置参考

```ini
# /etc/audit/auditd.conf
log_file = /var/log/audit/audit.log
max_log_file = 8
max_log_file_action = ROTATE
space_left_action = SYSLOG
```

```bash
# /etc/audit/rules.d/audit.rules
-D -b 8192 -f 1
-a always,exit -S execve -S open -S openat
-w /etc/shadow -p wa
-a exclude,always -F msgtype=USER_START
```

---

## 12. audit_buffer 分配

```c
struct audit_buffer *audit_log_start(struct audit_context *ctx, gfp_t gfp_mask, int type)
{
    // 检查积压队列
    while (audit_backlog_limit &&
           skb_queue_len(&audit_queue) > audit_backlog_limit) {
        wake_up_interruptible(&kauditd_wait);
        schedule_timeout(stime);
    }
    // 分配 buffer（使用 kmem_cache）
    ab = audit_buffer_alloc(ctx, gfp_mask, type);
    ab->skb = nlmsg_new(AUDIT_BUFSIZ, gfp_mask);
    return ab;
}
```

---

## 13. 审计上下文释放

```c
static inline void audit_free_context(struct audit_context *context)
{
    audit_reset_context(context);
    audit_proctitle_free(context);
    free_tree_refs(context);
    kfree(context->filterkey);
    kfree(context);
}
```

---

## 14. 审计系统初始化

```c
static int __init audit_init(void)
{
    audit_buffer_cache = KMEM_CACHE(audit_buffer, SLAB_PANIC);
    skb_queue_head_init(&audit_queue);
    skb_queue_head_init(&audit_retry_queue);
    skb_queue_head_init(&audit_hold_queue);
    register_pernet_subsys(&audit_net_ops);
    kauditd_task = kthread_run(kauditd_thread, NULL, "kauditd");
    return 0;
}
```

---

## 15. 审计规则优先级

AUDIT_NEVER > AUDIT_ALWAYS。规则按链表顺序匹配，先匹配到 AUDIT_NEVER 则跳过记录。

---

## 16. 问题排查

```bash
systemctl status auditd     # 守护进程状态
auditctl -s                 # 内核审计状态
cat /proc/sys/kernel/audit/backlog_limit  # 积压上限
grep audit_lost /var/log/kern.log        # 丢失事件
```

---

## 17. 安全最佳实践

```bash
-b 8192                     # 足够缓冲区
-f 1                        # 故障静默
-a always,exit -S execve    # 程序执行监控
-a always,exit -S open -S openat  # 文件打开
-w /etc/passwd -p wa        # 关键文件
-w /etc/shadow -p wa
-a exclude,always -F msgtype=USER_START  # 排除噪声
```

---

## 18. 关联文章

- **33-audit-deep**: 审计深入分析

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 19. 审计事件类型详解

```c
// include/uapi/linux/audit.h
#define AUDIT_SYSCALL       1300  // 系统调用
#define AUDIT_PATH          1302  // 路径名
#define AUDIT_IPC           1303  // IPC 操作
#define AUDIT_EXECVE        1309  // execve 参数和环境
#define AUDIT_USER_START    1320  // 用户会话开始
#define AUDIT_USER_END      1321  // 用户会话结束
#define AUDIT_LOGIN         1322  // 登录结果
#define AUDIT_AVC           1400  // SELinux 决策
#define AUDIT_MAC_POLICY_LOAD 1403  // 策略加载
#define AUDIT_KERNEL        2000  // 内核事件
#define AUDIT_USER          2100  // 用户空间事件
```

## 20. 规则匹配流程

```c
// kernel/auditsc.c:869
static void audit_filter_syscall(struct task_struct *tsk,
                                  struct audit_context *ctx, enum audit_state *state)
{
    __audit_filter_op(tsk, ctx, &audit_filter_list[AUDIT_FILTER_EXIT], ...);
}

// __audit_filter_op 遍历 filter_list 中的每条规则:
// 1. 检查 syscall 掩码是否匹配
// 2. 检查字段条件（uid/gid/pid/arch/msgtype）
// 3. Audit_equal / Audit_not_equal 操作符比较
// 4. AUDIT_NEVER → 跳过记录
// 5. AUDIT_ALWAYS → 记录
```

## 21. 审计日志分析示例

```bash
# 查看所有失败的系统调用
ausearch --success no -i

# 查看特定用户的操作
ausearch -ua 1000 -ts today -i

# 统计事件分布
ausearch --interpret | grep "^type=" | sort | uniq -c | sort -rn

# 实时监控
tail -f /var/log/audit/audit.log | ausearch --interpret
```

## 22. 审计与安全性

| 功能 | 说明 |
|------|------|
| 入侵检测 | 监控 execve、open 等敏感系统调用 |
| 文件完整性 | 监控关键配置文件变更 |
| 用户审计 | 追踪用户操作历史 |
| 合规审计 | PCI DSS、SOC2 等合规要求 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 23. 审计规则格式详解

```bash
# 完整语法
auditctl -a <list>,<action> [-S syscall] [-F field=value] [-k key]

# list 类型:
#   task    - 进程创建时过滤
#   exit    - 系统调用退出时（最常用）
#   user    - 用户空间事件
#   exclude - 事件排除

# action 类型:
#   always  - 始终记录
#   never   - 不记录（优先级高于 always）

# 常用过滤字段:
#   uid    - 用户 ID
#   gid    - 组 ID
#   pid    - 进程 ID
#   ppid   - 父进程 ID
#   arch   - 架构（b64 = x86_64）
#   success - 成功(1)或失败(0)
#   msgtype - 消息类型
#   auid   - 审计用户 ID

# 文件监控:
#   auditctl -w /path -p rwxa -k key
#   r=读, w=写, x=执行, a=属性修改
```

## 24. auditd 配置

```ini
# /etc/audit/auditd.conf
log_file = /var/log/audit/audit.log   # 日志路径
log_format = RAW                        # 日志格式
flush = INCREMENTAL                     # 刷新策略
max_log_file = 8                        # 单文件最大 (MB)
max_log_file_action = ROTATE            # 超限处理
num_logs = 5                            # 保留历史数
space_left_action = SYSLOG              # 磁盘不足时
admin_space_left = 50                   # 告警阈值 (MB)
disk_full_action = SUSPEND              # 磁盘满时
disk_error_action = SUSPEND             # 磁盘错误时
```

## 25. 问题排查指南

```bash
# 1. auditd 未运行
systemctl start auditd
systemctl enable auditd

# 2. 日志丢失
# 原因: auditd 处理速度跟不上事件产生速度
# 解决: auditctl -b 8192 (增大缓冲区)

# 3. 规则加载失败
# 检查规则文件语法: auditctl -R /etc/audit/rules.d/audit.rules

# 4. 性能问题
# 增加排除规则减少事件量
# auditctl -a exclude,always -F msgtype=USER_START
```

## 26. 总结

Linux Audit 子系统是安全审计的核心基础设施。通过 per-CPU 缓冲区缓存减少分配开销、netlink 多播传输送达事件、灵活规则引擎支持系统调用/文件/用户多维度过滤。audit_backlog_limit 控制积压防止内存耗尽，AUDIT_NEVER 优先级高于 AUDIT_ALWAYS 提供精细控制。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 27. 高级规则示例

```bash
# 监控权限提升
auditctl -a always,exit -S execve -F euid=0 -k priv_esc

# 监控 SSH 配置
auditctl -w /etc/ssh/sshd_config -p wa -k sshd_config

# 监控 sudo 执行
auditctl -w /etc/sudoers -p wa -k sudoers
auditctl -w /etc/sudoers.d -p wa -k sudoers

# 监控网络配置
auditctl -a always,exit -S sethostname -S setdomainname

# 监控时间变更
auditctl -a always,exit -S settimeofday -S clock_settime

# 监控内核模块加载
auditctl -a always,exit -S init_module -S finit_module

# 监控用户/组管理
auditctl -w /etc/passwd -p wa -k identity
auditctl -w /etc/group -p wa -k identity
auditctl -w /etc/shadow -p wa -k identity
```

## 28. 审计系统限制

| 限制项 | 默认值 | 说明 |
|--------|--------|------|
| backlog_limit | 64 | 积压队列上限 |
| AUDIT_BUFSIZ | 1024 | 单事件最大大小 |
| AUDIT_MAX_FIELDS | 64 | 单规则最大字段数 |
| AUDIT_NAME_MAX | 64 | 路径名数量上限 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 29. 审计规则排错

```bash
# 测试规则是否匹配
auditctl -t always,exit -S open

# 查看规则计数
auditctl -l -v

# 临时启用/禁用审计
auditctl -e 1   # 启用
auditctl -e 0   # 禁用

# 清空所有规则
auditctl -D
```

## 30. 审计日志轮转配置

```ini
# /etc/logrotate.d/audit
/var/log/audit/*.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        /sbin/service auditd restart >/dev/null 2>&1 || true
    endscript
}
```

## 31. 规则优化建议

```bash
# 1. 使用文件监控替代 syscall 规则（性能更好）
# 不好: auditctl -a always,exit -S open -F path=/etc/shadow
# 更好: auditctl -w /etc/shadow -p wa

# 2. 合并同类规则到 key
# 不好: auditctl -a always,exit -S open -k open_trace
#        auditctl -a always,exit -S openat -k open_trace
# 更好: auditctl -a always,exit -S open -S openat -k open_trace

# 3. 使用排除规则减少日志量
# auditctl -a exclude,always -F msgtype=USER_START
# auditctl -a exclude,always -F msgtype=CRED_DISP
```

## 32. 审计上下文生命周期

```c
// 1. syscall 入口 — 分配上下文
context = audit_alloc_context(AUDIT_RECORD_CONTEXT);
current->audit_context = context;

// 2. syscall 执行期间 — 记录路径名
audit_getname(context, filename);

// 3. syscall 退出 — 过滤并记录
audit_filter_syscall(current, context, &state);
if (state == AUDIT_RECORD)
    audit_log_exit(context, current);

// 4. 释放上下文
audit_free_context(context);
current->audit_context = NULL;
```

## 33. 总结

Linux Audit 是系统安全审计的核心组件。通过 per-CPU 缓冲区缓存、netlink 多播传输和灵活的多维度过滤引擎，在系统调用级提供细粒度审计能力且保持低性能影响。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 34. 审计网络命名空间

容器场景中，每个网络命名空间有独立的 audit socket：

```c
struct audit_net {
    struct sock *sk;
};
```

## 35. 参考链接

- 内核源码: kernel/audit.c, kernel/auditsc.c, kernel/auditfilter.c
- 工具: auditd, auditctl, ausearch, aureport
- 文档: Documentation/admin-guide/audit/

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 36. 审计 vs 其他追踪机制

| 机制 | 层级 | 用途 |
|------|------|------|
| audit | 系统调用 | 安全审计 |
| ftrace | 函数级 | 调试/性能 |
| perf | PMU/软件事件 | 性能分析 |
| eBPF | 可编程 | 观测/安全 |
| tracepoints | 静态插桩 | 调试 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01*

## 37. auditctl 高级参数




audit 子系统通过三种机制保证可靠性：积压队列限制防止内存耗尽、丢失计数器跟踪丢失事件、AUDIT_NEVER 优先级高于 AUDIT_ALWAYS 提供确定性过滤。


audit_log_start 通过 kmem_cache (audit_buffer_cache) 分配 audit_buffer，skb 通过 nlmsg_new(AUDIT_BUFSIZ) 创建。简化了旧版本的 per-CPU 缓存设计。


过滤引擎支持 8 种过滤类型：USER、TASK、ENTRY、WATCH、EXIT、EXCLUDE（记录前排除）、FS（inode_child）、URING_EXIT（io_uring 退出）。EXIT 是最常用的过滤点。


每个 audit_context 在系统调用入口处分配，在系统调用退出后释放。期间通过 audit_getname 记录操作的文件路径。每个路径名包含 inode、设备号、权限和 SELinux 上下文。


audit_receive_msg 处理来自用户空间的 NETLINK_AUDIT 消息：AUDIT_ADD_RULE 添加规则、AUDIT_DEL_RULE 删除规则、AUDIT_LIST_RULES 列出规则、AUDIT_GET 查询状态。


audit_log_end 将完成格式化的审计记录提交。nlmsg_multicast 发送到 AUDIT_NLGRP_READ 组。所有订阅该 netlink 组的进程（如 auditd、ausearch）都会收到事件。
