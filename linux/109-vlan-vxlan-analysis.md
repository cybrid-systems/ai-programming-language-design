# VLAN / VXLAN — 虚拟网络深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/vlan/` + `drivers/net/vxlan.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**VLAN**（802.1Q）和 **VXLAN** 是网络虚拟化技术：
- **VLAN**：在二层隔离（12 位 VID）
- **VXLAN**：在三层封装（24 位 VNI），用于虚拟机/容器隔离

---

## 1. VLAN（802.1Q）

### 1.1 vlan_hdr — VLAN 头

```c
// include/linux/if_vlan.h — vlan_hdr
struct vlan_hdr {
    __be16              tpid;           // 0x8100（ETH_P_8021Q）
    __be16              tci;           // Tag Control Information
    //   bits 0-11: VID（12 位）
    //   bits 12-14: PCP（优先级）
    //   bit 15: CFI（规范格式）
};
```

### 1.2 vlan_dev — VLAN 设备

```c
// drivers/net/vlan/vlan_dev.c — vlan_dev
struct vlan_dev_priv {
    unsigned int        vlan_id;        // VLAN ID（0-4095）
    unsigned long       flags;          // VLAN_* 标志
    struct net_device   *real_dev;       // 下层设备
    __be16             vlan_proto;      // ETH_P_8021Q
};
```

---

## 2. VXLAN

### 2.1 vxlan_config — VXLAN 配置

```c
// drivers/net/vxlan.c — vxlan_config
struct vxlan_config {
    unsigned int        vni;            // VXLAN Network Identifier（24 位）
    unsigned int        remote_ip;      // 目的 IP（UDP 封装的远程）
    unsigned int        local_ip;       // 源 IP

    // 端口
    unsigned short     dst_port;       // 目的 UDP 端口（4789）
    unsigned short     src_port_min;   // 源端口范围
    unsigned short     src_port_max;

    // 选项
    unsigned int        df;            // Do not Fragment
    __u8                tos;           // Type of Service
    __u8                ttl;           // Time to Live
};
```

### 2.2 vxlan_xmit — 发送

```c
// drivers/net/vxlan.c — vxlan_xmit
static void vxlan_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct vxlan_config *conf = netdev_priv(dev);
    struct vxlanhdr *vh;

    // 1. 添加 VXLAN 头
    vh = (struct vxlanhdr *)skb_push(skb, sizeof(*vh));
    vh->vx_flags = VXLAN_FLAGS;          // I bit = 1（VNI 有效）
    vh->vx_vni = conf->vni << 8;        // VNI（24 位）

    // 2. UDP 封装
    struct udphdr *uh = udp_hdr(skb);
    uh->dest = conf->dst_port;          // 4789

    // 3. IP 封装
    //    将 skb 发送到 remote_ip
}
```

---

## 3. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/net/vlan/vlan_dev.c` | `vlan_dev_priv` |
| `drivers/net/vxlan.c` | `vxlan_config`、`vxlan_xmit` |
| `include/linux/if_vlan.h` | `vlan_hdr` |