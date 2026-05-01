# 93-apparmor-selinux — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**AppArmor** 和 **SELinux** 是 Linux 强制访问控制（MAC）系统。AppArmor 基于路径名，SELinux 基于安全上下文（label）。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
