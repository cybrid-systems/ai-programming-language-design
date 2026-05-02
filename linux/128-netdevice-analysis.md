# 128-netdevice — Linux 网络设备核心深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**netdevice** 是 Linux 网络设备核心层——`struct net_device` 是网络设备在内核中的抽象，包含设备名称、索引、操作表（`net_device_ops`）、特征标志等。驱动通过 `alloc_netdev()` + `register_netdevice()` 注册设备到内核网络栈。

**核心设计**：每个网络设备对应一个 `struct net_device`，通过 `net_device_ops` 实现发送、接收、配置等操作。`register_netdevice()` 将设备加入系统全局的 `dev_base_head` 链表和 `dev_name_head` 哈希表，使其对用户空间可见。

**doom-lsp 确认**：`net/core/dev.c` 是核心实现文件。

---

## 1. 核心数据结构

```c
// include/linux/netdevice.h
struct net_device {
    char name[IFNAMSIZ];                         // 设备名（eth0, wlan0）
    unsigned int flags;                           // IFF_UP, IFF_BROADCAST, IFF_MULTICAST
    unsigned int features;                        // 设备特征（NETIF_F_*）
    unsigned int mtu;                              // MTU
    unsigned short type;                           // ARPHRD_ETHER 等

    int ifindex;                                   // 接口索引（唯一）
    struct net_device_stats stats;                 // 统计

    const struct net_device_ops *netdev_ops;       // 操作表
    const struct header_ops *header_ops;           // 头部操作

    struct netdev_rx_queue *_rx;                   // 接收队列
    struct netdev_queue *_tx ____cacheline_aligned; // 发送队列
    unsigned int num_tx_queues;

    struct list_head dev_list;                     // 设备链表
    struct list_head napi_list;                    // NAPI 链表
};

struct net_device_ops {
    int (*ndo_open)(struct net_device *dev);        // 接口启用
    int (*ndo_stop)(struct net_device *dev);        // 接口停用
    netdev_tx_t (*ndo_start_xmit)(struct sk_buff *skb, struct net_device *dev);
    int (*ndo_set_rx_mode)(struct net_device *dev);
    int (*ndo_set_mac_address)(struct net_device *dev, void *addr);
    int (*ndo_do_ioctl)(struct net_device *dev, struct ifreq *ifr, int cmd);
    int (*ndo_change_mtu)(struct net_device *dev, int new_mtu);
};
```

---

## 2. 设备注册

```c
// alloc_netdev(sizeof_priv, name, name_assign_type, setup)
// → 分配 net_device + 私有数据
// → 调用 setup 函数初始化默认值

// register_netdevice(dev) @ net/core/dev.c
// → 0. 检查有效性
// → 1. dev_get_valid_name(dev, dev->name) 分配名称
// → 2. 分配 ifindex（dev_new_index）
// → 3. list_add_rcu(&dev->dev_list, &dev_base_head)
// → 4. hlist_add_head_rcu(&dev->name_hlist, dev_name_hash(net, dev->name))
// → 5. netdev_queue_init(dev) 初始化发送队列
// → 6. call_netdevice_notifiers(NETDEV_REGISTER, dev)
// → 7. dev->reg_state = NETREG_REGISTERED

// 注销：unregister_netdevice(dev)
// → NETDEV_UNREGISTER 通知 → 从链表移除 → 释放
```

---

## 3. 关键函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `alloc_netdev_mqs` | `dev.c` | 分配 net_device |
| `register_netdevice` | `dev.c` | 注册设备到系统 |
| `unregister_netdevice` | `dev.c` | 注销设备 |
| `dev_open` | `dev.c` | 启用接口（调用 ndo_open）|
| `dev_close` | `dev.c` | 停用接口 |
| `dev_queue_xmit` | `dev.c` | 发送数据包入口 |

---

## 4. 调试

```bash
# 查看所有网络设备
ip link show
cat /proc/net/dev

# 查看设备统计
cat /sys/class/net/eth0/statistics/tx_packets

# 查看特征
ethtool -k eth0
```

---

## 5. 总结

`struct net_device` 是 Linux 网络设备的统一抽象。驱动通过 `alloc_netdev` + `register_netdevice` 注册设备，`net_device_ops` 定义操作。`dev_queue_xmit` 是发送入口，`netif_rx`/`napi_gro_receive` 是接收入口。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*
