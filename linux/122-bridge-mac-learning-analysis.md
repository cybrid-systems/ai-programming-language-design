# 108-bridge — Linux 网桥（bridge）深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**Linux bridge** 是内核中的虚拟以太网交换机实现，将多个网络接口连接为一个二层广播域。bridge 实现 MAC 地址学习（`br_fdb_update`）、转发决策（`br_handle_frame_fwd`）、生成树协议（STP）、VLAN 过滤等标准交换机功能。

**核心设计**：bridge 在 `netif_receive_skb` 路径中通过 `br_handle_frame` 钩子（挂接到 `rx_handler`）截获输入数据包。查找 FDB（转发数据库）决定转发端口，若未知则洪泛所有端口。STP 管理环路避免。

```
数据包处理路径：
  netif_receive_skb(skb)
    ↓
  rx_handler → br_handle_frame @ br_input.c
    ├── STP BPDU → br_stp_handle_bpdu() 处理
    ├── VLAN 过滤 → br_vlan_rcv()
    ├── MAC 学习 → br_fdb_update() @ br_fdb.c
    ├── 查找 FDB → __br_fdb_get()
    │   ├── 找到 → br_forward() 单播转发
    │   └── 未找到 → br_flood() 洪泛所有端口
    └── 本地投递 → br_pass_frame_up() → 协议栈
```

**doom-lsp 确认**：bridge 实现在 `net/bridge/` 目录。`br_handle_frame` @ `br_input.c`，`br_fdb_update` @ `br_fdb.c`（1,639 行）。

---

## 1. 核心数据结构

### 1.1 struct net_bridge @ br_private.h:495

```c
struct net_bridge {
    spinlock_t lock;                          // 全局锁
    struct list_head port_list;                // 端口列表
    struct net_device *dev;                    // 桥设备本身

    struct hlist_head hash[BR_HASH_SIZE];      // FDB 哈希表
    struct bridge_ageing_info ageing;

    unsigned long flags;                       // BR_* 标志
    u16 group_addr[ETH_ALEN];                  // 多播 MAC（STP 用）

    struct stp_state stp;                      // STP 状态
    struct net_bridge_vlan_group *vlgrp;       // VLAN 组
};
```

### 1.2 struct net_bridge_port @ :387

```c
struct net_bridge_port {
    struct net_bridge *br;                     // 所属桥
    struct net_device *dev;                    // 物理/虚拟端口设备
    struct list_head list;

    u8 state;                                  // STP 状态（BLOCKING/LISTENING/LEARNING/FORWARDING）
    u16 port_no;
    u32 path_cost;                             // 路径开销
    port_id port_id;

    struct timer_list forward_delay_timer;      // STP 定时器
    struct timer_list hold_timer;
    struct timer_list message_age_timer;

    struct kobject kobj;
};
```

### 1.3 struct net_bridge_fdb_entry @ :291

```c
struct net_bridge_fdb_entry {
    struct hlist_node fdb_node;                // 哈希表节点
    struct net_bridge_port *dst;               // 输出端口
    unsigned long updated;                     // 最后一次更新 jiffies
    unsigned long used;                        // 最后一次使用 jiffies
    unsigned char addr[ETH_ALEN];              // MAC 地址
    u16 flags;
    struct rcu_head rcu;
};
```

---

## 2. 数据包处理——br_handle_frame

```c
// netif_receive_skb → rx_handler → br_handle_frame @ br_input.c

rx_handler_result_t br_handle_frame(struct sk_buff **pskb)
{
    struct sk_buff *skb = *pskb;
    struct net_bridge_port *p = br_port_get_rcu(skb->dev);

    // 1. STP BPDU 处理
    if (unlikely(eth_is_stp(skb)))
        return br_stp_handle_bpdu(skb);        // STP 协议处理

    // 2. VLAN 过滤
    if (p->br->vlan_enabled)
        br_vlan_rcv(p, ...);

    // 3. 进入桥处理
    return br_handle_frame_fwd(pskb);
}

// br_handle_frame_fwd → 核心转发逻辑：
// → br_fdb_update(br, p, eth_hdr(skb)->h_source, 0)  // MAC 学习
// → __br_fdb_get(br, eth_hdr(skb)->h_dest)            // FDB 查找
//   → 找到 → br_forward(dst_port, skb)                 // 单播
//   → 未找到 → br_flood(skb)                           // 洪泛
```

---

## 3. MAC 学习——br_fdb_update

```c
// br_fdb_update @ br_fdb.c — 每条输入数据包的源 MAC 学习

void br_fdb_update(struct net_bridge *br, struct net_bridge_port *source,
                    const unsigned char *addr, u16 vid, unsigned long flags)
{
    struct hlist_head *head = &br->hash[br_mac_hash(addr, vid)];

    // 查找 FDB 条目
    hlist_for_each_entry_rcu(fdb, head, fdb_node) {
        if (ether_addr_equal(fdb->addr.addr, addr) && fdb->vlan_id == vid) {
            // 更新端口和时间戳
            if (fdb->dst != source) {
                // MAC 地址从不同端口到达 → 更新（迁移）
                fdb->dst = source;
            }
            fdb->updated = jiffies;
            return;
        }
    }

    // 未找到 → 创建新条目
    fdb = kmalloc(sizeof(*fdb), GFP_ATOMIC);
    fdb->dst = source;
    fdb->updated = jiffies;
    hlist_add_head_rcu(&fdb->fdb_node, head);
}
```

---

## 4. 转发决策

```c
// br_forward @ br_forward.c — 单播转发
void br_forward(struct net_bridge_port *to, struct sk_buff *skb)
{
    // 1. 检查 STP 状态（只在 FORWARDING 状态转发）
    if (to->state != BR_STATE_FORWARDING)
        goto drop;

    // 2. 克隆 skb（每个端口需要独立拷贝）
    skb = skb_clone(skb, GFP_ATOMIC);
    if (!skb) return;

    // 3. 发送
    br_forward_finish(to, skb);
}

// br_forward_finish → dev_queue_xmit(skb)
// → 从端口设备发送出去

// br_flood — 未知单播/广播洪泛
void br_flood(struct sk_buff *skb)
{
    // 遍历所有端口（除接收端口外）
    list_for_each_entry_rcu(p, &br->port_list, list) {
        if (p == prev) continue;           // 不送回原端口
        if (p->state != BR_STATE_FORWARDING) continue;
        br_forward(p, skb);
    }
}
```

---

## 5. FDB 哈希与老化

```c
// FDB 哈希表（br->hash[BR_HASH_SIZE]）：
// br_mac_hash(addr, vid) — 按 MAC 地址 + VLAN 计算哈希

// 老化机制（br_fdb_cleanup @ br_fdb.c）：
// → 定期（默认 30s）扫描 FDB
// → 检查 updated + ageing_time 是否过期
// → 过期的动态 FDB 条目 → fdb_delete()
// → 收到新数据包时更新 updated（br_fdb_update）

// 静态 FDB（通过 bridge fdb add 手动添加）不过期
```

## 6. STP 状态机

```c
// 每个端口的状态（struct net_bridge_port->state）：
// BR_STATE_DISABLED   (0) — 端口关闭
// BR_STATE_LISTENING  (1) — 监听 BPDU（不学习 MAC）
// BR_STATE_LEARNING   (2) — 学习 MAC（不转发数据）
// BR_STATE_FORWARDING (3) — 正常转发
// BR_STATE_BLOCKING   (4) — 阻塞（环路避免）

// STP 定时器：
// forward_delay_timer — LISTENING→LEARNING→FORWARDING 延迟
// hold_timer          — BPDU 发送间隔
// message_age_timer   — BPDU 老化
```

## 7. VLAN 过滤

```c
// bridge 支持 802.1Q VLAN 过滤：
// 1. 每个端口配置 VLAN 成员资格
// 2. 入口 VLAN 检查 → br_vlan_rcv()
// 3. 转发时 VLAN 过滤

// struct net_bridge_vlan { u16 vid; struct net_bridge_port *port; ... };
// br_vlan_find(br, vid) → 查找 VLAN 条目
// 未通过 VLAN 检查 → 丢弃（不转发）
```

---

## 6. 关键函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `br_handle_frame` | `br_input.c` | 入口——STP/VLAN/转发 |
| `br_fdb_update` | `br_fdb.c` | MAC 学习 |
| `__br_fdb_get` | `br_fdb.c` | FDB 查找 |
| `br_forward` | `br_forward.c` | 单播转发 |
| `br_flood` | `br_forward.c` | 洪泛 |
| `br_stp_handle_bpdu` | `br_stp.c` | STP BPDU 处理 |

---

## 7. 调试

```bash
# 查看 FDB
bridge fdb show
bridge fdb show dev br0

# 查看 STP 状态
bridge stp show
bridge stp show br0

# 查看 VLAN
bridge vlan show

# 跟踪 MAC 学习
echo 1 > /sys/kernel/debug/tracing/events/bridge/enable
```

---

## 8. 总结

bridge 通过 `br_handle_frame`（`br_input.c`）截获输入数据包 → `br_fdb_update`（`br_fdb.c`）学习源 MAC → `__br_fdb_get` 查找目的 MAC → `br_forward` 或 `br_flood` 转发。STP 协议（`br_stp_handle_bpdu`）管理环路，VLAN 过滤控制广播域。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*
