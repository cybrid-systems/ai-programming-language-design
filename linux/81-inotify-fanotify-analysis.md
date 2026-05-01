# 81-signal-signalfd — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**信号（Signal）** 是 Linux 进程间通信和异常处理机制。内核通过 `kernel/signal.c` 管理信号的发送、挂起和处理，支持标准 POSIX 信号和实时信号。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
