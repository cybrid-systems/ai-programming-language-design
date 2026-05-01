# 62-UDP — 用户数据报协议深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

UDP 传输层协议实现，位于 `net/ipv4/udp.c`。无连接、不可靠、无拥塞控制。

---

## 1. 核心调用链

```
发送端：udp_sendmsg(sk, msg, len)
  └─ ip_make_skb(sk, fl4, ...)        ← 构造 skb
       └─ udp_send_skb(skb, fl4)       ← 发送
            └─ ip_local_out(net, sk, skb)

接收端：udp_rcv(skb)
  └─ __udp4_lib_lookup_skb(skb, ...)  ← 根据 port/IP 查找 socket
  └─ udp_queue_rcv_skb(sk, skb)       ← 放入 socket 接收队列
       └─ skb_queue_tail(&sk->sk_receive_queue, skb)
       └─ sk->sk_data_ready(sk)        ← 通知进程
```

---

*分析工具：doom-lsp（clangd LSP）*
