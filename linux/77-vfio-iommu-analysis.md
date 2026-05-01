# 77-**VFIO** 将设备直接暴露给用户空间驱动，**IOMMU** 提供 DMA 重映射和安全隔离。KVM/QEMU 设备透传的核心。 — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**VFIO** 将设备直接暴露给用户空间驱动，**IOMMU** 提供 DMA 重映射和安全隔离。KVM/QEMU 设备透传的核心。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
