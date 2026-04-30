# 151-rt_i — 路由项与路由缓存深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/net/ip_fib.h` + `net/ipv4/fib_trie.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**rt_i** 和 **fib_info** 是 Linux 路由子系统的核心结构，分别代表单个路由项和完整的路由信息（包括多个下一跳）。

---

## 1. 核心数据结构

### 1.1 struct fib_nh_exception — 黑洞路由异常

```c
// include/net/ip_fib.h — fib_nh_exception
struct fib_nh_exception {
    struct fn_hash       *fnhe_hash;    // 哈希表
    __be32               fnhe_daddr;     // 目的地址
    unsigned long         fnhe_expires;   // 过期时间

    struct rtable        *fnhe_rth_input; // 输入路由缓存
    struct rtable        *fnhe_rth_output; // 输出路由缓存
    unsigned int         fnhe_genid;     // 生成 ID
};
```

### 1.2 struct fib_nh — 下一跳

```c
// include/net/ip_fib.h — fib_nh
struct fib_nh {
    struct net_device       *nh_dev;     // 出口设备
    int                  nh_oif;         // 出口接口索引
    __be32               nh_gw;          // 网关 IP

    // ECMP（等价多路径）
    unsigned int         nh_weight;       // 权重
    unsigned int         nh_power;       // 当前使用计数

    // 哈希
    unsigned int         nh_upper_bound; // 上界
    unsigned int         nh_lower_bound; // 下界
};
```

### 1.3 struct fib_info — 完整路由信息

```c
// include/net/ip_fib.h — fib_info
struct fib_info {
    struct hlist_node       fib_hash;    // 哈希表节点
    struct hlist_node       fib_laddr;   // 本地地址哈希

    // 度量值
    u32               fib_priority;       // 路由优先级（metric）
    u32               fib_nh[0];         // 下一跳（变长数组）
};
```

### 1.4 struct rtmsg — 路由消息

```c
// include/linux/rtnetlink.h — rtmsg
struct rtmsg {
    unsigned char       rtm_family;       // AF_INET / AF_INET6
    unsigned char       rtm_dst_len;      // 目的前缀长度
    unsigned char       rtm_src_len;      // 源前缀长度
    unsigned char       rtm_tos;          // TOS

    unsigned char       rtm_table;        // 路由表 ID
    unsigned char       rtm_protocol;     // 协议
    unsigned char       rtm_scope;       // 范围
    unsigned char       rtm_type;        // 类型

    unsigned           rtm_flags;          // 标志
};
```

---

## 2. 路由类型（rtm_type）

```c
// include/linux/rtnetlink.h — 路由类型
#define RTN_UNSPEC     0  // 未指定
#define RTN_UNICAST    1  // 单播（普通路由）
#define RTN_LOCAL      2  // 本地地址
#define RTN_BROADCAST  3  // 广播
#define RTN_ANYCAST    4  // 任播
#define RTN_MULTICAST  5  // 多播
#define RTN_BLACKHOLE  6  // 黑洞
#define RTN_UNREACHABLE 7 // 不可达
#define RTN_PROHIBIT   8  // 禁止
#define RTN_THROW      9  // 继续查找
#define RTN_NAT        10 // NAT
#define RTN_XRESOLVE   11 // 外部解析
```

---

## 3. 路由协议（rtm_protocol）

```c
#define RTPROT_UNSPEC   0  // 未知
#define RTPROT_REDIRECT  1  // ICMP 重定向
#define RTPROT_KERNEL   2  // 内核
#define RTPROT_BOOT     3  // 启动
#define RTPROT_STATIC   4  // 静态配置
#define RTPROT_GATED    8  // GateD
#define RTPROT_RA       9  // 路由公告（RA）
#define RTPROT_MRT      10 // MRT
#define RTPROT_BIRD     12 // BIRD
```

---

## 4. ECMP（等价多路径路由）

### 4.1 ECMP 选择

```c
// net/ipv4/fib_frontend.c — fib_select_path
u32 fib_select_path(u32 id, const struct flowi4 *fl4, int oif, bool *resook, struct fib_result *res)
{
    struct fib_nh *nh;
    int hash_val;

    if (res->fi->fib_nhs > 1) {
        // 多下一跳：ECMP 哈希
        hash_val = fib_ecompute_hash(fl4);
        nh = fib_nh_get_idx(res->fi, hash_val);
    } else {
        nh = res->fib_nh;
    }

    return nh;
}
```

### 4.2 ECMP 哈希计算

```c
// 基于源/目的 IP 和端口的哈希
hash = jhash_2words(fl4->saddr, fl4->daddr, 0);
if (fl4->fl4_sport)
    hash = jhash_2words(hash, fl4->fl4_sport ^ (fl4->fl4_dport << 16), 0);
hash = hash % fib_nh->fib_nhs;
```

---

## 5. 路由缓存（rtable）

### 5.1 struct rtable — 路由缓存项

```c
// include/net/route.h — rtable
struct rtable {
    struct dst_entry       dst;            // DST 条目基类

    // 路由信息
    struct fib_result       *rt_res;      // 查找结果
    __be32                 rt_gateway;     // 网关

    // 协议头
    unsigned int           rt_spec_dst;     // 特定目的地址
    struct inet_peer       *rt_peer;       // 对等点（用于反向路径验证）
};
```

---

## 6. 路由添加（ip_route_output）

### 6.1 ip_route_output_flow

```c
// net/ipv4/route.c — ip_route_output_flow
int ip_route_output_flow(struct net *net, struct flowi4 *fl4, struct sock *sk)
{
    struct dst_entry *dst;

    // 1. 查找缓存路由
    dst = ip_route_output_key(net, fl4);
    if (IS_ERR(dst))
        return PTR_ERR(dst);

    // 2. 如果有缓存，使用缓存
    if (dst->obsolete > 0)
        ip_route_output_key_slow(net, fl4);

    return 0;
}
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/net/ip_fib.h` | `struct fib_nh`、`struct fib_info`、`struct fib_nh_exception` |
| `include/net/route.h` | `struct rtable` |
| `include/linux/rtnetlink.h` | `struct rtmsg`、`RTN_*`、`RTPROT_*` |
| `net/ipv4/fib_frontend.c` | `fib_select_path`、`fib_ecompute_hash` |

---

## 8. 西游记类比

**路由项** 就像"土地神的交通地图"——

> 土地神（路由器）有一本交通地图（fib_info），每一页（fib_nh）记录了一条路怎么走：经过哪个城门（nh_oif）、下一站是什么（nh_gw）、这条路有多宽（nh_weight）。如果有多条路可以到同一个地方（ECMP），就用哈希算法决定走哪条。黑洞路由（RTN_BLACKHOLE）就像地图上标了"此路不通"的标记，如果数据包走到了这里，就直接扔掉，不返回任何消息。不可达（RTN_UNREACHABLE）则是走到这里后，要给发件人回一封信说"此路不通"（ICMP 不可达）。

---

## 9. 关联文章

- **fib_lookup**（article 149）：路由查找
- **neighbour**（article 150）：ARP 解析下一跳 MAC