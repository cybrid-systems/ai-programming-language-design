# 22-sk_buff — 网络缓冲区深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**sk_buff（socket buffer）** 是 Linux 网络子���统中最核心的数据结构，贯穿整个网络协议栈——从网卡驱动到 socket 层，每个网络包都封装在一个 sk_buff 中。

sk_buff 的设计核心是**灵活的头部空间管理**：通过 head/tail/end/data 指针，协议栈各层可以轻松地添加/移除 协议头部，无需复制数据。

doom-lsp 确认 `include/linux/skbuff.h` 定义了核心结构，`net/core/skbuff.c` 包含分配/释放/克隆/复制等操作。

---

## 1. 核心数据结构

### 1.1 struct sk_buff

```c
struct sk_buff {
    union {
        struct {
            struct sk_buff  *next;      // skb 链表
            struct sk_buff  *prev;
        };
        struct rb_node      rbnode;     // 红黑树节点（TCP 重传队列）
    };

    struct sock             *sk;        // 所属 socket

    ktime_t                 tstamp;     // 时间戳

    struct net_device       *dev;       // 输入/输出设备

    unsigned int            len,        // 数据总长度
                            data_len;   // 非线性数据长度（paged frags）

    __u16                   protocol;   // 上层协议

    sk_buff_data_t          transport_header; // 传输层头部偏移
    sk_buff_data_t          network_header;   // 网络层头部偏移
    sk_buff_data_t          mac_header;       // 链路层头部偏移

    union {
        struct skb_shared_info *skb_shinfo; // 指向 skb_shared_info
    };

    /* 数据缓冲区指针 */
    unsigned char           *head,      // 缓冲区起始
                            *data,      // 当前数据起始
                            *tail,      // 当前数据结束
                            *end;       // 缓冲区结束

    ...
};
```

### 1.2 缓冲区布局

```
sk_buff 结构本身 ~ 200 字节
数据缓冲区（head → end）在结构体外，通过指针引用

head                     data              tail              end
  │                       │                 │                │
  ├──────────┬────────────┼─────────────────┼────────────────┤
  │ headroom │  L2 header │   L3 header     │    payload     │
  │ (预留)   │  (MAC)     │   (IP)          │                │
  └──────────┴────────────┴─────────────────┴────────────────┘

              headroom          数据区域           tailroom
```

各层对缓冲区的操作：

```
L2（网卡驱动）:     data → MAC 头
L3（IP 层）:        skb_pull(skb, ETH_HLEN) → data 跳过 MAC 头
L4（TCP/UDP）:      skb_pull(skb, ip_hdrlen) → data 跳过 IP 头
发送时：            skb_push(skb, header_len) → data 前移，填充头部
```

---

## 2. 关键操作

### 2.1 分配

```c
struct sk_buff *alloc_skb(unsigned int size, gfp_t priority)
{
    return __alloc_skb(size, priority, 0, -1);
}
```

`__alloc_skb` 分配 sk_buff 结构 + 数据缓冲区，初始化 head/data/tail/end 指针。

### 2.2 数据操作

| 函数 | 操作 | 效果 |
|------|------|------|
| `skb_put(skb, len)` | tail 后移 | 增加数据长度 |
| `skb_push(skb, len)` | data 前移 | 在头部添加协议头 |
| `skb_pull(skb, len)` | data 后移 | 剥离协议头 |
| `skb_reserve(skb, len)` | data+tail 一起前移 | 预留 headroom |

### 2.3 克隆与复制

```c
struct sk_buff *skb_clone(struct sk_buff *skb, gfp_t priority);
struct sk_buff *skb_copy(const struct sk_buff *skb, gfp_t priority);
```

- **skb_clone**: 共享数据缓冲区，只复制 sk_buff 结构体（引用计数 +1）
- **skb_copy**: 复制完整的 sk_buff + 数据缓冲区（深拷贝）

---

## 3. skb_shared_info

每个 sk_buff 尾部有一个 `skb_shared_info` 结构，管理非线性数据（碎片页）：

```c
struct skb_shared_info {
    unsigned char   nr_frags;           // 碎片页数
    skb_frag_t      frags[MAX_SKB_FRAGS]; // 碎片数组
    struct sk_buff  *frag_list;         // skb 链表（GSO 分段）

    unsigned int    gso_size;           // GSO 分段大小
    unsigned short  gso_segs;           // GSO 分段数
    unsigned short  gso_type;           // GSO 类型
};
```

---

## 4. 源码文件索引

| 文件 | 关键符号 |
|------|---------|
| `include/linux/skbuff.h` | `struct sk_buff` 定义 |
| `net/core/skbuff.c` | `__alloc_skb` / `skb_clone` / `skb_copy` |
| `net/core/dev.c` | netif_receive_skb 等接收路径 |

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
