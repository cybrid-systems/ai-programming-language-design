# udp_sendmsg / udp_recvmsg — UDP 收发函数分析

> 基于 Linux 7.0-rc1 内核源码，`net/ipv4/udp.c`（含 IPv6 路径）

## 1. udp_sendmsg 入口和 ip_append_data 路径

`udp_sendmsg`（[第 1233 行](#1233)）是 IPv4 UDP 发送的主入口。完整签名：

```c
// net/ipv4/udp.c:1233
int udp_sendmsg(struct sock *sk, struct msghdr *msg, size_t len)
```

### 1.1 快速路径（非 Corking）

当 **socket 未被 corking**（即 `MSG_MORE` 未置位且 `UDP_CORK` sockopt 未开启），走快速路径，直接构建并发送单个 skb：

```c
// net/ipv4/udp.c:1437–1443
if (!corkreq) {
    struct inet_cork cork;

    skb = ip_make_skb(sk, fl4, ip_generic_getfrag, msg, ulen,
                      sizeof(struct udphdr), &ipc, &rt,
                      &cork, msg->msg_flags);
    err = PTR_ERR(skb);
    if (!IS_ERR_OR_NULL(skb))
        err = udp_send_skb(skb, fl4, &cork);   // ← 实际发送
    goto out;
}
```

`ip_make_skb` 在内核网络栈中负责分配 skb、填充 IP 头、调用 `ip_generic_getfrag`（[第 1230 行](#1230)）从用户态 `iovec` 复制数据。复制完成后立即通过 `udp_send_skb` 发送。

### 1.2 Corking 路径（ip_append_data）

当应用显式设置 `UDP_CORK` 或传入 `MSG_MORE` 标志时，数据被"软 Cork"在 socket 写队列中，**不立即发送**，等待后续 `udp_push_pending_frames` 触发。

```c
// net/ipv4/udp.c:1459–1475
fl4 = &inet->cork.fl.u.ip4;
fl4->daddr  = daddr;
fl4->saddr  = saddr;
fl4->fl4_dport = dport;
fl4->fl4_sport = inet->inet_sport;
WRITE_ONCE(up->pending, AF_INET);   // 标记 AF_INET pending

do_append_data:
up->len += ulen;
err = ip_append_data(sk, fl4, ip_generic_getfrag, msg, ulen,
                     sizeof(struct udphdr), &ipc, &rt,
                     corkreq ? msg->msg_flags|MSG_MORE : msg->msg_flags);
if (err)
    udp_flush_pending_frames(sk);
else if (!corkreq)
    err = udp_push_pending_frames(sk);   // 非 cork 模式，立即 push
else if (unlikely(skb_queue_empty(&sk->sk_write_queue)))
    WRITE_ONCE(up->pending, 0);
```

`ip_append_data`（位于 `net/ipv4/ip_output.c`）负责将用户数据分片组装到 `sk->sk_write_queue` 上的多个 skb 中。它会反复调用 `ip_generic_getfrag` 从用户态 `iovec` 复制数据，每次处理一个 fragment，直到凑满一个 mtu 单元或用户所有数据复制完毕。

关键设计点：
- `up->pending` 记录当前 corking 状态：`AF_INET`（IPv4）或 `AF_INET6`（IPv6）。
- `up->len` 累加本次 `udp_sendmsg` 传入的 `ulen`（原始数据长度 + sizeof(struct udphdr)）。
- 如果 `ip_append_data` 失败，调用 `udp_flush_pending_frames`（[第 1017 行](#1017)）清空所有 pending 帧。

## 2. udp_push_pending_frames → udp_send_skb

```c
// net/ipv4/udp.c:1177
int udp_push_pending_frames(struct sock *sk)
{
    struct udp_sock  *up = udp_sk(sk);
    struct inet_sock *inet = inet_sk(sk);
    struct flowi4 *fl4 = &inet->cork.fl.u.ip4;
    struct sk_buff *skb;
    int err = 0;

    skb = ip_finish_skb(sk, fl4);   // 从写队列取出一个完整报文
    if (!skb)
        goto out;

    err = udp_send_skb(skb, fl4, &inet->cork.base);

out:
    up->len = 0;
    WRITE_ONCE(up->pending, 0);
    return err;
}
```

`ip_finish_skb`（`net/ipv4/ip_output.c`）从 `sk->sk_write_queue` 取出一个完整的 IP 报文 skb，然后交由 `udp_send_skb` 完成最后的 UDP 头填充和校验和计算。

### udp_send_skb — UDP 头填充与校验和

```c
// net/ipv4/udp.c:1092
static int udp_send_skb(struct sk_buff *skb, struct flowi4 *fl4,
                        struct inet_cork *cork)
{
    struct udphdr *uh;
    int offset = skb_transport_offset(skb);
    int len = skb->len - offset;
    int datalen = len - sizeof(*uh);

    uh = udp_hdr(skb);
    uh->source = inet_sk(sk)->inet_sport;
    uh->dest   = fl4->fl4_dport;
    uh->len    = htons(len);
    uh->check  = 0;   // 校验和字段先清零

    // GSO（UDP Fragmentation Offload）处理
    if (cork->gso_size) {
        skb_shinfo(skb)->gso_size = cork->gso_size;
        skb_shinfo(skb)->gso_type = SKB_GSO_UDP_L4;
        skb_shinfo(skb)->gso_segs = DIV_ROUND_UP(datalen, cork->gso_size);
        goto csum_partial;
    }

    if (sk->sk_no_check_tx) {          // 用户禁用 UDP 校验和
        skb->ip_summed = CHECKSUM_NONE;
        goto send;
    } else if (skb->ip_summed == CHECKSUM_PARTIAL) {  // 硬件校验和
csum_partial:
        udp4_hwcsum(skb, fl4->saddr, fl4->daddr);
        goto send;
    }

    // 软件校验和
    uh->check = csum_tcpudp_magic(fl4->saddr, fl4->daddr, len,
                                  IPPROTO_UDP, udp_csum(skb));
    if (uh->check == 0)
        uh->check = CSUM_MANGLED_0;   // 0 表示"已置零"，改为 -0

send:
    err = ip_send_skb(sock_net(sk), skb);
    // ...
}
```

**三层校验和处理：**

| 情况 | `uh->check` 值 | `ip_summed` |
|------|---------------|-------------|
| 用户 `SO_NO_CHECK` | 不填（直接丢弃） | `CHECKSUM_NONE` |
| 硬件分段（CHECKSUM_PARTIAL） | 调用 `udp4_hwcsum` 计算 | `CHECKSUM_PARTIAL` |
| 软件计算 | `csum_tcpudp_magic` | 隐式计算后填入 |

## 3. MSG_CONFIRM 确认机制

`MSG_CONFIRM` 是 BSD socket API 的一个标志，用于告诉内核"对端已确认收到了之前的报文"，从而避免 ARP/ND 表项在规定时间内被删除（维持邻居缓存条目）。

在 `udp_sendmsg` 中的处理：

```c
// net/ipv4/udp.c:1426
if (msg->msg_flags & MSG_CONFIRM)
    goto do_confirm;
back_from_confirm:

// net/ipv4/udp.c:1499
do_confirm:
    if (msg->msg_flags & MSG_PROBE)
        dst_confirm_neigh(&rt->dst, &fl4->daddr);
    if (!(msg->msg_flags & MSG_PROBE) || len)
        goto back_from_confirm;
    err = 0;
    goto out;
```

流程：

1. **快速路径（无 cork）**：先执行 `ip_make_skb` → `udp_send_skb`，最后在 `MSG_CONFIRM` 分支调用 `dst_confirm_neigh`。
2. **Corking 路径**：`MSG_CONFIRM` 跳到 `do_confirm` **在 `ip_append_data` 之前**，在数据发送前先确认邻居条目，避免数据报文因 ARP 缺失而被丢弃。

> 注意：`MSG_CONFIRM` 和 `MSG_PROBE` 行为略有差异。`MSG_PROBE` 用于探路，不带数据时不触发回退。

IPv6 路径（`net/ipv6/udp.c:1696`）逻辑相同：

```c
if (msg->msg_flags & MSG_CONFIRM)
    goto do_confirm;
back_from_confirm:
    // 快速路径或 cork 路径
```

## 4. udp_recvmsg 入口（__udp_recvmsg）

Linux 没有独立的 `__udp_recvmsg`（BSD 层），只有 `udp_recvmsg`（[第 2023 行](#2023)）：

```c
// net/ipv4/udp.c:2023
int udp_recvmsg(struct sock *sk, struct msghdr *msg, size_t len, int flags)
{
    int off, err, peeking = flags & MSG_PEEK;
    unsigned int ulen, copied;
    struct sk_buff *skb;

    if (flags & MSG_ERRQUEUE)
        return ip_recv_error(sk, msg, len);   // 先处理 socket error queue

try_again:
    off = sk_peek_offset(sk, flags);
    skb = __skb_recv_udp(sk, flags, &off, &err);  // ← 从 receive queue 取 skb
    if (!skb)
        return err;

    ulen = udp_skb_len(skb);
    copied = len;
    if (copied > ulen - off)
        copied = ulen - off;              // 缓冲区不足则截断，设 MSG_TRUNC
    else if (copied < ulen)
        msg->msg_flags |= MSG_TRUNC;

    // 校验和处理（见第 6 节）
    if (copied < ulen || peeking) {
        checksum_valid = udp_skb_csum_unnecessary(skb) ||
                        !__udp_lib_checksum_complete(skb);
        if (!checksum_valid)
            goto csum_copy_err;
    }

    // 数据复制到用户态
    if (checksum_valid || udp_skb_csum_unnecessary(skb)) {
        if (udp_skb_is_linear(skb))
            err = copy_linear_skb(skb, copied, off, &msg->msg_iter);
        else
            err = skb_copy_datagram_msg(skb, off, msg, copied);
    } else {
        err = skb_copy_and_csum_datagram_msg(skb, off, msg);
        if (err == -EINVAL)
            goto csum_copy_err;
    }

    // 统计
    if (!peeking)
        UDP_INC_STATS(net, UDP_MIB_INDATAGRAMS);

    // 填充发送端地址
    if (sin) {
        sin->sin_family = AF_INET;
        sin->sin_port   = udp_hdr(skb)->source;
        sin->sin_addr.s_addr = ip_hdr(skb)->saddr;
        msg->msg_namelen = sizeof(*sin);
    }

    skb_consume_udp(sk, skb, peeking ? -err : err);
    return err;

csum_copy_err:
    // 校验和失败，丢弃 skb 并重试
    __sk_queue_drop_skb(sk, &udp_sk(sk)->reader_queue, skb, flags, ...);
    cond_resched();
    msg->msg_flags &= ~MSG_TRUNC;
    goto try_again;
}
```

## 5. skb_recv_datagram 和 socket 缓冲区管理

实际取 skb 的函数是 `__skb_recv_udp`（[第 1923 行](#1923)），不是已废弃的 `skb_recv_datagram`：

```c
// net/ipv4/udp.c:1923
struct sk_buff *__skb_recv_udp(struct sock *sk, unsigned int flags,
                               int *off, int *err)
{
    struct sk_buff_head *sk_queue = &sk->sk_receive_queue;
    struct sk_buff_head *queue = &udp_sk(sk)->reader_queue;
    long timeo = sock_rcvtimeo(sk, flags & MSG_DONTWAIT);

    do {
        // 1. 先从 reader_queue 尝试取（PEEK 模式先查后取）
        spin_lock_bh(&queue->lock);
        skb = __skb_try_recv_from_queue(queue, flags, off, err, &last);
        if (skb) {
            if (!(flags & MSG_PEEK))
                udp_skb_destructor(sk, skb);   // 非 PEEK 模式出队
            spin_unlock_bh(&queue->lock);
            return skb;
        }

        // 2. reader_queue 空，将 socket 全局 receive_queue 合并过来
        spin_lock(&sk_queue->lock);
        skb_queue_splice_tail_init(sk_queue, queue);  // splice 到 reader_queue
        spin_unlock(&sk_queue->lock);

        // 3. 从合并后的 reader_queue 再尝试取
        skb = __skb_try_recv_from_queue(queue, flags, off, err, &last);
        if (skb && !(flags & MSG_PEEK))
            udp_skb_dtor_locked(sk, skb);
        spin_unlock_bh(&queue->lock);
        if (skb)
            return skb;

        // 4. 队列全空，等待新数据或超时
    } while (timeo && __skb_wait_for_more_packets(sk, ...));

    *err = error;
    return NULL;
}
```

**缓冲区管理设计：**

- `sk->sk_receive_queue`：socket 全局接收队列，所有新到达的 UDP 数据报首先进入这里。
- `udp_sk(sk)->reader_queue`：每个 UDP socket 的"读者队列"，用于支持 `MSG_PEEK` 特性。
- `__skb_try_recv_from_queue` 从队列中取出匹配的 skb，`MSG_PEEK` 时只查看不删除（通过引用计数）。
- 数据包按 `reader_queue` → `sk_receive_queue` 的顺序查找。

**超时控制：** `sock_rcvtimeo` 根据 socket 的 `SO_RCVTIMEO` 选项计算超时时间，`MSG_DONTWAIT` 时为 0，直接返回 `-EAGAIN`。

## 6. checksum 处理（MSG_PEEK + CHECKSUM_COMPLETE）

UDP 接收时的校验和处理是出错重试机制的核心（[第 2047–2057 行](#2047)）：

```c
// net/ipv4/udp.c:2047
if (copied < ulen || peeking) {
    checksum_valid = udp_skb_csum_unnecessary(skb) ||
                    !__udp_lib_checksum_complete(skb);
    if (!checksum_valid)
        goto csum_copy_err;   // 校验和失败，丢弃后重试
}
```

**何时检查校验和：**
- 接收缓冲区小于实际数据（`copied < ulen`）——需要完整数据时。
- `MSG_PEEK` ——只查看不消费，必须保证数据正确。

**校验和可能的 `ip_summed` 状态：**

| 状态 | 含义 | `udp_skb_csum_unnecessary` |
|------|------|--------------------------|
| `CHECKSUM_NONE` | 没有校验和（IPv6 报文） | `true`（IPv4 全零头也跳过） |
| `CHECKSUM_UNNECESSARY` | 网卡已校验过 | `true` |
| `CHECKSUM_COMPLETE` | skb 已经完整在校验和计算 | 调用 `__udp_lib_checksum_complete` 验证 |

**CHECKSUM_COMPLETE 陷阱：**
```c
// net/ipv4/udp.c:2540（udp_lib_setsockopt 相关代码）
if (skb->ip_summed == CHECKSUM_COMPLETE && !skb->csum_valid) {
    UDP_INC_STATS(net, UDP_MIB_CSUMERRORS);
    UDP_INC_STATS(net, UDP_MIB_INERRORS);
    goto csum_copy_err;
}
```
当网卡计算校验和后发现结果无效（`csum_valid = false`），说明数据在传输中损坏，即使 `MSG_PEEK` 模式也要丢弃该 skb。

**出错重试流程（`csum_copy_err` → `goto try_again`）：**

```c
// net/ipv4/udp.c:2076
csum_copy_err:
    if (!__sk_queue_drop_skb(sk, &udp_sk(sk)->reader_queue, skb, flags,
                              udp_skb_destructor)) {
        UDP_INC_STATS(net, UDP_MIB_CSUMERRORS);
        UDP_INC_STATS(net, UDP_MIB_INERRORS);
    }
    kfree_skb_reason(skb, SKB_DROP_REASON_UDP_CSUM);
    cond_resched();
    msg->msg_flags &= ~MSG_TRUNC;
    goto try_again;   // 重新从 receive queue 取下一个 skb
```

注意：`__sk_queue_drop_skb` 用于正确地从 `reader_queue` 中摘除 skb（因为 `MSG_PEEK` 模式下 skb 还挂在队列上），确保下一个 skb 能被正确取到。

## 7. IPv6 UDP 路径（udpv6_sendmsg / udpv6_recvmsg）

### 7.1 udpv6_sendmsg（net/ipv6/udp.c:1456）

IPv6 发送路径与 IPv4 基本一致，关键差异在于：

1. **地址类型**：`struct sockaddr_in6`，使用 `struct flowi6` 而非 `flowi4`。
2. **IPv4-mapped IPv6 地址**：当目标地址是 `::ffff:a.b.c.d` 格式时，回退到 `udp_sendmsg`：
   ```c
   // net/ipv6/udp.c:1527
   if (ipv6_addr_v4mapped(daddr)) {
       // ... 构造 sockaddr_in ...
       goto do_udp_sendmsg;      // → ipv4 路径
   }
   ```
3. **Flowlabel**：IPv6 使用 20-bit flowlabel（`fl6->flowlabel`），在 `ip6_make_skb` / `ip6_append_data` 时通过 `ip6_make_flowinfo` 生成。
4. **Corking**：`up->pending == AF_INET6` 时走 IPv6 专用路径。

```c
// net/ipv6/udp.c:1713
WRITE_ONCE(up->pending, AF_INET6);

do_append_data:
    up->len += ulen;
    err = ip6_append_data(sk, ip_generic_getfrag, msg, ulen,
                          sizeof(struct udphdr), &ipc6, fl6,
                          dst_rt6_info(dst), ...);
    if (err)
        udp_v6_flush_pending_frames(sk);
    else if (!corkreq)
        err = udp_v6_push_pending_frames(sk);
```

### 7.2 udpv6_recvmsg（net/ipv6/udp.c:464）

```c
// net/ipv6/udp.c:464
int udpv6_recvmsg(struct sock *sk, struct msghdr *msg, size_t len, int flags)
{
    int off, is_udp4, err, peeking = flags & MSG_PEEK;
    unsigned int ulen, copied;
    struct sk_buff *skb;

    // ...
    skb = __skb_recv_udp(sk, flags, &off, &err);
    if (!skb)
        return err;

    ulen = udp6_skb_len(skb);
    // ...
    is_udp4 = (skb->protocol == htons(ETH_P_IP));
    mib = __UDPX_MIB(sk, is_udp4);   // 选择 IPv4/IPv6 统计表

    // 地址填充区分 IPv4/IPv6
    if (is_udp4) {
        ipv6_addr_set_v4mapped(ip_hdr(skb)->saddr, &sin6->sin6_addr);
        sin6->sin6_scope_id = 0;
    } else {
        sin6->sin6_addr = ipv6_hdr(skb)->saddr;
        sin6->sin6_scope_id = ipv6_iface_scope_id(...);
    }
```

**与 IPv4 的关键差异：**

| 方面 | IPv4 | IPv6 |
|------|------|------|
| 地址结构 | `sin_family = AF_INET` | `sin6_family = AF_INET6` |
| 统计表 | `UDP_MIB_*` | `UDP_MIB_*_V6`（通过 `mib` 指针选择） |
| Rx PMTU | `ip_recv_error` | `ipv6_recv_rxpmtu` |
| 源地址 scope | 无 | `sin6_scope_id` 从 `skb->iif` 推断 |

## 8. 错误处理（ICMP unreachable 反馈）

`udp_err`（[第 912 行](#912)）由 ICMP 模块调用，将 ICMP 错误反馈给 socket：

```c
// net/ipv4/udp.c:912
int udp_err(struct sk_buff *skb, u32 info)
{
    const struct iphdr *iph = (const struct iphdr *)skb->data;
    const int type = icmp_hdr(skb)->type;
    const int code = icmp_hdr(skb)->code;
    struct udphdr *uh = (struct udphdr *)(skb->data + (iph->ihl << 2));

    // 通过五元组查找目标 socket
    sk = __udp4_lib_lookup(net, iph->daddr, uh->dest,
                           iph->saddr, uh->source, skb->dev->ifindex, ...);

    if (!sk || udp_sk(sk)->encap_type) {
        // 没有找到 socket 或是隧道 → 尝试 UDP 隧道处理
        sk = __udp4_lib_err_encap(net, iph, uh, sk, skb, info);
        if (!sk)
            return 0;
    }
    // ...
    switch (type) {
    case ICMP_DEST_UNREACH:
        if (code == ICMP_FRAG_NEEDED) {    // MTU discovery
            ipv4_sk_update_pmtu(skb, sk, info);
            if (inet->pmtudisc != IP_PMTUDISC_DONT)
                harderr = 1;
            err = EMSGSIZE;
        } else {
            err = icmp_err_convert[code].errno;  // ECONNREFUSED 等
            harderr = icmp_err_convert[code].fatal;
        }
        break;
    case ICMP_TIME_EXCEEDED:
        err = EHOSTUNREACH;  break;
    case ICMP_PARAMETERPROB:
        err = EPROTO; harderr = 1; break;
    }

    // 向 socket 报告错误
    if (!inet_test_bit(RECVERR, sk)) {
        if (!harderr || sk->sk_state != TCP_ESTABLISHED)
            goto out;   // 用户未开启 RECVERR → 静默丢弃
    } else {
        ip_icmp_error(sk, skb, err, uh->dest, info, (u8 *)(uh+1));
    }
    sk->sk_err = err;
    sk_error_report(sk);
}
```

**关键行为：**

1. **端口不可达（ICMP_PORT_UNREACH）**：在 `__udp4_lib_lookup` 找不到 socket 时触发，调用 `icmp_send` 回复 ICMP 目标不可达。
2. **`RECVERR` socket option**：默认关闭（`inet_test_bit(RECVERR, sk) == 0`）。如果用户未开启，`ICMP_DEST_UNREACH` 错误不会报告给应用层，但 `sk->sk_err` 仍会被设置，`sk_error_report` 触发下一次 send/recv 返回错误。
3. **UDP 隧道**：如果 socket 配置了 UDP 封装（encap），错误会路由到 `encap_err_rcv` 回调，而不是直接报告。

## 附录：关键函数索引

| 函数 | 文件:行号 | 说明 |
|------|---------|------|
| `udp_sendmsg` | `net/ipv4/udp.c:1233` | IPv4 UDP 发送主入口 |
| `udp_push_pending_frames` | `net/ipv4/udp.c:1177` | 将 corked 帧推送到网络 |
| `udp_send_skb` | `net/ipv4/udp.c:1092` | UDP 头填充、校验和、发送 |
| `udp_recvmsg` | `net/ipv4/udp.c:2023` | IPv4 UDP 接收主入口 |
| `__skb_recv_udp` | `net/ipv4/udp.c:1923` | 从 socket receive queue 取 skb |
| `udp_err` | `net/ipv4/udp.c:912` | ICMP 错误回调 |
| `udp_flush_pending_frames` | `net/ipv4/udp.c:1017` | 丢弃 corked 未发帧 |
| `udpv6_sendmsg` | `net/ipv6/udp.c:1456` | IPv6 UDP 发送主入口 |
| `udpv6_recvmsg` | `net/ipv6/udp.c:464` | IPv6 UDP 接收主入口 |
| `__udp_lib_checksum_complete` | `net/ipv4/udp.c:2540` | 校验和完整验证 |


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

