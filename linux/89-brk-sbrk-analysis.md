# 89-brk-sbrk — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**brk/sbrk** 是进程堆扩展的基础系统调用。do_brk_flags() 在进程 VMA 末尾扩展匿名映射区域。malloc 的底层最终调用 brk。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
