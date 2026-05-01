# bonding / team — 链路聚合深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/bonding/bond_main.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**bonding/team** 将多个物理网卡聚合成一个逻辑接口，实现冗余（故障切换）或带宽聚合。

## 1. Bond 模式

```c
// 模式 0: balance-rr（轮询）
//   → 以 round-robin 方式分发到所有从设备
//   → 带宽叠加，容错

// 模式 1: active-backup（主备）
//   → 只有一个从设备活跃，其他备用
//   → 主要用于容错

// 模式 2: balance-xor（异或）
//   → 源 MAC xor 目标 MAC 选择从设备
//   → 同一连接使用同一从设备

// 模式 3: broadcast（广播）
//   → 所有从设备收到相同数据
//   → 用于某些特殊场景

// 模式 4: 802.3ad（LACP）
//   → IEEE 802.3ad 动态链路聚合
//   → 需要交换机支持 LACP

// 模式 5: balance-tlb（自适应负载）
//   → 根据负载动态调整

// 模式 6: balance-alb（自适应负载均衡）
//   → 包括 tlb + ARP 协商
```

## 2. 核心数据结构

```c
// drivers/net/bonding/bond_main.c — bonding
struct bonding {
    // 主设备
    struct net_device       *dev;           // Bond 设备
    struct net               *net;          // 网络命名空间

    // 从设备链表
    struct list_head        slave_list;      // 活跃从设备链表
    struct net_device       *first_slave;   // 第一个从设备
    struct slave            *curr_active_slave; // 当前活跃从设备
    struct slave            *primary_slave; // 主用从设备

    // 模式
    int                     mode;           // 模式（0-6）
    int                     ll_interval;    // 链路监控间隔（毫秒）

    // 状态
    u32                     moved_count;    // 切换计数
    bool                    force_primary;   // 强制主用

    // LACP
    struct ad_bond {
        struct aggregator   *aggregator;      // LACP 聚合器
        short               aggregator_id;    // 聚合器 ID
    } ad;

    // MII 监控
    int                     miimon;          // MII 监控间隔（毫秒）
    struct timer_list       mii_timer;        // 定时器

    // ARP 监控
    u32                     arp_interval;    // ARP 探测间隔
    struct timer_list       arp_timer;       // ARP 定时器
    struct arp_target       *arp_targets;    // ARP 目标
};
```

## 3. 主备切换（bond_select_active_slave）

```c
// drivers/net/bonding/bond_main.c — bond_select_active_slave
static bool bond_select_active_slave(struct bonding *bond)
{
    struct slave *bestSlave = NULL;
    struct list_head *tmp;

    // 1. 遍历所有从设备，查找最佳候选
    bond_for_each_slave(bond, slave, tmp) {
        // 检查链路是否 UP
        if (slave->link != BOND_LINK_UP)
            continue;

        // 检查是否是活跃状态
        if (slave->state == BOND_STATE_ACTIVE)
            if (!bestSlave ||
                slave->speed > bestSlave->speed)
                bestSlave = slave;  // 速度更快的优先
    }

    // 2. 如果没有活跃的从设备，保持当前
    if (!bestSlave)
        return false;

    // 3. 切换到新的活跃从设备
    if (bestSlave != bond->curr_active_slave) {
        bond_set_slave_active_flags(bestSlave, 1);
        bond_set_slave_inactive_flags(bond->curr_active_slave, 1);

        bond->curr_active_slave = bestSlave;
        bond->send_peer_notify = 1;
    }

    return true;
}
```

## 4. 负载均衡（mode 2 xor）

```c
// drivers/net/bonding/bond_main.c — bond_xmit_hash
static u32 bond_xmit_hash(struct bonding *bond, struct sk_buff *skb)
{
    struct ethhdr *eth = (struct ethhdr *)skb->data;

    if (bond->xmit_policy == BOND_XMIT_POLICY_LAYER2)
        // 仅使用 MAC 地址
        return (eth->h_source[5] ^ eth->h_dest[5]) % bond->slave_cnt;

    else if (bond->xmit_policy == BOND_XMIT_POLICY_LAYER23)
        // 使用 MAC + IP
        return (eth->h_source[5] ^ eth->h_dest[5] ^
                iph->saddr ^ iph->daddr) % bond->slave_cnt;

    else if (bond->xmit_policy == BOND_XMIT_POLICY_LAYER34)
        // 仅使用 IP + 端口
        return (iph->saddr ^ iph->daddr ^ th->source ^ th->dest) %
               bond->slave_cnt;
}
```

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/net/bonding/bond_main.c` | `struct bonding`、`bond_select_active_slave`、`bond_xmit_hash` |
| `drivers/net/bonding/bond_options.c` | bonding 参数配置 |

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

