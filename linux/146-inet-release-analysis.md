# 146-udp-send-recv — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**UDP 发送/接收**：udp_sendmsg → ip_append_data → 发送；接收端 udp_rcv → __udp4_lib_lookup_skb → 放入接收队列。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
