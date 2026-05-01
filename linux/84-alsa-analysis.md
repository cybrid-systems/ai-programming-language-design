# 84-posix-timers — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**POSIX timers** 提供高精度定时器（timer_create/timer_settime），底层基于 hrtimer 实现，支持 CLOCK_REALTIME/MONOTONIC 等时钟源。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
