# 100-relayfs — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**relayfs（中继文件系统）** 提供从内核到用户空间的高效数据中继通道，适用于大量日志/跟踪数据的零拷贝传输。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
