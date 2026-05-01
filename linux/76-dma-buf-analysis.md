# 76-dma-buf — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**dma-buf** 共享 DMA 缓冲区。dma_buf_export 导出，dma_buf_attach+sg_table 导入，GPU 和显示控制器之间零拷贝。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
