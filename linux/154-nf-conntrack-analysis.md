# 154-nf_conntrack — 连接跟踪深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/netfilter/nf_conntrack_core.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**nf_conntrack**（连接跟踪）是 Netfilter 的状态跟踪模块，为每个穿过防火墙的连接维护状态。TCP/UDP/ICMP 连接的状态被跟踪，实现状态防火墙、NAT 友等。

---

## 1. 连接状态

```
TCP 连接状态：
  NONE               → 无状态（UDP/ICMP）
  SYN_SENT           → 已发送 SYN
  SYN_RECV           → 收到 SYN
  ESTABLISHED        → 三次握手完成
  FIN_WAIT           → 收到 FIN
  CLOSE_WAIT         → 收到 FIN，等待关闭
  TIME_WAIT          → 2*MSL 等待

UDP 连接状态：
  NONE               → 无状态（初始）
  SRC_DST            → 已看到两个方向的数据

ICMP 连接状态：
  NONE               → 无状态
  SRC_DST            → 已响应
```

---

## 2. 核心数据结构

### 2.1 struct nf_conntrack_tuple — 连接元组

```c
// include/net/netfilter/nf_conntrack_tuple.h — nf_conntrack_tuple
struct nf_conntrack_tuple {
    // 方向
    struct {
        union nf_inet_addr u3;       // IP 地址（IPv4/IPv6）
        union {                       // 协议标识
            __be16 port;             // TCP/UDP 端口
            struct icmp_type_id {    // ICMP 类型+ID
                __u8 type;
                __u8 code;
            } icmp;
        } protonum;
        union nf_inet_addr u3_all;    // 所有地址
        __be16 l3num;                // 第三层协议号（AF_INET等）
    } src;                           // 源方向

    struct {
        union nf_inet_addr u3;       // 目的 IP
        union {                       // 目的端口
            __be16 port;
            struct { __u8 type; __u8 code; } icmp;
        } protonum;
        union nf_inet_addr u3_all;
        __be16 l3num;
    } dst;                           // 目的方向
};
```

### 2.2 struct nf_conn — 连接

```c
// include/net/netfilter/nf_conntrack.h — nf_conn
struct nf_conn {
    // 状态
    struct nf_conntrack        *ct_general;

    // 元组
    struct nf_conntrack_tuple  tuplehash[IP_CT_DIR_MAX]; // [0]=原始，[1]=回复

    // 状态
    unsigned long               status;     // IPS_* 标志

    // 计时器
    struct timer_list           timeout;   // 超时计时器

    // 协议特定
    union {
        struct nf_conntrack_tcp tcp;
        struct nf_conntrack_udp udp;
        struct nf_conntrack_icmp icmp;
    } proto;

    // 标记
    u32               mark;           // netfilter 标记
    u32               seennat;        // NAT 标记
};
```

### 2.3 struct nf_conntrack_tuple_hash — 元组哈希

```c
// include/net/netfilter/nf_conntrack.h — nf_conntrack_tuple_hash
typedef struct nf_conntrack_tuple_hash {
    struct nf_conntrack_tuple  tuple;   // 连接元组
    struct hlist_nulls_node   hnnode; // 哈希桶节点
    struct nf_conn            *conntrack; // 指向连接的指针
}nf_conntrack_tuple_hash;
```

---

## 3. conntrack 查找

### 3.1 ipv4_conntrack_in — TCP/UDP/ICMP 入口

```c
// net/netfilter/nf_conntrack_core.c — ipv4_conntrack_in
int ipv4_conntrack_in(struct net *net, unsigned int hooknum,
                       struct sk_buff *skb)
{
    struct nf_conntrack_tuple tuple;
    struct nf_conntrack_tuple_hash *h;
    struct nf_conn *ct;

    // 1. 解析数据包，构造 tuple
    nf_ct_get_tuple(skb, &tuple);

    // 2. 查找连接跟踪表
    h = nf_conntrack_find_get(net, &tuple);
    if (!h) {
        // 新连接，创建跟踪
        ct = nf_conntrack_alloc(net, &tuple);
        if (!ct)
            return NF_DROP;

        // 添加到连接跟踪表
        nf_conntrack_hash_insert(ct);
    } else {
        ct = nf_ct_get(h);

        // 更新状态
        nf_conntrack_update(ct, skb);
    }

    // 3. 根据状态决定是否放行
    return NF_ACCEPT;
}
```

---

## 4. TCP 状态转换

```c
// net/netfilter/nf_conntrack_tcp.c — tcp_packet
// TCP 状态转换：
//   NONE → SYN_SENT：看到 SYN
//   SYN_SENT → ESTABLISHED：看到 SYN+ACK
//   ESTABLISHED → FIN_WAIT：看到 FIN
//   ESTABLISHED → CLOSE_WAIT：看到对方的 FIN
//   FIN_WAIT → TIME_WAIT：收到对方的 ACK
```

---

## 5. NAT 与连接跟踪

### 5.1 NAT 对连接的影响

```c
// NAT 时，tuple 被修改：
// 原始方向：src=192.168.1.100:5000 → dst=8.8.8.8:80
// NAT 后：    src=1.2.3.4:10000 → dst=8.8.8.8:80

// 连接跟踪同时记录两个方向：
//   tuplehash[IP_CT_DIR_ORIGINAL]:  192.168.1.100:5000 → 8.8.8.8:80
//   tuplehash[IP_CT_DIR_REPLY]:      8.8.8.8:80 → 1.2.3.4:10000
```

---

## 6. 超时管理

```c
// 连接超时（默认）：
//   TCP SYN_SENT: 30 秒
//   TCP ESTABLISHED: 432000 秒（5 天）
//   UDP: 30 秒

// timer_list 到期后，调用 nf_ct_put() 释放连接
```

---

## 7. /proc 接口

```bash
# 查看连接跟踪：
cat /proc/net/nf_conntrack

# 示例：
ipv4 2 tcp 6 431999 ESTABLISHED src=192.168.1.100 dst=8.8.8.8 sport=5000 dport=80

# 清空连接跟踪：
conntrack -F

# 最大连接数：
cat /proc/sys/net/netfilter/nf_conntrack_max
```

---

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/netfilter/nf_conntrack_core.c` | `ipv4_conntrack_in`、`nf_conntrack_find_get`、`nf_conntrack_hash_insert` |
| `include/net/netfilter/nf_conntrack.h` | `struct nf_conn`、`struct nf_conntrack_tuple_hash` |
| `include/net/netfilter/nf_conntrack_tuple.h` | `struct nf_conntrack_tuple` |

---

## 9. 西游记类比

**nf_conntrack** 就像"取经路的身份证登记处"——

> 每个过关的人（数据包）都要在登记处（conntrack）登记身份证（tuple）。登记处看到"北京来的悟空"（源地址），就记录下来。等悟空回来时（回复数据包），登记处一看"哦，这是之前那个悟空的回信"（reply tuple），就知道这是已登记的人，可以直接放行。如果悟空第一次来（NEW），登记处还要决定是否允许进入（NEW → ESTABLISHED）。如果中途有人假冒悟空（异常包），登记处会根据记录判断这是假悟空（INVALID），拒绝进入。NAT 就像登记处有权修改过关人的身份证号码——把内网地址换成外网地址，但登记处的记录也跟着变，确保回信能被正确路由回来。

---

## 10. 关联文章

- **netfilter hooks**（article 153）：conntrack 在哪个 HOOK 点被调用
- **iptables**（相关）：使用 conntrack 的状态防火墙