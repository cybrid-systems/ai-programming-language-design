# 36-slab-allocator — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**SLUB 分配器** 管理小对象分配。三层路径：Per-CPU freelist → partial slab → 从 buddy 分配新 slab。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
