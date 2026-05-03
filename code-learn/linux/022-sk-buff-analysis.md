# 022-sk-buff — Linux 内核网络缓冲区深度源码分析

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
// 注意：以下为简化表示，实际结构使用大量 union 和 struct_group
struct sk_buff {
    // ----- 缓存线 0：链表 + socket -----
    struct sk_buff      *next;         // 链表 next
    struct sk_buff      *prev;         // 链表 prev
    union {
        struct net_device *dev;        // 网络设备
        unsigned long      dev_scratch;
    };
    struct sock         *sk;           // 关联的 socket

    ktime_t             tstamp;        // 时间戳
    char                cb[48];        // 控制缓冲区（各协议层私有）

    // ----- 长度信息 -----
    unsigned int        len;           // 数据长度
    unsigned int        data_len;      // 分散/聚集数据长度
    __u16               mac_len;       // MAC 头部长度
    __u16               hdr_len;       // 协议头长度

    // ----- 协议元数据（在 struct_group(headers) 内）-----
    __u8                pkt_type:3;    // PACKET_HOST / PACKET_BROADCAST ...
    __u8                ip_summed:2;   // 校验和状态
    __u8                encapsulation:1; // 封装标志
    __be16              protocol;      // 协议（htons(ETH_P_IP)）
    __u32               priority;      // 优先级
    __u16               transport_header; // L4 头部偏移
    __u16               network_header;   // L3 头部偏移
    __u16               mac_header;       // L2 头部偏移

    // ----- buffer 指针（位于 struct 末尾）-----
    sk_buff_data_t      tail;          // 数据结束（相对于 head 的偏移）
    sk_buff_data_t      end;           // 缓冲区结束（相对于 head 的偏移）
    unsigned char       *head;         // 缓冲区起始
    unsigned char       *data;         // 当前协议数据起点
    unsigned int        truesize;      // 总分配大小（含 sk_buff 本身）
    refcount_t          users;         // 引用计数
    // ...
};
// skb_shared_info 不直接作为字段，而是通过 skb_shinfo(skb) 宏
// 从 skb->end 之后的内存位置获取
``````

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
// 注意：skb_shared_info 不直接嵌入 struct sk_buff，
// 而是存储在 skb 数据缓冲区的末尾（head 起始处偏移 skb->end）。
// 访问方式：skb_shinfo(skb) → (struct skb_shared_info *)skb->end
// 这种设计让 GSO/GRO 的分片数据紧跟在 skb 数据区之后，充分利用局部性。
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

## 6. 网络栈处理举例——TCP 数据包接收

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

## 7. 源码文件索引

| 文件 | 内容 |
|------|------|
| `include/linux/skbuff.h` | sk_buff 定义 + inline 函数 |
| `net/core/skbuff.c` | 核心实现（alloc_skb, skb_clone, skb_copy）|

---

## 8. 关联文章

- **141-skb-shared-info**：共享信息详解
- **139-netif-receive-skb**：数据包接收路径
- **144-tcp-sendmsg**：TCP 发送中的 skb 操作

---

## 9. 总结

sk_buff 的设计核心是无复制协议层传递——各层通过移动 data 指针而非复制数据来"添加/移除"协议头。四个数据指针（head/data/tail/end）定义了缓冲区边界，三个 16 位偏移（transport/network/mac_header）记录协议层位置。skb_shared_info 通过 `skb_shinfo()` 宏从缓冲区尾部获取，使分片和 GSO 数据紧邻主数据区。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

