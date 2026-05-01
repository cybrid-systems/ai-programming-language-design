# TCP 三次握手与状态转换 — 从 `tcp_v4_connect` 到 `tcp_state_machine`

> 源码基于 Linux 7.0-rc1 (`net/ipv4/tcp.c`, `tcp_input.c`, `tcp_output.c`, `tcp_ipv4.c`, `tcp_minisocks.c`, `inet_hashtables.c`)

## 1. TCP 状态定义

```c
// include/net/tcp_states.h
enum {
    TCP_ESTABLISHED = 1,
    TCP_SYN_SENT,      // 2
    TCP_SYN_RECV,      // 3
    TCP_FIN_WAIT1,     // 4
    TCP_FIN_WAIT2,     // 5
    TCP_TIME_WAIT,     // 6
    TCP_CLOSE,         // 7
    TCP_CLOSE_WAIT,    // 8
    TCP_LAST_ACK,      // 9
    TCP_LISTEN,        // 10
    TCP_CLOSING,       // 11
    TCP_NEW_SYN_RECV,  // 12
};
```

## 2. 完整调用链：主动打开（Active Open）

```
用户调用 connect()
    │
    ▼
tcp_v4_connect()               [tcp_ipv4.c:221]
    │  1. ip_route_connect()       — 路由查找
    │  2. tcp_set_state(TCP_SYN_SENT)
    │  3. inet_hash_connect()     — 源端口选择 + 放入 bind hash
    │  4. ip_route_newports()     — 路由重绑定
    │  5. secure_tcp_seq()        — 随机 Initial Sequence Number
    │  6. tcp_connect()           — 构造 SYN 包并发送
    ▼
tcp_connect()                  [tcp_output.c:4292]
    │
    ├─► tcp_connect_init()       — 初始化 mss / window / seq
    ├─► tcp_stream_alloc_skb()   — 分配一个空 SKB（len=0）
    ├─► tcp_init_nondata_skb()   — 设置 seq=write_seq, TCPHDR_SYN
    ├─► tcp_connect_queue_skb()  — write_seq++ (SYN 消耗一个 seq)
    ├─► tcp_transmit_skb()       — 调用 ip_output() 发送 SYN
    └─► tp->snd_nxt = tp->write_seq  [tcp_output.c:4387]
         │
         ▼
    启动重传定时器 (ICSK_TIME_RETRANS)
```

### 2.1 `tcp_v4_connect` 详解

```c
// tcp_ipv4.c:221
int tcp_v4_connect(struct sock *sk, struct sockaddr_unsized *uaddr, int addr_len)
{
    // ...
    fl4 = &inet->cork.fl.u.ip4;
    rt = ip_route_connect(fl4, nexthop, inet->inet_saddr,
                          sk->sk_bound_dev_if, IPPROTO_TCP,
                          orig_sport, orig_dport, sk);
    // 若未绑定源地址，inet_bhash2_update_saddr() 会从路由分配

    tcp_set_state(sk, TCP_SYN_SENT);          // [tcp_ipv4.c:298]

    err = inet_hash_connect(tcp_death_row, sk); // [tcp_ipv4.c:306]
    if (err) goto failure;

    rt = ip_route_newports(fl4, rt, ...);     // [tcp_ipv4.c:318]

    // 序列号 = secure_tcp_seq_and_ts_off() 生成
    st = secure_tcp_seq_and_ts_off(net, inet->inet_saddr,
                                   inet->inet_daddr,
                                   inet->inet_sport, usin->sin_port);
    tp->write_seq = st.seq;                  // [tcp_ipv4.c:340]

    err = tcp_connect(sk);                   // [tcp_ipv4.c:349]
}
```

### 2.2 源端口选择：`inet_hash_connect` + `__inet_hash_connect`

```c
// inet_hashtables.c:1042
int __inet_hash_connect(struct inet_timewait_death_row *death_row,
                        struct sock *sk, u64 port_offset, u32 hash_port0,
                        int (*check_established)(...))
{
    // 获取随机增量 (table_perturb 机制)
    get_random_sleepable_once(table_perturb, INET_TABLE_PERTURB_SIZE);
    index = port_offset & (INET_TABLE_PERTURB_SIZE - 1);
    offset = READ_ONCE(table_perturb[index]) + (port_offset >> 32);
    offset %= remaining;                          // [inet_hashtables.c:1095]

    // 计算随机步长 scan_step，避免每次都从同一端口开始扫描
    scan_step = get_random_u32_inclusive(1, upper_bound);
    while (gcd(scan_step, range) != 1)           // 确保互质
        scan_step++;

    // 遍历可用端口范围，选择第一个未冲突的端口
    for (i = 0; i < remaining; i += step, port += scan_step) {
        // inet_is_local_reserved_port() — 跳过保留端口
        // inet_bind_bucket_for_each()    — 检查端口是否已被占用
        // inet_bind_bucket_create()      — 创建新的 bind bucket
        // check_established()            — 检查 TIME_WAIT 连接冲突
    }
}
```

`xor_rand`（实际上叫 `table_perturb`，来自 `/proc/sys/net/ipv4/ip_local_port_range` 的哈希混淆）确保并发多个 `connect()` 调用时，源端口扫描不会每次都从同一位置开始，减少冲突概率。

### 2.3 `tcp_connect_init`：连接参数初始化

```c
// tcp_output.c:4099
static void tcp_connect_init(struct sock *sk)
{
    const struct dst_entry *dst = __sk_dst_get(sk);
    struct tcp_sock *tp = tcp_sk(sk);

    tp->tcp_header_len = sizeof(struct tcphdr);
    if (sysctl_tcp_timestamps) tp->tcp_header_len += TCPOLEN_TSTAMP_ALIGNED;

    tp->rx_opt.mss_clamp = user_mss ?: TCP_MSS_DEFAULT;

    tcp_mtup_init(sk);                      // MTU 发现
    tcp_sync_mss(sk, dst_mtu(dst));         // 计算 MSS

    tp->advmss = tcp_mss_clamp(tp, dst_metric_advmss(dst));

    // 初始化接收窗口
    rcv_wnd = tcp_rwnd_init_bpf(sk) ?: dst_metric(dst, RTAX_INITRWND);
    tcp_select_initial_window(sk, tcp_full_space(sk), tp->advmss,
                              &tp->rcv_wnd, &tp->window_clamp,
                              sysctl_tcp_window_scaling, &rcv_wscale, rcv_wnd);
    tp->rx_opt.rcv_wscale = rcv_wscale;

    // 发送侧序列号初始化
    WRITE_ONCE(tp->snd_una, tp->write_seq);   // [tcp_output.c:4157]
    tp->snd_sml = tp->write_seq;
    tp->snd_up  = tp->write_seq;
    WRITE_ONCE(tp->snd_nxt, tp->write_seq);

    tp->rcv_nxt  = 0;                         // 尚未收到任何数据
    tp->rcv_wup  = tp->rcv_nxt;
    tp->copied_seq = tp->rcv_nxt;

    inet_csk(sk)->icsk_rto = tcp_timeout_init(sk); // RTO 初始化
}
```

### 2.4 `tcp_connect`：构造并发送 SYN

```c
// tcp_output.c:4292
int tcp_connect(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *buff;

    tcp_connect_init(sk);                        // [tcp_output.c:4350]

    buff = tcp_stream_alloc_skb(sk, sk->sk_allocation, true);
    //                               ^^^^^^^^  zero-length SKB

    // SYN 包：seq = write_seq，SYN 消耗一个序列号，所以 end_seq = write_seq + 1
    tcp_init_nondata_skb(buff, sk, tp->write_seq, TCPHDR_SYN);
                                                       // [tcp_output.c:386]
    //  → TCP_SKB_CB(buff)->seq     = tp->write_seq
    //  → TCP_SKB_CB(buff)->end_seq = tp->write_seq + 1  (因为 SYN|FIN flag)

    tcp_connect_queue_skb(sk, buff);
    //  → tp->write_seq = TCP_SKB_CB(buff)->end_seq  (即 write_seq + 1)
    //  → sk_wmem_queued_add(sk, skb->truesize)
    //  → tp->packets_out++

    tcp_ecn_send_syn(sk, buff);               // ECN 功能

    // 发送 SYN
    err = tp->fastopen_req ? tcp_send_syn_data(sk, buff) :
          tcp_transmit_skb(sk, buff, 1, sk->sk_allocation);

    // 发送后更新 snd_nxt
    WRITE_ONCE(tp->snd_nxt, tp->write_seq);   // [tcp_output.c:4387]
    // 此时 snd_nxt == write_seq == 初始 ISN + 1（SYN 消耗了 1）

    // 启动 SYN 重传定时器
    tcp_reset_xmit_timer(sk, ICSK_TIME_RETRANS,
                         inet_csk(sk)->icsk_rto, false);
    return 0;
}
```

## 3. TCP 状态机图（ASCII）

```
                              ┌─────────────────────────────────────────────┐
                              │                                             │
   主动打开                    ▼                                             │
  connect()              TCP_SYN_SENT ────── SYN+ACK ─────────► TCP_SYN_RECV │
  ┌─────────┐            (客户端发送                 (服务器收到 SYN，       │
  │ CLOSED  │───────────── SYN后进入)                 发送SYN+ACK后进入)      │
  └─────────┘                                               │                │
                              ▲                              │                │
                              │                              ▼                │
                         收到 RST                   收到 ACK (三次握手       │
                         / 拒绝连接                  完成)后进入              │
                              │                              │                │
                              │                              ▼                │
                              │                    TCP_ESTABLISHED ◄───┐     │
                              │                    (数据传输状态)         │     │
                              │                              │           │     │
                              │  close()                      │主动关闭   │     │
                              │  (收到 FIN 后)                │           │     │
                              │                              ▼           │     │
                              │                     TCP_FIN_WAIT1 ────────┤     │
                              │                              │           │     │
                              │                              │收到 FIN   │     │
                              │                              │ACK        │     │
                              │                              ▼           │     │
                              │                     TCP_FIN_WAIT2 ◄───────┤     │
                              │                              │           │     │
                              │                              │超时或     │     │
                              │                              │收到 FIN   │     │
                              │                              ▼           │     │
                              │                       TCP_TIME_WAIT ◄──┘     │
                              │                       (2MSL = 60s)            │
                              │                              │                │
                              └──────────────────────────────┘                │
                                                                             │
                              ┌──────────────────────────────────────────────┘
                              │
                         TCP_CLOSE ◄─────────────────────────────────────────┘
                         (连接结束)
```

## 4. 三次握手详细状态转换

### 第一次握手：TCP_SYN_SENT

**客户端**调用 `tcp_connect()`，发送 SYN (seq=ISN)，进入 `TCP_SYN_SENT`。

关键序列号操作（`tcp_output.c`）：

```c
// tcp_output.c:4366
tcp_init_nondata_skb(buff, sk, tp->write_seq, TCPHDR_SYN);
// SYN: seq=write_seq, end_seq=write_seq+1

tcp_connect_queue_skb(sk, buff);
// tp->write_seq = write_seq + 1  (SYN 消耗一个 seq)

WRITE_ONCE(tp->snd_nxt, tp->write_seq);
// snd_nxt = ISN + 1
```

### 第二次握手：TCP_SYN_RECV（被动端）

**服务器**收到 SYN 后：

1. `tcp_v4_rcv()` → `tcp_rcv_state_process()` (`tcp_input.c:7119`)
2. `sk->sk_state == TCP_LISTEN` 时，调用 `icsk->icsk_af_ops->conn_request()` → `tcp_v4_syn_recv_sock()` 或 `tcp_conn_request()`
3. 创建 `request_sock`（三次握手半开连接）
4. 调用 `inet_csk_reqsk_queue_hash_add(sk, req)` (`inet_connection_sock.c:1161`)：

```c
// inet_connection_sock.c:1161
bool inet_csk_reqsk_queue_hash_add(struct sock *sk, struct request_sock *req)
{
    if (!reqsk_queue_hash_req(req))         // 放入 listen  socket 的 hash 表
        return false;
    inet_csk_reqsk_queue_added(sk);          // 更新 icsk_ack.fastopenq.rskq_len
    return true;
}
```

服务器回复 SYN+ACK（seq=服务器ISN，ack=客户端ISN+1），进入 `TCP_SYN_RECV`。

### 第三次握手：TCP_ESTABLISHED

**客户端**收到 SYN+ACK 后，`tcp_v4_rcv()` → `tcp_rcv_state_process()`：

```c
// tcp_input.c:7119
enum skb_drop_reason tcp_rcv_state_process(struct sock *sk, struct sk_buff *skb)
{
    switch (sk->sk_state) {
    case TCP_SYN_SENT:
        tp->rx_opt.saw_tstamp = 0;
        tcp_mstamp_refresh(tp);
        queued = tcp_rcv_synsent_state_process(sk, skb, th);
        //                ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        //                处理 SYN+ACK，返回 -1 表示"发送 ACK 后等待"
        if (queued >= 0)
            return queued;
        // ...
    }
}
```

核心处理在 `tcp_rcv_synsent_state_process()` (`tcp_input.c:6819`)：

```c
// tcp_input.c:6819
static int tcp_rcv_synsent_state_process(struct sock *sk,
                                         struct sk_buff *skb,
                                         const struct tcphdr *th)
{
    // 1. 验证 ACK 字段：SND.UNA < ACK <= SND.NXT
    if (!after(TCP_SKB_CB(skb)->ack_seq, tp->snd_una) ||
         after(TCP_SKB_CB(skb)->ack_seq, tp->snd_nxt)) {
        // ACK 无效 → reset
        goto reset_and_undo;
    }

    // 2. 收到 RST？→ 直接关闭
    if (th->rst) { tcp_reset(sk, skb); goto consume; }

    // 3. 收到 SYN + ACK（第三次握手）
    if (th->syn) {
        tcp_set_state(sk, TCP_SYN_RECV);        // [tcp_input.c:7027]

        // 确认对端序列号
        WRITE_ONCE(tp->rcv_nxt, TCP_SKB_CB(skb)->seq + 1);
        tp->rcv_wup = tp->rcv_nxt;

        // 计算snd_una（确认了对端的 SYN）
        tcp_ack(sk, skb, FLAG_SLOWPATH);

        // 调用 tcp_finish_connect() → 状态变为 ESTABLISHED
        tcp_finish_connect(sk, skb);            // [tcp_input.c:6700]
        return -1;  // 让调用者发送 ACK
    }
}
```

`tcp_finish_connect()` (`tcp_input.c:6700`)：

```c
void tcp_finish_connect(struct sock *sk, struct sk_buff *skb)
{
    struct tcp_sock *tp = tcp_sk(sk);
    tcp_ao_finish_connect(sk, skb);
    tcp_set_state(sk, TCP_ESTABLISHED);         // ★ 三次握手完成

    tcp_init_transfer(sk, BPF_SOCK_OPS_ACTIVE_ESTABLISHED_CB, skb);

    tp->lsndtime = tcp_jiffies32;

    if (!tp->rx_opt.snd_wscale)
        __tcp_fast_path_on(tp, tp->snd_wnd);   // 快速路径
}
```

**服务器**收到第三次握手的 ACK 后（处于 `TCP_SYN_RECV`）：

```c
// tcp_input.c:7244 (tcp_rcv_state_process switch)
case TCP_SYN_RECV:
    WRITE_ONCE(tp->delivered, tp->delivered + 1);
    if (!tp->srtt_us)
        tcp_synack_rtt_meas(sk, req);

    if (req) {
        tcp_rcv_synrecv_state_fastopen(sk);
    } else {
        tcp_try_undo_spurious_syn(sk);
        tcp_init_transfer(sk, BPF_SOCK_OPS_PASSIVE_ESTABLISHED_CB, skb);
    }
    tcp_ao_established(sk);
    tcp_set_state(sk, TCP_ESTABLISHED);         // ★ 被动端也进入 ESTABLISHED
    sk->sk_state_change(sk);
```

## 5. Established 状态下的 ACK 确认

`tcp_ack()` (`tcp_input.c`) 是 ACK 处理的核心。当 `tcp_rcv_state_process()` 在 `TCP_ESTABLISHED` 状态收到任何包时：

```c
// tcp_input.c:7244
switch (sk->sk_state) {
case TCP_SYN_RECV:
    // ...
    reason = tcp_ack(sk, skb, FLAG_SLOWPATH | FLAG_UPDATE_TS_RECENT | FLAG_NO_CHALLENGE_ACK);
    if ((int)reason <= 0) { /* 处理无效 ACK */ }
    // 状态变为 ESTABLISHED ...
    WRITE_ONCE(tp->snd_una, TCP_SKB_CB(skb)->ack_seq); // 更新 snd_una
    tp->snd_wnd = ntohs(th->window) << tp->rx_opt.snd_wscale;
```

`snd_una`（send unacknowledged）是发送窗口的左边界，所有小于 `snd_una` 的数据都已收到对方确认。

## 6. TIME_WAIT 和 2MSL

### 6.1 何时进入 TIME_WAIT

```
主动关闭端（假设客户端先 close）：
  ESTABLISHED
     │ close()
     ▼
  FIN_WAIT1 ──── 收到 FIN, ACK ────► FIN_WAIT2
     │                              │
     │ 收到对方 FIN 的 ACK           │ 收到对方 FIN
     ▼                              ▼
  TIME_WAIT ◄──────────────────────┘
  (持续 2MSL = 60s)

被动关闭端：
  ESTABLISHED
     │ 收到对方 FIN
     ▼
  CLOSE_WAIT ──── close() ────► LAST_ACK ──── 收到 ACK ────► CLOSED
```

### 6.2 `tcp_time_wait`：TIME_WAIT 的创建

```c
// tcp_minisocks.c:326
void tcp_time_wait(struct sock *sk, int state, int timeo)
{
    const struct inet_connection_sock *icsk = inet_csk(sk);
    struct tcp_sock *tp = tcp_sk(sk);
    struct inet_timewait_sock *tw;

    tw = inet_twsk_alloc(sk, &net->ipv4.tcp_death_row, state);

    if (tw) {
        struct tcp_timewait_sock *tcptw = tcp_twsk((struct sock *)tw);

        // 复制连接状态到 timewait sock
        tcptw->tw_rcv_nxt  = tp->rcv_nxt;
        tcptw->tw_snd_nxt  = tp->snd_nxt;
        tcptw->tw_rcv_wnd  = tcp_receive_window(tp);
        tcptw->tw_ts_recent = tp->rx_opt.ts_recent;

        tcp_time_wait_init(sk, tcptw);

        /* TIME_WAIT 状态强制使用 TCP_TIMEWAIT_LEN = 60s */
        if (state == TCP_TIME_WAIT)
            timeo = TCP_TIMEWAIT_LEN;          // [tcp_minisocks.c:380]

        inet_twsk_hashdance_schedule(tw, sk, ..., timeo);
        //                                   ^^^^^ timeo 作为定时器超时
    }

    tcp_done(sk);  // 原始 sock 进入 CLOSED
}
```

### 6.3 2MSL 的值

```c
// include/net/tcp.h:142
#define TCP_TIMEWAIT_LEN (60*HZ)   /* = 60 秒，Linux 固定值 */
```

Linux 没有使用动态 2MSL，而是固定 60 秒。在 `tcp_timewait_state_process()` 中检查 `PAWS`（防止旧数据段被误接受）和 RST：

```c
// tcp_minisocks.c:101
enum tcp_tw_status tcp_timewait_state_process(struct inet_timewait_sock *tw,
                                               struct sk_buff *skb,
                                               const struct tcphdr *th, u32 *tw_isn,
                                               enum skb_drop_reason *drop_reason)
{
    // PAWS 检查：确保包的时间戳在有效范围内
    paws_reject = tcp_paws_reject(&tmp_opt, th->rst);

    if (!paws_reject &&
        TCP_SKB_CB(skb)->seq == rcv_nxt &&
        (TCP_SKB_CB(skb)->seq == TCP_SKB_CB(skb)->end_seq || th->rst)) {
        if (th->rst) {
            // RFC 1337: 若 rfc1337=0，收到 RST 立即删除 TIME_WAIT
            if (!sysctl_tcp_rfc1337)
                goto kill;
            return TCP_TW_SUCCESS;
        }
        // 收到有效 ACK 或 FIN → 发送 ACK
        inet_twsk_reschedule(tw, TCP_TIMEWAIT_LEN);
        return TCP_TW_ACK;
    }

    if (th->syn && !before(TCP_SKB_CB(skb)->seq, rcv_nxt))
        return TCP_TW_RST;  // 收到新 SYN → 可以重建连接
}
```

### 6.4 TIME_WAIT 的作用

1. **可靠地实现 TCP 全双工连接的终止**：确保所有在网络中游荡的报文段在连接关闭前被吸收
2. **让旧连接的重复报文段在网络中消亡**：防止新连接被旧连接的数据混淆（通过 PAWS 检查）
3. **允许旧连接的 SYN+ACK 被拒绝**：新连接如果使用了旧序列号，会被 TIME_WAIT 状态的端口拒绝

## 7. 核心数据结构关系

```
sock (struct sock)
  └── sk_state           : TCP 状态枚举
  └── sk_prot            : tcp_prot
  └── sk_rcvbuf/sndbuf   : 接收/发送缓冲区

inet_sock (struct inet_sock)  : 嵌入 sock，IPv4 特有
  └── inet_sport / inet_dport : 源/目标端口
  └── inet_saddr / inet_daddr : 源/目标 IP

tcp_sock (struct tcp_sock)    : 嵌入 inet_sock
  └── write_seq               : 下一个要发送的序列号（初始 ISN）
  └── snd_nxt                 : 已发送但未确认的最大序列号
  └── snd_una                 : 已确认的最大序列号
  └── rcv_nxt                 : 已接收的最大序列号
  └── rcv_wnd                 : 接收窗口大小
  └── rx_opt                  : TCP 选项（MSS, window scale, TS...）

request_sock (struct request_sock) : listen socket 收到的连接请求
  └── ir_num / ir_rmt_port   : 本地端口 / 远端端口
  └── ir_rcv_nxt / ir_snd_nxt : 三次握手时记录的序列号
  └── rsk_refcnt              : 引用计数

inet_timewait_sock (struct inet_timewait_sock) : TIME_WAIT 状态
  └── tw_substate             : TCP_TIME_WAIT / TCP_FIN_WAIT2
  └── tw_rcv_nxt / tw_snd_nxt : 复制连接关闭时的序列号
```

## 8. 关键时序总结

| 步骤 | 函数 | 状态变化 | 关键操作 |
|------|------|---------|---------|
| `connect()` | `tcp_v4_connect()` | → TCP_SYN_SENT | 路由查找，源端口选择，ISN 生成 |
| 发 SYN | `tcp_connect()` | TCP_SYN_SENT | `write_seq` 写入 SYN，`snd_nxt = write_seq+1` |
| 收 SYN+ACK | `tcp_rcv_synsent_state_process()` | → TCP_ESTABLISHED | 验证 ack，更新 `rcv_nxt`，`tcp_finish_connect()` |
| 收 ACK | `tcp_rcv_state_process()` (SYN_RECV) | → TCP_ESTABLISHED | `snd_una` 更新，`rcv_synrecv` 完成 |
| 主动 close() | `tcp_close()` → `tcp_set_state()` | → FIN_WAIT1 | 发送 FIN，`snd_nxt++` |
| 收对方 FIN+ACK | `tcp_rcv_state_process()` | → FIN_WAIT2 | `snd_una` 更新 |
| 收对方 FIN | `tcp_rcv_state_process()` | → TIME_WAIT | `tcp_time_wait()` 创建 twsk，`timeo = 60s` |
| 60s 超时 | `inet_twsk_schedule()` | twsk 销毁 | 释放 timewait bucket |

## 9. 重传定时器

```c
// tcp_output.c:4391
tcp_reset_xmit_timer(sk, ICSK_TIME_RETRANS,
                     inet_csk(sk)->icsk_rto, false);
//   RTO 初始值 = max(1s, 200ms + 4 * MSS)，通常约 3s
//   指数退避：icsk_rto *= 1.3^retransmits
//   上限：TCP_RTO_MAX (120s)
```

SYN 发出后在 `ICSK_TIME_RETRANS` 超时重传，直到收到 SYN+ACK 或达到 `tcp_retries2`（默认 15 次，约 13~30 分钟）后放弃。


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

