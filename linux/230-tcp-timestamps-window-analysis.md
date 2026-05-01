# TCP 时间戳与窗口缩放：内核源码深度分析

> 基于 Linux 7.0-rc1 内核源码，分析 TCP 时间戳选项（tcp_timestamps）和窗口缩放（tcp_window_scaling）的实现细节。

---

## 1. TCP_TIMESTAMP 选项格式（TSval / TSecr）

### 选项结构

TCP 时间戳选项（RFC 1323）在内核中的定义为：

```c
// include/net/tcp.h:212-215
#define TCPOPT_TIMESTAMP     8   /* Better RTT estimations/PAWS */
#define TCPOLEN_TIMESTAMP    10  /* TSval(4) + TSecr(4) = 10 bytes */
```

选项编码为**两行 32-bit word**格式（避免 NOP 填充问题），实际占用 12 字节（TCPOLEN_TSTAMP_ALIGNED）：

```
+--------+--------+--------+--------+--------+--------+
|  NOP   |  NOP   |  Kind=8 | Len=10 |   TSval (4B)   |   ← 第1个 word
+--------+--------+--------+--------+--------+--------+
|                    TSecr (4B)                     |   ← 第2个 word
+--------+--------+--------+--------+--------+--------+
```

### 选项写入（tcp_options_write）

`tcp_output.c:658` 的 `tcp_options_write()` 将 `opts->tsval` 和 `opts->tsecr` 写入 TCP 头：

```c
// net/ipv4/tcp_output.c:683-697
if (likely(OPTION_TS & options)) {
    if (unlikely(OPTION_SACK_ADVERTISE & options)) {
        *ptr++ = htonl((TCPOPT_SACK_PERM << 24) |
                       (TCPOLEN_SACK << 16) |
                       (TCPOPT_TIMESTAMP << 8) |
                       TCPOLEN_TIMESTAMP);
        options &= ~OPTION_SACK_ADVERTISE;
    } else {
        *ptr++ = htonl((TCPOPT_NOP << 24) |
                       (TCPOPT_NOP << 16) |
                       (TCPOPT_TIMESTAMP << 8) |
                       TCPOLEN_TIMESTAMP);
    }
    *ptr++ = htonl(opts->tsval);   // TSval — 本端发送时的时间戳
    *ptr++ = htonl(opts->tsecr);   // TSecr  — 来自对端的 echo 时间戳
}
```

注意：TCPOLEN_TIMESTAMP = 10，但实际编码会与其他选项（NOP/SACK）组合成 12 字节对齐。

---

## 2. ts_recent / ts_recent_stamp 维护（PAWS 防护）

### 数据结构

TCP 时间戳接收状态存储在 `struct tcp_options_received`（`linux/tcp.h:111`）中：

```c
// include/linux/tcp.h:111-135
struct tcp_options_received {
    int     ts_recent_stamp;   /* 存放 ts_recent 的时间（jiffies/秒） */
    u32     ts_recent;         /* 要回显的下一个时间戳（Last-TS）       */
    u32     rcv_tsval;         /* 刚收到的 TSval                       */
    u32     rcv_tsecr;         /* 刚收到的 TSecr                       */
    u16     saw_tstamp : 1,    /* 当前报文是否带时间戳                 */
            tstamp_ok  : 1,   /* SYN 时协商了时间戳选项               */
            dsack      : 1,
            wscale_ok  : 1,
            sack_ok    : 3,
            smc_ok     : 1,
            snd_wscale : 4,   /* 对端发来的窗口扩大因子              */
            rcv_wscale : 4;   /* 本端向对端宣告的窗口扩大因子        */
    // ...
};
```

### PAWS 检查（tcp_paws_check / tcp_paws_reject）

PAWS（Protect Against Wrapped Sequences）防止旧重复报文被当作合法报文接受：

```c
// include/net/tcp.h:1889-1907
#define TCP_PAWS_WRAP  (INT_MAX / USEC_PER_SEC)   // ~2147 秒，防止 timestamp 回绕
#define TCP_PAWS_MSL   60                          // 60 秒，MSL 级别的时间戳老化
#define TCP_PAWS_WINDOW 1                          // 1 个时间戳单位宽的 replay window

static inline bool tcp_paws_check(const struct tcp_options_received *rx_opt,
                                  int paws_win)
{
    // 比较 rcv_tsval 与 ts_recent，paws_win 通常为 0 或 1
    if ((s32)(rx_opt->ts_recent - rx_opt->rcv_tsval) <= paws_win)
        return true;   // 落在 replay window 内
    if (unlikely(!time_before32(ktime_get_seconds(),
                                rx_opt->ts_recent_stamp + TCP_PAWS_WRAP)))
        return true;   // 已回绕，放弃检查
    // 0 值特殊情况：部分 OS 在 SYN/SYN-ACK 中发送 TSval=0
    if (!rx_opt->ts_recent)
        return true;
    return false;  // PAWS 判定为重复报文
}
```

### ts_recent 更新（tcp_store_ts_recent / tcp_replace_ts_recent）

```c
// net/ipv4/tcp_input.c:4077-4080
static void tcp_store_ts_recent(struct tcp_sock *tp)
{
    tp->rx_opt.ts_recent = tp->rx_opt.rcv_tsval;
    tp->rx_opt.ts_recent_stamp = ktime_get_seconds();
}

// net/ipv4/tcp_input.c:4088-4101
static int tcp_replace_ts_recent(struct tcp_sock *tp, u32 seq)
{
    s32 delta;
    // 仅对有效数据更新（seq 未超出 rcv_wup），且通过 PAWS 检查
    if (tp->rx_opt.saw_tstamp && !after(seq, tp->rcv_wup)) {
        if (tcp_paws_check(&tp->rx_opt, 0)) {
            delta = tp->rx_opt.rcv_tsval - tp->rx_opt.ts_recent;
            return __tcp_replace_ts_recent(tp, delta);
        }
    }
    return 0;
}
```

关键约束：seq 不超过 `rcv_wup`（已确认的接收上沿），防止对纯 ACK 帧的 PAWS bug（见源码注释）。

---

## 3. tcp_transmit_skb 中的 timestamp 选项添加

### __tcp_transmit_skb 流程

`__tcp_transmit_skb()`（`tcp_output.c:1529`）是所有 TCP 发包的中心入口：

```c
// net/ipv4/tcp_output.c:1569-1587
if (unlikely(tcb->tcp_flags & TCPHDR_SYN)) {
    tcp_options_size = tcp_syn_options(sk, skb, &opts, &key);
} else {
    tcp_options_size = tcp_established_options(sk, skb, &opts, &key);
    if (tcp_skb_pcount(skb) > 1)
        tcb->tcp_flags |= TCPHDR_PSH;
}
tcp_header_size = tcp_options_size + sizeof(struct tcphdr);
// ... 后续构造 TCP 头 ...
tcp_options_write(th, tp, NULL, &opts, &key);
```

### tcp_established_options — 已建立连接的 TS 选项

```c
// net/ipv4/tcp_output.c:1175-1178
if (likely(tp->rx_opt.tstamp_ok)) {
    opts->options |= OPTION_TS;
    opts->tsval = skb ? tcp_skb_timestamp_ts(tp->tcp_usec_ts, skb) + tp->tsoffset : 0;
    opts->tsecr = tp->rx_opt.ts_recent;   // 始终回显 ts_recent（即使对端未设置 TS）
    size += TCPOLEN_TSTAMP_ALIGNED;
}
```

关键点：
- **TSval**：`tcp_skb_timestamp_ts()` 从 skb 的时间戳（1MHz 或 1kHz）加上 `tp->tsoffset`（时间戳偏移量，用于防止信息泄露）
- **TSecr**：直接取 `tp->rx_opt.ts_recent`（本端记录的最后有效 TSval）

### tcp_syn_options — SYN 阶段

```c
// net/ipv4/tcp_output.c:1001-1003
if (likely(timestamps)) {
    opts->options |= OPTION_TS;
    opts->tsval = tcp_skb_timestamp_ts(tp->tcp_usec_ts, skb) + tp->tsoffset;
    opts->tsecr = tp->rx_opt.ts_recent;
    remaining -= TCPOLEN_TSTAMP_ALIGNED;
}
```

---

## 4. tcp_parse_options — 时间戳解析

### tcp_parse_options（常规路径）

```c
// net/ipv4/tcp_input.c:4591-4599
case TCPOPT_TIMESTAMP:
    if ((opsize == TCPOLEN_TIMESTAMP) &&
        ((estab && opt_rx->tstamp_ok) ||
         (!estab && READ_ONCE(net->ipv4.sysctl_tcp_timestamps)))) {
        opt_rx->saw_tstamp = 1;
        opt_rx->rcv_tsval = get_unaligned_be32(ptr);      // 解析 TSval
        opt_rx->rcv_tsecr = get_unaligned_be32(ptr + 4);  // 解析 TSecr
    }
    break;
```

条件：
- 长度必须为 10
- 已建立连接时要求 SYN 时协商过（`tstamp_ok`）
- 非建立状态（listen socket）要求 sysctl `tcp_timestamps` 开启

### tcp_fast_parse_options（快速路径）

对已建立连接，内核优先尝试快速对齐解析（`tcp_input.c:4669-4719`）：

```c
// net/ipv4/tcp_input.c:4673-4686
static bool tcp_parse_aligned_timestamp(struct tcp_sock *tp, const struct tcphdr *th)
{
    __be32 *ptr = (__be32 *)(th + 1);
    if (ptr[0] == htonl((TCPOPT_TIMESTAMP << 24) | (TCPOLEN_TIMESTAMP << 16) |
                        (TCPOPT_NOP << 8) | TCPOPT_NOP)) {
        ++ptr;
        tp->rx_opt.rcv_tsval = ntohl(*ptr);
        ++ptr;
        if (*ptr)
            tp->rx_opt.rcv_tsecr = ntohl(*ptr) - tp->tsoffset;
        else
            tp->rx_opt.rcv_tsecr = 0;
        return true;
    }
    return false;
}
```

若对齐格式匹配（4字节对齐+特定模式），则直接解析，跳过完整解析。但无论哪种路径，解析后都会对 TSecr 减去 `tsoffset`（`tcp_input.c:4684`）：

```c
tp->rx_opt.rcv_tsecr -= tp->tsoffset;
```

---

## 5. 窗口缩放（Window Scaling）factor 计算

### 协商时序

```
主动端（connect）                          被动端（listen）
    │                                          │
    │--- SYN + WSCALE( rcv_wscale ) ---------->│  记录对端 snd_wscale
    │                                          │
    │<-- SYN-ACK + WSCALE( rcv_wscale ) -------|  记录自己的 rcv_wscale，保存对端 snd_wscale
    │                                          │
    │--- ACK --------------------------------->│
```

### 本端 rcv_wscale 计算（tcp_select_initial_window）

在 `tcp_output.c:237` 的 `tcp_select_initial_window()` 中：

```c
// net/ipv4/tcp_output.c:268-273
*rcv_wscale = 0;
if (wscale_ok) {
    space = max_t(u32, space, READ_ONCE(sock_net(sk)->ipv4.sysctl_tcp_rmem[2]));
    space = max_t(u32, space, READ_ONCE(sysctl_rmem_max));
    space = min_t(u32, space, window_clamp);
    *rcv_wscale = clamp_t(int, ilog2(space) - 15, 0, TCP_MAX_WSCALE);
}
```

算法：`rcv_wscale = clamp(ilog2(receive_buffer) - 15, 0, 14)`

| 实际缓冲大小 | ilog2 | rcv_wscale |
|---|---|---|
| 16KB | 14 | 0 (最大 64KB) |
| 64KB | 16 | 1 (最大 128KB) |
| 256KB | 18 | 3 |
| 1MB | 20 | 5 |
| 16MB | 24 | 9 |
| 64MB（最大） | 26 | 11 |

> TCP_MAX_WSCALE 定义为 `include/net/tcp.h:102`：`#define TCP_MAX_WSCALE 14U`
> 14 对应最大缓冲 65535 × 2^14 ≈ 1 GB（RFC 1323 规定上限）

### 本端收到对端 WSCALE 选项

在 `tcp_input.c:4581-4591` 解析对端发来的 WSCALE：

```c
// net/ipv4/tcp_input.c:4581-4591
case TCPOPT_WINDOW:
    if (opsize == TCPOLEN_WINDOW && th->syn && !estab &&
        READ_ONCE(net->ipv4.sysctl_tcp_window_scaling)) {
        __u8 snd_wscale = *(__u8 *)ptr;
        opt_rx->wscale_ok = 1;
        if (snd_wscale > TCP_MAX_WSCALE) {
            net_info_ratelimited("Illegal window scaling value %d > %u received\n",
                                snd_wscale, TCP_MAX_WSCALE);
            snd_wscale = TCP_MAX_WSCALE;
        }
        opt_rx->snd_wscale = snd_wscale;
    }
    break;
```

若对端 snd_wscale > 14，内核会截断为 14 而非拒绝连接。

---

## 6. shift_cnt vs actual window size

### 发送端：收到对方宣告的窗口

接收对方 TCP 头中的 16-bit window 字段后，本端用 `snd_wscale` 左移还原实际窗口：

```c
// net/ipv4/tcp_input.c:7248
tp->snd_wnd = ntohs(th->window) << tp->rx_opt.snd_wscale;
```

示例：
- 对端发送 window = 8192，snd_wscale = 3
- 实际窗口 = 8192 << 3 = 65536

### 接收端：宣告本端接收窗口

`tcp_receive_window()` 计算当前可通告的窗口，然后 `tcp_select_window()` 考虑是否需要收缩：

```c
// net/ipv4/tcp_output.c:305-327
if (!tp->rx_opt.rcv_wscale &&
    READ_ONCE(net->ipv4.sysctl_tcp_workaround_signed_windows))
    new_win = min(new_win, MAX_TCP_WINDOW);
else
    new_win = min(new_win, (65535U << tp->rx_opt.rcv_wscale));

/* RFC1323 scaling applied */
new_win >>= tp->rx_opt.rcv_wscale;   // 缩回 16-bit 字段能表示的值
```

### 关键：ALIGN 约束

当 `rcv_wscale > 0` 时，`__tcp_select_window()` 强制窗口值为 `shift_cnt` 的整数倍：

```c
// net/ipv4/tcp_output.c:3382-3385
if (tp->rx_opt.rcv_wscale) {
    window = free_space;
    window = ALIGN(window, (1 << tp->rx_opt.rcv_wscale));
} else {
    window = tp->rcv_wnd;
    if (window <= free_space - mss || window > free_space)
        window = rounddown(free_space, mss);
}
```

> 若 1<<rcv_wscale > MSS，`window` 至少为 1<<rcv_wscale（确保缩放后仍可通告非零窗口）

---

## 7. tcp_select_window — scaling 协商

### tcp_select_window 完整流程

```c
// net/ipv4/tcp_output.c:276-348
static u16 tcp_select_window(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct net *net = sock_net(sk);
    u32 old_win = tp->rcv_wnd;
    u32 cur_win, new_win;

    if (unlikely(inet_csk(sk)->icsk_ack.pending & ICSK_ACK_NOMEM)) {
        tp->pred_flags = 0;
        tp->rcv_wnd = 0;
        tp->rcv_wup = tp->rcv_nxt;
        tcp_update_max_rcv_wnd_seq(tp);
        return 0;
    }

    cur_win = tcp_receive_window(tp);
    new_win = __tcp_select_window(sk);
    
    if (new_win < cur_win) {
        /* 仅在 sysctl tcp_shrink_window 开启且已启用 scaling 时允许收缩 */
        if (!READ_ONCE(net->ipv4.sysctl_tcp_shrink_window) || !tp->rx_opt.rcv_wscale) {
            new_win = ALIGN(cur_win, 1 << tp->rx_opt.rcv_wscale);
        }
    }

    tp->rcv_wnd = new_win;
    tp->rcv_wup = tp->rcv_nxt;
    tcp_update_max_rcv_wnd_seq(tp);

    /* 不可超过对方可表示的最大缩放窗口 */
    new_win = min(new_win, (65535U << tp->rx_opt.rcv_wscale));
    new_win >>= tp->rcv_wscale;

    /* Fast path 控制 */
    if (new_win == 0) {
        tp->pred_flags = 0;
    } else if (old_win == 0) {
        NET_INC_STATS(net, LINUX_MIB_TCPFROMZEROWINDOWADV);
    }

    return new_win;  // 返回 16-bit 字段值（缩放前的原始值）
}
```

### 被动端握手时 wscale_ok 处理

```c
// net/ipv4/tcp_input.c:6914-6920
if (!tp->rx_opt.wscale_ok) {
    tp->rx_opt.snd_wscale = tp->rx_opt.rcv_wscale = 0;
    WRITE_ONCE(tp->window_clamp, min(tp->window_clamp, 65535U));
}
```

若对端未在 SYN 中携带 WSCALE 选项，本端将两边都设为 0，并同时将 `window_clamp` 回落到 65535（防止老旧 buggy stack 把 window 字段当 signed 处理）。

---

## 8. RTTM（Round Trip Time Measurement）

### 时间戳的 RTT 测量机制

当本端发送包含 TSval=T1 的报文，对端在数据帧中回显该 TSval 作为 TSecr。本端收到 ACK 时，计算 RTT：

```
RTT = (ACK 到达时间) - (对端收到报文的时间)
    ≈ (本地收到 ACK 时间) - TSecr - (Propagation delay)
```

### 本端 RTT 计算（tcp_clean_rtt_queue）

```c
// net/ipv4/tcp_input.c:2736
seq_rtt_us = (s32)(tcp_time_stamp(tp) - tp->rx_opt.rcv_tsecr);
```

前提：`rcv_tsecr` 必须非零且 `saw_tstamp` 已设置。

### 时间戳在 RTTM 中的约束

- **TSecr 有效性**：若 TSecr = 0（如对端不支持 timestamp），本端无法执行 RTTM
- **高精度模式**：`tcp_usec_ts` 时钟为 1MHz（微秒级），默认模式为 1kHz（毫秒级），见 `include/net/tcp.h:191`
- **拥塞控制**：RTT 采样进入 `tcp_rtt_estimator()` 影响 srtt/rttvar，进而决定 RTO 和拥塞控制参数

---

## 9. TSval 伪随机化与 tsoffset

### 时间戳时钟源

内核支持两种时间戳时钟源，通过 `tp->tcp_usec_ts` 布尔标志选择：

```c
// include/net/tcp.h:1032
static inline u32 tcp_skb_timestamp_ts(bool usec_ts, const struct sk_buff *skb)
{
    if (usec_ts)
        return tcp_skb_timestamp_us(skb);   // 1MHz，usec 精度
    return div_u64(skb->skb_mstamp_ns, NSEC_PER_MSEC);  // 1kHz，msec 精度
}
```

### tsoffset — 时间戳偏移量

`tsoffset` 是 `tcp_sock` 中的一个可配置字段，用于对 TSval 进行偏移：

```c
// net/ipv4/tcp_output.c:1002
opts->tsval = tcp_skb_timestamp_ts(tp->tcp_usec_ts, skb) + tp->tsoffset;
```

接收时（`tcp_input.c:4684` 和 `4716`）：
```c
tp->rx_opt.rcv_tsecr -= tp->tsoffset;   // 减去偏移量，还原真实 TSval
```

**目的**：`tsoffset` 提供了时间戳的伪随机化能力，使得即使攻击者能观察时间戳格式，也难以推断连接的真实时间线。注意：Linux 7.0-rc1 的时间戳直接来自单调时钟，而非早期版本的 `secure_tcp_ts_off()` 系列函数——该安全机制在较新内核中已通过其他方式实现（如 `tsoffset`）。

---

## 关键源码行号索引

| 主题 | 文件 | 行号 |
|---|---|---|
| TCPOPT_TIMESTAMP / TCPOLEN_TIMESTAMP | `include/net/tcp.h` | 212, 215, 236 |
| TCP_MAX_WSCALE = 14 | `include/net/tcp.h` | 102 |
| struct tcp_options_received | `include/linux/tcp.h` | 111-135 |
| tcp_paws_check / tcp_paws_reject | `include/net/tcp.h` | 1889-1931 |
| tcp_store_ts_recent | `net/ipv4/tcp_input.c` | 4077-4080 |
| tcp_replace_ts_recent | `net/ipv4/tcp_input.c` | 4088-4101 |
| __tcp_transmit_skb | `net/ipv4/tcp_output.c` | 1529-1733 |
| tcp_options_write | `net/ipv4/tcp_output.c` | 658-756 |
| tcp_established_options | `net/ipv4/tcp_output.c` | 1155-1192 |
| tcp_syn_options | `net/ipv4/tcp_output.c` | 964-1053 |
| tcp_parse_options (TS) | `net/ipv4/tcp_input.c` | 4591-4599 |
| tcp_fast_parse_options | `net/ipv4/tcp_input.c` | 4669-4719 |
| tcp_parse_aligned_timestamp | `net/ipv4/tcp_input.c` | 4673-4686 |
| tcp_select_initial_window | `net/ipv4/tcp_output.c` | 230-274 |
| tcp_openreq_init (wscale) | `net/ipv4/tcp_input.c` | 7451-7482 |
| tcp_connect_init | `net/ipv4/tcp_output.c` | 4090-4155 |
| __tcp_select_window | `net/ipv4/tcp_output.c` | 3312-3427 |
| tcp_select_window | `net/ipv4/tcp_output.c` | 276-348 |
| tcp_receive_window | `net/ipv4/tcp_output.c` | 305-326 |
| RTT 采样（seq_rtt_us） | `net/ipv4/tcp_input.c` | 2736 |
| tsoffset 应用 | `net/ipv4/tcp_output.c` | 1002, 1177 |
| tsoffset 接收回减 | `net/ipv4/tcp_input.c` | 4684, 4716, 6831 |
| PAWS 检查（慢路径） | `net/ipv4/tcp_input.c` | 6286-6320 |
| 握手时 tstamp_ok 处理 | `net/ipv4/tcp_input.c` | 6920-6925 |

---

## 总结

TCP 时间戳和窗口缩放是 RFC 1323 的两大核心扩展，它们在内核中深度交织：

1. **时间戳**通过 10 字节选项（TSval + TSecr）实现 PAWS 防重放保护和精确 RTT 测量，`ts_recent`/`ts_recent_stamp` 维护时间窗口内的最近 TSval
2. **窗口缩放**通过 3 字节选项（scale factor 0-14）将 16-bit 窗口字段扩展至最大 1GB 缓冲，双方各自维护 `snd_wscale` 和 `rcv_wscale`，窗口值始终以 `1 << rcv_wscale` 为最小粒度对齐
3. **tsoffset** 机制为 TSval 提供偏移能力，防止时间信息泄露
4. 握手阶段协商完成后，`tcp_header_len` 会因选项空间增大而调整，进而影响 MSS 计算