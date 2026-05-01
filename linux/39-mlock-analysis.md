# 39-mlock — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**mlock** 锁定物理页不被换出。do_mlock 设置 VM_LOCKED，__mlock_vma_pages_range 遍历页表锁定每页。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
