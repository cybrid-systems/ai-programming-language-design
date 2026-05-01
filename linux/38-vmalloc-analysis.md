# 38-vmalloc — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**vmalloc** 分配虚拟连续（物理可能离散）的大块内存。__get_vm_area_node 分配 VA，__vmalloc_area_node 逐页 alloc_page + map_vm_area。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
