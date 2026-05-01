# 132-kmemleak — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**kmemleak** 是内核内存泄漏检测器，周期性扫描分配的内存，报告无法通过指针追踪的对象。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
