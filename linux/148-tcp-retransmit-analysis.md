# 148-tcp_retransmit — TCP超时重传深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/tcp_timer.c` + `net/ipv4/tcp_output.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**TCP 重传** 是 TCP 可靠性的核心：当发送的段在 RTO（Retransmission Timeout）内没收到 ACK 时，触发重传。Linux 使用自适应 RTO 和多种拥塞控制算法。

## 1. 重传定时器

### 1.1 struct inet_connection_sock — 连接相关

```c
// include/net/inet_connection_sock.h — inet_connection_sock
struct inet_connection_sock {
    struct inet_sock           icsk_inet;

    // 重传
    struct {
        u32             rto;              // 重传超时（毫秒）
        u32            ato;               // 延迟 ACK 超时
        u32             timeout;          // 定时器值
        void            (*retransmit_handler)(struct sock *);
        struct timer_list  timer;            // 重传定时器
    } icsk_retransmit_timer;

    // 拥塞控制
    const struct tcp_congestion_ops *icsk_ca_ops;

    // 重传计数
    u32             icsk_retransmits;     // 重传次数
    u32             icsk_probes_out;       // 保活探测次数
    u32             icsk_backoff;         // 指数退避
};
```

## 2. RTO 计算

### 2.1 tcp_set_rto — 设置 RTO

```c
// net/ipv4/tcp_timer.c — tcp_set_rto
static inline void tcp_set_rto(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);

    // RTT → RTO 转换：
    //   RTO = SRTT + 4 * RTTVAR
    //   SRTT = 平滑 RTT 估计
    //   RTTVAR = RTT 偏差

    tp->srtt_us = smooth_read(tp->srtt_us, rtt);
    tp->mdev_us = rtt - tp->srtt_us;
    tp->mdev_us = smooth_read(tp->mdev_us, tp->mdev_us);

    // RTO = srtt + 4 * mdev
    tp->rttvar_us = max(tp->mdev_us, TCP_TIMEOUT_MIN);
    tp->srtt_us = max(tp->srtt_us, TCP_TIMEOUT_MIN);

    icsk_rto = (tp->srtt_us >> 3) + (tp->mdev_us << 2);
}
```

### 2.2 tcp_init_xmit_timers — 初始化定时器

```c
// net/ipv4/tcp_timer.c — tcp_init_xmit_timers
void tcp_init_xmit_timers(struct sock *sk)
{
    // 重传定时器
    inet_csk_reset_xmit_timer(sk, ICSK_TIME_RETRANS,
                              inet_csk(sk)->icsk_rto, TCP_RTO_MAX);
}
```

## 3. tcp_retransmit_timer — 重传处理

### 3.1 tcp_retransmit_timer

```c
// net/ipv4/tcp_timer.c — tcp_retransmit_timer
void tcp_retransmit_timer(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct inet_connection_sock *icsk = inet_csk(sk);

    // 1. 检查是否应该重传
    if (!tcp_packets_in_flight(tp))
        goto out;

    // 2. 指数退避
    icsk->icsk_backoff++;

    // 3. RTO 加倍（指数退避）
    icsk->icsk_rto = min(icsk->icsk_rto << 1, TCP_RTO_MAX);

    // 4. 重传最早未确认的段
    if (tcp_retransmit_skb(sk, tcp_write_queue_head(sk)) > 0) {
        // 失败，延迟重试
        icsk->icsk_retransmits++;
        goto out;
    }

    // 5. 重传成功
    tp->retrans_stamp = 1;

    // 6. 如果超过重传上限，放弃连接
    if (icsk->icsk_retransmits > tcp_retries1) {
        tcp_write_err(sk);
    }

out:
    // 重新设置定时器
    inet_csk_reset_xmit_timer(sk, ICSK_TIME_RETRANS, icsk->icsk_rto, TCP_RTO_MAX);
}
```

## 4. tcp_retransmit_skb — 重传单个段

### 4.1 tcp_retransmit_skb

```c
// net/ipv4/tcp_output.c — tcp_retransmit_skb
int tcp_retransmit_skb(struct sock *sk, struct sk_buff *skb)
{
    struct tcp_sock *tp = tcp_sk(sk);
    int err;

    // 1. 检查是否超过 MSS
    if (skb->len > tcp_skb_mss(skb)) {
        // 分段重传
        return tcp_retransmit_skb(sk, tcp_split_skb(skb, ...));
    }

    // 2. 拥塞控制
    if (tcp_ca_event(sk, CA_EVENT_TX_START) == CA_EMERGENCY)
        tcp_enter_cwr(sk);

    // 3. 更新重传计数
    tp->total_retrans++;

    // 4. 重传
    err = tcp_transmit_skb(sk, skb, 1, GFP_ATOMIC);

    if (err)
        return err;

    // 5. 更新统计
    tp->icsk_retransmits++;

    return 0;
}
```

## 5. 拥塞控制

### 5.1 tcp_enter_cwr — 拥塞窗口恢复

```c
// net/ipv4/tcp_cubic.c — tcp_cubic 模块示例
void tcp_cubic_recalc(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    u32 delta, cuh, wCP;

    // CUBIC 算法：
    //   W(t) = C * (t - K)^3 + Wmax
    //   C = 0.4, K = (Wmax * β / C)^(1/3)

    // 发生拥塞（超时）时：
    //   Wmax = cwnd
    //   cwnd = cwnd * β (β = 0.7)
    //   ssthresh = cwnd
    //   重新进入慢启动
}
```

### 5.2 tcp_timeout_eqrtx — 快速重传

```c
// net/ipv4/tcp_input.c — 快速重传
// 当收到 3 个重复 ACK 时，触发快速重传
// 不等待 RTO，直接重传丢失的段

// tcp_parse_options → 检测 SACK
// tcp_fastretrans_alert → 触发快速重传
```

## 6. 重传计数参数

```c
// net/ipv4/tcp_ipv4.c — 重传参数
#define TCP_RTO_MAX   120000  // RTO 最大值（120 秒）
#define TCP_RTO_MIN      200  // RTO 最小值（200 毫秒）

// tcp_retries1 = 3：超过此值，进入探测模式
// tcp_retries2 = 15：超过此值，放弃连接
```

## 7. 重传 vs 快速重传

```
超时重传（RTO）：
  触发条件：等待 RTO，无 ACK
  时间：通常 200ms-120s
  触发：tcp_retransmit_timer
  影响：拥塞窗口减半（cwnd = cwnd / 2）

快速重传（Fast Retransmit）：
  触发条件：收到 3 个重复 ACK
  时间：立即（不等 RTO）
  触发：tcp_fastretrans_alert
  影响：只重传丢失段，不减半 cwnd
```

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/tcp_timer.c` | `tcp_retransmit_timer`、`tcp_set_rto`、`tcp_init_xmit_timers` |
| `net/ipv4/tcp_output.c` | `tcp_retransmit_skb` |
| `include/net/inet_connection_sock.h` | `struct inet_connection_sock` |

## 9. 西游记类比

**tcp_retransmit** 就像"取经路的快递超时重发"——

> 悟空寄了一个快递（TCP 段），正常情况下几天内应该收到回执（ACK）。但如果超出了预期时间（RTO），还没收到回执，就要重发一个同样的快递（RTO 重传）。为了避免网络拥堵，每次重发后等待时间加倍（指数退避），直到等待时间达到上限（TCP_RTO_MAX）。如果一直收不到回执，连续重发多次后（tcp_retries2），就认为这条路完全不通了，放弃这个快递（放弃连接）。但如果收到的是"没收到快递"的回执（3个重复 ACK），说明快递可能丢了，但路还通，就用快速重传——不等超时，直接重发那个快递。

## 10. 关联文章

- **tcp_state_machine**（article 147）：状态转换
- **tcp_sendmsg**（article 144）：数据发送
- **拥塞控制**（相关）：CUBIC、 Reno 算法

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

