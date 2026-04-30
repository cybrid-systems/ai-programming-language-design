# sk_buff — 套接字缓冲区深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/skbuff.h` + `net/core/skbuff.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**sk_buff（socket buffer）** 是 Linux 网络栈中**数据包的核心描述符**，贯穿整个协议栈（NIC 驱动 → TCP/UDP → Socket API）。

---

## 1. 核心数据结构

### 1.1 sk_buff — 数据包描述符

```c
// include/linux/skbuff.h — sk_buff
struct sk_buff {
    /* 缓存行 1 — 通常被访问的字段 */
    struct sk_buff          *next;          // 链表（用于 rx/tx 队列）
    struct sk_buff          *prev;          // 链表

    union {
        struct {
            unsigned long       skb_refcnt; // 引用计数
        };
        struct inet_frag_info   *fraginfo;   // 分片信息
    };

    /* 网络层信息 */
    __u16                   protocol;      // ETH_P_IP 等
    __u16                   mac_len;      // MAC 头长度
    __u8                    ip_summed:2; // CHECKSUM_* 标志

    /* 头/尾指针（数据边界）*/
    unsigned char           *head;          // 缓冲起始
    unsigned char           *end;           // 缓冲结束
    unsigned char           *data;          // 数据起始
    unsigned char           *tail;          // 数据结束

    /* 分片（用于分片 IP 包）*/
    struct skb_shared_info *shinfo;       // 共享信息（frag_list）

    /* 时间戳 */
    struct skb_mstamp       skb_mstamp;   // 到达/发送时间

    /* 层次头指针 */
    struct {
        __u8    *mac_header;    // MAC 头
        __u8    *network_header; // 网络层头
        __u8    *transport_header; // 传输层头
    };

    /* Socket 引用 */
    struct sock              *sk;         // 关联的 sock
    struct net_device       *dev;         // 网络设备

    /* 路由 */
    struct dst_entry        *dst;         // 路由缓存
};
```

### 1.2 内存布局

```
head  ──────────────────── end
       │                   │
       ▼                   ▼
       ┌───────────────────┐
       │     skb_shared_info │
       │                   │
       ├───────────────────┤
       │    frag_list       │
       │                   │
       ├───────────────────┤
       │   tailroom        │◄── tail
       │                   │
       │     data          │◄── data
       │                   │
       │    headroom       │◄── data
       │                   │
       └───────────────────┘
```

---

## 2. headroom / tailroom

### 2.1 skb_push — 在数据前添加空间（头部增长）

```c
// include/linux/skbuff.h
static inline unsigned char *skb_push(struct sk_buff *skb, unsigned int len)
{
    skb->data -= len;
    skb->len += len;
    if (skb->data < skb->head)
        skb_panic(skb, ...);
    return skb->data;
}
```

### 2.2 skb_put — 在数据后添加空间（尾部增长）

```c
// include/linux/skbuff.h
static inline unsigned char *skb_put(struct sk_buff *skb, unsigned int len)
{
    unsigned char *tmp = skb->tail;
    skb->tail += len;
    skb->len += len;
    if (skb->tail > skb->end)
        skb_panic(skb, ...);
    return tmp;
}
```

### 2.3 skb_pull — 移除头部数据

```c
// include/linux/skbuff.h
static inline unsigned char *skb_pull(struct sk_buff *skb, unsigned int len)
{
    skb->len -= len;
    return skb->data += len;
}
```

---

## 3. 协议头访问

### 3.1 层次指针

```
ETH 头： mac_header ──────────► [DA][SA][Type][Data...]
                                      ▲
IP 头：  network_header ─────────┘
                                           ▲
TCP 头：  transport_header ───────────┘
```

### 3.2 常用宏

```c
// include/linux/skbuff.h
#define ip_hdr(skb)       ((skb)->network_header)
#define tcp_hdr(skb)      ((skb)->transport_header)
#define udp_hdr(skb)      ((skb)->transport_header)
#define eth_hdr(skb)      ((skb)->mac_header)

// 示例：访问 IP 头
struct iphdr *iph = ip_hdr(skb);
printk("src=%pI4 dst=%pI4\n", &iph->saddr, &iph->daddr);
```

---

## 4. 克隆和引用

```c
// include/linux/skbuff.h
static inline struct sk_buff *skb_get(struct sk_buff *skb)
{
    atomic_inc(&skb->users);
    return skb;
}

// 释放
void kfree_skb(struct sk_buff *skb)
{
    if (atomic_dec_and_test(&skb->users))
        __kfree_skb(skb);
}
```

---

## 5. 完整文件索引

| 文件 | 函数/宏 |
|------|---------|
| `include/linux/skbuff.h` | `struct sk_buff`、`skb_push/pull/put` |
| `net/core/skbuff.c` | `alloc_skb`、`__kfree_skb` |
