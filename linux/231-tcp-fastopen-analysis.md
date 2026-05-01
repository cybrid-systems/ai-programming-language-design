# TCP Fast Open (TFO) 内核实现深度分析

## 1. 背景：1-RTT vs 3-RTT

TCP Fast Open 的核心目标是将三次握手（3-Way Handshake）的 RTT 从 **3-RTT 减少到 1-RTT**，使得应用程序在连接建立后立即可以发送数据，而不需要等待握手完成。

```
传统 3-RTT：
  客户端 ──────────────────────────────> 服务端
           SYN (seq=x)
  客户端 <────────────────────────────── 服务端
           SYN+ACK (seq=y, ack=x+1)
  客户端 ──────────────────────────────> 服务端
           ACK (ack=y+1)
  ... 握手完成后才发送数据 ...
  客户端 ──────────────────────────────> 服务端
           PSH+DATA (第一次实际数据传输)

TFO 1-RTT（第二次及以后的连接）：
  客户端 ──────────────────────────────> 服务端
           SYN + DATA + TFO Cookie
  客户端 <────────────────────────────── 服务端
           SYN+ACK + ACK(DATA)
  客户端 ──────────────────────────────> 服务端
           ACK + more DATA
```

关键概念：
- **Cookie**：服务器生成并由客户端保存的认证令牌，用于验证 TFO 请求的合法性
- **TFO_SERVER_ENABLE / TFO_CLIENT_ENABLE**：分别对应服务端和客户端的开关（`net.ipv4.tcp_fastopen` 位掩码）

---

## 2. 数据结构

### fastopen_queue — TFO 等待队列

定义于 `/home/dev/code/linux/include/net/request_sock.h:157`：

```c
struct fastopen_queue {
    struct request_sock *rskq_rst_head;  // 因 RST 被丢弃的 req 链表头
    struct request_sock *rskq_rst_tail;  // 链表尾
    spinlock_t lock;                      // 保护 fastopenq 访问
    int qlen;                             // TCP_SYN_RECV 状态的 TFO 请求数
    int max_qlen;                         // 非零则表示 TFO 已启用
    struct tcp_fastopen_context __rcu *ctx; // Cookie 加密的密钥上下文
};
```

注释说明 `max_qlen != 0` 时才认为 TFO 启用（`request_sock.h:187`）。

### tcp_fastopen_context — Cookie 加密上下文

定义于 `/home/dev/code/linux/include/net/tcp.h:2156`：

```c
struct tcp_fastopen_context {
    siphash_key_t key[TCP_FASTOPEN_KEY_MAX]; // 支持主/备两套密钥
    int num;                                  // 有效密钥数量（1 或 2）
    struct rcu_head rcu;
};
```

密钥通过 `TCP_FASTOPEN_KEY_LENGTH` (= `sizeof(siphash_key_t)`) 生成，默认在系统启动时一次性初始化（`tcp_fastopen_init_key_once`）。

### tcp_request_sock 中的 TFO 字段

定义于 `/home/dev/code/linux/include/linux/tcp.h:154-170`：

```c
struct tcp_request_sock {
    // ...
    bool tfo_listener;           // 此 req 是否由 TFO listener 创建
    u32 rcv_nxt;                 // SYN-ACK 的 ack#，对于 TFO 是 data-in-SYN 后的 seq#
    // ...
};
```

`tfo_listener` 标记用于标识这是 Fast Open listener 创建的 child socket，帮助在后续处理中（例如 `inet_csk_listen_stop`）决定是否需要特殊清理。

### tcp_sock 中的 TFO 字段

定义于 `/home/dev/code/linux/include/linux/tcp.h:399-410`：

```c
struct tcp_sock {
    // ...
    fastopen_connect:1,      // setsockopt(TCP_FASTOPEN_CONNECT)
    fastopen_no_cookie:1,   // setsockopt(TCP_FASTOPEN_NO_COOKIE)，无需 cookie 即可 TFO
    fastopen_client_fail:2, // TFO 客户端失败原因
    // ...
    syn_fastopen:1,         // SYN 中包含 Fast Open 选项
    syn_fastopen_exp:1,     // SYN 中包含 Fast Open experimental option
    syn_fastopen_ch:1,     // 活跃 TFO 重启探针
    syn_fastopen_child:1,  // TFO 被动创建的 child socket
    syn_data_acked:1,      // SYN 中的数据被 SYN-ACK 确认
    // ...
    struct tcp_fastopen_request *fastopen_req; // 客户端 TFO 请求结构
};
```

### tcp_fastopen_request — 客户端 TFO 请求

定义于 `/home/dev/code/linux/include/net/tcp.h:2125`：

```c
struct tcp_fastopen_request {
    struct tcp_fastopen_cookie cookie;  // Fast Open Cookie
    struct msghdr *data;               // MSG_FASTOPEN 的数据
    size_t size;                        // 数据总大小
    int copied;                          // 已在 tcp_connect() 中排队的字节数
    struct ubuf_info *uarg;
};
```

---

## 3. tcp_sendmsg 中的 TFO 检查路径

在 `/home/dev/code/linux/net/ipv4/tcp.c:1178-1193`，`tcp_sendmsg_locked` 中：

```c
if (unlikely(flags & MSG_FASTOPEN ||
             inet_test_bit(DEFER_CONNECT, sk)) &&
    !tp->repair) {
    err = tcp_sendmsg_fastopen(sk, msg, &copied_syn, size, uarg);
    if (err == -EINPROGRESS && copied_syn > 0)
        goto out;
    else if (err)
        goto out_err;
}
```

`tcp_sendmsg_fastopen`（`tcp.c:1055`）检查：

```c
int tcp_sendmsg_fastopen(struct sock *sk, struct msghdr *msg, int *copied,
                         size_t size, struct ubuf_info *uarg)
{
    // ...
    if (!(READ_ONCE(sock_net(sk)->ipv4.sysctl_tcp_fastopen) &
          TFO_CLIENT_ENABLE) ||
        (uaddr && msg->msg_namelen >= sizeof(uaddr->sa_family) &&
         uaddr->sa_family == AF_UNSPEC))
        return -EOPNOTSUPP;
    if (tp->fastopen_req)
        return -EALREADY; /* 另一个 Fast Open 已在进行中 */
    // 分配 fastopen_req 结构
    tp->fastopen_req = kzalloc_obj(struct tcp_fastopen_request, ...);
    tp->fastopen_req->data = msg;
    tp->fastopen_req->size = size;
    tp->fastopen_req->uarg = uarg;
```

关键点：**`cookie_req` 不存在于内核中**——客户端判断是否请求 cookie 是在用户空间或协议栈的更高层。内核 `tcp_fastopen_request.cookie.len == 0` 表示**请求 cookie**，`< 0` 表示**不使用 cookie**。

### tcp_fastopen_defer_connect — 延迟 SYN

`tcp_fastopen_defer_connect`（`tcp_fastopen.c:550`）处理客户端的延迟连接行为：

```c
bool tcp_fastopen_defer_connect(struct sock *sk, int *err)
{
    struct tcp_fastopen_cookie cookie = { .len = 0 };
    struct tcp_sock *tp = tcp_sk(sk);
    u16 mss;

    if (tp->fastopen_connect && !tp->fastopen_req) {
        if (tcp_fastopen_cookie_check(sk, &mss, &cookie)) {
            inet_set_bit(DEFER_CONNECT, sk);
            return true;  // 延迟发送 SYN，直到第一次 write()
        }
        // 分配 fastopen_req 以便在 SYN 中包含 FO 选项
        tp->fastopen_req = kzalloc_obj(struct tcp_fastopen_request, ...);
        if (tp->fastopen_req)
            tp->fastopen_req->cookie = cookie;
        else
            *err = -ENOBUFS;
    }
    return false;
}
```

如果 `fastopen_connect` 已设置但没有有效 cookie，则分配 `fastopen_req` 并在后续 `tcp_connect()` 中发送 SYN 时附上 cookie 请求选项。

---

## 4. tcp_fastopen_cookie_gen 与 tcp_fastopen_cookie_gen_check

### Cookie 生成（服务端）

`tcp_fastopen_cookie_gen`（`tcp_fastopen.c:246`）使用 SipHash 对源/目的地址进行哈希：

```c
static void tcp_fastopen_cookie_gen(struct sock *sk,
                                    struct request_sock *req,
                                    struct sk_buff *syn,
                                    struct tcp_fastopen_cookie *foc)
{
    struct tcp_fastopen_context *ctx;

    rcu_read_lock();
    ctx = tcp_fastopen_get_ctx(sk);
    if (ctx)
        __tcp_fastopen_cookie_gen_cipher(req, syn, &ctx->key[0], foc);
    rcu_read_unlock();
}
```

`__tcp_fastopen_cookie_gen_cipher`（`tcp_fastopen.c:197`）实际做哈希计算：

```c
static bool __tcp_fastopen_cookie_gen_cipher(struct request_sock *req,
                                             struct sk_buff *syn,
                                             const siphash_key_t *key,
                                             struct tcp_fastopen_cookie *foc)
{
    BUILD_BUG_ON(TCP_FASTOPEN_COOKIE_SIZE != sizeof(u64));
    if (req->rsk_ops->family == AF_INET) {
        const struct iphdr *iph = ip_hdr(syn);
        foc->val[0] = cpu_to_le64(siphash(&iph->saddr,
                                          sizeof(iph->saddr) +
                                          sizeof(iph->daddr), key));
        foc->len = TCP_FASTOPEN_COOKIE_SIZE;
        return true;
    }
#if IS_ENABLED(CONFIG_IPV6)
    if (req->rsk_ops->family == AF_INET6) {
        const struct ipv6hdr *ip6h = ipv6_hdr(syn);
        foc->val[0] = cpu_to_le64(siphash(&ip6h->saddr,
                                          sizeof(ip6h->saddr) +
                                          sizeof(ip6h->daddr), key));
        foc->len = TCP_FASTOPEN_COOKIE_SIZE;
        return true;
    }
#endif
    return false;
}
```

IPv4 和 IPv6 各自使用对应的地址字段作为 SipHash 输入，输出 8 字节（64-bit）cookie。

### Cookie 验证（服务端）

`tcp_fastopen_cookie_gen_check`（`tcp_fastopen.c:283`）检查客户端传来的 cookie 是否匹配主钥或备用钥：

```c
static int tcp_fastopen_cookie_gen_check(struct sock *sk,
                                         struct request_sock *req,
                                         struct sk_buff *syn,
                                         struct tcp_fastopen_cookie *orig,
                                         struct tcp_fastopen_cookie *valid_foc)
{
    struct tcp_fastopen_cookie search_foc = { .len = -1 };
    struct tcp_fastopen_cookie *foc = valid_foc;
    struct tcp_fastopen_context *ctx;
    int i, ret = 0;

    rcu_read_lock();
    ctx = tcp_fastopen_get_ctx(sk);
    if (!ctx)
        goto out;
    for (i = 0; i < tcp_fastopen_context_len(ctx); i++) {
        __tcp_fastopen_cookie_gen_cipher(req, syn, &ctx->key[i], foc);
        if (tcp_fastopen_cookie_match(foc, orig)) {
            ret = i + 1;  // 返回 1（主钥）或 2（备用钥）
            goto out;
        }
        foc = &search_foc;  // 下一个密钥用临时结构
    }
out:
    rcu_read_unlock();
    return ret;  // 0 表示无匹配
}
```

返回 `ret == 2` 时表示 cookie 使用备用密钥验证通过，服务端会在响应中标记 `MIB_TCPFASTOPENPASSIVEALTKEY`。

---

## 5. fastopen_queue 与 max_qlen 限制

`tcp_fastopen_queue_check`（`tcp_fastopen.c:389`）负责 TFO 的队列长度检查：

```c
static bool tcp_fastopen_queue_check(struct sock *sk)
{
    struct fastopen_queue *fastopenq;
    int max_qlen;

    fastopenq = &inet_csk(sk)->icsk_accept_queue.fastopenq;
    max_qlen = READ_ONCE(fastopenq->max_qlen);
    if (max_qlen == 0)
        return false;

    if (fastopenq->qlen >= max_qlen) {
        struct request_sock *req1;
        spin_lock(&fastopenq->lock);
        req1 = fastopenq->rskq_rst_head;
        if (!req1 || time_after(req1->rsk_timer.expires, jiffies)) {
            __NET_INC_STATS(sock_net(sk),
                    LINUX_MIB_TCPFASTOPENLISTENOVERFLOW);
            spin_unlock(&fastopenq->lock);
            return false;
        }
        // 有等待超时的 RST req，清理后继续
        fastopenq->rskq_rst_head = req1->dl_next;
        fastopenq->qlen--;
        spin_unlock(&fastopenq->lock);
        reqsk_put(req1);
    }
    return true;
}
```

关键点：
- `max_qlen == 0` → TFO 完全禁用
- `qlen >= max_qlen` 时，尝试清理 `rskq_rst_head` 中已超时的请求（60 秒超时，见下方）
- 被 RST 的请求在 `rskq_rst_head/tail` 链表中停留 60 秒，这段时间内请求仍然计入 `qlen`，作为防御 TFO 欺骗攻击的一部分

### RST req 的 60 秒等待机制

在 `reqsk_fastopen_remove`（`tcp_fastopen.c:55-88`）中：

```c
/* Wait for 60secs before removing a req that has triggered RST.
 * This is a simple defense against TFO spoofing attack - by
 * counting the req against fastopen.max_qlen, and disabling
 * TFO when the qlen exceeds max_qlen.
 *
 * For more details see CoNext'11 "TCP Fast Open" paper.
 */
req->rsk_timer.expires = jiffies + 60*HZ;
if (fastopenq->rskq_rst_head == NULL)
    fastopenq->rskq_rst_head = req;
else
    fastopenq->rskq_rst_tail->dl_next = req;
req->dl_next = NULL;
fastopenq->rskq_rst_tail = req;
fastopenq->qlen++;
```

**欺骗攻击防御原理**：攻击者伪造大量带 cookie 的 TFO SYN 到服务器，如果服务器为每个这样的 SYN 都创建 child socket 并排队，会消耗资源。通过在 RST 后将 req 保留 60 秒并计入 `qlen`，服务器可以在 `max_qlen` 限制内快速拒绝大量欺骗流量，防止 `qlen` 无限增长导致 DoS。

---

## 6. SYN 数据包的 skb 处理 — tcp_fastopen_add_skb

当服务端收到带数据的 SYN（`syn_data = true`），`tcp_fastopen_add_skb`（`tcp_fastopen.c:223`）将数据 skb 附加到刚创建的 child socket：

```c
void tcp_fastopen_add_skb(struct sock *sk, struct sk_buff *skb)
{
    struct tcp_sock *tp = tcp_sk(sk);

    if (TCP_SKB_CB(skb)->end_seq == tp->rcv_nxt)
        return;  // 重复数据，跳过

    skb = skb_clone(skb, GFP_ATOMIC);
    if (!skb)
        return;

    tcp_cleanup_skb(skb);
    /* segs_in 在 tcp_create_openreq_child() 中已初始化为 1，
     * 调用 tcp_segs_in() 前需重置为 0 以避免重复计数。
     */
    tp->segs_in = 0;
    tcp_segs_in(tp, skb);
    __skb_pull(skb, tcp_hdrlen(skb));
    sk_forced_mem_schedule(sk, skb->truesize);
    skb_set_owner_r(skb, sk);

    TCP_SKB_CB(skb)->seq++;
    TCP_SKB_CB(skb)->tcp_flags &= ~TCPHDR_SYN;  // 清除 SYN 标志

    tp->rcv_nxt = TCP_SKB_CB(skb)->end_seq;
    tcp_add_receive_queue(sk, skb);
    tp->syn_data_acked = 1;  // 标记 SYN 中的数据已被确认
    tp->bytes_received = skb->len;

    if (TCP_SKB_CB(skb)->tcp_flags & TCPHDR_FIN)
        tcp_fin(sk);
}
```

注意 `TCP_SKB_CB(skb)->tcp_flags &= ~TCPHDR_SYN` 这行——SYN 中的数据不再带有 SYN 标志，接收窗口按照正常数据处理。`tcp_urg_fin` 的处理实际上是 `tcp_fin()` 函数，FIN 如果出现在 SYN data 中会被正确处理。

---

## 7. TFO 的三条路径 — tcp_try_fastopen

`tcp_try_fastopen`（`tcp_fastopen.c:437`）是 TFO 服务端处理的核心函数，处理三种情况：

### 路径 A：Cookie 请求（foc.len == 0）

```c
if (foc->len == 0) /* Client requests a cookie */
    NET_INC_STATS(sock_net(sk), LINUX_MIB_TCPFASTOPENCOOKIEREQD);

if (!((tcp_fastopen & TFO_SERVER_ENABLE) &&
      (syn_data || foc->len >= 0) &&
      tcp_fastopen_queue_check(sk))) {
    foc->len = -1;
    return NULL;
}
```

此时客户端请求 cookie，服务端生成并通过 SYN-ACK 返回（`tcp_conn_request` 在 `tcp_input.c:7591`）。

### 路径 B：有效 Cookie + 有数据（foc.len > 0，syn_data）

```c
} else if (foc->len > 0) {
    ret = tcp_fastopen_cookie_gen_check(sk, req, skb, foc, &valid_foc);
    if (!ret) {
        NET_INC_STATS(sock_net(sk), LINUX_MIB_TCPFASTOPENPASSIVEFAIL);
    } else {
        // Cookie 有效，创建 child socket 并接受 SYN 中的数据
fastopen:
        child = tcp_fastopen_create_child(sk, skb, req);
        if (child) {
            if (ret == 2) {
                valid_foc.exp = foc->exp;
                *foc = valid_foc;
                NET_INC_STATS(sock_net(sk),
                      LINUX_MIB_TCPFASTOPENPASSIVEALTKEY);
            }
            NET_INC_STATS(sock_net(sk), LINUX_MIB_TCPFASTOPENPASSIVE);
            tcp_sk(child)->syn_fastopen_child = 1;
            return child;
        }
        NET_INC_STATS(sock_net(sk), LINUX_MIB_TCPFASTOPENPASSIVEFAIL);
    }
}
```

### 路径 C：无 Cookie 模式（fastopen_no_cookie 或 TFO_SERVER_COOKIE_NOT_REQD）

```c
if (tcp_fastopen_no_cookie(sk, dst, TFO_SERVER_COOKIE_NOT_REQD))
    goto fastopen;
```

`tcp_fastopen_no_cookie`（`tcp_fastopen.c:425`）检查：

```c
static bool tcp_fastopen_no_cookie(const struct sock *sk,
                                   const struct dst_entry *dst,
                                   int flag)
{
    return (READ_ONCE(sock_net(sk)->ipv4.sysctl_tcp_fastopen) & flag) ||
           tcp_sk(sk)->fastopen_no_cookie ||
           (dst && dst_metric(dst, RTAX_FASTOPEN_NO_COOKIE));
}
```

只要满足以下任一条件就直接跳过 cookie 验证：
1. `sysctl_tcp_fastopen` 包含 `TFO_SERVER_COOKIE_NOT_REQD`
2. socket 设置了 `fastopen_no_cookie`
3. 路由 `dst` 设置了 `RTAX_FASTOPEN_NO_COOKIE`

---

## 8. fastopen_key 与 Cookie 加密机制

### tcp_fastopen_init_key_once — 一次性初始化

`tcp_fastopen_init_key_once`（`tcp_fastopen.c:94`）：

```c
void tcp_fastopen_init_key_once(struct net *net)
{
    u8 key[TCP_FASTOPEN_KEY_LENGTH];
    struct tcp_fastopen_context *ctxt;

    rcu_read_lock();
    ctxt = rcu_dereference(net->ipv4.tcp_fastopen_ctx);
    if (ctxt) {
        rcu_read_unlock();
        return;  // 已初始化，跳过
    }
    rcu_read_unlock();

    /* 允许此处存在竞态 —— tcp_fastopen_cookie_gen 在使用 cookie 前
     * 也会检查有效性，所以这个风险是可接受的。
     */
    get_random_bytes(key, sizeof(key));
    tcp_fastopen_reset_cipher(net, NULL, key, NULL);
}
```

注意它只初始化**一次**（`net->ipv4.tcp_fastopen_ctx` 已存在则直接返回），并且允许初始化竞态（因为后续 cookie 生成时会再次验证有效性）。

### tcp_fastopen_reset_cipher — 重置/设置密钥

`tcp_fastopen_reset_cipher`（`tcp_fastopen.c:145`）负责创建新的 `tcp_fastopen_context`：

```c
int tcp_fastopen_reset_cipher(struct net *net, struct sock *sk,
                              void *primary_key, void *backup_key)
{
    struct tcp_fastopen_context *ctx, *octx;
    struct fastopen_queue *q;
    int err = 0;

    ctx = kmalloc_obj(*ctx);  // 使用 struct tcp_fastopen_context 大小
    if (!ctx) {
        err = -ENOMEM;
        goto out;
    }

    ctx->key[0].key[0] = get_unaligned_le64(primary_key);
    ctx->key[0].key[1] = get_unaligned_le64(primary_key + 8);
    if (backup_key) {
        ctx->key[1].key[0] = get_unaligned_le64(backup_key);
        ctx->key[1].key[1] = get_unaligned_le64(backup_key + 8);
        ctx->num = 2;
    } else {
        ctx->num = 1;
    }

    if (sk) {
        q = &inet_csk(sk)->icsk_accept_queue.fastopenq;
        octx = unrcu_pointer(xchg(&q->ctx, RCU_INITIALIZER(ctx)));
    } else {
        octx = unrcu_pointer(xchg(&net->ipv4.tcp_fastopen_ctx,
                                  RCU_INITIALIZER(ctx)));
    }

    if (octx)
        call_rcu(&octx->rcu, tcp_fastopen_ctx_free);
out:
    return err;
}
```

- `primary_key` 为 16 字节（SipHash 密钥），被分解为两个 `u64` 存储
- `backup_key` 存在时 `num = 2`，支持密钥轮换
- 旧 context 通过 RCU 延迟释放（`tcp_fastopen_ctx_free`）

### Cookie 验证匹配

`tcp_fastopen_cookie_match`（`tcp.h:2182`）：

```c
static inline
bool tcp_fastopen_cookie_match(const struct tcp_fastopen_cookie *foc,
                               const struct tcp_fastopen_cookie *orig)
{
    if (orig->len == TCP_FASTOPEN_COOKIE_SIZE &&
        orig->len == foc->len &&
        !memcmp(orig->val, foc->val, foc->len))
        return true;
    return false;
}
```

必须长度相等（`TCP_FASTOPEN_COOKIE_SIZE == 8`）且字节内容完全匹配。

---

## 9. tcp_fastopen_create_child — 创建 TFO child socket

`tcp_fastopen_create_child`（`tcp_fastopen.c:310`）在服务端收到带有效 cookie 的 SYN 时被调用：

```c
static struct sock *tcp_fastopen_create_child(struct sock *sk,
                                              struct sk_buff *skb,
                                              struct request_sock *req)
{
    // ... 分配 child socket ...
    child = inet_csk(sk)->icsk_af_ops->syn_recv_sock(sk, skb, req, NULL, NULL, &own_req, NULL);
    if (!child)
        return NULL;

    spin_lock(&queue->fastopenq.lock);
    queue->fastopenq.qlen++;  // 增加 TFO 队列长度
    spin_unlock(&queue->fastopenq.lock);

    tp = tcp_sk(child);
    rcu_assign_pointer(tp->fastopen_rsk, req);  // child 关联到 req
    tcp_rsk(req)->tfo_listener = true;          // 标记为 TFO listener

    /* RFC1323: SYN & SYN/ACK 中的窗口不缩放 */
    tp->snd_wnd = ntohs(tcp_hdr(skb)->window);
    tp->max_window = tp->snd_wnd;

    req->timeout = tcp_timeout_init(child);
    tcp_reset_xmit_timer(child, ICSK_TIME_RETRANS,
                         req->timeout, false);

    refcount_set(&req->rsk_refcnt, 2);  // child + listener 各持有一个引用

    tp->rcv_nxt = TCP_SKB_CB(skb)->seq + 1;
    tcp_fastopen_add_skb(child, skb);   // 将 SYN 中的数据移入 child socket

    tcp_rsk(req)->rcv_nxt = tp->rcv_nxt;
    tp->rcv_wup = tp->rcv_nxt;
    tp->rcv_mwnd_seq = tp->rcv_wup + tp->rcv_wnd;

    return child;
}
```

关键设计点：
- `fastopen_rsk` 将 child socket 与其 request_sock 关联，直到 3WHS 完成或中止
- `tfo_listener = true` 标记此 req 属于 TFO listener 创建
- `refcount_set(&req->rsk_refcnt, 2)` — child 和 listener 各持一个引用，确保 req 不会过早释放
- `tcp_fastopen_add_skb` 将 SYN 中的数据（如果有）移入 receive queue

---

## 10. TFO 攻击面与限制措施

### max_qlen 限制 — 防 DoS

`setsockopt(TCP_FASTOPEN, val)` 调用 `fastopen_queue_tune`（`tcp.c:4109`）设置 `fastopenq.max_qlen`。当 `qlen >= max_qlen` 时，新 TFO 请求会被拒绝直到超时 RST req 被清理。

### 60 秒 RST 保留 — 防 Spoofing

`reqsk_fastopen_remove` 在收到 RST 时将 req 移入 `rskq_rst_head/tail` 链表并保持 60 秒，这段时间内该 req 仍计入 `qlen`，防止攻击者通过发送大量伪造 RST 来耗尽 `qlen` 空间。

### tcp_fastopen_active_disable — 防 Middlebox Blackhole

主动（客户端）TFO 在检测到以下情况时会全局禁用：
1. 收到乱序 FIN
2. 收到乱序 RST
3. 连续超时三次

实现为指数退避：`1hr → 2hr → 4hr → ...`，上限为 `2^6 * 初始超时`。见 `tcp_fastopen_active_disable`、`tcp_fastopen_active_should_disable`（`tcp_fastopen.c:576-621`）。

### tcp_fastopen_blackhole_timeout

`sysctl_tcp_fastopen_blackhole_timeout` 控制上述全局禁用时长。如果为 0，则禁用此防护机制。

---

## 11. TCP_FASTOPEN 选项的 setsockopt 处理

`tcp.c:4107-4134` 处理 `TCP_FASTOPEN` socket option：

```c
case TCP_FASTOPEN:
    if (val >= 0 && ((1 << sk->sk_state) & (TCPF_CLOSE | TCPF_LISTEN))) {
        tcp_fastopen_init_key_once(net);  // 延迟初始化 key
        fastopen_queue_tune(sk, val);     // 设置 max_qlen
    } else {
        err = -EINVAL;
    }
    break;
case TCP_FASTOPEN_CONNECT:
    if (val > 1 || val < 0)
        err = -EINVAL;
    else if (READ_ONCE(net->ipv4.sysctl_tcp_fastopen) & TFO_CLIENT_ENABLE) {
        if (sk->sk_state == TCP_CLOSE)
            tp->fastopen_connect = val;
        else
            err = -EINVAL;
    }
case TCP_FASTOPEN_NO_COOKIE:
    if (val > 1 || val < 0)
        err = -EINVAL;
    else if (!((1 << sk->sk_state) & (TCPF_CLOSE | TCPF_LISTEN)))
        err = -EINVAL;
    else
        tp->fastopen_no_cookie = val;
```

注意：
- `TCP_FASTOPEN` 只允许在 `CLOSED` 或 `LISTEN` 状态设置
- `TCP_FASTOPEN_CONNECT` 只允许在 `CLOSED` 状态设置
- `TCP_FASTOPEN_NO_COOKIE` 允许在 `CLOSED` 或 `LISTEN` 状态设置

---

## 12. tcp_send_syn_data — SYN+DATA 的发送

`tcp_output.c:4199` 中的 `tcp_send_syn_data` 处理客户端在 SYN 中携带数据：

```c
static int tcp_send_syn_data(struct sock *sk, struct sk_buff *syn)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct tcp_fastopen_request *fo = tp->fastopen_req;
    // ...
    if (!tcp_fastopen_cookie_check(sk, &tp->rx_opt.mss_clamp, &fo->cookie))
        goto fallback;  // 无有效 cookie 则回退到普通 SYN

    // 构建 SYN+DATA 包
    syn_data = tcp_stream_alloc_skb(sk, sk->sk_allocation, false);
    // ...复制用户数据到 syn_data...
    err = tcp_transmit_skb(sk, syn_data, 1, sk->sk_allocation);

    if (!err) {
        tp->syn_data = (fo->copied > 0);
        tcp_rbtree_insert(&sk->tcp_rtx_queue, syn_data);
        goto done;
    }

    /* 数据未发送，放入 write_queue */
    __skb_queue_tail(&sk->sk_write_queue, syn_data);

fallback:
    /* 发送带 Cookie 请求选项的普通 SYN */
    if (fo->cookie.len > 0)
        fo->cookie.len = 0;  // 请求新的 cookie
    err = tcp_transmit_skb(sk, syn, 1, sk->sk_allocation);
    if (err)
        tp->syn_fastopen = 0;
done:
    fo->cookie.len = -1;  // SYN 重传时排除 Fast Open 选项
    return err;
}
```

fallback 路径说明：如果因为任何原因（SYN+DATA 包传输失败、cookie 无效等），内核会回退到发送普通 SYN 并请求新 cookie。如果 `fo->cookie.len > 0`（之前有有效 cookie 但失败了），会将其重置为 0 以请求新 cookie，避免重用失败的 cookie。

---

## 总结

Linux 内核的 TCP Fast Open 实现涉及：

1. **Cookie 机制**：使用 SipHash-64 对地址哈希生成 8 字节 cookie，支持主/备双密钥轮换
2. **队列限制**：`fastopenq.qlen/max_qlen` 限制_pending TFO 请求，配合 60 秒 RST 保留链表防御 Spoofing
3. **三条路径**：Cookie 请求、有效 Cookie（有无数据均可）、无 Cookie 模式
4. **child socket 创建**：通过 `tcp_fastopen_create_child` 在 SYN 阶段创建socket，数据通过 `tcp_fastopen_add_skb` 移入 receive queue
5. **主动 TFO 保护**：指数退避的 blackhole 检测机制防止中间件导致的数据黑洞