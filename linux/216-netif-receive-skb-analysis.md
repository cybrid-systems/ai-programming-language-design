# netif_receive_skb — 数据包接收流程分析

> 基于 Linux 7.0-rc1 内核源码，文件：`net/core/dev.c`（13314行）、`net/core/gro.c`

## 1. 调用路径概述

数据包从网卡到协议栈，主要有两条路径：

```
路径A（老式驱动，非NAPI）：
  驱动interrupt -> netif_rx() -> netif_rx_internal() -> enqueue_to_backlog()
  -> raise_softirq_irqoff(NET_RX_SOFTIRQ)  →  net_rx_action() -> process_backlog()

路径B（NAPI + GRO，现代驱动）：
  驱动interrupt -> NAPI poll -> napi_gro_receive() -> gro_receive_skb()
  -> dev_gro_receive() -> __netif_receive_skb() -> __netif_receive_skb_one_core()
  -> __netif_receive_skb_core() -> 协议分发

路径C（netif_receive_skb，最通用）：
  netif_receive_skb() -> netif_receive_skb_internal() -> __netif_receive_skb()
  -> __netif_receive_skb_one_core() -> __netif_receive_skb_core()
```

### 调用流程图

```
NIC 驱动
  │
  ├─► netif_rx()               [dev.c:5764] （传统驱动，禁 BH）
  │     └─► netif_rx_internal() [dev.c:5692]
  │           └─► enqueue_to_backlog() [dev.c:5373]
  │                 └─► raise_softirq_irqoff(NET_RX_SOFTIRQ) [dev.c:5270]
  │                       └─► net_rx_action() [dev.c:7911]（软中断处理）
  │                             └─► process_backlog() [dev.c:6644]
  │                                   └─► __netif_receive_skb() [dev.c:6295]
  │
  ├─► napi_gro_receive()        [netdevice.h:4286] （NAPI+GRO驱动）
  │     └─► gro_receive_skb()   [gro.c:634]
  │           └─► dev_gro_receive() / __netif_receive_skb()
  │
  └─► netif_receive_skb()       [dev.c:6457] （最通用入口）
        └─► netif_receive_skb_internal() [dev.c:6379]
              └─► __netif_receive_skb() [dev.c:6295]
```

## 2. netif_receive_skb 入口和接收路径概述

`netif_receive_skb`（`dev.c:6457`）是通用的接收入口，可从软中断上下文调用：

```c
// dev.c:6447
/**
 *  netif_receive_skb - process receive buffer from network
 *  @skb: buffer to process
 *
 *  netif_receive_skb() is the main receive data processing function.
 *  It always succeeds. The buffer may be dropped during processing
 *  for congestion control or by the protocol layers.
 *
 *  This function may only be called from softirq context.
 */
int netif_receive_skb(struct sk_buff *skb)
{
    int ret;

    trace_netif_receive_skb_entry(skb);
    ret = netif_receive_skb_internal(skb);
    trace_netif_receive_skb_exit(ret);

    return ret;
}
EXPORT_SYMBOL(netif_receive_skb);
```

`netif_receive_skb_internal`（`dev.c:6379`）决定走哪条路径：

```c
// dev.c:6379
static int netif_receive_skb_internal(struct sk_buff *skb)
{
    int ret;

    net_timestamp_check(...);

    if (skb_defer_rx_timestamp(skb))
        return NET_RX_SUCCESS;

    rcu_read_lock();
#ifdef CONFIG_RPS
    if (static_branch_unlikely(&rps_needed)) {
        // RPS路径：查找目标CPU，加入该CPU的backlog队列
        cpu = get_rps_cpu(skb->dev, skb, &rflow);
        if (cpu >= 0) {
            ret = enqueue_to_backlog(skb, cpu, &rflow->last_qtail);
            rcu_read_unlock();
            return ret;
        }
    }
#endif
    // 无RPS或无映射 → 直接协议分发
    ret = __netif_receive_skb(skb);
    rcu_read_unlock();
    return ret;
}
```

## 3. __netif_receive_skb_core → enqueue_to_backlog 核心路径

### 3.1 enqueue_to_backlog

`enqueue_to_backlog`（`dev.c:5373`）将skb加入per-CPU backlog队列，若队列为空则调度NAPI：

```c
// dev.c:5373
static int enqueue_to_backlog(struct sk_buff *skb, int cpu,
                              unsigned int *qtail)
{
    enum skb_drop_reason reason;
    struct softnet_data *sd;
    unsigned long flags;
    unsigned int qlen;
    int max_backlog;
    u32 tail;

    reason = SKB_DROP_REASON_DEV_READY;
    if (unlikely(!netif_running(skb->dev)))
        goto bad_dev;

    sd = &per_cpu(softnet_data, cpu);
    qlen = skb_queue_len_lockless(&sd->input_pkt_queue);
    max_backlog = READ_ONCE(net_hotdata.max_backlog);

    if (unlikely(qlen > max_backlog) ||
        skb_flow_limit(skb, qlen, max_backlog))
        goto cpu_backlog_drop;

    backlog_lock_irq_save(sd, &flags);
    qlen = skb_queue_len(&sd->input_pkt_queue);
    if (likely(qlen <= max_backlog)) {
        if (!qlen) {
            // 队列为空，调度 backlog NAPI
            if (!__test_and_set_bit(NAPI_STATE_SCHED, &sd->backlog.state))
                napi_schedule_rps(sd);   // -> __napi_schedule_irqoff() / raise_softirq
        }
        __skb_queue_tail(&sd->input_pkt_queue, skb);  // 入队
        tail = rps_input_queue_tail_incr(sd);
        backlog_unlock_irq_restore(sd, flags);
        rps_input_queue_tail_save(qtail, tail);
        return NET_RX_SUCCESS;
    }
    backlog_unlock_irq_restore(sd, flags);

cpu_backlog_drop:
    reason = SKB_DROP_REASON_CPU_BACKLOG;
    numa_drop_add(&sd->drop_counters, 1);
bad_dev:
    dev_core_stats_rx_dropped_inc(skb->dev);
    kfree_skb_reason(skb, reason);
    return NET_RX_DROP;
}
```

### 3.2 RPS（Receive Packet Steering）

RPS通过`get_rps_cpu`（`dev.c:5107`）计算skb应投递的CPU：

```c
// dev.c:5107
static int get_rps_cpu(struct net_device *dev, struct sk_buff *skb,
                       struct rps_dev_flow **rflowp)
{
    struct netdev_rx_queue *rxqueue = dev->_rx;
    // ... 根据 skb_get_rx_queue() / hash 计算目标CPU
    // 查 rps_map / rps_dev_flow_table
}
```

### 3.3 napi_schedule_rps

`napi_schedule_rps`（`dev.c:5284`）调度backlog NAPI：

```c
// dev.c:5284
static void napi_schedule_rps(struct softnet_data *sd)
{
#ifdef CONFIG_RPS
    if (cpu_online(cpu)) {
        struct softnet_data *mysd = &per_cpu(softnet_data, cpu);
        if (cpu != smp_processor_id())
            // 跨CPU：发送IPI中断触发软中断
            sdp = &per_cpu(softnet_data, cpu);
            sd->rps_ipi_list = ...;
        else
            // 本地CPU：直接调度
            __napi_schedule_irqoff(&sd->backlog);
    } else {
        // CPU不在线，直接raise软中断
        __raise_softirq_irqoff(NET_RX_SOFTIRQ);
    }
#endif
}
```

## 4. netif_rx → netif_rx_internal → raise_softirq_irqoff(NET_RX_SOFTIRQ)

`netif_rx`（`dev.c:5764`）是传统驱动（非NAPI）的入口：

```c
// dev.c:5764
int netif_rx(struct sk_buff *skb)
{
    bool need_bh_off = !(hardirq_count() | softirq_count());
    int ret;

    if (need_bh_off)
        local_bh_disable();          // 禁止底部半部
    trace_netif_rx_entry(skb);
    ret = netif_rx_internal(skb);     // -> enqueue_to_backlog -> raise_softirq
    trace_netif_rx_exit(ret);
    if (need_bh_off)
        local_bh_enable();
    return ret;
}
```

`netif_rx_internal`（`dev.c:5692`）实际执行入队，路径与上面完全一致：通过`enqueue_to_backlog`入队后，在`enqueue_to_backlog`内部（`dev.c:5270`）触发`NET_RX_SOFTIRQ`软中断：

```c
// dev.c:5270（位于____napi_schedule内）
if (!sd->in_net_rx_action)
    raise_softirq_irqoff(NET_RX_SOFTIRQ);
```

> `open_softirq(NET_RX_SOFTIRQ, net_rx_action)` 在`net_dev_init`（`dev.c:13286`）中注册。

## 5. napi_gro_receive 和 NAPI 轮询机制

### 5.1 napi_gro_receive

`napi_gro_receive`（`netdevice.h:4286`）是inline函数，直接调用`gro_receive_skb`：

```c
// netdevice.h:4286
static inline gro_result_t napi_gro_receive(struct napi_struct *napi,
                                            struct sk_buff *skb)
{
    return gro_receive_skb(&napi->gro, skb);
}
```

`gro_receive_skb`（`gro.c:634`）执行GRO（Generic Receive Offload）合并逻辑：

```c
// gro.c:634
gro_result_t gro_receive_skb(struct gro_node *gro, struct sk_buff *skb)
{
    __skb_mark_napi_id(skb, gro);
    trace_napi_gro_receive_entry(skb);
    skb_gro_reset_offset(skb, 0);
    ret = gro_skb_finish(gro, skb, dev_gro_receive(gro, skb));
    trace_napi_gro_receive_exit(ret);
    return ret;
}
```

`dev_gro_receive`（`gro.c`）尝试将skb与GRO哈希表中已有的skb合并，失败则排队。`gro_skb_finish`根据返回值处理：
- `GRO_NORMAL`：调用`gro_normal_one()`将skb送入`gro->rx_list`，批量累积后通过`gro_normal_list()`批量上送协议栈
- `GRO_MERGED`：已合并，直接完成
- `GRO_HELD`：保留待定
- `GRO_MERGED_FREE`：释放

### 5.2 gro_normal_one 与批量上送

```c
// include/net/gro.h:537
static inline void gro_normal_one(struct gro_node *gro, struct sk_buff *skb, int segs)
{
    list_add_tail(&skb->list, &gro->rx_list);
    gro->rx_count += segs;
    if (gro->rx_count >= READ_ONCE(net_hotdata.gro_normal_batch))
        gro_normal_list(gro);   // 超过批次阈值，批量交付
}
```

`gro_normal_batch`默认值为8（`hotdata.c:12`），由`/proc/sys/net/core/gro_normal_batch`控制。

### 5.3 napi_gro_frags

`napi_gro_frags`（`gro.c:763`）处理分片包（无头skb），与`napi_gro_receive`流程类似，但处理ETH_HLEN剥离和协议类型设置：

```c
// gro.c:763
gro_result_t napi_gro_frags(struct napi_struct *napi)
{
    gro_result_t ret;
    struct sk_buff *skb = napi_frags_skb(napi);
    trace_napi_gro_frags_entry(skb);
    ret = napi_frags_finish(napi, skb, dev_gro_receive(&napi->gro, skb));
    trace_napi_gro_frags_exit(ret);
    return ret;
}
```

### 5.4 NAPI 轮询 — process_backlog

`process_backlog`（`dev.c:6644`）是backlog设备的poll函数，由`net_rx_action`软中断调用：

```c
// dev.c:6644
static int process_backlog(struct napi_struct *napi, int quota)
{
    struct softnet_data *sd = container_of(napi, struct softnet_data, backlog);
    bool again = true;
    int work = 0;

    // 先处理RPS IPI等待队列
    if (sd_has_rps_ipi_waiting(sd))
        net_rps_action_and_irq_enable(sd);

    napi->weight = READ_ONCE(net_hotdata.dev_rx_weight);
    while (again) {
        struct sk_buff *skb;
        while ((skb = __skb_dequeue(&sd->process_queue))) {
            rcu_read_lock();
            __netif_receive_skb(skb);   // 协议分发
            rcu_call_unlock();
            if (++work >= quota)
                return work;
        }
        // input_pkt_queue -> process_queue
        backlog_lock_irq_disable(sd);
        if (skb_queue_empty(&sd->input_pkt_queue)) {
            napi->state &= NAPIF_STATE_THREADED;  // 清除SCHED标志
            again = false;
        } else {
            skb_queue_splice_tail_init(&sd->input_pkt_queue, &sd->process_queue);
        }
        backlog_unlock_irq_enable(sd);
    }
    return work;
}
```

> `__netif_receive_skb`最终调用`__netif_receive_skb_core`，见下一节。

## 6. packet_type 查找和协议分发（ptype_all / ptype_base）

Linux用`packet_type`结构体描述每个协议 handler：

```c
// include/linux/netdevice.h
struct packet_type {
    __be16                  type;   // Ethernet协议类型，如ETH_P_IP
    struct net_device      *dev;    // NULL表示通配
    int                     (*func)(struct sk_buff *,
                                    struct net_device *,
                                    struct packet_type *,
                                    struct net_device *);
    struct list_head        list;
    // ...
};
```

### 6.1 注册与管理

- `ptype_base[PTYPE_HASH_SIZE]`（`dev.c:172`）：按协议类型哈希的handler表
- `dev_add_pack`（`dev.c:624`）：加入`ptype_base`或`dev->ptype_all`
- `dev_remove_pack`（`dev.c:650`）：移除

### 6.2 ptype_all 和 ptype_base 查找

`__netif_receive_skb_core`（`dev.c:5973`）中，协议分发分三个阶段：

**阶段1 — ptype_all 钩子**（所有协议都看到的监听器，如AF_PACKET原始套接字）：

```c
// dev.c:6034
list_for_each_entry_rcu(ptype, &dev_net_rcu(skb->dev)->ptype_all, list) {
    if (unlikely(pt_prev))
        ret = deliver_skb(skb, pt_prev, orig_dev);
    pt_prev = ptype;
}

// dev.c:6041
list_for_each_entry_rcu(ptype, &skb->dev->ptype_all, list) {
    if (unlikely(pt_prev))
        ret = deliver_skb(skb, pt_prev, orig_dev);
    pt_prev = ptype;
}
```

**阶段2 — 协议特定handler**（根据ethertype查找）：

```c
// dev.c:6146
deliver_ptype_list_skb(skb, &pt_prev, orig_dev, type,
    &ptype_base[ntohs(type) & PTYPE_HASH_MASK]);

// dev.c:6155
deliver_ptype_list_skb(skb, &pt_prev, orig_dev, type,
    &dev_net_rcu(skb->dev)->ptype_specific);

// dev.c:6159
deliver_ptype_list_skb(skb, &pt_prev, orig_dev, type,
    &orig_dev->ptype_specific);

// dev.c:6163（如果skb穿过vlan设备，dev会变化）
if (unlikely(skb->dev != orig_dev))
    deliver_ptype_list_skb(skb, &pt_prev, orig_dev, type,
        &skb->dev->ptype_specific);
```

**阶段3 — 最终交付**：

`__netif_receive_skb_one_core`（`dev.c:6194`）在所有分发完成后，调用最后一个匹配到的`pt_prev->func`：

```c
// dev.c:6197
static int __netif_receive_skb_one_core(struct sk_buff *skb, bool pfmemalloc)
{
    struct packet_type *pt_prev = NULL;
    int ret;

    ret = __netif_receive_skb_core(&skb, pfmemalloc, &pt_prev);
    if (pt_prev)
        ret = INDIRECT_CALL_INET(pt_prev->func, ipv6_rcv, ip_rcv,
                                 skb, skb->dev, pt_prev, orig_dev);
    return ret;
}
```

### 6.3 deliver_skb 和 deliver_ptype_list_skb

```c
// dev.c:2485
static int deliver_skb(struct sk_buff *skb,
                       struct packet_type *pt_prev,
                       struct net_device *orig_dev)
{
    if (unlikely(skb_orphan_frags_rx(skb, GFP_ATOMIC)))
        return -ENOMEM;
    refcount_inc(&skb->users);
    return pt_prev->func(skb, skb->dev, pt_prev, orig_dev);
}

// dev.c:2507
static inline void deliver_ptype_list_skb(struct sk_buff *skb,
                      struct packet_type **pt,
                      struct net_device *orig_dev,
                      __be16 type, struct list_head *ptype_list)
{
    struct packet_type *ptype, *pt_prev = *pt;
    list_for_each_entry_rcu(ptype, ptype_list, list) {
        if (ptype->type != type) continue;
        if (unlikely(pt_prev))
            deliver_skb(skb, pt_prev, orig_dev);
        pt_prev = ptype;
    }
    *pt = pt_prev;
}
```

## 7. gro_normal_receive / napi_gro_frags

### 7.1 gro_normal_receive

Linux内核中**没有**名为`gro_normal_receive`的函数。实际调用链是`gro_normal_one`（见第5.2节），GRO_NORMAL时将skb加入NAPI的`gro->rx_list`，批量达到阈值后通过`gro_normal_list`一次性上送。

### 7.2 napi_gro_frags 分片路径

```c
// gro.c:763
gro_result_t napi_gro_frags(struct napi_struct *napi)
{
    gro_result_t ret;
    struct sk_buff *skb = napi_frags_skb(napi);   // 补全ETH_HLEN头
    trace_napi_gro_frags_entry(skb);
    ret = napi_frags_finish(napi, skb, dev_gro_receive(&napi->gro, skb));
    trace_napi_gro_frags_exit(ret);
    return ret;
}

// gro.c:696 - napi_frags_finish
static gro_result_t napi_frags_finish(...)
{
    switch (ret) {
    case GRO_NORMAL:
    case GRO_HELD:
        __skb_push(skb, ETH_HLEN);
        skb->protocol = eth_type_trans(skb, skb->dev);
        if (ret == GRO_NORMAL)
            gro_normal_one(&napi->gro, skb, 1);   // 批量上送
        break;
    // ...
    }
}
```

## 8. 接收软中断处理流程（NET_RX_SOFTIRQ）

### 8.1 net_rx_action

`net_rx_action`（`dev.c:7911`）是`NET_RX_SOFTIRQ`的处理函数：

```c
// dev.c:7911
static __latent_entropy void net_rx_action(void)
{
    struct softnet_data *sd = this_cpu_ptr(&softnet_data);
    unsigned long time_limit = jiffies + usecs_to_jiffies(
        READ_ONCE(net_hotdata.netdev_budget_usecs));
    int budget = READ_ONCE(net_hotdata.netdev_budget);
    LIST_HEAD(list);
    LIST_HEAD(repoll);

start:
    sd->in_net_rx_action = true;
    local_irq_disable();
    list_splice_init(&sd->poll_list, &list);   // 取出所有待处理的NAPI
    local_irq_enable();

    for (;;) {
        struct napi_struct *n;
        skb_defer_free_flush();
        if (list_empty(&list)) {
            if (list_empty(&repoll)) {
                sd->in_net_rx_action = false;
                // 检测到新的NAPI被加入，重新开始
                if (!list_empty(&sd->poll_list))
                    goto start;
                if (!sd_has_rps_ipi_waiting(sd))
                    goto end;
            }
            break;
        }
        n = list_first_entry(&list, struct napi_struct, poll_list);
        budget -= napi_poll(n, &repoll);         // 调用设备的poll函数

        if (unlikely(budget <= 0 ||
                     time_after_eq(jiffies, time_limit))) {
            WRITE_ONCE(sd->time_squeeze, sd->time_squeeze + 1);
            break;
        }
    }

    local_irq_disable();
    // 未处理完的放回队列，重新触发软中断
    list_splice_tail_init(&sd->poll_list, &list);
    list_splice_tail(&repoll, &list);
    list_splice(&list, &sd->poll_list);
    if (!list_empty(&sd->poll_list))
        __raise_softirq_irqoff(NET_RX_SOFTIRQ);
    else
        sd->in_net_rx_action = false;
    net_rps_action_and_irq_enable(sd);
end:
    bpf_net_ctx_clear(bpf_net_ctx);
}
```

关键参数：
- `netdev_budget`：每次软中断最多处理的数据包数（默认300）
- `netdev_budget_usecs`：时间片上限（默认2000us）
- `time_squeeze`：预算耗尽次数，指标压力信号

### 8.2 __napi_poll

`__napi_poll`（`dev.c:7716`）调用单个NAPI的poll函数：

```c
// dev.c:7716
static int __napi_poll(struct napi_struct *n, bool *repoll)
{
    int work;

    if (test_bit(NAPI_STATE_SCHED, &n->state)) {
        work = n->poll(n, weight);
        // ...
        if (work < weight)
            *repoll = false;
    }
    return work;
}
```

### 8.3 软中断触发时机

| 函数 | 位置 | 触发位置 |
|------|------|---------|
| `raise_softirq_irqoff(NET_RX_SOFTIRQ)` | `____napi_schedule` | `dev.c:4989` |
| `__raise_softirq_irqoff(NET_RX_SOFTIRQ)` | `enqueue_to_backlog` | `dev.c:5270` |
| `__raise_softirq_irqoff(NET_RX_SOFTIRQ)` | `net_rx_action` | `dev.c:7963`（重触发）|

## 9. 统计信息更新

内核通过`softnet_data.processed`统计处理的数据包数：

```c
// dev.c:6006（__netif_receive_skb_core）
__this_cpu_inc(softnet_data.processed);
```

其他关键统计：

| 统计项 | 位置 | 说明 |
|--------|------|------|
| `dev_core_stats_rx_dropped_inc()` | `dev.c:5420,6172` | 设备RX丢包计数 |
| `dev_core_stats_rx_nohandler_inc()` | `dev.c:6174` | 无协议handler匹配 |
| `numa_drop_add()` | `dev.c:5403` | NUMA远程丢包 |
| `softnet_data.processed` | `dev.c:6006` | 已处理包数 |
| `sd->time_squeeze` | `dev.c:7949` | 软中断预算耗尽次数 |

设备统计通过`/proc/net/softnet_stat`暴露：

```
[CPU_id] [processed] [dropped] [time_squeeze] [cpu_collision] ...
```

## 10. 关键数据流总图

```
NIC 驱动 (hardirq)
  │
  ├─► netif_rx()               dev.c:5764 ──► netif_rx_internal() ──► enqueue_to_backlog()
  │                                                               │
  │                                                      ┌─────────┴──────────┐
  │                                                      │ 队列空？           │
  │                                                      │ napi_schedule_rps  │
  │                                                      │ raise_softirq_irqoff│
  │                                                      └─────────┬──────────┘
  │                                                                ▼
  │                                              ┌─► NET_RX_SOFTIRQ 软中断
  │                                              │         │
  └─► napi_gro_receive()  netdev.h:4286          │         ▼
        │   (NAPI+GRO驱动)                       │  net_rx_action() dev.c:7911
        │                                         │         │
        ▼                                         │         ▼
  gro_receive_skb() gro.c:634                     │  process_backlog() dev.c:6644
        │                                         │         │ (backlog NAPI)
        ▼                                         │         ▼
  dev_gro_receive() [GRO哈希合并]                  │  __netif_receive_skb() dev.c:6295
        │                                                  │
        ├─► GRO_NORMAL ──► gro_normal_one() ──► list_add_tail(rx_list)
        │                              ┌─► gro_normal_batch(8) ──► gro_normal_list()
        │                              │              (阈值触发批量上送)
        ├─► GRO_MERGED ──► 完成
        └─► GRO_HELD ──► 保留

        ▼
  __netif_receive_skb_core() dev.c:5973
        │
        ├── 1. ptype_all  ──► AF_PACKET 原始套接字
        ├── 2. skb->dev->ptype_all
        ├── 3. VLAN 处理 ──► vlan_do_receive() ──► another_round
        ├── 4. rx_handler  ──► 网桥 / macvlan / bonding
        ├── 5. ptype_base[hash] ──► IP / IPv6 / ARP ...
        ├── 6. ptype_specific   ──► 协议族专属handler
        └── 7. pt_prev->func() ──► ip_rcv() / ipv6_rcv() ...
```

## 参考

- `net/core/dev.c` — 主要网络设备核心（13314行）
- `net/core/gro.c` — GRO实现
- `include/net/gro.h` — GRO内联函数
- `include/linux/netdevice.h` — 网络设备接口定义

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

