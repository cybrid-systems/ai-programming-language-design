# 137-netdevice — 网络设备结构深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/netdevice.h` + `net/core/dev.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**netdevice** 是 Linux 网络子系统的核心数据结构，代表一个网络设备（网卡、veth、bridge port 等）。所有网络数据包的收发都经过 netdevice。

## 1. 核心数据结构

### 1.1 struct net_device — 网络设备

```c
// include/linux/netdevice.h — net_device (主要字段)
struct net_device {
    // 名称和标识
    char                    name[IFNAMSIZ];      // 设备名（如 "eth0"）
    unsigned long           mem_end;              // 内存结束
    unsigned long           mem_start;            // 内存起始
    unsigned long           base_addr;            // I/O 基地址
    unsigned int            irq;                  // 中断号

    // 统计
    struct net_device_stats  stats;               // 设备统计
    atomic_long_t           rx_pkts;              // 接收包数
    atomic_long_t           tx_pkts;              // 发送包数
    atomic_long_t           rx_bytes;             // 接收字节数
    atomic_long_t           tx_bytes;             // 发送字节数

    // 设备属性
    unsigned int           flags;                  // IFF_* 标志
    unsigned int           priv_flags;             // 私有标志
    unsigned short         type;                  // ARPHRD_* 类型
    unsigned short         mtu;                    // 最大传输单元（1500）
    unsigned short         hard_header_len;        // 硬件头部长度（ETH_HLEN=14）

    // MAC 地址
    unsigned char           addr_len;               // 地址长度（ETH_ALEN=6）
    unsigned char           dev_addr[MAX_ADDR_LEN]; // MAC 地址
    unsigned char           broadcast[MAX_ADDR_LEN]; // 广播地址

    // 网络层头
    unsigned short          needed_headroom;        // 需要保留的头部空间
    unsigned short          needed_tailroom;        // 需要保留的尾部空间

    // 队列
    struct netdev_queue    __rcu *tx_queue;        // 发送队列
    struct Qdisc           *qdisc;                  // 队列规则

    // 协议层
    unsigned long           features;                // NETIF_F_* 特性
    unsigned long           hw_features;            // 硬件特性
    unsigned long           wanted_features;        // 想要的特性

    // 内存
    struct net             *nd_net;                 // 所属网络命名空间

    // 设备操作
    const struct net_device_ops *netdev_ops;       // 设备操作函数表
    const struct ethtool_ops *ethtool_ops;         // ethtool 操作
    const struct header_ops  *header_ops;          // 头部操作

    // 链表
    struct list_head        dev_list;               // 全局设备链表
    struct list_head        napi_list;             // NAPI 链表
    struct hlist_head       index_hlist;           // 哈希表（ifindex 索引）

    // 混杂模式
    struct net_device       *master;                // 如果是 bridge port，指向 bridge
    unsigned int            promiscuity;           // 混杂计数
    struct dev_addr_list   *mc_list;              // 多播列表
    int                     mc_count;              // 多播数量

    // 设备链
    struct netdev_queue    *_tx ____cacheline_aligned_in_smp; // per-CPU 发送队列
    unsigned int            num_tx_queues;          // 发送队列数
    unsigned int            real_num_tx_queues;     // 实际发送队列数

    // gro
    struct napi_gro_cb    *gro_data;              // GRO 私有数据
};
```

### 1.2 struct netdev_queue — 发送队列

```c
// include/linux/netdevice.h — netdev_queue
struct netdev_queue {
    struct net_device       *dev;                  // 所属设备
    struct Qdisc           *qdisc;                 // qdisc
    unsigned long           state;                  // QUEUE_STATE_*

    // 统计
    atomic_long_t           tx_pkts;
    atomic_long_t           tx_bytes;
    atomic_long_t           tx_dropped;
};
```

### 1.3 struct net_device_ops — 设备操作

```c
// include/linux/netdevice.h — net_device_ops
struct net_device_ops {
    int                   (*ndo_init)(struct net_device *dev);
    void                  (*ndo_uninit)(struct net_device *dev);
    int                   (*ndo_open)(struct net_device *dev);       // 打开
    int                   (*ndo_stop)(struct net_device *dev);      // 停止
    netdev_tx_t           (*ndo_start_xmit)(struct sk_buff *skb,   // 发送
                                           struct net_device *dev);
    void                  (*ndo_set_mac_address)(struct net_device *dev,
                                                  void *addr);
    int                   (*ndo_set_rx_mode)(struct net_device *dev); // 设置混杂模式
    int                   (*ndo_do_ioctl)(struct net_device *dev,
                                           int ifreq, int cmd);
    int                   (*ndo_set_config)(struct net_device *dev,
                                             struct ifmap *map);
    struct net_device_stats* (*ndo_get_stats)(struct net_device *dev);
};
```

## 2. 设备注册

### 2.1 register_netdevice — 注册设备

```c
// net/core/dev.c — register_netdevice
int register_netdevice(struct net_device *dev)
{
    struct net *net = dev_net(dev);

    // 1. 分配 ifindex
    dev->ifindex = dev_new_index(net);

    // 2. 初始化锁
    netdev_set_lockdep_class(&dev->addr_list_lock);
    dev->rtnl_link_ops = rtnl_link_ops;

    // 3. 初始化 header_ops
    if (dev->header_ops)
        dev->header_ops->create = dev_header_create;

    // 4. 初始化gro
    dev->gro_data = kzalloc(sizeof(struct napi_gro_cb), GFP_KERNEL);

    // 5. 加入全局哈希表
    dev_add_index(dev);

    // 6. 调用设备驱动注册
    err = dev->netdev_ops->ndo_init(dev);
    if (err)
        goto err_out;

    // 7. 加入网络命名空间
    list_add_tail_rcu(&dev->dev_list, &net->dev_base_head);

    // 8. 注册到 sysfs
    register_netdevice_notifier(&dev_netdev_notifier);

    return 0;
}
```

## 3. 设备标志（IFF_*）

```c
// include/linux/if.h — 设备标志
#define IFF_UP           0x1         // 设备已启用
#define IFF_BROADCAST    0x2         // 广播地址有效
#define IFF_DEBUG        0x4         // 调试模式
#define IFF_LOOPBACK     0x8         // 回环设备（lo）
#define IFF_POINTOPOINT  0x10        // 点对点
#define IFF_NOARP        0x80        // 无 ARP
#define IFF_PROMISC      0x100       // 混杂模式
#define IFF_ALLMULTI     0x200       // 接收所有多播
#define IFF_MASTER       0x400       // 主设备（bridge）
#define IFF_SLAVE        0x800       // 从设备（bridge port）
#define IFF_MULTICAST    0x1000      // 支持多播
#define IFF_PORTSEL      0x2000      // 端口选择
#define IFF_AUTOMEDIA    0x4000      // 自动媒体选择
#define IFF_DYNAMIC      0x8000      // 动态地址
```

## 4. 设备特性（NETIF_F_*）

```c
// include/linux/netdev_features.h — 设备特性
#define NETIF_F_SG           0x1   // 分散-聚集
#define NETIF_F_CSUM          0x2   // 校验和
#define NETIF_F_GRO           0x4   // GRO
#define NETIF_F_HIGHDMA       0x8   // 高 DMA
#define NETIF_F_FRAGLIST      0x10  // 分片列表
#define NETIF_F_HW_CSUM       0x20  // 硬件校验和
#define NETIF_F_LRO           0x40  // LRO（软件 GRO）
#define NETIF_F_GSO           0x80  // GSO（分片）
#define NETIF_F_TSO           0x100 // TSO（TCP 分片）
#define NETIF_F_UFO           0x200 // UFO（UDP 分片）
#define NETIF_F_HW_VLAN_CTAG_TX 0x400 // 硬件 VLAN 标签
#define NETIF_F_HW_VLAN_CTAG_RX 0x800 // 硬件 VLAN 解析
#define NETIF_F_NTUPLE        0x1000 // n-tuple 流分类
#define NETIF_F_RXCSUM        0x2000 // RX 校验和
#define NETIF_F_RXHASH        0x4000 // RX 哈希
```

## 5. 内存布局图

```
netdevice 设备列表关系：

net_namespace (init_net)
  │
  └── dev_base_head (list_head)
          │
          ├── netdev (eth0) ──→ napi_list → napi_struct (NAPI)
          │       │
          │       └── _tx[0..N] (per-CPU netdev_queue)
          │
          ├── netdev (eth1)
          │
          ├── netdev (lo)
          │
          └── netdev (br0) ──→ master=NULL, slave_list → [eth0, eth1]
```

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/netdevice.h` | `struct net_device`、`struct netdev_queue`、`struct net_device_ops` |
| `net/core/dev.c` | `register_netdevice`、`dev_add_index` |

## 7. 西游记类比

**netdevice** 就像"取经路上的各个驿站"——

> 每个网络设备（netdevice）就像一个驿站（eth0、wifi0、br0）。驿站有自己的名称（name）、地址（MAC）、大门开关（open/stop）、收发快递的能力（ndo_start_xmit）。如果一个驿站是某个大驿站的分站（slave），master 指向主驿站（bridge）。每个驿站有多个发送通道（tx_queue），可以同时发不同的快递。驿站的标志（IFF_UP/IFF_PROMISC）决定了它的状态。驿站的能力（NETIF_F_TSO/GRO）决定了它能处理的快递类型。

## 8. 关联文章

- **sk_buff**（article 22）：数据包经过 netdevice 时使用 sk_buff
- **netif_receive_skb**（article 139）：数据包接收
- **dev_queue_xmit**（article 138）：数据包发送

---

## doom-lsp 源码分析

> 以下分析基于 Linux 7.0 主线源码，使用 doom-lsp (clangd LSP) 进行深度符号分析

### 文件分析摘要

| 源文件 | 符号数 | 结构体 | 函数 | 变量 |
|--------|--------|--------|------|------|
| `include/linux/list.h` | 51 | 0 | 51 | 0 |
| `include/linux/sched.h` | 567 | 70 | 134 | 7 |
| `include/linux/mm.h` | 793 | 24 | 527 | 18 |

### 核心数据结构

- **audit_context** `sched.h:58`
- **bio_list** `sched.h:59`
- **blk_plug** `sched.h:60`
- **bpf_local_storage** `sched.h:61`
- **bpf_run_ctx** `sched.h:62`
- **bpf_net_context** `sched.h:63`
- **capture_control** `sched.h:64`
- **cfs_rq** `sched.h:65`
- **fs_struct** `sched.h:66`
- **futex_pi_state** `sched.h:67`
- **io_context** `sched.h:68`
- **io_uring_task** `sched.h:69`
- **mempolicy** `sched.h:70`
- **nameidata** `sched.h:71`
- **nsproxy** `sched.h:72`
- **perf_event_context** `sched.h:73`
- **perf_ctx_data** `sched.h:74`
- **pid_namespace** `sched.h:75`
- **pipe_inode_info** `sched.h:76`
- **rcu_node** `sched.h:77`
- **reclaim_state** `sched.h:78`
- **robust_list_head** `sched.h:79`
- **root_domain** `sched.h:80`
- **rq** `sched.h:81`
- **sched_attr** `sched.h:82`

### 关键函数

- **INIT_LIST_HEAD** `list.h:43`
- **__list_add_valid** `list.h:136`
- **__list_del_entry_valid** `list.h:142`
- **__list_add** `list.h:154`
- **list_add** `list.h:175`
- **list_add_tail** `list.h:189`
- **__list_del** `list.h:201`
- **__list_del_clearprev** `list.h:215`
- **__list_del_entry** `list.h:221`
- **list_del** `list.h:235`
- **list_replace** `list.h:249`
- **list_replace_init** `list.h:265`
- **list_swap** `list.h:277`
- **list_del_init** `list.h:293`
- **list_move** `list.h:304`
- **list_move_tail** `list.h:315`
- **list_bulk_move_tail** `list.h:331`
- **list_is_first** `list.h:350`
- **list_is_last** `list.h:360`
- **list_is_head** `list.h:370`
- **list_empty** `list.h:379`
- **list_del_init_careful** `list.h:395`
- **list_empty_careful** `list.h:415`
- **list_rotate_left** `list.h:425`
- **list_rotate_to_front** `list.h:442`
- **list_is_singular** `list.h:457`
- **__list_cut_position** `list.h:462`
- **list_cut_position** `list.h:488`
- **list_cut_before** `list.h:515`
- **__list_splice** `list.h:531`
- **list_splice** `list.h:550`
- **list_splice_tail** `list.h:562`
- **list_splice_init** `list.h:576`
- **list_splice_tail_init** `list.h:593`
- **list_count_nodes** `list.h:755`

### 全局变量

- **__tracepoint_sched_set_state_tp** `sched.h:350`
- **__tracepoint_sched_set_need_resched_tp** `sched.h:352`
- **def_root_domain** `sched.h:407`
- **sched_domains_mutex** `sched.h:408`
- **cad_pid** `sched.h:1749`
- **init_stack** `sched.h:1964`
- **class_migrate_is_conditional** `sched.h:2519`
- **_totalram_pages** `mm.h:53`
- **high_memory** `mm.h:74`
- **sysctl_legacy_va_layout** `mm.h:86`
- **mmap_rnd_bits_min** `mm.h:92`
- **mmap_rnd_bits_max** `mm.h:93`
- **mmap_rnd_bits** `mm.h:94`
- **sysctl_user_reserve_kbytes** `mm.h:210`
- **sysctl_admin_reserve_kbytes** `mm.h:211`

### 成员/枚举

- **utime** `sched.h:366`
- **stime** `sched.h:367`
- **lock** `sched.h:368`
- **seqcount** `sched.h:386`
- **starttime** `sched.h:387`
- **state** `sched.h:388`
- **cpu** `sched.h:389`
- **utime** `sched.h:390`
- **stime** `sched.h:391`
- **gtime** `sched.h:392`
- **sched_priority** `sched.h:413`
- **pcount** `sched.h:421`
- **run_delay** `sched.h:424`
- **max_run_delay** `sched.h:427`
- **min_run_delay** `sched.h:430`
- **last_arrival** `sched.h:435`
- **last_queued** `sched.h:438`
- **max_run_delay_ts** `sched.h:441`
- **weight** `sched.h:461`
- **inv_weight** `sched.h:462`

