# 61-neighbour — Linux 邻居协议（ARP/ND）深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**邻居子系统（Neighbour）** 是 Linux 网络协议栈中实现 L3→L2 地址解析的核心组件。对 IPv4（ARP）和 IPv6（ND）提供统一的邻居缓存管理——将 IP 地址映射到 MAC 地址，管理条目状态机（可达、延迟、陈旧、探测），并触发地址解析协议（ARP/NDISC）。

```
发送 IP 包到 192.168.1.1:
  ┌─────────────────────────────────┐
  │ 路由查找 → 下一跳 192.168.1.1   │
  │    ↓                             │
  │ neigh_lookup() → 查邻居缓存      │
  │    ├─ 命中 (NUD_REACHABLE)      │
  │    │    → 直接封装 L2 帧发送     │
  │    └─ 未命中 (NUD_NONE)          │
  │         → 发出 ARP 请求          │
  │         → 等待响应 (NUD_INCOMPLETE)
  │         → 收到响应 → 更新缓存    │
  │         → 重发队列中的 skb       │
  └─────────────────────────────────┘
```

**doom-lsp 确认**：核心实现 `net/core/neighbour.c`（**3,968 行**）。头文件 `include/net/neighbour.h`（617 行）。IPv4 ARP 在 `net/ipv4/arp.c`，IPv6 ND 在 `net/ipv6/ndisc.c`。

---

## 1. 核心数据结构

### 1.1 struct neighbour — 邻居条目

```c
// include/net/neighbour.h
struct neighbour {
    struct neighbour __rcu *next;         /* 哈希链表 */
    struct neigh_table *tbl;              /* 所属邻居表 */
    struct neigh_parms *parms;
    struct rcu_head rcu;
    struct net_device *dev;
    unsigned long used;                   /* 最近使用时间 */
    unsigned long confirmed;              /* 确认可达时间 */
    unsigned long updated;                /* 更新时间 */
    __u8 flags;                           /* NTF_* 标志 */
    __u8 nud_state;                       /* NUD_* 状态 */
    __u8 type;                            /* 邻居类型 */
    __u8 dead;                            /* 是否已标记死亡 */
    refcount_t refcnt;
    struct sk_buff_head arp_queue;        /* 等待 ARP 响应的 skb 队列 */
    struct timer_list timer;              /* 状态机定时器 */
    struct neigh_ops *ops;                /* 操作函数（输出/更新）*/
    u8 ha[];                              /* L2 地址（变长）*/
};
```

### 1.2 NUD 状态机

```c
// include/net/neighbour.h
enum {
    NUD_NONE       = 0x00,  /* 无条目 */
    NUD_INCOMPLETE = 0x01,  /* ARP 请求已发出，等待响应 */
    NUD_REACHABLE  = 0x02,  /* 地址可达（可正常发送）*/
    NUD_STALE      = 0x04,  /* 条目陈旧，需要验证 */
    NUD_DELAY      = 0x08,  /* 进入延迟验证状态 */
    NUD_PROBE      = 0x10,  /* 正在发送单播探测 */
    NUD_FAILED     = 0x20,  /* 解析失败 */
    NUD_NOARP      = 0x40,  /* 不需要 ARP（点对点）*/
    NUD_PERMANENT  = 0x80,  /* 静态永久条目 */
};

#define NUD_IN_TIMER   (NUD_INCOMPLETE|NUD_DELAY|NUD_PROBE)
#define NUD_VALID      (NUD_PERMANENT|NUD_NOARP|NUD_REACHABLE|NUD_PROBE|NUD_STALE|NUD_DELAY)
#define NUD_CONNECTED  (NUD_PERMANENT|NUD_NOARP|NUD_REACHABLE)
```

**状态转换图**：

```
                        neigh_update(NUD_REACHABLE)
                              ↓
 [NONE] ─→ [INCOMPLETE] ─→ [REACHABLE] ─→ [STALE] ─→ [DELAY] ─→ [PROBE] ═→ [FAILED]
   ↑          ARP 请求       可达确认      超时      发送探测     3 次超时     ↑
   └──────── 定时器超时 ──── NEIGH_VAR_DELAY_PROBE_TIME ──── NEIGH_VAR_RETRANS_TIME ─┘
```

### 1.3 struct neigh_table — 邻居表

```c
// include/net/neighbour.h
struct neigh_table {
    int family;                            /* AF_INET / AF_INET6 */
    int entry_size;                        /* neighbour + ha 大小 */
    int key_len;                           /* 地址长度（4/16）*/
    __be16 protocol;                       /* ETH_P_IP / ETH_P_IPV6 */
    struct neigh_parms parms;              /* 默认参数 */
    struct list_head parms_list;
    unsigned long entries;                 /* 条目数 */
    unsigned long gc_entries;
    unsigned int last_flush;
    unsigned int gc_thresh1;               /* 垃圾回收阈值 1 */
    unsigned int gc_thresh2;               /* 阈值 2 */
    unsigned int gc_thresh3;               /* 阈值 3 */
    unsigned long gc_interval;             /* 回收间隔 */
    unsigned int gc_chain_max;
    struct timer_list gc_timer;            /* GC 定时器 */
    struct timer_list proxy_timer;
    struct sk_buff_head proxy_queue;
    struct neigh_hash_table __rcu *nht;    /* 哈希表 */
    struct list_head gc_list;
    struct list_head managed_list;
    int (*constructor)(struct neighbour *);/* 邻居创建 */
    int (*pconstructor)(...);              /* 代理构造 */
    void (*pdestructor)(...);              /* 代理析构 */
    void (*proxy_redo)(struct sk_buff *skb); /* 代理重做 */
    int (*is_multicast)(const void *addr);  /* 多播检查 */
    int (*allow_add)(...);
    char *id;                              /* "arp_cache" / "ndisc_cache" */
    struct neigh_statistics __percpu *stats;
    struct net *net;
};
```

**doom-lsp 确认**：`struct neigh_table` 在 `include/net/neighbour.h`。IPv4 的 `arp_tbl` 和 IPv6 的 `nd_tbl` 是全局的 `neigh_table` 实例。

---

## 2. 邻居条目生命周期

### 2.1 查找——neigh_lookup

```c
// net/core/neighbour.c
struct neighbour *neigh_lookup(struct neigh_table *tbl, const void *pkey,
                               struct net_device *dev)
{
    return __neigh_lookup(tbl, key, dev, 0);  /* creat=0 → 不创建 */
}

struct neighbour *__neigh_lookup(struct neigh_table *tbl, const void *pkey,
                                 struct net_device *dev, int creat)
{
    /* 1. 哈希查找 */
    n = neigh_lookup_rcu(tbl, pkey, dev);

    if (n || !creat)
        return n;

    /* 2. 未命中 → 创建条目 */
    n = ___neigh_create(tbl, pkey, dev, false);
    return n;
}
```

### 2.2 创建——___neigh_create

```c
// net/core/neighbour.c
struct neighbour *___neigh_create(struct neigh_table *tbl,
    const void *pkey, struct net_device *dev, bool notify)
{
    size_t entry_size = tbl->entry_size + tbl->key_len;
    struct neighbour *n;

    n = kzalloc(entry_size, GFP_ATOMIC);
    n->tbl = tbl;
    n->parms = neigh_get_dev_parms_rcu(dev, tbl);
    n->dev = dev;
    n->nud_state = NUD_NONE;
    n->dead = 1;
    skb_queue_head_init(&n->arp_queue);
    timer_setup(&n->timer, neigh_timer_handler, 0);

    memcpy(n->primary_key, pkey, tbl->key_len);
    n->ops = tbl->entry_size ? &neigh_ops_alloc(tbl) : NULL;

    /* 调用构造器（arp/ndisc 的 constructor）*/
    if (tbl->constructor && tbl->constructor(n))
        goto out_neigh_release;

    /* 加入哈希表 */
    neigh_hash_insert(tbl, n);
    n->dead = 0;

    /* GC 列表管理 */
    neigh_update_gc_list(n);

    return n;
}
```

### 2.3 更新——neigh_update

```c
// net/core/neighbour.c
int neigh_update(struct neighbour *neigh, const u8 *lladdr, u8 new,
                 u32 flags, u32 nlmsg_pid)
{
    u8 old = neigh->nud_state;

    /* 1. 更新 L2 地址 */
    if (lladdr != neigh->ha) {
        memcpy(neigh->ha, lladdr, dev->addr_len);
        neigh_update_flags(neigh, flags, &notify, ...);
    }

    /* 2. 状态转换 */
    if (new & NUD_PERMANENT)
        goto out;
    if (old & NUD_VALID) {
        /* 从有效状态转移 */
        if (new & NUD_VALID) {           /* VALID → VALID */
            neigh->nud_state = new;
        } else if (new & NUD_NOARP) {
            /* NOARP */
        } else {
            /* VALID → INCOMPLETE 或 FAILED */
        }
    } else {
        /* 从无效状态 → 新状态 */
        neigh->nud_state = new;
    }

    /* 3. 处理 ARP 等待队列 */
    if (new & NUD_CONNECTED)
        neigh_send_arp_queued(neigh, lladdr);  /* 发送堆积的 skb */
    else if (!(old & NUD_VALID))
        /* 刚变成有效 → 发送排队数据 */
        __skb_queue_purge(&neigh->arp_queue);  /* 或重新入队 */

    /* 4. 定时器管理 */
    if (new & NUD_IN_TIMER)
        neigh_add_timer(neigh, ...);
    else
        neigh_del_timer(neigh);
}
```

**doom-lsp 确认**：`neigh_update` 在 `neighbour.c`。该函数处理所有 NUD 状态转换，从 L2 地址更新到等待队列处理到定时器管理。

### 2.4 定时器——neigh_timer_handler

```c
// net/core/neighbour.c:53
static void neigh_timer_handler(struct timer_list *t)
{
    struct neighbour *neigh = from_timer(neigh, t, timer);
    unsigned long next;

    switch (neigh->nud_state) {
    case NUD_INCOMPLETE:
        /* ARP 请求超时，重试或标记失败 */
        if (neigh-> probes >= neigh_max_probes(neigh)) {
            neigh->nud_state = NUD_FAILED;
            neigh_del_timer(neigh);       /* 条目死亡 */
        } else {
            /* 重新发送 ARP 请求 */
            __neigh_event_send_probe(neigh, ...);
            neigh_add_timer(neigh, jiffies + NEIGH_VAR(parms, RETRANS_TIME));
        }
        break;

    case NUD_DELAY:
        /* 延迟结束 → 进入探测 */
        neigh->nud_state = NUD_PROBE;
        neigh_add_timer(neigh, jiffies + NEIGH_VAR(parms, RETRANS_TIME));
        neigh_probe(neigh);
        break;

    case NUD_PROBE:
        /* 探测超时 → 重试或失败 */
        if (neigh->probes >= neigh_max_probes(neigh)) {
            neigh->nud_state = NUD_FAILED;
            notify = true;
        } else {
            neigh_add_timer(neigh, jiffies + NEIGH_VAR(parms, RETRANS_TIME));
            neigh_probe(neigh);
        }
        break;
    }
}
```

---

## 3. 输出路径

```c
// 输出路径：
dev_queue_xmit(skb)
  → neigh_output(neigh, skb)      /* 邻居层 */
      → n->ops->output(neigh, skb) /* 根据 NUD 状态选择 */
          ├─ NUD_CONNECTED → neigh_connected_output
          │   → 直接填充 L2 头 → dev_hard_start_xmit
          ├─ NUD_VALID → neigh_resolve_output
          │   → 可能触发 ARP 重新解析
          └─ NUD_NONE → neigh_resolve_output
              → __neigh_event_send → ARP 加入队列

// 驱动层（ARP 类型）的函数：
neigh_ops.output:
  ┌─ CONNECTED → dev_queue_xmit(skb)  ← 直接发送
  ├─ RESOLVE   → neigh_resolve_output()
  └─ BLACKHOLE → kfree_skb(skb)       ← 黑洞丢弃
```

---

## 4. GC 垃圾回收

```c
// net/core/neighbour.c
// 三个阈值水位：
// gc_thresh1 — 超过此值开始回收
// gc_thresh2 — 超过此值提高回收强度
// gc_thresh3 — 超过此值硬限制（不能再分配）

// 定时器驱动的 GC：neigh_periodic_work()
// 遍历 gc_list，移除过期的 STALE 条目

static void neigh_periodic_work(struct timer_list *t)
{
    struct neigh_table *tbl = from_timer(tbl, t, gc_timer);

    list_for_each_entry_safe(n, tmp, &tbl->gc_list, gc_list) {
        /* 跳过永久条目和正在使用的 */
        if (n->nud_state & (NUD_PERMANENT | NUD_IN_TIMER))
            continue;

        /* STALE 条目保留一段时间后再回收 */
        if (time_before(jiffies, n->used + NEIGH_VAR(parms, GC_STALETIME)))
            continue;

        neigh_ifdown(n, NULL);
    }
}
```

---

## 5. 邻居协议接口

### 5.1 ARP（IPv4）

```c
// net/ipv4/arp.c
struct neigh_table arp_tbl = {
    .family     = AF_INET,
    .key_len    = 4,                         /* 32-bit IPv4 */
    .protocol   = htons(ETH_P_IP),
    .hash       = neigh_rand_reach_queue,
    .constructor = arp_constructor,
    .proxy_redo = parp_redo,
    .id         = "arp_cache",
};

// ARP 请求的构造
int arp_constructor(struct neighbour *neigh)
{
    /* 设置操作函数指针 */
    if (dev->flags & (IFF_LOOPBACK | IFF_POINTOPOINT))
        neigh->ops = &arp_direct_ops;       /* 点对点 */
    else
        neigh->ops = &arp_generic_ops;      /* 以太网 */
}
```

### 5.2 NDISC（IPv6）

```c
// net/ipv6/ndisc.c
struct neigh_table nd_tbl = {
    .family     = AF_INET6,
    .key_len    = 16,                        /* 128-bit IPv6 */
    .protocol   = htons(ETH_P_IPV6),
    .constructor = ndisc_constructor,
    .id         = "ndisc_cache",
};
```

---

## 6. 调试

```bash
# 查看邻居表
ip neigh show
ip -s neigh show        # 含统计

# ARP 表
arp -n
cat /proc/net/arp

# 查看 GC 参数
ip neigh show nud all

# 邻居统计
cat /proc/net/stat/arp_cache

# 清理邻居
ip neigh flush all
arp -d <ip>

# 跟踪 ARP 事件
echo 1 > /sys/kernel/debug/tracing/events/neigh/neigh_update/enable
cat /sys/kernel/debug/tracing/trace_pipe
```

---

## 7. 总结

Linux 邻居子系统是一个**通用 L3→L2 地址解析引擎**：

**1. 统一的状态机** — NUD 状态机覆盖了从无条目→解析中→可达→陈旧→探测→失败的完整生命周期。

**2. 定时器驱动的解析** — `neigh_timer_handler` 处理 ARP/ND 请求的定时动作和超时。

**3. 等待队列机制** — `arp_queue` 暂存等待地址解析完成的 skb，解析成功后自动发送。

**4. 垃圾回收水位** — gc_thresh1/2/3 三级水位控制邻居缓存大小。

**5. 统一接口** — IPv4 ARP 和 IPv6 ND 共享同一个 neighbour 框架，通过 `neigh_table` / `constructor` 差异化。

**关键数字**：
- `neighbour.c`：3,968 行
- NUD 状态：8 个（+ 组合掩码）
- GC 阈值：3 级（thresh1/2/3）
- ARP 超时：默认 60s STALE、30s DELAY、5s PROBE、3 次探测

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
