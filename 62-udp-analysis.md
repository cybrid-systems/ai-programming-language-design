# Linux Kernel UDP / RAW Socket 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/udp.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. UDP 核心特点

**UDP（User Datagram Protocol）** 是无连接、不可靠的传输协议：
- 无握手，直接发送
- 不保证顺序和可靠到达
- 无拥塞控制（除非使用 reno/cubic）

---

## 1. 核心数据结构

```c
// include/net/udp.h — udp_sock
struct udp_sock {
    struct sock           sk;           // 继承 sock
    __u16               encap_type;    // 封装类型（0 = 普通 UDP）
    __u16               no_check6_tx;  // 不校验 IPv6
    struct udp_hslot     *socket2;     // UDP 哈希表槽

    /* 隧道 */
    int (*encap_rcv)(struct sock *sk, struct sk_buff *skb);  // VXLAN/GRE 封装
};

// net/ipv4/udp.c — udp_table
struct udp_table {
    struct udp_hslot     *hash;         // 哈希表（IPv4）
    struct udp_hslot     *hash2;        // 二次哈希（sport）
    int                  mask;          // 哈希掩码
    int                  log;           // log2(mask+1)
};
```

---

## 2. UDP 发送

```c
// net/ipv4/udp.c — udp_sendmsg
int udp_sendmsg(struct sock *sk, struct msghdr *msg, size_t len)
{
    // 1. 查找路由
    fl4 = &inet->cork.fl.u.ip4;
    err = ip_route_output_flow(net, fl4, sk);

    // 2. 分配 skb
    skb = sock_alloc_send_skb(sk, ulen, ...);

    // 3. 填充 UDP 头
    struct udphdr *uh = udp_hdr(skb);
    uh->source = inet->inet_sport;
    uh->dest = udp_sk(sk)->corkbase.hottail;
    uh->len = htons(len);
    uh->check = 0;  // IPv4 可选校验

    // 4. 发送
    err = ip_send_skb(net, skb);
}
```

---

## 3. UDP 接收

```c
// net/ipv4/udp.c — udp_rcv
int udp_rcv(struct sk_buff *skb)
{
    // 1. 查找 socket
    //    哈希 (sport, dport) → udp_table
    struct sock *sk = __udp4_lib_lookup(net, saddr, sport,
                          daddr, dport, udptable);

    // 2. 封装处理（VXLAN 等）
    if (UP_ENCAP(sk))
        skb = sk->sk_prot->encap_rcv(sk, skb);

    // 3. 接收队列
    sk_receive_skb(sk, skb);
}
```

---

## 4. RAW Socket

```c
// net/ipv4/raw.c — raw_sendmsg / raw_rcv
// RAW socket 直接发送 IP 层数据，跳过传输层
// 常用于 ping、traceroute、OSPF、IGMP

// 创建：
int fd = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
```

---

## 5. 参考

| 文件 | 内容 |
|------|------|
| `net/ipv4/udp.c` | `udp_sendmsg`、`udp_rcv`、`__udp4_lib_lookup` |
| `include/net/udp.h` | `struct udp_sock` |
