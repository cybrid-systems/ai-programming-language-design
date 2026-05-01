# 31-audit — Linux 内核审计深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**Linux Audit** 是内核的安全事件审计子系统。它记录系统调用、文件访问、进程创建等安全相关事件，生成审计日志供安全分析。广泛应用于 SELinux、AppArmor、PCI DSS 合规等场景。

**doom-lsp 确认**：`kernel/audit.c` 是主实现文件。`kernel/auditsc.c` 实现系统调用审计。

---

## 1. 架构

```
用户空间               auditd 守护进程
                          ↑
                      netlink
                          ↑
内核              audit_receive_msg()
                    ↓              ↑
               audit_log_start()   audit_filter()
                    ↓
               audit_buffer → nlmsgbuf → auditd
```

---

## 2. 核心函数

```c
// 记录审计事件（核心输出）
struct audit_buffer *audit_log_start(struct audit_context *ctx,
                                      gfp_t gfp_mask, int type);
void audit_log_format(struct audit_buffer *ab, const char *fmt, ...);
void audit_log_end(struct audit_buffer *ab);

// 使用示例
audit_log(audit_context(), GFP_KERNEL,
          AUDIT_SYSCALL, "syscall=%d arg0=%lx", nr, a0);
```

---

## 3. 审计规则

```bash
auditctl -a always,exit -S open -F key=my_rule
auditctl -a always,exit -F arch=b64 -S execve
ausearch -k my_rule
aureport --summary
```

---

## 4. 源码文件索引

| 文件 | 内容 |
|------|------|
| kernel/audit.c | 核心框架 |
| kernel/auditsc.c | 系统调用审计 |
| kernel/auditfilter.c | 规则过滤 |
| kernel/audit_watch.c | 文件监视 |

---

## 5. 关联文章

- **33-audit-deep**：审计深度分析

---

*分析工具：doom-lsp*
