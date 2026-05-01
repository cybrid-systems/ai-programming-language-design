# 85-epoll — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**epoll** 是 Linux 高性能 I/O 事件通知机制，使用红黑树组织监听 fd，就绪列表返回活跃 fd。支持 ET（边缘触发）和 LT（水平触发）。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
