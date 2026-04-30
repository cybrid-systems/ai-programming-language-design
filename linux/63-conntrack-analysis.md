# netfilter/conntrack — 连接跟踪深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/netfilter/nf_conntrack_core.c` + `net/netfilter/nf_conntrack_netlink.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**conntrack** 是 netfilter 的连接跟踪模块，为每个 TCP/UDP/ICMP 流维护状态（NEW/ESTABLISHED/RELATED），是 NAT 和状态防火墙的基础。

---

## 1. 核心数据结构

### 1.1 nf_conn — 连接描述符

```c
// include/net/netfilter/nf_conntrack.h — nf_conn
struct nf_conn {
    // 通用
    struct nf_conntrack        *ct_general;
    unsigned long              status;     // IPS_* 状态标志

    // 元组
    struct nf_conntrack_tuple  tuple[IP_CT_DIR_MAX];  // 双向元组
    // tuple[IP_CT_DIR_ORIGINAL]  → 原始方向（客户端 → 服务器）
    // tuple[IP_CT_DIR_REPLY]     → 回复方向（服务器 → 客户端）

    // 协议特定数据
    union nf_conntrack_proto_help *help;

    // NAT 辅助
    struct nf_conntrack_l4proto *proto;  // L4 协议
    struct nf_nat_info          *nat;  // NAT 信息

    // 期望（RELATED 连接）
    struct list_head            expecteds;  // 期望链表

    // 标记
    u16                         mark;

    // 命名空间
    struct net                 *ct_net;

    // 引用计数
    atomic_t                    use_count;

    // 时间戳
    unsigned long               timeout;
    struct timer_list           timeout_timer;  // 连接超时定时器
};
```

### 1.2 nf_conntrack_tuple — 元组（流方向）

```c
// include/net/netfilter/nf_conntrack.h — nf_conntrack_tuple
struct nf_conntrack_tuple {
    // 源/目的
    union nf_inet_addr          src;       // 源地址
    union nf_inet_addr          dst;       // 目的地址

    // 协议
    union {
        struct {
            __be16              sport;    // TCP/UDP 源端口
            __be16              dport;    // TCP/UDP 目的端口
        } tcp;
        struct {
            __be16              sport;
            __be16              dport;
        } udp;
        struct {
            __u8                type;     // ICMP 类型
            __u8                code;     // ICMP 代码
            __be16              id;       // ICMP 标识符
        } icmp;
    } u;

    // L3 协议
    u_int8_t                   protonum;  // IPPROTO_TCP/UDP/ICMP
    u_int8_t                   dir;       // IP_CT_DIR_*
};
```

### 1.3 IPS 状态标志

```c
// include/net/netfilter/nf_conntrack.h — enum ip_conntrack_status
enum ip_conntrack_status {
    IPS_EXPECTED         = (1 << IPS_EXPECTED_BIT),     // 期望连接
    IPS_SEEN_REPLY       = (1 << IPS_SEEN_REPLY_BIT),     // 已见回复
    IPS_ASSURED         = (1 << IPS_ASSURED_BIT),       // 已确认
    IPS_CONFIRMED       = (1 << IPS_CONFIRMED_BIT),       // 已确认（已加入表）
    IPS_SRC_NAT         = (1 << IPS_SRC_NAT_BIT),        // 源 NAT
    IPS_DST_NAT         = (1 << IPS_DST_NAT_BIT),         // 目的 NAT
    IPS_SEQ_ADJUST      = (1 << IPS_SEQ_ADJUST_BIT),     // 序列号调整
    IPS_DYING           = (1 << IPS_DYING_BIT),           // 正在死亡
    IPS_FIXED_TIMEOUT   = (1 << IPS_FIXED_TIMEOUT_BIT),  // 固定超时
};
```

---

## 2. 哈希表

### 2.1 nf_conntrack_hash — 全局连接表

```c
// net/netfilter/nf_conntrack_core.c — nf_conntrack_hash
struct nf_conntrack_tuple_hash {
    struct nf_conntrack_tuple  tuple;      // 元组
    struct hlist_nulls_node    hn;         // 哈希桶链表
    unsigned int               hash_index; // 哈希索引
};

static struct nf_conntrack_hash {
    struct hlist_nulls_head   *table;      // 哈希桶
    unsigned int               size;        // 哈希大小
    unsigned int               hash_mask;   // 哈希掩码
    atomic_t                   count;      // 连接数
} nf_conntrack_hash;
```

### 2.2 nf_ct_find_get — 查找连接

```c
// net/netfilter/nf_conntrack_core.c — nf_ct_find_get
struct nf_conntrack_tuple_hash *
nf_ct_find_get(const struct net *net, u16 zone,
               const struct nf_conntrack_tuple *tuple)
{
    struct nf_conntrack_tuple_hash *h;
    struct nf_conn *ct;

    // 1. 哈希查找
    hash = hash_conntrack(net, tuple);
    hlist_nulls_for_each_entry(h, n, &nf_conntrack_hash.table[hash], hn) {
        ct = nf_ct_tuplehash_to_ctrack(h);
        if (ct_matches(net, zone, tuple, h))
            return h;
    }

    return NULL;
}
```

---

## 3. NEW 状态处理（TCP 示例）

```c
// net/netfilter/nf_conntrack_proto_tcp.c — tcp_new
static bool tcp_new(struct nf_conn *ct, const struct sk_buff *skb,
                    unsigned int index)
{
    struct nf_conntrack_tuple *tuple = &ct->tuplehash[IP_CT_DIR_ORIGINAL].tuple;

    // TCP 三次握手第一个 SYN：
    // - 是 NEW 连接（未在哈希表中）
    // - 创建新 nf_conn，设置 state = TCP_CONNTRACK_SYN_SENT
    // - 加入连接跟踪表

    return true;
}
```

### 3.1 ESTABLISHED 确认

```c
// net/netfilter/nf_conntrack_proto_tcp.c — tcp_packet
static unsigned int *tcp_packet(struct nf_conn *ct,
                                const struct sk_buff *skb,
                                unsigned int dataoff,
                                enum tcp_conntrack *ct_state,
                                struct ip_ct_tcp_state *state)
{
    // 收到 SYN+ACK：
    //   state = SYN_SENT → ESTABLISHED
    //   设置 IPS_SEEN_REPLY 标志
    //   允许反向数据包通过

    // 收到 ACK（三次握手完成）：
    //   确认双向通信 → ESTABLISHED

    // 收到 FIN：
    //   ESTABLISHED → FIN_WAIT
    //   → TIME_WAIT
}
```

---

## 4. NAT 辅助

### 4.1 nf_nat_setup_info — 设置 NAT

```c
// net/netfilter/nf_nat_core.c — nf_nat_setup_info
static int nf_nat_setup_info(struct nf_conn *ct,
                             const struct nf_nat_range *range,
                             enum nf_nat_manip_type maniptype)
{
    // 1. 设置 IPS_SRC_NAT 或 IPS_DST_NAT
    if (maniptype == NF_NAT_MANIP_SRC)
        ct->status |= IPS_SRC_NAT;
    else
        ct->status |= IPS_DST_NAT;

    // 2. 修改元组
    //   源 NAT：改 src_ip/src_port
    //   目的 NAT：改 dst_ip/dst_port

    // 3. 设置反向元组（让回复流量也能被 NAT）
    nf_conntrack_alter_reply(ct, new_reply_tuple);

    // 4. 更新期望表（对于 RELATED 连接）
    adjust_expected_proto(ct, ct->master);

    return NF_ACCEPT;
}
```

---

## 5. netlink 用户空间接口

```c
// net/netfilter/nf_conntrack_netlink.c — ctnetlink_create
static int ctnetlink_create(struct net *net, struct sock *ctnl,
                            struct nlmsghdr *nlh, struct nlattr **cda)
{
    // 用户空间调用：conntrack -I -s 192.168.1.1 -d 10.0.0.1 -p tcp --sport 80 --dport 8080 -t NEW
    // → 创建期望的 conntrack 条目
}
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/net/netfilter/nf_conntrack.h` | `struct nf_conn`、`struct nf_conntrack_tuple` |
| `net/netfilter/nf_conntrack_core.c` | `nf_ct_find_get`、`tcp_packet`、`udp_packet` |
| `net/netfilter/nf_conntrack_netlink.c` | ctnetlink 用户空间接口 |