# 144-inet-stream-connect — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**TCP 连接建立**：connect 系统调用 → tcp_v4_connect → tcp_transmit_skb(SYN) → 三次握手全过程。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
