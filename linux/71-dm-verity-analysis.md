# 71-**dm-verity** 提供块设备的只读完整性校验，使用 Merkle 哈希树验证每个数据块。广泛用于 Android verified boot。 — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**dm-verity** 提供块设备的只读完整性校验，使用 Merkle 哈希树验证每个数据块。广泛用于 Android verified boot。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
