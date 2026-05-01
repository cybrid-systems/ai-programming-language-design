# 66-**ext4 journal (jbd2)** 是 ext4 文件系统的日志块设备层，保证元数据一致性。写操作先记录到日志，再写入磁盘。 — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**ext4 journal (jbd2)** 是 ext4 文件系统的日志块设备层，保证元数据一致性。写操作先记录到日志，再写入磁盘。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
