# Linux Kernel VLAN / VXLAN 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/vlan/` + `drivers/net/vxlan/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. VLAN (802.1Q)

**VLAN** 在以太网帧头插入 4 字节 VLAN tag（TPID + TCI），实现**虚拟局域网**隔离。

```
以太网头：  [DA][SA][Type][Data][CRC]
VLAN帧：    [DA][SA][0x8100][VLAN_ID][Type][Data][CRC]
```

---

## 1. VLAN 结构

```c
// drivers/net/vlan/dev.c — vlan_dev_priv
struct vlan_dev_priv {
    unsigned int             vlan_id;       // VLAN ID (0-4095)
    unsigned int             vlan_proto;    // VLAN_PROTO_8021Q / 802.1AD
    struct net_device       *real_dev;     // 下层设备（eth0）
    struct vlan_pcpu_stats  *vlan_pcpu_stats; // 每 CPU 统计
};
```

---

## 2. VXLAN — 隧道

**VXLAN** 在 UDP（端口 4789）上封装二层，实现**跨主机的虚拟机网络**。

```c
// drivers/net/vxlan/vxlan.h — vxlan_config
struct vxlan_config {
    __u32              vni;              // VXLAN Network Identifier
    __u32              remote_ip;        // 远程 VTEP IP
    __u32              local_ip;        // 本地 VTEP IP
    __u16              dst_port;        // UDP 目标端口（4789）
    __u8               ttl;
    __u8               tos;
    struct vxlan_sock  *vsock;          // 绑定的 UDP socket
};
```

---

## 3. VXLAN 封装

```
原始帧:  [ETH_HDR][IP_HDR][Payload]
          ↓
VXLAN 封装：
          [ETH_HDR][IP_HDR][UDP_HDR][VXLAN_HDR][ETH_HDR][Payload]
                                              [VNI][0]

VTEP（VXLAN Tunnel End Point）：
  - 封装：VM → eth0 → vxlan0 → 封装 → 物理网络
  - 解封装：物理网络 → vxlan0 → 解封装 → VM
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `drivers/net/vlan/dev.c` | VLAN 设备实现 |
| `drivers/net/vxlan/vxlan.c` | VXLAN 封装/解封装 |
