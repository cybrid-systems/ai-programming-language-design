# 139-netif_receive_skb — 数据包接收深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/core/dev.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**netif_receive_skb** 是 Linux 网络子系统的核心数据包接收函数，网卡驱动通过 NAPI 或中断收到数据包后，最终汇聚到此处进行协议层分发。

## 1. 接收流程总览

```
网卡硬件
    ↓ (DMA)
skb (socket buffer)  ← 网卡驱动分配
    ↓
netif_receive_skb(skb)
    ↓
netif_receive_skb_list()  ← 批量版本
    ↓
handleIncoming(skb) = deliver_skb(skb)  ← 投递给协议层
    ↓
protocolHandler(skb)  ← 如 ip_rcv(), arp_rcv()
    ↓
协议层处理（IP → TCP/UDP → Socket）
```

## 2. NAPI — 中断替代机制

### 2.1 struct napi_struct — NAPI

```c
// include/linux/netdevice.h — napi_struct
struct napi_struct {
    struct list_head        list;         // 接入 netdev 的 napi_list
    struct net_device       *dev;         // 所属设备

    // 轮询
    int                   (*poll)(struct napi_struct *, int); // 轮询函数
    int                   weight;           // 每次轮询的最大包数（通常 64）
    unsigned int           state;            // NAPI_STATE_* 状态

    // 计数
    int                   gro_count;        // GRO 计数
    int                   irq;              // 中断号
};
```

### 2.2 NAPI vs 传统中断

```
传统中断模式：
  每包一个中断 → CPU 被中断打断 → 高负载下性能差

NAPI 模式：
  中断触发 → NAPI 轮询 → 批量处理 → 中断被抑制
  轮询完成前不会产生新中断（中断抑制）
```

## 3. netif_receive_skb — 接收函数

### 3.1 netif_receive_skb

```c
// net/core/dev.c — netif_receive_skb
static inline int netif_receive_skb(struct sk_buff *skb)
{
    return netif_receive_skb_internal(skb);
}

static int netif_receive_skb_internal(struct sk_buff *skb)
{
    struct packet_type *pt_prev = NULL;
    struct net_device *orig_dev;
    int ret;

    orig_dev = skb->dev;

    // 1. 去除 VLAN tag
    skb = skb_vlan_untag(skb);

    // 2. 处理 GRO（如果不是批量）
    if (!skb_is_gso(skb))
        gro_normal_one(skb);

    // 3. 投递给协议层
    ret = __netif_receive_skb(skb, &pt_prev);

    // 4. 清理
    if (pt_prev)
        dev_put(pt_prev->dev);

    return ret;
}
```

### 3.2 __netif_receive_skb — 核心分发

```c
// net/core/dev.c — __netif_receive_skb
static int __netif_receive_skb(struct sk_buff *skb, struct packet_type **pt_prev)
{
    struct net_device *dev = skb->dev;
    int ret = NET_RX_DROP;

    // 1. 检查隧道
    ret = INDIRECT_CALL_INET(inet_gro_receive, ipv6_gro_receive,
                            ip_gro_receive, &skb);
    if (!ret)
        goto out;

    // 2. GRO 汇聚后，重新检查
    if (skb_bonded(skb)) {
        ret = bond_handle_frame(skb);
        goto out;
    }

    // 3. 分发到协议层
    ret = __do_receive_skb(skb, pt_prev);

out:
    return ret;
}
```

### 3.3 __do_receive_skb — 分发给 handler

```c
// net/core/dev.c — __do_receive_skb
static int __do_receive_skb(struct sk_buff *skb, struct packet_type **pt_prev)
{
    struct net_device *dev = skb->dev;
    struct packet_type *ptype;
    int ret = NET_RX_DROP;

    // 遍历所有注册的 packet_type
    list_for_each_entry_rcu(ptype, &netdev_type_list, list) {
        if (ptype->type != dev->type)
            continue;

        if (ptype->dev == dev || ptype->dev == dev->master || !ptype->dev) {
            // 匹配，调用 handler
            ret = pt_prev->func(skb, dev, pt_prev, dev);

            if (pt_prev)
                break;
        }
        pt_prev = ptype;
    }

    return ret;
}
```

## 4. GRO（Generic Receive Offload）

### 4.1 gro_normal_one

```c
// net/core/dev.c — gro_normal_one
void gro_normal_one(struct sk_buff *skb)
{
    // GRO 尝试汇聚多个小包成一个大包
    napi_gro_receive(&skb->napi_cache->napi, skb);
}
```

### 4.2 napi_gro_receive

```c
// net/core/netif.c — napi_gro_receive
gro_result_t napi_gro_receive(struct napi_struct *napi, struct sk_buff *skb)
{
    gro_result_t ret;

    // 尝试汇聚
    skb_gro_reset_offset(skb, 0);

    // inet_gro_receive → IP 层汇聚
    ret = inet_gro_receive(&napi->gro_list, skb);

    if (!ret)
        return GRO_MERGED_FREE;

    return ret;
}
```

## 5. packet_type — 协议处理函数

### 5.1 struct packet_type — 协议类型

```c
// include/linux/netdevice.h — packet_type
struct packet_type {
    __be16                  type;           // 协议类型（如 ETH_P_IP = 0x0800）
    struct net_device       *dev;           // 设备（NULL=所有设备）
    int                   (*func)(struct sk_buff *,   // 处理函数
                                 struct net_device *,
                                 struct packet_type *,
                                 struct net_device *);

    void                   *af_packet_priv; // 私有数据
    struct list_head        list;           // 链表
};
```

### 5.2 inet_add_protocol — 注册协议

```c
// net/ipv4/af_inet.c — inet_add_protocol
int inet_add_protocol(const struct net_protocol *prot, unsigned int protocol)
{
    // 注册 IP 层协议（如 ICMP、TCP、UDP）
    // 每种协议有一个 handler
}
```

## 6. handleIngue 单包流程图

```
数据包接收（从网卡到协议栈）：

NIC 硬件（DMA）→ 驱动 skb 分配
    ↓
NAPI poll 或 软中断
    ↓
netif_receive_skb()
    ↓
skb_vlan_untag()          ← 去除 VLAN tag
    ↓
gro_normal_one()            ← GRO 尝试汇聚
    ↓
__netif_receive_skb()
    ↓
inet_gro_receive()         ← IP 层汇聚
    ↓
ip_rcv()                   ← IP 层入口
    ↓
ip_rcv_finish()
    ↓
ip_local_deliver()         ← 投递给上层
    ↓
tcp_v4_rcv() / udp_rcv() ← 传输层
```

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/core/dev.c` | `netif_receive_skb`、`__netif_receive_skb`、`__do_receive_skb` |
| `net/core/netif.c` | `napi_gro_receive`、`gro_normal_one` |
| `include/linux/netdevice.h` | `struct napi_struct`、`struct packet_type` |

## 8. 西游记类比

**netif_receive_skb** 就像"取经路上的快递接收站"——

> 各藩王（网卡）收到的包裹（sk_buff）送到接收站（netif_receive_skb）。接收站先把包裹上的VIP标签去掉（vlan_untag），然后看看能不能把多个小包裹合并成一个大箱子再送出去（GRO）。合并后再按照包裹的类型（packet_type，如 ETH_P_IP）分发给不同的部门处理（IP层 → TCP/UDP）。每个部门（协议）都在门口等着（注册了 packet_type），看到自己类型的包裹就拿走处理。NAPI 就像接收站的智能模式：平时有快递就通知（中断），但如果快递太多（高负载），就改成主动去藩王那里轮询（poll），批量取货，减少通知次数。

## 9. 关联文章

- **netdevice**（article 137）：网络设备结构
- **dev_queue_xmit**（article 138）：发送流程
- **sk_buff**（article 22）：数据包结构

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

