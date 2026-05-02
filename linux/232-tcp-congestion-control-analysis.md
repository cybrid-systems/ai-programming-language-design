# tcp_congestion_control — Linux TCP 拥塞控制框架分析

## 1. 概述

Linux 内核的 TCP 拥塞控制（Congestion Control）采用**插件化架构**，通过 `struct tcp_congestion_ops` 定义统一操作集，支撑 Reno、CUBIC、Hybla 等多种算法自由插拔。本分析基于 Linux 7.0-rc1 源码，文件路径：

- `/net/ipv4/tcp_cong.c` — 框架主体 + Reno
- `/net/ipv4/tcp_cubic.c` — CUBIC 实现
- `/net/ipv4/tcp_hybla.c` — Hybla 实现
- `/include/net/tcp.h` — 核心数据结构

---

## 2. struct tcp_congestion_ops — 拥塞控制操作集

**定义位置**：`tcp.h:1315`

```c
struct tcp_congestion_ops {
/* fast path fields are put first to fill one cache line */

    /* (a) "classic" response: calculate new cwnd */
    void (*cong_avoid)(struct sock *sk, u32 ack, u32 acked);

    /* (b) "custom" response: complete control */
    void (*cong_control)(struct sock *sk, u32 ack, int flag,
                         const struct rate_sample *rs);

    /* return slow start threshold (required) */
    u32 (*ssthresh)(struct sock *sk);

    /* call before changing ca_state (optional) */
    void (*set_state)(struct sock *sk, u8 new_state);

    /* call when cwnd event occurs (optional) */
    void (*cwnd_event)(struct sock *sk, enum tcp_ca_event ev);

    /* call when CA_EVENT_TX_START cwnd event occurs (optional) */
    void (*cwnd_event_tx_start)(struct sock *sk);

    /* call when ack arrives (optional) */
    void (*in_ack_event)(struct sock *sk, u32 flags);

    /* hook for packet ack accounting (optional) */
    void (*pkts_acked)(struct sock *sk, const struct ack_sample *sample);

    /* override sysctl_tcp_min_tso_segs (optional) */
    u32 (*min_tso_segs)(struct sock *sk);

    /* new value of cwnd after loss (required) */
    u32  (*undo_cwnd)(struct sock *sk);

    /* returns the multiplier used in tcp_sndbuf_expand (optional) */
    u32 (*sndbuf_expand)(struct sock *sk);

    /* get info for inet_diag (optional) */
    size_t (*get_info)(struct sock *sk, u32 ext, int *attr,
                       union tcp_cc_info *info);

    char            name[TCP_CA_NAME_MAX];
    struct module  *owner;
    struct list_head list;
    u32            key;
    u32            flags;   /* TCP_CONG_NON_RESTRICTED | TCP_CONG_NEEDS_ECN */

    /* initialize private data (optional) */
    void (*init)(struct sock *sk);
    /* cleanup private data (optional) */
    void (*release)(struct sock *sk);
} ____cacheline_aligned_in_smp;
```

**关键字段说明**：

| 字段 | 必须 | 作用 |
|------|------|------|
| `cong_avoid` | 二选一 | 经典模式：在每个 ACK 时更新 cwnd |
| `cong_control` | 二选一 | 自定义模式：完全接管拥塞控制逻辑 |
| `ssthresh` | 必须 | 返回慢启动阈值 |
| `undo_cwnd` | 必须 | 丢包后撤销操作，返回有效 cwnd |
| `init` | 可选 | 初始化算法私有状态 |
| `release` | 可选 | 释放资源 |
| `flags` | — | `TCP_CONG_NEEDS_ECN`：需要 ECN 协作；`TCP_CONG_NON_RESTRICTED`：对非特权用户开放 |

### 2.1 算法注册与查找

**tcp_cong.c** 中维护一个全局链表 `tcp_cong_list`（行 16-17）：

```c
static DEFINE_SPINLOCK(tcp_cong_list_lock);
static LIST_HEAD(tcp_cong_list);
```

注册时对算法做验证（行 65-70）：

```c
int tcp_validate_congestion_control(struct tcp_congestion_ops *ca)
{
    /* all algorithms must implement these */
    if (!ca->ssthresh || !ca->undo_cwnd ||
        !(ca->cong_avoid || ca->cong_control)) {
        pr_err("%s does not implement required ops\n", ca->name);
        return -EINVAL;
    }
    return 0;
}
```

每个算法通过 `jhash(ca->name, ...)` 生成唯一 `key`（行 95），防止重复注册。

---

## 3. 初始化流程

### 3.1 tcp_init_congestion_control

**位置**：`tcp_cong.c:216`

```c
void tcp_init_congestion_control(struct sock *sk)
{
    struct inet_connection_sock *icsk = inet_csk(sk);

    tcp_sk(sk)->prior_ssthresh = 0;
    if (icsk->icsk_ca_ops->init)
        icsk->icsk_ca_ops->init(sk);
    if (tcp_ca_needs_ecn(sk))
        INET_ECN_xmit(sk);
    else
        INET_ECN_dontxmit(sk);
    icsk->icsk_ca_initialized = 1;
}
```

流程：
1. 记录 `prior_ssthresh`（用于后续撤销）
2. 调用算法自定义 `init` 回调（如有）
3. 根据算法是否需要 ECN 设置ECT位（ECN Capable Transport）

### 3.2 tcp_assign_congestion_control

**位置**：`tcp_cong.c:205`

```c
void tcp_assign_congestion_control(struct sock *sk)
{
    struct net *net = sock_net(sk);
    struct inet_connection_sock *icsk = inet_csk(sk);
    const struct tcp_congestion_ops *ca;

    rcu_read_lock();
    ca = rcu_dereference(net->ipv4.tcp_congestion_control);
    if (unlikely(!bpf_try_module_get(ca, ca->owner)))
        ca = &tcp_reno;        // 回退到 Reno
    icsk->icsk_ca_ops = ca;
    rcu_read_unlock();

    memset(icsk->icsk_ca_priv, 0, sizeof(icsk->icsk_ca_priv));
    // ... ECN 标志设置 ...
}
```

`icsk->icsk_ca_priv` 是 `ICSK_CA_PRIV_SIZE` 大小的算法私有数据区（通常为 ~200 字节），各算法在此存放状态。

---

## 4. 拥塞窗口与慢启动阈值

### 4.1 cwnd — 拥塞窗口

```c
// tcp.h:1508
static inline u32 tcp_snd_cwnd(const struct tcp_sock *tp)
{
    return tp->snd_cwnd;
}
```

`cwnd` 表示发送端允许的未确认数据量上限（以 MSS 为单位）。每次 ACK 到达时，通过 `cong_avoid` 增大 cwnd。

### 4.2 ssthresh — 慢启动阈值

```c
// tcp.h:1519
static inline bool tcp_in_slow_start(const struct tcp_sock *tp)
{
    return tcp_snd_cwnd(tp) < tp->snd_ssthresh;
}
```

- **cwnd < ssthresh**：处于**慢启动（Slow Start）**阶段，指数增长
- **cwnd >= ssthresh**：进入**拥塞避免（Congestion Avoidance）**阶段，线性增长

### 4.3 tcp_slow_start — 慢启动

**位置**：`tcp_cong.c:289`

```c
__bpf_kfunc u32 tcp_slow_start(struct tcp_sock *tp, u32 acked)
{
    u32 cwnd = min(tcp_snd_cwnd(tp) + acked, tp->snd_ssthresh);

    acked -= cwnd - tcp_snd_cwnd(tp);
    tcp_snd_cwnd_set(tp, min(cwnd, tp->snd_cwnd_clamp));

    return acked;
}
EXPORT_SYMBOL_GPL(tcp_slow_start);
```

慢启动中，每个 ACK 增加 cwnd 1 个 MSS。`tcp_slow_start` 一次性处理 `acked` 个被确认的 packet（stretch ACK），但受 `ssthresh` 上限约束。返回值是剩余"溢出"的 acked，可交给拥塞避免阶段继续处理。

### 4.4 tcp_cong_avoid_ai — 线性增长

**位置**：`tcp_cong.c:302`

```c
__bpf_kfunc void tcp_cong_avoid_ai(struct tcp_sock *tp, u32 w, u32 acked)
{
    /* If credits accumulated at a higher w, apply them gently now. */
    if (tp->snd_cwnd_cnt >= w) {
        tp->snd_cwnd_cnt = 0;
        tcp_snd_cwnd_set(tp, tcp_snd_cwnd(tp) + 1);
    }

    tp->snd_cwnd_cnt += acked;
    if (tp->snd_cwnd_cnt >= w) {
        u32 delta = tp->snd_cwnd_cnt / w;
        tp->snd_cwnd_cnt -= delta * w;
        tcp_snd_cwnd_set(tp, tcp_snd_cwnd(tp) + delta);
    }
    tcp_snd_cwnd_set(tp, min(tcp_snd_cwnd(tp), tp->snd_cwnd_clamp));
}
```

`w` 是算法提供的计数器（`cnt`），表示"每多少个 ACK 增长 1 个 cwnd"。每累计 `w` 个 ACK 的确认，cwnd 增加 1。

---

## 5. Reno / newreno — 标准 AIMD

### 5.1 Reno 的 ssthresh

**位置**：`tcp_cong.c:322`

```c
__bpf_kfunc u32 tcp_reno_ssthresh(struct sock *sk)
{
    const struct tcp_sock *tp = tcp_sk(sk);
    return max(tcp_snd_cwnd(tp) >> 1U, 2U);
}
```

丢包后 ssthresh 设为当前 cwnd 的一半（乘法减少，Multiplicative Decrease）。

### 5.2 Reno 的拥塞避免

**位置**：`tcp_cong.c:307`

```c
__bpf_kfunc void tcp_reno_cong_avoid(struct sock *sk, u32 ack, u32 acked)
{
    struct tcp_sock *tp = tcp_sk(sk);

    if (!tcp_is_cwnd_limited(sk))
        return;

    if (tcp_in_slow_start(tp)) {
        acked = tcp_slow_start(tp, acked);
        if (!acked)
            return;
    }
    /* In dangerous area, increase slowly. */
    tcp_cong_avoid_ai(tp, tcp_snd_cwnd(tp), acked);
}
```

**AIMD（Additive Increase Multiplicative Decrease）** 逻辑：
- **慢启动**：cwnd < ssthresh，指数增长（每个 ACK cwnd + 1）
- **拥塞避免**：cwnd >= ssthresh，每 RTT cwnd + 1（线性增长）
- **丢包时**：ssthresh = cwnd / 2，cwnd 通常回退到 1 或 2（TCP Reno 回到 1，newreno 回到 ssthresh）

### 5.3 Reno 的 undo_cwnd

```c
__bpf_kfunc u32 tcp_reno_undo_cwnd(struct sock *sk)
{
    const struct tcp_sock *tp = tcp_sk(sk);
    return max(tcp_snd_cwnd(tp), tp->prior_cwnd);
}
```

### 5.4 tcp_reno 全局实例

```c
struct tcp_congestion_ops tcp_reno = {
    .flags      = TCP_CONG_NON_RESTRICTED,
    .name       = "reno",
    .owner      = THIS_MODULE,
    .ssthresh   = tcp_reno_ssthresh,
    .cong_avoid = tcp_reno_cong_avoid,
    .undo_cwnd  = tcp_reno_undo_cwnd,
};
```

---

## 6. CUBIC — 二分查找导向的拥塞控制

### 6.1 bictcp 结构体

**位置**：`tcp_cubic.c:62`

```c
struct bictcp {
    u32  cnt;            /* increase cwnd by 1 after ACKs */
    u32  last_max_cwnd;  /* last maximum snd_cwnd (Wmax) */
    u32  last_cwnd;      /* the last snd_cwnd */
    u32  last_time;      /* time when updated last_cwnd */
    u32  bic_origin_point;   /* origin point of bic function */
    u32  bic_K;          /* time to origin point from epoch begin */
    u32  delay_min;      /* min delay (usec) */
    u32  epoch_start;    /* beginning of an epoch */
    u32  ack_cnt;        /* number of acks */
    u32  tcp_cwnd;       /* estimated tcp cwnd (for friendliness) */
    u16  unused;
    u8   sample_cnt;     /* number of samples for curr_rtt */
    u8   found;          /* exit point is found? */
    u32  round_start;    /* beginning of each round */
    u32  end_seq;        /* end_seq of the round */
    u32  last_ack;       /* last time when ACK spacing is close */
    u32  curr_rtt;       /* minimum rtt of current round */
};
```

存储在 `icsk->icsk_ca_priv` 中，`sizeof(struct bictcp)` 须小于 `ICSK_CA_PRIV_SIZE`（构建时 `BUILD_BUG_ON` 校验）。

### 6.2 cubictcp_init — 初始化

**位置**：`tcp_cubic.c:101`

```c
__bpf_kfunc static void cubictcp_init(struct sock *sk)
{
    struct bictcp *ca = inet_csk_ca(sk);

    bictcp_reset(ca);   // memset(ca, 0, offsetof(...))

    if (hystart)
        bictcp_hystart_reset(sk);

    if (!hystart && initial_ssthresh)
        WRITE_ONCE(tcp_sk(sk)->snd_ssthresh, initial_ssthresh);
}
```

`bictcp_reset`（行 91）将所有字段清零。Hybla 风格的 Hybrid Slow Start（Hystart）在初始化时记录 `round_start`、`end_seq` 等基准值。

### 6.3 bictcp_update — CUBIC 核心

**位置**：`tcp_cubic.c:158`

CUBIC 使用如下增长函数：

```
W(t) = C * (T - K)^3 + Wmax
```

其中 `K = cubic_root((Wmax - Wmin) * RTT / C)`，确保从 Wmax 下降到当前 cwnd 后，经过 K 秒能够恢复至 Wmax。

**关键步骤**（行 158-233）：

```c
static inline void bictcp_update(struct bictcp *ca, u32 cwnd, u32 acked)
{
    ca->ack_cnt += acked;

    // 1. 进入新 epoch：丢包后 epoch_start=0，每次更新先检查
    if (ca->epoch_start == 0) {
        ca->epoch_start = tcp_jiffies32;
        ca->ack_cnt = acked;
        ca->tcp_cwnd = cwnd;

        if (ca->last_max_cwnd <= cwnd) {
            // 处于上升段，未突破 Wmax
            ca->bic_K = 0;
            ca->bic_origin_point = cwnd;
        } else {
            // 丢包后重建 K
            ca->bic_K = cubic_root(cube_factor
                                   * (ca->last_max_cwnd - cwnd));
            ca->bic_origin_point = ca->last_max_cwnd;
        }
    }

    // 2. 计算 cubic 目标值
    t = (s32)(tcp_jiffies32 - ca->epoch_start);
    t += usecs_to_jiffies(ca->delay_min);
    t <<= BICTCP_HZ;  // 2^10 = 1024 分辨率
    do_div(t, HZ);

    offs = (t < ca->bic_K) ? (ca->bic_K - t) : (t - ca->bic_K);
    delta = (cube_rtt_scale * offs * offs * offs) >> (10+3*BICTCP_HZ);

    if (t < ca->bic_K)
        bic_target = ca->bic_origin_point - delta;
    else
        bic_target = ca->bic_origin_point + delta;

    // 3. cnt：多少个 ACK 增长 1 个 cwnd
    if (bic_target > cwnd)
        ca->cnt = cwnd / (bic_target - cwnd);
    else
        ca->cnt = 100 * cwnd;   // 极小增量

    // 4. TCP friendliness 修正（保证不比标准 Reno 慢）
    if (tcp_friendliness) {
        delta = (cwnd * beta_scale) >> 3;  // beta = 717/1024
        while (ca->ack_cnt > delta) {
            ca->ack_cnt -= delta;
            ca->tcp_cwnd++;
        }
        if (ca->tcp_cwnd > cwnd) {
            delta = ca->tcp_cwnd - cwnd;
            max_cnt = cwnd / delta;
            if (ca->cnt > max_cnt)
                ca->cnt = max_cnt;
        }
    }

    ca->cnt = max(ca->cnt, 2U);  // 最大增长速率为 1 cwnd/2 ACK = 1.5x/RTT
}
```

### 6.4 cubictcp_cong_avoid

**位置**：`tcp_cubic.c:237`

```c
__bpf_kfunc static void cubictcp_cong_avoid(struct sock *sk, u32 ack, u32 acked)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct bictcp *ca = inet_csk_ca(sk);

    if (!tcp_is_cwnd_limited(sk))
        return;

    if (tcp_in_slow_start(tp)) {
        acked = tcp_slow_start(tp, acked);
        if (!acked)
            return;
    }
    bictcp_update(ca, tcp_snd_cwnd(tp), acked);
    tcp_cong_avoid_ai(tp, ca->cnt, acked);
}
```

先用 `tcp_slow_start` 处理慢启动（cwnd < ssthresh）；进入拥塞避免后，用 `bictcp_update` 计算新的 `cnt`，再通过 `tcp_cong_avoid_ai` 执行线性增长。

### 6.5 cubictcp_recalc_ssthresh — 丢包后乘法减少

**位置**：`tcp_cubic.c:247`

```c
__bpf_kfunc static u32 cubictcp_recalc_ssthresh(struct sock *sk)
{
    const struct tcp_sock *tp = tcp_sk(sk);
    struct bictcp *ca = inet_csk_ca(sk);

    ca->epoch_start = 0;   // 结束当前 epoch，下次 ack 重新开始

    if (tcp_snd_cwnd(tp) < ca->last_max_cwnd && fast_convergence)
        // Fast Convergence：比完全恢复到 Wmax 更快
        ca->last_max_cwnd = (tcp_snd_cwnd(tp) * (BICTCP_BETA_SCALE + beta))
                            / (2 * BICTCP_BETA_SCALE);
    else
        ca->last_max_cwnd = tcp_snd_cwnd(tp);

    return max((tcp_snd_cwnd(tp) * beta) / BICTCP_BETA_SCALE, 2U);
}
```

`beta = 717`（即 `717/1024 ≈ 0.7`），所以 ssthresh 设为 `cwnd * 0.7`。

### 6.6 cubictcp_acked — RTT 采样与 HyStart 触发

**位置**：`tcp_cubic.c:304`

```c
__bpf_kfunc static void cubictcp_acked(struct sock *sk,
                                       const struct ack_sample *sample)
{
    const struct tcp_sock *tp = tcp_sk(sk);
    struct bictcp *ca = inet_csk_ca(sk);
    u32 delay;

    if (sample->rtt_us < 0)
        return;

    /* Discard delay samples right after fast recovery */
    if (ca->epoch_start && (s32)(tcp_jiffies32 - ca->epoch_start) < HZ)
        return;

    delay = sample->rtt_us ?: 1;

    if (ca->delay_min == 0 || ca->delay_min > delay)
        ca->delay_min = delay;

    if (!ca->found && tcp_in_slow_start(tp) && hystart)
        hystart_update(sk, delay);
}
```

更新 `delay_min`，同时在慢启动阶段通过 `hystart_update` 检测是否应提前退出慢启动（Hystart 机制）。

### 6.7 CUBIC 状态转移

```
                          丢包 / 超时
    ┌──────────────────────────────────────────┐
    │                                          ▼
 ┌─────────┐   cwnd >= ssthresh          ┌─────────┐
 │  慢启动   │ ───────────────────────▶  │ 拥塞避免 │
 │(指数增长) │                            │(CUBIC增长)│
 └─────────┘                              └─────────┘
    │                                          ▲
    │ cwnd >= hystart_low_window &&          │
    │ (ack_train_detected || delay_detected)   │
    │         退出慢启动，ssthresh = cwnd        │
    └──────────────────────────────────────────┘
                   (HyStart 提前退出)
```

---

## 7. Hybla — 高 RTT 链路优化

### 7.1 背景

Hybla 针对卫星网络等高 RTT 环境设计。标准 Reno 在 RTT 很高时吞吐率极低——因为 cwnd 在每个 RTT 内只增长固定量，而 RTT 越大，单位时间内可增长次数越少。

Hybla 的核心思想是：将高 RTT 链路"等效"为 RTT0 = 25ms 的标准链路，然后按比例调整增长速率。

### 7.2 hybla 结构体

```c
struct hybla {
    bool  hybla_en;
    u32   snd_cwnd_cents; /* 小数部分累积（<<7） */
    u32   rho;            /* Rho 参数，整数部分 */
    u32   rho2;           /* Rho^2，整数部分 */
    u32   rho_3ls;        /* Rho 参数，<<3 */
    u32   rho2_7ls;       /* Rho^2，<<7 */
    u32   minrtt_us;      /* 最小平滑 RTT */
};
```

`rho = srtt_us / (rtt0 * 1000)`，即当前 RTT 与参考 RTT（25ms）的比值。

### 7.3 增长公式

- **慢启动**：`INC = 2^rho - 1`（相当于把 rho 代入指数函数）
- **拥塞避免**：`INC = rho^2 / cwnd`

由于 `rho > 1` 时 `2^rho` 远大于 1，Hybla 在高 RTT 链路中增长速度远快于 Reno，从而弥补长 RTT 带来的带宽利用不足。

### 7.4 小数精度处理

`hybla.c:97` 使用 `snd_cwnd_cents`（<<7 精度）累积小数部分，每满 128（= 1）即增加 1 个 cwnd：

```c
ca->snd_cwnd_cents += odd;
while (ca->snd_cwnd_cents >= 128) {
    tcp_snd_cwnd_set(tp, tcp_snd_cwnd(tp) + 1);
    ca->snd_cwnd_cents -= 128;
    tp->snd_cwnd_cnt = 0;
}
```

---

## 8. 拥塞检测机制

Linux TCP 拥塞控制框架支持三类拥塞检测：

### 8.1 Loss-Based（丢包检测）

最经典的方式，通过超时或重复 ACK 触发：
- **3 个重复 ACK** → 进入 `TCP_CA_Recovery`，执行快速重传 + 选择性确认
- **超时** → 进入 `TCP_CA_Loss`，激进回退

算法在 `set_state` 回调中感知状态变化：

```c
static void cubictcp_state(struct sock *sk, u8 new_state)
{
    if (new_state == TCP_CA_Loss) {
        bictcp_reset(inet_csk_ca(sk));
        bictcp_hystart_reset(sk);
    }
}
```

### 8.2 ECN（显式拥塞通知）

RFC 3168 定义，路由器在即将丢包时将 IP 头 ECN 字段设为 `CE`，接收端回传 `ECT(1)` 触发 `CWR`（Congestion Window Reduced）。

- `TCP_CONG_NEEDS_ECN` 标志的算法（如 DCTCP）依赖此机制
- `tcp_init_congestion_control` 中根据 `tcp_ca_needs_ecn(sk)` 设置ECT位

### 8.3 Delay-Based（基于时延）

CUBIC 的 HyStart 是典型的 delay-based 检测：
- **ACK Train 检测**（行 222）：连续 ACK 间隔小于 `delay_min + hystart_ack_delay`，说明 pacing 延迟增加
- **Delay 检测**（行 240）：`curr_rtt > delay_min + threshold`，说明队列积压

两种条件任一满足即退出慢启动，将 `ssthresh = cwnd`，避免丢包。

### 8.4 CA 状态枚举

```c
TCP_CA_Open = 0       // 正常
TCP_CA_Disorder       // 检测到重复 ACK，但未确认丢包
TCP_CA_CWR            // 正在减小窗口（收到 ECN Echo 或快速重传）
TCP_CA_Recovery       // 处于快速恢复中
TCP_CA_Loss           // 超时导致的丢包
```

---

## 9. 关键函数关系图

```
ACK 到达
  │
  ▼
tcp_rcv_acks() [TCP 核心]
  │
  ▼
icsk->icsk_ca_ops->cong_avoid()
  │
  ├─ tcp_reno_cong_avoid()
  │     ├─ tcp_in_slow_start() → tcp_slow_start()
  │     └─ tcp_cong_avoid_ai()
  │
  └─ cubictcp_cong_avoid()
        ├─ tcp_in_slow_start() → tcp_slow_start()
        └─ bictcp_update() → tcp_cong_avoid_ai()

丢包 / ECN
  │
  ▼
tcp_enter_cwr() / tcp_fastretrans_alert()
  │
  ▼
icsk->icsk_ca_ops->ssthresh()  ← 计算新 ssthresh
  │
  ▼
icsk->icsk_ca_ops->set_state() ← 通知算法状态变化
  │
  ▼
icsk->icsk_ca_ops->undo_cwnd() ← 必要时撤销
```

---

## 10. 总结

| 组件 | 核心职责 |
|------|----------|
| `struct tcp_congestion_ops` | 统一接口定义，支持 `cong_avoid`（经典）或 `cong_control`（自定义）两种工作模式 |
| `tcp_cong_list` | 全局算法链表，通过 `register/unregister` 动态增删 |
| `tcp_init_congestion_control` | socket 创建后初始化算法，调用 `init` 回调并处理 ECN |
| `snd_cwnd` / `snd_ssthresh` | 核心控制变量：cwnd 是发送窗口上限，ssthresh 是慢启动/拥塞避免分界线 |
| `tcp_slow_start` | 慢启动：每个 ACK cwnd + 1 MSS，受 ssthresh 上限约束 |
| `tcp_cong_avoid_ai` | 拥塞避免线性增长：每累计 `cnt` 个 ACK cwnd + 1 |
| Reno | 标准 AIMD：丢包后 ssthresh = cwnd / 2，cwnd 可回退到 1 |
| CUBIC | 使用 cubic 函数，在高带宽-延迟积网络中比 Reno 更aggressive；含 HyStart delay-based 提前退出慢启动 |
| Hybla | 通过 `rho = RTT/RTT0` 比例因子，在高 RTT 链路上等效加速增长 |

Linux 的可插拔设计使新算法（如 BBR）无需改动核心 TCP 栈，只需实现 `tcp_congestion_ops` 并注册即可。这套框架自 2.6 引入以来，持续演进，是 Linux TCP 协议栈最具扩展性的子系统之一。
