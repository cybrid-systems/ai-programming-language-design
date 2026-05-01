# 62-UDP — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**UDP** 无连接传输层。udp_sendmsg→ip_make_skb→udp_send_skb 发送，udp_rcv→__udp4_lib_lookup_skb→udp_queue_rcv_skb 接收。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
