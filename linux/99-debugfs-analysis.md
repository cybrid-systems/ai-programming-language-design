# 99-debugfs — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**debugfs** 是内核调试文件系统（/sys/kernel/debug/），驱动开发者可在此创建调试接口，生产环境通常禁用。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
