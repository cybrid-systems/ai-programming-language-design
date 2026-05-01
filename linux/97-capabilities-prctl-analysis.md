# 97-capabilities-prctl — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**capabilities（权能）** 将 root 权限拆分为独立单元（如 CAP_NET_RAW、CAP_SYS_ADMIN），实现最小权限原则。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
