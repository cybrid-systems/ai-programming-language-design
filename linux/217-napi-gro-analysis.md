# napi_gro — Generic Receive Offload 机制分析

> 基于 Linux 7.0-rc1 (`net/core/dev.c` + `net/core/gro.c`)
> 源码行号均指向实际文件位置

## 1. struct napi_struct 核心字段

```c
// include/linux/netdevice.h:381
struct napi_struct {
    unsigned long           state;          // 位掩码，控制调度状态
    struct list_head        poll_list;       // 挂载到 per-CPU poll_list 的链表节点
    int                     weight;          // 本次 poll 调用的工作配额（默认 64）
    u32                     defer_hard_irqs_count;
    int                     (*poll)(struct napi_struct *, int);  // 驱动注册的轮询函数
    int                     poll_owner;      // 正在运行 poll 的 CPU ID
    int                     list_owner;      // 将 napi 调度到 poll_list 的 CPU
    struct net_device       *dev;            // 所属网络设备
    struct sk_buff          *skb;           // 为 GRO frags 模式复用的 skb 缓存
    struct gro_node         gro;             // GRO 缓冲节点（内嵌 gro_node）
    struct hrtimer          timer;           // GRO 超时定时器
    struct task_struct      *thread;         // threaded NAPI 专用线程
    unsigned long           gro_flush_timeout;
    unsigned long           irq_suspend_timeout;
    u32                     defer_hard_irqs;
    u32                     napi_id;         // 全局唯一 NAPI ID
    struct list_head        dev_list;        // 挂在 net_device->napi_list 上
    struct hlist_node       napi_hash_node;  // napi_hash 全局哈希表节点
    int                     irq;             // 中断号
    struct irq_affinity_notify notify;
    int                     napi_rmap_idx;
    int                     index;
    struct napi_config      *config;
};
```

### 状态位（`enum napi_state`）

| 位 | 名称 | 含义 |
|---|---|---|
| `NAPI_STATE_SCHED` | `NAPIF_STATE_SCHED` | NAPI 已被调度，正在 `poll_list` 上 |
| `NAPI_STATE_MISSED` | `NAPIF_STATE_MISSED` | 曾在 SCHED 状态下被跳过，需下次重调度 |
| `NAPI_STATE_DISABLE` | `NAPIF_STATE_DISABLE` | 正在执行 `napi_disable()`，禁止新调度 |
| `NAPI_STATE_NPSVC` | `NAPIF_STATE_NPSVC` | Netpoll 模式，不从 poll_list 出队 |
| `NAPI_STATE_LISTED` | `NAPIF_STATE_LISTED` | 已加入系统 napi_hash 全局列表 |
| `NAPI_STATE_NO_BUSY_POLL` | — | 不加入 napi_hash，无 busy poll |
| `NAPI_STATE_IN_BUSY_POLL` | — | 正在 busy poll 中，禁止并发 `napi_complete_done` |
| `NAPI_STATE_PREFER_BUSY_POLL` | — | 优先 busy poll 而非软中断 |
| `NAPI_STATE_THREADED` | `NAPIF_STATE_THREADED` | 允许 threaded（专用线程）模式 |
| `NAPI_STATE_SCHED_THREADED` | `NAPIF_STATE_SCHED_THREADED` | 当前在线程中调度 |

## 2. struct gro_node — GRO 缓冲容器

```c
// include/linux/netdevice.h:348
#define GRO_HASH_BUCKETS  8

struct gro_list {
    struct list_head    list;   // 同一 flow 的待合并 skb 链表
    int                 count; // 该 bucket 中 skb 数量
};

struct gro_node {
// include/linux/netdevice.h:351
    unsigned long       bitmask;              //  位掩码，记录哪些 hash bucket 非空
    struct gro_list     hash[GRO_HASH_BUCKETS]; // 8 个 flow 分离的合并缓冲桶
    struct list_head    rx_list;               //  GRO_NORMAL 类型 skb 链表
    u32                 rx_count;             //  rx_list 长度缓存
    u32                 cached_napi_id;       //  热路径优化，0 代表独立节点
};
```

每个 NAPI 实例直接内嵌一个 `gro_node`（如 `struct napi_struct.gro`），GRO 缓冲按 **flow hash** 分流到 8 个 bucket 中，最多缓存 `MAX_GRO_SKBS=8` 个 skb 再强制刷新最旧的。

## 3. napi_enable / napi_disable 机制

### 3.1 napi_enable_locked（dev.c:7650）

```c
void napi_enable_locked(struct napi_struct *n)
{
    unsigned long new, val = READ_ONCE(n->state);

    // 恢复 config（threaded 模式参数）或加入全局 napi_hash
    if (n->config)
        napi_restore_config(n);
    else
        napi_hash_add(n);

    // 原子地清除 SCHED | NPSVC，写入 THREADED 标志
    do {
        BUG_ON(!test_bit(NAPI_STATE_SCHED, &val));
        new = val & ~(NAPIF_STATE_SCHED | NAPIF_STATE_NPSVC);
        if (n->dev->threaded && n->thread)
            new |= NAPIF_STATE_THREADED;
    } while (!try_cmpxchg(&n->state, &val, new));
}
```

关键：只有在**锁保护**（`netdev_lock`）下才调用此函数；使用 `try_cmpxchg` 保证原子性更新。

### 3.2 napi_disable_locked（dev.c:7601）

```c
void napi_disable_locked(struct napi_struct *n)
{
    set_bit(NAPI_STATE_DISABLE, &n->state);

    // 轮询等待直到 SCHED | NPSVC 被清除（poll 完成时由 napi_complete_done 清除）
    val = READ_ONCE(n->state);
    do {
        while (val & (NAPIF_STATE_SCHED | NAPIF_STATE_NPSVC)) {
            usleep_range(20, 200);  // 等待 poll() 退出
            val = READ_ONCE(n->state);
        }
        // 原子地设置 SCHED | NPSVC，清除线程相关状态
        new = val | NAPIF_STATE_SCHED | NAPIF_STATE_NPSVC;
        new &= ~(NAPIF_STATE_THREADED |
                 NAPI_STATE_THREADED_BUSY_POLL |
                 NAPI_STATE_PREFER_BUSY_POLL);
    } while (!try_cmpxchg(&n->state, &val, new));

    hrtimer_cancel(&n->timer);
    // 从 napi_hash 移除（若非 config 模式）
    if (n->config)
        napi_save_config(n);
    else
        napi_hash_del(n);

    clear_bit(NAPI_STATE_DISABLE, &n->state);
}
```

**状态机转换示意：**

```
napi_enable()
  state = 0 → 加到 napi_hash
  state &= ~(SCHED|NPSVC) → 可调度

napi_schedule() / napi_schedule_prep()
  state |= SCHED → 加入 poll_list，可被 net_rx_action() 处理

napi_complete_done()
  state &= ~(SCHED|MISSED) → 离开 poll_list
  若有 MISSED → state |= SCHED（下次重调度）

napi_disable()
  state |= DISABLE → 禁止新调度
  轮询等待 SCHED | NPSVC 消失
  state |= SCHED | NPSVC → 确保 poll() 不会再启动
  napi_hash_del() → 从全局表移除
  clear_bit(DISABLE) → 禁用完成
```

## 4. napi_schedule → __napi_schedule → raise_softirq_irqoff

### 4.1 napi_schedule_prep（dev.c:6729）

```c
bool napi_schedule_prep(struct napi_struct *n)
{
    unsigned long new, val = READ_ONCE(n->state);

    do {
        // 如果已经在 DISABLE 过程中，直接返回 false
        if (unlikely(val & NAPIF_STATE_DISABLE))
            return false;

        new = val | NAPIF_STATE_SCHED;

        // 如果 SCHED 已经设置，说明已被调度过，设置 MISSED 位
        new |= (val & NAPIF_STATE_SCHED) / NAPI_STATE_SCHED *
                                        NAPIF_STATE_MISSED;
    } while (!try_cmpxchg(&n->state, &val, new));

    // 返回：之前不在 SCHED 状态 → true（可以调度）
    return !(val & NAPIF_STATE_SCHED);
}
```

### 4.2 __napi_schedule（dev.c:6710）

```c
void __napi_schedule(struct napi_struct *n)
{
    unsigned long flags;

    local_irq_save(flags);
    ____napi_schedule(this_cpu_ptr(&softnet_data), n);
    local_irq_restore(flags);
}
EXPORT_SYMBOL(__napi_schedule);
```

### 4.3 ____napi_schedule（dev.c:4957）

```c
/* Called with irq disabled */
static inline void ____napi_schedule(struct softnet_data *sd,
                                    struct napi_struct *napi)
{
    struct task_struct *thread;

    lockdep_assert_irqs_disabled();

    if (test_bit(NAPI_STATE_THREADED, &napi->state)) {
        // threaded 模式：唤醒专用 kthread，不添加到 poll_list
        thread = READ_ONCE(napi->thread);
        if (thread) {
            if (use_backlog_threads() && thread == raw_cpu_read(backlog_napi))
                goto use_local_napi;

            set_bit(NAPI_STATE_SCHED_THREADED, &napi->state);
            wake_up_process(thread);       // 唤醒专用线程
            return;
        }
    }

use_local_napi:
    // 普通模式：将 napi 添加到 per-CPU poll_list
    list_add_tail(&napi->poll_list, &sd->poll_list);
    WRITE_ONCE(napi->list_owner, smp_processor_id());

    // 如果不是在 net_rx_action 上下文中，手动触发软中断
    if (!sd->in_net_rx_action)
        raise_softirq_irqoff(NET_RX_SOFTIRQ);
}
```

`sd->in_net_rx_action` 标志用于**嵌套检测**：当 `net_rx_action` 正在执行并调用 `____napi_schedule`（比如在 RPS 路径上）时，无需再次触发软中断——当前正在运行的 `net_rx_action` 会在适当时候处理新的 `poll_list` 条目。

## 5. napi_gro_receive / napi_gro_frags 核心流程

### 5.1 gro_receive_skb（gro.c:624）

```c
gro_result_t gro_receive_skb(struct gro_node *gro, struct sk_buff *skb)
{
    gro_result_t ret;

    __skb_mark_napi_id(skb, gro);
    trace_napi_gro_receive_entry(skb);
    skb_gro_reset_offset(skb, 0);

    ret = gro_skb_finish(gro, skb, dev_gro_receive(gro, skb));
    trace_napi_gro_receive_exit(ret);

    return ret;
}
EXPORT_SYMBOL(gro_receive_skb);
```

### 5.2 dev_gro_receive（gro.c:462）

```
dev_gro_receive(gro, skb)
│
├─ netif_elide_gro() → 跳过 GRO，直接 GRO_NORMAL
│
├─ gro_list_prepare() — 遍历 bucket 中已有 skb，逐个比较 same_flow
│   └─ same_flow 判断：hash 值、dev、vlan、mac_header、sk、nf_ct、TC ext、PSP...
│
├─ 在 offload_base 中按 type 查找对应的 packet_offload.gro_receive 回调
│   └─ 例如 inet_gro_receive / ipv6_gro_receive（TCP/UDP/ICMP）
│
├─ 协议层 gro_receive() 返回值：
│   ├─ pp != NULL && same_flow → 合并到现有 skb → GRO_MERGED / GRO_MERGED_FREE
│   ├─ pp == NULL（被协议层拒绝）→ GRO_HELD（进入 gro_node.hash bucket）
│   └─ pp != NULL && !same_flow → GRO_NORMAL（不合并）
│
└─ 若 GRO_HELD 且 bucket 已满（≥ MAX_GRO_SKBS=8）
    └─ gro_flush_oldest() — 强制完成最老的 skb 并出队
```

### 5.3 skb_gro_receive（gro.c:92）— 真正的缓冲合并逻辑

```c
int skb_gro_receive(struct sk_buff *p, struct sk_buff *skb)
{
    // 1. pp_recycle 不匹配直接拒绝（page pool vs non-page pool 不可混并）
    if (p->pp_recycle != skb->pp_recycle)
        return -ETOOMANYREFS;

    // 2. 合并后大小超限拒绝
    if (unlikely(p->len + len >= netif_get_gro_max_size(p->dev, p) ||
                 NAPI_GRO_CB(skb)->flush))
        return -E2BIG;

    // 3. legacy TCP 合并超限检测
    if (unlikely(p->len + len >= GRO_LEGACY_MAX_SIZE)) {
        if (NAPI_GRO_CB(skb)->proto != IPPROTO_TCP || p->encapsulation)
            return -E2BIG;
    }

    segs = NAPI_GRO_CB(skb)->count;
    lp = NAPI_GRO_CB(p)->last;
    pinfo = skb_shinfo(lp);

    // ── 路径 A：headroom 足够，直接合并 fragment ──
    if (headlen <= offset) {
        // 将 skb 的所有 frag 追加到 p 的 frag 数组
        pinfo->nr_frags += skbinfo->nr_frags;
        NAPI_GRO_CB(skb)->free = NAPI_GRO_FREE;
        goto done;
    }
    // ── 路径 B：skb 有线性 head_frag ──
    else if (skb->head_frag) {
        // 在 pinfo->frags 中新增一个描述 head 的 frag descriptor
        pinfo->nr_frags = nr_frags + 1 + skbinfo->nr_frags;
        skb_frag_fill_page_desc(frag, page, first_offset, first_size);
        goto done;
    }
    // ── 路径 C：都不满足 → frag_list 模式（skb 作为子链挂到 p）──
merge:
    skb->destructor = NULL;
    skb->sk = NULL;
    if (NAPI_GRO_CB(p)->last == p)
        skb_shinfo(p)->frag_list = skb;  // 首个 frag_list 节点
    else
        NAPI_GRO_CB(p)->last->next = skb;
    NAPI_GRO_CB(p)->last = skb;
    __skb_header_release(skb);
done:
    // 更新聚合后的统计信息
    NAPI_GRO_CB(p)->count += segs;
    p->data_len += len;
    p->truesize += delta_truesize;
    p->len += len;
    NAPI_GRO_CB(skb)->same_flow = 1;
    return 0;
}
```

### 5.4 napi_gro_frags（gro.c:763）

```c
gro_result_t napi_gro_frags(struct napi_struct *napi)
{
    struct sk_buff *skb = napi->skb;   // 从 napi->skb 复用缓存

    napi->skb = NULL;
    skb_gro_reset_offset(skb, hlen);

    // 从 skb 提取 eth hdr，修复 network header 位置
    if (unlikely(!skb_gro_may_pull(skb, hlen))) {
        eth = skb_gro_header_slow(skb, hlen, 0);
        ...
    }

    skb->protocol = eth->h_proto;
    ret = napi_frags_finish(napi, skb, dev_gro_receive(&napi->gro, skb));
    trace_napi_gro_frags_exit(ret);
    return ret;
}
EXPORT_SYMBOL(napi_gro_frags);
```

## 6. gro_normal_receive / napi_complete_done

### 6.1 gro_normal_one（gro.c:265）

`gro_normal_one` 将 `GRO_NORMAL` 类型（即不能或不应该参与 GRO 合并）的 skb 放入 `gro_node.rx_list`，供后续 `gro_flush_normal` 批量出队：

```c
static void gro_normal_one(struct gro_node *gro, struct sk_buff *skb, int segs)
{
    // 添加到 rx_list
    list_add_tail(&skb->list, &gro->rx_list);
    gro->rx_count += segs;
}
```

### 6.2 gro_flush_normal（gro.c 约287）

```c
void gro_flush_normal(struct gro_node *gro, unsigned long expire)
{
    struct list_head *head = &gro->rx_list;
    struct sk_buff *skb;

    // 按 rx_count 批量出队 rx_list 中的 skb，送往协议栈
    while ((skb = list_first_entry_or_null(head, struct sk_buff, list))) {
        list_del_init(&skb->list);
        gro->rx_count--;
        // 送协议栈处理
        netif_receive_skb(skb);
    }
}
```

### 6.3 napi_complete_done（dev.c:6771）

```c
bool napi_complete_done(struct napi_struct *n, int work_done)
{
    unsigned long flags, val, new, timeout = 0;
    bool ret = true;

    // Netpoll / busy poll 模式：不处理，直接返回
    if (unlikely(n->state & (NAPIF_STATE_NPSVC | NAPIF_STATE_IN_BUSY_POLL)))
        return false;

    if (work_done) {
        if (n->gro.bitmask)
            timeout = napi_get_gro_flush_timeout(n);
        n->defer_hard_irqs_count = napi_get_defer_hard_irqs(n);
    }
    // 延迟硬中断计数：递减计数，触发超时则不忙等待
    if (n->defer_hard_irqs_count > 0) {
        n->defer_hard_irqs_count--;
        timeout = napi_get_defer_flush_timeout(n);
        if (timeout)
            ret = false;
    }

    // 刷新 GRO_NORMAL 缓冲区的数据包
    gro_flush_normal(&n->gro, !!timeout);

    // 从 poll_list 移除
    if (unlikely(!list_empty(&n->poll_list))) {
        local_irq_save(flags);
        list_del_init(&n->poll_list);
        local_irq_restore(flags);
    }
    WRITE_ONCE(n->list_owner, -1);

    // 原子地清除 SCHED 相关位；若 MISSED 置位则重新设置 SCHED
    val = READ_ONCE(n->state);
    do {
        WARN_ON_ONCE(!(val & NAPIF_STATE_SCHED));
        new = val & ~(NAPIF_STATE_MISSED | NAPIF_STATE_SCHED |
                      NAPIF_STATE_SCHED_THREADED |
                      NAPIF_STATE_PREFER_BUSY_POLL);
        new |= (val & NAPIF_STATE_MISSED) / NAPI_STATE_MISSED *
                                    NAPIF_STATE_SCHED;
    } while (!try_cmpxchg(&n->state, &val, new));

    // 若有 MISSED：重新调度
    if (unlikely(val & NAPIF_STATE_MISSED)) {
        __napi_schedule(n);
        return false;
    }

    // 启动 GRO 超时定时器
    if (timeout)
        hrtimer_start(&n->timer, ns_to_ktime(timeout),
                      HRTIMER_MODE_REL_PINNED);
    return ret;
}
EXPORT_SYMBOL(napi_complete_done);
```

## 7. GRO 缓冲合并规则（skb_gro_receive）

### 合并条件

| 条件 | 不满足时的处理 |
|---|---|
| `pp_recycle` 匹配 | 返回 `-ETOOMANYREFS`，两 skb 不合并 |
| 合并后 `len < GRO_MAX_SIZE (8*65535)` | 返回 `-E2BIG` |
| Legacy TCP：`len < GRO_LEGACY_MAX_SIZE (65536)` 且为 TCP 非封装包 | 返回 `-E2BIG` |
| frag 数量 `nr_frags <= MAX_SKB_FRAGS` | 走 frag 直接追加路径 |
| 否则 | 回退到 frag_list 链表模式 |

### same_flow 判断（gro_list_prepare，gro.c:343）

**逐字段比较**产生 `diffs`，零差异则 same_flow：

```
diffs = dev(物理设备指针) 差异
      | vlan_all 位域差异
      | skb_metadata_dst_cmp() 元数据差异
      | mac_header 比较（ETH_HLEN 内用 compare_ether_header，否则 memcmp）
      | （若 slow_gro）sk 指针差异
      | （若 slow_gro）nf_ct 差异
      | （若 slow_gro）TC ext chain 差异
      | （若 slow_gro）PSP coalesce 差异
      | hash 值差异（前面已比较）
```

`same_flow=0` 的 skb 不会被当前 bucket 合并，但会作为新 bucket 条目加入（或走 `GRO_NORMAL` 路径）。

## 8. dev_gro_receive → napi_gro_receive → NET_RX_SOFTIRQ 处理全流程

```
驱动收到数据包
    │
    ▼
netif_rx() / netif_receive_skb()
    │
    ├─ 设置 skb->dev 和 skb->skb_iif
    ├─ 更新 rx_per_cpu 统计
    ▼
__netif_receive_skb()
    │
    ├─ 遍历 ptype_all 发送 PACKET_HOST 事件
    ├─ 查找 rx_handler（bridge、vlan、bonding...）
    │   └─ 若 RX_HANDLER_CONSUMED：skb 被吞，流程结束
    │
    ▼
__netif_receive_skb_core()
    │
    ├─ 查找 ptype_base[protocol] 上的协议 handler（IP、ARP...）
    │   └─ 若存在 gro_receive 回调，走 GRO 路径
    │   └─ 若无，回调 process_rcv，然后 goto deliver
    │
    ▼
gro 路径（协议层注册了 gro_receive 回调）
    │
    ├─ napi_gro_receive() 或 napi_gro_frags()
    │   │
    │   ├─ gro_receive_skb(&napi->gro, skb)
    │   │   ├─ dev_gro_receive()
    │   │   │   ├─ gro_list_prepare() — same_flow 检查
    │   │   │   ├─ 找 packet_offload.gro_receive 回调
    │   │   │   │   └─ 例：inet_gro_receive()（TCP/UDP）
    │   │   │   │       ├─ 初始化 NAPI_GRO_CB
    │   │   │   │       ├─ same_flow=1 → skb_gro_receive() 合并
    │   │   │   │       └─ same_flow=0 → GRO_NORMAL
    │   │   │   └─ 返回：GRO_MERGED / GRO_HELD / GRO_NORMAL / ...
    │   │   └─ gro_skb_finish() 按返回值处理
    │   │       ├─ GRO_NORMAL → gro_normal_one() → rx_list
    │   │       ├─ GRO_MERGED → 无操作（已合并）
    │   │       └─ GRO_MERGED_FREE → 释放 skb
    │   │
    │   └─ 返回 gro_result_t
    │
    └─ NET_RX_SOFTIRQ 被触发（在 backlog 路径上）

NET_RX_SOFTIRQ 软中断（net_rx_action）
    │
    ├─ 遍历 per-CPU softnet_data.poll_list（从 head 向 tail）
    │   │
    │   ├─ 设置 sd->in_net_rx_action = true
    │   │
    │   ├─ 取出 napi，从 poll_list 解链
    │   │
    │   ├─ 调用 napi->poll(napi, budget)
    │   │   └─ 驱动 poll 函数：读取 descriptors，组装 skb
    │   │       ├─ 每个 skb 调用 napi_gro_receive() 或 napi_gro_frags()
    │   │       └─ 返回已处理的工作量
    │   │
    │   ├─ napi_complete_done(n, work_done)
    │   │   ├─ gro_flush_normal() — 刷新 rx_list
    │   │   ├─ 清除 SCHED 位
    │   │   └─ 若有 MISSED → __napi_schedule() 重调度
    │   │
    │   └─ 检查 budget 是否耗尽，若耗尽重新调度 SCHED/MISSED
    │
    └─ 设置 sd->in_net_rx_action = false
```

## 9. NAPI vs 传统中断模式对比

### 传统中断模式（每包一次 IRQ）

```
数据包到达 → 触发 IRQ → CPU 中断 → 驱动读取数据 → 发送至协议栈 → 返回
     │
     问题：高速网络下 IRQ 风暴，CPU 被切碎，cache miss 严重
```

### NAPI 模式（轮询批量处理）

```
数据包到达 → 触发单个 IRQ（或 modem 状态变化）
     │
     ▼
napi_schedule() → 将 napi 添加到 poll_list → 触发 NET_RX_SOFTIRQ
     │
     ▼
net_rx_action（软中断）→ 调用 napi->poll(batch=N）→ 批量读取 N 个数据包
     │
     ▼
每个 skb 经 napi_gro_receive() 尝试 GRO 合并后送协议栈
     │
     ▼
napi_complete_done() → 返回 poll_list → 若有更多数据 → 重新调度
```

### 关键差异总结

| 方面 | 传统 IRQ 模式 | NAPI 模式 |
|---|---|---|
| **中断频率** | 每个包一次 IRQ | 每批次一个 IRQ（或零 IRQ） |
| **CPU 开销** | 高（IRQ 风暴） | 低（批量轮询） |
| **缓存友好性** | 差（频繁跨函数跳转） | 好（批量顺序处理） |
| **GRO 合并** | 不支持 | 原生支持（flow hash 分组） |
| **Busy Poll** | 不支持 | 支持（用户空间可主动轮询） |
| **Threaded NAPI** | 不支持 | 支持（专用 kthread 线程模型） |
| **调度粒度** | 无（随机竞争） | 有（weight/budget 限制） |

### Threaded NAPI 特殊路径

```
napi_schedule() → napi_schedule_prep() → __napi_schedule()
    │
    ▼
____napi_schedule()
    │
    ├─ 若 NAPI_STATE_THREADED 置位：
    │   └─ wake_up_process(napi->thread) → 不添加到 poll_list
    │
    └─ 否则：
        ├─ list_add_tail(&napi->poll_list, &sd->poll_list)
        └─ raise_softirq_irqoff(NET_RX_SOFTIRQ)
```

### gro_node 与 per-CPU 的关系

```
每个 CPU：softnet_data.poll_list  — 当前待处理的 NAPI 实例链表
         softnet_data.backlog    — 系统级 backlog NAPI（无驱动的伪设备）

每个 NAPI 实例：struct napi_struct {
                    struct gro_node  gro;   // GRO 缓冲容器
                    struct list_head poll_list; // 挂 poll_list 链表
                    ...
                 }

每个 gro_node：
    bitmask          — 标记哪些 hash bucket 有数据
    hash[8]          — 8 个 flow bucket（same_flow 的 skb 放同一 bucket）
    rx_list         — GRO_NORMAL skb 链表
    rx_count        — rx_list 长度
```

## 附：gro_result 枚举

```c
enum gro_result {
    GRO_MERGED,       // skb 已合并到现有分组，调用者应释放 skb
    GRO_MERGED_FREE,  // 合并后原 skb 已被 free（STOLEN_HEAD 或 kfree）
    GRO_HELD,         // skb 保留在 GRO 层，等待后续数据包合并或超时完成
    GRO_NORMAL,      // 不合并，作为普通数据包送协议栈
    GRO_CONSUMED,     // 协议层完全消费了 skb（如 tunnel decap）
};
```

> `dev_gro_receive` 内部协议层回调返回 `pp` 非空表示"已处理（合并或消费）"，`pp` 为 NULL 表示"请按普通方式处理"。`gro_skb_finish` 按上述枚举值决定是 `gro_normal_one`（进 `rx_list`）、释放 skb 还是静默丢弃。


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

