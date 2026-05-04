# 110-bonding-team — Linux Bonding 和 Team 链路聚合深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**Bonding** 和 **Team** 是 Linux 的两种链路聚合技术——将多个物理网卡聚合成一个逻辑接口，提供冗余和带宽扩展。

**核心设计**：Bonding 通过 `struct bonding` 管理一组 `struct slave`，`bond_xmit_slave_id()` 根据模式（round-robin/active-backup/802.3ad 等）选择发送端口。802.3ad 模式通过 `bond_3ad_state_machine_handler()` 实现 LACP 协议。Team 通过 `struct team_mode_ops` 实现可插拔的负载均衡算法。

```
Bonding 发送路径：
  dev_queue_xmit(skb) → bond_start_xmit()
    → bond_xmit_slave_id(skb, bond, slave_id) @ bond_main.c:376
      → slave = bond->slave_ids[slave_id]   // 按模式选择端口
      → bond_dev_queue_xmit(slave->dev, skb) // 从选中端口发送

Team 架构：
  team_xmit() @ team_core.c
    → team->mode_ops->transmit()              // 可插拔模式
      → roundrobin/activebackup/loadbalance
```

**doom-lsp 确认**：bonding @ `drivers/net/bonding/bond_main.c`（6,659 行）。Team @ `drivers/net/team/team_core.c`（3,246 行）。

---

## 1. Bonding 核心结构

```c
// drivers/net/bonding/bonding.h
struct bonding {
    struct net_device *dev;                    // bond 设备
    struct slave *active_slave;                // 当前活动端口（AB 模式）
    struct slave **slave_ids;                  // slave ID 数组
    int slave_cnt;                              // slave 数量
    unsigned long mode;                         // 模式（BOND_MODE_ROUNDROBIN 等）
    spinlock_t mode_lock;

    struct bond_params params;
    struct bond_up_slave __rcu *usable_slaves; // 可用 slave
    struct bond_up_slave __rcu *all_slaves;

    struct ad_info ad;                          // 802.3ad 状态
};

struct slave {
    struct bonding *bond;                      // 所属 bond
    struct net_device *dev;                    // 物理端口
    struct slave *next;                         // slave 链表
    u32 speed;                                 // 端口速度
    u8 duplex;                                 // 双工模式
    u8 link;                                   // 链路状态
    unsigned long last_link_up;
};
```

---

## 2. 发送模式

```c
// Bonding 支持的 7 种模式：
#define BOND_MODE_ROUNDROBIN    0  // 轮询——逐包轮转端口
#define BOND_MODE_ACTIVEBACKUP  1  // 主备——活动+备份
#define BOND_MODE_XOR           2  // XOR——按 MAC 哈希选择
#define BOND_MODE_BROADCAST     3  // 广播——所有端口发送
#define BOND_MODE_8023AD        4  // 802.3ad——LACP 协议
#define BOND_MODE_TLB           5  // 自适应发送负载均衡
#define BOND_MODE_ALB           6  // 自适应负载均衡

// bond_start_xmit → bond_xmit_slave_id() @ bond_main.c:376
// → 按 mode 选择 slave：
//    ROUNDROBIN: slave = bond->slave_ids[bond->rr_tx_counter++ % slave_cnt]
//    ACTIVEBACKUP: slave = bond->active_slave
//    XOR: slave = bond->slave_ids[skb->hash % slave_cnt]
//    BROADCAST: 遍历所有 slave 发送
//    TLB/ALB: 按负载情况选择
```

---

## 3. 802.3ad（LACP）协议

```c
// bond_3ad.c — LACP 协议实现
// bond_3ad_state_machine_handler() — 周期性状态机：
// → 1. 通过 actor_port 和 partner_port 交换 LACPDU
// → 2. 根据对端状态更新端口聚合
// → 3. 协商成功后端口进入 COLLECTING_DISTRIBUTING 状态
// → 4. 链路故障时切换到其他端口

// struct port — 每个 slave 的 LACP 状态：
struct port {
    struct slave *slave;
    struct port_params partner;      // 对端参数
    struct port_params actor;        // 本端参数
    u16 actor_oper_port_key;
    u16 partner_admin_port_key;
    u8 sm_vars;                      // 状态机变量
};

## 4. Slave 管理

```c
// bond_enslave @ bond_main.c:1884 — 添加 slave：
// 1. ip link set eth0 master bond0
// → bond_enslave(bond_dev, slave_dev)
//   → 检查 slave 是否合法（不同设备、未 bond）
//   → 分配 slave 结构 → 初始化
//   → 设置 slave->dev 的 dev->features
//   → 更新 bond->slave_cnt + usable_slaves
//   → 如果 AB 模式且是第一个 slave → 设为 active_slave
//   → 调用 bond_mode->slave_add_cb()
//   → 发送 uevent BOND_EVENT_SLAVE_ADDED

// bond_release @ bond_main.c:2594 — 移除 slave：
// → __bond_release_one(bond_dev, slave_dev, ...)
//   → 停止相关定时器
//   → 从 slave_ids 移除
//   → 更新 active_slave（如果被移除的是活动端口）
//   → 发送 uevent BOND_EVENT_SLAVE_RELEASED
```

```

---

## 5. Team 架构

```c
// Team 相比 Bonding 的核心改进——可插拔模式：
struct team {
    struct net_device *dev;
    struct rcu_head rcu;

    const struct team_mode *mode;               // 当前模式
    struct team_mode_ops ops;                    // 模式操作
    struct list_head port_list;                  // 端口列表
};

struct team_mode_ops {
    netdev_tx_t (*transmit)(struct team *team, struct sk_buff *skb);
    int (*port_enter)(struct team *team, struct team_port *port);
    int (*port_leave)(struct team *team, struct team_port *port);
};

// team_xmit @ team_core.c:
// → team->ops.transmit(team, skb)  // 模式特定的发送函数
```

---

## 6. Bonding vs Team

| 特性 | Bonding | Team |
|------|---------|------|
| 内核版本 | 2.0+（成熟） | 3.11+（较新）|
| 代码量 | ~6,700 行 | ~3,200 行 |
| 负载均衡 | 内置 7 种模式 | 可插拔模式 |
| LACP | 802.3ad | libteam 用户空间 + 内核 |
| 配置工具 | `ip link` / `ifenslave` | `teamd` |

---

## 7. 调试

```bash
# Bonding
cat /proc/net/bonding/bond0
ip link show bond0

# Team
teamdctl <team> state
teamnl <team> ports
```

---

## 8. 关键函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `bond_start_xmit` | `bond_main.c` | bonding 发送入口 |
| `bond_xmit_slave_id` | `bond_main.c` | 按模式选择 slave |
| `bond_3ad_state_machine_handler` | `bond_3ad.c` | LACP 状态机 |
| `team_xmit` | `team_core.c` | team 发送入口 |

---

## 9. 总结

Bonding 提供 7 种内置模式（`bond_xmit_slave_id` 按模式选择 slave），802.3ad LACP 通过 `bond_3ad_state_machine_handler` 实现。Team 通过 `team_mode_ops` 实现可插拔发送算法。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*

## 10. 发送模式详解

```c
// 7 种模式的发送算法：

// BOND_MODE_ROUNDROBIN (0)：
//   slave = bond->slave_ids[bond->rr_tx_counter++ % slave_cnt]
//   每个连接数据包会在不同端口间轮转（可能乱序）

// BOND_MODE_ACTIVEBACKUP (1)：
//   slave = bond->active_slave（只有一个端口活动）
//   故障时切换到 backup slave（切换时间 < 1s）

// BOND_MODE_XOR (2)：
//   slave = bond->slave_ids[skb->hash % slave_cnt]
//   hash = (src_mac ^ dst_mac) % slave_cnt（同流同端口）
//   保证每个 TCP 连接走一个端口（不乱序）

// BOND_MODE_8023AD (4)：
//   使用 LACP 协议协商聚合
//   根据 actor/partner 的速率/双工选择活跃端口

// BOND_MODE_TLB (5)：
//   自适应发送负载均衡
//   根据每个 slave 的当前负载动态分配

// BOND_MODE_ALB (6)：
//   自适应负载均衡（发送+接收）
//   接收侧通过 ARP 协商更新 peer 的 ARP 缓存
```

## 11. 链路监控

```c
// 两种链路监控方式：

// MII 监控（推荐）：
//   bond->params.miimon = 100  // 每 100ms 检查一次
//   bond_mii_monitor() — 定时器周期检查
//   → 检查 slave->dev 的链路状态（netif_carrier_ok）
//   → 状态变化时触发 failover

// ARP 监控：
//   bond->params.arp_interval = 1000  // 每 1s 发一次 ARP
//   bond_arp_send_all() — 发送 ARP 请求到目标 IP
//   bond_arp_rcv() — 接收 ARP 响应
//   → 如果 arp_ip_target 无响应 → 标记为 DOWN

// 802.3ad 模式下使用 MII 监控（ARP 监控不支持）
```

## 12. bonding sysfs 接口

```c
// /sys/class/net/bond0/bonding/ 下的参数：
// mode          — 当前模式（可动态切换）
// slaves        — 所有 slave 列表
// active_slave  — 当前活动 slave
// miimon        — MII 监控间隔
// arp_interval  — ARP 监控间隔
// arp_ip_target — ARP 目标 IP
// updelay       — 启用延迟
// downdelay     — 停用延迟
// lacp_rate     — LACP 速率（slow/fast）

// 查看：
// cat /sys/class/net/bond0/bonding/mode
// cat /sys/class/net/bond0/bonding/slaves
```

## 13. Team 模式注册

```c
// Team 支持可插拔模式（用户空间加载）：
// team_mode_register(&roundrobin_mode_ops)
// → 注册 roundrobin 模式
// → mode_ops->transmit() 在 team_xmit 中调用

struct team_mode {
    const char *kind;                       // 模式名
    struct team_mode_ops ops;               // 操作函数
};

// 内建模式：
// roundrobin — 轮询（与 bonding RR 相同）
// activebackup — 主备
// loadbalance — 负载均衡（基于哈希）
```

## 14. 关键 doom-lsp 确认

```c
// bond_main.c:
// bond_xmit_slave_id @ :376  — 按模式选择 slave
// bond_enslave @ :1884        — 添加 slave
// bond_release @ :2594        — 移除 slave
// bond_mii_monitor            — MII 链路监控
// bond_arp_rcv                — ARP 监控接收

// bond_3ad.c:
// bond_3ad_state_machine_handler — LACP 状态机

// team_core.c:
// team_xmit                   — 统一发送入口
// team_mode_register           — 注册模式
```


## 15. 故障切换流程

```c
// 链路故障时的 failover 流程：
// 1. bond_mii_monitor() 检测到 slave 链路 DOWN
// 2. bond_set_slave_inactive_flags(slave)
// 3. 如果是 active_slave：
//    a. bond_select_active_slave() 选择新的 active
//    b. 更新 ARP 表（bond_arp_send_all 发送 gratuitous ARP）
//    c. 802.3ad → 发送 LACP PDU 通知对端
//    d. 发送 NETDEV_BONDING_FAILOVER uevent
// 4. 用户空间监控 uevent 可触发额外动作

// 恢复流程：
// 1. slave 链路恢复
// 2. bond_set_slave_active_flags(slave)
// 3. 如果 updelay 配置了 → 等待延迟时间
// 4. 重新加入活跃端口池
```


## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `bond_xmit_slave()` | drivers/net/bonding/bond_main.c | 主从发送 |
| `bond_arp_rcv()` | drivers/net/bonding/bond_main.c | ARP 监控 |
| `team_xmit()` | drivers/net/team/team_core.c | 组发送 |
| `struct bonding` | drivers/net/bonding/bond_main.c | 核心结构 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
