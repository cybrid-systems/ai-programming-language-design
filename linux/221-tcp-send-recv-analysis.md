# 221-tcp-send-recv-analysis — tcp_sendmsg / tcp_recvmsg 收发函数深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/tcp.c` + `net/ipv4/tcp_input.c` + `net/ipv4/tcp_output.c`）
> 关键词：TCP 发送 / 接收、MSG_MORE、zero-copy、out-of-order、skb_copy_datagram_iter

## 0. 概述

TCP 的发送和接收是内核网络栈中最核心的两个路径：

- **`tcp_sendmsg`**（`tcp.c:1450`）：将应用层数据复制到内核 SKB 并push到发送队列
- **`tcp_recvmsg`**（`tcp.c:2934`）：从接收队列取出 SKB，复制数据到用户缓冲区

两者都遵循"加锁 → 调用Locked版本 → 解锁"的外层模式，核心逻辑在 `*_locked` 函数中。

## 1. tcp_sendmsg 入口和 MSG_MORE 处理

### 1.1 外层 wrapper

```c
// net/ipv4/tcp.c:1450
int tcp_sendmsg(struct sock *sk, struct msghdr *msg, size_t size)
{
    int ret;

    lock_sock(sk);
    ret = tcp_sendmsg_locked(sk, msg, size);
    release_sock(sk);

    return ret;
}
EXPORT_SYMBOL(tcp_sendmsg);
```

外层只做锁管理，逻辑全在 `tcp_sendmsg_locked`（`tcp.c:1120`）。

### 1.2 MSG_MORE 的语义

应用层通过 `msg->msg_flags & MSG_MORE` 告知内核"还有更多数据要来"。在内核侧：

```c
// net/ipv4/tcp.c:753
if (!(flags & MSG_MORE) || forced_push(tp))
    tcp_mark_push(tp, skb);

// net/ipv4/tcp.c:695
static inline bool forced_push(const struct tcp_sock *tp)
{
    return after(tp->write_seq, tp->pushed_seq + (tp->max_window >> 1));
}
```

**MSG_MORE = 1**：不清除 PSH 标志，数据暂存于用户空间，不立即触发发送（Nagle 算法的 CORK 模式）

**MSG_MORE = 0**：调用 `tcp_push()`，强制将 pending 帧推送下去

`forced_push()` 是一个自适应的"半窗口"阈值：即使传了 MSG_MORE，只要已积累超过窗口一半，就强制 push。

### 1.3 发送主循环入口

```c
// net/ipv4/tcp.c:1234
tcp_rate_check_app_limited(sk);  /* is sending application-limited? */

// net/ipv4/tcp.c:1238 — 等待连接建立
if (((1 << sk->sk_state) & ~(TCPF_ESTABLISHED | TCPF_CLOSE_WAIT)) &&
    !tcp_passive_fastopen(sk)) {
    err = sk_stream_wait_connect(sk, &timeo);
    if (err != 0)
        goto do_error;
}

// net/ipv4/tcp.c:1246
restart:
mss_now = tcp_send_mss(sk, &size_goal, flags);
```

然后进入核心 `while (msg_data_left(msg))` 循环（`tcp.c:1248`），对每一块数据进行复制。

## 2. skb_append_data → skb_add_data 缓存逻辑

### 2.1 缓存 SKB 的复用

Linux 7.0 中没有名为 `skb_append_data` 的函数，数据追加逻辑直接在 `tcp_sendmsg_locked` 里实现：

```c
// net/ipv4/tcp.c:1249
while (msg_data_left(msg)) {
    int copy = 0;

    skb = tcp_write_queue_tail(sk);        // 取发送队列尾部 SKB
    if (skb)
        copy = size_goal - skb->len;      // 当前 SKB 剩余空间
```

如果 `copy <= 0`（SKB 满了）或者 `!tcp_skb_can_collapse_to(skb)`（不能扩张），则走 `new_segment` 分支申请新 SKB。

### 2.2 新 SKB 的分配

```c
// net/ipv4/tcp.c:1262
new_segment:
if (!sk_stream_memory_free(sk))
    goto wait_for_space;

if (unlikely(process_backlog >= 16)) {
    process_backlog = 0;
    if (sk_flush_backlog(sk))
        goto restart;
}

first_skb = tcp_rtx_and_write_queues_empty(sk);
skb = tcp_stream_alloc_skb(sk, sk->sk_allocation, first_skb);
if (!skb)
    goto wait_for_space;

process_backlog++;

tcp_skb_entail(sk, skb);                  // 关联到发送队列尾部
copy = size_goal;
```

`tcp_skb_entail`（`tcp.c:697`）将新 SKB 加入 `tcp_write_queue_tail`，并初始化 seq/end_seq。

### 2.3 skb_copy_to_page_nocache — 零拷贝准备

```c
// net/ipv4/tcp.c:1293
bool merge = true;
int i = skb_shinfo(skb)->nr_frags;

// net/ipv4/tcp.c:1297 — 检查能否合并到现有 fragment
if (!skb_can_coalesce(skb, i, pfrag->page, pfrag->offset)) {
    if (i >= READ_ONCE(net_hotdata.sysctl_max_skb_frags)) {
        tcp_mark_push(tp, skb);
        goto new_segment;                 // SKB 满了，创建新的
    }
    merge = false;
}

copy = tcp_wmem_schedule(sk, copy);      // 预借 send buffer 信用

// net/ipv4/tcp.c:1314 — 核心拷贝操作
err = skb_copy_to_page_nocache(sk, &msg->msg_iter, skb,
                               pfrag->page, pfrag->offset, copy);
```

`skb_copy_to_page_nocache` 直接将用户态 `iovec`/iter 数据拷贝到 SKB 的 page fragment，**不经过 CPU cache**（nocache），为后续 DMA 发送做准备。

### 2.4 数据追加后更新 SKB

```c
// net/ipv4/tcp.c:1317
if (merge) {
    skb_frag_size_add(&skb_shinfo(skb)->frags[i - 1], copy);
} else {
    skb_fill_page_desc(skb, i, pfrag->page,
                       pfrag->offset, copy);
    page_ref_inc(pfrag->page);
}
pfrag->offset += copy;

// net/ipv4/tcp.c:1378 — 更新 seq
WRITE_ONCE(tp->write_seq, tp->write_seq + copy);
TCP_SKB_CB(skb)->end_seq += copy;
tcp_skb_pcount_set(skb, 0);             // 重置分段计数，下次 TSO 时重新计算
```

### 2.5 循环退出条件

```c
// net/ipv4/tcp.c:1388
if (!msg_data_left(msg)) {               // 数据全部复制完毕
    if (unlikely(flags & MSG_EOR))
        TCP_SKB_CB(skb)->eor = 1;
    goto out;
}
```

## 3. tcp_push_pending_frames → tcp_write_xmit 发送

### 3.1 tcp_push — 外层触发点

```c
// net/ipv4/tcp.c:744
void tcp_push(struct sock *sk, int flags, int mss_now,
              int nonagle, int size_goal)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *skb;

    skb = tcp_write_queue_tail(sk);
    if (!skb)
        return;
    if (!(flags & MSG_MORE) || forced_push(tp))
        tcp_mark_push(tp, skb);

    tcp_mark_urg(tp, flags);

    if (tcp_should_autocork(sk, skb, size_goal)) {
        if (!test_bit(TSQ_THROTTLED, &sk->sk_tsq_flags)) {
            NET_INC_STATS(sock_net(sk), LINUX_MIB_TCPAUTOCORKING);
            set_bit(TSQ_THROTTLED, &sk->sk_tsq_flags);
            smp_mb__after_atomic();
        }
        // TSQ_THROTTLED 标记后，TX completion handler 会延迟触发
        if (refcount_read(&sk->sk_wmem_alloc) > skb->truesize)
            return;                      // 内存紧张，延迟发送
    }

    if (flags & MSG_MORE)
        nonagle = TCP_NAGLE_CORK;        // MSG_MORE 强化为 CORK

    __tcp_push_pending_frames(sk, mss_now, nonagle);
}
```

### 3.2 __tcp_push_pending_frames

```c
// net/ipv4/tcp_output.c:3233
void __tcp_push_pending_frames(struct sock *sk, unsigned int cur_mss,
                               int nonagle)
{
    // ... (调用 tcp_write_xmit)
    tcp_write_xmit(sk, cur_mss, nonagle, 0, sk->sk_allocation);
}
```

### 3.3 tcp_write_xmit — 实际发送

```c
// net/ipv4/tcp_output.c:2962
static bool tcp_write_xmit(struct sock *sk, unsigned int mss_now, int nonagle,
                           int push_one, gfp_t gfp)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *skb;
    unsigned int tso_segs, sent_pkts;
    u32 cwnd_quota, max_segs;

    tcp_mstamp_refresh(tp);

    // MTU probe（ping probe）
    if (!push_one) {
        result = tcp_mtu_probe(sk);
        if (!result)
            return false;
    }

    max_segs = tcp_tso_segs(sk, mss_now);
    while ((skb = tcp_send_head(sk))) {
        cwnd_quota = tcp_cwnd_test(tp);
        if (!cwnd_quota)
            break;                       // cwnd 满了，等 ACK

        cwnd_quota = min(cwnd_quota, max_segs);

        // TSO 分片
        tso_segs = tcp_set_skb_tso_segs(skb, mss_now);

        // 窗口检测
        if (unlikely(!tcp_snd_wnd_test(tp, skb, mss_now))) {
            is_rwnd_limited = true;
            break;
        }

        // Nagle 测试（决定是否合并多个小包）
        if (tso_segs == 1) {
            if (unlikely(!tcp_nagle_test(tp, skb, mss_now,
                             (tcp_skb_is_last(sk, skb) ?
                              nonagle : TCP_NAGLE_PUSH))))
                break;
        } else {
            if (!push_one &&
                tcp_tso_should_defer(sk, skb, &is_cwnd_limited,
                                     &is_rwnd_limited, max_segs))
                break;
        }

        // 发送单个 SKB
        if (unlikely(tcp_transmit_skb(sk, skb, 1, gfp)))
            break;

        tcp_event_new_data_sent(sk, skb); // 更新 packets_out 等统计
        sent_pkts += tcp_skb_pcount(skb);

        if (push_one)
            break;
    }
    // ...
}
```

`tcp_write_xmit` 的核心是一个 **`while ((skb = tcp_send_head(sk)))`** 循环，从发送队列头开始遍历，对每个 SKB 做 TSO分段、窗口检测、Nagle 测试，最终调用 `tcp_transmit_skb` 发包。

### 3.4 退出时触发延迟 ACK / loss probe

```c
// net/ipv4/tcp_output.c:3070
if (sent_pkts) {
    if (tcp_in_cwnd_reduction(sk))
        tp->prr_out += sent_pkts;
    if (push_one != 2)
        tcp_schedule_loss_probe(sk, false);
}
```

## 4. tcp_recvmsg 入口和 MSG_PEEK / MSG_WAITALL

### 4.1 外层 wrapper

```c
// net/ipv4/tcp.c:2934
int tcp_recvmsg(struct sock *sk, struct msghdr *msg, size_t len, int flags)
{
    int cmsg_flags = 0, ret;
    struct scm_timestamping_internal tss;

    if (unlikely(flags & MSG_ERRQUEUE))
        return inet_recv_error(sk, msg, len);

    if (sk_can_busy_loop(sk) &&
        skb_queue_empty_lockless(&sk->sk_receive_queue) &&
        sk->sk_state == TCP_ESTABLISHED)
        sk_busy_loop(sk, flags & MSG_DONTWAIT);

    lock_sock(sk);
    ret = tcp_recvmsg_locked(sk, msg, len, flags, &tss, &cmsg_flags);
    release_sock(sk);

    if ((cmsg_flags | msg->msg_get_inq) && ret >= 0) {
        if (cmsg_flags & TCP_CMSG_TS)
            tcp_recv_timestamp(msg, sk, &tss);
        if ((cmsg_flags & TCP_CMSG_INQ) | msg->msg_get_inq) {
            msg->msg_inq = tcp_inq_hint(sk);
            if (cmsg_flags & TCP_CMSG_INQ)
                put_cmsg(msg, SOL_TCP, TCP_CM_INQ, ...);
        }
    }
    return ret;
}
```

### 4.2 MSG_PEEK — 不破坏性读取

```c
// net/ipv4/tcp.c:2704
seq = &tp->copied_seq;
if (flags & MSG_PEEK) {
    peek_offset = max(sk_peek_offset(sk, flags), 0);
    peek_seq = tp->copied_seq + peek_offset;
    seq = &peek_seq;                     // 使用副本，不推进真实 consumed seq
}
```

**MSG_PEEK = 1**：用局部变量 `peek_seq` 而非 `tp->copied_seq`，读取后 SKB **不删除**

**MSG_PEEK = 0**：正常使用 `tp->copied_seq`，读取后调用 `tcp_eat_recv_skb` 删除 SKB

```c
// net/ipv4/tcp.c:2907
if (!(flags & MSG_PEEK))
    tcp_eat_recv_skb(sk, skb);           // 非 PEEK 模式：消费掉 SKB
```

### 4.3 MSG_WAITALL — 最小读取量控制

```c
// net/ipv4/tcp.c:2688
target = sock_rcvlowat(sk, flags & MSG_WAITALL, len);
```

`target` 是最小应读取字节数。如果接收队列没有足够数据：

```c
// net/ipv4/tcp.c:2811
if (copied >= target && !READ_ONCE(sk->sk_backlog.tail))
    break;                               // 已读够量，退出循环

// net/ipv4/tcp.c:2817 — 否则等待数据
err = sk_wait_data(sk, &timeo, last);
```

### 4.4 接收循环 do-while

```c
// net/ipv4/tcp.c:2698
do {
    u32 offset;

    // 检查 urgent data
    if (unlikely(tp->urg_data) && tp->urg_seq == *seq) {
        if (copied)
            break;
        if (signal_pending(current)) {
            copied = timeo ? sock_intr_errno(timeo) : -EAGAIN;
            break;
        }
    }

    // 遍历接收队列的 SKB 链表
    last = skb_peek_tail(&sk->sk_receive_queue);
    skb_queue_walk(&sk->sk_receive_queue, skb) {
        last = skb;
        offset = *seq - TCP_SKB_CB(skb)->seq;
        if (offset < skb->len)
            goto found_ok_skb;           // 找到含有所需数据的 SKB
        if (TCP_SKB_CB(skb)->tcp_flags & TCPHDR_FIN)
            goto found_fin_ok;
    }
    // ...
    // 需要等待：sk_wait_data() 阻塞
    tcp_cleanup_rbuf(sk, copied);
    err = sk_wait_data(sk, &timeo, last);
    // ...
} while (len > 0);
```

接收循环靠 `do { ... } while (len > 0)` 驱动：每次复制部分数据、减少 `len`，直到读完请求的字节数（或遇到 FIN）。

## 5. skb_recv_datagram → skb_copy_datagram_iter 拷贝

### 5.1 skb_copy_datagram_msg — 核心拷贝函数

Linux 7.0 中从 SKB 到用户缓冲区的拷贝路径是 `skb_copy_datagram_msg`（而不是 `skb_copy_datagram_iter`）：

```c
// net/ipv4/tcp.c:2844
if (skb_frags_readable(skb)) {
    err = skb_copy_datagram_msg(skb, offset, msg, used);
    if (err) {
        if (!copied)
            copied = -EFAULT;
        break;
    }
}
```

`skb_frags_readable` 判断 SKB 的 data 是否可以直接通过 `sg`方式传递给 `skb_copy_datagram_msg`。若不可读（dmabuf SKB），走 `tcp_recvmsg_dmabuf` 路径。

### 5.2 数据更新

```c
// net/ipv4/tcp.c:2871
WRITE_ONCE(*seq, *seq + used);            // 推进读取指针
copied += used;
len -= used;

// net/ipv4/tcp.c:2878
if (flags & MSG_PEEK)
    sk_peek_offset_fwd(sk, used);        // PEEK 模式：更新 peek offset 轨道
else
    sk_peek_offset_bwd(sk, used);         // 非 PEEK：回退 offset 轨道
tcp_rcv_space_adjust(sk);                // 调整 rcv_cwnd
```

### 5.3 tcp_cleanup_rbuf — 接收缓冲管理

```c
// net/ipv4/tcp.c:2917
tcp_cleanup_rbuf(sk, copied);
return copied;
```

`tcp_cleanup_rbuf` 在每次读取后更新 `sk_rcvbuf`、触发 window update ACK，告知对端可用接收窗口增大。

## 6. out-of-order SKB 处理（tcp_data_queue_ofo）

### 6.1 数据包乱序的两种处理路径

当数据包到达时序列号不是下一个期望的 seq，`tcp_data_queue`（`tcp_input.c:5574`）会将其送入 **out_of_order_queue**：

```c
// net/ipv4/tcp_input.c:5574
static void tcp_data_queue(struct sock *sk, struct sk_buff *skb)
{
    // ...
    if (TCP_SKB_CB(skb)->end_seq == tp->rcv_nxt ||
        before(TCP_SKB_CB(skb)->seq, tp->rcv_nxt)) {
        // 落在当前窗口内，走正常路径
    }

    /* Out of sequence packets to the out_of_order_queue. */
    tp->rcv_ooopack += max_t(u16, 1, skb_shinfo(skb)->gso_segs);
    NET_INC_STATS(sock_net(sk), LINUX_MIB_TCPOFOQUEUE);
    tcp_data_queue_ofo(sk, skb);         // 进入乱序队列
}
```

### 6.2 tcp_data_queue_ofo — 红黑树管理

```c
// net/ipv4/tcp_input.c:5348
static void tcp_data_queue_ofo(struct sock *sk, struct sk_buff *skb)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct rb_node **p, *parent;
    struct sk_buff *skb1;
    u32 seq, end_seq;

    // OOO queue 初始化时直接插入红黑树
    p = &tp->out_of_order_queue.rb_node;
    if (RB_EMPTY_ROOT(&tp->out_of_order_queue)) {
        if (tcp_is_sack(tp)) {
            tp->rx_opt.num_sacks = 1;
            tp->selective_acks[0].start_seq = seq;
            tp->selective_acks[0].end_seq = end_seq;
        }
        rb_link_node(&skb->rbnode, NULL, p);
        rb_insert_color(&skb->rbnode, &tp->out_of_order_queue);
        tp->ooo_last_skb = skb;
        goto end;
    }

    // 快速路径：追加到队列尾部（常见情况）
    if (tcp_ooo_try_coalesce(sk, tp->ooo_last_skb, skb, &fragstolen)) {
        kfree_skb_partial(skb, fragstolen);
        skb = NULL;
        goto add_sack;
    }

    // 一般情况：在红黑树中查找插入位置
    parent = NULL;
    while (*p) {
        parent = *p;
        skb1 = rb_to_skb(parent);
        if (before(seq, TCP_SKB_CB(skb1)->seq))
            p = &parent->rb_left;
        else
            p = &parent->rb_right;
    }
    // ...
    rb_insert_color(&skb->rbnode, &tp->out_of_order_queue);
```

Linux 使用 **红黑树**（`tp->out_of_order_queue`，`RB_ROOT`）管理乱序队列，保证插入/查找为 O(log N)。

### 6.3 乱序队列合并到接收队列

当后续数据到达填补了 gap 后，内核调用 `tcp_collapse_ofo_queue` 将连续块合并移入 `sk_receive_queue`：

```c
// net/ipv4/tcp_input.c:5853
skb = skb_rb_first(&tp->out_of_order_queue);
// 遍历所有 SKB，合并连续的段
while ((skb = skb_rb_first(&tp->out_of_order_queue)) != NULL) {
    if (after(tp->rcv_nxt, TCP_SKB_CB(skb)->seq))
        rb_erase(node, &tp->out_of_order_queue);
    else
        break;
}
```

## 7. zero-copy 路径（MSG_ZEROCOPY）

### 7.1 MSG_ZEROCOPY 识别

```c
// net/ipv4/tcp.c:1144
if ((flags & MSG_ZEROCOPY) && size) {
    if (msg->msg_ubuf) {
        uarg = msg->msg_ubuf;
        if (sk->sk_route_caps & NETIF_F_SG)
            zc = MSG_ZEROCOPY;
    } else if (sock_flag(sk, SOCK_ZEROCOPY)) {
        skb = tcp_write_queue_tail(sk);
        uarg = msg_zerocopy_realloc(sk, size, skb_zcopy(skb), ...);
        if (!uarg) {
            err = -ENOBUFS;
            goto out_err;
        }
        if (sk->sk_route_caps & NETIF_F_SG)
            zc = MSG_ZEROCOPY;
        else
            uarg_to_msgzc(uarg)->zerocopy = 0;
    }
}
```

关键条件：socket 必须设置了 `SOCK_ZEROCOPY` flag，且网卡必须有 `NETIF_F_SG`（scatter-gather）能力。

### 7.2 skb_zerocopy_iter_stream — 零拷贝核心

```c
// net/ipv4/tcp.c:1330
} else if (zc == MSG_ZEROCOPY)  {
    if (!skb->len)
        skb_shinfo(skb)->flags |= SKBFL_PURE_ZEROCOPY;

    if (!skb_zcopy_pure(skb)) {
        copy = tcp_wmem_schedule(sk, copy);
        if (!copy)
            goto wait_for_space;
    }

    err = skb_zerocopy_iter_stream(sk, skb, msg, copy, uarg,
                                   binding);
    if (err == -EMSGSIZE || err == -EEXIST) {
        tcp_mark_push(tp, skb);
        goto new_segment;
    }
    if (err < 0)
        goto do_error;
    copy = err;
}
```

`skb_zerocopy_iter_stream` 将用户态的 iovec 直接映射到 SKB 的 frags，**不经过 CPU 拷贝**，数据由网卡 DMA 直接发送。

### 7.3 pure zerocopy 标记

```c
// net/ipv4/tcp.c:1331
if (!skb->len)
    skb_shinfo(skb)->flags |= SKBFL_PURE_ZEROCOPY;
```

首次追加到空 SKB 时标记 `SKBFL_PURE_ZEROCOPY`，表示整个 SKB 无需 CPU 参与复制（全部 zerocopy）。

### 7.4 SOCK_ZEROCOPY socket 选项

用户通过 `setsockopt(sock, SOL_SOCKET, SO_ZEROCOPY, &val, sizeof(val))` 设置 `SOCK_ZEROCOPY`。内核在 `tcp_sendmsg_locked` 中检查该 flag，决定是否走 zerocopy 路径。

### 7.5 MSG_SPLICE_PAGES — 另一种零拷贝

```c
// net/ipv4/tcp.c:1177
} else if (unlikely(msg->msg_flags & MSG_SPLICE_PAGES) && size) {
    if (sk->sk_route_caps & NETIF_F_SG)
        zc = MSG_SPLICE_PAGES;
```

Linux 6.6+ 引入的 `MSG_SPLICE_PAGES`，将用户页直接从 `msg->msg_iter` splice 进 SKB，绕过 copy。

## 8. 关键数据结构汇总

| 数据结构 | 位置 | 用途 |
|---|---|---|
| `struct tcp_sock` | `include/net/tcp.h` | TCP per-socket 状态 |
| `tp->write_seq` | `tcp.c:1379` | 下一个待发送字节的序列号 |
| `tp->copied_seq` | `tcp.c:2705` | 已接收确认的字节序列号 |
| `tp->out_of_order_queue` | `tcp_input.c:5348` | 红黑树管理乱序包 |
| `tp->pushed_seq` | `tcp.c:695` | 已 push 的最大 seq |
| `sk->sk_receive_queue` | `tcp.c:2700` | 接收数据 SKB 链表 |
| `struct sk_buff` | `include/linux/skbuff.h` | 网络数据包 buffer |

## 9. 流程总览

```
用户空间 sendmsg()
  └─ tcp_sendmsg()                    [tcp.c:1450]
       └─ lock_sock()
            └─ tcp_sendmsg_locked()   [tcp.c:1120]
                 ├─ 解析 MSG_ZEROCOPY / MSG_MORE
                 ├─ while (msg_data_left())     [tcp.c:1248]
                 │    ├─ 取 send_queue 尾 SKB
                 │    ├─ skb_copy_to_page_nocache() 复制数据
                 │    └─ 更新 write_seq / skb->end_seq
                 └─ out:
                      tcp_push() → __tcp_push_pending_frames()
                           └─ tcp_write_xmit()  [tcp_output.c:2962]
                                ├─ TSO 分段 (tcp_set_skb_tso_segs)
                                ├─ Nagle 检测 (tcp_nagle_test)
                                └─ tcp_transmit_skb() → NIC DMA

用户空间 recvmsg()
  └─ tcp_recvmsg()                    [tcp.c:2934]
       ├─ lock_sock()
       │    └─ tcp_recvmsg_locked()   [tcp.c:2659]
       │         ├─ do { ... } while (len > 0)
       │         │    ├─ 遍历 sk_receive_queue
       │         │    ├─ skb_copy_datagram_msg() 复制到用户
       │         │    ├─ 更新 copied_seq / copied
       │         │    └─ PEEK vs 消费模式
       │         └─ tcp_cleanup_rbuf() 更新 rcv window
       └─ TCP_CMSG_INQ 返回 inq hint
```

## 10. 与旧版本的主要差异

Linux 7.0-rc1 对比 5.x 的主要变化：

- **MSG_SPLICE_PAGES**：新增的零拷贝路径，通过 `skb_splice_from_iter` 直接从用户页构建 SKB frags
- **AccECN（Accurate ECN）**：发送路径加入了 `tcp_accecn_option_beacon_check` 校验（`tcp_output.c:2978`）
- **`tcp_stream_alloc_skb` 的 `first_skb` 参数**：指示是否清空所有重传队列，用于 TSO 优化
- **pure zerocopy SKB 标记**：`SKBFL_PURE_ZEROCOPY` + `SKBFL_SHARED_FRAG`，区分纯零拷贝和普通 zerocopy SKB
- **tsorted_sent_queue 排序**：`tcp_event_new_data_sent` 用 TSQ 机制延迟发送，避免过度唤醒 TX softirq

> 分析基于 Linux 7.0-rc1 主线源码，commit 约 2025 年初版本。
> 相关文件：`net/ipv4/tcp.c`（5389行）、`net/ipv4/tcp_input.c`、`net/ipv4/tcp_output.c`。


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

