# skb_shared_info — skb 片段信息与 GSO 支持

**内核源码:** Linux 7.0-rc1 (`/home/dev/code/linux/include/linux/skbuff.h`)

---

## 1. 内存布局总览

`struct skb_shared_info` 位于 `skb->head` 缓冲区的**末尾**，紧跟在实际数据之后。它是 skb 内存布局的最后一块，位于 `skb->end`（字节偏移）处。

```text
skb->head                                    skb->head + skb->end
      |                                              |
      v                                              v
      +----------------------------------------------+------------------+
      |  headroom  |    data    |   tailroom   |  skb_shared_info   |
      +----------------------------------------------+------------------+
                           ^                              ^
                           |                              |
                      skb->data                      skb_end_pointer()
                                                       (指向 shinfo 起始)
```

- `skb_end_pointer(skb)` 返回 `skb->head + skb->end`，即 `struct skb_shared_info` 的起始地址
- `skb_shinfo(skb)` 正是对这个地址的强制转换（第 1783 行）:

```c
// skbuff.h:1783
#define skb_shinfo(SKB)  ((struct skb_shared_info *)(skb_end_pointer(SKB)))
```

**重要:** `skb_shared_info` 的大小在 `__alloc_skb()` 中被预先扣除——实际可用的 head 空间是 `SKB_WITH_OVERHEAD(X)`，而非用户请求的 `X`（第 255-265 行）。

---

## 2. struct skb_shared_info 核心字段

定义在 `skbuff.h:593`:

```c
struct skb_shared_info {
    __u8        flags;          // SKBFL_* 标志（zerocopy、shared frag 等）
    __u8        meta_len;       // 元数据长度
    __u8        nr_frags;       // frags[] 数组中已使用的元素个数
    __u8        tx_flags;       // SKBTX_* 传输标志（时间戳等）

    unsigned short gso_size;    // GSO 分段大小（字节）
    unsigned short gso_segs;   // GSO 段个数

    struct sk_buff *frag_list; // 指向片段 skb 链表（非线性数据）

    union {
        struct skb_shared_hwtstamps hwtstamps;  // 硬件时间戳
        struct xsk_tx_metadata_compl xsk_meta;  // XSK 元数据
    };

    unsigned int  gso_type;     // SKB_GSO_* 类型的位掩码

    u32           tskey;         // 时间戳 key（用于组播）

    atomic_t      dataref;      // 数据引用计数（低 16 位 = 总 ref，高 16 位 = payload ref）

    union {
        struct {
            u32 xdp_frags_size;
            u32 xdp_frags_truesize;
        };
        void *destructor_arg;  // 零拷贝回调参数
    };

    skb_frag_t frags[MAX_SKB_FRAGS];  // 必须为最后一个字段
};
```

### 字段分组说明

| 分组 | 字段 | 用途 |
|------|------|------|
| **片段管理** | `nr_frags`, `frags[]`, `frag_list` | 管理非线性数据的两种方式 |
| **GSO** | `gso_size`, `gso_segs`, `gso_type` | 通用分段卸载参数 |
| **时间戳/TX** | `tx_flags`, `tskey`, `hwtstamps` | 传输时间戳与元数据 |
| **引用计数** | `dataref` | 低 16 位 = 总 ref，高 16 位 = payload-only ref |
| **特殊功能** | `flags`, `destructor_arg` | zerocopy、zerocopy 标志等 |
| **XDP** | `xdp_frags_size`, `xdp_frags_truesize` | XDP 片段信息 |

### dataref 的分半设计

`skbuff.h:646-648` 定义了两个宏:

```c
#define SKB_DATAREF_SHIFT 16
#define SKB_DATAREF_MASK ((1 << SKB_DATAREF_SHIFT) - 1)  // 0xFFFF
```

- **低 16 位**: 整体引用计数（clone / hold / release）
- **高 16 位**: 仅 payload 的引用数——用于判断 `skb_header_cloned()` 是否允许写头部

这是 transport layer（如 TCP）实现"header-cloned skb"机制的关键。

---

## 3. struct skb_frag_t 与页面碎片

`skb_frag_t` 在 `skbuff.h:365-367` 定义为一个简单的三元组:

```c
typedef struct skb_frag {
    netmem_ref netmem;      // 内存引用（page 或 net_iov）
    unsigned int len;       // 片段长度（字节）
    unsigned int offset;    // 片段在内存对象内的偏移（字节）
} skb_frag_t;
```

> **注意:** 内核 7.0 引入了 `netmem_ref` 抽象层来统一管理 page 和 `struct net_iov`（XDP 零拷贝场景），不再直接存放 `struct page *`。

### frags[] 数组管理

`MAX_SKB_FRAGS` 默认值为 17 (`skbuff.h:351-354`):

```c
#ifndef CONFIG_MAX_SKB_FRAGS
# define CONFIG_MAX_SKB_FRAGS 17
#endif
#define MAX_SKB_FRAGS CONFIG_MAX_SKB_FRAGS
```

`frags[]` 是**必须为结构体最后一个字段**的数组（见注释 `/* must be last field, see pskb_expand_head() */`），因为 `pskb_expand_head()` 可能在 `skb_shared_info` 后面动态扩展 headroom，此时 `frags[]` 需要重新定位。

### 关键访问函数

```c
// skbuff.h:3641 — 获取片段偏移
static inline unsigned int skb_frag_off(const skb_frag_t *frag)
{
    return frag->offset;
}

// skbuff.h:3714 — 获取所属 page
static inline struct page *skb_frag_page(const skb_frag_t *frag)
{
    if (skb_frag_is_net_iov(frag))
        return NULL;
    return netmem_to_page(frag->netmem);
}

// skbuff.h:3719 — 获取 netmem 引用
static inline netmem_ref skb_frag_netmem(const skb_frag_t *frag)
{
    return frag->netmem;
}

// skbuff.h:3736 — 获取数据虚拟地址（需要 page 已映射）
static inline void *skb_frag_address(const skb_frag_t *frag)
{
    if (!skb_frag_page(frag))
        return NULL;
    return page_address(skb_frag_page(frag)) + skb_frag_off(frag);
}

// skbuff.h:3745 — 安全版本（检查 page 映射）
static inline void *skb_frag_address_safe(const skb_frag_t *frag)
{
    struct page *page = skb_frag_page(frag);
    void *ptr;
    if (!page)
        return NULL;
    ptr = page_address(page);
    if (unlikely(!ptr))
        return NULL;
    return ptr + skb_frag_off(frag);
}

// skbuff.h:3772 — 获取物理地址
static inline phys_addr_t skb_frag_phys(const skb_frag_t *frag)
{
    return page_to_phys(skb_frag_page(frag)) + skb_frag_off(frag);
}
```

### frags[] 片段合并逻辑（GRO）

`skb_gro_receive` (`gro.c:92`) 在合并两个 skb 时，会将 `skbinfo->frags[]` 直接拼接到 `pinfo->frags[]` 的末尾 (`gro.c:121-136`):

```c
if (headlen <= offset) {
    skb_frag_t *frag;
    skb_frag_t *frag2;
    int i = skbinfo->nr_frags;
    int nr_frags = pinfo->nr_frags + i;

    if (nr_frags > MAX_SKB_FRAGS)
        goto merge;  // 片段太多则走 frag_list 合并

    offset -= headlen;
    pinfo->nr_frags = nr_frags;
    skbinfo->nr_frags = 0;

    frag  = pinfo->frags + nr_frags;
    frag2 = skbinfo->frags + i;
    do {
        *--frag = *--frag2;  // 逆序批量拷贝，高效
    } while (--i);

    skb_frag_off_add(frag, offset);
    skb_frag_size_sub(frag, offset);
    ...
}
```

> 如果 `nr_frags` 超过 `MAX_SKB_FRAGS`，则回退到 `frag_list` 链表合并模式。

### DMA 映射

`skbuff.h:3801`:

```c
static inline dma_addr_t __skb_frag_dma_map(struct device *dev,
                                             const skb_frag_t *frag,
                                             size_t offset, size_t size,
                                             enum dma_data_direction dir)
{
    if (skb_frag_is_net_iov(frag)) {
        // XSK 场景：直接使用 net_iov 的 DMA 地址
        return xsk_buff_raw_get_dma(addr, offset);
    }
    return dma_map_page(dev, skb_frag_page(frag),
                        skb_frag_off(frag) + offset, size, dir);
}
```

---

## 4. frag_list — 片段链表

`frag_list` 是管理非线性数据的**第二种方式**，与 `frags[]` 互斥。`frag_list` 是一个 `struct sk_buff *` 指针，指向一个子 skb 链表:

```text
skb_shinfo(skb)->frag_list
        |
        v
   +---------+    next    +---------+    next   +---------+
   | sk_buff |  --------> | sk_buff |  -------> | sk_buff |
   | (子片)  |            | (子片)  |           | (子片)  |
   +---------+            +---------+           +---------+
```

**何时用 `frags[]` vs `frag_list`:**

| | frags[] | frag_list |
|---|---|---|
| **适用场景** | 连续 page 片段（IOMMU 可直接 DMA） | 子 skb 各自有独立 meta（需要携带协议头） |
| **GSO 片段合并** | 快速 memcpy/shuffle | 链表追加（`skb_gro_receive_list`） |
| **典型来源** | `pskb_expand_head()` 后填充 | TCP retransmit、UDP GRO 场景 |
| **内存开销** | 低（仅指针数组） | 高（每个子 skb 有独立 `struct sk_buff`） |

`skb_gro_receive_list` (`gro.c:225`) 的实现:

```c
int skb_gro_receive_list(struct sk_buff *p, struct sk_buff *skb)
{
    if (NAPI_GRO_CB(p)->last == p)
        skb_shinfo(p)->frag_list = skb;
    else
        NAPI_GRO_CB(p)->last->next = skb;

    skb_pull(skb, skb_gro_offset(skb));
    NAPI_GRO_CB(p)->last = skb;
    NAPI_GRO_CB(p)->count++;
    p->data_len += skb->len;
    p->truesize += skb->truesize;
    p->len += skb->len;
    ...
}
```

**注意:** `skb_segment_list` (`skbuff.c:4639`) 处理的是 `SKB_GSO_FRAGLIST` 类型，即发送端主动使用 frag_list 进行 GSO 分段。

---

## 5. GSO (Generic Segmentation Offload)

GSO 让协议层在**软件**中按 `gso_size` 字节进行分段，同时将分段工作"推迟"到驱动或硬件。内核负责设置 `gso_size`、`gso_segs` 和 `gso_type`，NIC 驱动在 `ndo_features_check` 或 `ndo_start_xmit` 中实际执行分段。

### 核心字段

```c
unsigned short gso_size;   // 每个 GSO 段的最大字节数
unsigned short gso_segs;   // 预期的 GSO 段个数
unsigned int   gso_type;   // SKB_GSO_* 位掩码
```

### gso_type 位定义

`skbuff.h:661-705` 定义了所有 GSO 类型:

```c
enum {
    SKB_GSO_TCPV4 = 1 << 0,        // TCPv4 分段
    SKB_GSO_DODGY  = 1 << 1,       // gso_size 不确定，需要验证
    SKB_GSO_TCP_ECN = 1 << 2,      // TCP ECN
    __SKB_GSO_TCP_FIXEDID = 1 << 3,
    SKB_GSO_TCPV6 = 1 << 4,       // TCPv6 分段
    SKB_GSO_FCOE  = 1 << 5,       // FCoE
    SKB_GSO_GRE   = 1 << 6,       // GRE TSO
    SKB_GSO_GRE_CSUM = 1 << 7,    // GRE + TSO checksum
    SKB_GSO_IPXIP4 = 1 << 8,      // IP-in-IP4
    SKB_GSO_IPXIP6 = 1 << 9,      // IP-in-IP6
    SKB_GSO_UDP_TUNNEL = 1 << 10, // UDP Tunnel
    SKB_GSO_UDP_TUNNEL_CSUM = 1 << 11,
    SKB_GSO_PARTIAL = 1 << 12,    // 仅对最内层 L4 做 HW GSO，其余 SW
    SKB_GSO_TUNNEL_REMCSUM = 1 << 13,
    SKB_GSO_SCTP   = 1 << 14,     // SCTP 片段
    SKB_GSO_ESP    = 1 << 15,     // ESP GSO
    SKB_GSO_UDP    = 1 << 16,     // UDP GSO（UFO，已废弃）
    SKB_GSO_UDP_L4 = 1 << 17,     // UDP L4 GSO（tuntap 等）
    SKB_GSO_FRAGLIST = 1 << 18,   // Fraglist GSO（发送端用 frag_list）
    SKB_GSO_TCP_ACCECN = 1 << 19, // TCP AccECN
    SKB_GSO_TCP_FIXEDID = 1 << 30,
    SKB_GSO_TCP_FIXEDID_INNER = 1 << 31,
};
```

### skb_segment — GSO 分割执行

`skb_segment()` (`skbuff.c:4742`) 是 GSO 分割的核心函数。它遍历 skb 的 `frags[]`、`frag_list` 和线性数据，按 `gso_size` 切成多个子 skb:

```c
struct sk_buff *skb_segment(struct sk_buff *head_skb,
                            netdev_features_t features)
{
    struct sk_buff *segs = NULL;
    struct sk_buff *tail = NULL;
    unsigned int mss = skb_shinfo(head_skb)->gso_size;  // 分段大小
    ...
    // 分段循环
    do {
        struct sk_buff *nskb;
        ...
        if (unlikely(mss == GSO_BY_FRAGS)) {
            len = list_skb->len;
        } else {
            len = head_skb->len - offset;
            if (len > mss)
                len = mss;
        }
        ...
        // 从 frags[] 中提取属于当前段的页面片段
        while (pos < offset + len) {
            if (unlikely(skb_shinfo(nskb)->nr_frags >= MAX_SKB_FRAGS)) {
                net_warn_ratelimited("skb_segment: too many frags: %u %u\n", ...);
                goto err;
            }
            *nskb_frag = ...;  // 从 head_skb 的 frags 拷贝到 nskb
            skb_shinfo(nskb)->nr_frags++;
            ...
        }
        nskb->data_len = len - hsize;
        nskb->len += nskb->data_len;
    } while ((offset += len) < head_skb->len);
    ...
}
```

关键行为:
- `SKB_GSO_DODGY` 类型的 skb（gso_size 不受信任），`skb_segment` 会额外验证 frag_list 成员是否对齐 `gso_size` 边界
- `SKB_GSO_PARTIAL` 时，最终一个段的 `gso_size` 会被设为 `tail->len % gso_size`（可能小于 `gso_size`）

### GSO_BY_FRAGS

`skbuff.h:357`:

```c
#define GSO_BY_FRAGS  0xFFFF
```

当 `gso_size == GSO_BY_FRAGS` 时，`skb_segment` 不做线性分段，而是直接返回 frag_list 中的子 skb 列表（用于 `SKB_GSO_FRAGLIST`）。

---

## 6. NETIF_F_GSO_* 特性标志

定义在 `netdev_features.h:26-57`:

```c
NETIF_F_GSO_BIT,        // Enable software GSO（总开关）
NETIF_F_GSO_ROBUST_BIT, // Robust GSO（对应 SKB_GSO_DODGY）
NETIF_F_GSO_GRE_BIT,    // GRE with TSO
NETIF_F_GSO_GRE_CSUM_BIT,
NETIF_F_GSO_IPXIP4_BIT, // IP4-in-IP4 or IP6-in-IP4
NETIF_F_GSO_IPXIP6_BIT,
NETIF_F_GSO_UDP_TUNNEL_BIT,
NETIF_F_GSO_UDP_TUNNEL_CSUM_BIT,
NETIF_F_GSO_PARTIAL_BIT,  // 部分 GSO（仅内层 L4 硬件）
NETIF_F_GSO_TUNNEL_REMCSUM_BIT,
NETIF_F_GSO_SCTP_BIT,
NETIF_F_GSO_ESP_BIT,
NETIF_F_GSO_UDP_BIT,    // UFO（deprecated）
NETIF_F_GSO_UDP_L4_BIT, // UDP L4 GSO
NETIF_F_GSO_FRAGLIST_BIT,
NETIF_F_GSO_ACCECN_BIT,
NETIF_F_GSO_LAST = NETIF_F_GSO_ACCECN_BIT,
```

汇总为简洁的宏:

```c
#define NETIF_F_GSO        __NETIF_F(GSO)
#define NETIF_F_GSO_ROBUST __NETIF_F(GSO_ROBUST)
#define NETIF_F_GSO_GRE    __NETIF_F(GSO_GRE)
#define NETIF_F_GSO_UDP_TUNNEL __NETIF_F(GSO_UDP_TUNNEL)
#define NETIF_F_GSO_PARTIAL     __NETIF_F(GSO_PARTIAL)
#define NETIF_F_GSO_SCTP        __NETIF_F(GSO_SCTP)
#define NETIF_F_GSO_ESP         __NETIF_F(GSO_ESP)
#define NETIF_F_GSO_UDP          __NETIF_F(GSO_UDP)
#define NETIF_F_GSO_UDP_L4       __NETIF_F(GSO_UDP_L4)
#define NETIF_F_GSO_FRAGLIST     __NETIF_F(GSO_FRAGLIST)
```

设备驱动通过 `dev->features` 宣告支持的 GSO 类型，内核在 `skb_segment` 之前用 `net_gso_ok()` 检查兼容性:

```c
// 判断 features 是否支持给定 gso_type
static inline bool net_gso_ok(netdev_features_t features, int gso_type)
{
    return (features & skb_gso_type_encoding(gso_type)) == skb_gso_type_encoding(gso_type);
}
```

---

## 7. tx_flags — 传输时间戳标志

`skbuff.h:469-491`:

```c
enum {
    SKBTX_HW_TSTAMP_NOBPF = 1 << 0,  // 驱动直接提供 HW 时间戳
    SKBTX_SW_TSTAMP = 1 << 1,        // SW 时间戳（入队时）
    SKBTX_IN_PROGRESS = 1 << 2,      // 驱动正在提供 HW 时间戳
    SKBTX_COMPLETION_TSTAMP = 1 << 3,// TX 完成时 SW 时间戳
    SKBTX_HW_TSTAMP_NETDEV = 1 << 5, // 基于 time/cycles 的 HW 时间戳
    SKBTX_SCHED_TSTAMP = 1 << 6,     // 进入调度时 SW 时间戳
    SKBTX_BPF = 1 << 7,              // BPF 扩展使用
};

#define SKBTX_HW_TSTAMP   (SKBTX_HW_TSTAMP_NOBPF | SKBTX_BPF)
#define SKBTX_ANY_SW_TSTAMP (SKBTX_SW_TSTAMP | SKBTX_SCHED_TSTAMP | \
                              SKBTX_BPF | SKBTX_COMPLETION_TSTAMP)
#define SKBTX_ANY_TSTAMP  (SKBTX_HW_TSTAMP | SKBTX_ANY_SW_TSTAMP)
```

---

## 8. SKBFL_* — Zero-copy 与共享片段标志

`skbuff.h:502-519`:

```c
enum {
    SKBFL_ZEROCOPY_ENABLE = BIT(0),   // 启用零拷贝例程
    SKBFL_SHARED_FRAG = BIT(1),        // 至少有一个 fragment 会被覆盖
    SKBFL_PURE_ZEROCOPY = BIT(2),     // 整个段均为零拷贝，不计入内核内存
    SKBFL_DONT_ORPHAN = BIT(3),       // 不要将 skb 设为孤儿
    SKBFL_MANAGED_FRAG_REFS = BIT(4), // fragment 引用由 ubuf_info 管理
};

#define SKBFL_ZEROCOPY_FRAG (SKBFL_ZEROCOPY_ENABLE | SKBFL_SHARED_FRAG)
#define SKBFL_ALL_ZEROCOPY  (SKBFL_ZEROCOPY_FRAG | SKBFL_PURE_ZEROCOPY | \
                               SKBFL_DONT_ORPHAN | SKBFL_MANAGED_FRAG_REFS)
```

`destructor_arg` (`void *`) 通常指向 `struct ubuf_info`，用于零拷贝完成后通知用户空间释放缓冲区。

---

## 9. pfmemalloc 标志与内存压力处理

`skb_shared_info` 本身不直接存储 `pfmemalloc`，但 `pfmemalloc` 标志存在于 `struct sk_buff` 本身（`skbuff.h:960`）:

```c
pfmemalloc:1,
```

### pfmemalloc 传播链

当 skb 从 page 分配并携带数据时，内核会传播 page 的 `pfmemalloc` 状态:

```c
// skbuff.h:3630 — 传播 pfmemalloc 到 skb
static inline void skb_propagate_pfmemalloc(const struct page *page,
                                            struct sk_buff *skb)
{
    if (page_is_pfmemalloc(page))
        skb->pfmemalloc = true;
}

// skbuff.c:2623 — page 分配时检测 pfmemalloc
if (page_is_pfmemalloc(page))
    skb->pfmemalloc = true;
```

### 零拷贝场景中的 pfmemalloc 约束

`skbuff.h:3622`:

```c
/* It is probably not a good idea to mix pfmemalloc pages and non-pfmemalloc
 * pages, because the caller may not check this and we may get the page
 * accounting wrong.
 */
static inline bool skb_page_frag_refill(unsigned int sz, void **ptr,
                                        gfp_t gfp)
{
    ...
    if (!page_is_pfmemalloc(page))
        return true;
    ...
}
```

当驱动使用 `pfmemalloc`  reserves 的 page 执行零拷贝传输时，必须注意:
1. `SKBFL_PURE_ZEROCOPY` 标记表示段不需要计入内核内存
2. `SKBFL_MANAGED_FRAG_REFS` 表示 fragment 引用由 `ubuf_info` 管理，在 `ubuf_info` 释放前是安全的
3. `pfmemalloc` page 在 DMA 完成后必须立即归还 page pool，不能长期持有

---

## 10. frags[] 数组管理细节

### 填充 frags[]

```c
// skbuff.h:2550 — 填充 netmem 引用到 frag
static inline void skb_frag_fill_netmem_desc(skb_frag_t *frag,
                                              netmem_ref netmem,
                                              unsigned int off,
                                              unsigned int size)
{
    frag->netmem = netmem;
    frag->offset = off;
    skb_frag_size_set(frag, size);
}

// skbuff.h:2559 — 填充 page 到 frag
static inline void skb_frag_fill_page_desc(skb_frag_t *frag,
                                            struct page *page,
                                            unsigned int off,
                                            unsigned int size)
{
    skb_frag_fill_netmem_desc(frag, page_to_netmem(page), off, size);
}

// skbuff.h:2570 — 批量填充（第 i 个 frag）
static inline void __skb_fill_page_desc_noacc(struct skb_shared_info *shinfo,
                                               int i, struct page *page,
                                               unsigned int off, unsigned int size)
{
    skb_frag_t *frag = &shinfo->frags[i];
    skb_frag_fill_page_desc(frag, page, off, size);
}
```

### SKBFL_SHARED_FRAG 与 __skb_linearize

在 `skb_segment` 的 `perform_csum_check` 路径 (`skbuff.c:5029`):

```c
if (skb_has_shared_frag(nskb) && __skb_linearize(nskb))
    goto err;
```

`SKBFL_SHARED_FRAG` 意味着 `frags[]` 中的页面可能被外部覆盖（如 vmsplice、sendfile）。如果需要计算校验和或进行线性化操作，必须先将数据拷贝到线性区域，否则可能读到被覆盖的数据。

### SKB_GSO_FRAGLIST 分割

`skb_segment_list` (`skbuff.c:4639`) 处理 `SKB_GSO_FRAGLIST` 类型。此时:
- `gso_size == GSO_BY_FRAGS` (0xFFFF)
- 内核直接遍历 `frag_list`，每个子 skb 对应一个 GSO 段
- 不需要从 `frags[]` 合并/分割

---

## 11. 完整内存布局图

```
+-- skb->head (固定 va, struct sk_buff 元数据在 slab/skb庐中) --+

struct sk_buff:
  next/prev     : 链表指针
  skb_shared_info *: 隐含在 skb->end 字段中
  
线性数据区 (head buffer):
  [headroom] [---------- data area ----------] [tailroom]
             ^               ^                ^
          skb->data      skb->tail         skb->end

skb_shared_info (位于 head buffer 末尾):
  +--------+--------+--------+--------+
  | flags  |meta_len| nr_frags | tx_flags |   (4 字节 @offset 0)
  +--------+--------+--------+--------+
  |       gso_size      |      gso_segs      |   (4 字节 @offset 4)
  +--------+--------+--------+--------+
  |              frag_list (ptr)              |   (8 字节 @offset 8)
  +--------+--------+--------+--------+
  |           gso_type (u32)                  |   (4 字节 @offset 16)
  +--------+--------+--------+--------+
  |              tskey (u32)                  |   (4 字节 @offset 20)
  +--------+--------+--------+--------+
  |         dataref (atomic_t)                |   (4 字节 @offset 24)
  +--------+--------+--------+--------+
  |   xdp_frags_size   |   xdp_frags_truesize |   (8 字节 @offset 28)
  +--------+--------+--------+--------+
  |           destructor_arg (ptr)            |   (8 字节 @offset 36)
  +--------+--------+--------+--------+
  |              frags[0]                    |   (12 字节)
  |              frags[1]                    |   (12 字节)
  |               ...                        |
  |              frags[MAX_SKB_FRAGS-1]       |   (17 * 12 = 204 字节)
  +-----------------------------------------+

子 skb 链表 (frag_list):
  skb_A  -->  skb_B  -->  skb_C  -->  NULL
    |           |           |
    v           v           v
  data_A     data_B      data_C    (各自独立的数据页)
```

> **注意:** `frags[]` 数组每个元素 12 字节（`netmem_ref`(8) + `len`(4) 实际在 64-bit 上), 实际上 `skb_frag_t` 是 16 字节对齐: `netmem_ref`(8) + `unsigned int len`(4) + `unsigned int offset`(4) = 16 字节。17 个 frag 共 272 字节。

---

## 12. 关键宏与 Helper 速查

| 宏/函数 | 定义位置 | 说明 |
|---------|----------|------|
| `skb_shinfo(skb)` | skbuff.h:1783 | 获取 `skb_shared_info *` |
| `skb_end_pointer(skb)` | skbuff.h:1722/1737 | 获取 shinfo 起始 va |
| `skb_end_offset(skb)` | skbuff.h:1727/1742 | 获取 shinfo 字节偏移 |
| `MAX_SKB_FRAGS` | skbuff.h:354 | frags[] 数组最大长度（默认 17） |
| `GSO_BY_FRAGS` | skbuff.h:357 | gso_size = 0xFFFF 时跳过线性分段 |
| `SKB_DATAREF_SHIFT` | skbuff.h:646 | dataref 高/低半分割位置（16） |
| `SKB_TRUESIZE(X)` | skbuff.h | 含 shinfo 开销的真实分配大小 |
| `skb_frag_size()` | skbuff.h:371 | 获取 fragment 长度 |
| `skb_frag_off()` | skbuff.h:3641 | 获取 fragment 偏移 |
| `skb_frag_page()` | skbuff.h:3705 | 获取 fragment 所属 page |
| `skb_frag_address()` | skbuff.h:3736 | 获取 fragment 数据 va |
| `skb_frag_phys()` | skbuff.h:3772 | 获取 fragment 物理地址 |
| `__skb_frag_dma_map()` | skbuff.h:3801 | DMA 映射 fragment |
| `skb_gro_receive()` | gro.c:92 | GRO 片段合并（frags[] 路径） |
| `skb_gro_receive_list()` | gro.c:225 | GRO 片段合并（frag_list 路径） |
| `skb_segment()` | skbuff.c:4742 | GSO 分割入口 |
| `skb_segment_list()` | skbuff.c:4639 | Fraglist GSO 分割 |
| `skb_propagate_pfmemalloc()` | skbuff.h:3630 | 传播 pfmemalloc 到 skb |

---

## 13. 小结

`struct skb_shared_info` 是 Linux 网络栈中处理**非线性 skb 数据**和**GSO 卸载**的核心数据结构。它位于每个 skb 的 head buffer 末尾，通过两种互补机制管理数据片段:

1. **`frags[]` 数组** — 高效的 page 片段指针数组，适合 IOMMU DMA，适合直接的 GSO 片段合并（`skb_gro_receive`）
2. **`frag_list` 链表** — 子 skb 链表，适合需要携带独立协议头的复杂场景（TCP retransmit、fraglist GSO）

GSO 相关的三个字段 `gso_size`、`gso_segs`、`gso_type` 为 NIC 驱动提供分段指令，由 `skb_segment()` 在软件中执行最终的段切分。`NETIF_F_GSO_*` 特性标志则在设备能力层面控制了可用 GSO 类型。

`dataref` 的 16-bit 分半设计允许 transport layer（如 TCP）在保持 payload 引用的情况下安全地"release header"，这是零拷贝路径优化的重要基础。
