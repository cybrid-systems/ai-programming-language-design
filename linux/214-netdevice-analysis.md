# 214-netdevice — struct net_device 核心结构分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/netdevice.h` + `net/core/dev.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照
> 内核版本：Linux 7.0-rc1 (2026 年)

## 0. 概述

`struct net_device` 是 Linux 网络子系统的核心数据结构，代表一个网络设备（物理网卡、veth pair、bridge port、loopback 等）。所有网络数据包的收发都经过 netdevice 节点。

本文聚焦于该结构的核心字段、队列模型、注册流程、操作方法集、统计体系和锁机制，结合 Linux 7.0-rc1 源码（最新主线）进行逐字段分析。

## 1. struct net_device 核心字段解析

### 1.1 name（设备名称）

```c
// include/linux/netdevice.h:2199
char name[IFNAMSIZ];  // IFNAMSIZ = 16
struct netdev_name_node *name_node;
```

- `name` 是设备的人类可读名称，如 `"eth0"`、`"lo"`、`"veth0"`。
- `IFNAMSIZ = 16`：Linux 定义的设备名最大长度（含结尾 `\0`）。
- `name_node` 是 `netdev_name_node` 结构指针，用于内核内部管理设备名查找（hash 表）。
- 设备名通过 `dev_get_valid_name()` 分配（`dev.c:11326`）。

```
struct netdev_name_node {
    struct hlist_node  hlist;      // hash 链表节点
    struct net_device *dev;        // 指向所属设备
    char               name[IFNAMSIZ];
    struct rcu_head    rcu;
};
```

### 1.2 dev_addr / perm_addr（MAC 地址）

```c
// include/linux/netdevice.h:1946
const unsigned char  *dev_addr;    // 运行时 MAC 地址（可更改）
// include/linux/netdevice.h:1948
unsigned char  perm_addr[MAX_ADDR_LEN];  // 永久 MAC 地址
unsigned char  addr_assign_type;        // 地址分配类型（NET_ADDR_*）
unsigned char  addr_len;                 // 地址长度（ETH_ALEN = 6）
```

- `dev_addr`：指向当前 MAC 地址的指针，运行时可修改（`ndo_set_mac_address`）。
- `perm_addr`：驱动烧录的永久地址，不随软件修改变化。
- `addr_assign_type` 标注地址来源：

| 值 | 含义 |
|---|---|
| `NET_ADDR_PERM` | 永久地址，驱动初始化时设置 |
| `NET_ADDR_STOLEN` | 从硬件偷取 |
| `NET_ADDR_DHCP` | 通过 DHCP 获得 |
| `NET_ADDR_RANDOM` | 随机生成 |

- `addr_len` 对以太网为 `ETH_ALEN = 6` 字节。

### 1.3 mac_header（协议头偏移）

```c
// include/linux/netdevice.h:1946（dev_addr 附近）
// 注：Linux 7.0 中 mac_header 已从 net_device 移除，
// 移至 struct sk_buff 的 mac_header 字段，
// 由 eth_type_trans() 在包接收时设置。
```

> **变化追踪**：早期内核中 `struct net_device` 包含 `unsigned char *mac_header` 指针字段。Linux 5.x+ 以后，该字段已从小甜甜（net_device）移至 `struct sk_buff`，避免每次收发包都访问 device 结构。

### 1.4 type（ARPHRD_* 设备类型）

```c
// include/linux/netdevice.h:2020
unsigned short type;  // ARPHRD_*，定义在 include/uapi/linux/if_arp.h
```

- `ARPHRD_ETHER = 1`：以太网
- `ARPHRD_LOOPBACK = 772`：loopback 设备
- `ARPHRD_VLAN = 802.1Q`
- `ARPHRD_TUNNEL = 776`：IP tunnel
- `type` 决定如何解析 MAC 头、是否使用 ARP 等。

### 1.5 mtu（最大传输单元）

```c
// include/linux/netdevice.h:2146
unsigned int mtu;  // read-mostly, 推荐用 READ_ONCE() 读取
```

- 默认 Ethernet `mtu = 1500`，jumbo frame 可达 9000。
- 驱动可动态修改：`ndo_change_mtu` 回调。
- **重要**：`mtu` 的读写通常不需要加锁，但写操作方（驱动）需持 `RTNL`。

### 1.6 flags（设备标志 IFF_*）

```c
// include/linux/netdevice.h:2160
unsigned int flags;  // IFF_* 标志位
```

常用标志：

| 标志 | 值 | 含义 |
|---|---|---|
| `IFF_UP` | 0x0001 | 设备已启用 |
| `IFF_BROADCAST` | 0x0002 | 广播地址有效 |
| `IFF_LOOPBACK` | 0x0008 | loopback 设备 |
| `IFF_POINTOPOINT` | 0x0010 | 点对点链路 |
| `IFF_RUNNING` | 0x0040 | 设备正在运行 |
| `IFF_NOARP` | 0x0080 | 无 ARP 协议 |
| `IFF_PROMISC` | 0x0100 | 混杂模式 |
| `IFF_ALLMULTI` | 0x0200 | 接收所有多播 |
| `IFF_MASTER` | 0x0400 | 主设备（bonding） |
| `IFF_SLAVE` | 0x0800 | 从设备 |

## 2. netdev_queue 结构（发送队列）

### 2.1 struct netdev_queue

```c
// include/linux/netdevice.h:676
struct netdev_queue {
// --- read-mostly part ---
    struct net_device *dev;
    struct Qdisc __rcu *qdisc;            // 排队规则
    struct Qdisc __rcu *qdisc_sleeping;   // 休眠时 Qdisc
    unsigned long    tx_maxrate;         // 最大发送速率
    atomic_long_t     trans_timeout;      // TX 超时计数

// --- write-mostly part ---
    struct dql       dql;                // Byte Queue Limits
    spinlock_t        _xmit_lock ____cacheline_aligned_in_smp;
    int               xmit_lock_owner;    // 锁持有者（进程 PID）
    unsigned long     trans_start;        // 上次发送时间（jiffies）

// --- slow/control path ---
    struct napi_struct *napi;             // NAPI 实例
    int                numa_node;        // NUMA 节点
} ____cacheline_aligned_in_smp;
```

关键字段解析：

- **`dev`**：指向所属 `net_device`。
- **`qdisc`**：指向 `struct Qdisc`（队列规则），控制包如何出队。
- **`_xmit_lock`**：发送路径的自旋锁，防止并发出队。**每个队列独立一把锁**。
- **`xmit_lock_owner`**：记录当前锁持有者的 PID，用于 `spin_is_locked()` 检测和死锁调试。
- **`trans_start`**：记录该队列最近一次发送的时间戳（jiffies），驱动或 NAPI 在每包发出后更新，用于 `netif_warn_QUEUE_TIMEOUT` 超时检测。
- **`napi`**：关联的 NAPI polling 实例，用于 TX completions 或低延迟轮询。

### 2.2 TX 队列在 net_device 中的组织

```c
// include/linux/netdevice.h:2139
struct netdev_queue *_tx;  // TX 队列数组指针

// include/linux/netdevice.h:2141
unsigned int real_num_tx_queues;  // 当前活跃 TX 队列数

// include/linux/netdevice.h:2143
unsigned int num_tx_queues;  // alloc_netdev_mq() 时分配的队列数
```

```
net_device
├── num_tx_queues = N     // 分配时的队列数（静态）
├── real_num_tx_queues    // 当前活跃队列数（可动态调整）
└── _tx --→ [ netdev_queue#0, netdev_queue#1, ..., netdev_queue#N-1 ]
```

- `_tx` 是动态分配的数组，通过 `alloc_netdev_mq()` 分配 `num_tx_queues` 个 `netdev_queue`。
- `real_num_tx_queues` 可通过 `netif_set_real_num_tx_queues()` 动态调整，但不超过 `num_tx_queues`。
- **Cache line 对齐**：`____cacheline_aligned_in_smp` 保证每个队列占满一个 cache line（避免 false sharing）。

## 3. 设备注册流程

### 3.1 register_netdevice() 核心流程

```
dev.c:11301 — int register_netdevice(struct net_device *dev)
```

流程图：

```
[Caller holds RTNL]
        │
        ▼
┌──────────────────────────────────────────────┐
│ 1. 检查 reg_state == NETREG_UNINITIALIZED    │ dev.c:11318
└──────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────┐
│ 2. ethtool_check_ops()                      │ dev.c:11322
│    验证驱动 ethtool 操作集有效性              │
└──────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────┐
│ 3. dev_get_valid_name() — 分配设备名         │ dev.c:11326
└──────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────┐
│ 4. netdev_name_node_head_alloc()             │ dev.c:11329
│    分配 name_node，插入内核 name hash 表     │
└──────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────┐
│ 5. ndo_init() — 驱动自定义初始化             │ dev.c:11333
│    如果 dev->netdev_ops->ndo_init 存在       │
└──────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────┐
│ 6. dev_index_reserve() — 申请 ifindex        │ dev.c:11348
│    从 net->dev_by_index xarray 分配唯一索引  │
└──────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────┐
│ 7. netdev_register_kobject()                 │ dev.c:11389
│    在 /sys/class/net/ 下创建设备 kobject     │
│    并初始化每个 txq 的 kobject               │
└──────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────┐
│ 8. 设置 reg_state = NETREG_REGISTERED        │ dev.c:11396
│    netdev_lock(dev) + WRITE_ONCE()           │
└──────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────┐
│ 9. __netdev_update_features()                │ dev.c:11401
│    合并 hw_features → features                │
└──────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────┐
│ 10. list_netdevice() — 加入全局设备链表       │ dev.c:11445
│     加入 net->dev_base_head + index_hlist    │
└──────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────┐
│ 11. add_device_randomness()                 │ dev.c:11447
│     用 MAC 地址熵填充 /dev/random 池          │
└──────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────┐
│ 12. call_netdevice_notifiers(NETDEV_REGISTER)│ dev.c:11455
│     通知订阅者（TCP/IP 协议栈等）             │
└──────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────┐
│ 13. rtmsg_ifinfo() → 发送 rtnetlink 消息     │ dev.c:11462
│     通知用户空间（iproute2 等工具）           │
└──────────────────────────────────────────────┘
```

### 3.2 list_netdevice() — 加入全局设备链表

```c
// dev.c:407 — static void list_netdevice(struct net_device *dev)
struct net *net = dev_net(dev);

ASSERT_RTNL();

list_add_tail_rcu(&dev->dev_list, &net->dev_base_head);  // 加入 netns 设备链表
netdev_name_node_add(net, dev->name_node);                 // 加入 name hash 表
hlist_add_head_rcu(&dev->index_hlist,
                   dev_index_hash(net, dev->ifindex));    // 加入 index hash 表

/* altname 也一并加入 */
netdev_for_each_altname(dev, name_node)
    netdev_name_node_add(net, name_node);
```

- `dev_list`：按注册顺序链接所有 `net_device`，是 `for_each_netdev()` 遍历的基础。
- `index_hlist`：按 `ifindex` 组织，用于 `dev_get_by_index()` 快速查找。
- **RCU 操作**：所有链表操作使用 `*_rcu` 变体，配合 `rcu_barrier()` 在释放前保证 grace period。

### 3.3 设备注册状态机（reg_state）

```c
// include/linux/netdevice.h:1791
enum netdev_reg_state {
    NETREG_UNINITIALIZED = 0,  // 初始状态，register_netdevice() 前
    NETREG_REGISTERED,         // 注册成功
    NETREG_UNREGISTERING,      // 正在注销（unregister_netdevice 调用中）
    NETREG_UNREGISTERED,       // 已从链表移除，等待 free_netdev()
    NETREG_RELEASED,           // 已调用 free_netdev()
    NETREG_DUMMY,              // 虚拟 Dummy NAPI 设备
};
```

```
    alloc_netdev_mq()
           │
           ▼
    NETREG_UNINITIALIZED ──────► register_netdevice()
           │                          │
           │                          ▼
           │                  NETREG_REGISTERED
           │                          │
           │                          ▼
           │               unregister_netdevice()
           │                          │
           │                          ▼
           │               NETREG_UNREGISTERING
           │                          │
           │                          ▼
           │               NETREG_UNREGISTERED
           │                          │
           │                          ▼
           │                  free_netdev()
           │                          │
           ▼                          ▼
    NETREG_RELEASED ◄─────────────────┘
```

## 4. 设备操作方法集（net_device_ops）

### 4.1 struct net_device_ops

```c
// include/linux/netdevice.h:1436
struct net_device_ops {
    int         (*ndo_init)         (struct net_device *dev);
    void        (*ndo_uninit)       (struct net_device *dev);
    int         (*ndo_open)         (struct net_device *dev);
    int         (*ndo_stop)         (struct net_device *dev);

    netdev_tx_t (*ndo_start_xmit)  (struct sk_buff *skb,
                                    struct net_device *dev);
    netdev_features_t (*ndo_features_check)(struct sk_buff *skb,
                                             struct net_device *dev,
                                             netdev_features_t features);
    u16         (*ndo_select_queue)(struct net_device *dev,
                                    struct sk_buff *skb,
                                    struct net_device *sb_dev);
    void        (*ndo_set_rx_mode) (struct net_device *dev);
    int         (*ndo_set_mac_address)(struct net_device *dev, void *addr);
    int         (*ndo_validate_addr)(struct net_device *dev);
    int         (*ndo_change_mtu)   (struct net_device *dev, int new_mtu);
    void        (*ndo_tx_timeout)  (struct net_device *dev,
                                    unsigned int txqueue);
    // ... 还有百余个回调
};
```

### 4.2 ndo_start_xmit（发送数据包）

```c
// include/linux/netdevice.h:1441
netdev_tx_t (*ndo_start_xmit)(struct sk_buff *skb,
                              struct net_device *dev);

// include/linux/netdevice.h:131
enum netdev_tx {
    __NETDEV_TX_MIN    = INT_MIN,
    NETDEV_TX_OK       = 0x00,   // 发送成功，skb 已释放
    NETDEV_TX_BUSY     = 0x10,   // 发送忙碌，skb 应保留并重新入队
};
typedef enum netdev_tx netdev_tx_t;
```

**典型驱动实现**：

```c
static netdev_tx_t
my_driver_start_xmit(struct sk_buff *skb, struct net_device *dev)
{
    /* 获取队列 */
    struct netdev_queue *txq = netdev_get_tx_queue(dev, skb->queue_mapping);

    /* 检查 txq 是否停止（qdisc 满） */
    if (netif_tx_queue_stopped(txq))
        return NETDEV_TX_BUSY;

    /* 更新 trans_start */
    txq->trans_start = jiffies;

    /* 写硬件 DMA 描述符 ... */
    dma_map_single(...);
    writel(DESC_REG, tx_desc_ptr);

    return NETDEV_TX_OK;
}
```

**返回值语义**：

| 返回值 | 含义 |
|---|---|
| `NETDEV_TX_OK` | 发送完成，skb 由驱动释放 |
| `NETDEV_TX_BUSY` | 硬件忙，qdisc 应重新入队，稍后重试 |

### 4.3 ndo_open / ndo_stop（打开和关闭设备）

```c
// include/linux/netdevice.h:1439
int (*ndo_open)(struct net_device *dev);    // 启用设备
int (*ndo_stop)(struct net_device *dev);  // 关闭设备
```

- `ndo_open`：分配 IRQ、注册中断处理函数、启动 NAPI、设置 `IFF_UP`，在 `ip link set eth0 up` 时调用。
- `ndo_stop`：停止 NAPI、关闭硬件、释放 IRQ，调用路径是 `dev_close()` → `ndo_stop()`。
- 两者的保护：`netdev_lock()` 覆盖实例锁，防止与 `ndo_start_xmit` 并发。

### 4.4 ndo_tx_timeout（发送超时）

```c
// include/linux/netdevice.h:1476
void (*ndo_tx_timeout)(struct net_device *dev, unsigned int txqueue);
```

- 当 `trans_start` 距今超过 `watchdog_timeo` jiffies 时，`dev_watchdog()` timer 触发。
- 典型处理：打印统计、打印队列状态、调用 `netif_tx_queue_stopped()` 等。
- `watchdog_timer` 定义在 `net_device:2260`。

## 5. 统计信息（stats / pcpu stats）

### 5.1 传统 struct net_device_stats

```c
// include/linux/netdevice.h:193
#define NET_DEV_STAT(FIELD)           \
    union {                            \
        unsigned long FIELD;           \
        atomic_long_t __##FIELD;       \  // 原子版本用于热路径
    }

struct net_device_stats {
    NET_DEV_STAT(rx_packets);    // 收到的包数
    NET_DEV_STAT(tx_packets);    // 发送的包数
    NET_DEV_STAT(rx_bytes);      // 收到的字节数
    NET_DEV_STAT(tx_bytes);      // 发送的字节数
    NET_DEV_STAT(rx_errors);     // 接收错误总数
    NET_DEV_STAT(tx_errors);     // 发送错误总数
    NET_DEV_STAT(rx_dropped);     // 接收丢弃数
    NET_DEV_STAT(tx_dropped);     // 发送丢弃数
    NET_DEV_STAT(multicast);      // 多播包数
    NET_DEV_STAT(collisions);     // MAC 层冲突数
    NET_DEV_STAT(rx_length_errors);
    NET_DEV_STAT(rx_crc_errors);
    NET_DEV_STAT(rx_frame_errors);
    NET_DEV_STAT(rx_fifo_errors);
    NET_DEV_STAT(tx_aborted_errors);
    NET_DEV_STAT(tx_carrier_errors);
    NET_DEV_STAT(tx_fifo_errors);
    // ...
};
```

> **注意**：`NET_DEV_STAT` 使用 `union` 同时提供原子操作接口（`__rx_packets`）和常规接口（`rx_packets`），热路径可直接 `atomic_long_inc(&dev->stats.__rx_packets)` 而无需加锁。

### 5.2 现代 per-CPU 统计（pcpu_*stats）

```c
// include/linux/netdevice.h:2163
union {
    struct pcpu_lstats __percpu      *lstats;     // 本地统计（loopback 等）
    struct pcpu_sw_netstats __percpu *tstats;     // 发送/接收统计
    struct pcpu_dstats __percpu      *dstats;     // driver 统计
};

enum netdev_stat_type pcpu_stat_type:8;
```

- Linux 7.0 鼓励驱动使用 `pcpu_sw_netstats`（`struct pcpu_sw_netstats`），每个 CPU 独立的计数器，零争用。
- `lstats`/`tstats`/`dstats` 三选一，通过 `netdev_setup_tstats()` 初始化。

## 6. 锁机制（dev_lock / xmit_lock）

### 6.1 netdev_lock — 实例级 mutex

```c
// include/linux/netdevice.h:2816
static inline void netdev_lock(struct net_device *dev)
{
    mutex_lock(&dev->lock);
}
static inline void netdev_unlock(struct net_device *dev)
{
    mutex_unlock(&dev->lock);
}
```

- `dev->lock` 是一个 `struct mutex`，保护 `net_device` 的小部分字段。
- **Linux 7.0 的新设计**：`dev->lock` 的保护范围由 `netdev_need_ops_lock()` 决定：

```
netdev_lock 保护的字段（Simply protected — 只要 dev->lock）：
  - @gro_flush_timeout, @napi_defer_hard_irqs, @napi_list
  - @net_shaper_hierarchy, @reg_state, @threaded

双保护的字段（writers hold both locks, readers hold either）：
  - @up, @moving_ns, @nd_net, @xdp_features

需要 ops_lock 的字段（由 netdev_lock 或 rtnl_lock 保护）：
  - 大部分 ndo_* 回调的执行期间
```

- 驱动可在 `ndo_open` / `ndo_stop` / `ndo_start_xmit` 执行期间依赖 `netdev_lock` 的保护。

### 6.2 _xmit_lock — 队列级自旋锁

```c
// include/linux/netdevice.h:709（netdev_queue 结构内）
spinlock_t _xmit_lock ____cacheline_aligned_in_smp;
int xmit_lock_owner;
```

```c
// dev.c:4781 — 典型加锁路径（__dev_queue_xmit）
spin_lock(&txq->_xmit_lock);
// ... 发送逻辑 ...
spin_unlock(&txq->_xmit_lock);
```

**特点**：
- **每队列独立锁**：不同 TX 队列可真正并行，无全局竞争。
- **`xmit_lock_owner`**：记录当前持锁线程（PID），用于 lockdep 和调试 `spin_is_locked()`。
- **`____cacheline_aligned_in_smp`**：确保锁变量独占一个 cache line，消除 false sharing。
- 锁粒度：**每包一次**（packet-level），而非每事务一次。

### 6.3 全局锁（RTNL）

```c
// 网络配置变更（设备添加/删除、地址设置、MTU 修改）需要持 RTNL
// register_netdevice() 调用链：
ASSERT_RTNL();  // dev.c:11318，必须持 RTNL 才能调用
```

- `rtnl_lock()` 是全局 mutex，序列化所有网络设备配置操作。
- `register_netdevice()` 在整个注册期间持有 `RTNL`。

### 6.4 锁层次总结

```
优先级：RTNL > netdev_lock > _xmit_lock

RTNL (全局配置锁)
   │
   ├─ register_netdevice() / unregister_netdevice()
   ├─ ndo_set_mac_address()
   ├─ ndo_change_mtu()
   └─ ndo_set_rx_mode()
          │
          ▼
netdev_lock (实例锁，per-device)
   │
   ├─ ndo_open() / ndo_stop()
   ├─ ndo_start_xmit()（部分驱动）
   └─ netdev notifier 链回调
          │
          ▼
_xmit_lock (队列锁，per-queue)
   │
   └─ __dev_queue_xmit()（每个包的发送路径）
```

## 7. 数据结构全貌

```
struct net_device
│
├── [TX Read-Mostly Hotpath — cacheline group]
│   ├── unsigned long  priv_flags    :32    // 私有标志位
│   ├── unsigned long  lltx                   // lockless TX（已废弃）
│   ├── const struct net_device_ops *netdev_ops
│   ├── const struct header_ops *header_ops
│   ├── struct netdev_queue *_tx[]           // TX 队列数组
│   ├── unsigned int  real_num_tx_queues     // 活跃 TX 队列数
│   ├── netdev_features_t gso_partial_features
│   └── unsigned int  mtu                    // 最大传输单元
│
├── [TXRX Read-Mostly Hotpath]
│   ├── union { pcpu_lstats/pcpu_sw_netstats/pcpu_dstats }  // per-CPU 统计
│   ├── unsigned int  flags                  // IFF_UP/IFF_RUNNING/...
│   ├── unsigned short hard_header_len       // ETH_HLEN = 14
│   ├── netdev_features_t features           // 启用特性（NETIF_F_*）
│   └── struct inet6_dev __rcu *ip6_ptr      // IPv6 信息
│
├── [RX Read-Mostly Hotpath]
│   ├── struct bpf_prog __rcu *xdp_prog      // XDP 程序
│   ├── int ifindex                          // 设备索引号
│   ├── struct netdev_rx_queue *_rx[]        // RX 队列数组
│   └── rx_handler_func_t __rcu *rx_handler  // 接收处理器（bridge/vlan）
│
├── [设备标识]
│   ├── char name[IFNAMSIZ]                  // 设备名 "eth0"
│   ├── unsigned short type                  // ARPHRD_ETHER 等
│   └── unsigned char addr_len               // ETH_ALEN = 6
│
├── [MAC 地址]
│   ├── const unsigned char *dev_addr        // 运行时 MAC 地址
│   ├── unsigned char perm_addr[MAX_ADDR_LEN]
│   ├── unsigned char addr_assign_type       // NET_ADDR_PERM/DHCP/RANDOM
│   └── unsigned char broadcast[MAX_ADDR_LEN]
│
├── [链表节点]
│   ├── struct list_head dev_list            // net->dev_base_head 链表
│   ├── struct list_head napi_list           // 属于本设备的 NAPI 实例列表
│   ├── struct list_head unreg_list          // 注销链表
│   └── struct hlist_node index_hlist       // ifindex hash 表节点
│
├── [统计]
│   ├── struct net_device_stats stats        // 传统（过时）统计
│   ├── union { ... } *tstats/lstats/dstats  // 现代 per-CPU 统计
│   └── atomic_t carrier_up/down_count
│
├── [锁]
│   ├── struct mutex lock                    // 实例锁（netdev_lock）
│   ├── spinlock_t addr_list_lock            // 地址列表锁
│   └── spinlock_t tx_global_lock            // TX 全局锁（qdisc 用）
│
├── [注册状态]
│   ├── u8 reg_state                         // NETREG_* 状态机
│   └── bool needs_free_netdev
│
├── [协议特定指针]
│   ├── struct in_device __rcu *ip_ptr        // IPv4 信息
│   ├── struct inet6_dev __rcu *ip6_ptr
│   ├── struct vlan_info __rcu *vlan_info
│   └── struct net_device *master           // bonding master
│
└── [私有数据]
    └── void *priv / *ml_priv               // 驱动私有数据
```

## 8. 关键代码片段

### 8.1 设备注册完整检查（dev.c:11318）

```c
int register_netdevice(struct net_device *dev)
{
    // ...
    BUG_ON(dev->reg_state != NETREG_UNINITIALIZED);  // 必须是初始状态
    BUG_ON(!net);                                     // 必须属于某个 netns

    ret = ethtool_check_ops(dev->ethtool_ops);
    if (ret)
        return ret;

    spin_lock_init(&dev->addr_list_lock);
    netdev_set_addr_lockdep_class(dev);  // 设置 lockdep class

    ret = dev_get_valid_name(net, dev, dev->name);  // 分配设备名
    // ...
    ret = dev_index_reserve(net, dev->ifindex);  // 分配 ifindex

    // 设置 reg_state
    netdev_lock(dev);
    WRITE_ONCE(dev->reg_state, ret ? NETREG_UNREGISTERED : NETREG_REGISTERED);
    netdev_unlock(dev);

    list_netdevice(dev);  // 加入全局设备链表
    // ...
}
```

### 8.2 TX 超时检测（dev.c:watchdog_timer）

```c
static void dev_watchdog(struct timer_list *t)
{
    struct net_device *dev = from_timer(dev, t, watchdog_timer);

    for (each queue i) {
        txq = netdev_get_tx_queue(dev, i);
        if (txq->trans_start + dev->watchdog_timeo < jiffies) {
            // 触发 ndo_tx_timeout
            dev->netdev_ops->ndo_tx_timeout(dev, i);
        }
    }
}
```

## 9. 参考文献

- `include/linux/netdevice.h` — Linux 7.0-rc1，struct net_device 定义（行 2124 起）
- `include/linux/netdevice.h` — struct netdev_queue 定义（行 676 起）
- `include/linux/netdevice.h` — enum netdev_reg_state（行 1791 起）
- `include/linux/netdevice.h` — struct net_device_ops（行 1436 起）
- `include/linux/netdevice.h` — struct net_device_stats（行 193 起）
- `include/linux/netdevice.h` — netdev_lock / netdev_unlock（行 2816 起）
- `net/core/dev.c` — register_netdevice() 完整实现（行 11301 起）
- `net/core/dev.c` — list_netdevice()（行 407 起）
- `net/core/dev.c` — netdev_lock_type[]（行 477 起，注释说明 _xmit_lock 初始化）
- `Documentation/networking/net_cachelines/net_device.rst` — cacheline 分组文档


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

