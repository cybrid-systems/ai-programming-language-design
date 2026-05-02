# 109-vlan-vxlan — Linux VLAN 和 VXLAN 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**VLAN**（802.1Q）和 **VXLAN** 是 Linux 的两种网络虚拟化技术。VLAN 在以太帧中插入 4 字节 802.1Q 标签（VID 12-bit），限制广播域。VXLAN 将 L2 帧封装在 UDP 中（VTEP），实现跨三层网络的 L2 扩展。

**核心设计**：VLAN 设备通过 `vlan_dev_hard_start_xmit()` 在 skb 头部插入 VLAN 标签后从父设备发送。VXLAN 通过 `vxlan_xmit()` 将原始 skb 封装为 UDP 包（VXLAN 头 + 外层 UDP/IP），从物理网卡发送。

```
VLAN 封装：
  [DMAC][SMAC][802.1Q(VID)][EtherType][Payload]     ← 4 字节额外开销

VXLAN 封装：
  [Outer MAC][Outer IP][UDP][VXLAN(VNI)][Inner MAC][Inner IP][Payload]
   ↑  物理网络     ↑                    ↑ 原始 L2 帧
```

**doom-lsp 确认**：VLAN @ `net/8021q/vlan_dev.c`。VXLAN @ `drivers/net/vxlan/vxlan_core.c`。

---

## 1. VLAN 设备

### 1.1 数据结构

```c
// net/8021q/vlan.h
struct vlan_dev_priv {
    struct net_device *real_dev;             // 父设备
    struct vlan_info *vlan_info;
    unsigned int flags;
    u16 vlan_id;                              // VLAN ID (0-4095)
    u16 vlan_qos;                             // 默认 QoS
};
```

### 1.2 vlan_dev_hard_start_xmit——发送路径

```c
static netdev_tx_t vlan_dev_hard_start_xmit(struct sk_buff *skb,
    struct net_device *dev)
{
    struct vlan_dev_priv *vlan = vlan_dev_priv(dev);

    // 1. 插入 VLAN 标签
    if (vlan->flags & VLAN_FLAG_REORDER_HDR)
        __vlan_hwaccel_put_tag(skb, htons(ETH_P_8021Q), vlan->vlan_id);

    // 2. 从父设备发送
    skb->dev = vlan->real_dev;
    dev_queue_xmit(skb);
}
```

---

## 2. VXLAN 隧道

### 2.1 数据结构

```c
struct vxlan_dev {
    struct hlist_node hlist;                 // vni 哈希表节点
    struct net_device *dev;
    struct vxlan_config cfg;
    struct socket *sock;                     // UDP socket
    struct list_head fdb_head;               // FDB 表
    struct timer_list age_timer;             // FDB 老化
};

struct vxlan_fdb {
    struct hlist_node fdb_node;              // FDB 哈希节点
    unsigned char eth_addr[ETH_ALEN];        // 内层 MAC
    __be32 vni;                               // VXLAN VNI
    struct list_head remotes;                // 远端 VTEP
    unsigned long updated;
};
```

### 2.2 vxlan_xmit——VXLAN 发送

```c
static netdev_tx_t vxlan_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct vxlan_dev *vxlan = netdev_priv(dev);

    // 1. 查找 FDB（目标 MAC → 远端 VTEP）
    f = vxlan_fdb_find(vxlan, eth_hdr(skb)->h_dest, vni);

    // 2. 计算封装头部
    vxh = (struct vxlanhdr *)__skb_push(skb, sizeof(*vxh));
    vxh->vx_flags = htonl(VXLAN_HF_VNI);
    vxh->vx_vni = vni;

    // 3. 添加 UDP/IP 外层头
    udp_tunnel_xmit_skb(vxlan->sock->sk, skb, ...);
    // → 创建外层 UDP 包 → 从物理接口发送
}
```

### 2.3 vxlan_rcv——VXLAN 接收

```c
// UDP socket 收到 VXLAN 包 → vxlan_rcv()
void vxlan_rcv(struct vxlan_sock *vs, struct sk_buff *skb)
{
    // 1. 解析 VXLAN 头
    vxh = vxlan_gro_remcsum_offload(skb);
    vni = vxlan_vni(vxh->vx_vni);

    // 2. 查找 VXLAN 设备（按 VNI）
    vxlan = vxlan_find_vni(net, vni, vs->saddr.sa_family, ...);
    if (!vxlan) goto drop;

    // 3. MAC 学习（源 VTEP MAC）
    vxlan_snoop(skb, vxlan, vni);

    // 4. 剥离外层头后送入网络栈
    skb->protocol = eth_type_trans(skb, vxlan->dev);
    netif_rx(skb);
}
```

---

## 3. VLAN vs VXLAN

| 特性 | VLAN | VXLAN |
|------|------|-------|
| 标准 | 802.1Q | RFC 7348 |
| 封装开销 | 4 字节 | 50 字节 (UDP+IP+VXLAN) |
| ID 空间 | 12-bit (4096) | 24-bit (16M) |
| 跨三层 | 不支持 | 支持（UDP 隧道）|
| 多租户 | 有限 | 支持（16M VNI）|
| 配置 | `ip link add link eth0 name eth0.100 type vlan id 100` | `ip link add vxlan0 type vxlan id 100 remote 10.0.0.2` |

---

## 4. 调试

```bash
# VLAN
ip link add link eth0 name eth0.100 type vlan id 100
ip link set eth0.100 up

# VXLAN
ip link add vxlan0 type vxlan id 100 remote 10.0.0.2 dstport 4789
ip link set vxlan0 up

# 查看 FDB
bridge fdb show dev vxlan0

# 跟踪 VXLAN
echo 1 > /sys/kernel/debug/tracing/events/vxlan/enable
```

---

## 5. 关键函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `vlan_dev_hard_start_xmit` | `vlan_dev.c` | VLAN 发送（插入 802.1Q 标签）|
| `vxlan_xmit` | `vxlan_core.c` | VXLAN 发送（封装 UDP）|
| `vxlan_rcv` | `vxlan_core.c` | VXLAN 接收（解封装+学习）|
| `vxlan_snoop` | `vxlan_core.c` | VXLAN MAC 学习 |
| `vxlan_fdb_find` | `vxlan_core.c` | FDB 查找 |

---

## 6. 总结

VLAN 通过 `vlan_dev_hard_start_xmit` 在 skb 插入 4 字节 802.1Q 标签，限制广播域。VXLAN 通过 `vxlan_xmit` 将原始 L2 帧封装为 UDP 包（VXLAN 头 + VNI 24-bit），`vxlan_rcv` 接收端解封装 + MAC 学习（`vxlan_snoop`），实现跨三层网络的 L2 扩展。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*
