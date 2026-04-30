# 170-packet_socket — Packet套接字深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/packet/af_packet.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Packet Socket** 允许用户进程直接访问数据链路层（Ethernet），无需经过路由层。用于网络抓包工具（tcpdump）、用户态协议栈、绕过 TCP/UDP 等。

---

## 1. packet socket 类型

```c
// packet socket 类型：

SOCK_DGRAM：
  发送：已去掉 Ethernet 头，只有净荷
  接收：只包含净荷（自动去掉 Ethernet 头）

SOCK_RAW：
  发送：包含完整的 Ethernet 头（手动构造）
  接收：完整的 Ethernet 帧（Ethernet 头 + 净荷）

SOCK_PACKET（已废弃，使用 SOCK_DGRAM）：
  行为类似 SOCK_RAW，但使用老式 bind 接口
```

---

## 2. packet socket 创建

### 2.1 packet_create

```c
// net/packet/af_packet.c — packet_create
int packet_create(struct socket *sock, int protocol)
{
    struct packet_sock *po;

    // 1. 分配 packet_sock
    po = pkt_sock_alloc(sock, sizeof(*po));

    // 2. 设置协议族
    sock->ops = &packet_ops;
    sock_init_data(sock, sk);

    // 3. 初始化 ring buffer
    po->ring = NULL;

    // 4. 注册协议处理
    po->prot_hook.type = proto;  // ETH_P_IP, ETH_P_ARP, etc.
    po->prot_hook.func = packet_rcv;
    dev_add_pack(&po->prot_hook);

    return 0;
}
```

---

## 3. packet_rcv — 接收数据包

### 3.1 packet_rcv

```c
// net/packet/af_packet.c — packet_rcv
static int packet_rcv(struct sk_buff *skb, struct net_device *dev,
                     struct packet_type *pt, struct net_device *orig_dev)
{
    struct packet_sock *po;

    po = container_of(pt, struct packet_sock, prot_hook);

    // 1. 检查 socket 类型是否匹配
    if (po->prot_hook.type != skb->protocol)
        return 0;

    // 2. 检查 bind 的设备
    if (po->ifindex && dev->ifindex != po->ifindex)
        return 0;

    // 3. 推送 skb 到 socket 队列
    skb_set_owner_r(skb, sk);
    skb_queue_tail(&po->rx_queue, skb);

    // 4. 唤醒用户空间 read
    sk->sk_data_ready(sk);

    return 0;
}
```

---

## 4. packet_send — 发送

### 4.1 packet_sendmsg

```c
// net/packet/af_packet.c — packet_sendmsg
int packet_sendmsg(struct socket *sock, struct msghdr *msg, size_t len)
{
    struct packet_sock *po = pkt_sk(sock);

    // 1. 获取目标地址（sockaddr_ll）
    // struct sockaddr_ll {
    //   sa_family_t sll_family;   // AF_PACKET
    //   __be16 sll_protocol;    // ETH_P_*
    //   int sll_ifindex;         // 接口索引
    // };

    // 2. 如果是 SOCK_DGRAM，加上 Ethernet 头
    if (sock->type == SOCK_DGRAM) {
        eth_hdr(skb)->h_proto = po->num;
        dev_hard_header(skb, dev, ETH_P_IP, dest_mac, NULL, skb->len);
    }

    // 3. 发送到设备
    return dev_queue_xmit(skb);
}
```

---

## 5. tpacket_rx_ring — MMAP 零拷贝

```c
// packet_mmap 使用 TPACKET_V3 ring buffer
// 和 packet_mmap (article 111) 的环缓冲区共享
// 用户空间 mmap 到 ring 后，直接读写环形缓冲区
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/packet/af_packet.c` | `packet_create`、`packet_rcv`、`packet_sendmsg` |

---

## 7. 西游记类喻

**Packet Socket** 就像"天庭的物流监控站"——

> Packet Socket 像在物流公司的货车上装了摄像头（tcpdump），可以实时看到所有经过的货物（Ethernet 帧）。SOCK_RAW 像看完整的货车记录（包含车牌号、货物标签、实际货物），SOCK_DGRAM 像只看货物本身（已去掉车牌号和标签）。直接访问数据链路层的好处是可以看到所有东西，坏处是所有东西都要自己处理。

---

## 8. 关联文章

- **packet_mmap**（article 111）：TPACKET_V3 高性能抓包
- **netif_receive_skb**（article 139）：packet_rcv 的上游函数