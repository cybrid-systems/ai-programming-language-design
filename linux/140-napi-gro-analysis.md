# 140-netif-receive-skb — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**netif_receive_skb** 是网络接收的核心函数：从驱动接收 skb → 传递到上层协议处理（ip_rcv / arp_rcv / bridge 等）。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
