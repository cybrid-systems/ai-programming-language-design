# UDP — 用户数据报协议深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/udp.c` + `net/ipv6/udp.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**UDP** 是无连接的传输层协议，提供简单的"发送数据报"服务，不保证可靠性。

---

## 1. 核心数据结构

### 1.1 udp_sock — UDP socket

```c
// include/net/udp.h — udp_sock
struct udp_sock {
    struct inet_sock        inet;          // 基类（IP 层）
    __u16                   udp_data_offset; // UDP 数据偏移
    __u16                   no_check6_tx;   // 6to4 校验和
    __u16                   encap_enable;   // 封装启用（GTP/TLS）
    __u16                  _port_rover;    // 端口漫游
    struct sk_buff_head     reader_queue;    // 读取队列

    // 隧道封装
    int                     (*encap_rcv)(struct sock *sk, struct sk_buff *skb);
};

#define UDP_HTABLE_SIZE_MIN         32
```

### 1.2 udp_hslot — UDP 端口哈希槽

```c
// include/net/udp.h — udp_hslot
struct udp_hslot {
    struct hlist_nulls_head head;          // 链表头（nulls 标记）
    spinlock_t             lock;           // 保护
    int                     count;          // 槽中 socket 数
};
```

---

## 2. sendmsg — 发送 UDP 数据报

### 2.1 udp_sendmsg

```c
// net/ipv4/udp.c — udp_sendmsg
int udp_sendmsg(struct sock *sk, struct msghdr *msg, size_t len)
{
    struct inet_sock *inet = inet_sk(sk);
    struct udp_sock *up = udp_sk(sk);
    struct udphdr *uh;
    struct ipcm_cookie ipc;
    struct rtable *rt;
    u32 daddr, saddr;
    u16 dport, sport;
    int connected = 0;
    int ulen;

    // 1. 获取目标地址
    if (msg->msg_name) {
        struct sockaddr_in *sin = msg->msg_name;
        daddr = sin->sin_addr.s_addr;
        dport = sin->sin_port;
    } else {
        daddr = inet->inet_daddr;
        dport = inet->inet_dport;
        connected = 1;
    }

    // 2. 查找路由
    if (!connected) {
        rt = ip_route_output_flow(sock_net(sk), &fl4, sk);
        if (IS_ERR(rt))
            return PTR_ERR(rt);
    }

    // 3. 构建 UDP 头
    ulen = sizeof(struct udphdr) + len;
    skb = alloc_skb(ulen + LL_ALLOCATED_SPACE(rt->dst.dev), sk->sk_allocation);
    uh = udp_hdr(skb);
    uh->source = inet->inet_sport;
    uh->dest = dport;
    uh->len = htons(ulen);
    uh->check = 0;  // 0 = 不校验

    // 4. 复制数据
    err = memcpy_from_msg(data, msg, len);

    // 5. 设置 IP 选项
    ipc.opt = ipc_opts(sk);
    ipc.sockc.tsflags = sk->sk_tsflags;

    // 6. 发送（IP 层）
    err = ip_send_skb(sock_net(sk), skb);
    if (err)
        return err;

    return len;
}
```

---

## 3. recvmsg — 接收 UDP 数据报

### 3.1 udp_recvmsg

```c
// net/ipv4/udp.c — udp_recvmsg
int udp_recvmsg(struct sock *sk, struct msghdr *msg, size_t len, int flags)
{
    struct sk_buff *skb;
    unsigned int ulen, copied;
    int peeked;

    // 1. 从 socket 队列获取 skb
    skb = __skb_recv_udp(sk, flags, &peeked, &off);
    if (!skb)
        return -EAGAIN;

    // 2. 校验
    ulen = udp_skb_len(skb);
    if (ulen > len) {
        msg->msg_flags |= MSG_TRUNC;
        ulen = len;
    }

    // 3. 复制数据到用户空间
    copied = ulen;
    if (copied < ulen)
        msg->msg_flags |= MSG_TRUNC;

    err = skb_copy_datagram_msg(skb, sizeof(struct udphdr), msg, copied);

    // 4. 填充发送者地址
    if (msg->msg_name) {
        struct sockaddr_in *sin = msg->msg_name;
        sin->sin_family = AF_INET;
        sin->sin_port = udp_hdr(skb)->source;
        sin->sin_addr.s_addr = ip_hdr(skb)->saddr;
        msg->msg_namelen = sizeof(*sin);
    }

    // 5. 消费或偷看（peek）
    if (flags & MSG_PEEK)
        return copied;

    // 消费
    skb_consume_udp(sk, ulen);
    return copied;
}
```

---

## 4. udp_lib_lookup — 端口查找

```c
// net/ipv4/udp.c — udp_lib_lookup
struct sock *udp_lib_lookup(struct net *net, __be32 saddr, __be16 sport,
                            __be32 daddr, __be16 dport, int dif)
{
    struct sock *sk;
    struct udp_hslot *hslot;
    int score;

    // 1. 按目的端口哈希
    hslot = &udp_table.hash[dport % UDP_HTABLE_SIZE];

    // 2. 遍历链表
    sk_nulls_for_each_rcu(sk, node, &hslot->head) {
        score = match(sk, saddr, sport, daddr, dport, dif);
        if (score > best)
            best = sk;
    }

    return sk;
}
```

---

## 5. 完整文件索引

| 文件 | 函数 |
|------|------|
| `net/ipv4/udp.c` | `udp_sendmsg`、`udp_recvmsg`、`udp_lib_lookup` |
| `net/ipv6/udp.c` | IPv6 UDP 实现 |
| `include/net/udp.h` | `struct udp_sock`、`struct udp_hslot` |