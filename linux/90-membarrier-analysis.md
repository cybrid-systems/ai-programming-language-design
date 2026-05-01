# 90-membarrier — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**membarrier** 提供高效的进程级内存屏障。用于用户空间 RCU 实现，比 sys_membarrier 轻量。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
