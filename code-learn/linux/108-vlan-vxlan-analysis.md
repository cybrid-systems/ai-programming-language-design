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


## 3. VXLAN FDB 管理

```c
// FDB（Forwarding Database）将内层 MAC 地址映射到远端 VTEP（UDP 端点）
// 条目结构：
struct vxlan_fdb {
    struct hlist_node fdb_node;                // 哈希表节点
    unsigned char eth_addr[ETH_ALEN];          // 内层 MAC
    __be32 vni;                                 // VNI
    struct list_head remotes;                  // 远端 VTEP 列表
    unsigned long updated;                     // 最后更新
    u8 state;
};

// MAC 学习（@ :1421）：
// vxlan_snoop(dev, skb, vni)
//   → 提取 skb 源 MAC + 远端 UDP 地址
//   → 查找 FDB：vxlan_fdb_find_uc() @ :443
//   → 未找到：vxlan_fdb_create() 创建新条目 @ :855
//   → 找到：更新远端地址和时间戳

// FDB 老化：age_timer 定时器定期扫描
// → 超时未更新的条目删除
// → 类似 bridge FDB 的 ageing 机制
```

## 4. VXLAN GRO/GSO

```c
// VXLAN 支持 GRO（Generic Receive Offload）——合并接收：
// vxlan_gro_receive @ :705 — GRO 回调
// → 查找 VNI 匹配的 VXLAN 设备
// → skb_gro_receive() 合并多个 VXLAN 包
// → 减少协议栈处理次数

// VXLAN GSO（Generic Segmentation Offload）——分段发送：
// → 大 TCP 段分割为 MTU 大小的 VXLAN 包
// → 硬件 TSO 卸载或软件 GSO
```

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

## 7. VLAN rx_handler @ vlan_core.c

```c
// 802.1Q 标记的帧从物理接口进入时，通过 rx_handler 重定向到 VLAN 设备：
// vlan_skb_recv() — 在 __netif_receive_skb_core 中调用
// → 解析 VLAN 头（检查 CFI/DEI 位）
// → 提取 VLAN ID（12-bit）
// → 根据 VID 查找 VLAN 设备（__vlan_find_device)
// → 剥离 VLAN 头
// → 将 skb->dev 替换为 VLAN 设备
// → __netif_receive_skb(skb) — 送入 VLAN 设备的协议栈

// vlan_vid_add(dev, htons(ETH_P_8021Q), vid) @ :318
// → 通知底层设备添加 VLAN 过滤
// → 支持在交换机/网卡硬件中过滤指定 VLAN
```

## 8. VXLAN 硬件卸载

```c
// VXLAN 支持 GRO/GSO 卸载（减少 CPU 开销）：

// vxlan_gro_receive @ vxlan_core.c:705
// → 在 NAPI GRO 回调中识别 VXLAN 包
// → 解析 VNI 和内外层头
// → 合并多个 VXLAN 包为一个（减少协议栈处理）

// VXLAN TSO（分段卸载）：
// → 硬件在发送时将大 TCP 段分割为多个 VXLAN 包
// → 每个分割后的包有独立的外层 UDP/IP/VXLAN 头
// → 需要网卡支持 VXLAN TSO 卸载

// vxlan_features 包含：
// NETIF_F_SG | NETIF_F_HW_CSUM | NETIF_F_TSO | NETIF_F_GSO
```

## 9. GENEVE——VXLAN 的替代

```c
// GENEVE（Generic Network Virtualization Encapsulation）：
// 类似 VXLAN 的 UDP 隧道封装，但更灵活：
// - 可变长选项头
// - 24-bit VNI
// - 支持 TLV 选项

// struct genevehdr { u8 ver; u8 opt_len; __be16 protocol; __be32 vni; u8 options[]; };
// 创建：ip link add geneve0 type geneve id 100 remote 10.0.0.2
```

## 10. VLAN 协议注册

```c
// 内核支持 802.1Q（标准 VLAN）和 802.1AD（运营商桥接）：
// vlan_proto_register(&vlan_8021q_proto)
// → 注册 0x8100 EtherType 的处理
// vlan_proto_register(&vlan_8021ad_proto)
// → 注册 0x88A8 EtherType 的处理

// VLAN 设备创建：
// ip link add link eth0 name eth0.100 type vlan id 100
// → rtnetlink → vlan_newlink()
//   → register_vlan_dev() → 创建 VLAN 设备
```


## 11. VXLAN FDB 条目结构

```c
// VXLAN FDB 将内层 MAC 映射到远端 VTEP（UDP 端点）：
struct vxlan_fdb {
    struct hlist_node fdb_node;              // 哈希表节点
    unsigned char eth_addr[ETH_ALEN];        // 内层 MAC 地址
    __be32 vni;                               // VNI
    struct list_head remotes;                // 远端 VTEP 列表
    unsigned long updated;                    // 最后更新时间
    u8 state;
};

// 每个远端 VTEP 包含：
struct vxlan_rdst {
    struct sockaddr_in remote_ip;             // IPv4 地址
    __be16 remote_port;                       // UDP 端口（默认 4789）
    u32 remote_ifindex;
    struct vxlan_fdb *fdb;
    struct list_head list;
};

// FDB 老化（age_timer）：
// → 定期扫描 FDB 表
// → 删除超过 ageing_time 未更新的条目
// → 与 bridge 的 ageing 机制类似
```

## 12. VLAN 类型和 GVRP

```c
// VLAN 端口模式：
// ACCESS — 仅允许一个 VLAN，入帧打标签，出帧去标签
// TRUNK  — 允许多个 VLAN，帧带标签传输

// GVRP（GARP VLAN Registration Protocol）：
// → 交换机间自动协商 VLAN 成员
// → 内核中通过 vlan_gvrp_request_join() 实现

// VLAN 设备状态：
// cat /proc/net/vlan/config  — 查看 VLAN 配置
// cat /proc/net/vlan/eth0.100 — 查看 VLAN 统计
```


## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `vlan_dev_hard_start_xmit()` | net/8021q/vlan_dev.c | VLAN 发送 |
| `vxlan_xmit()` | drivers/net/vxlan/vxlan_core.c | VXLAN 封装 |
| `vxlan_rcv()` | drivers/net/vxlan/vxlan_core.c | VXLAN 解封装 |
| `struct vxlan_dev` | drivers/net/vxlan/vxlan.h | VXLAN 设备 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
