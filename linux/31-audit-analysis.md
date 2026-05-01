# 31-audit — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**audit** 记录系统安全事件（系统调用、文件访问）。syscall entry 时 audit_syscall_entry 记录上下文，exit 时根据规则过滤并通过 netlink 发送给 auditd。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
