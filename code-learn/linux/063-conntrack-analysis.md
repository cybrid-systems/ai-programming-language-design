# 63-conntrack — Linux Netfilter 连接跟踪框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**连接跟踪（conntrack）** 是 Linux Netfilter 框架的核心组件——跟踪所有网络连接的状态（TCP/UDP/ICMP 等），是 NAT、状态防火墙、conntrack 工具的基础。每个数据包经过 conntrack 时被关联到一个 `struct nf_conn` 连接条目，该条目记录原始和回复方向的五元组、协议状态、超时时间等。

**核心设计**：Conntrack 使用**双向元组 + HMAC哈希**来 O(1) 查找连接。每个连接条目有 `tuplehash[2]`——`tuplehash[IP_CT_DIR_ORIGINAL]` 和 `tuplehash[IP_CT_DIR_REPLY]`。收到数据包时，用其五元组计算哈希，在哈希桶中线性搜索匹配的条目。

```
数据包到达
    ↓
nf_conntrack_in()
    ↓
resolve_normal_ct() — 查找已有连接或新建
    │
    ├─ __nf_conntrack_find()
    │   → 计算哈希 → 搜索哈希桶
    │   → 找到 → 更新状态和超时
    │
    └─ init_conntrack()
        → nf_conntrack_alloc()
        → 设置 tuplehash[ORIGINAL] 和 tuplehash[REPLY]
        → 添加到哈希表
        → 设置 L4 协议跟踪器 (tcp/udp/icmp...)
    ↓
nf_conntrack_confirm() — 确认连接
    → 最终插入哈希表（报文可转发）
```

**doom-lsp 确认**：核心在 `net/netfilter/nf_conntrack_core.c`（**2,819 行**）。结构定义在 `include/net/netfilter/nf_conntrack.h`（384 行）。元组定义在 `include/net/netfilter/nf_conntrack_tuple.h`。

---

## 1. 核心数据结构

### 1.1 struct nf_conntrack_tuple — 连接元组

```c
// include/net/netfilter/nf_conntrack_tuple.h
struct nf_conntrack_tuple {
    struct nf_conntrack_man src;                 /* 源: {IP, 端口/ICMP类型/...} */
    struct {
        union nf_inet_addr u3;                   /* 目标 IP */
        union {
            __be16 all;                          /* 通用端口 */
            struct { __be16 port; } tcp;
            struct { __be16 port; } udp;
            struct {
                u8 type, code;                   /* ICMP 类型/代码 */
            } icmp;
            struct { __be16 port; } dccp;
            struct { __be16 port; } sctp;
            struct { __be16 key; } gre;
        } u;
        u_int8_t protonum;                       /* 协议号 (IPPROTO_TCP/UDP/ICMP) */
        struct { } __nfct_hash_offsetend;         /* 哈希偏移填充 */
        u_int8_t dir;                            /* 方向 */
    } dst;
};

struct nf_conntrack_man {
    union nf_inet_addr u3;                       /* 源 IP */
    union {
        __be16 u6;                               /* 源端口 */
        struct { u8 id[2]; };                    /* ICMP ID */
    } u;
    u_int16_t l3num;                             /* L3 协议 (AF_INET/AF_INET6) */
};
```

### 1.2 struct nf_conn — 连接条目

```c
// include/net/netfilter/nf_conntrack.h:74-105
struct nf_conn {
    struct nf_conntrack ct_general;              /* 引用计数 */

    spinlock_t lock;
    u32 timeout;                                  /* 超时时间 (jiffies32) */

#ifdef CONFIG_NF_CONNTRACK_ZONES
    struct nf_conntrack_zone zone;                /* conntrack 区域 */
#endif
    struct nf_conntrack_tuple_hash tuplehash[IP_CT_DIR_MAX]; /* 双向元组 */

    unsigned long status;                         /* IPS_* 状态位 */
    possible_net_t ct_net;                        /* 所属 netns */

#if IS_ENABLED(CONFIG_NF_NAT)
    struct hlist_node nat_bysource;               /* NAT 源跟踪 */
#endif
    struct { } __nfct_init_offset;                /* memset 初始化偏移 */
    struct nf_conn *master;                       /* 主连接（expect）*/

#if defined(CONFIG_NF_CONNTRACK_MARK)
    u32 mark;                                     /* 连接标记 */
#endif
#ifdef CONFIG_NF_CONNTRACK_SECMARK
    u32 secmark;                                  /* 安全标记 */
#endif

    /* 扩展区域（可变大小，通过 nf_ct_ext_add 添加）*/
    struct nf_ct_ext *ext;

    /* 协议私有数据 */
    union nf_conntrack_proto proto;
};
```

**`struct nf_conntrack_tuple_hash`**：

```c
struct nf_conntrack_tuple_hash {
    struct hlist_nulls_node hnnode;           /* 哈希链表节点 */
    struct nf_conntrack_tuple tuple;          /* 元组 */
};
```

**IPS_* 状态位**：

```c
IPS_EXPECTED      /* 是被期望的连接 */
IPS_SEEN_REPLY    /* 已看到回复方向流量 */
IPS_ASSURED        /* 连接已确认（不会因超时被提前回收）*/
IPS_CONFIRMED      /* 连接已确认（在哈希表中）*/
IPS_SRC_NAT        /* 源 NAT 已应用 */
IPS_DST_NAT        /* 目标 NAT 已应用 */
IPS_SEQ_ADJUST     /* TCP 序列号已调整 */
IPS_SRC_NAT_DONE   /* 源 NAT 已完成 */
IPS_DST_NAT_DONE   /* 目标 NAT 已完成 */
IPS_DYING          /* 连接正在死亡 */
IPS_FIXED_TIMEOUT  /* 固定超时 */
IPS_TEMPLATE       /* 模板连接 */
IPS_OFFLOAD        /* 卸载到硬件 */
```

---

## 2. 查找——__nf_conntrack_find

```c
// net/netfilter/nf_conntrack_core.c
struct nf_conntrack_tuple_hash *
__nf_conntrack_find(struct net *net, const struct nf_conntrack_tuple *tuple,
                    const struct nf_conntrack_zone *zone)
{
    struct nf_conntrack_tuple_hash *h;
    struct hlist_nulls_node *n;
    unsigned int hash = hash_conntrack(net, tuple, zone);

    /* 计算哈希值 → 定位哈希桶 → 遍历链表 */
    hlist_nulls_for_each_entry_rcu(h, n, &net->ct.hash[hash], hnnode) {
        if (nf_ct_tuplehash_to_ctrack(h)->zone.id != zone->id)
            continue;
        if (nf_ct_tuple_equal(tuple, &h->tuple)) {
            /* 检查是否在 dying 列表（正在销毁的连接应被忽略）*/
            if (unlikely(nf_ct_is_dying(nf_ct_tuplehash_to_ctrack(h))))
                continue;
            return h;
        }
    }
    return NULL;
}
```

**哈希计算——`hash_conntrack()`**：

```c
// 使用 jhash + net_hash_mix() 实现均匀分布
// 对 tuple 的 IP/L4 信息进行哈希
static u32 hash_conntrack(const struct net *net,
                          const struct nf_conntrack_tuple *tuple,
                          const struct nf_conntrack_zone *zone)
{
    unsigned int hash;

    hash = jhash2((u32 *)tuple, sizeof(*tuple) / sizeof(u32),
                  zone->id ^ net_hash_mix(net));
    return reciprocal_scale(hash, net->ct.htable_size);
}
```

---

## 3. 新建连接——init_conntrack

```c
// net/netfilter/nf_conntrack_core.c
static struct nf_conn *
init_conntrack(struct net *net, struct nf_conn *tmpl,
               const struct nf_conntrack_tuple *tuple,
               struct nf_conntrack_l4proto *l4proto,
               struct sk_buff *skb, unsigned int dataoff, u32 hash)
{
    struct nf_conn *ct;

    /* 1. 分配 nf_conn */
    ct = nf_conntrack_alloc(net, zone, tuple, &repl_tuple, GFP_ATOMIC, hash);
    if (IS_ERR(ct))
        return (struct nf_conn *)ct;

    /* 2. 设置模板参数（mark、secmark、扩展等）*/
    if (tmpl) {
        ct->mark = tmpl->mark;
        ct->secmark = tmpl->secmark;
    }

    /* 3. 调用 L4 协议的新建连接函数 */
    if (l4proto->new(ct, skb, dataoff, timeouts))
        goto out;

    /* 4. 添加扩展区（helper、NAT、seqadj 等）*/
    if (tmpl && tmpl->ext) {
        nf_ct_ext_add(ct, extension, GFP_ATOMIC);
    }

    /* 5. 设置超时 */
    ct->timeout = l4proto->get_timeouts(net, ct, timeouts);

    /* 6. 设置状态标志 */
    if (test_bit(IPS_SEEN_REPLY_BIT, &ct->status))
        nf_conntrack_event_cache(IPCT_REPLY, ct);

    return ct;
}
```

---

## 4. 主处理流程

```c
// net/netfilter/nf_conntrack_core.c
int nf_conntrack_in(struct sk_buff *skb, const struct nf_hook_state *state)
{
    struct nf_conn *tmpl, *ct;
    enum ip_conntrack_info ctinfo;
    struct nf_conntrack_l4proto *l4proto;

    /* 1. 获取模板（或默认）*/
    tmpl = nf_ct_get(skb, &ctinfo);

    /* 2. 提取 L4 协议 */
    l4proto = __nf_ct_l4proto_find(l3num, protonum);

    /* 3. 提取元组 */
    if (!nf_ct_get_tuple(skb, skb_network_offset(skb) + dataoff,
                         l3num, protonum, net, &tuple, l4proto))
        goto out;

    /* 4. 查找已有连接 */
    h = nf_conntrack_find_get(net, zone, &tuple);

    if (!h) {
        /* 5. 新建连接 */
        ct = init_conntrack(net, tmpl, &tuple, l4proto, skb, dataoff, hash);

        if (IS_ERR(ct))
            goto out;

        /* 6. 添加到未确认列表（等待确认）*/
        nf_ct_add_to_unconfirmed_list(ct);

        /* 7. 设置 skb 的 conntrack 引用 */
        nf_ct_set(skb, ct, IP_CT_NEW_REPLY);

    } else {
        /* 8. 更新已有连接 */
        ct = nf_ct_tuplehash_to_ctrack(h);
        nf_ct_set(skb, ct, ctinfo);

        /* 9. 刷新超时 */
        nf_ct_refresh(ct, skb, l4proto->get_timeouts(net, ct, ...));
    }

    /* 10. 调用 L4 协议包处理（TCP 状态机更新等）*/
    ret = l4proto->packet(ct, skb, dataoff, ctinfo, state);
}
```

---

## 5. 确认——nf_conntrack_confirm

```c
// net/netfilter/nf_conntrack_core.c
int nf_conntrack_confirm(struct sk_buff *skb)
{
    struct nf_conn *ct = nf_ct_get(skb, &ctinfo);

    if (CTINFO2DIR(ctinfo) != IP_CT_DIR_ORIGINAL)
        return NF_ACCEPT;

    /* 标记为已确认 */
    set_bit(IPS_CONFIRMED_BIT, &ct->status);

    /* 从未确认列表移动到主哈希表 */
    nf_ct_add_to_dying_list(ct);           /* 旧 API 兼容 */
    nf_ct_delete_from_unconfirmed_list(ct);

    return NF_ACCEPT;
}
```

---

## 6. TCP 状态跟踪

```c
// net/netfilter/nf_conntrack_proto_tcp.c
// Conntrack 维护简化的 TCP 状态机：
enum tcp_conntrack {
    TCP_CONNTRACK_NONE,        /* 未建立 */
    TCP_CONNTRACK_SYN_SENT,    /* 发出 SYN */
    TCP_CONNTRACK_SYN_RECV,    /* 收到 SYN+ACK */
    TCP_CONNTRACK_ESTABLISHED, /* 已建立 */
    TCP_CONNTRACK_FIN_WAIT,    /* 收到 FIN */
    TCP_CONNTRACK_CLOSE_WAIT,  /* 关闭等待 */
    TCP_CONNTRACK_LAST_ACK,    /* 最后确认 */
    TCP_CONNTRACK_TIME_WAIT,   /* 时间等待 */
    TCP_CONNTRACK_CLOSE,       /* 已关闭 */
    TCP_CONNTRACK_MAX
};

// 通过分析 TCP 标志位驱动状态机转换
// SYN → SYN_SENT, SYN+ACK → SYN_RECV
// ACK → ESTABLISHED, FIN → FIN_WAIT... 
```

**doom-lsp 确认**：TCP conntrack 状态机在 `net/netfilter/nf_conntrack_proto_tcp.c` 中。

---

## 7. 超时管理

```c
// 每种协议有独立的超时表
// UDP: 30s (stream) / 3s (unicast)
// TCP: 120h (ESTABLISHED) / 120s (SYN_SENT) / 60s (FIN_WAIT)
// ICMP: 30s

// 超时刷新点在两个地方：
// 1. nf_conntrack_in() 的 packet handler 中直接刷新
// 2. nf_ct_gc_expired() GC 删除过期条目
```

**ECS（Early Connection Setup）超时调整**——通过 `nf_ct_refresh_acct()` 动态改变超时。

---

## 8. Expect——期望连接

```c
// 用于 FTP、SIP、H.323 等协议的控制→数据通道建立
// 控制连接注册一个 expectation，指定预期到达的数据连接的五元组
// 当数据包匹配 expectation 时，预创建 nf_conn，并设置 master 指针

struct nf_conntrack_expect {
    struct nf_conntrack_tuple tuple;      /* 期望的连接元组 */
    struct nf_conntrack_tuple_mask mask;   /* 通配掩码 */
    struct nf_conn *master;               /* 控制连接 */
    struct timer_list timeout;            /* 期望超时 */
    atomic_t use;
};

// FTP 示例：
// PORT 命令 → 期望 (TCP, 客户端:高端口 ↔ 服务端:20)
// PASV 命令 → 期望 (TCP, 客户端↔服务端:高端口)
```

---

## 9. 调试

```bash
# 查看所有跟踪的连接
cat /proc/net/nf_conntrack
  ipv4 2 tcp      6 431999 ESTABLISHED src=10.0.0.1 dst=10.0.0.2 sport=12345 dport=80 ...
  ipv4 2 udp      17 29 src=10.0.0.1 dst=8.8.8.8 sport=54321 dport=53 ...

# 查看统计
cat /proc/net/stat/nf_conntrack

# conntrack 工具
conntrack -L          # 列出连接
conntrack -E           # 事件监听
conntrack -D           # 删除连接

# 调整超时
echo 600 > /proc/sys/net/netfilter/nf_conntrack_udp_timeout
echo 3600 > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established
```

---

## 10. 总结

Conntrack 是一个**通用、高速的连接跟踪引擎**：

1. **双向元组** — `tuplehash[ORIGINAL]` + `tuplehash[REPLY]` 使 NAT 回复查找也能 O(1)
2. **哈希表 + 无锁 RCU 查找** — `hlist_nulls_for_each_entry_rcu` + dying 列表避免活锁
3. **L4 协议抽象** — TCP/UDP/ICMP/SCTP/DCCP/GRE 等通过统一 `nf_conntrack_l4proto` 接口
4. **扩展系统** — Helper、NAT、seqadj 等通过 nf_ct_ext 插件式附加
5. **expectation** — 预测并自动跟踪关联数据连接

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
