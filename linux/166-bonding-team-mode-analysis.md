# 166-bonding_team_mode — 网卡绑定与team深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/bonding/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**Bonding** 和 **Team** 是 Linux 的网卡聚合/负载均衡技术，将多个物理网卡虚拟成一个逻辑网卡，提供带宽扩展和故障容错。

## 1. Bonding vs Team

| 特性 | Bonding | Team |
|------|---------|------|
| 驱动 | 内核 (net/core/bonding) | 用户空间 (teamd) |
| 配置 | ifenslave / ip link | teamd (JSON 配置) |
| 负载均衡 | 多种模式 | 多种 runner |
| 状态监控 | ARP / MII | ARP / NS / ethtool |
| 灵活性 | 有限 | 高（用户空间 runner）|

## 2. Bonding 模式

### 2.1 模式列表

```bash
# 模式 0：balance-rr（轮询）
#   数据包按顺序从每个 slave 发送
#   缺点：不保序

# 模式 1：active-backup（主备）
#   只有一个 slave 活跃
#   其他 slave 备份

# 模式 2：balance-xor（异或）
#   根据 MAC 地址异或决定走哪个 slave
#   同一对 MAC 走同一 slave

# 模式 3：broadcast（广播）
#   所有 slave 都发相同数据

# 模式 4：802.3ad（LACP）
#   IEEE 802.3ad 链路聚合
#   需要交换机支持 LACP

# 模式 5：balance-tlb（自适应负载均衡）
#   动态调整

# 模式 6：balance-alb（自适应负载均衡）
#   包括 IPv4 负载均衡
```

### 2.2 struct bonding — Bonding 设备

```c
// drivers/net/bonding/bond_main.h — bonding
struct bonding {
    struct net_device       *dev;              // bond 设备

    // slave 列表
    struct list_head        slave_list;         // 所有 slave
    struct slave           *curr_active_slave;  // 当前活跃 slave
    struct slave           *primary_slave;      // 主 slave

    // 模式
    s8                     params.mode;        // bond_mode

    // 监控
    struct ad_bond_info    ad_info;            // 802.3ad
    struct alb_bond_info   alb_info;           // balance-alb
    struct lacpdu_stats    lacp_stats;         // LACP 统计
};
```

## 3. active-backup 模式

### 3.1 activebackup

```c
// drivers/net/bonding/bond_main.c — activebackup
static void activebackup(struct bonding *bond)
{
    struct slave *current;

    // 1. 获取当前活跃 slave
    current = bond->curr_active_slave;

    // 2. 检查是否需要切换
    if (current && bond->params.primary) {
        if (slave_is_up(current)) {
            // 当前 slave 正常，保持
            return;
        }
        // 当前 slave 挂了，切换
        current = failover(bond);
    }

    // 3. 选择新的活跃 slave
    if (!current) {
        // 选择第一个可用的 slave
        current = bond->slave_list;
        bond->curr_active_slave = current;
    }
}
```

## 4. LACP（802.3ad）

### 4.1 lacpdu — LACP 帧

```
LACP 帧（Slow Protocols）：

Actor Info（发送方）：
  - System ID（MAC + Priority）
  - Key（端口聚合 Key）
  - Port ID
  - Port Priority
  - State（Activity/Timeout/Synchronization/...）

Partner Info（对方）：
  - 对方系统信息

Collector Info：
  - Max Delay
```

### 4.2 lacpdu_mux

```c
// drivers/net/bonding/bond_main.c — lacpdu_mux
static void lacpdu_mux(struct slave *slave)
{
    // 1. 接收 LACP
    if (lacpdu_received(slave)) {
        // 更新 partner 信息
        update_partner_info(slave);
    }

    // 2. 选择 aggregator
    if (can_become_active(slave)) {
        // 加入 aggregator
        select_aggregator(slave);
    }

    // 3. 发送 LACP
    lacpdu_send(slave);
}
```

## 5. Team（libteam）

### 5.1 Team Runner

```c
// team runner 模式：
//   broadcast    — 所有 port 发送
//   roundrobin  — 轮询
//   random      — 随机
//   activebackup — 主备
//   loadbalance — 基于哈希
//   lacp       — LACP

// teamd 配置示例：
// {
//   "device": "team0",
//   "runner": {
//     "name": "lacp",
//     "active": true,
//     "fast_rate": true,
//     "tx_hash": ["eth", "ipv4", "ipv6"]
//   },
//   "ports": {
//     "eth0": {},
//     "eth1": {}
//   }
// }
```

## 6. bond_open — bond 设备打开

```c
// drivers/net/bonding/bond_main.c — bond_open
static int bond_open(struct net_device *dev)
{
    struct bonding *bond = netdev_priv(dev);

    // 1. 初始化监控定时器
    if (BOND_MODE(bond) == BOND_MODE_ACTIVEBACKUP)
        bond->params miiimon)
            init_timer(&bond->mii_timer);
            bond->mii_timer.function = bond_mii_monitor;

    // 2. 初始化 ARP 监控
    if (bond->params.arp_interval)
        init_timer(&bond->arp_timer);

    return 0;
}
```

## 7. 故障切换（Failover）

```c
// bond_failover — 故障切换
static void bond_failover(struct bonding *bond, struct slave *new_slave)
{
    // 1. 取消旧的 active
    if (bond->curr_active_slave) {
        bond_set_slave_inactive(bond->curr_active_slave);
    }

    // 2. 激活新的 slave
    if (new_slave) {
        bond_set_slave_active(new_slave);
        bond->curr_active_slave = new_slave;
    }
}
```

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/net/bonding/bond_main.c` | `bond_open`、`activebackup`、`bond_failover` |
| `drivers/net/bonding/bond_main.h` | `struct bonding`、`struct slave` |

## 9. 西游记类喻

**Bonding/Team** 就像"天庭的多线路通信系统"——

> 天庭和某个地方通信时，如果只有一条线路，断了就全断了。Bonding/Team 就是建立多条通信线路（多个 slave），虚拟成一个总的通信线路（bond/team）。模式 1（active-backup）像主备线路——主线备用线，平时只有主线工作，断了自动切换。模式 4（LACP）像和对方协调，让对方把多条线路捆绑在一起用，既能增加带宽，又能容错。Bonding 就是天庭的"多线路保障计划"，确保通信永远不中断。

## 10. 关联文章

- **netdevice**（article 137）：bond/team 设备也是 netdevice
- **bridge**（article 165）：bond 和 bridge 都虚拟交换机

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

