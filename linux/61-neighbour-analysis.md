# 61-neighbour — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**neighbour** 管理 ARP/NDP 缓存（IP↔MAC）。neigh_lookup 哈希查找，neigh_resolve_output 未知时发 ARP 请求。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
