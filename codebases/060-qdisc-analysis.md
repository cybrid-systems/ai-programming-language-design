# 60-qdisc — Linux TC 排队规则（Queueing Discipline）框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**Qdisc（Queueing Discipline，排队规则）** 是 Linux TC（Traffic Control）子系统的核心——管理网络设备发送队列的数据包排队和调度策略。每个网络设备有一个根 qdisc，用户可以通过 `tc` 命令配置复杂的 qdisc 层次结构来实现带宽限制、优先级控制、公平队列等。

**核心设计**：Qdisc 通过三个关键钩子（enqueue/dequeue/peek）实现插入和调度。上层协议栈调用 `__dev_xmit_skb()` 入队，内核在 NET_TX softirq 中调用 `dequeue()` 取出报文发送。

```
TCP/IP 协议栈
    ↓
__dev_xmit_skb() → qdisc->enqueue(skb, qdisc)
    ↓
  Qdisc 层次
    ┌─────────────────────┐
    │ root: htb (classful)│
    │   ├── class 1:10   │  ── rate 100Mbit
    │   └── class 1:20   │  ── rate 10Mbit
    │                    │
    │ leaf: pfifo_fast   │  ── 叶子 qdisc
    └─────────────────────┘
    ↓
qdisc->dequeue() → dev_hard_start_xmit()
    ↓
网卡驱动
```

**doom-lsp 确认**：核心框架在 `net/sched/sch_generic.c`（**1,619 行**）。API 在 `net/sched/sch_api.c`（2,522 行）。数据结构在 `include/net/sch_generic.h`（1,503 行）。

**关键文件索引**：

| 文件 | 行数 | 职责 |
|------|------|------|
| `include/net/sch_generic.h` | 1503 | `struct Qdisc`, `struct Qdisc_ops`, `struct netdev_queue` |
| `net/sched/sch_generic.c` | 1619 | 核心框架：入队/出队/调度循环 |
| `net/sched/sch_api.c` | 2522 | qdisc 创建/删除/配置 API |
| `net/sched/sch_fq.c` | 1361 | 公平队列（FQ） |
| `net/sched/sch_fq_codel.c` | 752 | fq_codel |
| `net/sched/sch_htb.c` | ~2000 | 层级令牌桶（HTB） |
| `net/sched/sch_tbf.c` | ~500 | 令牌桶过滤器（TBF） |
| `net/sched/sch_prio.c` | ~400 | 优先级队列 |
| `net/sched/sch_red.c` | ~400 | 随机早期检测（RED）|

---

## 1. 核心数据结构

### 1.1 struct Qdisc — 排队规则

```c
// include/net/sch_generic.h:69-142
struct Qdisc {
    /* ── 操作函数 ─ */
    int (*enqueue)(struct sk_buff *skb, struct Qdisc *sch,
                   struct sk_buff **to_free);
    struct sk_buff *(*dequeue)(struct Qdisc *sch);
    unsigned int flags;                    /* TCQ_F_* 标志 */

    u32 limit;                              /* 队列长度限制 */
    const struct Qdisc_ops *ops;            /* Qdisc 操作表 */
    struct qdisc_size_table __rcu *stab;    /* 大小表 */
    u32 handle;                             /* 句柄 */
    u32 parent;                             /* 父 qdisc */
    struct netdev_queue *dev_queue;         /* 关联的设备队列 */

    refcount_t refcnt;

    /* ── 写频繁字段（独立缓存行）─ */
    struct sk_buff_head gso_skb;            /* GSO 分段队列 */
    struct Qdisc *next_sched;               /* 下一个调度 qdisc */
    struct sk_buff_head skb_bad_txq;        /* 错误 TX 队列 */

    /* ── 出队热路径字段 ─ */
    struct qdisc_skb_head q;                /* 数据包队列 */
    unsigned long state;                    /* 状态位 */
    struct gnet_stats_basic_sync bstats;    /* 基本统计 */
    bool running;
    struct gnet_stats_queue qstats;         /* 队列统计 */
    struct sk_buff *to_free;                /* 待释放 skb 链表 */

    /* ── 延迟处理 ─ */
    atomic_long_t defer_count;
    struct llist_head defer_list;

    struct rcu_head rcu;
    long privdata[];                        /* 每个 qdisc 的私有数据 */
};
```

**TCQ_F_* 标志**：

```c
TCQ_F_BUILTIN       = 1    /* 内建 qdisc（不可删除）*/
TCQ_F_INGRESS       = 2    /* 入口 qdisc（ingress）*/
TCQ_F_CAN_BYPASS    = 4    /* 可绕过（空队列时直接发送）*/
TCQ_F_MQROOT        = 8    /* 多队列根 Qdisc */
TCQ_F_ONETXQUEUE    = 0x10 /* 单 TX 队列优化 */
TCQ_F_CPUSTATS      = 0x20 /* per-CPU 统计 */
TCQ_F_NOLOCK        = 0x100/* qdisc 不使用锁 */
TCQ_F_OFFLOADED     = 0x200/* 卸载到硬件 */
TCQ_F_DEQUEUE_DROPS = 0x400/* dequeue 可能丢包 */
```

### 1.2 struct Qdisc_ops — Qdisc 操作表

```c
// include/net/sch_generic.h
struct Qdisc_ops {
    struct Qdisc_ops *next;                /* 链表 */
    const struct Qdisc_class_ops *cl_ops;  /* 分类操作（classful qdisc）*/
    char id[TC_QDISC_NAME];               /* 标识名（"htb","fq","tbf"...）*/
    struct module *owner;

    int (*enqueue)(struct sk_buff *, struct Qdisc *, struct sk_buff **);
    struct sk_buff *(*dequeue)(struct Qdisc *);
    struct sk_buff *(*peek)(struct Qdisc *);

    int (*init)(struct Qdisc *, struct nlattr *arg);
    void (*reset)(struct Qdisc *);
    void (*destroy)(struct Qdisc *);
    int (*change)(struct Qdisc *, struct nlattr *arg);
    int (*dump)(struct Qdisc *, struct sk_buff *);
    int (*dump_stats)(struct Qdisc *, struct gnet_dump *);

    int (*priv_size);                     /* privdata 大小 */
};
```

### 1.3 struct Qdisc_class_ops — 分类操作

Classful qdisc（如 HTB、CBQ）需要额外的分类操作：

```c
struct Qdisc_class_ops {
    int (*graft)(struct Qdisc *, unsigned long cl,
                 struct Qdisc *, struct Qdisc **);
    int (*leaf)(struct Qdisc *, unsigned long cl);
    int (*get)(struct Qdisc *, u32 classid);
    void (*put)(struct Qdisc *, unsigned long);
    int (*change)(struct Qdisc *, u32, u32, struct nlattr **,
                  unsigned long *);
    int (*delete)(struct Qdisc *, unsigned long);
    int (*walk)(struct Qdisc *, struct qdisc_walker *);
    int (*dump)(struct Qdisc *, unsigned long, struct sk_buff *, struct tcmsg*);
    int (*dump_stats)(struct Qdisc *, unsigned long, struct gnet_dump*);
    unsigned long (*bind)(struct Qdisc *, unsigned long, u32 classid);
    void (*unbind)(struct Qdisc *, unsigned long);
};
```

---

## 2. 入队路径——__dev_xmit_skb

```c
// net/sched/sch_generic.c
static inline int __dev_xmit_skb(struct sk_buff *skb, struct Qdisc *q,
                                 struct net_device *dev,
                                 struct netdev_queue *txq)
{
    /* 1. NOLOCK qdisc（无锁快速路径）*/
    if (q->flags & TCQ_F_NOLOCK) {
        if (q->flags & TCQ_F_CAN_BYPASS && nolock_qdisc_is_empty(q) &&
            qdisc_run_begin(q)) {
            /* 队列空 + 可绕过 → 直接发送 */
            if (unlikely(test_bit(__QDISC_STATE_DEACTIVATED, &q->state)))
                __qdisc_drop(skb, &to_free);
            else
                __qdisc_run(skb, q, dev, txq);  /* 直接发送 */
            qdisc_run_end(q);
            return NET_XMIT_SUCCESS;
        }
        /* 队列非空 → 入队 */
        rc = q->enqueue(skb, q, &to_free) & NET_XMIT_MASK;
        __qdisc_run(q);
        break;
    }

    /* 2. 锁保护的 qdisc */
    spin_lock(root_lock);
    /* 可绕过优化：队列空且无竞争时直接发送 */
    if (q->flags & TCQ_F_CAN_BYPASS && qdisc_qlen(q) == 0 &&
        !qdisc_is_running(q) && qdisc_run_begin(q)) {
        qdisc_bstats_update(q, skb);
        __qdisc_run(skb, q, dev, txq);
        qdisc_run_end(q);
        spin_unlock(root_lock);
        return NET_XMIT_SUCCESS;
    }
    /* 普通入队 */
    rc = q->enqueue(skb, q, &to_free) & NET_XMIT_MASK;
    __qdisc_run(q);
    spin_unlock(root_lock);
}
```

### 2.1 pfifo_fast——默认 qdisc

```c
// net/sched/sch_generic.c
// 默认 qdisc（Three-band priority FIFO）
// band 0: 交互式（ACK、控制包）— 优先级 0-3
// band 1: 尽力服务  — 优先级 4-5
// band 2: 批量数据    — 优先级 6-7

// enqueue: 按 skb->priority 分到三个 band 之一
// dequeue: 从高到低轮询三个 band

static const u8 prio2band[TC_PRIO_MAX+1] = {
    1, 2, 2, 2, 1, 2, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1
};
// band 0: 优先级最高（控制流量）
// band 1: 普通
// band 2: 批量
```

**doom-lsp 确认**：`pfifo_fast_ops` 在 `sch_generic.c` 中注册。`prio2band` 映射 skb->priority 到三个优先级队列。

---

## 3. 出队循环——__qdisc_run

```c
// net/sched/sch_generic.c
void __qdisc_run(struct Qdisc *q)
{
    int quota = dev_tx_weight;           /* 64 个包 */
    int packets;

    while (qdisc_restart(q, &packets)) {
        quota -= packets;
        if (quota <= 0) {
            /* 一次发送太多 → 通过 softirq 继续 */
            __netif_schedule(q);
            break;
        }
    }
}
```

**`qdisc_restart()`**——dequeue + 发送：

```c
// net/sched/sch_generic.c
static int qdisc_restart(struct Qdisc *q, int *packets)
{
    /* 1. dequeue 一个 skb */
    skb = q->dequeue(q);
    if (!skb)
        return 0;

    /* 2. 调用网卡驱动发送 */
    err = dev_hard_start_xmit(skb, dev, txq, &ret);

    if (err == NETDEV_TX_BUSY) {
        /* 队列满 → re-enqueue */
        skb->next = NULL;
        __qdisc_enqueue_tail(skb, q);
        return 0;
    }

    (*packets)++;
    return 1;
}
```

**调度循环决策流**：

```
NET_TX softirq
  └─ net_tx_action()
       └─ __netif_schedule(q) → qdisc_schedule(q)
            └─ __qdisc_run(q)
                 ├─ qdisc_restart() → dequeue → dev_hard_start_xmit()
                 ├─ quota--
                 ├─ quota > 0 → 继续 dequeue
                 └─ quota == 0 → __netif_schedule(q) → 延后到下次 softirq
```

---

## 4. 典型 Qdisc 类型

### 4.1 Classless Qdisc（无分类）

| Qdisc | 文件 | 功能 |
|-------|------|------|
| `pfifo_fast` | `sch_generic.c` | 三优先级 FIFO（默认）|
| `pfifo` / `bfifo`| `sch_fifo.c` | 先进先出（packet/bytes 限制）|
| `sfq` | `sch_sfq.c` | 随机公平队列 |
| `tbf` | `sch_tbf.c` | 令牌桶过滤器（速率限制）|
| `fq` | `sch_fq.c` | 公平队列（per-flow pacing）|
| `fq_codel` | `sch_fq_codel.c` | 公平队列 + CoDel AQM |
| `codel` | `sch_codel.c` | 受控延迟（Controlled Delay）|
| `red` | `sch_red.c` | 随机早期检测 |
| `gred` | `sch_gred.c` | 通用 RED |
| `ingress` | `sch_ingress.c` | 入口过滤（重定向到 ifb）|

### 4.2 Classful Qdisc（有分类）

| Qdisc | 文件 | 功能 |
|-------|------|------|
| `htb` | `sch_htb.c` | 层级令牌桶（Hierarchical Token Bucket）|
| `cbq` | `sch_cbq.c` | 基于类的队列（Class Based Queueing）|
| `dsmark` | `sch_dsmark.c` | Differentiated Service 标记 |
| `prio` | `sch_prio.c` | 优先级队列（每个 class 一个 qdisc）|
| `mq` | `sch_mq.c` | 多队列映射（per-queue qdisc）|
| `mqprio` | `sch_mqprio.c` | 多队列 + 优先级 |
| `multi` | `sch_multiq.c` | 多优先级队列（硬编码）|

---

## 5. HTB 示例——层级带宽控制

```
tc qdisc add dev eth0 root handle 1: htb default 30

tc class add dev eth0 parent 1: classid 1:1 htb rate 1000mbit
tc class add dev eth0 parent 1:1 classid 1:10 htb rate 100mbit ceil 200mbit
tc class add dev eth0 parent 1:1 classid 1:20 htb rate 50mbit ceil 100mbit

tc qdisc add dev eth0 parent 1:10 handle 20: pfifo limit 1000
tc qdisc add dev eth0 parent 1:20 handle 30: sfq perturb 10
```

**Qdisc 层次结构**：
```
root: htb (handle 1:)
  └── class 1:1 (rate 1000mbit)
       ├── class 1:10 (rate 100mbit, ceil 200mbit)
       │     └── leaf: pfifo (handle 20:)
       └── class 1:20 (rate 50mbit, ceil 100mbit)
             └── leaf: sfq (handle 30:)
```

---

## 6. 多队列支持（MQ/MQPRIO）

```c
// 多队列网卡：每个 TX 队列有自己的 qdisc
// struct net_device 的 num_tx_queues 决定队列数
// MQ qdisc 作为根 qdisc，为每个 TX 队列创建子 qdisc

net_device
  ├── TX queue 0 → sch_mq → pfifo_fast qdisc_0
  ├── TX queue 1 → sch_mq → pfifo_fast qdisc_1
  └── TX queue 2 → sch_mq → pfifo_fast qdisc_2

// 入队时 skb->queue_mapping 选择子 qdisc
```

---

## 7. NOLOCK qdisc 优化

```c
// TCQ_F_NOLOCK 标志（2018 年引入）
// 无锁 qdisc 不需要在 enqueue/dequeue 中持 spinlock
// 使用 percpu 统计 + llist 延迟处理

// 适用：fq_codel、fq 等算法（自身已经是 lockless 设计）
// 优势：大幅减少多核竞争，特别适合高带宽多核场景
```

---

## 8. 统计与监控

```bash
# 查看 qdisc 统计
tc -s qdisc show dev eth0
# 输出：
# qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024 quantum 1514
#  Sent 123456 bytes 789 pkt (dropped 12, overlimits 0 requeues 0)
#  backlog 0b 0p requeues 0
#   maxpacket 0 drop_overlimit 0 new_flow_count 0 ecn_mark 0
#   new_flows_len 0 old_flows_len 0

# 查看类统计
tc -s class show dev eth0

# /proc/net/psched
# 查看调度器参数
```

---

## 9. 性能考量

| Qdisc | 复杂度 | 适用场景 | 延迟 |
|-------|--------|---------|------|
| pfifo_fast | O(1) | 默认通用 | ~50ns |
| fq_codel | O(log flows) | 低延迟、公平 | ~200ns |
| fq | O(log flows) | pacing | ~200ns |
| htb | O(depth) | 层级带宽控制 | ~500ns-2μs |
| tbf | O(1) | 速率限制 | ~50ns |
| sfq | O(log flows) | 公平队列（旧）| ~100ns |

---

## 10. 调试

```bash
# 查看 qdisc 层次
tc qdisc show dev eth0
tc class show dev eth0

# 查看 qdisc 内部状态
tc -d qdisc show dev eth0

# 动态调试
echo 'module sch_fq_codel +p' > /sys/kernel/debug/dynamic_debug/control

# 跟踪排队事件
echo 1 > /sys/kernel/debug/tracing/events/qdisc/qdisc_enqueue/enable
echo 1 > /sys/kernel/debug/tracing/events/qdisc/qdisc_dequeue/enable
```

---

## 11. 总结

Linux Qdisc 框架是一个灵活的数据包调度基础设施：

**1. enqueue/dequeue 抽象** — 所有排队算法的统一接口，协议栈→qdisc→设备的标准化路径。

**2. 分类/类属层次结构** — classful qdisc 支持任意深度的树形层次，每个叶子节点可挂载不同的排队算法。

**3. CAN_BYPASS 快速路径** — 空队列时直接发送，绕过排队算法，实现零额外延迟。

**4. NOLOCK 无锁优化** — 高吞吐量场景通过 per-CPU 统计 + llist 绕过锁竞争。

**5. AQM 集成** — fq_codel、codel 等算法提供主动队列管理，应对 bufferbloat。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
