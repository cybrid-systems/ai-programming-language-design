# Linux Kernel qdisc / netdev_queue 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/sched/sch_generic.c` + `net/sched/sch_htb.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 qdisc？

**qdisc（Queueing Discipline）** 是 Linux 网络栈的**流量控制**框架，位于发送路径（TX），决定数据包的**排队和发送顺序**。

---

## 1. 核心数据结构

### 1.1 netdev_queue

```c
// include/linux/netdevice.h — netdev_queue
struct netdev_queue {
    struct net_device   *dev;           // 所属网卡
    struct Qdisc       *qdisc;         // 关联的 qdisc
    unsigned long       state;         // 状态（__QUEUE_STATE_XOFF 等）
    struct xmit_skbuff *xmit_skbs;   // 传输数据包缓存
    spinlock_t         _xmit_lock;
    int                 xmit_lock_owner;
    unsigned long       trans_start;   // 上次发送时间
    unsigned long       trans_start_jiffies;
};
```

### 1.2 Qdisc

```c
// include/net/sch_generic.h — Qdisc
struct Qdisc {
    struct netdev_queue *dev_queue;   // 关联的队列

    struct Qdisc_ops   *ops;          // qdisc 操作函数表
    struct qdisc_watchdog  *watchdog;  // 定时器（令牌桶等）

    /* 统计 */
    u32                 qlen;         // 队列长度
    u64                 backlog;       // 积压字节数
    u64                 qstats.nr_bytes;
    u64                 qstats.nr_packets;

    /* 队列 */
    struct sk_buff      *skb_head;    // 队列头
    struct sk_buff      *skb_tail;    // 队列尾
    spinlock_t          reenqueue_lock;

    /* 绑定 */
    struct gso_classid_ops *class_ops;
    int (*enqueue)(struct sk_buff *skb, struct Qdisc *sch, struct sk_buff **to);
    struct sk_buff *(*dequeue)(struct Qdisc *sch);
    struct sk_buff *(*peek)(struct Qdisc *sch);
};
```

---

## 2. qdisc 操作

```c
// include/net/sch_generic.h — Qdisc_ops
struct Qdisc_ops {
    char               id[IFNAMSIZ];
    struct Qdisc_ops   *next;

    /* 入队 */
    int (*enqueue)(struct sk_buff *skb, struct Qdisc *sch, struct sk_buff **to);

    /* 出队 */
    struct sk_buff *(*dequeue)(struct Qdisc *sch);

    /* 重新入队（丢弃时）*/
    struct sk_buff *(*reshape_fail)(struct sk_buff *skb, struct Qdisc *sch);

    /* 初始化/销毁 */
    int  (*init)(struct Qdisc *sch, struct nlattr *opt);
    void (*destroy)(struct Qdisc *sch);
};
```

---

## 3. 完整入队/出队流程

```
应用层 send():
  ↓
tcp_sendmsg()
  ↓
tcp_write_xmit() → tcp_transmit_skb()
  ↓
ip_queue_xmit()
  ↓
__dev_queue_xmit()
  ↓
__dev_xmit_skb(skb, qdisc)
  ↓
qdisc->enqueue(skb, qdisc, &to)  ← 入队
  ↓
sch_direct_xmit()  ← 尝试直接发送
  ↓
dev_hard_start_xmit() → netdev_start_xmit()
  ↓
ndo_start_xmit(skb, dev)  ← 驱动发送
```

---

## 4. HTB (Hierarchical Token Bucket)

```c
// net/sched/sch_htb.c
// HTB：分层令牌桶，支持流量分级和带宽保障

struct htb_sched_data {
    struct Qdisc   common;  // 继承 Qdisc
    struct rb_root  wait_pq;  // 等待的类（按 next_token 排序）
    struct htb_class {
        u32   quantum;         // 每次发送的令牌数
        u64   token_bucket;    // 当前令牌数
        u64   ceil_bucket;     // ceil 令牌桶
        int   level;           // 层级（0 = 叶）
        struct list_head leaf_list;  // 叶子类
        struct rb_root rate_tree;   // 速率树
    } *root, *inner[];
};
```

---

## 5. 无类 qdisc（pfifo_fast）

```c
// net/sched/sch_prio.c — pfifo_fast
// 默认 qdisc，按 skb->priority 分到三个 FIFO 队列
// 优先级高（band 0）的队列优先发送

static int pfifo_fast_enqueue(struct sk_buff *skb, struct Qdisc *sch, ...)
{
    unsigned int band = prio2band[skb->priority & 0xF];
    struct pfifo_fast_priv *priv = qdisc_priv(sch);

    // 入对应 band 的 FIFO
    if (priv->enqueue(skb, &priv->q[band], to) == NET_XMIT_SUCCESS)
        qdisc_qstats_backlog_inc(sch, skb);

    return NET_XMIT_SUCCESS;
}
```

---

## 6. 参考

| 文件 | 内容 |
|------|------|
| `net/sched/sch_generic.c` | `__dev_queue_xmit`、`netdev_tx_t` |
| `net/sched/sch_htb.c` | HTB 实现 |
| `include/linux/netdevice.h` | `struct netdev_queue` |
| `include/net/sch_generic.h` | `struct Qdisc`、`Qdisc_ops` |
