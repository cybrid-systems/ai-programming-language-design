# 145-tcp-send-recv — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**TCP 发送/接收**：tcp_sendmsg（写 socket 缓冲）→ tcp_push → tcp_transmit_skb → 接收端 tcp_v4_rcv → tcp_rcv_established。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
