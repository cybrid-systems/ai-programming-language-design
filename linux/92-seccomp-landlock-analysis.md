# 92-seccomp-landlock — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**seccomp** 限制进程可用的系统调用。支持 strict mode（只允许 read/write/exit）和 filter mode（BPF 规则过滤）。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
