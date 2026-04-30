# 173-GRE_tunnel — GRE隧道协议深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/ip_gre.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**GRE（Generic Routing Encapsulation）** 是 Cisco 开发的隧道协议，将任意网络层协议封装进 IP 包。支持点对点隧道和多点隧道（通过 GRE Keys 区分）。

---

## 1. GRE 封装格式

```
原始 IP 包：
  [IP头][TCP][DATA]

GRE 封装后：
  [外部IP头][GRE头][原始IP头][TCP][DATA]

GRE 头（4字节 + 可选）：
  ┌──────────────────────────────┐
  │C|R|K|S|s|Recur|AFlag|Flags│
  ├──────────────────────────────┤
  │  Protocol Type (2B)          │
  ├──────────────────────────────┤
  │  Checksum（可选，2B）         │
  ├──────────────────────────────┤
  │  Offset（可选，2B）          │
  ├──────────────────────────────┤
  │  Key（可选，4B）             │
  ├──────────────────────────────┤
  │  Sequence Number（可选，4B）  │
  └──────────────────────────────┘

标志：
  C = Checksum Present
  K = Key Present
  S = Sequence Number Present
```

---

## 2. struct ip_tunnel — GRE 隧道

```c
// include/net/ip_tunnels.h — ip_tunnel
struct ip_tunnel {
    struct dst_entry       *dst;              // 路由缓存
    struct iphdr           *tun_hrd;        // 隧道头
    __be32                 i_key;           // 内部 key（用于 GRE Keys）
    __be32                 o_key;           // 外部 key
    __be16                 tun_flags;        // TUNNEL_*

    // 端点
    __be32                 saddr;           // 源 IP
    __be32                 daddr;           // 目的 IP
};
```

---

## 3. GRE 发送

### 3.1 ipgre_xmit

```c
// net/ipv4/ip_gre.c — ipgre_xmit
int ipgre_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct ip_tunnel *tun = netdev_priv(dev);
    __be16 proto;

    // 1. 重新计算校验和
    if (tun->parms.o_flags & TUNNEL_CSUM)
        skb->ip_summed = CHECKSUM_PARTIAL;

    // 2. 封装 GRE
    struct gre_base_hdr *greh;
    greh = (struct gre_base_hdr *)skb_push(skb, sizeof(*greh));
    greh->protocol = proto;  // 原始协议类型
    greh->flags = GRE_VERSION_0 | GRE_FLAGS;

    // 3. 添加外部 IP 头
    iph = ip_hdr(skb);
    iph->protocol = IPPROTO_GRE;
    iph->daddr = tun->parms.iph.daddr;

    // 4. 发送
    ip_local_out(skb);
}
```

---

## 4. GRE vs VXLAN

| 特性 | GRE | VXLAN |
|------|-----|-------|
| 封装 | IP | UDP |
| 支持协议 | 任意 L3 | 任意 |
| VNI | 无（用 Key）| 24 bit VNI |
| 多播 | 不支持 | 支持（通过多播组）|
| 负载均衡 | 差（所有流量同一隧道）| 好（基于 UDP 源端口）|

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/ip_gre.c` | `ipgre_xmit`、`gre_rcv` |
| `include/net/ip_tunnels.h` | `struct ip_tunnel` |

---

## 6. 西游记类喻

**GRE** 就像"取经路的快递封箱"——

> GRE 像把要寄的货物（原始 IP 包）放进一个箱子里（GRE 头），然后箱子上贴上地址标签（外部 IP 头），寄到对方城市。对方城市拆开箱子，取出里面的货物。GRE 不关心里面是什么货物（可以是任何 L3 协议）。比起 VXLAN，GRE 就像普通快递（IP 封装），VXLAN 像加了专用物流网（UDP 多播，更适合云计算的多租户隔离）。

---

## 7. 关联文章

- **VXLAN**（article 152）：另一种隧道协议
- **netif_receive_skb**（article 139）：GRE 接收路径