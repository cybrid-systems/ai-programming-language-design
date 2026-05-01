# 98-procfs-sysctl — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**procfs**（/proc）和 **sysctl** 提供内核参数和进程信息的文件系统接口。procfs 暴露进程信息，sysctl 管理内核参数。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
