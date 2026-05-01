# inet_stream_connect — TCP 连接建立分析

**内核版本：** Linux 7.0-rc1  
**源文件：** `net/ipv4/af_inet.c`、`net/ipv4/tcp_ipv4.c`、`net/ipv4/tcp_output.c`、`include/net/sock.h`、`include/net/tcp_states.h`

---

## 1. inet_stream_connect 入口（__inet_stream_connect）

应用程序调用 `connect()` 系统调用，最终通过 socket 层dispatch到 `inet_stream_ops.connect`，即 `inet_stream_connect()`（`af_inet.c` 第 698 行）：

```c
// af_inet.c:698
int inet_stream_connect(struct socket *sock, struct sockaddr_unsized *uaddr,
                        int addr_len, int flags)
{
    int err;

    lock_sock(sock->sk);
    err = __inet_stream_connect(sock, uaddr, addr_len, flags, 0);
    release_sock(sock->sk);
    return err;
}
```

`inet_stream_connect()` 只是做了一层锁封装，实际逻辑在 `__inet_stream_connect()`（第 707 行）。该函数处理：

1. **AF_UNSPEC 断开连接**：若 `uaddr->sa_family == AF_UNSPEC`，调用 `sk->sk_prot->disconnect()` 断开连接
2. **状态 switch 分支**：根据 `sock->state`（socket 状态）进入不同分支
3. **同步/异步 connect 处理**：非阻塞时返回 `-EINPROGRESS`，同步等待直到连接建立或超时

关键代码（`af_inet.c` 第 739–776 行）：

```c
switch (sock->state) {
default:
    err = -EINVAL;
    goto out;
case SS_CONNECTED:
    err = -EISCONN;
    goto out;
case SS_CONNECTING:
    if (inet_test_bit(DEFER_CONNECT, sk))
        err = is_sendmsg ? -EINPROGRESS : -EISCONN;
    else
        err = -EALREADY;
    break;
case SS_UNCONNECTED:
    err = -EISCONN;
    if (sk->sk_state != TCP_CLOSE)
        goto out;

    if (BPF_CGROUP_PRE_CONNECT_ENABLED(sk)) {
        err = sk->sk_prot->pre_connect(sk, uaddr, addr_len);
        if (err)
            goto out;
    }

    err = sk->sk_prot->connect(sk, uaddr, addr_len);   // 调用 tcp_v4_connect
    if (err < 0)
        goto out;

    sock->state = SS_CONNECTING;

    if (!err && inet_test_bit(DEFER_CONNECT, sk))
        goto out;

    err = -EINPROGRESS;   // 非阻塞情况下的返回值
    break;
}
```

---

## 2. sock->ops->connect → inet_stream_connect

socket 创建时（`inet_create()`，`af_inet.c` 第 250 行附近），根据 socket type 和 protocol 选择对应的 `proto_ops` 结构体。对于 `SOCK_STREAM + IPPROTO_TCP`，注册的操作表为 `inet_stream_ops`（第 880 行）：

```c
// af_inet.c:880
const struct proto_ops inet_stream_ops = {
    .family         = PF_INET,
    .owner          = THIS_MODULE,
    .release        = inet_release,
    .bind           = inet_bind,
    .connect        = inet_stream_connect,   // <-- connect 入口
    .accept         = inet_accept,
    // ...
};
```

当用户态调用 `connect(fd, &addr, len)` 时，VFS socket 层通过 `sock->ops->connect` 分发到此函数。整个调用链：

```
用户空间 connect()
  → SYSCALL_DEFINE3(connect)
    → sock_connect()
      → inet_stream_connect()        // af_inet.c:698
        → __inet_stream_connect()    // af_inet.c:707
          → sk->sk_prot->connect()   // = tcp_v4_connect
```

---

## 3. tcp_v4_connect → ip_route_connect → tcp_connect

### 3.1 tcp_v4_connect（tcp_ipv4.c 第 221 行）

`tcp_v4_connect()` 是 TCP IPv4 的 connect 实现，执行以下关键步骤：

**Step 1：路由查询**（第 256–266 行）

```c
fl4 = &inet->cork.fl.u.ip4;
rt = ip_route_connect(fl4, nexthop, inet->inet_saddr,
                      sk->sk_bound_dev_if, IPPROTO_TCP, orig_sport,
                      orig_dport, sk);
```

`ip_route_connect()` 同时完成路由查找和源地址/端口选择。若尚未 bind，本步会自动分配一个本地端口（自动 bind）。

**Step 2：更新 socket 地址**（第 303–310 行）

```c
inet->inet_dport = usin->sin_port;
sk_daddr_set(sk, daddr);
```

**Step 3：设置 TCP 状态为 SYN_SENT**（第 312–317 行）

```c
tcp_set_state(sk, TCP_SYN_SENT);
// ...
err = inet_hash_connect(tcp_death_row, sk);  // 将 socket 加入 hash 表
```

将 socket 插入全局 `ehash` 哈希表，使其可接收来自服务端的数据包。

**Step 4：路由重选（端口/协议相关）**（第 323–331 行）

```c
rt = ip_route_newports(fl4, rt, orig_sport, orig_dport,
                       inet->inet_sport, inet->inet_dport, sk);
```

**Step 5：调用 tcp_connect()**（第 361 行）

```c
err = tcp_connect(sk);
```

### 3.2 tcp_connect（tcp_output.c 第 4292 行）

`tcp_connect()` 是真正构造并发送 SYN 包的地方：

```c
int tcp_connect(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *buff;
    int err;

    tcp_call_bpf(sk, BPF_SOCK_OPS_TCP_CONNECT_CB, 0, NULL);

    // ... MD5/AO 密钥检查 ...

    if (inet_csk(sk)->icsk_af_ops->rebuild_header(sk))
        return -EHOSTUNREACH;

    tcp_connect_init(sk);   // 初始化连接参数

    if (unlikely(tp->repair)) {
        tcp_finish_connect(sk, NULL);
        return 0;
    }

    buff = tcp_stream_alloc_skb(sk, sk->sk_allocation, true);
    if (unlikely(!buff))
        return -ENOBUFS;

    // 构造 SYN 包
    tcp_init_nondata_skb(buff, sk, tp->write_seq, TCPHDR_SYN);
    tcp_mstamp_refresh(tp);
    tp->retrans_stamp = tcp_time_stamp_ts(tp);
    tcp_connect_queue_skb(sk, buff);
    tcp_ecn_send_syn(sk, buff);
    tcp_rbtree_insert(&sk->tcp_rtx_queue, buff);

    // 发送 SYN（或 SYN+data for Fast Open）
    err = tp->fastopen_req ? tcp_send_syn_data(sk, buff) :
          tcp_transmit_skb(sk, buff, 1, sk->sk_allocation);
    // ...
}
```

---

## 4. 三次握手起始（tcp_connect_init, tcp_connect_queue_skb）

### tcp_connect_init（tcp_output.c 第 4099 行）

在发送 SYN 之前，`tcp_connect_init()` 完成连接参数的初始化：

```c
static void tcp_connect_init(struct sock *sk)
{
    // ...
    tp->tcp_header_len = sizeof(struct tcphdr);
    if (READ_ONCE(sock_net(sk)->ipv4.sysctl_tcp_timestamps))
        tp->tcp_header_len += TCPOLEN_TSTAMP_ALIGNED;

    // MSS 相关
    tp->rx_opt.mss_clamp = TCP_MSS_DEFAULT;
    tcp_mtup_init(sk);
    tcp_sync_mss(sk, dst_mtu(dst));

    // 初始化发送窗口
    tp->snd_wnd = 0;
    tp->rcv_wnd = 0;
    tcp_init_wl(tp, 0);
    tcp_write_queue_purge(sk);

    // 序列号初始化
    WRITE_ONCE(tp->snd_una, tp->write_seq);
    tp->snd_nxt = tp->write_seq;
    tp->rcv_nxt = 0;   // 期望从对方收到的第一个序列号

    // RTO 初始化
    inet_csk(sk)->icsk_rto = tcp_timeout_init(sk);
    WRITE_ONCE(inet_csk(sk)->icsk_retransmits, 0);
    tcp_clear_retrans(tp);
}
```

### tcp_connect_queue_skb（tcp_output.c 第 4177 行）

```c
static void tcp_connect_queue_skb(struct sock *sk, struct sk_buff *skb)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct tcp_skb_cb *tcb = TCP_SKB_CB(skb);

    tcb->end_seq += skb->len;  // SYN 消耗一个序列号
    __skb_header_release(skb);
    sk_wmem_queued_add(sk, skb->truesize);
    sk_mem_charge(sk, skb->truesize);
    WRITE_ONCE(tp->write_seq, tcb->end_seq);  // write_seq 前移
    tp->packets_out += tcp_skb_pcount(skb);
}
```

### 三次握手时序

```
客户端                           服务端
  |                               |
  |--- SYN (seq=write_seq) ------>|  tcp_connect_init 设置初始序列号
  |                               |  tcp_transmit_skb 发送 SYN
  |                               |
  |<-- SYN+ACK (seq, ack=seq+1) --|  客户端进入 TCP_SYN_RECV 状态
  |                               |
  |--- ACK (ack=seq+1) --------->|  客户端进入 TCP_ESTABLISHED
  |                               |
```

握手完成后，客户端socket 状态从 `TCP_SYN_SENT` → `TCP_ESTABLISHED`。

---

## 5. 同步 vs 非同步 connect

`__inet_stream_connect()` 的行为由 socket 是否置 `O_NONBLOCK` 决定：

### 非阻塞（O_NONBLOCK）

```c
// af_inet.c:755
err = sk->sk_prot->connect(sk, uaddr, addr_len);  // tcp_v4_connect
if (err < 0)
    goto out;
sock->state = SS_CONNECTING;
err = -EINPROGRESS;   // 立即返回，不等待
```

`tcp_v4_connect` → `tcp_connect` 会发起 SYN 并将 socket 插入发送队列，但不会等待对方 ACK。立即返回 `-EINPROGRESS`，应用需通过 `poll`/`select`/`epoll` 监听 `EPOLLOUT` 来判断连接完成。

### 阻塞（同步）

```c
// af_inet.c:758–776
if ((1 << sk->sk_state) & (TCPF_SYN_SENT | TCPF_SYN_RECV)) {
    // ...
    timeo = sock_sndtimeo(sk, flags & O_NONBLOCK);
    if (!timeo || !inet_wait_for_connect(sk, timeo, writebias))
        goto out;
    // ...
}
```

`inet_wait_for_connect()`（`af_inet.c` 第 676 行）将当前进程置入 wait queue，直到：

- socket 进入 `TCP_ESTABLISHED`
- 收到 signal
- 超时

### DEFER_CONNECT 特殊路径

若 socket 设置了 `TCP_FASTOPEN_CONNECT` 且 `DEFER_CONNECT` bit 被置位，`tcp_v4_connect` 会直接返回 0，由后续 `sendmsg()` 或 `write()` 触发实际 SYN 发送（Fast Open 优化）。此时 `__inet_stream_connect` 对于 `is_sendmsg=1` 的情况也返回 `-EINPROGRESS`（`af_inet.c` 第 745–747 行）。

---

## 6. connect 过程的 socket 状态变化

Socket 层状态（`socket->state`）和内核 TCP 协议状态（`sk->sk_state`）是两条独立的状态机：

### Socket 层状态（af_inet.c）

| 状态 | 进入时机 |
|------|----------|
| `SS_UNCONNECTED` | socket 创建时 |
| `SS_CONNECTING` | `__inet_stream_connect` 中调用 `sk_prot->connect` 成功后 |
| `SS_CONNECTED` | `__inet_stream_connect` 确认连接建立后（第 779 行） |
| `SS_DISCONNECTING` | 连接被 RST 或 `disconnect()` 调用 |

### TCP 协议状态（include/net/tcp_states.h）

```
TCP_CLOSE
   │  connect() 调用
   ▼
TCP_SYN_SENT        tcp_v4_connect 中设置（tcp_ipv4.c:312）
   │  收到 SYN+ACK
   ▼
TCP_ESTABLISHED      三次握手完成后
   │  主动 close() 或收到 FIN
   ▼
TCP_FIN_WAIT1 / TCP_FIN_WAIT2
   │  双方都关闭
   ▼
TCP_CLOSE
```

### 关键状态转换代码

`tcp_v4_connect` 在发起连接时调用 `tcp_set_state(sk, TCP_SYN_SENT)`（tcp_ipv4.c:312）。`__inet_stream_connect` 在连接建立后更新 socket 状态（af_inet.c:779）：

```c
sock->state = SS_CONNECTED;
```

错误情况下（`sk->sk_state == TCP_CLOSE`）进入 `sock_error` 路径（af_inet.c:781–786）：

```c
sock_error:
    err = sock_error(sk) ? : -ECONNABORTED;
    sock->state = SS_UNCONNECTED;
    sk->sk_disconnects++;
    if (sk->sk_prot->disconnect(sk, flags))
        sock->state = SS_DISCONNECTING;
```

---

## 7. 错误处理（EINPROGRESS, ECONNREFUSED）

### EINPROGRESS（非阻塞进行中）

在 `__inet_stream_connect` 中，非阻塞 connect 成功发起 SYN 后返回 `-EINPROGRESS`（af_inet.c:755）。应用需要：

1. 调用 `poll()`/`epoll_wait()` 监听 socket 的 `EPOLLOUT` 事件
2. 连接建立成功 → `EPOLLOUT` 触发
3. 连接失败 → `EPOLLERR` 触发，可通过 `getsockopt(SO_ERROR)` 获取具体错误

### ECONNREFUSED（连接拒绝）

服务端没有监听对应端口，或端口被防火墙丢弃：

```
客户端                              服务端
  |--- SYN ----------------------->|
  |<-- RST -----------------------| 无服务端口
  |
  ▼
tcp_v4_err() 收到 ICMP 或 RST
  → tcp_done(sk)
  → sk->sk_state = TCP_CLOSE
```

`__inet_stream_connect` 中检查 `sk->sk_state == TCP_CLOSE`（af_inet.c:781）来捕获 RST/超时导致的连接失败，向上返回 `-ECONNREFUSED` 或 `-ETIMEDOUT`。

### 连接超时（ETIMEDOUT）

TCP 重传 SYN 共 `tcp_syn_retries` 次（默认 6 次，约 3 分钟），仍未收到响应则调用 `tcp_done()` 关闭连接。`inet_wait_for_connect()` 的循环检测到 `sk->sk_state == TCP_CLOSE` 后，从 `sock_error()` 获取软错误。

### 其他可返回的错误

| 错误码 | 场景 |
|--------|------|
| `-EISCONN` | socket 已处于 `SS_CONNECTED` 状态再次 connect |
| `-EALREADY` | 非阻塞 connect 正在进行中（不带 DEFER_CONNECT） |
| `-EINVAL` | socket 不是 `SOCK_STREAM` 或状态不对 |
| `-ENETUNREACH` | 路由查不到（`ip_route_connect` 失败） |
| `-EHOSTUNREACH` | 路由重建失败（`rebuild_header` 失败） |
| `-EADDRINUSE` | 端口已被占用（`inet_hash_connect` 失败） |
| `-EKEYREJECTED` | TCP MD5/AO 密钥校验失败（`tcp_connect` 入口检查） |

---

## 总结：完整调用图

```
用户 connect()
  └─> inet_stream_connect()        [af_inet.c:698]
        └─> __inet_stream_connect() [af_inet.c:707]
              ├─> AF_UNSPEC: disconnect() → SS_UNCONNECTED
              ├─> SS_CONNECTING: -EALREADY / -EINPROGRESS
              └─> SS_UNCONNECTED:
                    ├─> BPF pre_connect check
                    └─> sk->sk_prot->connect()   [= tcp_v4_connect]
                          ├─> ip_route_connect()        路由查询
                          ├─> tcp_set_state(TCP_SYN_SENT)
                          ├─> inet_hash_connect()       插入 hash 表
                          └─> tcp_connect()             [tcp_output.c:4292]
                                ├─> tcp_connect_init()  初始化参数
                                ├─> tcp_stream_alloc_skb() 分配 SKB
                                ├─> tcp_init_nondata_skb()   SYN
                                └─> tcp_transmit_skb()       发送 SYN
              ├─> [同步] inet_wait_for_connect() 阻塞等待
              └─> [非同步] 返回 -EINPROGRESS
```

应用层通过 `poll`/`epoll` 监听 `EPOLLOUT`（连接建立）或 `EPOLLERR`（连接失败）来异步获取 connect 结果。