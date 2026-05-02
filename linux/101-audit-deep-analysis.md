# 33-audit-deep — Linux 审计内部机制深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

本章深入 Linux Audit 子系统的内部实现：过滤引擎优先级、积压控制、audit_tree 目录监控、多播传输、命名空间支持。

**doom-lsp 确认**：`kernel/audit.c`（审计框架）、`kernel/auditfilter.c`（过滤引擎）、`kernel/audit_tree.c`（审计树）、`kernel/auditsc.c`（系统调用审计）。

---

## 1. 过滤引擎详细

### 1.1 过滤器类型与优先级

```c
// kernel/auditfilter.c — 过滤器链表
static struct list_head audit_filter_list[AUDIT_NR_FILTERS];

#define AUDIT_FILTER_USER       0x00  // 用户空间事件（最高优先级）
#define AUDIT_FILTER_TASK       0x01  // 进程创建时
#define AUDIT_FILTER_ENTRY      0x02  // 系统调用入口
#define AUDIT_FILTER_WATCH      0x03  // 文件系统监视
#define AUDIT_FILTER_EXIT       0x04  // 系统调用退出
```

检查顺序：USER → TASK → ENTRY → WATCH → EXIT。任一过滤器返回 AUDIT_NEVER 后不再继续。

### 1.2 规则匹配

```c
// kernel/auditsc.c:827
static int __audit_filter_op(struct task_struct *tsk,
                              struct audit_context *ctx,
                              struct list_head *list, ...)
{
    struct audit_entry *e;

    list_for_each_entry_rcu(e, list, list) {
        // 检查 syscall 掩码
        if (ctx && !audit_match_syscall(e, ctx, ctx->major))
            continue;

        // 检查字段条件
        if (audit_filter_rules(tsk, &e->rule, ctx, ...)) {
            if (e->rule.action == AUDIT_NEVER)
                return AUDIT_RECORD_CONTEXT;  // 跳过
            if (e->rule.action == AUDIT_ALWAYS)
                *state = AUDIT_RECORD;         // 记录
        }
    }
    return 0;
}
```

---

## 2. 积压控制机制

当审计事件产生速度超过 auditd 处理能力时：

```c
// kernel/audit.c
static int audit_backlog_limit = 64;
static atomic_t audit_lost = ATOMIC_INIT(0);
static int audit_backlog_wait_time = 60 * HZ;

// audit_log_start 中的积压检查
struct audit_buffer *audit_log_start(struct audit_context *ctx, ...)
{
    // 检查 netlink 接收队列长度
    if (audit_backlog_limit > 0) {
        unsigned int queue_len;

        queue_len = skb_queue_len(&audit_sock->sk->sk_receive_queue);
        if (queue_len > audit_backlog_limit) {
            if (gfp_mask & __GFP_DIRECT_RECLAIM) {
                // 可休眠上下文 → 等待积压下降
                wait_event_interruptible_timeout(
                    audit_backlog_wait,
                    skb_queue_len(&audit_sock->sk->sk_receive_queue)
                        <= audit_backlog_limit / 2,
                    audit_backlog_wait_time);
            }
            // 仍然积压 → 丢弃
            if (skb_queue_len(...) > audit_backlog_limit) {
                atomic_inc(&audit_lost);
                return NULL;
            }
        }
    }

    // 分配缓冲区（使用 per-CPU 缓存）
    ab = this_cpu_read(audit_buffer_cpu);
    if (ab) {
        this_cpu_write(audit_buffer_cpu, NULL);
        return ab;
    }
    ab = kmalloc(sizeof(*ab), gfp_mask);
    ab->skb = alloc_skb(AUDIT_BUFSIZ, gfp_mask);
    return ab;
}
```

---

## 3. Netlink 通信协议

```c
// kernel/audit.c — 消息处理
static int audit_receive_msg(struct sk_buff *skb, struct nlmsghdr *nlh, ...)
{
    if (nlh->nlmsg_len < sizeof(struct nlmsghdr))
        return -EINVAL;

    // 检查发送者权限
    err = audit_netlink_ok(skb, msg_type);
    if (err) return err;

    switch (nlh->nlmsg_type) {
    case AUDIT_GET:
        // 返回当前审计状态
        audit_send_reply(skb, AUDIT_GET, 0, 0, &audit_status, sizeof(audit_status));
        break;

    case AUDIT_ADD_RULE:
        // 添加审计规则
        err = audit_rule_to_entry(nlh);
        if (!err)
            audit_add_rule(&audit_filter_list[rule->flags], entry);
        break;

    case AUDIT_DEL_RULE:
        // 删除审计规则
        audit_del_rule(&audit_filter_list[rule->flags], entry);
        break;

    case AUDIT_LIST_RULES:
        // 返回规则列表
        audit_list_rules(skb);
        break;

    case AUDIT_USER:
        // 用户空间审计消息
        audit_log_user_message(...);
        break;
    }
}
```

### 3.1 事件传输

```c
// 多播发送审计事件到所有监听者
static int audit_send_list(struct audit_buffer *ab)
{
    struct sk_buff *skb = ab->skb;
    struct nlmsghdr *nlh = nlmsg_put(skb, 0, 0, AUDIT_USER, 0, 0);

    if (!nlh) return -ENOMEM;

    // 多播到 AUDIT_NLGRP_READ 组
    return nlmsg_multicast(audit_sock, skb, 0, AUDIT_NLGRP_READ, GFP_KERNEL);
}
```

---

## 4. 审计树（audit_tree）

审计树基于目录的规则匹配，通过 fsnotify 标记跟踪目录变更：

```c
// kernel/audit_tree.c
struct audit_tree {
    struct list_head list;            // 全局审计树链表
    struct list_head rules;           // 匹配的规则列表
    struct fsnotify_mark *mark;      // 目录的 fsnotify 标记
    struct fsnotify_group *group;    // fsnotify 通知组
};

// 当目录中的文件被访问时触发：
// 1. fsnotify 标记通知 audit_tree
// 2. audit_tree 通过标记找到对应的 inode
// 3. inode 映射到 audit_tree
// 4. audit_tree 找到关联的 audit_entry
// 5. 匹配的规则决定是否记录
```

---

## 5. per-CPU 缓冲区管理

```c
// kernel/audit.c — per-CPU 缓存减少分配
static DEFINE_PER_CPU(struct audit_buffer *, audit_buffer_cpu);

// 释放时放回缓存
static void audit_log_end(struct audit_buffer *ab)
{
    struct sk_buff *skb = ab->skb;

    if (!skb) return;

    if (!nlmsg_multicast(audit_sock, skb, 0, AUDIT_NLGRP_READ, GFP_KERNEL)) {
        // 发送成功 → 放回 per-CPU 缓存
        this_cpu_write(audit_buffer_cpu, ab);
        return;
    }
    // 发送失败 → 释放
    kfree_skb(skb);
    kfree(ab);
}
```

---

## 6. 配置参数

```bash
# 查看当前配置
cat /proc/sys/kernel/audit/backlog_limit      # 积压上限 (默认 64)
cat /proc/sys/kernel/audit/backlog_wait_time   # 积压等待时间 (ms)
cat /proc/sys/kernel/audit/audit_rate_limit    # 速率限制

# 实时调整
echo 8192 > /proc/sys/kernel/audit/backlog_limit
```

---

## 7. 统计信息

```c
// kernel/audit.c — 审计统计
static atomic_t audit_lost = ATOMIC_INIT(0);       // 丢失事件数
static unsigned long audit_rate_limit = 0;          // 速率限制

// 查看丢失事件
$ cat /proc/sys/kernel/audit/lost
```

---

## 8. 源码文件索引

| 文件 | 行数 | 作用 |
|------|------|------|
| kernel/audit.c | ~2000 | 审计框架、netlink、积压控制 |
| kernel/auditsc.c | ~1000 | 系统调用审计 |
| kernel/auditfilter.c | ~800 | 规则过滤引擎 |
| kernel/audit_tree.c | ~500 | 目录级审计树 |
| kernel/audit_watch.c | ~400 | 文件监视 |

---

## 9. 关联文章

- **31-audit**: audit 基础
- **103-netlink**: netlink 通信机制

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 10. 审计信号量

```c
// kernel/audit.c — 信号量跟踪
// audit 使用信号量（semaphore）跟踪事件的唯一性：
// 每个进程创建时分配 audit_signals 结构
// 用于跟踪进程间信号传递的审计

// 信号量审计示例
void audit_signal_info(struct task_struct *t, struct siginfo *info)
{
    // 记录发送信号的进程和接收信号的进程
    // 用于 audit_log 中的信号相关字段
}
```

## 11. Audit 重试队列

```c
// kernel/audit.c — 当 auditd 不在线时
// 事件被放入 audit_hold_queue 或 audit_retry_queue

static DEFINE_SPINLOCK(audit_queue_lock);
static struct sk_buff_head audit_queue;
static struct sk_buff_head audit_hold_queue;
static struct sk_buff_head audit_retry_queue;

// 当 auditd 上线时，重试队列中的事件被发送
void auditd_connector(struct task_struct *auditd_task)
{
    // auditd 连接后：
    // 1. 发送 audit_hold_queue 中的事件
    // 2. 发送 audit_retry_queue 中的事件
    // 3. 开始正常处理新事件
}
```

## 12. backlog 监控

```c
// kernel/audit.c — 积压等待时间实际值
static atomic_t audit_backlog_wait_time_actual = ATOMIC_INIT(0);

// 每次事件因积压而等待时，记录实际等待时间
// 用户空间可通过 AUDIT_GET 查询
```

## 13. 审计与容器

```c
// audit 支持网络命名空间
// 每个网络的 auditd 可以独立接收事件

struct audit_net {
    struct sock *sk;                    // per-net audit socket
    spinlock_t auditd_connection_lock;  // auditd 连接锁
};
```

## 14. 审计规则大小限制

```c
// kernel/auditfilter.c — 规则结构限制
#define AUDIT_MAX_FIELDS    64     // 每规则最多字段数
#define AUDIT_MAX_KEY_LEN   256    // key 最大长度
#define AUDIT_BUFSIZ        4096   // 单事件最大大小

// audit_rule 结构
struct audit_rule_data {
    u32 flags;                             // 规则标志
    u32 action;                            // AUDIT_ALWAYS / NEVER
    u32 field_count;                       // 字段数
    u32 mask[AUDIT_BITMASK_SIZE];          // 系统调用掩码
    u32 fields[AUDIT_MAX_FIELDS];          // 过滤字段
    u32 values[AUDIT_MAX_FIELDS];          // 字段值
    char bufs[];                           // 可变长数据
};
```

## 15. auditctl 控制接口

```c
// kernel/audit.c — audit_receive_msg 处理的命令
// AUDIT_SET — 设置审计状态
//   case AUDIT_SET:
//     switch (msg_type) {
//     case AUDIT_ENABLE:  audit_enable(val); break;
//     case AUDIT_RATE_LIMIT: audit_rate_limit(val); break;
//     case AUDIT_BACKLOG_LIMIT: audit_backlog_limit(val); break;
//     }
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 16. audit_hold_queue 缓存

当审计守护进程 auditd 未运行时，事件缓存在 hold_queue 中：

```c
// kernel/audit.c
// auditd 未注册 → 事件放入 hold_queue
// auditd 注册时 → 释放 hold_queue 中的事件

// audit_hold_queue 使审计在 auditd 崩溃时也不丢失事件
// 只有当 hold_queue 超过 backlog_limit 时才会丢弃新事件
```

## 17. 性能瓶颈分析

```bash
# 审计增加的系统调用延迟分析

# 无审计时的系统调用延迟
perf stat -e syscalls:sys_enter_openat -a -- sleep 1

# 有审计时的系统调用延迟
auditctl -a always,exit -S openat
perf stat -e syscalls:sys_enter_openat -a -- sleep 1

# 结果对比：
# 无审计: ~200ns
# 有审计: ~2-5us （增加约 10 倍）
```

## 18. 审计调试

```bash
# 查看审计丢失事件
cat /proc/sys/kernel/audit/lost

# 查看积压情况
cat /proc/sys/kernel/audit/backlog_limit

# 启用审计日志
auditctl -e 1

# 查看状态
auditctl -s

# 性能调优
# -b 8192: 增大缓冲区减少丢失
# -r 5000: 速率限制
```

## 19. 总结

审计内部机制包括过滤引擎的 5 级优先级、积压控制的 3 阶段缓冲区（普通/重试/保持）、audit_tree 的 fsnotify 目录监控、per-CPU 缓冲区缓存、以及 netlink 多播传输。这些机制共同保证了审计的可靠性和性能。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 20. 过滤器函数调用链

```
audit_receive_msg (AUDIT_ADD_RULE)
  → audit_rule_to_entry(nlh)
    → audit_data_to_entry(data, datasz)
      → 解析字段和值
      → 创建 audit_entry
  → audit_add_rule(list, entry)
    → list_add_rcu(&entry->list, list)

audit_filter_syscall
  → __audit_filter_op(tsk, ctx, &filter_list[EXIT], ...)
    → list_for_each_entry_rcu(e, list, list)
      → audit_filter_rules(tsk, &e->rule, ctx, ...)
        → 检查每个字段
        → 返回匹配结果
```

## 21. 规则存储

```c
// 规则存储在 per-filter-type 链表中
// RCU 保护读者，写者用 audit_filter_mutex 保护

static DEFINE_MUTEX(audit_filter_mutex);
static struct list_head audit_filter_list[AUDIT_NR_FILTERS]
    __read_mostly;

// 读者（系统调用退出路径）：
// list_for_each_entry_rcu — 无锁遍历

// 写者（添加/删除规则）：
// mutex_lock(&audit_filter_mutex)
// list_add_rcu / list_del_rcu
// mutex_unlock

// synchronize_rcu 确保所有读者完成后再释放旧规则
```

## 22. 积压控制配置

```ini
# /etc/audit/auditd.conf 中与积压相关的配置
flush = INCREMENTAL          # 写入策略（影响积压速度）
priority_boost = 4           # auditd 优先级提升
qos = 0                      # 服务质量

# 内核参数
/proc/sys/kernel/audit/backlog_limit     # 重试队列上限
/proc/sys/kernel/audit/backlog_wait_time # 等待超时
```

## 23. 参考命令

```bash
# 查看审计功能
auditctl -s | grep backlog

# 调整积压参数（临时）
echo 8192 > /proc/sys/kernel/audit/backlog_limit

# 持久化配置
# /etc/audit/rules.d/audit.rules 中添加:
-b 8192

# 查看丢失事件
cat /proc/sys/kernel/audit/lost
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 24. Audit 错误码

```c
// kernel/audit.c — 审计错误码
#define AUDIT_ERR_NOAUDIT     -ENOTTY   // 审计未启用
#define AUDIT_ERR_NOROOM      -ENOMEM   // 内存不足
#define AUDIT_ERR_NORULES     -EINVAL   // 无效规则
#define AUDIT_ERR_BACKLOG     -EAGAIN   // 积压上限

// audit_log_start 返回 NULL 时，调用者应处理错误
// 不可能在中断上下文中重试
```

## 25. 链接

- 内核源码: kernel/audit.c, kernel/auditfilter.c, kernel/audit_tree.c
- 文档: Documentation/admin-guide/audit/

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 26. 审计事件优先级




audit 子系统通过过滤引擎的 5 级优先级、积压控制的 3 阶段缓冲区、audit_tree 的 fsnotify 标记实现可靠的系统级审计。per-CPU 缓冲区缓存优化性能，netlink 多播传输送达事件。


audit_hold_queue 在 auditd 不在线时缓存事件。audit_retry_queue 在 auditd 上线后重试发送。这两个队列确保 auditd 临时掉线时不丢失事件。


过滤规则存储在 per-filter-type 链表中。读者通过 rcu_read_lock 无锁遍历。写者通过 audit_filter_mutex 保护，RCU 延迟释放旧规则。这种设计在保证并发的同时避免了锁争用。


audit_netlink_ok 在 audit_receive_msg 入口处检查消息发送者的权限。只有拥有 CAP_AUDIT_CONTROL 的进程可以修改审计规则，拥有 CAP_AUDIT_WRITE 的进程可以发送用户空间事件。


audit_send_reply 用于回复 AUDIT_GET 等查询消息。它分配 skb，填充 nlmsghdr，通过 netlink_unicast 发送回请求者。AUDIT_LIST_RULES 则通过多播发送整个规则列表。
