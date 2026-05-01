# dev_queue_xmit 数据包发送流程分析

**来源文件：** `/home/dev/code/linux/net/core/dev.c`（Linux 7.0-rc1，共 13314 行）
**内核版本：** Linux 7.0-rc1
**分析日期：** 2026-05-01

## 1. dev_queue_xmit 入口与基本流程

### 1.1 两层接口：dev_queue_xmit → __dev_queue_xmit

在 `/home/dev/code/linux/include/linux/netdevice.h:3416-3418` 中，`dev_queue_xmit` 是一个轻量包装：

```c
// netdevice.h:3416
static inline int dev_queue_xmit(struct sk_buff *skb)
{
    return __dev_queue_xmit(skb, NULL);
}
```

`__dev_queue_xmit` 是真正的核心实现，位于 `dev.c:4766`。调用链：

```
dev_queue_xmit(skb)
  └─> __dev_queue_xmit(skb, NULL)
        ├─> skb_reset_mac_header() / skb_assert_len()
        ├─> __skb_tstamp_tx()           // 时间戳
        ├─> qdisc_pkt_len_segs_init()   // 包长度验证
        ├─> rcu_read_lock_bh()          // 关闭软中断
        ├─> skb_update_prio()           // 优先级
        ├─> nf_hook_egress()            // NETFILTER EGRESS
        ├─> sch_handle_egress()         // EGRESS QoS
        ├─> netdev_core_pick_tx()       // 选择发送队列
        ├─> [q->enqueue ? __dev_xmit_skb() : direct xmit]
        └─> rcu_read_unlock_bh()
```

### 1.2 函数签名与返回值

```c
// dev.c:4766
int __dev_queue_xmit(struct sk_buff *skb, struct net_device *sb_dev)
```

**返回值语义：**
- `0` — 成功发送（或成功入队）
- 正数 — qdisc 返回码（`NET_XMIT_DROP` 等）
- 负数 — 其他错误（如 `-ENETDOWN`）

> **注意：** 无论返回值如何，`skb` 总是被消费（释放）。调用者不应在返回后访问 `skb`。

## 2. __dev_queue_xmit → netdev_start_xmit 核心路径

### 2.1 两种发送路径

`__dev_queue_xmit` 存在两条路径，取决于设备是否有 qdisc 队列：

```
__dev_queue_xmit()
  │
  ├─> [q->enqueue 存在]  ──> __dev_xmit_skb()   // 有 qdisc，走排队逻辑
  │
  └─> [q->enqueue 不存在] ──> 直接硬件发送路径   // 无 qdisc（loopback、tunnel）
```

### 2.2 直接发送路径（无 qdisc）

当设备没有 qdisc 绑定时（`q->enqueue == NULL`），在 `dev.c:4831` 之后走如下流程：

```c
// dev.c:4831
rc = __dev_xmit_skb(skb, q, dev, txq);
```

实际的直接发送路径在 `dev.c:4852-4891`：

```c
// dev.c:4852-4891
if (likely(!netif_tx_owned(txq, cpu))) {
    // ...

    skb = validate_xmit_skb(skb, dev, &again);   // GSO/校验和验证
    if (!skb)
        goto out;

    HARD_TX_LOCK(dev, txq, cpu);                   // 获取设备 TX 锁

    if (!netif_xmit_stopped(txq)) {
        is_list = !!skb->next;

        dev_xmit_recursion_inc();
        skb = dev_hard_start_xmit(skb, dev, txq, &rc);  // 核心发送
        dev_xmit_recursion_dec();

        if (is_list)
            rc = NETDEV_TX_OK;  // GSO 分片视为全部成功
    }
    HARD_TX_UNLOCK(dev, txq);

    if (!skb) /* xmit completed */
        goto out;

    // 虚拟设备（无真实驱动）返回 NETDEV_TX_BUSY 或 -ENETDOWN
    rc = -ENETDOWN;
}
```

### 2.3 HARD_TX_LOCK / HARD_TX_UNLOCK

设备驱动可以使用 `HARD_TX_LOCK`/`HARD_TX_UNLOCK` 保护发送过程：

```c
// 位于 dev.c 中，典型实现为空或 spin_lock
HARD_TX_LOCK(dev, txq, cpu)   // 获取设备发送锁
...
HARD_TX_UNLOCK(dev, txq, cpu) // 释放设备发送锁
```

## 3. netdev_pick_tx 发送队列选择

### 3.1 入口：netdev_core_pick_tx

```c
// dev.c:4724
struct netdev_queue *netdev_core_pick_tx(struct net_device *dev,
                                         struct sk_buff *skb,
                                         struct net_device *sb_dev)
{
    int queue_index = 0;

    #ifdef CONFIG_XPS
    u32 sender_cpu = skb->sender_cpu - 1;
    if (sender_cpu >= (u32)NR_CPUS)
        skb->sender_cpu = raw_smp_processor_id() + 1;
    #endif

    if (dev->real_num_tx_queues != 1) {
        const struct net_device_ops *ops = dev->netdev_ops;

        if (ops->ndo_select_queue)
            queue_index = ops->ndo_select_queue(dev, skb, sb_dev);
        else
            queue_index = netdev_pick_tx(dev, skb, sb_dev);

        queue_index = netdev_cap_txqueue(dev, queue_index);
    }

    skb_set_queue_mapping(skb, queue_index);
    return netdev_get_tx_queue(dev, queue_index);
}
```

### 3.2 默认选择策略：netdev_pick_tx

```c
// dev.c:4691
u16 netdev_pick_tx(struct net_device *dev, struct sk_buff *skb,
                    struct net_device *sb_dev)
{
    struct sock *sk = skb->sk;
    int queue_index = sk_tx_queue_get(sk);   // 先查 socket 缓存的队列号

    sb_dev = sb_dev ? : dev;

    if (queue_index < 0 || skb->ooo_okay ||
        queue_index >= dev->real_num_tx_queues) {
        int new_index = get_xps_queue(dev, sb_dev, skb);  // XPS CPU→队列映射

        if (new_index < 0)
            new_index = skb_tx_hash(dev, sb_dev, skb);    // RSS 哈希

        if (sk && sk_fullsock(sk) &&
            rcu_access_pointer(sk->sk_dst_cache))
            sk_tx_queue_set(sk, new_index);               // 写回 socket 缓存

        queue_index = new_index;
    }

    return queue_index;
}
EXPORT_SYMBOL(netdev_pick_tx);
```

**选择优先级：**
1. `sk_tx_queue_get(sk)` — socket 上次使用的队列（缓存命中）
2. `get_xps_queue()` — XPS（Transmit Packet Steering）CPU→队列映射
3. `skb_tx_hash()` — 根据 skb 哈希值在队列间分散

## 4. dev_hard_start_xmit → ndo_start_xmit 调用链

### 4.1 调用链总览

```
dev_hard_start_xmit()
  └─> xmit_one()  [循环处理 GSO 片段列表]
        └─> netdev_start_xmit()
              └─> __netdev_start_xmit()
                    └─> ops->ndo_start_xmit(skb, dev)  // 驱动实现的回调
```

### 4.2 dev_hard_start_xmit

```c
// dev.c:3894
struct sk_buff *dev_hard_start_xmit(struct sk_buff *first, struct net_device *dev,
                                    struct netdev_queue *txq, int *ret)
{
    struct sk_buff *skb = first;
    int rc = NETDEV_TX_OK;

    while (skb) {
        struct sk_buff *next = skb->next;

        skb_mark_not_on_list(skb);
        rc = xmit_one(skb, dev, txq, next != NULL);
        if (unlikely(!dev_xmit_complete(rc))) {
            skb->next = next;
            goto out;
        }

        skb = next;
        if (netif_tx_queue_stopped(txq) && skb) {
            rc = NETDEV_TX_BUSY;
            break;
        }
    }

out:
    *ret = rc;
    return skb;  // 返回未发送完的剩余 skb（通常为 NULL）
}
```

注意：`dev_hard_start_xmit` 遍历 `skb->next` 链表（GSO 分片后的多个帧），直到驱动返回非 `dev_xmit_complete()` 状态。

### 4.3 xmit_one

```c
// dev.c:3874
static int xmit_one(struct sk_buff *skb, struct net_device *dev,
                    struct netdev_queue *txq, bool more)
{
    unsigned int len;
    int rc;

    if (dev_nit_active_rcu(dev))
        dev_queue_xmit_nit(skb, dev);   // 发送镜像（port mirror）

    len = skb->len;
    trace_net_dev_start_xmit(skb, dev);
    rc = netdev_start_xmit(skb, dev, txq, more);
    trace_net_dev_xmit(skb, rc, dev, len);

    return rc;
}
```

### 4.4 netdev_start_xmit → ndo_start_xmit

```c
// netdevice.h:5363-5378
static inline netdev_tx_t __netdev_start_xmit(const struct net_device_ops *ops,
                                              struct sk_buff *skb, struct net_device *dev,
                                              bool more)
{
    netdev_xmit_set_more(more);
    return ops->ndo_start_xmit(skb, dev);
}

static inline netdev_tx_t netdev_start_xmit(struct sk_buff *skb, struct net_device *dev,
                                            struct netdev_queue *txq, bool more)
{
    const struct net_device_ops *ops = dev->netdev_ops;
    netdev_tx_t rc;

    rc = __netdev_start_xmit(ops, skb, dev, more);
    if (rc == NETDEV_TX_OK)
        txq_trans_update(dev, txq);   // 更新 trans_start

    return rc;
}
```

`ndo_start_xmit` 是网卡驱动的发送回调，由每个驱动自行实现（如 `igb_xmit_frame`、`mlx5e_xmit` 等）。

## 5. qdisc_run / qdisc_run_end 队列规则

### 5.1 qdisc_run 宏

```c
// pkt_sched.h:117
static inline struct sk_buff *qdisc_run(struct Qdisc *q)
{
    if (qdisc_run_begin(q)) {
        __qdisc_run(q);
        return qdisc_run_end(q);
    }
    return NULL;
}
```

这是 qdisc 的"尝试发送 + 耗尽"模式的核心封装。

### 5.2 qdisc_run_begin / qdisc_run_end

```c
// sch_generic.h:202
static inline bool qdisc_run_begin(struct Qdisc *qdisc)
{
    if (qdisc->flags & TCQ_F_NOLOCK) {
        if (spin_trylock(&qdisc->seqlock))
            return true;

        // 如果获取锁失败，设置 MISSED 标记，让持有锁的 CPU 稍后处理
        if (test_and_set_bit(__QDISC_STATE_MISSED, &qdisc->state))
            return false;

        return spin_trylock(&qdisc->seqlock);
    }
    // 有锁 qdisc：检查 running 标志
    if (READ_ONCE(qdisc->running))
        return false;
    WRITE_ONCE(qdisc->running, true);
    return true;
}

// sch_generic.h:228
static inline struct sk_buff *qdisc_run_end(struct Qdisc *qdisc)
{
    struct sk_buff *to_free = NULL;

    if (qdisc->flags & TCQ_F_NOLOCK) {
        spin_unlock(&qdisc->seqlock);
        smp_mb();

        if (unlikely(test_bit(__QDISC_STATE_MISSED, &qdisc->state)))
            __netif_schedule(qdisc);   // 触发延迟调度
        return NULL;
    }

    if (qdisc->flags & TCQ_F_DEQUEUE_DROPS)
        to_free = qdisc->to_free;

    WRITE_ONCE(qdisc->running, false);
    return to_free;
}
```

**关键点：**
- `qdisc_run_begin` 使用 `spin_trylock`（NOLOCK qdisc）或检查 `running` 标志（有锁 qdisc）
- 对于 NOLOCK qdisc，如果获取锁失败会设置 `MISSED` 标记，持有锁的 CPU 在 `qdisc_run_end` 时检测到该标记并触发 `__netif_schedule`
- 这样实现了无锁 qdisc 的"偷执行"（stealing）优化

### 5.3 __dev_xmit_skb 中的 qdisc 逻辑

```c
// dev.c:4180
static inline int __dev_xmit_skb(struct sk_buff *skb, struct Qdisc *q,
                                  struct net_device *dev,
                                  struct netdev_queue *txq)
{
    struct sk_buff *next, *to_free = NULL, *to_free2 = NULL;
    spinlock_t *root_lock = qdisc_lock(q);
    // ...

    if (q->flags & TCQ_F_NOLOCK) {
        if (q->flags & TCQ_F_CAN_BYPASS && nolock_qdisc_is_empty(q) &&
            qdisc_run_begin(q)) {
            // NOLOCK bypass：qdisc 为空，直接发送
            if (unlikely(!nolock_qdisc_is_empty(q))) {
                // 竞态：enqueue 同时 bypass 检查，需要重新入队
                rc = dev_qdisc_enqueue(skb, q, &to_free, txq);
                __qdisc_run(q);
                to_free2 = qdisc_run_end(q);
                goto free_skbs;
            }

            qdisc_bstats_cpu_update(q, skb);
            if (sch_direct_xmit(skb, q, dev, txq, NULL, true) &&
                !nolock_qdisc_is_empty(q))
                __qdisc_run(q);

            to_free2 = qdisc_run_end(q);
            rc = NET_XMIT_SUCCESS;
            goto free_skbs;
        }

        // 无法 bypass，走普通入队 + qdisc_run 耗尽
        rc = dev_qdisc_enqueue(skb, q, &to_free, txq);
        to_free2 = qdisc_run(q);
        goto free_skbs;
    }

    // 有锁 qdisc：加入 defer_list（批量排队）
    // ...
}
```

## 6. NETDEV_TX_OK / NETDEV_TX_BUSY 返回处理

### 6.1 返回码定义

```c
// netdevice.h:135-136
NETDEV_TX_OK     = 0x00,   // 驱动成功处理了数据包
NETDEV_TX_BUSY   = 0x10,   // 驱动发送路径忙（需重新入队）
```

### 6.2 驱动返回 NETDEV_TX_OK

驱动成功接管数据包，skb 已不再属于网络栈。此时：

```c
// netdevice.h:5377-5378
if (rc == NETDEV_TX_OK)
    txq_trans_update(dev, txq);   // 更新 txq->trans_update = jiffies
```

设备队列锁会在 `HARD_TX_UNLOCK` 时处理任何后续资源清理。

### 6.3 驱动返回 NETDEV_TX_BUSY

驱动无法立即接收数据包（发送环满、硬件忙等），`__dev_queue_xmit` 需要重新入队：

```c
// dev.c:4877-4885
if (!skb) /* xmit completed */
    goto out;

/* 虚拟设备要求排队 */
if (!is_list)
    rc = -ENETDOWN;
else
    rc = NETDEV_TX_BUSY;
```

在 `sch_direct_xmit`（`sch_generic.c:344`）中：

```c
bool sch_direct_xmit(struct sk_buff *skb, struct Qdisc *q,
                    struct net_device *dev, struct netdev_queue *txq,
                    spinlock_t *root_lock, bool validate)
{
    int ret = NETDEV_TX_BUSY;
    // ...

    if (likely(skb)) {
        HARD_TX_LOCK(dev, txq, smp_processor_id());
        if (!netif_xmit_frozen_or_stopped(txq))
            skb = dev_hard_start_xmit(skb, dev, txq, &ret);
        // ...
        HARD_TX_UNLOCK(dev, txq);
    }

    // ...

    if (!dev_xmit_complete(ret)) {
        // 驱动返回 BUSY，重新入队
        dev_requeue_skb(skb, q);
        return false;
    }

    return true;
}
```

### 6.4 dev_xmit_complete

```c
// netdevice.h:4847-4852
/* legacy drivers only, netdev_start_xmit() sets txq->trans_start */
static inline bool dev_xmit_complete(int ret)
{
    return likely(ret == NETDEV_TX_OK);
}
```

这是一个简单的相等性检查，用于判断驱动是否成功发送。

## 7. 软件回环（softnet_data.output）

### 7.1 回环触发：__netif_schedule

当 qdisc 被标记为 `SCHED` 时，调用 `__netif_schedule` 将 qdisc 加入 CPU 的 output 队列：

```c
// dev.c:3394
void __netif_schedule(struct Qdisc *q)
{
    if (!llist_empty(&q->defer_list))
        return;  // defer_list 不为空，说明已有线程在处理

    if (!test_and_set_bit(__QDISC_STATE_SCHED, &q->state))
        __netif_reschedule(q);
}

// dev.c:3377
static void __netif_reschedule(struct Qdisc *q)
{
    struct softnet_data *sd;
    unsigned long flags;

    local_irq_save(flags);
    sd = this_cpu_ptr(&softnet_data);
    q->next_sched = NULL;
    *sd->output_queue_tailp = q;           // 加入 output_queue 链表
    sd->output_queue_tailp = &q->next_sched;
    raise_softirq_irqoff(NET_TX_SOFTIRQ);   // 触发 NET_TX 软中断
    local_irq_restore(flags);
}
```

### 7.2 NET_TX_SOFTIRQ 处理：net_tx_action

`NET_TX_SOFTIRQ` 在 `dev.c:13285` 注册，处理函数为 `net_tx_action`：

```c
// dev.c:5780
static __latent_entropy void net_tx_action(void)
{
    struct softnet_data *sd = this_cpu_ptr(&softnet_data);

    // 处理 completion_queue（发送完成的 skb）
    if (sd->completion_queue) {
        struct sk_buff *clist, *skb;

        local_irq_disable();
        clist = sd->completion_queue;
        sd->completion_queue = NULL;
        local_irq_enable();

        while (clist) {
            struct sk_buff *skb = clist;
            clist = clist->next;
            // 释放 skb
        }
    }

    // 处理 output_queue（待调度的 qdisc）
    if (sd->output_queue) {
        struct Qdisc *head;

        local_irq_disable();
        head = sd->output_queue;
        sd->output_queue = NULL;
        sd->output_queue_tailp = &sd->output_queue;
        local_irq_enable();

        rcu_read_lock();

        while (head) {
            struct Qdisc *q = head;
            head = head->next_sched;

            smp_mb__before_atomic();
            clear_bit(__QDISC_STATE_SCHED, &q->state);  // 清除 SCHED 标记

            if (!(q->flags & TCQ_F_NOLOCK)) {
                root_lock = qdisc_lock(q);
                spin_lock(root_lock);
            }
            // 调用 qdisc->ops->requeue 或直接耗尽
            qdisc_run(q);
            // ...
        }
        rcu_read_unlock();
    }
}
```

### 7.3 softnet_data 结构

```c
// dev.c:462
DEFINE_PER_CPU_ALIGNED(struct softnet_data, softnet_data) = {
    .process_queue_bh_lock = INIT_LOCAL_LOCK(process_queue_bh_lock),
};
```

关键字段：
- `completion_queue` — 发送完成的 skb 链表（从驱动回收）
- `output_queue` — 待调度的 qdisc 链表（通过 `__netif_schedule` 加入）
- `output_queue_tailp` — 链表尾指针

## 8. 发送完成回调（netdev_run_todo）

### 8.1 注册与触发时机

`netdev_run_todo` 不是发送完成回调，而是设备注销（unregister）流程的一部分。当设备从网络命名空间注销时：

```c
// dev.c:11666
void netdev_run_todo(void)
{
    struct net_device *dev, *tmp;
    struct list_head list;

    // 快照 net_todo_list
    list_replace_init(&net_todo_list, &list);

    __rtnl_unlock();

    // 等待所有 RCU 回调完成
    if (!list_empty(&list))
        rcu_barrier();

    // 逐个完成注销
    list_for_each_entry_safe(dev, tmp, &list, todo_list) {
        if (unlikely(dev->reg_state != NETREG_UNREGISTERING)) {
            // 警告并跳过
            continue;
        }

        netdev_lock(dev);
        WRITE_ONCE(dev->reg_state, NETREG_UNREGISTERED);
        netdev_unlock(dev);
        linkwatch_sync_dev(dev);
        // 调用 free_netdev() 释放设备
    }
}
```

设备注销流程：
1. `unregister_netdevice()` 将设备加入 `net_todo_list`，状态设为 `NETREG_UNREGISTERING`
2. `rtnl_unlock()` 释放 RTNL 锁
3. `rcu_barrier()` 等待所有正在使用该设备的 RCU 读端结束
4. `netdev_run_todo()` 完成最终的资源释放

### 8.2 设备发送相关的生命周期

设备发送过程中的资源释放主要通过：
- **skb 消费**：`dev_kfree_skb_irq_reason()` 将 skb 放入 `completion_queue`，由 `net_tx_action` 释放
- **qdisc 资源**：设备注销时 `netdev_init()` 清理关联的 qdisc
- **队列映射**：设备注销时 `netdev_rx_queue_unregister()` 清理多队列映射

## 9. 调用流程图

```
dev_queue_xmit(skb)
  └─> __dev_queue_xmit(skb, NULL)
        │
        ├─> [qdisc 路径]
        │   └─> __dev_xmit_skb(skb, q, dev, txq)
        │         ├─> dev_qdisc_enqueue(skb, q, ...)
        │         ├─> qdisc_run(q)         // 循环耗尽 qdisc
        │         │     ├─> qdisc_run_begin(q)
        │         │     ├─> __qdisc_run(q) // 调用 sch->dequeue() 发送
        │         │     └─> qdisc_run_end(q)
        │         └─> [sch_direct_xmit() 处理 BUSY 重入]
        │
        └─> [直接硬件路径 q->enqueue == NULL]
              ├─> netdev_core_pick_tx()     // 选择发送队列
              │     └─> [ndo_select_queue ? ops->ndo_select_queue : netdev_pick_tx]
              ├─> validate_xmit_skb()       // GSO/校验和验证
              ├─> HARD_TX_LOCK()
              ├─> dev_hard_start_xmit(skb, dev, txq, &rc)
              │     └─> xmit_one()  [循环 skb->next 链]
              │           └─> netdev_start_xmit()
              │                 └─> __netdev_start_xmit()
              │                       └─> ops->ndo_start_xmit()  // 驱动回调
              │                             └─> [返回 NETDEV_TX_OK/BUSY]
              ├─> HARD_TX_UNLOCK()
              └─> [NETDEV_TX_BUSY → dev_requeue_skb() → __netif_schedule()]
```

**NET_TX_SOFTIRQ（后台调度）：**

```
raise_softirq_irqoff(NET_TX_SOFTIRQ)
  └─> net_tx_action()
        ├─> 处理 completion_queue（释放发送完成的 skb）
        └─> 处理 output_queue（对每个 qdisc 调用 qdisc_run 继续发送）
```

## 10. 关键数据结构

| 结构 | 位置 | 用途 |
|------|------|------|
| `softnet_data` | `dev.c:462` | Per-CPU 状态（output_queue、completion_queue 等） |
| `netdev_queue` | `netdevice.h` | 发送队列描述符，含 qdisc 指针 |
| `Qdisc` | `sch_generic.h` | 队列规则（排队、调度算法） |
| `net_device` | `netdevice.h` | 网络设备，含 `netdev_ops` 回调 |

## 11. 参考行号索引

| 内容 | 文件:行 |
|------|---------|
| `dev_queue_xmit` 内联包装 | `netdevice.h:3416` |
| `__dev_queue_xmit` 定义 | `dev.c:4766` |
| `netdev_core_pick_tx` | `dev.c:4724` |
| `netdev_pick_tx` | `dev.c:4691` |
| `__dev_xmit_skb` | `dev.c:4180` |
| `dev_hard_start_xmit` | `dev.c:3894` |
| `xmit_one` | `dev.c:3874` |
| `netdev_start_xmit` | `netdevice.h:5371` |
| `__netdev_start_xmit` | `netdevice.h:5363` |
| `ndo_start_xmit` 调用 | `netdevice.h:5366` |
| `qdisc_run` | `pkt_sched.h:117` |
| `qdisc_run_begin` | `sch_generic.h:202` |
| `qdisc_run_end` | `sch_generic.h:228` |
| `NETDEV_TX_OK / BUSY` | `netdevice.h:135-136` |
| `__netif_schedule` | `dev.c:3394` |
| `__netif_reschedule` | `dev.c:3377` |
| `net_tx_action` | `dev.c:5780` |
| `softnet_data` 定义 | `dev.c:462` |
| `sch_direct_xmit` | `sch_generic.c:344` |
| `netdev_run_todo` | `dev.c:11666` |
| `dev_xmit_complete` | `netdevice.h:4847` |
| `dev_kfree_skb_irq_reason` | `dev.c:3442` |

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

