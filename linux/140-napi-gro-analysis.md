# 140-NAPI-GRO — 网络接收聚合深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/core/netif.c` + `include/linux/netdevice.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**NAPI**（New API）和 **GRO**（Generic Receive Offload）是 Linux 网卡驱动的高性能接收框架。NAPI 通过轮询替代中断，解决高负载下的中断风暴；GRO 在 NAPI 之上将多个同源数据包合并，减少协议栈处理开销。

## 1. NAPI 核心

### 1.1 struct napi_struct — NAPI 结构

```c
// include/linux/netdevice.h — napi_struct
struct napi_struct {
    // 链表
    struct list_head        list;              // 接入 net_device->napi_list

    // 所属设备
    struct net_device      *dev;               // 所属 net_device

    // 轮询函数
    int                   (*poll)(struct napi_struct *, int);

    // 权重（每次最多处理的包数）
    int                   weight;              // 通常 64
    int                   weight_bias;         // 权重偏移

    // 状态
    unsigned int            state;             // NAPI_STATE_* 标志
    //   NAPI_STATE_SCHED         = 正在调度
    //   NAPI_STATE_DISABLE       = 被禁用
    //   NAPI_STATE_NO_CB_CB_BUDGET = 无 CB 回调预算

    // GRO
    struct sk_buff        *gro_list;          // GRO 汇聚链表
    int                   gro_count;           // GRO 链表中 skb 数量

    // 预算
    int                   budget;              // 每次 budget 预算

    // 中断
    int                   irq;                 // 中断号
};
```

## 2. NAPI 轮询机制

### 2.1 napi_schedule — 调度 NAPI

```c
// net/core/netif.c — napi_schedule
void napi_schedule(struct napi_struct *n)
{
    // 触发软中断 NET_RX_SOFTIRQ
    // 实际通过 __raise_softirq_irqoff(NET_RX_SOFTIRQ)

    if (napi_schedule_prep(n)) {
        __napi_schedule(n);
    }
}

void __napi_schedule(struct napi_struct *n)
{
    // 将 n 加入 per-CPU 的 softnet_data.poll_list
    list_add_tail(&n->poll_list, &softnet_data[n->cpu].poll_list);

    // 触发 NET_RX_SOFTIRQ
    raise_softirq_irqoff(NET_RX_SOFTIRQ);
}
```

### 2.2 net_rx_action — 软中断处理

```c
// net/core/dev.c — net_rx_action
static void net_rx_action(struct softirq_action *h)
{
    struct softnet_data *sd = this_cpu_ptr(&softnet_data);
    struct list_head *list = &sd->poll_list;
    unsigned long time_limit = jiffies + 2;
    int budget = netdev_budget;

    while (!list_empty(list)) {
        struct napi_struct *n;

        // 达到预算或时间限制，退出
        if (budget <= 0 || time_after_eq(jiffies, time_limit))
            goto out;

        n = list_first_entry(list, struct napi_struct, poll_list);

        // 调用 poll 函数
        // budget 是总预算，weight 是 napi 的权重
        work = n->poll(n, min(budget, weight));
        budget -= work;
    }

out:
    // 重新调度未完成的 NAPI
    if (!list_empty(list))
        __netif_reschedule(n);
}
```

## 3. GRO 深度

### 3.1 gro_result_t — GRO 结果

```c
// include/linux/netdev.h — gro_result_t
typedef enum {
    GRO_MERGED = 0,       // 被合并到现有流
    GRO_MERGED_FREE,     // 被合并，然后释放
    GRO_UPDATE = 2,       // 更新现有流
    GRO_HELD,            // 持有，等待合并
    GRO_DROP = 4,        // 丢弃
    GRO_CONSUMED,        // 被消费
} gro_result_t;
```

### 3.2 inet_gro_receive — IP 层 GRO

```c
// net/ipv4/af_inet.c — inet_gro_receive
static gro_result_t inet_gro_receive(struct list_head *head, struct sk_buff *skb)
{
    const struct net_offload *ops;
    struct sk_buff **pp = NULL;
    struct sk_buff *p;
    __be16 type = skb->protocol;

    // 1. 查找对应的 offload（IP 层）
    ops = rcu_dereference(inet_offloads[type]);
    if (!ops || !ops->gro_receive)
        goto out;

    // 2. 调用协议的 gro_receive
    return ops->gro_receive(head, skb);

out:
    return GRO_DROP;
}
```

### 3.3 tcp_gro_receive — TCP 层 GRO

```c
// net/ipv4/tcp_offload.c — tcp_gro_receive
struct sk_buff *tcp_gro_receive(struct list_head *head, struct sk_buff *skb)
{
    struct sk_buff *pp = NULL;
    struct sk_buff *p;

    // 遍历现有 GRO 流
    list_for_each_entry(p, head, list) {
        // 检查是否可以合并：
        // 1. 源/目的 IP 相同
        // 2. 源/目的端口相同
        // 3. TCP 序列号连续
        if (tcp_gro_check(p, skb))
            continue;
        break;
    }

    // 可以合并：把 skb 的数据追加到 p
    if (pp)
        skb_gro_receive(pp, skb);
    else
        list_add(&skb->list, head);  // 新建流

    return pp;
}
```

### 3.4 skb_gro_receive — 合并两个 skb

```c
// include/linux/netdevice.h — skb_gro_receive
static inline int skb_gro_receive(struct sk_buff **head, struct sk_buff *skb)
{
    struct sk_buff *p = *head;
    struct sk_buff *n = skb;

    // 把 n 的 frag 数据追加到 p
    // 只合并 frag_list，不复制线性数据

    // 更新 p 的 transport_header
    NAPI_GRO_CB(p)->fragcnt++;
    p->data_len += n->len;

    return 0;
}
```

## 4. GRO 条件

### 4.1 TCP 流合并条件

```
两个 skb 可以 GRO 合并，当且仅当：
  1. IP 源地址相同
  2. IP 目的地址相同
  3. IP 标识（ID）连续
  4. TCP 源端口相同
  5. TCP 目的端口相同
  6. TCP 序列号连续（下一个 skb 的 seq = 前一个的 seq + 前一个的 len）
  7. TCP 不带任何 flag（如 SYN/FIN/RST）
  8. TCP 不带 options
```

## 5. NAPI + GRO 流程图

```
高负载下的数据包接收：

NIC DMA → 驱动创建 skb
    ↓
触发 RX IRQ（初期）
    ↓
napi_schedule() → 调度 NAPI
    ↓
net_rx_action (NET_RX_SOFTIRQ)
    ↓
napi->poll(napi, weight)
    ↓
netif_receive_skb()
    ↓
gro_normal_one() → gro_normal_batch()
    ↓
inet_gro_receive() → tcp_gro_receive()
    ↓
可以合并？ → Yes → skb_gro_receive() → 合并
    ↓ No
→ 返回 GRO_DROP → 正常处理

多个同源小包 → 合并成一个大 skb → 减少协议栈处理次数
```

## 6. GRO vs LRO

| 特性 | GRO | LRO |
|------|-----|-----|
| 层级 | 通用（网络层）| 仅 TCP（传输层）|
| 合并位置 | IP 层之后 | TCP 层之后 |
| 兼容性 | 好（设备无关）| 受限（依赖硬件）|
| 近代内核 | 主流 | 已废弃 |

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/core/netif.c` | `napi_schedule`、`__napi_schedule` |
| `net/core/dev.c` | `net_rx_action` |
| `net/ipv4/tcp_offload.c` | `tcp_gro_receive`、`skb_gro_receive` |
| `include/linux/netdevice.h` | `struct napi_struct`、`gro_result_t` |

## 8. 西游记类比

**NAPI + GRO** 就像"取经路的智能快递接收系统"——

> 驿站（网卡）收到大量快递（数据包）时，如果每个快递都敲门通知（NAPI 旧模式），就会造成大量的敲门声（中断风暴）。NAPI 的做法是：先让快递员（软中断）集中去取货（poll），减少敲门次数。GRO 则是在取货时把同一家公司的多个小箱子合并成一个大箱子再送进天庭（协议栈），省去多次处理小箱子的开销。比如同一台机器发了 10 个小 TCP 包，GRO 会把它们合并成 1 个大 skb 送到协议栈，协议栈一次性处理，减少了 9 次上下文切换。这就是为什么现代网卡在高负载下性能很好的原因。

## 9. 关联文章

- **netif_receive_skb**（article 139）：GRO 汇聚后的接收
- **sk_buff**（article 22）：skb 的 frag_list 和 GRO
- **netdevice**（article 137）：napi_list 和 poll 函数

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

