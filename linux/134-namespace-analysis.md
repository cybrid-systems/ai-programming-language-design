# 134-percpu — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**percpu** 变量是每 CPU 数据，避免同步开销。使用 `DEFINE_PER_CPU` 和 `this_cpu_ptr()` 访问。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
