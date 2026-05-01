# 44-swap — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**swap** 换出不活跃匿名页到磁盘。shrink_list→swap_writepage 分配 swap slot 写磁盘，缺页时 do_swap_page 读回。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
