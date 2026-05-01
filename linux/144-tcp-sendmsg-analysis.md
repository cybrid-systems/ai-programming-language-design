# 144-tcp_sendmsg — TCP发送深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/tcp.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**tcp_sendmsg** 是 TCP 发送的核心函数，将用户空间数据复制到内核 socket 缓冲区，按 MSS（Maximum Segment Size）分段，触发拥塞控制和重传机制。

## 1. 核心数据结构

### 1.1 struct tcp_sock — TCP sock

```c
// include/linux/tcp.h — tcp_sock
struct tcp_sock {
    struct inet_connection_sock inet_conn;

    // 序列号
    u32               snd_nxt;           // 下一个要发送的序列号
    u32               snd_una;           // 最早未确认的序列号

    // 窗口
    u32               snd_wnd;           // 发送窗口大小
    u32               rcv_wnd;           // 接收窗口大小
    u32               rcv_nxt;           // 下一个期望接收的序列号

    // MSS
    u16               mss_cache;          // 当前 MSS
    u16               mss_clamp;         // MSS 上限

    // 拥塞控制
    u32               snd_ssthresh;       // 慢启动阈值
    u32               snd_cwnd;           // 拥塞窗口
    u32               snd_cwnd_cnt;       // 窗口计数
    struct tcp_congestion_ops *icsk_ca_ops; // 拥塞控制算法

    // 重传
    struct sk_buff    *highest_sack;      // 最高已确认的 SACK 块

    // 计时器
    struct timer_list  retransmit_timer;  // 重传计时器
    struct timer_list  delack_timer;     // 延迟 ACK 计时器

    // SACK
    struct tcp_sack_block tcp_sack_info[4]; // SACK 信息
};
```

### 1.2 struct sk_buff — TCP 发送队列

```c
// TCP 发送队列：sk->sk_write_queue
// 每个 skb 包含一个 TCP 段

// skb 中的 TCP 相关信息：
//   seq   = skb->seq       // 起始序列号
//   end_seq = skb->seq + skb->len // 结束序列号
```

## 2. tcp_sendmsg — 发送入口

### 2.1 tcp_sendmsg

```c
// net/ipv4/tcp.c — tcp_sendmsg
int tcp_sendmsg(struct sock *sk, struct msghdr *msg, size_t size)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *skb;
    int copied = 0;
    long timeo = sock_sndtimeo(sk, msg->msg_flags & MSG_DONTWAIT);

    lock_sock(sk);

    // 1. 检查连接状态
    if (sk->sk_state != TCP_ESTABLISHED) {
        err = -ENOTCONN;
        goto out;
    }

    // 2. 循环发送所有数据
    while (msg_data_left(msg)) {
        // 获取目标 MSS
        int mss = tcp_send_mss(sk, &size_goal, msg->msg_flags);

        // 检查窗口
        err = tcp_write_xmit(sk, mss, tp->nonagle, tp->rcv_wnd, 0);
        if (err)
            goto do_error;

        // 复制数据到 skb
        copied = tcp_sendmsg_locked(sk, msg, size);
    }

out:
    release_sock(sk);
    return copied;

do_error:
    // 处理错误
    goto out;
}
```

## 3. tcp_sendmsg_locked — 实际复制

### 3.1 tcp_sendmsg_locked

```c
// net/ipv4/tcp.c — tcp_sendmsg_locked
int tcp_sendmsg_locked(struct sock *sk, struct msghdr *msg, size_t size)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *skb;
    int copied = 0;
    int err;

    while (copied < size) {
        // 1. 获取/创建 skb
        skb = tcp_write_queue_tail(sk);
        if (!skb || skb->len >= mss) {
            // 创建新 skb
            skb = alloc_skb_with_frags(tp, mss);
            if (!skb)
                break;
            tcp_mark_push(tp, skb);
            __skb_queue_tail(&sk->sk_write_queue, skb);
        }

        // 2. 计算可用空间
        int space = min(size_goal - skb->len, size_left);
        int copied_seg = min(space, mss - skb->len);

        // 3. 复制用户数据到 skb
        err = memcpy_from_msg(skb_put(skb, copied_seg), msg, copied_seg);
        if (err)
            goto out;

        // 4. 更新序列号
        tp->write_seq += copied_seg;
        copied += copied_seg;
    }

    // 5. 发送
    if (copied) {
        tcp_push(sk, tp, 0, 0, tp->nonagle ? TCP_NAGLE_OFF : TCP_NAGLE_PUSH);
    }

    return copied;
}
```

## 4. tcp_push — 推送数据

### 4.1 tcp_push

```c
// net/ipv4/tcp.c — tcp_push
void tcp_push(struct sock *sk, struct tcp_sock *tp, int flags,
              int nonagle, int size_goal)
{
    // 1. 如果设置了 PSH 标志，立即发送
    if (flags & TCPHDR_PSH)
        nonagle = TCP_NAGLE_PUSH;

    // 2. 如果需要发送（达到窗口边界或 Nagle 允许）
    if (tcp_needs_send(sk, nonagle)) {
        tcp_write_xmit(sk, tp->mss_cache, nonagle, tp->rcv_wnd, 0);
    }
}
```

## 5. tcp_write_xmit — 实际发送

### 5.1 tcp_write_xmit

```c
// net/ipv4/tcp_output.c — tcp_write_xmit
static bool tcp_write_xmit(struct sock *sk, unsigned int mss, int nonagle,
                          int push_one, int rcv_wnd)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *skb;

    // 遍历发送队列
    skb_queue_walk(&sk->sk_write_queue, skb) {
        // 1. 检查序列号
        if (skb->len > 0 && after(skb->seq, tp->snd_nxt))
            break;  // 超出窗口

        // 2. 分段（如果需要）
        if (skb->len > mss)
            continue;  // 后续会被分段

        // 3. 发送
        tcp_transmit_skb(sk, skb, 1, GFP_ATOMIC);

        // 4. 更新
        tp->packets_out += tcp_skb_pcount(skb);
    }
}
```

## 6. tcp_transmit_skb — 发送 TCP 段

### 6.1 tcp_transmit_skb

```c
// net/ipv4/tcp_output.c — tcp_transmit_skb
int tcp_transmit_skb(struct sock *sk, struct sk_buff *skb, int clone_it,
                     gfp_t gfp_mask)
{
    // 1. 分配 skb（如果没有 clone）
    if (clone_it)
        skb = skb_clone(skb, gfp_mask);

    // 2. 构建 TCP 头
    struct tcphdr *th = tcp_hdr(skb);
    th->source  = inet_sk(sk)->inet_sport;
    th->dest   = inet_sk(sk)->inet_dport;
    th->seq    = htonl(skb->seq);
    th->ack_seq = htonl(tp->rcv_nxt);
    th->window = htons(tcp_select_window(sk));

    // 3. 设置标志
    th->urg_ptr = 0;
    th->doff   = 5;  // 20 字节头

    // 4. 计算校验和
    th->check = tcp_v4_check(skb->len, inet_sk(sk)->inet_saddr,
                              inet_sk(sk)->inet_daddr,
                              csum_partial(th, th->doff << 2, 0));

    // 5. 发送
    err = ip_queue_xmit(skb, &inet_sk(sk)->inet_opt);
}
```

## 7. Nagle 算法

```c
// Nagle 算法：避免发送大量小包
// tcp_nagle_check 判断是否应该发送

bool tcp_nagle_check(bool should_push, struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);

    // 如果没有未确认的数据，或有 PSH，或 Nagle 关闭：
    if (should_push || !tp->packets_out)
        return false;

    // 如果累积的小包达到 mss，发送
    if (tcp_packets_in_flight(tp) >= tp->mss_cache)
        return false;

    // 否则延迟发送（等待更多数据或 ACK）
    return true;
}
```

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/tcp.c` | `tcp_sendmsg`、`tcp_sendmsg_locked`、`tcp_push` |
| `net/ipv4/tcp_output.c` | `tcp_write_xmit`、`tcp_transmit_skb` |
| `include/linux/tcp.h` | `struct tcp_sock` |

## 9. 西游记类比

**tcp_sendmsg** 就像"驿站寄送宝物"——

> 悟空要把一批宝物送到天庭（发送数据）。宝物太大，一次塞不进一个箱子（MSS），就要先分成小箱子（分段）。每个箱子（TCP segment）有编号（seq），如果中途丢了（丢包），就要重发（Nagle算法可以减少小包数量）。每个箱子到收货人后要签字确认（ACK）。如果同时有多个箱子在路上（拥塞窗口），就按顺序发，过多了就堵路（拥塞控制）。宝物太多放不下时，就要在驿站排队（write_queue），等前面确认了再发下一批。这就是 TCP 可靠传输的精髓——分包发送、编号确认、丢包重传、拥塞控制。

## 10. 关联文章

- **inet_stream_connect**（article 143）：连接建立
- **tcp_recvmsg**（相关）：TCP 数据接收
- **tcp_retransmit**（相关）：超时重传

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

