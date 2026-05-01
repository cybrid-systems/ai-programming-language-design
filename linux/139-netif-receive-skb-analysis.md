# 139-dev-queue-xmit — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**dev_queue_xmit** 是网络发送的核心函数：选择队列 → enqueue → 调用 qdisc → 驱动 ndo_start_xmit。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
