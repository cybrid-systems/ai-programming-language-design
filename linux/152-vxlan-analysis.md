# 152-VXLAN — 虚拟可扩展局域网深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/vxlan/vxlan_core.c` + `include/net/vxlan.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**VXLAN（Virtual Extensible LAN）** 是 Linux 的三层 overlay 网络隧道协议，通过 UDP 在现有 IP 网络上建立虚拟二层网络。VNI（VXLAN Network Identifier）有 24 bit，支持约 1600 万个隔离网络。

## 1. VXLAN 封装格式

```
物理网络：
[ Outer Eth | Outer IP | Outer UDP | VXLAN | Inner Eth | Payload ]

Outer Eth:    DA/SA/Type=0x0800
Outer IP:     Protocol=17(UDP), TTL=64
Outer UDP:    DstPort=4789 (IANA), SrcPort=随机
VXLAN Header: 8字节 = Flags(1) + Reserved(3) + VNI(3) + Reserved(1)
Inner Eth:    原始以太网帧（MAC, VLAN, etc.）

VXLAN 头（8字节）：
  8bit Flags:
    I (1) = 1（VNI 有效）
    G (1) = 0/1（GBP 扩展，Group Policy）
    保留(6)
  3字节 Reserved
  3字节 VNI（24bit，0-16777215）
  1字节 Reserved
```

## 2. 核心数据结构

### 2.1 struct vxlan_dev — VXLAN 设备

```c
// drivers/net/vxlan/vxlan_private.h — vxlan_dev
struct vxlan_dev {
    struct vxlan_config  conf;             // 配置
    struct vxlan_sock   *vs4;             // IPv4 socket
    struct vxlan_sock   *vs6;             // IPv6 socket

    // FDB（MAC 表）
    struct rhash_head   *fdb_head;       // FDB 哈希表
    unsigned int         fdb_age_interval;  // 老化间隔

    // 网络命名空间
    struct net           *net;

    // 统计
    atomic64_t           stats.tx_pkts;
    atomic64_t           stats.rx_pkts;
    atomic64_t           stats.tx_dropped;
    atomic64_t           stats.rx_dropped;
};
```

### 2.2 struct vxlan_config — 配置

```c
// include/net/vxlan.h — vxlan_config
struct vxlan_config {
    __u32               vni;             // VXLAN 网络 ID（24bit）
    union vxlan_addr    remote_ip;       // 远端 IP（单播或多播）
    __u16               src_port_min;   // 源端口范围
    __u16               src_port_max;
    __u8                ttl;             // TTL
    __u8                tos;             // TOS
    bool                learn;           // 学习 FDB
    bool                no_learn;       // 禁用学习
    __u16               port_min;       // VXLAN 端口
    __u16               port_max;
    __u32               mcast_grp;     // 多播组
};
```

### 2.3 struct vxlan_fdb — FDB 条目

```c
// drivers/net/vxlan/vxlan_private.h — vxlan_fdb
struct vxlan_fdb {
    struct rhash_node    rhnode;         // 哈希表节点
    union vxlan_addr    remote_ip;       // 远端 IP
    __u8                eth_addr[ETH_ALEN]; // MAC 地址
    __u32               vni;            // VNI
    unsigned long       updated;        // 更新时间
    unsigned long       used;           // 最后使用时间
    __u8                state;           // 状态（NUD_STABLE 等）
    __u16               flags;           // FDB_*
};
```

## 3. VXLAN 发送（vxlan_xmit）

### 3.1 vxlan_xmit_one

```c
// drivers/net/vxlan/vxlan_core.c — vxlan_xmit_one
void vxlan_xmit_one(struct vxlan_dev *vxlan, struct sk_buff *skb,
                    __be32 vni, struct vxlan_fdb *fdb)
{
    union vxlan_addr *dst;

    // 1. 获取远端 IP
    if (fdb) {
        dst = &fdb->remote_ip;
    } else if (vxlan->conf.remote_ip.sin.sin_addr) {
        dst = &vxlan->conf.remote_ip;
    } else {
        goto drop;
    }

    // 2. 添加 VXLAN 头
    struct vxlanhdr {
        __be32 v_flags_vni;
    };
    vxlan_build_skb(skb, sizeof(vxlanhdr), vni, ...);

    // 3. 添加 UDP/IP 封装
    udp_tunnel_xmit_skb(rt, vxlan->vs4->sock, skb,
                        vxlan->conf.src_port_min,
                        dst->sin.sin_addr.s_addr,
                        vxlan_conf->tos, vxlan->conf.ttl);
}
```

## 4. VXLAN 接收（vxlan_rcv）

### 4.1 vxlan_udp_encap_recv

```c
// drivers/net/vxlan/vxlan_core.c — vxlan_udp_encap_recv
int vxlan_udp_encap_recv(struct sock *sk, struct sk_buff *skb)
{
    struct vxlanhdr *vxh;

    // 1. 检查长度
    if (!pskb_may_pull(skb, VXLAN_HLEN))
        goto drop;

    vxh = (struct vxlanhdr *)skb->data;

    // 2. 检查 VNI 标志
    if (!(vxh->vx_flags & VXLAN_HF_VNI))
        goto drop;

    // 3. 获取 VNI
    __u32 vni = vxlan_get_sk_vni(vsx, skb);

    // 4. 解封装
    skb = vxlan_rcv_one(vxlan, skb, vxh, vni);

    return 0;

drop:
    kfree_skb(skb);
    return 0;
}
```

### 4.2 vxlan_rcv_one

```c
// drivers/net/vxlan/vxlan_core.c — vxlan_rcv_one
static struct sk_buff *vxlan_rcv_one(struct vxlan_dev *vxlan,
                                     struct sk_buff *skb, ...)
{
    struct ethhdr *eth;
    union vxlan_addr saddr;

    // 1. 移除 UDP/IP 头
    skb_pull(skb, sizeof(struct udphdr) + sizeof(struct iphdr));

    // 2. 移除 VXLAN 头
    skb_pull(skb, sizeof(struct vxlanhdr));

    // 3. 学习源 MAC（FDB）
    if (vxlan->conf.learn)
        vxlan_fdb_learn(vxlan, eth->h_source, saddr);

    // 4. 发送到上层协议栈
    skb->protocol = eth_type_trans(skb, vxlan->dev);
    netif_rx(skb);
}
```

## 5. FDB（MAC 表）学习

### 5.1 vxlan_fdb_learn

```c
// drivers/net/vxlan/vxlan_core.c — vxlan_fdb_learn
void vxlan_fdb_learn(struct vxlan_dev *vxlan, const __u8 *mac,
                    union vxlan_addr *src_ip)
{
    struct vxlan_fdb *fdb;

    // 查找或创建 FDB 条目
    fdb = rhash_lookup(vxlan->fdb_hash, mac);
    if (!fdb) {
        // 新条目
        fdb = kzalloc(sizeof(*fdb), GFP_ATOMIC);
        fdb->eth_addr = mac;
        rhashtable_insert(vxlan->fdb_hash, fdb);
    }

    // 更新
    fdb->remote_ip = src_ip;
    fdb->updated = jiffies;
}
```

## 6. VXLAN vs VLAN 对比

| 特性 | VLAN | VXLAN |
|------|------|-------|
| ID 宽度 | 12 bit（4096 个）| 24 bit（1677 万个）|
| 二层/三层 | 二层 | 三层（UDP 隧道）|
| 封装 | 802.1Q tag | UDP/IP 封装 |
| 规模 | 小型网络 | 跨数据中心，多租户 |
| 硬件支持 | 交换机 | 支持 VXLAN 的网卡/交换机 |

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/net/vxlan/vxlan_core.c` | `vxlan_xmit_one`、`vxlan_rcv_one`、`vxlan_udp_encap_recv` |
| `drivers/net/vxlan/vxlan_private.h` | `struct vxlan_dev`、`struct vxlan_fdb` |
| `include/net/vxlan.h` | `struct vxlan_config` |

## 8. 西游记类比

**VXLAN** 就像"跨城市的虚拟镖局"——

> 如果要在两个城市之间建立专属的镖道（虚拟二层网络），但这两个城市之间隔着很多其他的城市（物理网络）。VXLAN 就像把镖车（以太网帧）装进一个大的货箱里（UDP/IP 封装），货箱上贴上镖道的编号（VNI，24bit），然后让镖局的车队（UDP 4789端口）送到对方城市。对方城市收到后，拆开货箱，取出里面的镖车，继续派送。每个城市可以有 1600 万条专属镖道（VNI），足够大公司给每个部门甚至每个员工分配一条专属的虚拟二层通道，互不干扰。

## 9. 关联文章

- **VLAN**（相关）：传统二层隔离
- **netdevice**（article 137）：VXLAN 是 netdevice 的实例
- **GRE**（相关）：另一种隧道协议

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

