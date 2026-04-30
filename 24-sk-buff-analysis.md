# Linux Kernel sk_buff (Socket Buffer) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/skbuff.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 sk_buff？

**`sk_buff`**（socket buffer）是 Linux 网络子系统的**网络包描述符**——每个收发的数据包都用一个 skb 表示，包含包头指针、数据指针、校验和等信息。

**核心设计目标**：
- 包头可以在不复制数据的情况下替换（线性化操作）
- 多个 skb 可以组成**fragments 链表**（scatter-gather I/O）
- headroom / tailroom 允许在包前后扩展头
- zero-copy 操作支持（避免数据复制）

---

## 1. 核心数据结构

```c
// include/linux/skbuff.h:885 — sk_buff
struct sk_buff {
    /* 链表 */
    struct sk_buff        *next;          // 下一个 skb（用于链表）
    struct sk_buff        *prev;

    /* 时间戳 */
    ktime_t                tstamp;         // 包到达/发送时间

    /* 网络设备 */
    struct net_device     *dev;           // 收发该包的设备
    struct sec_path       *sp;            // 安全路径（IPsec）

    /* 协议层信息 */
    unsigned int          len;             // 包总长度（包含 frag）
    unsigned int          data_len;        // frag 数据长度
    __u16                 mac_len;         // MAC 头长度
    __u16                 hdr_len;         // 可克隆的头长度

    /* 优先级 */
    __u8                  priority;         // QoS 优先级

    /* 校验和 */
    __u8                  csum_not_inet:1; // CRC 需要软件计算
    __u8                  csum_valid:1;
    __u8                  ip_summed:2;    // CHECKSUM_NONE/UNNECESSARY/COMPUTE/PARTIAL

    /* 分片相关 */
    __u8                  encapsulation:1;
    __u8                  encap_hdr_csum:1;
    __u8                  csum_status:3;
    struct skb_frag_ref   frag_list;
    struct sk_buff        *frag_list_next;

    /* 主要数据区域（重要！）*/
    unsigned char         *head;           // 分配空间的起始
    unsigned char         *data;           // 当前数据的起始
    unsigned char         *tail;           // 当前数据的结束
    unsigned char         *end;            // 分配空间的结束

    /* 传输层头 */
    __u16                 transport_header;
    /* 网络层头 */
    __u16                 network_header;
    /* 链路层头 */
    __u16                 mac_header;

    /* 协议头快速解析 */
    struct sk_buff        *inner_skb;
    struct {
        __be16            source;
        __be16            dest;
    } THL_OFFSET;

    /* 内容管理 */
    union {
        __u32            mark;
        __u32            dropped;
        __u32            reserved_tailroom;
    };

    /* TCP 特定信息 */
    struct tcp_skb_cb      *tcp_skb_cb;    // TCP 控制块
    unsigned int           csum_start;     // 校验和起始偏移
    unsigned short         csum_offset;    // 校验和偏移

    /* XDP（Express Data Path） */
    struct page_frag      *frag_page;
    void                  (*destructor)(struct sk_buff *skb);

    /* 引用计数（clone 时使用）*/
    refcount_t            users_ref;       // skb_get() / kfree_skb()
};
```

---

## 2. headroom / tailroom 布局

```
skb->head                              skb->end
       │                                     │
       ▼                                     ▼
┌──────────────────────────────────────────────────────┐
│ [headroom]    │  skb->data   │       │ [tailroom] │
│               │               │       │             │
│ 预留空间      │  包数据       │       │ 预留空间    │
│ (L2/L3/L4 头)│  payload     │       │             │
└──────────────────────────────────────────────────────┘
                ▲              ▲
                │              │
           skb->tail       skb->end
```

**关键操作**：

```c
// 扩展头部（L2/L3/L4 头）
skb_push(skb, add_len)   // skb->data -= add_len, skb->len += add_len
skb_pull(skb, del_len)   // skb->data += del_len, skb->len -= del_len

// 扩展尾部
skb_put(skb, add_len)    // skb->tail += add_len, skb->len += add_len
skb_trim(skb, len)       // skb->tail = skb->data + len

// 预留空间
skb_reserve(skb, add_len) // skb->data += add_len（用于接收时对齐）
```

---

## 3. 接收路径：netif_receive_skb

```c
// net/core/dev.c — netif_receive_skb
static int netif_receive_skb_core(struct sk_buff **skb)
{
    // 1. 分发到协议层
    __netif_receive_skb(skb);

    // 2. 遍历每个 packet_type：
    //    - ip_packet_type（IPv4）
    //    - ipv6_packet_type（IPv6）
    //    - arp_packet_type
    //    - ip_rcv() → ip_rcv_core()
    //    - tcp_v4_rcv() → tcp_rcv_established()
    //    - ...

    // 3. 如果是 VLAN：__vlan_hwaccel_push_inside()
}

// ETH 头解析
struct ethhdr *eth = eth_hdr(skb);    // = skb->mac_header + ETH_HLEN
```

---

## 4. 发送路径：dev_queue_xmit

```c
// net/core/dev.c — dev_queue_xmit
int dev_queue_xmit(struct sk_buff *skb)
{
    struct net_device *dev = skb->dev;
    struct netdev_queue *txq;

    // 1. 获取传输队列
    txq = netdev_pick_tx(dev, skb);

    // 2. 放入队列
    if (__netdev_tx_sent_queue(txq, skb->len, ...)) {
        // 队列已满，调用 qdisc->enqueue()
        dev->qdisc->enqueue(skb, qdisc, &to_free);
        return 0;
    }

    // 3. 硬件发送
    if (!netif_tx_queue_stopped(txq))
        dev->netdev_ops->ndo_start_xmit(skb, dev);
}
```

---

## 5. skb_clone — 零复制克隆

```c
// net/core/skbuff.c — skb_clone
struct sk_buff *skb_clone(struct sk_buff *skb, gfp_t gfp_mask)
{
    struct sk_buff *nskb;

    // 分配新的 skb（共享 data 区域）
    nskb = kmem_cache_alloc(skbuff_head_cache, gfp_mask);

    // 复制 skb 头（但不复制数据）
    memcpy(nskb, skb, offsetof(struct sk_buff, tail));

    // 共享数据区（不复制）
    nskb->head = skb->head;
    nskb->data = skb->data;
    nskb->tail = skb->tail;
    nskb->end = skb->end;
    nskb->len = skb->len;
    nskb->data_len = skb->data_len;

    // 引用计数 +1
    refcount_set(&nskb->users_ref, 1);

    return nskb;
}

// skb_share_check — 共享 skb，如果是共享的需要 clone
struct sk_buff *skb_share_check(struct sk_buff *skb, gfp_t gfp)
{
    if (refcount_read(&skb->users_ref) > 1) {
        // 正在被多个使用者共享，需要 clone
        struct sk_buff *nskb = skb_clone(skb, gfp);
        kfree_skb(skb);  // 释放原 skb
        return nskb;
    }
    // 唯一使用者，直接使用
    return skb;
}
```

---

## 6. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| headroom/tailroom | 允许在包前后扩展头，避免数据复制 |
| skb_push/pull/put | 线性化操作，不复制数据，只移动指针 |
| head/data/tail/end 四指针 | 精确控制数据区域，避免边界溢出 |
| frag_list | scatter-gather：支持超过 MTU 的包 |
| skb_clone vs skb_copy | clone 零复制（共享数据），copy 完整复制 |
| users_ref 引用计数 | 同一 skb 被多个路径使用时安全释放 |

---

## 7. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/skbuff.h:885` | `struct sk_buff` 完整定义 |
| `net/core/skbuff.c` | `skb_clone`、`skb_push`、`skb_put`、`skb_share_check` |
| `net/core/dev.c` | `netif_receive_skb`、`dev_queue_xmit` |
