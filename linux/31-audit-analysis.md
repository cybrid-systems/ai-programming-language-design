# 31-audit — Linux 审计子系统深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**audit** 是 Linux 安全审计子系统，记录系统安全相关事件（系统调用、文件访问、登录等），通过 netlink 将事件发送到用户空间的 auditd 守护进程。

---

## 1. 核心数据流

```
系统调用入口（syscall entry）
  │
  ├─ audit_syscall_entry(arch, nr, args)
  │    └─ 记录当前进程审计上下文
  │
  └─ 执行系统调用
       │
       └─ audit_syscall_exit(regs)
            ├─ 根据规则过滤
            ├─ 构造审计记录
            └─ kauditd_send_multicast_skb() → netlink → auditd
```

---

## 2. 源码文件索引

| 文件 | 功能 |
|------|------|
| `kernel/audit.c` | 核心审计框架 |
| `kernel/auditsc.c` | 系统调用审计 |
| `include/linux/audit.h` | 审计 API |

---

*分析工具：doom-lsp（clangd LSP）*
