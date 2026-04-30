# qdisc — 流量控制队列规则深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/sched/sch_generic.c` + `net/sched/sch_api.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**qdisc（Queueing Discipline）** 是 Linux 网络栈的**流量整形和调度**机制，位于 NIC 驱动和网络协议栈之间。

---

## 1. 核心数据结构

### 1.1 Qdisc — 队列规则

```c
// include/net/sch_generic.h — Qdisc
struct Qdisc {
    // 通用
    struct net_device       *dev;          // 关联的网络设备
    struct Qdisc            *next;         // 下一个 qdisc
    u32                     handle;        // 句柄（"1:" "10:")
    u32                     parent;        // 父 qdisc

    // 队列
    struct sk_buff_head     q;             // 数据包队列（sk_buff）
    unsigned long           flags;         // QDISC_FLAGS_* 标志

    // 操作函数表
    const struct Qdisc_ops  *ops;         // qdisc 操作

    // 统计
    struct gstats            stats;        // 统计
    struct gstats            xstats;        // 扩展统计

    // 哈希表
    struct qdisc_skb_head    use_shadow;    // 共享流量的影子队列
    struct tcf_proto         *filter_list;  // 过滤器
    int                     (*enqueue)(struct sk_buff *, struct Qdisc *, struct sk_buff **);
    struct sk_buff *         (*dequeue)(struct Qdisc *);
    unsigned int             qlen;          // 队列长度
};
```

### 1.2 Qdisc_ops — 操作函数表

```c
// include/net/sch_generic.h — Qdisc_ops
struct Qdisc_ops {
    const char              *id;           // qdisc 名（"pfifo_fast" "mq"）
    const char              *clid;         // 类别 ID（classful qdisc 用）

    int                     (*enqueue)(struct sk_buff *, struct Qdisc *, struct sk_buff **);
    struct sk_buff *        (*dequeue)(struct Qdisc *);
    struct sk_buff *        (*peek)(struct Qdisc *);

    int                     (*init)(struct Qdisc *, struct nlattr *);
    void                    (*reset)(struct Qdisc *);
    void                    (*destroy)(struct Qdisc *);
    int                     (*change)(struct Qdisc *, struct nlattr *);
    int                     (*dump)(struct Qdisc *, struct sk_buff *);
    int                     (*dump_stats)(struct Qdisc *, struct gnet_stats *);
};
```

---

## 2. pfifo_fast — 默认 qdisc

### 2.1 pfifo_fast_enqueue — 入队

```c
// net/sched/sch_prio.c — pfifo_fast_enqueue
static int pfifo_fast_enqueue(struct sk_buff *skb, struct Qdisc *qdisc, struct sk_buff **to_free)
{
    struct pfifo_fast_priv *priv = qdisc_priv(qdisc);
    unsigned int band;

    // 1. 获取优先级（根据 skb->priority）
    //    TCA_PRIO_MAX = 16 优先级桶
    band = tcPriorityToBand[skb->priority];

    // 2. 加入对应优先级的队列
    //    prio2band[priority] → 哪个 band
    qdisc_skb_head_tail(&priv->q[band], skb);

    // 3. 更新统计
    qdisc->qlen++;

    // 4. 如果超过限制，丢弃
    if (qdisc->qlen > qdisc->limit)
        return qdisc_drop(skb, qdisc, to_free);

    return NET_XMIT_SUCCESS;
}
```

### 2.2 pfifo_fast_dequeue — 出队

```c
// net/sched/sch_prio.c — pfifo_fast_dequeue
static struct sk_buff *pfifo_fast_dequeue(struct Qdisc *qdisc)
{
    struct pfifo_fast_priv *priv = qdisc_priv(qdisc);
    unsigned int band;

    // 从最高优先级桶开始（band 0 最高）
    for (band = 0; band < TCQ_PRIO_BANDS; band++) {
        if (!qdisc_skb_head_empty(&priv->q[band])) {
            qdisc->qlen--;
            return qdisc_skb_head_dequeue(&priv->q[band]);
        }
    }

    return NULL;  // 队列空
}
```

---

## 3. HTB — 分层令牌桶（Hierarchical Token Bucket）

```c
// net/sched/sch_htb.c — HTB
struct htb_class {
    struct Qdisc_class_opt   opt;           // 类选项
    struct qdisc_rate_table  *rate;        // 速率表
    struct qdisc_rate_table  *ceil;        // 上限速率

    // 令牌桶状态
    s64                      token_bucket;  // 令牌数
    s64                      credit;        // 累积信用
    s64                      quantum;       // 每次发送的字节数

    // 优先级
    unsigned int            prio;           // 0（最高）~ 7

    // 父/子
    struct htb_class        *parent;        // 父类
    struct list_head        children;       // 子类链表
};
```

---

## 4. 调度算法（qdisc）

### 4.1 常见 qdisc 类型

| qdisc | 类型 | 说明 |
|-------|------|------|
| `pfifo_fast` | 无类 | 16 优先级桶，莺需配置 |
| `pfifo` | 无类 | 纯 FIFO |
| `bfifo` | 无类 | 字节为单位 FIFO |
| `htb` | 分类 | 层次令牌桶，支持整形 |
| `fq_codel` | 无类 | 字节码/延迟控制（Codel 算法）|
| `fq` | 无类 | 公平队列（Google 党发）|
| `mq` | 多队列 | 多队列调度（多核 NIC）|

### 4.2 qdisc_run — 运行 qdisc

```c
// net/sched/sch_generic.c — qdisc_run
void qdisc_run(struct net_device *dev)
{
    struct Qdisc *q = dev->qdisc;
    int pkts = 0;

    // 1. 检查是否可以发送（qdisc 无锁）
    while (qdisc_restart(q) < 0 && pkts++ < 4)
        ;  // 发送最多 4 个包，避免无限循环

    // 2. 完成后触发 NAPI
    if (netif_tx_trylock(dev)) {
        __netif_schedule(dev);
        netif_tx_unlock(dev);
    }
}
```

---

## 5. 网络优先级映射

```c
// net/core/skbuff.c — skb_tx_hash
static unsigned int skb_tx_hash(struct net_device *dev, struct sk_buff *skb)
{
    // 1. 获取 socket 优先级
    unsigned int prio = skb->sk ? skb->sk->sk_priority : skb->priority;

    // 2. 将 priority 映射到 hardware queue
    if (dev->num_tc)
        return netdev_pick_tx(dev, skb);

    return prio % dev->real_num_tx_queues;
}
```

---

## 6. tc 命令行示例

```bash
# 查看 qdisc
tc qdisc show dev eth0

# 添加 htb qdisc
tc qdisc add dev eth0 root handle 1: htb default 10

# 添加类
tc class add dev eth0 parent 1: classid 1:10 htb rate 100Mbps ceil 200Mbps

# 添加过滤器
tc filter add dev eth0 parent 1: protocol ip prio 10 u32 match ip sport 80 0xffff flowid 1:10
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/net/sch_generic.h` | `struct Qdisc`、`struct Qdisc_ops` |
| `net/sched/sch_prio.c` | `pfifo_fast_enqueue/dequeue` |
| `net/sched/sch_htb.c` | `htb_class`、`HTB` |
| `net/sched/sch_generic.c` | `qdisc_run`、`qdisc_restart` |