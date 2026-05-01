# 68-**btrfs (B-tree FS)** 是写时复制（COW）文件系统，支持快照、压缩、RAID、子卷等高级功能。 — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**btrfs (B-tree FS)** 是写时复制（COW）文件系统，支持快照、压缩、RAID、子卷等高级功能。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
