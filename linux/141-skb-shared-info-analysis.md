# 141-skb_shared_info — 分散-聚集与GSO深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/skbuff.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**skb_shared_info** 是 sk_buff 的扩展，存储分散-聚集（SG）列表、GSO（Generic Segmentation Offload）信息和 frags（页片段）。当数据包线性区放不下时，用 frag_list 或 frags 存储额外数据。

---

## 1. 核心数据结构

### 1.1 struct skb_shared_info — skb 扩展

```c
// include/linux/skbuff.h — skb_shared_info
struct skb_shared_info {
    // 分散-聚集
    unsigned char           nr_frags;          // 页片段数量（MAX_SKB_FRAGS=16）
    __skb_frag_t           frags[MAX_SKB_FRAGS]; // 页片段数组

    // frag_list（用于 GSO、隧道等）
    struct sk_buff        *frag_list;         // 片段链表（用于分段）

    // GSO（分片卸载）
    struct {
        __u32           features;              // GSO 特性（NETIF_F_*）
        __u16           gso_size;             // GSO 分片大小（不含头）
        __u16           gso_segs;             // GSO 段数
        __u16           gso_type;             // GSO 类型
    };

    // 引用计数
    atomic_t              dataref;             // 数据引用计数

    // PHYLINK
    unsigned short        gso_type __attribute__((aligned(4)));
    unsigned short        gso_size __attribute__((aligned(4)));
};
```

### 1.2 __skb_frag_t — 页片段

```c
// include/linux/skbuff.h — __skb_frag_t
typedef struct {
    struct page            *page;             // 数据页
    unsigned int            page_offset;       // 页内偏移
    unsigned int            size;              // 片段大小
} __skb_frag_t;
```

---

## 2. 线性区 vs 非线性区

```
skb 内存布局：

线性区（skb->data ~ skb->tail）：
  [MAC头][IP头][TCP头][应用数据...]

非线性区（frags + frag_list）：
  frags[]：直接引用物理页（零拷贝）
    frags[0] → page(page_offset=0, size=4096)
    frags[1] → page(page_offset=0, size=2048)

  frag_list：指向额外的 skb（用于隧道、GSO）
    frag_list → skb(segment_1) → skb(segment_2) → ... → skb(segment_N)

head     ────── skb->head
data     ────── skb->data（当前数据开始）
           ├─ skb->transport_header
tail     ────── skb->tail（当前数据结束）
end      ────── skb->end

frags    ────── frags[0..nr_frags-1]（物理页片段）
frag_list ────── skb_frag_list（分段链表）
```

---

## 3. GSO（Generic Segmentation Offload）

### 3.1 GSO 类型

```c
// include/linux/netdev_features.h — GSO 类型
#define SKB_GSO_TCPV4        0x1   // TCPv4 分片
#define SKB_GSO_UDP           0x2   // UDP 分片（如 VXLAN 隧道）
#define SKB_GSO_FRAGLIST      0x4   // frag_list GSO
#define SKB_GSO_TCPV6         0x8   // TCPv6 分片
#define SKB_GSO_ESP           0x10  // ESP 分片
#define SKB_GSO_TCP_FRAMER    0x20  // TCP 分片器
#define SKB_GSO_FRAGLIST_VALID_CHECKSUM  0x40 // frag_list +校验和
```

### 3.2 gso_size — GSO 分片大小

```c
// gso_size 示例：
// TCP over eth0（MTU=1500）：
//   gso_size = 1460（TCP payload 最大值）
//   一个 64KB 的 TCP segment 会自动在发送时分片成多个小包

// UDP over VXLAN：
//   gso_size = VXLAN payload 最大值
//   一个大的 UDP 包在物理网卡上被分成多个小包
```

### 3.3 skb_gso_segment — GSO 分段

```c
// net/core/dev.c — skb_gso_segment
struct sk_buff *skb_gso_segment(struct sk_buff *skb, netdev_features_t features)
{
    // 1. 检查 GSO 特性
    features &= skb->skb_iif ? NETIF_F_GEN_CSUM : NETIF_F_ALL_CSUM;

    // 2. 根据 gso_type 调用对应分片函数
    if (skb_shinfo(skb)->gso_type & SKB_GSO_TCPV4)
        return tcpv4_gso_segment(skb, features);
    if (skb_shinfo(skb)->gso_type & SKB_GSO_UDP)
        return udp4_ufo_fragment(skb, features);
    if (skb_shinfo(skb)->gso_type & SKB_GSO_FRAGLIST)
        return skb_gso_segment_check(skb, features);
}
```

---

## 4. UDP Fragmentation Offload (UFO)

### 4.1 udp4_ufo_fragment

```c
// net/ipv4/udp_offload.c — udp4_ufo_fragment
struct sk_buff *udp4_ufo_fragment(struct sk_buff *skb, netdev_features_t features)
{
    struct udphdr *uh;
    unsigned int mtu;
    struct iphdr *iph;

    // 1. 计算 MTU
    mtu = ip_skb_dst_mtu(skb);

    // 2. 创建第一个分片
    struct sk_buff *seg = skb_copy(skb, GFP_ATOMIC);

    // 3. 设置 IP 头（DF 标志，分片偏移）
    iph = ip_hdr(seg);
    iph->frag_off = htons(IP_MF);
    iph->frag_off |= htons(offset >> 3);

    // 4. 调整 UDP 长度
    uh = udp_hdr(seg);
    uh->len = htons(frag_size);

    // 5. 循环创建后续分片
    while (offset < skb->len) {
        // 创建每个 IP 分片
        // ...
    }
}
```

---

## 5. TCP Segmentation Offload (TSO)

### 5.1 tcp4_gso_segment

```c
// net/ipv4/tcp_offload.c — tcp4_gso_segment
struct sk_buff *tcp4_gso_segment(struct sk_buff *skb, netdev_features_t features)
{
    struct tcphdr *th;
    unsigned int mtu;
    struct iphdr *iph;

    // MTU = 设备 MTU（通常 1500）
    mtu = skb_shinfo(skb)->gso_size + sizeof(struct tcphdr) + sizeof(struct iphdr);

    // 每个分片：
    //   TCP payload = gso_size（不含头）
    //   总长度 = gso_size + TCP头(20) + IP头(20)

    // 如果 gso_size = 65536（64KB），MTU = 1500：
    //   → 分成 ~45 个分片
}
```

---

## 6. SG（Scatter-Gather）

### 6.1 skb_frag_ref — 增加页片段引用

```c
// include/linux/skbuff.h — skb_frag_ref
static inline void skb_frag_ref(struct sk_buff *skb, int f)
{
    get_page(skb_frag_page(frag));
}
```

### 6.2 frags 的使用场景

```
frags[] 使用场景：
  1. recvmsg() 接收数据时，数据从 socket 直接到用户页（零拷贝）
  2. sendpage() 发送时，数据直接从页发送（零拷贝）
  3. GRO 汇聚后的数据

frag_list 使用场景：
  1. GSO 分片后的段链表
  2. 隧道封装（如 VXLAN，外部 skb 包含内部 skb）
  3. tso_frags_send_page()
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/skbuff.h` | `struct skb_shared_info`、`__skb_frag_t` |
| `net/core/dev.c` | `skb_gso_segment` |
| `net/ipv4/udp_offload.c` | `udp4_ufo_fragment` |
| `net/ipv4/tcp_offload.c` | `tcp4_gso_segment` |

---

## 8. 西游记类比

**skb_shared_info** 就像"取经队伍的分散打包单"——

> 一个大包裹（64KB TCP数据）不可能一次塞进一个快递箱（MTU=1500），所以要把大包裹拆成小包裹分批发货。GSO（分片卸载）就是让驿站（网卡）帮忙拆包，而不是天庭（协议栈）自己拆。拆包的时候，包裹会被分成多个小箱子（gso_segs），每个小箱子有自己独立的头部（TCP/IP头）。skb_shared_info 就是记录这个包裹被拆成了几份、每份有多大的清单。如果有数据是从仓库直接发的（frags[]），就用零拷贝方式——直接引用物理页的片段，不用复制。frag_list 则像一个大箱子套小箱子（隧道场景），外箱是 VXLAN 头，内箱是原始以太网帧。

---

## 9. 关联文章

- **sk_buff**（article 22）：sk_buff 整体结构
- **NAPI/GRO**（article 140）：GRO 使用 frag_list
- **dev_queue_xmit**（article 138）：GSO 在发送时被分段