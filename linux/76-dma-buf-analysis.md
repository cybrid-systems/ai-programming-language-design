# 76-**dma-buf** 允许设备驱动之间共享 DMA 缓冲区（如 GPU 和显示控制器），实现零拷贝共享。 — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**dma-buf** 允许设备驱动之间共享 DMA 缓冲区（如 GPU 和显示控制器），实现零拷贝共享。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
