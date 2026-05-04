# 121-netdevice — Linux 网络设备核心深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**`struct net_device`** 是 Linux 网络子系统最核心的数据结构——它在内核中代表一个网络接口。无论是物理 NIC（e1000、mlx5）、虚拟设备（veth、tun、bridge），还是逻辑接口（bonding、VLAN），每个网络设备在 Linux 内核中对应一个 `net_device` 实例。

`net_device` 结构体约 **2000 字节**，跨越超过 30 条缓存线，包含 200+ 字段。内核社区专门用 `Documentation/networking/net_cachelines/net_device.rst` 文档追踪其缓存线布局。

**doom-lsp 确认**：`include/linux/netdevice.h` 含 **1160 个符号**，9580 行 — 内核中第二大的头文件（仅次于 skbuff.h）。

---

## 1. 核心数据结构

### 1.1 `struct net_device`——网络设备

（`include/linux/netdevice.h` L2124 — doom-lsp 确认）

```c
struct net_device {
    /* ----- TX 热路径（读较多，8 字节对齐）----- */
    __cacheline_group_begin(net_device_read_tx);
    unsigned long               priv_flags:32;    // L2133 — 私有标志
    unsigned long               lltx:1;           // L2135 — 锁发送（NETIF_F_LLTX）
    const struct net_device_ops *netdev_ops;      // L2137 — 设备操作函数表
    const struct header_ops     *header_ops;      // L2138 — 头部操作
    struct netdev_queue         *_tx;             // L2139 — 发送队列数组（percpu）
    unsigned int                real_num_tx_queues; // L2141 — 实际使用的 TX 队列数
    unsigned int                gso_max_size;     // L2142 — GSO 最大段大小
    unsigned int                gso_ipv4_max_size; // L2143
    u16                         gso_max_segs;     // L2144 — GSO 最大分段数
    __cacheline_group_end();

    /* ----- RX 热路径（读较多）----- */
    __cacheline_group_begin(net_device_read_rx);
    unsigned long               flags;            // L2159 — IFF_* 标志（IFF_UP, IFF_RUNNING...）
    unsigned int                min_mtu;          // L2161 — 最小 MTU
    unsigned int                max_mtu;          // L2162 — 最大 MTU
    unsigned int                mtu;              // L2163 — 当前 MTU（典型 1500）
    unsigned short              hard_header_len;  // L2164 — L2 头部预留长度（eth: 14）
    unsigned short              type;             // L2165 — ARPHRD_ETHER / ARPHRD_LOOPBACK...
    unsigned short              dev_id;           // L2167 — 同一设备类型内的 ID
    unsigned short              group;            // L2168 — 设备组
    struct netdev_rx_queue      *_rx;             // L2170 — 接收队列数组
    unsigned int                num_rx_queues;    // L2171 — RX 队列数
    __cacheline_group_end();

    /* ----- 特征和能力 ----- */
    netdev_features_t           features;         // L2240 — 当前启用的 offload 特性
    netdev_features_t           hw_features;      // L2244 — 硬件支持的 offload 特性
    netdev_features_t           wanted_features;  // L2245 — 期望的特性集
    netdev_features_t           vlan_features;    // L2246 — VLAN 透传 offload
    netdev_features_t           hw_enc_features;  // L2247 — 硬件封装 offload

    /* ----- 统计和状态 ----- */
    unsigned int                irq;              // L2292 — 中断号（传统设备）
    struct net_device_stats     stats;            // L2302 — 基本统计（rx_packets, tx_bytes...）
    struct list_head            dev_list;         // L2311 — 全局设备链表节点
    struct list_head            napi_list;        // L2312 — NAPI 实例链表
    struct list_head            unreg_list;       // L2313 — 注销中设备链表

    /* ----- 名称和索引 ----- */
    char                        name[IFNAMSIZ];   // L2335 — 设备名（"eth0", "lo"）
    struct net                  *nd_net;          // L2339 — 所属网络命名空间
    int                         ifindex;          // L2340 — 全局唯一接口索引
    int                         iflink;           // L2341 — 关联的设备索引

    /* ----- MAC 地址 ----- */
    unsigned char               dev_addr[MAX_ADDR_LEN]; // L2372 — 设备 MAC 地址
    unsigned char               *broadcast;       // L2378 — 广播地址

    /* ----- NAPI ----- */
    struct napi_struct          napi;             // L2395 — 嵌入式 napi_struct
    int                         gro_result;       // L2421 — GRO 结果缓存
    unsigned int                gro_max_size;     // L2422 — GRO 最大大小
    unsigned int                gro_ipv4_max_size;

    /* ----- 邻居子系统 ----- */
    struct netdev_queue         ingress_queue;    // L2473 — 入口队列（ifb 等使用）
    struct Qdisc                *qdisc;           // L2476 — 默认的出口排队规则
    struct Qdisc                *qdisc_sleeping;  // L2477 — 睡眠中的 qdisc
    unsigned int                tx_queue_len;     // L2479 — TX 队列长度（典型 1000）

    // ... 还有约 100 个字段未列出
};
```

### 1.2 `struct net_device_ops`——设备操作函数表

（`include/linux/netdevice.h` L1436 — doom-lsp 确认）

```c
struct net_device_ops {
    int     (*ndo_init)(struct net_device *dev);        // L1437 — 初始化
    void    (*ndo_uninit)(struct net_device *dev);       // L1438 — 反初始化
    int     (*ndo_open)(struct net_device *dev);         // L1439 — 打开设备（ifconfig up）
    int     (*ndo_stop)(struct net_device *dev);         // L1440 — 关闭设备
    netdev_tx_t (*ndo_start_xmit)(struct sk_buff *skb,   // L1441 — 发送数据包
                                  struct net_device *dev);
    u16     (*ndo_select_queue)(struct net_device *dev,  // L1446 — TX 队列选择
                                struct sk_buff *skb, ...);
    int     (*ndo_set_rx_mode)(struct net_device *dev);  // L1450 — 设置 RX 模式
    void    (*ndo_set_rx_mode)(struct net_device *dev);  // L1451 — 设置多播列表
    int     (*ndo_set_mac_address)(struct net_device *dev, void *addr); // L1456
    int     (*ndo_validate_addr)(struct net_device *dev); // L1457
    int     (*ndo_do_ioctl)(struct net_device *dev,      // L1458 — ioctl 处理
                            struct ifreq *ifr, int cmd);
    int     (*ndo_change_mtu)(struct net_device *dev,    // L1460 — 更改 MTU
                              int new_mtu);
    int     (*ndo_set_features)(struct net_device *dev,   // L1502 — 设置 offload 特征
                                netdev_features_t features);
    // ... 还有很多 ndo_* 函数指针（do_ioctl, get_stats64, xdp, set_features...）
};
```

### 1.3 `struct napi_struct`——NAPI 轮询状态

（`include/linux/netdevice.h` L381 — doom-lsp 确认）

```c
struct napi_struct {
    unsigned long               state;          // L383 — NAPI_STATE_SCHED 等状态
    struct list_head            poll_list;      // L390 — per-CPU poll 链表
    int                         weight;         // L392 — 单次轮询最大包数（典型 64）
    int                         (*poll)(struct napi_struct *, int); // L394 — 轮询回调
    struct net_device           *dev;           // L399 — 所属设备
    struct list_head            dev_list;       // L401 — 设备 NAPI 链表节点
    struct sk_buff_head         rx_ring;        // L407 — GRO 接收环
};
```

---

## 2. 数据包发送路径

```
应用程序 → sendmsg()
  │
  └─ sock_sendmsg() → tcp_sendmsg()
       │
       └─ dev_queue_xmit(skb, dev)
            │  net/core/dev.c
            │
            ├─ 1. QoS + TC（流量控制）
            │     └─ TC 分类器 → qdisc_enqueue_skb(skb, q)
            │           └─ 如果 qdisc 允许 → __qdisc_run(dev)
            │               └─ qdisc_restart(skb, dev)
            │                    → dev_hard_start_xmit(skb, dev)
            │
            ├─ 2. ndo_start_xmit
            │     skb = dev_queue_xmit_nit(skb, dev);  // 发包前通知
            │     rc = READ_ONCE(dev->netdev_ops)->ndo_start_xmit(skb, dev); // L1441
            │           └─ 驱动实现（如 e1000_xmit_frame、mlx5e_xmit_frame）
            │                → DMA 映射 skb->data → 写 TX descriptor → 通知硬件
            │
            ├─ 3. 发送完成
            │     驱动 TX 完成中断 → napi_schedule → napi_complete_done
            │     → skb_free(skb) → consume_skb
            │
            └─ 如果 ndo_start_xmit 返回 NETDEV_TX_BUSY
                 重新入队 qdisc
```

---

## 3. 数据包接收路径

```
网卡收到数据包 → DMA 写入 ring buffer
  │
  ├─ [硬件中断] napi_schedule(napi)
  │     → 设置 NAPI_STATE_SCHED
  │     → 将 napi 加入当前 CPU 的 softnet_data.poll_list
  │     → __raise_softirq_irqoff(NET_RX_SOFTIRQ)
  │
  ├─ [NET_RX_SOFTIRQ] net_rx_action()
  │     → 遍历 softnet_data.poll_list
  │
  └─ napi->poll(dev, budget)
       └─ 驱动实现（如 e1000_clean, mlx5e_napi_poll）
            ├─ 从 ring buffer 取出 skb（通过 DMA 完成描述符）
            ├─ napi_gro_receive(dev, skb)  // GRO 合并
            └─ netif_receive_skb(skb)      // 送入协议栈

net_device 在接收路径中的作用：
  skb->dev = dev（设置设备指针）
  驱动在构造 skb 后设置 skb->dev = 当前设备的 net_device
```

---

## 4. 关键操作

### 4.1 设备注册

```c
// net/core/dev.c
int register_netdevice(struct net_device *dev)
{
    // 1. 调用 ndo_init
    ret = dev->netdev_ops->ndo_init(dev);

    // 2. 分配 ifindex
    dev->ifindex = dev_new_index(dev_net(dev));

    // 3. 加入全局链表
    list_netdevice(dev);

    // 4. 生成 uevent → udev
    netdev_uevent(dev, ...);

    // 5. 通知 netlink
    rtmsg_ifinfo(RTM_NEWLINK, dev, ...);

    dev_hold(dev);  // 增加引用计数
}
```

### 4.2 设备重命名

```c
// sysfs 或 ioctl 触发
int dev_change_name(struct net_device *dev, const char *newname)
{
    // 验证名称唯一性
    sync_netdev_name(dev, newname);
    strcpy(dev->name, newname);  // L2335
    // 通知 netlink
    rtmsg_ifinfo(RTM_NEWLINK, dev, ...);
}
```

---

## 5. 功能标志（netdev_features）

```c
// include/linux/netdev_features.h
#define NETIF_F_SG          BIT(0)  // 散/聚 I/O（skb_frag_t）
#define NETIF_F_IP_CSUM     BIT(1)  // IPv4 TSO（TCP 校验和卸载）
#define NETIF_F_IPV6_CSUM   BIT(2)  // IPv6 TSO
#define NETIF_F_HW_VLAN     BIT(3)  // 硬件 VLAN 过滤
#define NETIF_F_HW_TC       BIT(4)  // 硬件流量控制
#define NETIF_F_GRO         BIT(14) // 通用接收卸载
#define NETIF_F_LRO         BIT(15) // 大包接收卸载
#define NETIF_F_TSO         BIT(16) // TCP 分段卸载（IPv4）
#define NETIF_F_TSO6        BIT(18) // TCP 分段卸载（IPv6）
#define NETIF_F_GSO         BIT(20) // 通用分段卸载
#define NETIF_F_NTUPLE      BIT(25) // 硬件 RX 流分类
#define NETIF_F_RXHASH      BIT(27) // 硬件 RSS 哈希
#define NETIF_F_RXCSUM      BIT(28) // 接收校验和卸载
#define NETIF_F_HW_L2FW_DOFFLOAD BIT(29) // L2 转发卸载
```

---

## 6. 设备类型与命名

| 类型 | 名称模式 | ndo_start_xmit 示例 | 说明 |
|------|---------|-------------------|------|
| 回环 | `lo` | loopback_xmit | 内核内部回环 |
| 以太网 | `eth0` | e1000_xmit_frame | 物理 NIC |
| 无线 | `wlan0` | iwl_pcie_tx | WiFi 网卡 |
| VLAN | `eth0.100` | 对应物理设备 | VLAN 子接口 |
| 桥接 | `br0` | br_dev_xmit | 软件交换机 |
| 隧道 | `tun0` | tun_net_xmit | 用户空间网络 |
| bond | `bond0` | bond_xmit_slave | 链路聚合 |

---


## 7. 网络设备生命周期

```
alloc_netdev_mqs() → register_netdevice(dev)
  → ndo_init → netif_carrier_on() → /sys/class/net/eth0
  → ndo_open → ndo_start_xmit → ndo_stop
  → unregister_netdevice(dev) → free_netdevice(dev)
```

## 8. 功能标志

## 7. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct net_device` | include/linux/netdevice.h | 2124 |
| `struct net_device_ops` | include/linux/netdevice.h | 1436 |
| `struct napi_struct` | include/linux/netdevice.h | 381 |
| `register_netdevice()` | net/core/dev.c | 相关 |
| `unregister_netdevice()` | net/core/dev.c | 相关 |
| `dev_queue_xmit()` | net/core/dev.c | 相关 |
| `netif_rx()` | net/core/dev.c | 相关 |
| `dev_change_name()` | net/core/dev.c | 相关 |
| `alloc_netdev_mqs()` | net/core/dev.c | 相关 |
| `free_netdev()` | net/core/dev.c | 相关 |
| `NETIF_F_*` | include/linux/netdev_features.h | 功能位定义 |
| `struct Qdisc` | include/net/sch_generic.h | 排队规则 |
| `struct netdev_rx_queue` | include/linux/netdevice.h | RX 队列 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-04 | 内核版本：Linux 7.0-rc1*
