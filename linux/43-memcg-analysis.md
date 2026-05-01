# 43-memcg — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**Memory Cgroup** 限制 cgroup 的内存使用。try_charge_memcg 检查限制，page_counter_try_charge 计费，超限时回收或 OOM。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
