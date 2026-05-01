# 31-audit — Linux 内核审计深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**Linux Audit 子系统**提供系统级的活动审计能力。它捕获系统调用、文件访问等安全事件，通过 netlink 送到 auditd。

## 1. 核心结构

```c
struct audit_context {
    int major;              // 系统调用号
    unsigned long argv[6];  // 参数
    long return_code;       // 返回值
    ktime_t ctime;          // 时间戳
};
```

审计上下文在 syscall 入口分配，exit 时检查并记录。

## 2. 过滤器

AUDIT_FILTER_USER → TASK → ENTRY → WATCH → EXIT

## 3. 数据流

syscall entry → audit_syscall_entry → 执行 → audit_syscall_exit → audit_filter → audit_log_start/format/end → netlink → auditd

## 4. 缓冲区

per-CPU audit_buffer 缓存。audit_backlog_limit=64，超限时丢弃。

## 5. 配置文件

/etc/audit/auditd.conf: log_file, max_log_file, flush, space_left_action

## 6. 调试

auditctl -s, auditctl -l, ausearch -k mykey, aureport --summary

## 7. 源码

| 文件 | 作用 |
|------|------|
| kernel/audit.c | 核心框架 |
| kernel/auditsc.c | syscall 审计 |
| kernel/auditfilter.c | 规则过滤 |
| kernel/audit_watch.c | 文件监视 |

## 9. 积压控制

当 audit 事件产生速度超过 auditd 处理能力时，netlink 接收队列积压。audit_backlog_limit 控制最大积压数量（默认 64），超过后事件被丢弃（audit_lost 计数器递增）。

## 10. 规则管理

添加规则: auditctl -a always,exit -S open -F key=mykey
删除规则: auditctl -d always,exit -S open
清空规则: auditctl -D
列出规则: auditctl -l

## 11. 性能影响

无审计: ~200ns/syscall
有审计: ~2-5us/syscall
规则越复杂，延迟越高

## 12. 命令速查

auditctl -s: 查看状态
auditctl -l: 列出规则
ausearch -m SYSCALL: 搜索系统调用
ausearch -k mykey: 按 key 搜索
aureport --summary: 摘要报告
aureport -x: 可执行文件统计

## 13. 关联文章

- **33-audit-deep**: 审计内部机制

