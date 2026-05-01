# 136-memory-compaction — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**memory compaction** 整理物理内存碎片，通过迁移可移动页面来创建大块连续内存（THP 分配的准备步骤）。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
