# 135-page-table-walk — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**page table walk** 遍历进程的页表，用于/proc/xx/maps、KSM、migration 等场景。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
