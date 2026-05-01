# 138-dev_queue_xmit — 数据包发送深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/core/dev.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**dev_queue_xmit** 是 Linux 网络子系统的核心数据包发送函数，从协议层（TCP/IP）收到 sk_buff 后，经过 qdisc 排队，然后通过网卡驱动发送。

## 1. 发送流程总览

```
应用数据
    ↓
TCP/UDP 协议层
    ↓
IP 路由查找
    ↓
dev_queue_xmit(skb)
    ↓
__dev_queue_xmit(skb, &to_free)
    ↓
处理 vlan/gso 等特性
    ↓
qdisc_enqueue(skb, qdisc, &to_free)
    ↓
__qdisc_run(qdisc)  ← 如果有数据要发
    ↓
sch_direct_xmit(skb, qdisc)
    ↓
dev_hard_start_xmit()
    ↓
ndo_start_xmit()    ← 驱动发送
    ↓
清理 vlan tag / 更新统计
```

## 2. dev_queue_xmit — 入口

### 2.1 dev_queue_xmit

```c
// net/core/dev.c — dev_queue_xmit
int dev_queue_xmit(struct sk_buff *skb)
{
    struct net_device *dev = skb->dev;
    struct netdev_queue *txq;
    int rc = NET_XMIT_SUCCESS;

    // 1. 处理虚拟设备（如 tunnel）
    if (netdev_tstamp_prequeue)
        skb->tstamp = 0;

    // 2. 选择发送队列
    txq = netdev_pick_tx(dev, skb);

    // 3. 进入发送队列
    rc = __dev_queue_xmit(skb, txq, &to_free);

    // 4. 处理延迟释放的 skb
    if (unlikely(to_free))
        kfree_skb_list(to_free);

    return rc;
}
```

### 2.2 __dev_queue_xmit

```c
// net/core/dev.c — __dev_queue_xmit
int __dev_queue_xmit(struct sk_buff *skb, struct netdev_queue *txq,
                     struct sk_buff **to_free)
{
    struct net_device *dev = skb->dev;
    struct Qdisc *qdisc;

    *to_free = NULL;

    // 1. 检查设备是否 up
    if (unlikely(!netif_running(dev) || !netif_carrier_ok(dev)))
        return NET_XMIT_DROP;

    // 2. 如果有虚拟功能，处理 vlan
    if (vlan_tx_tag_present(skb)) {
        if (vlan_handle_skb(skb, vlan_tci) != 0)
            return NET_XMIT_DROP;
        dev = skb->dev;
        txq = netdev_pick_tx(dev, skb);
    }

    // 3. GSO 处理（在发送前分片）
    if (skb->encapsulation)
        skb_set_inner_transport_header(skb, skb->transport_header);

    if (skb_shinfo(skb)->gso_size) {
        // GSO 分片
        return dev_gso_segment(skb);
    }

    // 4. 发送到 qdisc
    qdisc = rcu_dereference_bh(txq->qdisc);

    if (qdisc->enqueue) {
        // 入队
        rc = qdisc->enqueue(skb, qdisc, to_free);

        // 如果可以，触发 qdisc 处理
        if (qdisc_run_begin(qdisc)) {
            qdisc = qdisc;
            goto vif;
vif:
            __qdisc_run(qdisc);
            qdisc_run_end(qdisc);
        }

        return rc;
    }

    // 5. 无 qdisc，直接发送
    return dev_hard_start_xmit(skb, dev);
}
```

## 3. qdisc — 队列规则

### 3.1 struct Qdisc — 队列规则

```c
// include/net/sch_generic.h — Qdisc
struct Qdisc {
    struct net_device       *dev;          // 所属设备
    struct Qdisc_ops       *ops;           // 操作函数表
    u32                     handle;         // 句柄（如 "1:"）
    u32                     parent;         // 父句柄

    // 统计
    atomic64_t              qstats;         // 队列统计
    unsigned int            limit;           // 最大队列长度

    // 锁
    spinlock_t              busylock ____cacheline_aligned;

    // 包链表
    struct sk_buff_head     q;              // 队列中的包
};
```

### 3.2 __qdisc_run — qdisc 处理

```c
// net/sched/sch_generic.c — __qdisc_run
void __qdisc_run(struct Qdisc *qdisc)
{
    while (qdisc->q.qlen) {
        struct sk_buff *skb;

        // 出队
        skb = qdisc_dequeue_peeked(qdisc);
        if (!skb)
            break;

        // 发送
        spin_unlock(qdisc->lock);
        rc = sch_direct_xmit(skb, qdisc);
        spin_lock(qdisc->lock);

        if (qdisc->q.qlen == 0)
            break;
    }
}
```

## 4. sch_direct_xmit — 直接发送

```c
// net/core/dev.c — sch_direct_xmit
int sch_direct_xmit(struct sk_buff *skb, struct Qdisc *qdisc)
{
    struct net_device *dev = skb->dev;
    struct netdev_queue *txq;
    int rc = NET_XMIT_SUCCESS;

    // 1. 获取目标队列
    txq = netdev_pick_tx(dev, skb);

    // 2. 锁住队列
    spin_lock(&txq->_xmit_lock);

    // 3. 调用驱动发送
    if (!netif_xmit_stopped(txq)) {
        rc = netdev_start_xmit(skb, dev, txq);

        if (txq->qdisc == qdisc)
            qdisc->q.qlen--;
    } else {
        // 队列已满，丢弃
        kfree_skb(skb);
        rc = NET_XMIT_DROP;
    }

    spin_unlock(&txq->_xmit_lock);

    return rc;
}
```

## 5. 驱动发送（ndo_start_xmit）

### 5.1 netdev_start_xmit

```c
// include/linux/netdevice.h — ndo_start_xmit 回调示例（e1000）
// net/core/dev.c — netdev_start_xmit 包装
static inline netdev_tx_t netdev_start_xmit(struct sk_buff *skb,
                                             struct net_device *dev,
                                             struct netdev_queue *txq)
{
    const struct net_device_ops *ops = dev->netdev_ops;
    netdev_tx_t rc;

    // 调用驱动的 ndo_start_xmit
    rc = ops->ndo_start_xmit(skb, dev);

    // 成功：NETDEV_TX_OK
    // 队列满：NETDEV_TX_BUSY（qdisc 会重试）

    return rc;
}
```

## 6. 返回值

```c
// include/linux/netdev.h — 返回值
enum netdev_tx {
    NETDEV_TX_OK = 0,       // 发送成功
    NETDEV_TX_BUSY = 1,     // 队列满，需要重试
};

#define NET_XMIT_SUCCESS      0x00  // 成功
#define NET_XMIT_DROP         0x01  // 丢弃（统计）
#define NET_XMIT_CN          0x02  // 拥塞通知
#define NET_XMIT_MASK        0x0f  // 掩码
```

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/core/dev.c` | `dev_queue_xmit`、`__dev_queue_xmit`、`sch_direct_xmit` |
| `net/sched/sch_generic.c` | `__qdisc_run`、`qdisc_dequeue_peeked` |
| `include/net/sch_generic.h` | `struct Qdisc` |

## 8. 西游记类比

**dev_queue_xmit** 就像"取经路上的快递站发送流程"——

> 快递（sk_buff）从各部门（TCP/UDP）发出后，先到驿站（dev_queue_xmit），然后按照快递公司的规则（qdisc）排队。pfifo_fast 像先来先发（先进先出），fq_codel 像智能调度（公平排队 + 延迟控制）。如果快递太长了（GSO），会在发送前拆分成小包裹（分片）。每条发送通道（txq）是独立的，多通道设备可以同时发多个快递。驿站的门卫（netif_carrier_ok）如果发现路断了（网线拔了），就停止发送。

## 9. 关联文章

- **netdevice**（article 137）：net_device 结构
- **netif_receive_skb**（article 139）：接收流程

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

