# 33-audit-deep — Linux 审计深度源码分析

> 基于 Linux 7.0-rc1 主线源码

---

## 0. 概述

本章深入分析 audit 子系统的内部实现机制，包括信号量、过滤引擎、多播传输等。

**doom-lsp 确认**：核心实现在 `kernel/audit.c`（约 2000 行）。

---

## 1. 过滤引擎

```c
// kernel/auditfilter.c

struct audit_field {
    u32 type;                   // AUDIT_UID, AUDIT_GID, AUDIT_PID ...
    u32 op;                     // Audit_equal, Audit_not_equal
    u32 val;                    // 比较值
};

struct audit_rule {
    struct list_head list;
    int flags;                  // AUDIT_FILTER_EXIT, AUDIT_FILTER_USER
    struct audit_field fields[ AUDIT_MAX_FIELDS ];
};

// 过滤类型
#define AUDIT_FILTER_USER       0x00  // 用户空间事件
#define AUDIT_FILTER_TASK       0x01  // 进程创建时
#define AUDIT_FILTER_ENTRY      0x02  // 系统调用入口
#define AUDIT_FILTER_WATCH      0x03  // 文件监视
#define AUDIT_FILTER_EXIT       0x04  // 系统调用退出
```

---

## 2. 信号量管理

audit 使用信号量来控制日志量和负载：

```c
// kernel/audit.c
static atomic_t audit_lost = ATOMIC_INIT(0);   // 丢失事件计数
static int audit_backlog_limit = 64;            // 积压上限
static int audit_backlog_wait_time = 60 * HZ;   // 等待时间上限

int audit_log_start(struct audit_context *ctx, gfp_t gfp_mask, int type)
{
    // 检查积压队列
    if (audit_backlog_limit &&
        skb_queue_len(&audit_sock->sk->sk_receive_queue) > audit_backlog_limit) {
        if (gfp_mask & __GFP_DIRECT_RECLAIM) {
            // 等待积压下降
            wait_for_auditd();
        }
    }
}
```

---

## 3. 关联文章

- **31-audit**: audit 基础

---
