# 87-signalfd — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**signalfd** 将信号以 fd 形式传递给进程，可通过 read/poll/epoll 处理信号，避免了传统信号处理函数的异步问题。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
