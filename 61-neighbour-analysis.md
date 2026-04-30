# neighbour — ARP/NDP 表管理深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/core/neighbour.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**neighbour** 管理 IP → MAC 地址映射（ARP 表），支持 IPv4（ARP）和 IPv6（NDP）。核心是**邻居状态机**。

---

## 1. 核心数据结构

### 1.1 neighbour — 邻居条目

```c
// include/net/neighbour.h — neighbour
struct neighbour {
    struct neighbour        *next;         // 哈希桶链表
    struct net_device        *dev;          // 网络设备
    unsigned long            cn_flags;     // NTF_* 标志

    // IP 地址
    union {
        __u8                raw[16];       // 原始 IP
        struct in_addr      _4;
        struct in6_addr      _6;
    } ha;  // 硬件地址（MAC）

    // 状态机
    unsigned char            nud_state;    // NUD_* 状态
    unsigned char            type;          // NDTYPE_* 类型
    unsigned char            dead;          // 是否已删除

    // 定时器
    struct timer_list        timer;        // 状态转换定时器

    // 输出函数
    int                     (*output)(struct neighbour *, struct sk_buff *);

    // 哈希
    struct hh_cache          *hh;          // 链路层头缓存

    // ARP 票
    atomic_t                 arp_queue;    // ARP 请求队列（等待解析）

    // 检测
    int                     (*output)(struct neighbour *, struct sk_buff *);

    struct neigh_ops         *ops;         // 操作函数
    unsigned long            confirmed;     // 确认时间
    unsigned long            updated;       // 更新时间
    unsigned long            used;
};
```

### 1.2 NUD 状态

```c
// include/net/neighbour.h — enum NUD_STATE
enum {
    NUD_INCOMPLETE,     // 正在解析（已发送 ARP 请求，等待回复）
    NUD_REACHABLE,      // 已确认（可达）
    NUD_STALE,          // 陈旧（可能不可达，需要验证）
    NUD_DELAY,          // 延迟（陈旧后开始延迟探测）
    NUD_PROBE,          // 探测（主动发送 ARP 请求验证）
    NUD_FAILED,         // 失败（无法解析）
    NUD_NOARP,          // 无 ARP（如点对点接口）
    NUD_PERMANENT,      // 永久（静态条目）
};
```

### 1.3 neigh_ops — 操作函数表

```c
// include/net/neighbour.h — neigh_ops
struct neigh_ops {
    int                     (*solicit)(struct neighbour *, struct sk_buff *);
    void                    (*error_report)(struct neighbour *, struct sk_buff *);
    int                     (*output)(struct neighbour *, struct sk_buff *);
    int                     (*connected_output)(struct neighbour *, struct sk_buff *);
};
```

---

## 2. 邻居状态机

### 2.1 neigh_timer_handler — 定时器处理

```c
// net/core/neighbour.c — neigh_timer_handler
static void neigh_timer_handler(struct timer_list *t)
{
    struct neighbour *neigh = from_timer(neigh, t, timer);
    unsigned state = neigh->nud_state;

    switch (state) {
    case NUD_DELAY:
        // 延迟时间到达，转为 PROBE
        neigh->nud_state = NUD_PROBE;
        neigh->ops->solicit(neigh, NULL);
        break;

    case NUD_STALE:
        // 陈旧状态，变为 PROBE 开始验证
        neigh->nud_state = NUD_PROBE;
        neigh->ops->solicit(neigh, NULL);
        break;

    case NUD_INCOMPLETE:
        // 还未解析，发送 ARP 请求
        neigh->ops->solicit(neigh, NULL);
        // 如果超过最大重试次数 → FAILED
        break;

    case NUD_PROBE:
        // PROBE 等待回复
        // 如果超时 → FAILED
        break;
    }
}
```

### 2.1 neigh_update — 更新邻居

```c
// net/core/neighbour.c — neigh_update
int neigh_update(struct neighbour *neigh, const u8 *lladdr, u8 new, u32 flags)
{
    // 1. 更新硬件地址
    if (lladdr)
        memcpy(neigh->ha, lladdr, neigh->dev->addr_len);

    // 2. 更新状态
    switch (new) {
    case NUD_REACHABLE:
        neigh->confirmed = jiffies;
        // 保持 REACHABLE 状态
        break;
    case NUD_STALE:
        // 变为陈旧，不立即探测
        neigh->nud_state = NUD_STALE;
        break;
    case NUD_FAILED:
        // 标记为失败
        neigh->nud_state = NUD_FAILED;
        break;
    case NUD_PERMANENT:
        neigh->nud_state = NUD_PERMANENT;
        break;
    }

    // 3. 如果有队列数据包，发送
    neigh_flush_dev(neigh, lladdr);

    return 0;
}
```

---

## 3. 解析流程

### 3.1 neigh_resolve_output — 解析并发送

```c
// net/core/neighbour.c — neigh_resolve_output
int neigh_resolve_output(struct neighbour *neigh, struct sk_buff *skb)
{
    int rc;

    // 1. 检查状态
    if (neigh->nud_state == NUD_FAILED)
        goto discard;

    // 2. 如果未知，发送 ARP 请求
    if (neigh->nud_state == NUD_INCOMPLETE) {
        __neigh_queue_sk_buff(neigh, skb);
        return 0;
    }

    // 3. 建立链路层头（使用 hh 缓存）
    rc = neigh_ha_lookup(neigh, skb);
    if (rc < 0)
        goto discard;

    // 4. 调用 output
    return neigh->ops->output(neigh, skb);

discard:
    kfree_skb(skb);
    return -EINVAL;
}
```

---

## 4. proc 接口

```c
// /proc/net/arp — ARP 表
// /proc/net/ndisc — IPv6 NDP 表
// /proc/sys/net/ipv4/neigh/default/gc_thresh1 — 垃圾收集阈值
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/net/neighbour.h` | `struct neighbour`、`enum NUD_STATE` |
| `net/core/neighbour.c` | `neigh_timer_handler`、`neigh_update`、`neigh_resolve_output` |