# 95-namespace-unshare — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**命名空间（namespace）** 隔离全局系统资源，包括 mount/PID/net/IPC/UTS/user/cgroup 命名空间，是容器技术的基础。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
