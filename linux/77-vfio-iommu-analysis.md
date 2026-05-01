# 77-VFIO-IOMMU — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**VFIO** 将设备透传给用户空间驱动。**IOMMU** 提供 DMA 重映射隔离。KVM 设备透传基于此。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
