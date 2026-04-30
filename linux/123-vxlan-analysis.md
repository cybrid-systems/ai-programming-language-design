# Linux Kernel VXLAN 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/vxlan/vxlan_core.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：VNI、UDP 封装、VTEP、隧道

---

## 0. VXLAN 概述

**VXLAN（Virtual eXtensible LAN）** 在 UDP（端口 4789）上封装二层帧，实现跨主机的虚拟机网络隔离。

```
原始帧:    [ETH_HDR][IP_HDR][Payload]
             ↓
VXLAN 头:   [ETH_HDR][IP_HDR][UDP_HDR][VXLAN_HDR][ETH_HDR][Payload]
                                    [VNI][0]
```

---

## 1. 核心数据结构

### 1.1 vxlan_dev — VXLAN 设备

```c
// drivers/net/vxlan/vxlan_private.h — vxlan_dev
struct vxlan_dev {
    struct net_device       *dev;              // 网络设备
    struct vxlan_sock      *vn4;             // IPv4 socket
    struct vxlan_sock      *vn6;             // IPv6 socket
    struct vxlan_config    *cfg;              // 配置
    struct list_head        next;             // 全局链表
    __be32                  vni;             // VNI（24-bit）
    u32                     dst_port;         // 目标端口（4789）
};
```

### 1.2 vxlan_config — 配置

```c
// drivers/net/vxlan/vxlan_core.c — vxlan_config
struct vxlan_config {
    __u32              vni;               // VXLAN Network Identifier
    __u32              remote_ip;        // 远程 VTEP IP
    __u32              local_ip;        // 本地 VTEP IP
    __be16             dst_port;         // UDP 目标端口
    __u8               ttl;
    __u8               tos;
    __u8               inherit_tos;      // 继承内部 tos
    bool                gpe;             // Geneve 模式
    struct vxlan_fdb   *fdb;            // MAC 学习表
};
```

---

## 2. vxlan_xmit_one — 发送封装

```c
// drivers/net/vxlan/vxlan_core.c:2341 — vxlan_xmit_one
void vxlan_xmit_one(struct sk_buff *skb, struct net_device *dev,
            __be32 default_vni, struct vxlan_rdst *rdst, bool did_rsc)
{
    struct vxlan_dev *vxlan = netdev_priv(dev);
    struct vxlan_metadata _md, *md = &_md;
    __be16 protocol = htons(ETH_P_TEB);

    // 1. 查找目标 VTEP
    if (rdst == NULL) {
        // 未知目标：查找 FDB 表
        fdb = vxlan_fdb_find(vxlan, eth_hdr(skb)->h_dest);
        if (fdb == NULL) {
            // 洪泛到所有 VTEP
            vxlan_flood(vxlan, skb);
            return;
        }
        rdst = &fdb->remote;
    }

    // 2. 添加 VXLAN 头
    //    [UDP dst=4789][VXLAN头][VNI=24bit][0][原始帧]
    vxlan_build_skb(skb, ...);

    // 3. 添加外层 IP 头（隧道端点）
    __iph = ip_hdr(skb);  // 外层 IP 头
    __iph->saddr = local_ip;
    __iph->daddr = rdst->remote_ip;

    // 4. 添加 UDP 头
    udph = udp_hdr(skb);
    udph->dest = htons(4789);

    // 5. 发送
    udp_tunnel6_xmit_skb(rt, skb->dev, skb, ...);
}
```

---

## 3. vxlan_rcv — 接收解封装

```c
// drivers/net/vxlan/vxlan_core.c:1643 — vxlan_rcv
static int vxlan_rcv(struct sock *sk, struct sk_buff *skb)
{
    struct vxlanhdr *vh;
    struct vxlan_dev *vxlan;
    __be32 vni;

    // 1. 验证 VXLAN 头
    vh = vxlan_hdr(skb);
    if (vh->vx_flags != VXLAN_HF_VNI)
        return -1;

    // 2. 提取 VNI
    vni = vxlan_get_vni(vh);

    // 3. 查找对应的 VXLAN 设备
    vxlan = vxlan_find_vni(vni);
    if (!vxlan)
        return -1;

    // 4. 移除 VXLAN/UDP/IP 头
    skb_pull(skb, sizeof(*vh) + sizeof(struct udphdr) + sizeof(struct iphdr));

    // 5. 设置 VLAN
    __vlan_tci = vxlan_get_vni(vh);  // VNI 作为 VLAN ID
    __vlan_set_proto(skb, ETH_P_TEB);

    // 6. 递送到虚拟机
    netif_rx(skb);

    return 0;
}
```

---

## 4. 参考

| 文件 | 函数 | 行 |
|------|------|-----|
| `drivers/net/vxlan/vxlan_core.c` | `vxlan_xmit_one` | 2341 |
| `drivers/net/vxlan/vxlan_core.c` | `vxlan_rcv` | 1643 |
| `drivers/net/vxlan/vxlan_core.c` | `vxlan_flood` | 洪泛 |
