# 86-eventfd — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**eventfd** 提供进程间的事件通知机制，可被 poll/select/epoll 监听，常用于用户空间到内核的事件通知。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
