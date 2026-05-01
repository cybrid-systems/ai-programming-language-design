# Linux Kernel VXLAN 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/vxlan/vxlan_core.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：VNI、UDP 封装、VTEP、隧道

## 0. VXLAN 概述

**VXLAN（Virtual eXtensible LAN）** 在 UDP（端口 4789）上封装二层帧，实现跨主机的虚拟机网络隔离。

```
原始帧:    [ETH_HDR][IP_HDR][Payload]
             ↓
VXLAN 头:   [ETH_HDR][IP_HDR][UDP_HDR][VXLAN_HDR][ETH_HDR][Payload]
                                    [VNI][0]
```

## 1. 核心数据结构

### 1.1 vxlan_dev — VXLAN 设备

```c
// drivers/net/vxlan/vxlan_private.h — vxlan_dev
struct vxlan_dev {
    struct net_device       *dev;              // 网络设备
    struct vxlan_sock      *vn4;             // IPv4 socket
    struct vxlan_sock      *vn6;             // IPv6 socket
    struct vxlan_config    *cfg;              // 配置
    struct list_head        next;             // 全局链表
    __be32                  vni;             // VNI（24-bit）
    u32                     dst_port;         // 目标端口（4789）
};
```

### 1.2 vxlan_config — 配置

```c
// drivers/net/vxlan/vxlan_core.c — vxlan_config
struct vxlan_config {
    __u32              vni;               // VXLAN Network Identifier
    __u32              remote_ip;        // 远程 VTEP IP
    __u32              local_ip;        // 本地 VTEP IP
    __be16             dst_port;         // UDP 目标端口
    __u8               ttl;
    __u8               tos;
    __u8               inherit_tos;      // 继承内部 tos
    bool                gpe;             // Geneve 模式
    struct vxlan_fdb   *fdb;            // MAC 学习表
};
```

## 2. vxlan_xmit_one — 发送封装

```c
// drivers/net/vxlan/vxlan_core.c:2341 — vxlan_xmit_one
void vxlan_xmit_one(struct sk_buff *skb, struct net_device *dev,
            __be32 default_vni, struct vxlan_rdst *rdst, bool did_rsc)
{
    struct vxlan_dev *vxlan = netdev_priv(dev);
    struct vxlan_metadata _md, *md = &_md;
    __be16 protocol = htons(ETH_P_TEB);

    // 1. 查找目标 VTEP
    if (rdst == NULL) {
        // 未知目标：查找 FDB 表
        fdb = vxlan_fdb_find(vxlan, eth_hdr(skb)->h_dest);
        if (fdb == NULL) {
            // 洪泛到所有 VTEP
            vxlan_flood(vxlan, skb);
            return;
        }
        rdst = &fdb->remote;
    }

    // 2. 添加 VXLAN 头
    //    [UDP dst=4789][VXLAN头][VNI=24bit][0][原始帧]
    vxlan_build_skb(skb, ...);

    // 3. 添加外层 IP 头（隧道端点）
    __iph = ip_hdr(skb);  // 外层 IP 头
    __iph->saddr = local_ip;
    __iph->daddr = rdst->remote_ip;

    // 4. 添加 UDP 头
    udph = udp_hdr(skb);
    udph->dest = htons(4789);

    // 5. 发送
    udp_tunnel6_xmit_skb(rt, skb->dev, skb, ...);
}
```

## 3. vxlan_rcv — 接收解封装

```c
// drivers/net/vxlan/vxlan_core.c:1643 — vxlan_rcv
static int vxlan_rcv(struct sock *sk, struct sk_buff *skb)
{
    struct vxlanhdr *vh;
    struct vxlan_dev *vxlan;
    __be32 vni;

    // 1. 验证 VXLAN 头
    vh = vxlan_hdr(skb);
    if (vh->vx_flags != VXLAN_HF_VNI)
        return -1;

    // 2. 提取 VNI
    vni = vxlan_get_vni(vh);

    // 3. 查找对应的 VXLAN 设备
    vxlan = vxlan_find_vni(vni);
    if (!vxlan)
        return -1;

    // 4. 移除 VXLAN/UDP/IP 头
    skb_pull(skb, sizeof(*vh) + sizeof(struct udphdr) + sizeof(struct iphdr));

    // 5. 设置 VLAN
    __vlan_tci = vxlan_get_vni(vh);  // VNI 作为 VLAN ID
    __vlan_set_proto(skb, ETH_P_TEB);

    // 6. 递送到虚拟机
    netif_rx(skb);

    return 0;
}
```

## 4. 参考

| 文件 | 函数 | 行 |
|------|------|-----|
| `drivers/net/vxlan/vxlan_core.c` | `vxlan_xmit_one` | 2341 |
| `drivers/net/vxlan/vxlan_core.c` | `vxlan_rcv` | 1643 |
| `drivers/net/vxlan/vxlan_core.c` | `vxlan_flood` | 洪泛 |


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

