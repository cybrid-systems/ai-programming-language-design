# 22-sk_buff — Socket Buffer 套接字缓冲区深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/skbuff.h` + `net/core/skbuff.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**sk_buff（socket buffer）** 是 Linux 网络协议栈的核心数据结构，贯穿从网卡到用户空间的数据包。

---

## 1. 核心数据结构

### 1.1 struct sk_buff — 套接字缓冲区

```c
// include/linux/skbuff.h:82 — sk_buff
struct sk_buff {
    // 链表（用于 frag 列表等）
    struct sk_buff          *next;        // 下一个 skb（用于链表）
    struct sk_buff          *prev;        // 上一个 skb

    // 套接字关联
    struct sock             *sk;          // 所属 socket

    // 网络层头
    struct sk_buff_head     *list;        // 所属链表
    unsigned int            len;           // 总长度（包含数据）
    unsigned int            data_len;     // 数据长度（不包括线性区）
    __u16                   mac_len;     // MAC 头长度
    __u16                   hdr_len;     // 可被克隆的头部长度

    // 偏移
    skb_frag_t            *frag_list;    // frag 链表（线性区外的页）
    struct page            *page;          // 数据页（用于 frag）
    unsigned int            page_offset;   // 页内偏移
    unsigned int            truesize;      // 总大小（含 sk_buff 本身）

    // 协议头指针
    unsigned char           *head;         // 缓冲起始
    unsigned char           *end;          // 缓冲结束
    unsigned char           *data;         // 数据起始（当前）
    unsigned char           *tail;         // 数据结束（当前）

    // 校验
    __u32                   csum;         // 校验和
    __u16                   csum_start;   // 校验起始偏移
    __u16                   csum_offset;  // 校验偏移

    // 网络层头（通过 skb_mac_header 访问）
    unsigned char           *mac_header;    // MAC 头位置
    unsigned char           *network_header; // 网络层头位置
    unsigned char           *transport_header; // 传输层头位置

    // 输出队列
    struct sk_buff          *destructor;   // 析构函数
};
```

---

## 2. 内存布局

```
sk_buff 线性数据区布局：

head     ────── skb->head（缓冲起始）
           ├─ MAC 头（mac_header）
data     ────── skb->data（当前数据起始）
           ├─ 网络层头（network_header，如 IP 头）
           ├─ 传输层头（transport_header，如 TCP 头）
tail     ────── skb->tail（当前数据结束）
end      ────── skb->end（缓冲结束）

实际数据包：
[ ETH | IP | TCP | DATA ]    ← 线性区

如果数据很大（超过 MTU）：
skb->frag_list → 指向额外的 skb（线性区外的页）
```

---

## 3. 核心操作

### 3.1 skb_put — 尾部扩展

```c
// include/linux/skbuff.h — skb_put
static inline void *skb_put(struct sk_buff *skb, unsigned int len)
{
    void *tmp = skb->tail;    // 旧 tail
    skb->tail += len;         // 新 tail
    skb->len += len;          // 更新长度
    return tmp;               // 返回旧 tail（即新数据起始位置
}

// skb_push — 头部扩展（在 data 前插入）
static inline void *skb_push(struct sk_buff *skb, unsigned int len)
{
    skb->data -= len;
    skb->len += len;
    return skb->data;
}

// skb_pull — 头部收缩（移除头部）
static inline void *skb_pull(struct sk_buff *skb, unsigned int len)
{
    skb->len -= len;
    skb->data += len;
    return skb->data;
}
```

### 3.2 skb_reserve — 保留头部空间

```c
// include/linux/skbuff.h — skb_reserve
static inline void skb_reserve(struct sk_buff *skb, int len)
{
    skb->data += len;   // data 前移，为协议头腾出空间
    skb->tail += len;   // tail 也前移
}
```

---

## 4. 数据包接收流程

### 4.1 netif_receive_skb — 接收数据包

```c
// net/core/dev.c — netif_receive_skb
int netif_receive_skb(struct sk_buff *skb)
{
    struct packet_type *ptype;
    int ret = NET_RX_SUCCESS;

    // 1. 检查是否混杂模式
    if (skb->dev->flags & IFF_PROMISC)
        skb->pkt_type = PACKET_OTHERHOST;

    // 2. 分配 vlan_tag
    if (vlan_tx_tag_present(skb))
        __vlan_hwaccel_put_tag(skb);

    // 3. 分发到协议层
    list_for_each_entry_rcu(ptype, &ptype_all, list) {
        if (ptype->dev == skb->dev ||
            ptype->dev == dev_get_by_index(&init_net, skb->dev->ifindex)) {
            if (ptype->func(skb, skb->dev, pt_prev) == NET_RX_DROP)
                ret = NET_RX_DROP;
        }
    }

    return ret;
}
```

---

## 5. TCP 发送流程

```c
// net/ipv4/tcp_output.c — tcp_sendmsg
int tcp_sendmsg(struct sock *sk, struct msghdr *msg, size_t size)
{
    // 1. 分配 skb
    struct sk_buff *skb = alloc_skb(size + tcp_header_size, sk->sk_allocation);

    // 2. 填充 TCP 头
    th = tcp_hdr(skb);
    th->source = htons(sk->sk_sport);
    th->dest = htons(peer_port);
    th->seq = htonl(sk->sk_write_seq);
    th->ack_seq = htonl(sk->rcv_nxt);

    // 3. 复制数据
    copy_from_iter(skb_put(skb, copy), copy, &msg->msg_iter);

    // 4. 发送
    tcp_push(skb);
}
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/skbuff.h` | `struct sk_buff` |
| `include/linux/skbuff.h` | `skb_put`、`skb_push`、`skb_pull`、`skb_reserve` |
| `net/core/dev.c` | `netif_receive_skb` |

---

## 7. 西游记类比

**sk_buff** 就像"取经路上的快递包裹"——

> 包裹（sk_buff）有自己的包装区（head~end），里面有货物（data~tail）和各种标签（MAC头、IP头、TCP头）。每过一个驿站（协议层），就会在头部加一个新的标签（skb_push）。拆掉标签看内容（skb_pull）。如果货物太大，就用额外的袋子装（skb->frag_list）。快递公司（网卡驱动）负责收货（netif_receive_skb），把包裹贴上标签（MAC 头），然后根据标签送到各个部门（IP层、TCP层）。

---

## 8. 关联文章

- **netfilter**（article 28）：sk_buff 在 netfilter hook 中的修改
- **socket**（网络部分）：sk_buff 与 socket 的关联