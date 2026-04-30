# 169-raw_socket — 原始套接字深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/raw.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Raw Socket** 允许用户进程直接构造和发送 IP 数据包，跳过传输层（TCP/UDP）。用于 ping、traceroute、OSPF、BGP、VPN 等协议实现。

---

## 1. raw_socket 创建

### 1.1 raw_create

```c
// net/ipv4/raw.c — raw_create
int raw_create(struct net *net, struct socket *sock, int protocol, kern)
{
    struct raw_sock *rs;

    // 分配 raw_sock
    rs = inet_sk_alloc(net, &raw_sock_prot, GFP_KERNEL);
    if (!rs)
        return -ENOMEM;

    // 设置协议
    rs->sk.sk_protocol = protocol;

    // 绑定协议处理
    rs->prot = raw_prot;
    rs->no_check = 0;

    return 0;
}
```

---

## 2. raw 接收

### 2.1 raw_rcv

```c
// net/ipv4/raw.c — raw_rcv
int raw_rcv(struct sock *sk, struct sk_buff *skb)
{
    // 1. 跳过 IP 头部
    skb_pull(skb, ip_hdrlen(skb));

    // 2. 验证校验和
    if (sk->sk_filter) {
        if (sk_filter_run(sk->sk_filter, skb) == 0)
            goto drop;
    }

    // 3. 发送到用户空间
    return sock_queue_rcv_skb(sk, skb);
}
```

---

## 3. ICMP 实现（使用 raw socket）

```c
// net/ipv4/icmp.c — ICMP 使用 raw socket
// ICMP 协议使用 IPPROTO_ICMP = 1
// 发送：raw_sendmsg → ip_build_xmit
// 接收：icmp_rcv → raw_rcv

// 用户空间使用：
fd = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
sendto(fd, &packet, sizeof(packet), 0, &dest, sizeof(dest));
```

---

## 4. ping 实现

```c
// net/ipv4/ping.c — ping 使用 raw
// ping 使用 ICMP ECHO REQUEST / REPLY
// socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP) 或
// socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/raw.c` | `raw_create`、`raw_rcv` |
| `net/ipv4/icmp.c` | `icmp_rcv`、`icmp_send` |

---

## 6. 西游记类喻

**Raw Socket** 就像"天庭的快递公司直营"——

> 普通 UDP socket 像通过驿站寄快递，快递公司帮你装信封、写地址。Raw socket 像自己买信封、自己写地址，直接把东西送到驿站发货。如果你想寄一个特殊的包裹（自定义 IP 选项、路由追踪），就要用 Raw socket，直接控制 IP 层。

---

## 7. 关联文章

- **udp_sendmsg**（article 145）：UDP socket
- **netif_receive_skb**（article 139）：raw socket 收到的数据包来源