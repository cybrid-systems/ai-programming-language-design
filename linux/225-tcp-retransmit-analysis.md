# TCP 超时重传机制分析 (tcp_retransmit)

> 基于 Linux 7.0-rc1 源码，文件：`net/ipv4/tcp_timer.c`、`net/ipv4/tcp_output.c`、`net/ipv4/tcp_input.c`

---

## 1. 概述

TCP 超时重传（Retransmission Timeout，RTO）是 TCP 可靠性保证的核心机制。当发送的 segment 在约定期限内未收到 ACK，TCP 假设该 segment 丢失或被严重延迟，触发重传。Linux 内核将这一定时器称为 `tcp_retransmit_timer`，实现于 `net/ipv4/tcp_timer.c`。

---

## 2. tcp_retransmit_timer 定时器

### 2.1 定时器初始化

定时器在连接建立时通过 `timer_setup()` 注册（第 725 行，`inet_connection_sock.c`）：

```c
// net/ipv4/inet_connection_sock.c:725
timer_setup(&sk->tcp_retransmit_timer, retransmit_handler, 0);
```

实际的超时逻辑由 `tcp_write_timer_handler()` 统一分发（第 699 行，`tcp_timer.c`），根据 `icsk->icsk_pending` 的事件类型调用不同处理函数：

```c
// net/ipv4/tcp_timer.c:709-723
event = icsk->icsk_pending;
switch (event) {
case ICSK_TIME_REO_TIMEOUT:
    tcp_rack_reo_timeout(sk);
    break;
case ICSK_TIME_LOSS_PROBE:
    tcp_send_loss_probe(sk);
    break;
case ICSK_TIME_RETRANS:
    smp_store_release(&icsk->icsk_pending, 0);
    tcp_retransmit_timer(sk);   // ← 超时重传入口
    break;
case ICSK_TIME_PROBE0:
    smp_store_release(&icsk->icsk_pending, 0);
    tcp_probe_timer(sk);
    break;
}
```

### 2.2 tcp_retransmit_timer 主体逻辑

入口函数（第 534 行）：

```c
// net/ipv4/tcp_timer.c:534
void tcp_retransmit_timer(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct inet_connection_sock *icsk = inet_csk(sk);
    struct sk_buff *skb;

    // Fast Open 情况：重传 SYN-ACK
    req = rcu_dereference_protected(tp->fastopen_rsk, ...);
    if (req) {
        tcp_fastopen_synack_timer(sk, req);
        return;
    }

    if (!tp->packets_out)   // 没有发出且未确认的包，直接返回
        return;

    skb = tcp_rtx_queue_head(sk);  // 获取重传队列头
```

#### 2.2.1 零窗口探测（Zero-Window Probing）

当对端窗口收缩为 0 时（第 580-592 行），发送端不能直接超时断开连接，而是进入特殊的"零窗口探测"路径：

```c
// tcp_timer.c:579-600
if (!tp->snd_wnd && !sock_flag(sk, SOCK_DEAD) &&
    !((1 << sk->sk_state) & (TCPF_SYN_SENT | TCPF_SYN_RECV))) {
    // 接收端可恶地缩小窗口，我们的重传变成零探测
    if (tcp_rtx_probe0_timed_out(sk, skb, rtx_delta)) {
        tcp_write_err(sk);
        goto out;
    }
    tcp_enter_loss(sk);
    tcp_retransmit_skb(sk, skb, 1);
    __sk_dst_reset(sk);
    goto out_reset_timer;
}
```

零窗口探测使用 `tcp_rtx_probe0_timed_out()` 判断超时（第 493 行），超时值为 `tcp_rto_max(sk) * 2`（120 秒的 2 倍 = 240 秒）或用户指定的 `TCP_USER_TIMEOUT`。

#### 2.2.2 普通 RTO 超时

无零窗口情况时（第 607 行起）：

```c
// tcp_timer.c:607-627
__NET_INC_STATS(sock_net(sk), LINUX_MIB_TCPTIMEOUTS);
if (tcp_write_timeout(sk))      // 超过最大重传次数则终止连接
    goto out;

// 更新 MIB 统计（按 CA 状态区分失败类型）
if (icsk->icsk_retransmits == 0) { ... }

// 进入 Loss 状态
tcp_enter_loss(sk);

// 更新 RTO 相关统计
tcp_update_rto_stats(sk);

// 重传重传队列头部的 segment
if (tcp_retransmit_skb(sk, tcp_rtx_queue_head(sk), 1) > 0) {
    // 本地拥塞导致重传失败，启用保守的资源探测间隔
    tcp_reset_xmit_timer(sk, ICSK_TIME_RETRANS,
                 TCP_RESOURCE_PROBE_INTERVAL, false);
    goto out;
}
```

`tcp_update_rto_stats()`（第 445 行）增加 `total_rto` 计数并递增 `icsk_retransmits`：

```c
// tcp_timer.c:445
static void tcp_update_rto_stats(struct sock *sk)
{
    struct inet_connection_sock *icsk = inet_csk(sk);
    struct tcp_sock *tp = tcp_sk(sk);
    if (!icsk->icsk_retransmits)
        tp->total_rto_recoveries++;
    WRITE_ONCE(icsk->icsk_retransmits, icsk->icsk_retransmits + 1);
    tp->total_rto++;
}
```

---

## 3. RTO 计算

### 3.1 RTT 采样与 RTO 初始化

RTO 计算遵循 RFC 6298。初始 RTO 定义在 `include/net/tcp.h` 第 167 行：

```c
#define TCP_TIMEOUT_INIT    ((unsigned)(1*HZ))   // 1 秒
#define TCP_TIMEOUT_FALLBACK ((unsigned)(3*HZ)) // 3 秒（无 RTT 采样时的回退）
#define TCP_RTO_MAX         ((unsigned)(120*HZ)) // 120 秒上限
#define TCP_RTO_MIN         ((unsigned)(HZ/5))   // 200 ms 下限
```

连接建立阶段，`icsk_rto` 通过 `tcp_set_rto()`（第 1175 行，`tcp_input.c`）根据 SRTT 和 RTTVAR 初始化：

```c
// include/net/tcp.h:883
static inline u32 __tcp_set_rto(const struct tcp_sock *tp)
{
    return usecs_to_jiffies((tp->srtt_us >> 3) + tp->rttvar_us);
}
```

即 RTO = SRTT + 2 × RTTVAR（Jacobson 算法）。`tcp_bound_rto()` 将 RTO 限制在 `[TCP_RTO_MIN, tcp_rto_max(sk)]` 范围内。

### 3.2 拥塞控制相关的 ssthresh 与 cwnd

进入 Loss 状态后，`tcp_enter_loss()`（第 2554 行，`tcp_input.c`）立即调整拥塞窗口：

```c
// tcp_input.c:2568-2573
if (icsk->icsk_ca_state <= TCP_CA_Disorder ||
    !after(tp->high_seq, tp->snd_una) ||
    (icsk->icsk_ca_state == TCP_CA_Loss && !icsk->icsk_retransmits)) {
    tp->prior_ssthresh = tcp_current_ssthresh(sk);
    tp->prior_cwnd = tcp_snd_cwnd(tp);
    WRITE_ONCE(tp->snd_ssthresh, icsk->icsk_ca_ops->ssthresh(sk));
    tcp_ca_event(sk, CA_EVENT_LOSS);
    tcp_init_undo(tp);
}
tcp_snd_cwnd_set(tp, tcp_packets_in_flight(tp) + 1);  // cwnd = in_flight + 1
```

这对应标准拥塞控制：ssthresh 被更新（通常是 `cwnd / 2`），cwnd 降为 1 个 segment（TCP Reno/Loss 场景）。

---

## 4. 指数退避（Exponential Backoff）

每次 RTO 超时触发重传后，`icsk_rto` 执行指数退避（第 680-681 行）：

```c
// tcp_timer.c:676-683
if (sk->sk_state == TCP_ESTABLISHED &&
    (tp->thin_lto || READ_ONCE(net->ipv4.sysctl_tcp_thin_linear_timeouts)) &&
    tcp_stream_is_thin(tp) &&
    icsk->icsk_retransmits <= TCP_THIN_LINEAR_RETRIES) {
    // 细流（thin stream）使用线性退避
    icsk->icsk_backoff = 0;
    icsk->icsk_rto = clamp(__tcp_set_rto(tp), tcp_rto_min(sk), tcp_rto_max(sk));
} else if (sk->sk_state != TCP_SYN_SENT ||
           tp->total_rto > READ_ONCE(net->ipv4.sysctl_tcp_syn_linear_timeouts)) {
    // 一般情况：指数退避
    icsk->icsk_backoff++;
    icsk->icsk_rto = min(icsk->icsk_rto << 1, tcp_rto_max(sk));
}
```

关键点：
- **`icsk_backoff`**：退避阶数（0 开始），每次超时递增
- **`icsk_rto <<= 1`**：每次加倍，上限 120 秒（TCP_RTO_MAX）
- **细流保护**：对于数据量小、间隔短的连接（前 `TCP_THIN_LINEAR_RETRIES` 次），保持线性退避以避免过度延迟
- **SYN_SENT 状态**：`tcp_syn_linear_timeouts` 控制 SYN 段的线性退避范围

定时器重置（第 684-688 行）：

```c
tcp_reset_xmit_timer(sk, ICSK_TIME_RETRANS,
             tcp_clamp_rto_to_user_timeout(sk), false);
```

`tcp_clamp_rto_to_user_timeout()` 确保 RTO 不超过用户指定的 `TCP_USER_TIMEOUT`。

---

## 5. tcp_retransmit_skb 路径

### 5.1 函数层级

```
tcp_retransmit_timer()
  └─> tcp_retransmit_skb()         // net/ipv4/tcp_output.c:3696
        └─> __tcp_retransmit_skb() // net/ipv4/tcp_output.c:3548
              └─> tcp_transmit_skb()
```

### 5.2 tcp_retransmit_skb（对外接口）

第 3696 行：

```c
// net/ipv4/tcp_output.c:3696
int tcp_retransmit_skb(struct sock *sk, struct sk_buff *skb, int segs)
{
    struct tcp_sock *tp = tcp_sk(sk);
    int err = __tcp_retransmit_skb(sk, skb, segs);

    if (err == 0) {
        TCP_SKB_CB(skb)->sacked |= TCPCB_RETRANS;
        tp->retrans_out += tcp_skb_pcount(skb);
    }
    if (!tp->retrans_stamp)
        tp->retrans_stamp = tcp_skb_timestamp_ts(tp->tcp_usec_ts, skb);
    if (tp->undo_retrans < 0)
        tp->undo_retrans = 0;
    tp->undo_retrans += tcp_skb_pcount(skb);
    return err;
}
```

关键操作：
- 标记 `TCPCB_RETRANS` 标志
- 更新 `retrans_out`（正在重传的包数）
- 记录首次重传时间戳 `retrans_stamp`
- 增加 `undo_retrans`（用于 SACK undo）

### 5.3 __tcp_retransmit_skb（核心实现）

第 3548 行起，`__tcp_retransmit_skb()` 执行实际的重传逻辑：

```c
// tcp_output.c:3548
int __tcp_retransmit_skb(struct sock *sk, struct sk_buff *skb, int segs)
{
    struct inet_connection_sock *icsk = inet_csk(sk);
    struct tcp_sock *tp = tcp_sk(sk);
    unsigned int cur_mss;
    int diff, len, err;
    int avail_wnd;

    // 清除 MTU 探测状态
    if (icsk->icsk_mtup.probe_size)
        icsk->icsk_mtup.probe_size = 0;

    // 检查 skb 是否仍在主机队列中
    if (skb_still_in_host_queue(sk, skb)) {
        err = -EBUSY;
        goto out;
    }

start:
    // 如果 skb 的序列号已被完全确认（< snd_una），裁剪头部
    if (before(TCP_SKB_CB(skb)->seq, tp->snd_una)) {
        if (unlikely(TCP_SKB_CB(skb)->tcp_flags & TCPHDR_SYN)) {
            TCP_SKB_CB(skb)->tcp_flags &= ~TCPHDR_SYN;
            TCP_SKB_CB(skb)->seq++;
        }
        if (tcp_trim_head(sk, skb, tp->snd_una - TCP_SKB_CB(skb)->seq))
            goto out;
    }
```

#### 5.3.1 窗口检查与分段

```c
// tcp_output.c:3588
    cur_mss = tcp_current_mss(sk);
    avail_wnd = tcp_wnd_end(tp) - TCP_SKB_CB(skb)->seq;

    // 接收端缩小窗口时，若序列号不在新窗口内则不重传
    if (avail_wnd <= 0) {
        if (TCP_SKB_CB(skb)->seq != tp->snd_una) {
            err = -EAGAIN;
            goto out;
        }
        avail_wnd = cur_mss;  // 零窗口探测：允许发送一个 segment
    }

    len = cur_mss * segs;
    if (len > avail_wnd) {
        len = rounddown(avail_wnd, cur_mss);
        if (!len)
            len = avail_wnd;
    }
```

#### 5.3.2 SKB 分割（Fragmentation）

```c
// tcp_output.c:3618
    if (skb->len > len) {
        // 需要分割 skb（例如 TSO 大包超出窗口限制）
        if (tcp_fragment(sk, TCP_FRAG_IN_RTX_QUEUE, skb, len,
                 cur_mss, GFP_ATOMIC)) {
            err = -ENOMEM;
            goto out;
        }
    }
```

#### 5.3.3 ECN 处理

```c
// tcp_output.c:3641
    if (!tcp_ecn_mode_pending(tp) || icsk->icsk_retransmits > 1) {
        // 非 ECN 模式或第二次重传后：清除 ECN 标记
        if ((TCP_SKB_CB(skb)->tcp_flags & TCPHDR_SYN_ECN) ==
            TCPHDR_SYN_ECN)
            tcp_ecn_clear_syn(sk, skb);
    }
```

#### 5.3.4 发送与统计

```c
// tcp_output.c:3656-3678
    segs = tcp_skb_pcount(skb);
    TCP_ADD_STATS(sock_net(sk), TCP_MIB_RETRANSSEGS, segs);
    if (TCP_SKB_CB(skb)->tcp_flags & TCPHDR_SYN)
        __NET_INC_STATS(sock_net(sk), LINUX_MIB_TCPSYNRETRANS);
    WRITE_ONCE(tp->total_retrans, tp->total_retrans + segs);
    WRITE_ONCE(tp->bytes_retrans, tp->bytes_retrans + skb->len);

    // 低对齐或头部空间不足时使用 __pskb_copy 克隆
    if (unlikely((NET_IP_ALIGN && ((unsigned long)skb->data & 3)) ||
             skb_headroom(skb) >= 0xFFFF)) {
        tcp_skb_tsorted_save(skb) {
            nskb = __pskb_copy(skb, MAX_TCP_HEADER, GFP_ATOMIC);
            if (nskb) {
                nskb->dev = NULL;
                err = tcp_transmit_skb(sk, nskb, 0, GFP_ATOMIC);
            } else {
                err = -ENOBUFS;
            }
        } tcp_skb_tsorted_restore(skb);

        if (!err) {
            tcp_update_skb_after_send(sk, skb, tp->tcp_wstamp_ns);
            tcp_rate_skb_sent(sk, skb);
        }
    } else {
        err = tcp_transmit_skb(sk, skb, 1, GFP_ATOMIC);
    }

    // BPF 重传回调
    if (BPF_SOCK_OPS_TEST_FLAG(tp, BPF_SOCK_OPS_RETRANS_CB_FLAG))
        tcp_call_bpf_3arg(sk, BPF_SOCK_OPS_RETRANS_CB,
                  TCP_SKB_CB(skb)->seq, segs, err);
```

### 5.4 tcp_xmit_retransmit_queue（批量重传）

第 3723 行，`tcp_xmit_retransmit_timer()` 在一次 RTO 触发后尝试重传更多包（不仅仅是队头）：

```c
// tcp_output.c:3723
void tcp_xmit_retransmit_queue(struct sock *sk)
{
    const struct inet_connection_sock *icsk = inet_csk(sk);
    struct sk_buff *skb, *rtx_head, *hole = NULL;
    struct tcp_sock *tp = tcp_sk(sk);
    bool rearm_timer = false;
    u32 max_segs;
    int mib_idx;

    if (!tp->packets_out) return;

    rtx_head = tcp_rtx_queue_head(sk);
    skb = tp->retransmit_skb_hint ?: rtx_head;
    max_segs = tcp_tso_segs(sk, tcp_current_mss(sk));

    skb_rbtree_walk_from(skb) {
        if (tcp_pacing_check(sk)) break;
        if (!hole) tp->retransmit_skb_hint = skb;

        segs = tcp_snd_cwnd(tp) - tcp_packets_in_flight(tp);
        if (segs <= 0) break;
        segs = min_t(int, segs, max_segs);

        if (tp->retrans_out >= tp->lost_out) {
            break;  // 已重传的包数 >= 已确认的丢失包，停止
        } else if (!(sacked & TCPCB_LOST)) {
            if (!hole && !(sacked & (TCPCB_SACKED_RETRANS|TCPCB_SACKED_ACKED)))
                hole = skb;  // 记录第一个"洞"（未丢失也未被 SACK 的包）
            continue;
        } else {
            // 标记为丢失的包，执行重传
            if (icsk->icsk_ca_state != TCP_CA_Loss)
                mib_idx = LINUX_MIB_TCPFASTRETRANS;
            else
                mib_idx = LINUX_MIB_TCPSLOWSTARTRETRANS;
        }

        if (sacked & (TCPCB_SACKED_ACKED|TCPCB_SACKED_RETRANS))
            continue;

        if (tcp_retransmit_skb(sk, skb, segs)) break;

        NET_ADD_STATS(sock_net(sk), mib_idx, tcp_skb_pcount(skb));
        if (tcp_in_cwnd_reduction(sk))
            tp->prr_out += tcp_skb_pcount(skb);

        if (skb == rtx_head)
            rearm_timer = true;
    }

    if (rearm_timer)
        tcp_reset_xmit_timer(sk, ICSK_TIME_RETRANS,
                 inet_csk(sk)->icsk_rto, true);
}
```

核心策略：
- **`retrans_out >= lost_out`**：如果已重传包数已追上丢失包数，停止继续重传
- **hole 指针**：找到第一个未确定丢失的包，作为后续重传起点
- **cwnd 限制**：每次重传量受 `snd_cwnd - in_flight` 限制

---

## 6. tcp_write_wakeup → tcp_retransmit_skb

`tcp_write_wakeup()`（第 4552 行）用于在定时器到期前主动发送数据/窗口探测，唤醒对端产生 ACK：

```c
// tcp_output.c:4552
int tcp_write_wakeup(struct sock *sk, int mib)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *skb;

    if (sk->sk_state == TCP_CLOSE)
        return -1;

    skb = tcp_send_head(sk);
    if (skb && before(TCP_SKB_CB(skb)->seq, tcp_wnd_end(tp))) {
        int err;
        unsigned int mss = tcp_current_mss(sk);
        unsigned int seg_size = tcp_wnd_end(tp) - TCP_SKB_CB(skb)->seq;

        // 发送头部的 data segment（打上 PSH 标志）
        if (seg_size < TCP_SKB_CB(skb)->end_seq - TCP_SKB_CB(skb)->seq ||
            skb->len > mss) {
            seg_size = min(seg_size, mss);
            TCP_SKB_CB(skb)->tcp_flags |= TCPHDR_PSH;
            if (tcp_fragment(sk, TCP_FRAG_IN_WRITE_QUEUE, skb,
                     seg_size, mss, GFP_ATOMIC))
                return -1;
        } else if (!tcp_skb_pcount(skb))
            tcp_set_skb_tso_segs(skb, mss);

        TCP_SKB_CB(skb)->tcp_flags |= TCPHDR_PSH;
        err = tcp_transmit_skb(sk, skb, 1, GFP_ATOMIC);
        if (!err)
            tcp_event_new_data_sent(sk, skb);
        return err;
    } else {
        // 无数据可发，发送窗口探测包（probe）
        if (between(tp->snd_up, tp->snd_una + 1, tp->snd_una + 0xFFFF))
            tcp_xmit_probe_skb(sk, 1, mib);  // 带 urgent ptr 的探测
        return tcp_xmit_probe_skb(sk, 0, mib);  // 普通窗口探测
    }
}
```

`tcp_write_wakeup()` 内部直接调用 `tcp_transmit_skb()`（不经过 `tcp_retransmit_skb()`），是独立的发送路径，不经过重传队列标记逻辑。

---

## 7. SACK 下的重传与丢失标记

### 7.1 关键数据结构

TCP 连接维护三个核心计数器（定义在 `tcp_sock` 中）：

| 字段 | 含义 |
|------|------|
| `sacked_out` | 被 SACK 确认的包数 |
| `lost_out` | 标记为网络丢失的包数 |
| `retrans_out` | 正在重传的包数 |

### 7.2 tcp_sacktag_one — SACK 标记的核心

第 1612 行，`tcp_sacktag_one()` 处理每个 SACK 块，对包进行分类：

```c
// tcp_input.c:1612
static u8 tcp_sacktag_one(struct sock *sk,
              struct tcp_sacktag_state *state, u8 sacked,
              u32 start_seq, u32 end_seq,
              int dup_sack, int pcount, u32 plen, u64 xmit_time)
{
    struct tcp_sock *tp = tcp_sk(sk);

    // D-SACK 处理：如果是重传包被 D-SACK，清除 retrans 标记
    if (dup_sack && (sacked & TCPCB_RETRANS)) {
        if (tp->undo_marker && tp->undo_retrans > 0 &&
            after(end_seq, tp->undo_marker))
            tp->undo_retrans = max_t(int, 0, tp->undo_retrans - pcount);
    }

    if (!after(end_seq, tp->snd_una))
        return sacked;  // 无新数据确认，跳过

    if (!(sacked & TCPCB_SACKED_ACKED)) {
        tcp_rack_advance(tp, sacked, end_seq, xmit_time);

        if (sacked & TCPCB_SACKED_RETRANS) {
            // 已被 SACK 标记为"重传中"的包
            if (sacked & TCPCB_LOST) {
                // L|R 状态：从 LOST 和 SACKED_RETRANS 中清除
                sacked &= ~(TCPCB_LOST|TCPCB_SACKED_RETRANS);
                tp->lost_out -= pcount;
                tp->retrans_out -= pcount;
            }
        } else {
            // 未标记为重传的包（可能是新数据或丢失）
            if (!(sacked & TCPCB_RETRANS)) {
                // 新包在"洞"中被 SACK → 发生了重排（reordering）
                if (before(start_seq, tcp_highest_sack_seq(tp)) &&
                    before(start_seq, state->reord))
                    state->reord = start_seq;
                // ...
            }
            if (sacked & TCPCB_LOST) {
                // L 状态：丢失包被确认，从 lost_out 中移除
                sacked &= ~TCPCB_LOST;
                tp->lost_out -= pcount;
            }
        }

        sacked |= TCPCB_SACKED_ACKED;
        tp->sacked_out += pcount;
        // ...
    }
```

### 7.3 丢失检测路径

在 `tcp_fastretrans_alert()`（进入 Disorder/Recovery/Loss 状态后的快路径）中，Linux 使用两种丢失检测策略：

1. **RENO 风格**：三个重复 ACK 后标记丢失（`tcp_mark_skb_lost()`）
2. **SACK 风格**：进入 Loss 状态后重新扫描重传队列，对超出 `high_seq` 的包全部标记为丢失

第 2495 行（`tcp_enter_loss()` 触发的重置）：

```c
// tcp_input.c:2495
tp->sacked_out = 0;
tp->lost_out = 0;
// ...
tp->retrans_out = 0;
```

### 7.4 重传中包的 SACK 处理

第 1682 行，D-SACK 对"已重传且被确认"的包取消 retrans 标记：

```c
// tcp_input.c:1682
if (dup_sack && (sacked & TCPCB_SACKED_RETRANS)) {
    sacked &= ~TCPCB_SACKED_RETRANS;
    tp->retrans_out -= tcp_skb_pcount(skb);
    // undo_retrans 在 tcp_sacktag_one() 中已处理
}
```

---

## 8. Tail Loss Probe (TLP)

TLP 是一种优化机制，在有未确认数据且连接处于 Open/Disorder 状态时，发送一个尾部探测包，期望在 RTO 之前触发 SACK 或重复 ACK，从而避免等待完整 RTO。

### 8.1 探测触发条件

`tcp_schedule_loss_probe()` 决定是否发送 TLP（由 `tcp_set_xmit_timer()` 调用）：

```c
// tcp_timer.c:702
if (!tcp_sk(sk)->packets_out || !tcp_schedule_loss_probe(sk, true))
    tcp_rearm_rto(sk);
```

### 8.2 tcp_send_loss_probe 实现

第 3168 行：

```c
// net/ipv4/tcp_output.c:3168
void tcp_send_loss_probe(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *skb;
    int pcount;
    int mss = tcp_current_mss(sk);

    // 最多一个 TLP 在飞行中
    if (tp->tlp_high_seq)
        goto rearm_timer;

    tp->tlp_retrans = 0;

    // 优先发送 send_head（在窗口范围内）
    skb = tcp_send_head(sk);
    if (skb && tcp_snd_wnd_test(tp, skb, mss)) {
        pcount = tp->packets_out;
        tcp_write_xmit(sk, mss, TCP_NAGLE_OFF, 2, GFP_ATOMIC);
        if (tp->packets_out > pcount)
            goto probe_sent;
        goto rearm_timer;
    }

    // 否则重传 rtx 队列尾部最后一个包（尾部探测）
    skb = skb_rb_last(&sk->tcp_rtx_queue);
    if (unlikely(!skb)) {
        tcp_warn_once(sk, tp->packets_out, "invalid inflight: ");
        smp_store_release(&inet_csk(sk)->icsk_pending, 0);
        return;
    }

    if (skb_still_in_host_queue(sk, skb))
        goto rearm_timer;

    pcount = tcp_skb_pcount(skb);
    if (WARN_ON(!pcount))
        goto rearm_timer;

    // 如果 TSO 包超过一个 segment，先分割
    if ((pcount > 1) && (skb->len > (pcount - 1) * mss)) {
        if (unlikely(tcp_fragment(sk, TCP_FRAG_IN_RTX_QUEUE, skb,
                      (pcount - 1) * mss, mss, GFP_ATOMIC)))
            goto rearm_timer;
        skb = skb_rb_next(skb);
    }

    if (WARN_ON(!skb || !tcp_skb_pcount(skb)))
        goto rearm_timer;

    // 执行尾部探测重传
    if (__tcp_retransmit_skb(sk, skb, 1))
        goto rearm_timer;

    tp->tlp_retrans = 1;

probe_sent:
    // 记录探测序列号，用于丢失判断
    tp->tlp_high_seq = tp->snd_nxt;

    NET_INC_STATS(sock_net(sk), LINUX_MIB_TCPLOSSPROBES);
    smp_store_release(&inet_csk(sk)->icsk_pending, 0);
rearm_timer:
    tcp_rearm_rto(sk);
}
```

关键设计：
- **`tlp_high_seq`**：记录探测发送时的 `snd_nxt`，如果后续 ACK 未到达（超时），判断为真丢失
- **尾部探测优先**：探测 `tcp_rtx_queue` 的最后一个 skb（最老的未确认数据），最大化探测效果
- **发送成功后重置定时器**：调用 `tcp_rearm_rto()` 而非 `tcp_reset_xmit_timer`，从当前时间重新开始 RTO 计时

### 8.3 TLP 与普通 RTO 的区别

| | TLP | 普通 RTO |
|---|---|---|
| 触发时机 | 提前探测（loss 状态前） | 等待完整 RTO 超时 |
| 探测包 | 1 个 segment | 重传队列头（可能有多个） |
| 进入状态 | 不进入 Loss | `tcp_enter_loss()` |
| cwnd 影响 | 可能触发拥塞控制 | 拥塞控制立即生效 |

---

## 9. MSS 与 RTO 的交互

### 9.1 MSS 计算路径

```
tcp_current_mss(sk)   // tcp_output.c:2102
  └─> tp->mss_cache   // 初始值来自 tcp_sync_mss()
  └─> dst_mtu(dst)    // 检查 PMTU 是否变化
  └─> tcp_established_options() // 减去选项头部长度（TS/SACK 等）
```

`tcp_mss_to_mtu()`（第 2028 行）将 MSS 转换为 MTU：

```c
// tcp_output.c:2028
int tcp_mss_to_mtu(struct sock *sk, int mss)
{
    const struct tcp_sock *tp = tcp_sk(sk);
    const struct inet_connection_sock *icsk = inet_csk(sk);
    return mss +
          tp->tcp_header_len +
          icsk->icsk_ext_hdr_len +
          icsk->icsk_af_ops->net_header_len;
}
```

### 9.2 RTO 与 MSS 的关系

RTO 独立于 MSS 计算（基于 RTT 采样），但 MSS 影响：
- **可发送的数据量**：cwnd 以 segment 为单位，MSS 决定每个 segment 的有效负载
- **拥塞窗口实际大小**：`snd_cwnd * mss_cache` 等于拥塞窗口字节数
- **TLP 探测大小**：`tcp_send_loss_probe()` 使用 `tcp_current_mss(sk)` 作为探测 segment 大小

---

## 10. 定时器重置与 `tcp_rearm_rto`

`tcp_rearm_rto()`（第 3524 行，`tcp_input.c`）在收到有效 ACK 或每次发送后调用，重置 RTO 定时器：

```c
// tcp_input.c:3524
void tcp_rearm_rto(struct sock *sk)
{
    const struct inet_connection_sock *icsk = inet_csk(sk);
    struct tcp_sock *tp = tcp_sk(sk);

    if (rcu_access_pointer(tp->fastopen_rsk))
        return;  // Fast Open SYN-ACK 阶段不走普通 RTO

    if (!tp->packets_out) {
        inet_csk_clear_xmit_timer(sk, ICSK_TIME_RETRANS);
    } else {
        u32 rto = inet_csk(sk)->icsk_rto;
        // 如果当前有 RACK/LOSS_PROBE pending，计算 delta 补偿
        if (icsk->icsk_pending == ICSK_TIME_REO_TIMEOUT ||
            icsk->icsk_pending == ICSK_TIME_LOSS_PROBE) {
            s64 delta_us = tcp_rto_delta_us(sk);
            rto = usecs_to_jiffies(max_t(int, delta_us, 1));
        }
        tcp_reset_xmit_timer(sk, ICSK_TIME_RETRANS, rto, true);
    }
}
```

---

## 11. 完整重传流程图

```
应用 send()
  └─> tcp_write_xmit() — 发送数据，更新 snd_nxt
       └─> tcp_reset_xmit_timer() — 启动 RTO 定时器

RTO 到期（定时器触发）
  └─> tcp_write_timer_handler()
       └─> tcp_retransmit_timer()   ← 核心入口
            │
            ├─ Fast Open 路径：tcp_fastopen_synack_timer()
            │
            ├─ 零窗口探测路径：
            │    tcp_rtx_probe0_timed_out() → tcp_write_err() 或
            │    tcp_enter_loss() + tcp_retransmit_skb()
            │
            └─ 普通 RTO 路径：
                 tcp_write_timeout()    // 检查重传次数上限
                 tcp_enter_loss()      // 进入 Loss 状态，调整 cwnd/ssthresh
                 tcp_retransmit_skb()   // 重传 rtx 队头 segment
                 tcp_reset_xmit_timer() // 重设定时器（指数退避）

定时器重置时：
  tcp_rearm_rto() → tcp_reset_xmit_timer(ICSK_TIME_RETRANS, icsk_rto)

TLP（Loss Probe）路径：
  tcp_schedule_loss_probe() → tcp_send_loss_probe()
       └─> 发送 send_head 或 rtx 队列尾包
       └─> tp->tlp_high_seq = snd_nxt
       └─> tcp_rearm_rto() 重新开始 RTO 计时

SACK 处理路径：
  tcp_sacktag_one()  // 更新 sacked_out / lost_out / retrans_out
       └─> tcp_fastretrans_alert() // 状态机转换
       └─> tcp_xmit_retransmit_queue() // 批量重传丢失的包
```

---

## 12. 关键代码位置索引

| 函数/常量 | 文件:行号 |
|-----------|-----------|
| `tcp_retransmit_timer` | `tcp_timer.c:534` |
| `tcp_write_timer_handler` | `tcp_timer.c:699` |
| `tcp_write_timer` (timer callback) | `tcp_timer.c:731` |
| `tcp_retransmit_skb` | `tcp_output.c:3696` |
| `__tcp_retransmit_skb` | `tcp_output.c:3548` |
| `tcp_xmit_retransmit_queue` | `tcp_output.c:3723` |
| `tcp_write_wakeup` | `tcp_output.c:4552` |
| `tcp_send_probe0` | `tcp_output.c:4605` |
| `tcp_send_loss_probe` | `tcp_output.c:3168` |
| `tcp_enter_loss` | `tcp_input.c:2554` |
| `tcp_sacktag_one` | `tcp_input.c:1612` |
| `tcp_set_rto` | `tcp_input.c:1175` |
| `tcp_rearm_rto` | `tcp_input.c:3524` |
| `tcp_update_rto_stats` | `tcp_timer.c:445` |
| `tcp_rtx_probe0_timed_out` | `tcp_timer.c:493` |
| `TCP_RTO_MIN / TCP_RTO_MAX` | `tcp.h:163-164` |
| `__tcp_set_rto` | `tcp.h:883` |
| `tcp_rto_min / tcp_rto_max` | `tcp.h:873, 878` |