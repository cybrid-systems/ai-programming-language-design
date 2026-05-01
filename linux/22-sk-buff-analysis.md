# 22-skbuff — Linux 内核网络缓冲区深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**sk_buff（Socket Kernel Buffer）** 是 Linux 内核网络子系统中最重要的数据结构。每个网络数据包在协议栈的处理过程中都封装在一个 `sk_buff` 中——从网卡驱动通过 NAPI 接收，经 GRO 合并，到 IP/TCP/UDP 协议层处理，再到 socket 接收队列。

`sk_buff` 的设计核心是**头部/尾部预留**机制：处理过程中，各协议层通过 `skb_push`（在数据前添加头部）和 `skb_put`（在数据后添加数据）在不同协议层间传递数据包，而无需复制数据包内容。

**doom-lsp 确认**：`include/linux/skbuff.h` 包含 **852 个符号**，5467 行——这是内核最大的头文件之一。

---

## 1. 核心数据结构

### 1.1 `struct sk_buff` 内存布局

```
分配的 sk_buff 内存布局（data 指针移动演示）：

初始（分配后）：
  ┌──────────────────────────────────────────────────────┐
  │ headroom                      │   data 区域           │  tailroom
  │ (预留空间)                     │   (当前数据包)        │  (预留空间)
  └──────────────────────────────────────────────────────┘
  ↑                              ↑                       ↑
  head                           data                    tail  end

skb_reserve(headroom) 后（为各层协议头预留空间）：
  ┌─────────────┬────────────────────────────────────────┐
  │  headroom   │                                        │  tailroom
  │ (L2/L3/L4)  │                                        │
  └─────────────┴────────────────────────────────────────┘
                ↑
               data = tail

skb_put(data_len) 后（设备添加数据）：
  ┌─────────────┬─────────────────────┬──────────────────┐
  │  headroom   │  data (packet data)  │  tailroom        │
  └─────────────┴─────────────────────┴──────────────────┘
                ↑                     ↑
               data                 tail

skb_push(eth_hdr_len)（网络栈添加 Ethernet 头部）：
  ┌─────────────┬────────┬────────────┬──────────────────┐
  │  headroom   │ L2 hdr │ data       │  tailroom        │
  └─────────────┴────────┴────────────┴──────────────────┘
                         ↑
                        data（向后移）

skb_pull(eth_hdr_len)（到 IP 层，去掉 L2 头部）：
  ┌─────────────┬────────┬────────────┬──────────────────┐
  │  headroom   │ L2 hdr │ data       │  tailroom        │
  └─────────────┴────────┴────────────┴──────────────────┘
                ↑
               data（向前移，L2 头部被跳过）
```

### 1.2 `struct sk_buff`——定义

```c
// include/linux/skbuff.h — 852 个符号
struct sk_buff {
    // ----- 缓存线 1（数据指针）-----
    struct sk_buff      *next;         // 链表 next
    struct sk_buff      *prev;         // 链表 prev
    struct sock         *sk;           // 关联的 socket

    ktime_t             tstamp;        // 时间戳
    unsigned int        len;           // 数据长度
    unsigned int        data_len;      // 分散/聚集数据长度
    __u16               mac_len;       // MAC 头部长度

    // ----- Buffer 指针 -----
    unsigned char       *head;         // 缓冲区起始
    unsigned char       *data;         // 当前协议数据起点
    unsigned char       *tail;         // 数据结束
    unsigned char       *end;          // 缓冲区结尾

    // ----- 协议元数据 -----
    __u16               protocol;      // 协议（htons(ETH_P_IP)）
    __u32               priority;      // 优先级
    __u8                pkt_type;      // PACKET_HOST / PACKET_BROADCAST ...
    __u8                ip_summed;     // CHECKSUM_NONE / CHECKSUM_UNNECESSARY ...
    __u8                encapsulation; // 封装类型

    // ----- 功能标志 -----
    sk_buff_data_t      transport_header; // L4 头部偏移
    sk_buff_data_t      network_header;   // L3 头部偏移
    sk_buff_data_t      mac_header;       // L2 头部偏移

    struct skb_shared_info *shinfo;   // 共享信息（frags, frag_list, tso_size 等）
    // ...
};
```

### 1.3 `struct skb_shared_info`——数据分担信息

```c
struct skb_shared_info {
    __u8            nr_frags;          // 分散页的数量
    __u8            tx_flags;          // 发送标志
    unsigned short  gso_size;          // GSO 分片大小（MSS）
    unsigned short  gso_segs;          // GSO 分片数量
    struct sk_buff  *frag_list;        // 链表形式的分片
    skb_frag_t      frags[MAX_SKB_FRAGS]; // 分散页数组
    // ...
};
```

---

## 2. 操作函数

### 2.1 skb_put——添加数据到尾

```c
unsigned char *skb_put(struct sk_buff *skb, unsigned int len)
{
    unsigned char *tmp = skb_tail_pointer(skb);
    skb->tail += len;
    skb->len  += len;
    return tmp;
}
```

### 2.2 skb_push——添加头部到前

```c
unsigned char *skb_push(struct sk_buff *skb, unsigned int len)
{
    skb->data -= len;
    skb->len  += len;
    return skb->data;
}
```

### 2.3 skb_pull——移除头部

```c
unsigned char *skb_pull(struct sk_buff *skb, unsigned int len)
{
    skb->len  -= len;
    skb->data += len;
    return skb->data;
}
```

### 2.4 skb_reserve——预留头部空间

```c
void skb_reserve(struct sk_buff *skb, int len)
{
    skb->data += len;
    skb->tail += len;
}
```

### 2.5 skb_clone——轻量复制

```c
struct sk_buff *skb_clone(struct sk_buff *skb, gfp_t gfp_mask)
{
    // 只复制 sk_buff 结构本身（~200 字节），不复制数据
    // 共享同一 data 缓冲区（通过引用计数）
    // shinfo->dataref++
    // 用于在协议栈中多点分发数据包
}
```

### 2.6 pskb_copy——部分复制

```c
struct sk_buff *pskb_copy(struct sk_buff *skb, gfp_t gfp_mask)
{
    // 复制 sk_buff + 重新分配线性数据区域
    // 但不复制分散页（skb_shared_info.frags）
    // 用于修改数据前需确保数据不共享
}
```

---

## 3. 源码文件索引

| 文件 | 内容 |
|------|------|
| `include/linux/skbuff.h` | sk_buff 定义 + inline 函数 |
| `include/linux/skbuff.h` | skb_shared_info |
| `net/core/skbuff.c` | 核心实现 |

---

## 4. 关联文章

- **141-skb-shared-info**：共享信息详解
- **139-netif-receive-skb**：数据包接收路径
- **144-tcp-sendmsg**：TCP 发送中的 skb 操作

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 3. sk_buff 完整字段详解

### 3.1 数据指针（head/data/tail/end）

四个指针定义了 sk_buff 数据缓冲区的边界：

```c
struct sk_buff {
    unsigned char *head;      // 缓冲区起始
    unsigned char *data;      // 当前协议数据起始
    unsigned char *tail;      // 当前协议数据结束
    unsigned char *end;       // 缓冲区结束
};
```

**headroom** = `data - head`：可供 `skb_push` 使用的空间
**tailroom** = `end - tail`：可供 `skb_put` 使用的空间
**data_len** = `skb->len` 中位于分片中的部分（非线形数据）

### 3.2 协议头部偏移

```c
    sk_buff_data_t transport_header;  // L4 头部偏移（TCP/UDP）
    sk_buff_data_t network_header;    // L3 头部偏移（IP/IPv6）
    sk_buff_data_t mac_header;        // L2 头部偏移（Ethernet）
```

通过 `skb_set_network_header(skb, offset)` 等函数设置，配合 `ip_hdr(skb)` / `tcp_hdr(skb)` 等宏使用。

### 3.3 协议信息

```c
    __u16   protocol;       // 帧类型：htons(ETH_P_IP), ETH_P_IPV6
    __u8    pkt_type;       // PACKET_HOST（发往本地）/PACKET_BROADCAST/PACKET_MULTICAST
    __u32   priority;       // 优先级（用于 QoS）
    __u8    ip_summed;       // 校验和状态：
                             // CHECKSUM_NONE：没有计算校验和
                             // CHECKSUM_UNNECESSARY：硬件计算了校验和
                             // CHECKSUM_COMPLETE：硬件验证了校验和
                             // CHECKSUM_PARTIAL：部分校验和（TPO/GSO）
```

---

## 4. Socket 关联

```c
struct sk_buff {
    struct sock     *sk;        // 关联的 socket
    struct net_device *dev;     // 接收/发送的网络设备
};
```

`skb->sk` 在数据包接收路径中由协议层设置（TCP/UDP 查表后关联 socket），发送路径中由 `sendmsg` 系统调用传入。

---

## 5. 控制缓冲区（cb）

```c
struct sk_buff {
    char            cb[48] __aligned(8);  // 控制缓冲区
};
```

`cb[]` 是各协议层的私有存储区，用于在协议栈处理过程中传递上下文。例如 TCP 协议层在 `cb` 中存储序列号等信息，IP 层在 `cb` 中存储路由信息。不同协议层通过宏定义复用此区域。

---

## 6. 克隆和复制

| 函数 | sk_buff | data 缓冲区 | 分片 | 场景 |
|------|---------|------------|------|------|
| `alloc_skb` | 分配 | 分配 | 空 | 新建包 |
| `skb_clone` | 复制 | 共享 | 共享 | 多点分发 |
| `pskb_copy` | 复制 | 复制 | 共享 | 修改线性数据 |
| `skb_copy` | 复制 | 复制 | 复制 | 完全独立副本 |
| `pskb_expand_head` | 扩展 | 扩展head | 共享 | 添加额外头部 |

---

## 7. GSO/TSO/GRO 功能

```c
struct skb_shared_info {
    unsigned short  gso_size;     // GSO 分片大小（MSS 值）
    unsigned short  gso_segs;     // 分片后的总段数
    unsigned int    gso_type;     // GSO 类型（SKB_GSO_TCPV4 等）
};
```

**GSO（Generic Segmentation Offload）**：在协议栈中用大包传输，由网卡或内核分割为 MTU 大小的段。减少协议栈处理次数，提升吞吐量。

**GRO（Generic Receive Offload）**：接收路径的反向操作——将多个小包合并为大包再提交给协议栈。

---

## 8. skb 生命周期

```
1. alloc_skb(len, GFP_ATOMIC)  ← 在中断/NET_RX_SOFTIRQ 中分配
   skb_reserve(skb, headroom)  ← 预留头部空间

2. 网卡驱动调用 skb_put(skb, pkt_len)  ← 添加收到的数据
   写入从硬件 DMA 获取的数据

3. 设置协议头部：
   skb->protocol = eth_type_trans(skb, dev)
   skb_set_network_header(skb, ETH_HLEN)
   skb_set_transport_header(skb, ETH_HLEN + IP_HLEN)

4. netif_receive_skb(skb) → 协议栈处理

5. 协议释放：
   consume_skb(skb) / kfree_skb(skb)
```

---

## 9. 源码文件索引

| 文件 | 关键函数 |
|------|---------|
| `include/linux/skbuff.h` | sk_buff 结构（852 符号）|
| `net/core/skbuff.c` | alloc_skb, skb_clone, skb_copy |

---

## 10. 关联文章

- **141-sk_shared_info**：分片和 GSO 详细
- **139-netif-receive-skb**：数据包接收路径

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 3. sk_buff 完整字段详解

### 3.1 数据指针

```c
struct sk_buff {
    unsigned char *head;      // 缓冲区起始地址
    unsigned char *data;      // 当前协议层数据起始
    unsigned char *tail;      // 当前协议层数据结束
    unsigned char *end;       // 缓冲区结束地址
};
```

headroom = data - head：可供 skb_push 添加协议头
tailroom = end - tail：可供 skb_put 添加数据

### 3.2 协议头偏移

```c
sk_buff_data_t transport_header;  // L4 头偏移
sk_buff_data_t network_header;    // L3 头偏移  
sk_buff_data_t mac_header;        // L2 头偏移
```

通过 skb_set_network_header(skb, offset) 等设置。

### 3.3 校验和信息

```c
__u8 ip_summed;
// CHECKSUM_NONE: 未计算校验和
// CHECKSUM_UNNECESSARY: 硬件已计算
// CHECKSUM_COMPLETE: 硬件已验证
// CHECKSUM_PARTIAL: 部分校验和
```

### 3.4 skb_shared_info

```c
struct skb_shared_info {
    __u8 nr_frags;
    __u8 tx_flags;  
    unsigned short gso_size;     // MSS 分片大小
    unsigned short gso_segs;     // GSO 总段数
    struct sk_buff *frag_list;
    skb_frag_t frags[MAX_SKB_FRAGS];  // 分散页面数组
};
```

---

## 4. 控制缓冲区 (cb)

```c
char cb[48] __aligned(8);  // 各协议层私有存储
```

TCP 在 cb 中存序列号、IP 层存路由、网桥存端口信息。

---

## 5. 主要操作速查

| 函数 | 作用 | 影响 |
|------|------|------|
| alloc_skb(len, gfp) | 分配 skb + 数据缓冲区 | — |
| skb_reserve(skb, len) | 预留头部空间 | data += len |
| skb_put(skb, len) | 在尾部添加数据 | tail += len, len += len |
| skb_push(skb, len) | 在头部添加协议头 | data -= len, len += len |
| skb_pull(skb, len) | 移除协议头 | data += len, len -= len |
| skb_clone(skb, gfp) | 轻量复制（共享数据） | dataref++ |
| pskb_copy(skb, gfp) | 部分复制（重分配线性区） | 复制 headroom |
| skb_copy(skb, gfp) | 完全复制 | 所有数据 |

---

## 6. GSO/GRO

GSO：用大包传，网卡或内核分割为 MTU 小包
GRO：接收时合并小包再提交协议栈
```c
shinfo->gso_size = mss;   // 分片大小
shinfo->gso_segs = segs;  // 段数
```

---

## 7. 关联文章

- **141-skb-shared-info**：分片与 GSO 详细
- **139-netif-receive-skb**：接收路径

---

*分析工具：doom-lsp*

## 8. 网络栈处理举例——TCP 数据包接收

```
1. netif_receive_skb(skb)     → skb 进入协议栈
2. ip_rcv(skb)                → skb_pull(skb, ETH_HLEN) 去掉以太头
   skb_set_network_header(skb, 0)  → L3 层
3. ip_local_deliver(skb)      → 判断目标为本地
4. tcp_v4_rcv(skb)            → skb_set_transport_header(skb, 0) → L4 层
5. tcp_queue_rcv(skb, ...)    → 放入 socket 接收队列
```

整个过程 skb 的 data 指针从缓冲区起始逐步前移，不需要复制数据。

---

## 9. 总结

sk_buff 的设计核心是无复制协议层传递——各层通过移动 data 指针而非复制数据来"添加/移除"协议头。四个数据指针 + 三个协议头偏移 + skb_shared_info 的分片机制，使网络栈能以最小开销处理任意大小的数据包。

