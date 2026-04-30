# 109-VLAN-VXLAN — 虚拟局域网深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/8021q/vlan.c` + `drivers/net/vxlan/vxlan_core.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**VLAN（802.1Q）** 和 **VXLAN（NVO3）** 是两种网络虚拟化技术：VLAN 在二层插入 VLAN tag（12bit，最大 4096 个），VXLAN 在三层 UDP 封装（24bit，最大 1600 万个），实现大规模多租户隔离。

---

## 1. VLAN（802.1Q）

### 1.1 VLAN Tag

```
以太网帧 + VLAN Tag：

[DA(6) | SA(6) | VLAN Tag(4) | Type(2) | Data(46-1500) | FCS(4)]

VLAN Tag 结构（4 字节）：
  TPID(2) = 0x8100             // 固定
  TCI(2)  = VLAN ID (12 bit) + PCP (3 bit) + DEI (1 bit)

VLAN ID 范围：0-4095
  0 = no VLAN（优先级帧）
  1-4094 = 正常 VLAN
  4095 = 保留
```

### 1.2 struct vlan_hdr — VLAN 头

```c
// include/linux/if_vlan.h — vlan_hdr
struct vlan_hdr {
    __be16          h_vlan_TCI;   // TCI（VLAN ID + PCP + DEI）
    __be16          h_vlan_encapsulated_proto; // 上层协议类型
};
```

### 1.3 struct vlan_group — VLAN 组

```c
// net/8021q/vlan.h — vlan_group
struct vlan_group {
    // 4096 个 VLAN ID，每个有设备数组
    struct net_device __rcu *vlan_devices_arrays[NUMVLGROUPS][VLAN_GROUP_ARRAY_PART_LEN];
    //   NUMVLGROUPS = 1（未嵌套）或更多
    //   VLAN_GROUP_ARRAY_PART_LEN = 64
    //   vlan_devices_arrays[0][vid] = net_device for VLAN vid
};
```

### 1.4 vlan_dev_hard_start_xmit — VLAN 发送

```c
// net/8021q/vlan.c — vlan_dev_hard_start_xmit
static netdev_tx_t vlan_dev_hard_start_xmit(struct sk_buff *skb,
                                            struct net_device *dev)
{
    struct vlan_dev_priv *vlan = vlan_dev_priv(dev);
    u16 vlan_id = vlan->vlan_id;

    // 1. 移除 VLAN tag（如果入口已经是 vlan packet）
    if (eth_type_vlan(skb->protocol))
        __vlan_hwaccel_clear_tag(skb);

    // 2. 添加 VLAN tag
    __vlan_hwaccel_put_tag(skb, vlan->vlan_proto, vlan_id);

    // 3. 发送到真实设备
    return dev_queue_xmit(skb);
}
```

---

## 2. VXLAN（Virtual Extensible LAN）

### 2.1 VXLAN 封装

```
原始以太网帧：
[ DA(6) | SA(6) | Type | Payload ]

VXLAN 封装后：
[ Outer ETH | Outer IP(20) | Outer UDP(8) | VXLAN(8) | Inner ETH | Payload | FCS ]

VXLAN 头（8 字节）：
  标志(1) | 保留(3) | VXLAN ID(24 bit) | 标志(1) | 保留(3)

VXLAN ID（24 bit）：0-16777215（约 1600 万个）
```

### 2.2 struct vxlan_sock — VXLAN socket

```c
// drivers/net/vxlan/vxlan.h — vxlan_sock
struct vxlan_sock {
    struct socket          *sock;             // UDP socket
    struct work_struct      del_work;          // 删除延迟工作
    refcount_t              refcnt;             // 引用计数
    u32                     vnifilter:1;        // VNI filter 模式
    u32                     collect_metadata:1;  // 元数据收集
    u16                     port_min;           // 端口范围
    u16                     port_max;
    u32                     md5:1;
    struct vxlan_fdb       *fdb;              // MAC 表
    struct vxlan_config    *cfg;              // 配置
};
```

### 2.3 vxlan_xmit — VXLAN 发送

```c
// drivers/net/vxlan/vxlan_core.c — vxlan_xmit
void vxlan_xmit(struct sk_buff *skb, struct vxlan_config *cfg)
{
    union vxlan_addr *dst;
    u32 vni = vxlan_get_sk_family(vxlan_sk);

    // 1. 获取目标地址（从 MAC 或 IP 表）
    dst = vxlan_find_dst(skb, cfg);

    // 2. 添加 VXLAN 头
    struct vxlanhdr vh = {
        .vx_flags = VXLAN_HF_VNI,
        .vx_vni = vxlan_vni_field(vni),
    };

    // 3. 添加 UDP/IP 封装
    udp_tunnel_xmit(skb->dev, vxlan_sk, skb,
                    dst->sin.sin_addr.s_addr,
                    cfg->src_port, cfg->dst_port,
                    &vh, sizeof(vh));
}
```

---

## 3. VLAN vs VXLAN 对比

| 特性 | VLAN | VXLAN |
|------|------|-------|
| ID 宽度 | 12 bit（4096 个）| 24 bit（1677 万个）|
| 二层/三层 | 二层（同一交换机）| 三层（跨网络）|
| 封装 | 802.1Q tag | UDP + VXLAN 头 |
| 隔离范围 | 同一物理网络 | 跨数据中心 |
| 硬件支持 | 交换机支持 | 网络设备支持 |

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/8021q/vlan.c` | `vlan_group_prealloc_vid`、`vlan_dev_hard_start_xmit` |
| `net/8021q/vlan.h` | `struct vlan_group`、`struct vlan_hdr` |
| `drivers/net/vxlan/vxlan_core.c` | `vxlan_xmit`、`vxlan_rcv` |
| `drivers/net/vxlan/vxlan.h` | `struct vxlan_sock` |

---

## 5. 西游记类比

**VLAN/VXLAN** 就像"取经路上的驿站隔离"——

> VLAN 像在同一个大驿站里，用隔板划分出不同的小隔间（VLAN ID），每个隔间里的人只能和同一隔间的人说话，墙上有 4096 个隔间的限制。VXLAN 像在各个城市之间建立虚拟隧道（VXLAN ID），每个隧道可以穿过城墙（IP 网络），一共有 1600 万条隧道（24bit），让不同城市的同一队伍的人可以互相通信，而不受同城其他队伍干扰。这就是大二层网络的精髓——用 VLAN 或 VXLAN 把物理网络虚拟化成多个隔离的逻辑网络。

---

## 6. 关联文章

- **bridge**（article 108）：VLAN-aware bridge
- **netdevice**（网络部分）：VLAN 是 netdevice 的一个虚拟实例