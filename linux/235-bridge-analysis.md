# Linux Bridge 交换机制深度分析

> 内核版本: Linux 7.0-rc1  
> 源码路径: `/home/dev/code/linux/net/bridge/`

## 目录

1. [帧接收入口: `br_handle_frame` → `br_handle_frame_finish`](#1-帧接收入口)
2. [MAC 学习数据流串联](#2-mac-学习数据流串联)
3. [转发路径串联: 单播/组播/广播](#3-转发路径串联)
4. [STP 生成树协议](#4-stp-生成树协议)
5. [Broadcast/Multicast 处理](#5-broadcastmulticast-处理)
6. [VLAN 和 Bridge 的关系](#6-vlan-和-bridge-的关系)
7. [netdev 事件通知机制](#7-netdev-事件通知机制)
8. [完整数据流 ASCII 图](#8-完整数据流-ascii-图)

---

## 1. 帧接收入口

### 帧从网卡到 Bridge 的完整路径

```
网卡驱动 netif_rx()
    └─> netif_receive_skb()
        └─> __netif_receive_skb_one_core()
            └─> iterate_netdevs()
                └─> ... → rx_handler()
```

每个 bridge port 是一个 netdevice，其 `rx_handler` 被设置为 `br_handle_frame`:

```c
// br_input.c
rx_handler_func_t *br_get_rx_handler(const struct net_device *dev)
{
    if (netdev_uses_dsa(dev))
        return br_handle_frame_dummy;  // DSA 设备走特殊路径
    return br_handle_frame;  // 普通设备走 Bridge 处理
}
```

### `br_handle_frame` 的三层分发

```c
// br_input.c
static rx_handler_result_t br_handle_frame(struct sk_buff **pskb)
{
    struct net_bridge_port *p = br_port_get_rcu(skb->dev);
    const unsigned char *dest = eth_hdr(skb)->h_dest;

    // Step 1: link-local 地址处理 (STP/LLDP/PAUSE 等保留地址)
    if (unlikely(is_link_local_ether_addr(dest))) {
        switch (dest[5]) {
        case 0x00:  // Bridge Group Address (01-80-C2-00-00-00)
            if (p->br->stp_enabled == BR_NO_STP ||
                fwd_mask & (1u << dest[5]))
                goto forward;  // 转发
            // 否则交给 __br_handle_local_finish 处理后透传到栈
            return NF_HOOK(..., br_handle_local_finish);  // 本地接收
        case 0x01:  // IEEE MAC (Pause) 帧 → 直接丢弃
            goto drop;
        case 0x0E:  // LLDP (01-80-C2-00-00-0E) → 选择性转发
            ...
        }
    }

    // Step 2: 注册的自定义帧类型处理 (可通过 br_add_frame 添加)
    if (unlikely(br_process_frame_type(p, skb)))
        return RX_HANDLER_PASS;

    // Step 3: 正常转发
forward:
    switch (p->state) {
    case BR_STATE_FORWARDING:
    case BR_STATE_LEARNING:
        // 设置 PACKET_HOST (如果是发往本桥的)
        if (ether_addr_equal(p->br->dev->dev_addr, dest))
            skb->pkt_type = PACKET_HOST;
        return nf_hook_bridge_pre(skb, pskb);
    default:
        goto drop;
    }
}
```

### `nf_hook_bridge_pre` → `br_handle_frame_finish`

```c
// br_input.c
static int nf_hook_bridge_pre(struct sk_buff *skb, struct sk_buff **pskb)
{
    // 先过 netfilter bridge PREROUTING 钩子
    nf_hook(NFPROTO_BRIDGE, NF_BR_PRE_ROUTING, ...)
        ↓
    // 最后调用 br_handle_frame_finish
    br_handle_frame_finish(dev_net(skb->dev), NULL, skb);
}
```

---

## 2. MAC 学习数据流串联

### FDB 数据结构

FDB (Forwarding Database) 使用 `rhashtable` 存储，key 是 `(MAC, VLAN ID)`:

```c
// br_private.h
struct net_bridge_fdb_key {
    mac_addr addr;
    u16      vlan_id;
};

struct net_bridge_fdb_entry {
    struct rhash_head       rhnode;    // rhashtable 节点
    struct net_bridge_port *dst;      // 目标端口 (NULL = 桥自身)
    struct net_bridge_fdb_key key;   // MAC + VLAN
    unsigned long          flags;    // BR_FDB_LOCAL/STATIC/STICKY 等
    unsigned long          updated;  // 最后更新时间 (用于 aging)
    unsigned long          used;     // 最后使用时间
    struct hlist_node      fdb_node;  // 挂在 br->fdb_list 上
};
```

### MAC 学习触发点

在 `br_handle_frame_finish` 中，**过滤完成后** 才学习：

```c
// br_input.c: br_handle_frame_finish()
    ↓
// Step 1: VLAN 过滤
if (!br_allowed_ingress(...))  goto out;

// Step 2: MAB (MAC Authentication Bypass) 端口锁定检查
if (p->flags & BR_PORT_LOCKED) {
    fdb_src = br_fdb_find_rcu(br, eth_hdr(skb)->h_source, vid);
    if (!fdb_src) {
        if (p->flags & BR_PORT_MAB)  // 启用 MAB，创建锁定条目
            br_fdb_update(br, p, eth_hdr(skb)->h_source, vid, BIT(BR_FDB_LOCKED));
        goto drop;
    }
    // ... 各种锁定检查
}

// Step 3: 标记 switchdev 转发域
nbp_switchdev_frame_mark(p, skb);

// Step 4: MAC 学习 ★
if (p->flags & BR_LEARNING)
    br_fdb_update(br, p, eth_hdr(skb)->h_source, vid, 0);
```

### `br_fdb_update` 详细路径

```c
// br_fdb.c
void br_fdb_update(struct net_bridge *br, struct net_bridge_port *source,
                   const unsigned char *addr, u16 vid, unsigned long flags)
{
    // hold_time == 0 时不做学习 (有些用户想要始终泛洪)
    if (hold_time(br) == 0)  return;

    fdb = fdb_find_rcu(&br->fdb_hash_tbl, addr, vid);

    if (likely(fdb)) {
        // === 更新已有条目 ===
        if (unlikely(test_bit(BR_FDB_LOCAL, &fdb->flags))) {
            // 警告: 收到以本桥地址作为源地址的帧 (possible loop)
            br_warn(...)
        } else {
            // 更新时间戳
            WRITE_ONCE(fdb->updated, now);
            __fdb_mark_active(fdb);

            // 如果源端口发生变化 (漫游)，更新 dst
            if (source != READ_ONCE(fdb->dst) && !test_bit(BR_FDB_STICKY, &fdb->flags)) {
                br_switchdev_fdb_notify(br, fdb, RTM_DELNEIGH);
                WRITE_ONCE(fdb->dst, source);  // 更新转发出口
                // 清除锁定标志 (漫游到非锁定端口)
                if (test_bit(BR_FDB_LOCKED, &fdb->flags))
                    clear_bit(BR_FDB_LOCKED, &fdb->flags);
            }
            // 如果是外部学习条目被软件接管
            if (test_bit(BR_FDB_ADDED_BY_EXT_LEARN, &fdb->flags))
                clear_bit(BR_FDB_ADDED_BY_EXT_LEARN, &fdb->flags);
            // ... 通知等
        }
    } else {
        // === 创建新条目 ===
        spin_lock(&br->hash_lock);
        fdb = fdb_create(br, source, addr, vid, flags);  // fdb_create
        if (fdb)
            fdb_notify(br, fdb, RTM_NEWNEIGH, true);
        spin_unlock(&br->hash_lock);
    }
}
```

### `fdb_create` — 创建新的 FDB 条目

```c
// br_fdb.c
static struct net_bridge_fdb_entry *fdb_create(struct net_bridge *br,
    struct net_bridge_port *source, const unsigned char *addr,
    __u16 vid, unsigned long flags)
{
    bool learned = !test_bit(BR_FDB_ADDED_BY_USER, &flags) &&
                   !test_bit(BR_FDB_LOCAL, &flags);

    // 动态学习条目数限制检查
    if (likely(learned)) {
        u32 max_learned = READ_ONCE(br->fdb_max_learned);
        int n_learned = atomic_read(&br->fdb_n_learned);
        if (unlikely(max_learned && n_learned >= max_learned))
            return NULL;  // 达到上限，拒绝学习
        __set_bit(BR_FDB_DYNAMIC_LEARNED, &flags);
    }

    fdb = kmem_cache_alloc(br_fdb_cache, GFP_ATOMIC);
    // ... memcpy MAC/vlan, 设置 dst, updated, used
    // rhashtable_insert_fast → 加入 br->fdb_hash_tbl
    // hlist_add_head_rcu → 加入 br->fdb_list
    // atomic_inc(&br->fdb_n_learned)
    return fdb;
}
```

### Aging (老化) 机制

**不是定时器遍历，而是 Workqueue 延迟清理:**

```c
// br_fdb.c: br_fdb_cleanup()
void br_fdb_cleanup(struct work_struct *work)
{
    struct net_bridge *br = container_of(work, ...);
    unsigned long delay = hold_time(br);  // topology_change ? forward_delay : ageing_time
    unsigned long work_delay = delay;
    unsigned long now = jiffies;

    rcu_read_lock();
    hlist_for_each_entry_rcu(f, &br->fdb_list, fdb_node) {
        // 静态/外部学习条目不做 aging，但可发送 INACTIVE 通知
        if (test_bit(BR_FDB_STATIC, &f->flags) ||
            test_bit(BR_FDB_ADDED_BY_EXT_LEARN, &f->flags)) {
            if (test_bit(BR_FDB_NOTIFY, &f->flags)) {
                if (time_after(this_timer, now))
                    work_delay = min(work_delay, this_timer - now);
                else if (!test_and_set_bit(BR_FDB_NOTIFY_INACTIVE, &f->flags))
                    fdb_notify(br, f, RTM_NEWNEIGH, false);  // 发送 INACTIVE 通知
            }
            continue;
        }

        // 动态条目检查是否过期
        if (time_after(this_timer, now)) {
            work_delay = min(work_delay, this_timer - now);
        } else {
            spin_lock_bh(&br->hash_lock);
            if (!hlist_unhashed(&f->fdb_node))
                fdb_delete(br, f, true);  // 删除过期条目
            spin_unlock_bh(&br->hash_lock);
        }
    }
    rcu_read_unlock();

    work_delay = max(work_delay, msecs_to_jiffies(10));  // 至少间隔 10ms
    mod_delayed_work(system_long_wq, &br->gc_work, work_delay);  // 调度下次清理
}
```

**注意:** aging timer 的检查是**遍历时动态计算** (`f->updated + hold_time < now`)，不是预设定时器。这避免了每条目一个 timer 的开销。

---

## 3. 转发路径串联

### 帧分类

在 `br_handle_frame_finish` 中，帧首先被分类:

```c
// br_input.c
enum br_pkt_type { BR_PKT_UNICAST, BR_PKT_MULTICAST, BR_PKT_BROADCAST };

// 根据目标 MAC 判断
if (is_multicast_ether_addr(eth_hdr(skb)->h_dest)) {
    if (is_broadcast_ether_addr(eth_hdr(skb)->h_dest))
        pkt_type = BR_PKT_BROADCAST;
    else
        pkt_type = BR_PKT_MULTICAST;
} else {
    pkt_type = BR_PKT_UNICAST;
}
```

### 单播转发: `br_fdb_find_rcu` → `br_forward`

```c
// br_input.c: br_handle_frame_finish()
case BR_PKT_UNICAST:
    dst = br_fdb_find_rcu(br, eth_hdr(skb)->h_dest, vid);  // FDB 查找
    // 如果 VLAN 0 fallback 开启且主表查不到，尝试 VLAN 0
    if (unlikely(!dst && vid && br_opt_get(br, BROPT_FDB_LOCAL_VLAN_0))) {
        dst = br_fdb_find_rcu(br, eth_hdr(skb)->h_dest, 0);
        // 跳过纯 LOCAL 条目 (除非用户显式添加)
        if (dst && (!test_bit(BR_FDB_LOCAL, &dst->flags) ||
                   test_bit(BR_FDB_ADDED_BY_USER, &dst->flags)))
            dst = NULL;
    }
    break;

// → 然后
if (dst) {
    unsigned long now = jiffies;
    if (test_bit(BR_FDB_LOCAL, &dst->flags))
        return br_pass_frame_up(skb, false);  // 发往桥自身
    if (now != READ_ONCE(dst->used))
        WRITE_ONCE(dst->used, now);  // 更新时间戳
    br_forward(dst->dst, skb, local_rcv, false);  // 单播转发
} else {
    br_flood(br, skb, pkt_type, local_rcv, false, vid);  // 未知单播泛洪
}
```

### `br_forward` — 单播转发到特定端口

```c
// br_forward.c
void br_forward(const struct net_bridge_port *to, struct sk_buff *skb,
                bool local_rcv, bool local_orig)
{
    if (unlikely(!to))  goto out;

    // 检查是否需要 redirect 到备份链路
    if (rcu_access_pointer(to->backup_port) &&
        (!netif_carrier_ok(to->dev) || !netif_running(to->dev))) {
        to = rcu_dereference(to->backup_port);
        if (unlikely(!to))  goto out;
    }

    if (should_deliver(to, skb)) {
        if (local_rcv)
            deliver_clone(to, skb, local_orig);  // 复制一份转发，原始帧本地处理
        else
            __br_forward(to, skb, local_orig);    // 直接转发
        return;
    }
out:
    if (!local_rcv)  kfree_skb(skb);
}
```

关键检查 `should_deliver`:

```c
static inline int should_deliver(const struct net_bridge_port *p,
                                 const struct sk_buff *skb)
{
    struct net_bridge_vlan_group *vg = nbp_vlan_group_rcu(p);
    return ((p->flags & BR_HAIRPIN_MODE) || skb->dev != p->dev) &&  // 非 Hairpin 源端口
           (br_mst_is_enabled(p) || p->state == BR_STATE_FORWARDING) &&  // 端口转发状态
           br_allowed_egress(vg, skb) &&  // VLAN egress 过滤
           nbp_switchdev_allowed_egress(p, skb) &&  // switchdev 允许
           !br_skb_isolated(p, skb);  // 端口隔离
}
```

### `__br_forward` — 实际转发逻辑

```c
// br_forward.c
static void __br_forward(const struct net_bridge_port *to,
                         struct sk_buff *skb, bool local_orig)
{
    // 1. VLAN 处理 (可能剥除 VLAN tag)
    skb = br_handle_vlan(to->br, to, nbp_vlan_group_rcu(to), skb);
    if (!skb)  return;

    // 2. 修改 skb->dev 为目标端口
    indev = skb->dev;
    skb->dev = to->dev;

    // 3. 走 netfilter FORWARD 或 LOCAL_OUT 钩子
    if (!local_orig) {
        br_hook = NF_BR_FORWARD;
        skb_forward_csum(skb);
        net = dev_net(indev);
    } else {
        br_hook = NF_BR_LOCAL_OUT;
        net = dev_net(skb->dev);
        indev = NULL;
    }

    NF_HOOK(NFPROTO_BRIDGE, br_hook, net, NULL, skb, indev, skb->dev,
            br_forward_finish);
}

// br_forward_finish → br_dev_queue_push_xmit → dev_queue_xmit()
int br_forward_finish(...) {
    return NF_HOOK(NFPROTO_BRIDGE, NF_BR_POST_ROUTING, ...,
                   br_dev_queue_push_xmit);
}
```

### `br_pass_frame_up` vs `br_handle_frame` 的区别

| 函数 | 调用场景 | 作用 |
|------|---------|------|
| `br_handle_frame` | **入口**，每个包都过，从 rx_handler 调用 | 帧分类、VLAN 过滤、MAC 学习、分发到转发/本地 |
| `br_pass_frame_up` | 帧目的地是**桥自身** (LOCAL FDB 条目或本地收) | 将帧送到桥的 netdevice，触发上层协议栈 (L3) |
| `br_forward` | 单播帧，目标 MAC 在 FDB 中 | 转发到指定端口 |
| `br_flood` | 广播/组播/未知单播 | 泛洪到多个端口 |
| `br_multicast_flood` | IGMP/组播查表后命中 | 只转发到组播组成员端口 |

---

## 4. STP 生成树协议

### Port 角色确定: designated / root / alternate

```c
// br_stp.c
/* 判断一个端口是否应该成为 designated port */
static int br_should_become_designated_port(const struct net_bridge_port *p)
{
    struct net_bridge *br = p->br;

    // 已经是 designated port → 保留
    if (br_is_designated_port(p))  return 1;

    // 比较根 ID: 我更小 → 我成为 designated
    if (memcmp(&p->designated_root, &br->designated_root, 8))  return 1;

    // 比较根路径成本
    if (br->root_path_cost < p->designated_cost)  return 1;
    else if (br->root_path_cost > p->designated_cost)  return 0;

    // 比较桥 ID: 我更小 → 我成为 designated
    t = memcmp(&br->bridge_id, &p->designated_bridge, 8);
    if (t < 0)  return 1;
    else if (t > 0)  return 0;

    // 比较端口 ID: 我更小 → 我成为 designated
    if (p->port_id < p->designated_port)  return 1;

    return 0;
}
```

### Port 状态转换

```c
// br_stp.c: br_port_state_selection()
void br_port_state_selection(struct net_bridge *br)
{
    list_for_each_entry(p, &br->port_list, list) {
        if (p->state == BR_STATE_DISABLED)  continue;

        if (br->stp_enabled != BR_USER_STP) {
            if (p->port_no == br->root_port) {
                // ★ 根端口 → 转为 Forwarding
                p->config_pending = 0;
                p->topology_change_ack = 0;
                br_make_forwarding(p);
            } else if (br_is_designated_port(p)) {
                // ★ designated port → 转为 Forwarding
                timer_delete(&p->message_age_timer);
                br_make_forwarding(p);
            } else {
                // ★ 其他所有端口 → 转为 Blocking
                p->config_pending = 0;
                p->topology_change_ack = 0;
                br_make_blocking(p);
            }
        }

        if (p->state != BR_STATE_BLOCKING)
            br_multicast_enable_port(p);
        if (p->state == BR_STATE_FORWARDING)
            ++liveports;
    }

    // 无转发端口 → 桥 DOWN；有 → 桥 UP
    if (liveports == 0)  netif_carrier_off(br->dev);
    else  netif_carrier_on(br->dev);
}
```

### Forward Delay 控制 — TCA_MAX 的真正含义

**没有直接叫 "TCA_MAX" 的宏**，但 `forward_delay` 参数控制的是 BPDU 的传播延迟:

```c
// br_private_stp.h
#define BR_MIN_FORWARD_DELAY  (2*HZ)   // 最快 2 秒
#define BR_MAX_FORWARD_DELAY  (30*HZ)  // 最慢 30 秒

// 定时器到期时的状态推进 (br_stp_timer.c)
static void br_forward_delay_timer_expired(struct timer_list *t)
{
    struct net_bridge_port *p = ...;

    spin_lock(&br->lock);
    if (p->state == BR_STATE_LISTENING) {
        // LISTENING → LEARNING (等一个 forward_delay)
        br_set_state(p, BR_STATE_LEARNING);
        mod_timer(&p->forward_delay_timer, jiffies + br->forward_delay);
    } else if (p->state == BR_STATE_LEARNING) {
        // LEARNING → FORWARDING (再等一个 forward_delay)
        br_set_state(p, BR_STATE_FORWARDING);
        if (br_is_designated_for_some_port(br))
            br_topology_change_detection(br);  // 检测到拓扑变化
        netif_carrier_on(br->dev);
    }
    spin_unlock(&br->lock);
}
```

**Forward Delay 的语义：** 新选出的 designated port 需要经过 `LISTENING → LEARNING → FORWARDING` 两个阶段，每个阶段各等待一个 `forward_delay`。这确保了在网络收敛期间不会产生环路。

**Topology Change 时 aging 时间会缩短:**

```c
// br_stp.c: __br_set_topology_change()
if (br->stp_enabled == BR_KERNEL_STP && br->topology_change != val) {
    if (val) {
        // 拓扑变化时: ageing_time = 2 * forward_delay (而不是正常的 ageing_time)
        t = 2 * br->forward_delay;
        br_debug(br, "decreasing ageing time to %lu\n", t);
    } else {
        t = br->bridge_ageing_time;  // 恢复正常 ageing_time
    }
    __set_ageing_time(br->dev, t);  // 下发到硬件
    br->ageing_time = t;
}
```

---

## 5. Broadcast/Multicast 处理

### `br_flood` vs `br_multicast_flood` 的区别

| 函数 | 调用时机 | 转发范围 | 典型场景 |
|------|---------|---------|---------|
| `br_flood` | **未知单播** + **广播** + **未命中组播表** | 除源端口外所有启用对应 flood 标志的端口 | 未知 DA、ARP、Broadcast |
| `br_multicast_flood` | **组播帧** 命中 MDB 表 | 只到 MDB 中的组成员端口 | IGMP/MLD 组成员流量 |

### `br_flood` — 泛洪逻辑

```c
// br_forward.c
void br_flood(struct net_bridge *br, struct sk_buff *skb,
              enum br_pkt_type pkt_type, bool local_rcv, bool local_orig, u16 vid)
{
    struct net_bridge_port *prev = NULL;

    list_for_each_entry_rcu(p, &br->port_list, list) {
        // 检查 flood 标志
        switch (pkt_type) {
        case BR_PKT_UNICAST:
            if (!(p->flags & BR_FLOOD))  continue;
            break;
        case BR_PKT_MULTICAST:
            if (!(p->flags & BR_MCAST_FLOOD) && skb->dev != br->dev)  continue;
            break;
        case BR_PKT_BROADCAST:
            if (!(p->flags & BR_BCAST_FLOOD) && skb->dev != br->dev)  continue;
            break;
        }

        // 代理 ARP 相关检查
        if (p->flags & BR_PROXYARP)  continue;
        if (BR_INPUT_SKB_CB(skb)->proxyarp_replied &&
            ((p->flags & BR_PROXYARP_WIFI) ||
             br_is_neigh_suppress_enabled(p, vid)))  continue;

        prev = maybe_deliver(prev, p, skb, local_orig);
        if (IS_ERR(prev))  goto out;
    }

    if (!prev)  goto out;
    if (local_rcv)
        deliver_clone(prev, skb, local_orig);  // 最后一份复制给本地
    else
        __br_forward(prev, skb, local_orig);
    return;
out:
    if (!local_rcv)  kfree_skb_reason(skb, ...);
}
```

### `br_multicast_flood` — 组播查表转发

```c
// br_forward.c
void br_multicast_flood(struct net_bridge_mdb_entry *mdst,
                        struct sk_buff *skb, struct net_bridge_mcast *brmctx,
                        bool local_rcv, bool local_orig)
{
    struct net_bridge_port *prev = NULL;
    struct net_bridge_port_group *p;
    bool allow_mode_include = true;
    struct hlist_node *rp;

    rp = br_multicast_get_first_rport_node(brmctx, skb);  // 路由器端口

    if (mdst) {
        p = rcu_dereference(mdst->ports);
        // * 组播组条目存在，遍历组成员
        // * 过滤模式处理 (INCLUDE/EXCLUDE)
        if (br_multicast_is_star_g(&mdst->addr))
            allow_mode_include = false;  // (*,G) 条目
    } else {
        p = NULL;  // 无 MDB 条目 → 只发给路由器端口
        br_tc_skb_miss_set(skb, true);
    }

    while (p || rp) {
        struct net_bridge_port *port, *lport, *rport;
        lport = p ? p->key.port : NULL;
        rport = br_multicast_rport_from_node_skb(rp, skb);

        // ★ 组播转单播模式: 将组播转为单播发送
        if ((unsigned long)lport > (unsigned long)rport) {
            port = lport;
            if (port->flags & BR_MULTICAST_TO_UNICAST) {
                maybe_deliver_addr(lport, skb, p->eth_addr, local_orig);
                goto delivered;
            }
            // INCLUDE 模式且 (*,G) 条目 → 跳过
            if ((!allow_mode_include && p->filter_mode == MCAST_INCLUDE) ||
                (p->flags & MDB_PG_FLAGS_BLOCKED))  goto delivered;
        } else {
            port = rport;
        }

        prev = maybe_deliver(prev, port, skb, local_orig);
        if (IS_ERR(prev))  goto out;
delivered:
        if ((unsigned long)lport >= (unsigned long)port)  p = rcu_dereference(p->next);
        if ((unsigned long)rport >= (unsigned long)port)  rp = rcu_dereference(hlist_next_rcu(rp));
    }

    if (!prev)  goto out;
    if (local_rcv)
        deliver_clone(prev, skb, local_orig);
    else
        __br_forward(prev, skb, local_orig);
    return;
out:
    if (!local_rcv)  kfree_skb_reason(skb, reason);
}
```

### GARP (Gratuitous ARP) 的特殊处理

**GARP 没有专门的泛洪函数**，但有一个关键特性: **如果 bridge 收到 GARP，桥自身也会接收** (local_rcv=true)。

在 `br_handle_frame_finish` 中:

```c
// br_input.c
if (is_multicast_ether_addr(eth_hdr(skb)->h_dest)) {
    if (is_broadcast_ether_addr(eth_hdr(skb)->h_dest)) {
        pkt_type = BR_PKT_BROADCAST;
        local_rcv = true;  // ★ 广播帧本地也收一份
    } else {
        pkt_type = BR_PKT_MULTICAST;
        // IGMP 类型检查 → 可能丢弃
        if (br_multicast_rcv(&brmctx, &pmctx, vlan, skb, vid))  goto drop;
    }
}

// 然后走到 br_flood → deliver_clone → 本地也收到一份
```

---

## 6. VLAN 和 Bridge 的关系

### 两层 VLAN 数据结构

```
net_bridge (vlgrp: net_bridge_vlan_group)
    ├─ vlan_hash (rhashtable) → {vid: net_bridge_vlan, flags: MASTER}
    ├─ vlan_list (sorted list)
    ├─ num_vlans
    └─ pvid, pvid_state

net_bridge_port (vlgrp: net_bridge_vlan_group)
    ├─ vlan_hash (rhashtable) → {vid: net_bridge_vlan, flags: port-specific}
    ├─ vlan_list (sorted list)
    ├─ num_vlans
    ├─ pvid, pvid_state
    └─ brvlan → 指向 bridge 层的 master vlan (refcount 引用)
```

**核心概念区分:**

- `BRIDGE_VLAN_INFO_MASTER`: 这是 bridge 层的全局 VLAN 条目 (用于全局特性: 组播路由等)
- `BRIDGE_VLAN_INFO_BRENTRY`: 这个 VLAN 在 bridge 层**参与转发过滤**
- 一个 port vlan 的 `brvlan` 指向 bridge 层 master，形成跨层引用

### PVID 设置路径

```c
// br_vlan.c: __vlan_add() / __vlan_flags_update()
static bool __vlan_flags_update(struct net_bridge_vlan *v, u16 flags, bool commit)
{
    if (flags & BRIDGE_VLAN_INFO_PVID) {
        __vlan_add_pvid(vg, v);  // 写入 vg->pvid，同时设置 smp_wmb
    } else {
        __vlan_delete_pvid(vg, v->vid);  // 清除 pvid
    }
    ...
}

// br_vlan.c: __vlan_add_pvid()
static void __vlan_add_pvid(struct net_bridge_vlan_group *vg, const struct net_bridge_vlan *v)
{
    if (vg->pvid == v->vid)  return;
    smp_wmb();
    br_vlan_set_pvid_state(vg, v->state);  // 同步 PVID 的 STP 状态
    vg->pvid = v->vid;
}
```

### PVID 入站帧处理

在 `br_allowed_ingress` (VLAN 过滤入口):

```c
// br_vlan.c: __allowed_ingress()
if (!*vid) {
    u16 pvid = br_get_pvid(vg);  // 读取 PVID
    if (!pvid)  goto drop;

    *vid = pvid;  // ★ 无标签/VID=0 帧 → 归属到 PVID

    if (!tagged)
        __vlan_hwaccel_put_tag(skb, br->vlan_proto, pvid);  // 打上 PVID tag
    else
        skb->vlan_tci |= pvid;  // 仅更新 VID 字段，保留 PCP
    ...
}
```

### `br_vlan_bridge` vs `br_vlan_filter`

这两个不是两个不同的 "模式"，而是对同一个 per-VLAN 条目不同操作的视角:

- `br_vlan_filter_toggle()`: **开启/关闭整个 bridge 的 VLAN filtering 功能** (BROPT_VLAN_ENABLED)。关闭后，所有帧都不过滤。
- `br_vlan_bridge`: 这个措辞可能是指 **bridge 层的 VLAN 条目** (带 MASTER flag)，参与全局过滤。

---

## 7. netdev 事件通知机制

### `br_ifinfo_notify` — port 状态变化的传播者

```c
// br_netlink.c
void br_ifinfo_notify(int event, const struct net_bridge *br,
                      const struct net_bridge_port *port)
{
    // 最终调用 rtnl_notify → 发送 RTM_NEWLINK / RTM_DELLINK 消息
    // 会被用户空间的 iproute2 / NetworkManager 接收
}
```

### 谁在监听? — 事件触发点一览

| 触发场景 | 调用位置 | 通知类型 |
|---------|---------|---------|
| Port STP 状态变化 (`br_set_state`) | `br_stp.c: br_set_state()` | RTM_NEWLINK |
| Port 进入 listening (forward_delay timer) | `br_stp_if.c: br_make_blocking()` | RTM_NEWLINK |
| Port 进入 forwarding | `br_stp_if.c: br_make_forwarding()` | RTM_NEWLINK |
| Port 加入 bridge | `br_if.c: br_add_if()` | RTM_NEWLINK |
| Port 从 bridge 删除 | `br_if.c: br_del_if()` | RTM_DELLINK |
| Port 标志变化 (promiscuous 等) | `br_sysfs_if.c` (sysfs write) | RTM_NEWLINK |
| Bridge 地址变化 | `br_if.c: br_manage_promisc()` | NETDEV_CHANGEADDR |

```c
// br_stp.c: br_set_state()
void br_set_state(struct net_bridge_port *p, unsigned int state)
{
    p->state = state;
    // ... switchdev 下发到硬件 ...
    br_info(br, "port %u(%s) entered %s state\n", ...);
    // ★ 发送 netlink 通知
    br_ifinfo_notify(RTM_NEWLINK, NULL, p);
}

// br_stp_timer.c: br_forward_delay_timer_expired()
static void br_forward_delay_timer_expired(...)
{
    spin_lock(&br->lock);
    if (p->state == BR_STATE_LISTENING) {
        br_set_state(p, BR_STATE_LEARNING);
        mod_timer(&p->forward_delay_timer, jiffies + br->forward_delay);
    } else if (p->state == BR_STATE_LEARNING) {
        br_set_state(p, BR_STATE_FORWARDING);
        // ...
    }
    rcu_read_lock();
    br_ifinfo_notify(RTM_NEWLINK, NULL, p);  // ★ 每次状态变化都通知
    rcu_read_unlock();
    spin_unlock(&br->lock);
}
```

### 用户空间监听示例

```bash
# 监听 bridge port 状态变化
ip link monitor dev eth0

# 或者用 rtmon
rtmon link dev eth0

# 用户态程序通过 netlink 接收 RTM_NEWLINK / RTM_DELLINK
```

---

## 8. 完整数据流 ASCII 图

### 帧从 port1 入 → 转发到 port2 (已知单播)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           FRAME INGRESS PATH                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  [eth0] netif_rx()                                                         │
│         ↓                                                                   │
│  netif_receive_skb()                                                       │
│         ↓                                                                   │
│  br_handle_frame()  ← rx_handler (per-port netdevice)                    │
│         │                                                                   │
│         ├─ is_link_local_ether_addr(dest)?                                 │
│         │  ├─ YES: 802.1D STP/LLDP/PAUSE → special handling               │
│         │  └─ NO:  ↓                                                       │
│         │                                                                   │
│         ├─ br_process_frame_type() → custom protocol handlers             │
│         │                                                                   │
│         └─ nf_hook_bridge_pre()                                           │
│                    ↓                                                        │
│  br_handle_frame_finish()  ← VLAN 过滤 + MAC 学习 + FDB 查找 + 转发决策  │
│         │                                                                   │
│         ├─ br_allowed_ingress() ─→ VLAN 检查 (tagged/untagged/PVID)       │
│         │     │                                                              │
│         │     └─ br_vlan_get_tag() / br_get_pvid()                        │
│         │                                                                   │
│         ├─ br_fdb_update() ★ MAC 学习                                       │
│         │     ├─ fdb_find_rcu() → 查表                                      │
│         │     ├─ 不存在 → fdb_create() → 加入 rhashtable                   │
│         │     └─ 已存在 → 更新时间戳 updated/used                           │
│         │                                                                   │
│         ├─ br_fdb_find_rcu(dest_mac, vid) → 查找目标端口 FDB 条目          │
│         │     │                                                              │
│         │     ├─ dst != NULL → 单播帧                                       │
│         │     │    │                                                        │
│         │     │    ├─ test_bit(BR_FDB_LOCAL)? → br_pass_frame_up(本地)   │
│         │     │    │                                                        │
│         │     │    └─ br_forward(dst->dst, skb, local_rcv=false)          │
│         │     │         │                                                  │
│         │     │         ├─ should_deliver() 检查                           │
│         │     │         │    ├─ port.state == FORWARDING?                 │
│         │     │         │    ├─ br_allowed_egress()?                      │
│         │     │         │    └─ nbp_switchdev_allowed_egress()?           │
│         │     │         │                                                  │
│         │     │         ├─ __br_forward()                                  │
│         │     │         │    ├─ br_handle_vlan() (egress VLAN 处理)       │
│         │     │         │    ├─ NF_BR_FORWARD hook                         │
│         │     │         │    └─ br_forward_finish() → br_dev_queue_push_xmit()
│         │     │         │         │                                        │
│         │     │         │         └─ dev_queue_xmit() → [eth1] 发送        │
│         │     │         │                                                   │
│         │     └─ dst == NULL → br_flood(br, skb, UNICAST, ...)            │
│         │                                                                   │
│         └─ br_pass_frame_up() → 本地递交给上层协议栈                        │
│              ├─ br_allowed_egress() (bridge 自身)                          │
│              ├─ br_handle_vlan()                                          │
│              └─ NF_BR_LOCAL_IN → netif_receive_skb() → L3                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

                            FRAME EGRESS (unicast to port2)

    ┌────────────────────────────────────────────────────────────┐
    │  br_dev_queue_push_xmit()                                  │
    │       │                                                    │
    │       ├─ skb_push(skb, ETH_HLEN)                          │
    │       ├─ is_skb_forwardable()?                             │
    │       ├─ br_drop_fake_rtable()                            │
    │       ├─ br_switchdev_frame_set_offload_fwd_mark()        │
    │       └─ dev_queue_xmit(skb) → TX queue →网卡驱动          │
    └────────────────────────────────────────────────────────────┘
```

### 广播帧泛洪路径

```
br_flood(br, skb, BR_PKT_BROADCAST, local_rcv=true, ...)
    │
    ├─ list_for_each_entry_rcu(port, &br->port_list)
    │     │
    │     ├─ 检查 BR_BCAST_FLOOD 标志
    │     ├─ 检查 BR_PROXYARP / proxyarp_replied
    │     └─ maybe_deliver(prev, port, skb, false)
    │           │
    │           ├─ should_deliver()? → 状态/VLAN/switchdev 检查
    │           │
    │           └─ deliver_clone(prev, skb, false)
    │                 │
    │                 ├─ skb_clone() → 复制 skb
    │                 └─ __br_forward(port, skb_clone, false)
    │                      │
    │                      └─ br_handle_vlan() → 可能剥除 VLAN tag
    │                         ↓
    │                         NF_BR_FORWARD
    │                         ↓
    │                         br_forward_finish()
    │                            ↓
    │                            br_dev_queue_push_xmit() → dev_queue_xmit()
    │
    └─ 最后一份: deliver_clone(last_port, skb, local_rcv=true)
          │
          └─ __br_forward(last_port, skb, local_orig=false)
                 │
                 └─ NF_BR_LOCAL_OUT → br_pass_frame_up(skb, promisc)
                       │
                       └─ netif_receive_skb() → L3 (ARP 等)
```

### MAC 学习 + Aging 完整路径

```
1. FRAME INGRESS
   br_handle_frame_finish()
       ↓ (BR_LEARNING flag set)
   br_fdb_update(br, port, src_mac, vid, 0)
       │
       ├─ fdb_find_rcu(br->fdb_hash_tbl, src_mac, vid)
       │     │
       │     └─ rhashtable_lookup() → O(1) 查找
       │
       ├─ EXISTS:
       │     ├─ 更新 fdb->updated = now
       │     ├─ 如果端口变化: 漫游处理 (清除 LOCKED 等)
       │     └─ 如果需要: fdb_notify(RTM_NEWNEIGH)
       │
       └─ NOT EXISTS:
             ├─ spin_lock(&br->hash_lock)
             ├─ fdb_create() → kmem_cache_alloc + rhashtable_insert_fast
             ├─ fdb_notify(RTM_NEWNEIGH)
             └─ spin_unlock(&br->hash_lock)

2. AGEING (定期 workqueue)
   br_fdb_cleanup(work)
       │
       ├─ list_for_each_entry_rcu(f, &br->fdb_list)
       │     │
       │     ├─ STATIC/EXT_LEARNED: 不删除，但发 INACTIVE 通知
       │     │
       │     └─ DYNAMIC:
       │           if (f->updated + ageing_time < now)
       │               spin_lock_bh()
       │               fdb_delete() → rhashtable_remove + hlist_del_rcu + kfree_rcu
       │               atomic_dec(&br->fdb_n_learned)
       │               spin_unlock_bh()
       │
       └─ mod_delayed_work(system_long_wq, &br->gc_work, next_delay)
```

---

## 关键数据结构索引

| 文件 | 关键结构 | 作用 |
|------|---------|------|
| `br_private.h` | `net_bridge`, `net_bridge_port` | Bridge 和 Port 主结构 |
| `br_private.h` | `net_bridge_fdb_entry`, `net_bridge_fdb_key` | FDB 表项 |
| `br_private.h` | `net_bridge_vlan`, `net_bridge_vlan_group` | VLAN 过滤 |
| `br_private.h` | `net_bridge_mdb_entry`, `net_bridge_port_group` | 组播组 |
| `br_private_stp.h` | `bridge_id`, `mac_addr` | STP 协议专用 |
| `br_input.c` | `br_handle_frame`, `br_handle_frame_finish` | 帧入口和处理 |
| `br_forward.c` | `br_forward`, `br_flood`, `br_multicast_flood` | 转发决策 |
| `br_fdb.c` | `br_fdb_update`, `fdb_create`, `br_fdb_cleanup` | MAC 学习/老化 |
| `br_stp.c` | `br_should_become_designated_port`, `br_port_state_selection` | STP 角色/状态 |
| `br_stp_timer.c` | `br_forward_delay_timer_expired` | Forward Delay 定时器 |
| `br_vlan.c` | `br_allowed_ingress`, `br_handle_vlan` | VLAN 过滤/egress |
| `br_netlink.c` | `br_ifinfo_notify` | netlink 事件通知 |