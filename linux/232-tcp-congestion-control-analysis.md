# tcp_congestion_control — TCP 拥塞控制框架与 CUBIC 算法深度分析

> 基于 Linux 7.0-rc1 源码，追踪 `tcp_cong.c` / `tcp_cubic.c` / `include/net/tcp.h`  
> 写作目标：打通逻辑链路，不做行号堆砌

## 1. 框架全景：struct tcp_congestion_ops

```ascii
                 ┌─────────────────────────────────────────┐
                 │      struct tcp_congestion_ops          │
                 │  (内核通过 icsk->icsk_ca_ops 指向当前算法) │
                 └─────────────────────────────────────────┘
                                    │
    ┌───────────────────────────────┼───────────────────────────────┐
    │  cong_avoid / cong_control   │  ssthresh / undo_cwnd          │
    │  (必须实现)                   │  (必须实现)                    │
    └───────────────────────────────┴───────────────────────────────┘
         │                                    │
    Reno 实现                              Reno 实现
    CUBIC 实现 ────────────────────────── CUBIC 实现

关键字段（tcp.h:1315）：
struct tcp_congestion_ops {
    void (*cong_avoid)(struct sock *sk, u32 ack, u32 acked);
    u32  (*ssthresh)(struct sock *sk);
    u32  (*undo_cwnd)(struct sock *sk);
    void (*set_state)(struct sock *sk, u8 new_state);
    void (*cwnd_event_tx_start)(struct sock *sk);
    void (*pkts_acked)(struct sock *sk, const struct ack_sample *sample);
    void (*init)(struct sock *sk);
    void (*release)(struct sock *sk);
    char name[TCP_CA_NAME_MAX];
    struct list_head list;        // 全局链表 tcp_cong_list
    u32 key;                      // jhash(算法名)
};
```

拥塞控制算法通过全局链表 `tcp_cong_list` 注册（`tcp_register_congestion_control`），socket 创建时通过 `tcp_assign_congestion_control` 按 name 或 key 查找绑定到 `icsk->icsk_ca_ops`。

## 2. 完整数据流：用户 send() → cwnd 更新

### 2.1 发送路径（宏观）

```
用户调用 send()
  │
  ▼
tcp_sendmsg()            [net/ipv4/tcp.c]
  │ 把用户数据分段为 skb，写入 write_queue
  │
  ▼
tcp_write_xmit()         [net/ipv4/tcp_output.c]
  │ 遍历 write_queue，尝试发送所有 cwnd 允许的包
  │ 关键判断：sk_forbid蹭蹭蹭_can_spk_can_send() && tcp_cwnd_網絡_ok()
  │                          tcp_pacing_ok()
  │                          tcp_snd_wnd_probe()
  │ 每次发送前：tcp_cwnd_limit_chain() → 最终调用
  │
  ▼
tcp_cwnd_limit()          [net/ipv4/tcp_output.c]
  │ 限制发送数量不超过 cwnd 和 pacing_rate
  │
  ▼
tcp_snd_cwnd()            [include/net/tcp.h:1508]
  │ 读取 tp->snd_cwnd
  │
  ▼
icsk->icsk_ca_ops->cong_avoid(sk, ack, acked)
  │
  ├── Reno:  tcp_reno_cong_avoid()   [tcp_cong.c:496]
  └── CUBIC: cubictcp_cong_avoid()   [tcp_cubic.c:321]
```

关键点：`tcp_write_xmit` 是真正发送的函数，它在每个 ACK 到来后被调用（通过 `tcp_release_cb` 回调链）。`cong_avoid` 并不直接发送数据——它只负责更新 `snd_cwnd`，为下次 `tcp_write_xmit` 的发送决策提供依据。

### 2.2 cwnd 检查点——tcp_is_cwnd_limited

`tcp_is_cwnd_limited` 判断当前是否受 cwnd 限制：

```c
// tcp.h:1593
static inline bool tcp_is_cwnd_limited(const struct sock *sk)
{
    return tcp_snd_cwnd(tp) < 2 * tp->max_packets_out;
}
```

在 `cubictcp_cong_avoid` 和 `tcp_reno_cong_avoid` 开头都有这个判断——**只有 cwnd 受限时才增长窗口**。当网络发生丢包或发送受其他限制时，这个条件为 false，cwnd 不更新。

### 2.3 cwnd 增长的两阶段

```
         cwnd
          ▲
          │   阶段一：SLOW START（指数增长）
          │   cwnd += acked（每个 ACK 加 1 MSS 或更多）
          │   条件：cwnd < snd_ssthresh
          │
          ├──────────────────────────────────────────────→ snd_ssthresh
          │   阶段二：CONGESTION AVOIDANCE（线性增长）
          │   每 RTT 加 1 MSS（通过 snd_cwnd_cnt 积分实现）
          │   条件：cwnd >= snd_ssthresh
          ▼
```

**慢启动中** `tcp_in_slow_start(tp)` 为 true，`tcp_slow_start` 处理 ACK 合并（RFC2581），返回剩余未处理的 acked 值。

**拥塞避免中** `tcp_cong_avoid_ai` 实现"每 RTT 增长 1"：用 `snd_cwnd_cnt` 积分，攒满 `w` 个 MSS（w = 当前 cwnd）才加 1。

## 3. CUBIC 核心逻辑：bictcp_update 完整追踪

### 3.1 公式回顾

$$W_{cubic}(t) = C \cdot (t - K)^3 + W_{max}$$

- $t$: 自当前 epoch 开始经过的时间
- $K$: 使得 $W_{cubic}(K) = W_{max}$ 的时间常数
- $W_{max}$: 丢包前的 cwnd（乘法减小的起点）

**为什么用立方？**  
线性增长（ Reno ）在 RTT 较长时太慢；指数增长太激进。立方函数在初始阶段近似指数快速增长，之后平滑地过渡到线性增长，保持在网络可用带宽附近震荡。物理直观：**像在公路上开车——先加速，发现拥堵（丢包）后减速，然后慢慢加速回去，找到一个稳定的最大 throughput**。

### 3.2 内核实现源码（tcp_cubic.c:211）

```c
static inline void bictcp_update(struct bictcp *ca, u32 cwnd, u32 acked)
{
    ca->ack_cnt += acked;

    // ── 防抖：1 jiffy 内最多更新一次 ──
    if (ca->last_cwnd == cwnd &&
        (s32)(tcp_jiffies32 - ca->last_time) <= HZ / 32)
        return;

    ca->last_cwnd = cwnd;
    ca->last_time = tcp_jiffies32;

    // ── 丢包后 epoch_start 会被重置为 0，此时重新初始化 epoch ──
    if (ca->epoch_start == 0) {
        ca->epoch_start = tcp_jiffies32;     // ← epoch 起点
        ca->ack_cnt = acked;
        ca->tcp_cwnd = cwnd;

        if (ca->last_max_cwnd <= cwnd) {
            // cwnd 已经超过历史最大值 → 线性模式，K=0
            ca->bic_K = 0;
            ca->bic_origin_point = cwnd;
        } else {
            // 计算 K: (Wmax-cwnd) * (srtt>>3/HZ) / c * 2^(3*BICTCP_HZ)
            ca->bic_K = cubic_root(cube_factor
                                   * (ca->last_max_cwnd - cwnd));
            ca->bic_origin_point = ca->last_max_cwnd;
        }
    }

    // ── 计算 t: (当前时间 - epoch_start)，单位转换为 bictcp_HZ ──
    t = (s32)(tcp_jiffies32 - ca->epoch_start);
    t += usecs_to_jiffies(ca->delay_min);   // ← RTT 补偿
    t <<= BICTCP_HZ;                         // × 2^10
    do_div(t, HZ);                           // ÷ HZ → 变为 bictcp_HZ 单位

    // ── 计算 (t-K) 和 abs(t-K) ──
    if (t < ca->bic_K)
        offs = ca->bic_K - t;
    else
        offs = t - ca->bic_K;

    // ── delta = c/rtt * (t-K)^3，移位防止溢出 ──
    delta = (cube_rtt_scale * offs * offs * offs)
            >> (10 + 3 * BICTCP_HZ);        // >> (10+3*10) = >> 40

    // ── W_cubic = origin_point ± delta ──
    if (t < ca->bic_K)
        bic_target = ca->bic_origin_point - delta;
    else
        bic_target = ca->bic_origin_point + delta;

    // ── 计算 cnt: cwnd 增长到 bic_target 需要的 ACK 次数 ──
    //    cnt = cwnd / (W_cubic - cwnd)，每次 ACK 增加 cwnd/cnt
    if (bic_target > cwnd) {
        ca->cnt = cwnd / (bic_target - cwnd);
    } else {
        ca->cnt = 100 * cwnd;               // 极小增量
    }

    // ── 初始增长限制：cwnd < 20 时最多 5%/RTT ──
    if (ca->last_max_cwnd == 0 && ca->cnt > 20)
        ca->cnt = 20;

tcp_friendliness:
    // ── TCP 友好性修正：确保 CUBIC 不比 Reno 慢 ──
    if (tcp_friendliness) {
        delta = (cwnd * beta_scale) >> 3;   // beta_scale = 8*(B+beta)/(3*(B-beta))
        while (ca->ack_cnt > delta) {      // Reno 每 RTT 加 1 MSS
            ca->ack_cnt -= delta;
            ca->tcp_cwnd++;
        }
        if (ca->tcp_cwnd > cwnd) {          // 如果 Reno 更快，限制 CUBIC 增速
            delta = ca->tcp_cwnd - cwnd;
            max_cnt = cwnd / delta;
            if (ca->cnt > max_cnt)
                ca->cnt = max_cnt;
        }
    }

    ca->cnt = max(ca->cnt, 2U);             // 上限：最多每 2 ACK 加 1
}
```

**t 和 K 的含义：**
- `t`: 自 epoch 开始经过的时间，以 `bictcp_HZ` (= 2^10 = 1024) 为单位
- `K`: 同样单位，使得在 $t=K$ 时 $W_{cubic} = W_{max}$（origin_point）
- `epoch_start`: 每次 MD（乘法减小）后重置为当前 jiffies，标志着新 epoch 开始

**cube_factor 的预计算逻辑（初始化时）：**
```c
beta_scale = 8*(BICTCP_BETA_SCALE+beta) / 3 / (BICTCP_BETA_SCALE - beta);
// 其中 beta = 717, BICTCP_BETA_SCALE = 1024
// beta_scale ≈ 8*(1024+717)/(3*(1024-717)) ≈ 14.5

cube_factor = 1ull << (10+3*BICTCP_HZ);     // 2^40
do_div(cube_factor, bic_scale * 10);        // 归一化
```

### 3.3 cnt 的作用

`cnt` 是 CUBIC 的"增长计数器"——在 `cubictcp_cong_avoid` 中通过 `tcp_cong_avoid_ai(tp, ca->cnt, acked)` 控制 cwnd 增长：

- `cnt` 大 → 每次 ACK 只增加微小量
- `cnt` 小 → 每次 ACK 增加较大量

当 `bic_target > cwnd` 时，`cnt = cwnd / (bic_target - cwnd)`，这意味着需要约 `bic_target - cwnd` 个 ACK 才能把 cwnd 从当前位置推到目标值。

## 4. 慢启动 → 拥塞避免转换：HyStart 和 ssthresh

### 4.1 HyStart 的两个检测机制

```ascii
慢启动阶段 (cwnd < ssthresh)
    │
    ├── HyStart ACK Train ─────────────────────────┐
    │  触发条件：                                   │
    │  now - ca->round_start > delay_min + ack_delay │
    │  原理：ACK 间隔突然变大 → 队列开始堆积         │
    │                                                   │
    └── HyStart Delay ─────────────────────────────┐
         触发条件：                                   │
         连续 HYSTART_MIN_SAMPLES(8) 个 RTT 样本      │
         curr_rtt > delay_min + (delay_min >> 3)      │
         原理：RTT 增大 → 缓冲区开始填充               │
                                                      │
         任一触发 → 设置 ssthresh = cwnd，立即进入 CA
```

代码路径：`cubictcp_acked()` → `hystart_update()` → `WRITE_ONCE(tp->snd_ssthresh, tcp_snd_cwnd(tp))`

注意：`hystart_low_window = 16` — cwnd 小于 16 时不检测，避免在初始慢启动阶段误触发。

### 4.2 ssthresh 计算：cubictcp_recalc_ssthresh

```c
static u32 cubictcp_recalc_ssthresh(struct sock *sk)
{
    const struct tcp_sock *tp = tcp_sk(sk);
    struct bictcp *ca = inet_csk_ca(sk);

    ca->epoch_start = 0;   // ← 强制 epoch 重新开始

    // ── Fast Convergence ──
    // 丢包后 cwnd < 上次 W_max → 更快收敛：W_max' = cwnd * (B+beta)/(2B)
    // 否则：W_max' = cwnd（即不用上次 W_max，用当前 cwnd）
    if (tcp_snd_cwnd(tp) < ca->last_max_cwnd && fast_convergence)
        ca->last_max_cwnd = (tcp_snd_cwnd(tp) * (BICTCP_BETA_SCALE + beta))
                            / (2 * BICTCP_BETA_SCALE);
    else
        ca->last_max_cwnd = tcp_snd_cwnd(tp);

    // ssthresh = beta * W_max = 717/1024 * W_max
    return max((tcp_snd_cwnd(tp) * beta) / BICTCP_BETA_SCALE, 2U);
}
```

**为什么 epoch_start = 0 很重要？**  
这强制下一次 `bictcp_update` 重新初始化 epoch，重新计算 K，进入新的 CUBIC 曲线。如果没有这个重置，立方函数会基于错误的时间基准计算目标窗口。

## 5. 乘法减小（MD）：丢包后的 cwnd 处理

### 5.1 ssthresh 和 cwnd 的变化

```
丢包发生（重传超时 或 DUP ACK）

    ↓ tcp_ca_retransmit_synack / tcp_enter_loss
    ↓ 调用 cubictcp_recalc_ssthresh()
    ↓ 调用 cubictcp_state(sk, TCP_CA_Loss)

ssthresh = beta * last_max_cwnd   (β ≈ 0.7)
cwnd     = ssthresh               (减半效果)

last_max_cwnd = cwnd 或 cwnd*(B+β)/(2B)   (Fast Convergence)
epoch_start = 0                          (新 epoch)
bic_K = 0 或 cubic_root(...)            (重新计算)
```

调用链（重传超时场景）：
```
tcp_retransmit_synack() → tcp_enter_loss() → tcp_update_congestion_control()
                              ↓
                         icsk->icsk_ca_ops->ssthresh(sk)
                              ↓
                         tcp_reno_ssthresh() 或 cubictcp_recalc_ssthresh()
```

### 5.2 tcp_reno_undo_cwnd（重传恢复时用）

```c
__bpf_kfunc u32 tcp_reno_undo_cwnd(struct sock *sk)
{
    const struct tcp_sock *tp = tcp_sk(sk);
    return max(tcp_snd_cwnd(tp), tp->prior_cwnd);  // 取 max
}
```

当 ECN 或其他机制撤销丢包判定时，使用 `undo_cwnd` 而非直接恢复——取当前 cwnd 和之前 cwnd 的最大值。

## 6. RTT 感知：delay_min 的作用

### 6.1 delay_min 的记录

在 `cubictcp_acked` 中每次 ACK 的 RTT 样本都会更新 `delay_min`：

```c
static void cubictcp_acked(struct sock *sk, const struct ack_sample *sample)
{
    struct bictcp *ca = inet_csk_ca(sk);
    u32 delay = sample->rtt_us;

    if (delay == 0) delay = 1;
    if (ca->delay_min == 0 || ca->delay_min > delay)
        ca->delay_min = delay;         // ← 跟踪最小 RTT
}
```

### 6.2 delay_min 如何进入 W_cubic 计算

```c
t = (s32)(tcp_jiffies32 - ca->epoch_start);
t += usecs_to_jiffies(ca->delay_min);   // ← 在 t 上加上 min RTT
t <<= BICTCP_HZ;
do_div(t, HZ);
```

这相当于在时间轴上减去最小 RTT，使得在不同 RTT 的网络中 CUBIC 曲线能自动调整增长速度。**长 RTT 网络中 t 的补偿更大，CUBIC 的增长更平缓**，与网络实际带宽延迟积匹配。

### 6.3 Hybla（历史算法，针对卫星网络）

Linux 曾包含 Hybla 算法（已移除），专门针对高 RTT（卫星网络）优化。其核心思路与 CUBIC 类似：通过 RTT 归一化使得增长速率与物理带宽延迟积匹配。Hybla 的公式：

$$W_{hybla}(t) = \frac{RTT_{ref}}{RTT} \cdot (2^{t/RTT} - 1) + W_{max}$$

即把 RTT 作为时间尺度的归一化因子，让高铁和公路的"速度"可比。

## 7. 拥塞控制状态 vs TCP 状态机

### 7.1 两个独立状态机

```ascii
TCP 状态机（sk_state）                 拥塞控制状态（icsk_ca_state）
─────────────────────────               ───────────────────────────────
TCP_CLOSE                             TCP_CA_Open
TCP_LISTEN                            TCP_CA_Disorder
TCP_SYN_SENT ──────────────────────►  TCP_CA_Early_Retrans
TCP_SYN_RECV                          TCP_CA_Loss
TCP_ESTABLISHED ──────────────────►  TCP_CA_CWR   ← 收到 ECN CE 或 dup ACK
TCP_FIN_WAIT1                         TCP_CA_Recovery
TCP_FIN_WAIT2                         TCP_CA_Disputed
TCP_CLOSING
TCP_TIME_WAIT
```

**它们是独立的。** `sk_state` 管理连接生命周期（建立、关闭）；`icsk_ca_state` 管理拥塞控制行为（增长/收缩/恢复）。

`set_state` 回调只在 CA 状态变化时被调用（`tcp_set_ca_state`）。最关键的是 `TCP_CA_Loss`——此时调用 `bictcp_reset` 清零状态，重新初始化 HyStart：

```c
static void cubictcp_state(struct sock *sk, u8 new_state)
{
    if (new_state == TCP_CA_Loss) {
        bictcp_reset(inet_csk_ca(sk));
        bictcp_hystart_reset(sk);
    }
}
```

### 7.2 ECN 协作（TCP_CA_CWR）

```c
void tcp_set_ca_state(struct sock *sk, const u8 ca_state)
{
    struct inet_connection_sock *icsk = inet_csk(sk);

    trace_tcp_cong_state_set(sk, ca_state);

    if (icsk->icsk_ca_ops->set_state)
        icsk->icsk_ca_ops->set_state(sk, ca_state);  // ← 回调
    icsk->icsk_ca_state = ca_state;
}
```

当网络在 ECN 模式下提前通知拥塞（CE 包），TCP 可以优雅地降低窗口而不丢包。`TCP_CA_CWR` 状态表示 sender 正在缩减窗口（CWnd Reduction）。

## 8. BIC-TCP → CUBIC 的演进

### 8.1 BIC-TCP 的设计

BIC-TCP（2002）在丢包后维护一个"二分查找"的目标窗口：
- 如果当前 cwnd < W_max：目标 → W_max
- 如果 cwnd > W_max：目标 → cwnd（线性增长）
- 接近 W_max 时用二分搜索避免剧烈振荡

### 8.2 CUBIC 的改进

```
BIC-TCP 的问题：                       CUBIC 的解决方案：
─────────────────────────────────     ──────────────────────────────────
二分搜索在窗口大时收敛慢                用立方函数直接计算，无迭代
对低 RTT 网络增长过慢                   立方函数在高带宽延迟积网络表现好
参数调优困难                            公式固定，超参少（仅 beta）
TCP 友好性不自然                        在公式外显式做 TCP 友好性修正
```

**为什么 Linux 最终选 CUBIC？**
1. **公式简单，计算快**：无二分搜索，只需一次 `cubic_root` + 几次移位
2. **超参少**：只需调 beta（默认 0.7），而 BIC 有多个敏感参数
3. **收敛性更好**：立方函数在所有带宽延迟积场景下都表现良好
4. **Linux 官方支持**：2006 年进入内核主线，取代了实验性的 BIC-TCP

## 9. 完整状态转换图

```ascii
                 ┌──────────────────────────────┐
                 │      连接建立 / socket 创建   │
                 └──────────────┬───────────────┘
                                │
                    tcp_assign_congestion_control()
                    icsk->icsk_ca_ops = &cubictcp
                                │
                                ▼
                 ┌──────────────────────────────┐
                 │  cubictcp_init()              │
                 │  bictcp_reset(ca)             │
                 │  bictcp_hystart_reset(sk)     │
                 └──────────────┬───────────────┘
                                │
               ┌────────────────┴────────────────┐
               ▼                                 ▼
    ┌──────────────────┐           ┌──────────────────────────┐
    │  SLOW START       │           │  Slow Start (hystart on) │
    │  cwnd = 1 MSS     │           │  HyStart 检测队列堆积    │
    │  指数增长         │           │  → 提前设置 ssthresh      │
    └──────┬───────────┘           └────────────┬─────────────┘
           │                                     │
           │  HyStart 或 cwnd >= ssthresh       │
           ▼                                     ▼
    ┌─────────────────────────────────────────────┐
    │  CONGESTION AVOIDANCE (CA)                  │
    │  bictcp_update() → cubictcp_cong_avoid()   │
    │  cwnd_cnt 积分，每 RTT +1 MSS（CUBIC 通过   │
    │  cnt 控制精确到每个 ACK 的增量）             │
    └─────────────────────┬─────────────────────┘
                          │
          ┌───────────────┴───────────────┐
          ▼                               ▼
   丢包检测 (RTO 或 dup ACK)         ECN CE 通知
          │                               │
          ▼                               ▼
   cubictcp_recalc_ssthresh()      tcp_set_ca_state(sk, TCP_CA_CWR)
   epoch_start = 0                 icsk->icsk_ca_state = CWR
   last_max_cwnd 保留/调整         cwnd = ssthresh
   cwnd = beta * W_max             epoch_start += delta
          │                        (tx_start 回调)
          ▼
   cubictcp_state(sk, TCP_CA_Loss)
   bictcp_reset(ca)
   bictcp_hystart_reset(sk)
          │
          ▼
   重传完成 或 SACK 恢复
          │
          ▼
   tcp_reno_undo_cwnd() 或 CA 回调
   → 返回 CA 阶段（继续 CA 增长）
```

## 10. 关键数据结构一览

```ascii
struct bictcp (tcp_cubic.c:86)
├── cnt              // 控制增长速率：每个 ACK 增加 cwnd/cnt
├── last_max_cwnd    // 上次丢包前的窗口（Fast Convergence 用）
├── last_cwnd        // 上次更新时的 cwnd（防抖）
├── last_time        // 上次更新时间（jiffies32）
├── bic_origin_point // CUBIC 公式的 origin = W_max
├── bic_K            // CUBIC 公式的 K 时间常数
├── delay_min        // 最小 RTT（微秒）
├── epoch_start      // 当前 epoch 开始时间
├── ack_cnt          // Reno 友好性计数
├── tcp_cwnd         // Reno 等效窗口（友好性修正用）
├── round_start      // HyStart: 本轮开始时间
├── last_ack         // HyStart: 上次 ACK 时间
├── curr_rtt         // HyStart: 当前 RTT 最小样本
└── found            // HyStart: 是否已找到切换点

struct tcp_sock (tcp.h 中)
├── snd_cwnd         // 当前拥塞窗口（MSS 为单位）
├── snd_ssthresh     // 慢启动阈值
├── snd_cwnd_cnt     // 拥塞避免增长积分器
├── snd_cwnd_clamp   // cwnd 上限
└── tcp_mstamp       // 微秒级时间戳（bictcp_clock_us 用）

struct tcp_congestion_ops (tcp.h:1315)
├── cong_avoid       // 窗口增长回调（Reno/CUBIC 实现）
├── ssthresh         // 返回慢启动阈值
├── undo_cwnd        // 丢包恢复时返回 undo 窗口值
├── set_state        // CA 状态变化回调
├── cwnd_event_tx_start  // 空闲后恢复发送回调
└── pkts_acked       // RTT 测量回调
```

## 11. 核心要点总结

| 问题 | 答案 |
|------|------|
| cwnd 在哪里被检查和更新？ | `tcp_write_xmit` 在发送决策时检查，`cong_avoid` 在 ACK 到达后更新 |
| CUBIC 公式在内核怎么落地？ | `bictcp_update` 中 `t` = jiffies 差值，`K` = `cubic_root(cube_factor * delta_cwnd)`，`W_cubic` = `origin_point ± delta` |
| 为什么是立方，不是线性？ | 立方在窗口大时有近似线性增长的优点，在窗口小时有指数快速增长的特点，带宽利用率高且稳定 |
| ssthresh 怎么算？ | Reno: `cwnd >> 1`；CUBIC: `beta * last_max_cwnd / 1024`，同时重置 epoch |
| RTT 怎么影响 CUBIC？ | `delay_min` 补偿 `t`，使时间轴归一化；长 RTT 网络增长更平缓 |
| 拥塞控制和 TCP 状态独立吗？ | 独立。两个状态机通过 `set_state` 回调交互 |
| BIC-TCP 为什么被 CUBIC 取代？ | CUBIC 计算更快（无二分），超参更少，收敛性更好 |


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

