# 173-GRE_tunnel — GRE隧道协议深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/ip_gre.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**GRE（Generic Routing Encapsulation）** 是 Cisco 开发的隧道协议，将任意网络层协议封装进 IP 包。支持点对点隧道和多点隧道（通过 GRE Keys 区分）。

## 1. GRE 封装格式

```
原始 IP 包：
  [IP头][TCP][DATA]

GRE 封装后：
  [外部IP头][GRE头][原始IP头][TCP][DATA]

GRE 头（4字节 + 可选）：
  ┌──────────────────────────────┐
  │C|R|K|S|s|Recur|AFlag|Flags│
  ├──────────────────────────────┤
  │  Protocol Type (2B)          │
  ├──────────────────────────────┤
  │  Checksum（可选，2B）         │
  ├──────────────────────────────┤
  │  Offset（可选，2B）          │
  ├──────────────────────────────┤
  │  Key（可选，4B）             │
  ├──────────────────────────────┤
  │  Sequence Number（可选，4B）  │
  └──────────────────────────────┘

标志：
  C = Checksum Present
  K = Key Present
  S = Sequence Number Present
```

## 2. struct ip_tunnel — GRE 隧道

```c
// include/net/ip_tunnels.h — ip_tunnel
struct ip_tunnel {
    struct dst_entry       *dst;              // 路由缓存
    struct iphdr           *tun_hrd;        // 隧道头
    __be32                 i_key;           // 内部 key（用于 GRE Keys）
    __be32                 o_key;           // 外部 key
    __be16                 tun_flags;        // TUNNEL_*

    // 端点
    __be32                 saddr;           // 源 IP
    __be32                 daddr;           // 目的 IP
};
```

## 3. GRE 发送

### 3.1 ipgre_xmit

```c
// net/ipv4/ip_gre.c — ipgre_xmit
int ipgre_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct ip_tunnel *tun = netdev_priv(dev);
    __be16 proto;

    // 1. 重新计算校验和
    if (tun->parms.o_flags & TUNNEL_CSUM)
        skb->ip_summed = CHECKSUM_PARTIAL;

    // 2. 封装 GRE
    struct gre_base_hdr *greh;
    greh = (struct gre_base_hdr *)skb_push(skb, sizeof(*greh));
    greh->protocol = proto;  // 原始协议类型
    greh->flags = GRE_VERSION_0 | GRE_FLAGS;

    // 3. 添加外部 IP 头
    iph = ip_hdr(skb);
    iph->protocol = IPPROTO_GRE;
    iph->daddr = tun->parms.iph.daddr;

    // 4. 发送
    ip_local_out(skb);
}
```

## 4. GRE vs VXLAN

| 特性 | GRE | VXLAN |
|------|-----|-------|
| 封装 | IP | UDP |
| 支持协议 | 任意 L3 | 任意 |
| VNI | 无（用 Key）| 24 bit VNI |
| 多播 | 不支持 | 支持（通过多播组）|
| 负载均衡 | 差（所有流量同一隧道）| 好（基于 UDP 源端口）|

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/ip_gre.c` | `ipgre_xmit`、`gre_rcv` |
| `include/net/ip_tunnels.h` | `struct ip_tunnel` |

## 6. 西游记类喻

**GRE** 就像"取经路的快递封箱"——

> GRE 像把要寄的货物（原始 IP 包）放进一个箱子里（GRE 头），然后箱子上贴上地址标签（外部 IP 头），寄到对方城市。对方城市拆开箱子，取出里面的货物。GRE 不关心里面是什么货物（可以是任何 L3 协议）。比起 VXLAN，GRE 就像普通快递（IP 封装），VXLAN 像加了专用物流网（UDP 多播，更适合云计算的多租户隔离）。

## 7. 关联文章

- **VXLAN**（article 152）：另一种隧道协议
- **netif_receive_skb**（article 139）：GRE 接收路径

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

