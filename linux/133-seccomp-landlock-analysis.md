# 133-memblock — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**memblock** 是引导阶段的内存分配器，在 buddy 系统初始化前管理物理内存。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
