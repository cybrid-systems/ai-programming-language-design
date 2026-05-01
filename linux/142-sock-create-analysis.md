# 142-skb-shared-info — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**skb_shared_info** 管理 sk_buff 的非线性数据区域（碎片页、GSO 分段信息）。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
