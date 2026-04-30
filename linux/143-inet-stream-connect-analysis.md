# 143-inet_stream_connect — TCP连接建立深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/af_inet.c` + `net/ipv4/tcp_ipv4.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**inet_stream_connect** 是 TCP 三次握手的内核实现，将用户空间的 `connect()` 系统调用转化为协议栈的连接建立过程。

---

## 1. TCP 三次握手

```
客户端                              服务端
  │                                    │
  │─────────── SYN (seq=x) ──────────▶│  第一次握手
  │                                    │
  │◀── SYN+ACK (seq=y, ack=x+1) ─────│  第二次握手
  │                                    │
  │─────────── ACK (ack=y+1) ─────────▶│  第三次握手
  │                                    │
  │========== ESTABLISHED ============▶│
```

---

## 2. sys_connect — 系统调用入口

### 2.1 __sys_connect

```c
// net/socket.c — __sys_connect
int __sys_connect(int fd, struct sockaddr __user *uservaddr, int addrlen)
{
    struct socket *sock;

    // 1. 获取 socket
    sock = sockfd_lookup(fd, &err);
    if (!sock)
        return err;

    // 2. 调用 proto_ops->connect
    err = sock->ops->connect(sock, uservaddr, addrlen, 0);

    sockfd_put(sock);
    return err;
}
```

---

## 3. inet_stream_connect — TCP 连接

### 3.1 inet_stream_connect

```c
// net/ipv4/af_inet.c — inet_stream_connect
int inet_stream_connect(struct socket *sock, struct sockaddr *uaddr,
                        int addr_len, int flags)
{
    struct sock *sk = sock->sk;
    int err;

    // 1. 如果 UDP socket 调用了 connect，也有效
    lock_sock(sk);

    // 2. 如果 socket 状态不是 SS_UNCONNECTED，出错
    if (sock->state != SS_UNCONNECTED) {
        err = -EISCONN;
        goto out;
    }

    // 3. TCP：调用 tcp_v4_connect
    err = tcp_v4_connect(sk, uaddr, addr_len);
    if (err)
        goto out;

    // 4. 设置非阻塞
    if (flags & O_NONBLOCK) {
        sock->state = SS_CONNECTING;
        release_sock(sk);
        return -EINPROGRESS;
    }

    // 5. 阻塞等待连接完成
    err = wait_for_connect(sock, sk, timeo);

    if (err)
        goto out;

    sock->state = SS_CONNECTED;

out:
    release_sock(sk);
    return err;
}
```

---

## 4. tcp_v4_connect — IPv4 TCP 连接

### 4.1 tcp_v4_connect

```c
// net/ipv4/tcp_ipv4.c — tcp_v4_connect
int tcp_v4_connect(struct sock *sk, struct sockaddr *uaddr, int addr_len)
{
    struct sockaddr_in *usin = (struct sockaddr_in *)uaddr;
    struct inet_sock *inet = inet_sk(sk);
    struct tcp_sock *tp = tcp_sk(sk);
    __be16 orig_sport, orig_dport;
    __be32 daddr;

    // 1. 保存原始端口
    orig_sport = inet->inet_sport;
    orig_dport = inet->inet_dport;

    // 2. 设置目的地址
    inet->inet_dport = usin->sin_port;
    inet->inet_daddr = daddr = usin->sin_addr.s_addr;

    // 3. 路由查找（目的地址 → 出口设备 + 源地址）
    err = ip_route_connect(fl4, daddr, 0, oif, sk->sk_protocol,
                           orig_sport, orig_dport, sk, true);
    if (err)
        goto failure;

    // 4. 如果没设置源地址，使用路由的源地址
    if (!inet->inet_saddr)
        inet->inet_saddr = fl4.saddr;

    // 5. 设置初始序列号
    if (!tp->rx_opt.ts_recent_stamp)
        tcp_set_state(sk, TCP_SYN_SENT);

    // 6. 发送 SYN
    err = connect_flags(tp, bhash_ptr(bind_hash, 0));

    // 7. 将 socket 状态设置为 CONNECTING
    sock->state = SS_CONNECTING;

    return 0;

failure:
    tcp_set_state(sk, TCP_CLOSE);
}
```

---

## 5. connect_flags — 发送 SYN

### 5.1 connect_flags

```c
// net/ipv4/tcp_output.c — connect_flags
int tcp_connect_init(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct dst_entry *dst = __sk_dst_check(sk, 0);
    __u8 rcv_wscale;

    // 1. 计算窗口扩大因子
    tp->rcv_wnd = tcp_select_window(sk);

    // 2. 设置 Sack启用
    if (tp->rx_opt.dsack)
        tp-> SackOk = 1;

    // 3. 发送 SYN
    return tcp_transmit_skb(sk, __skb_clone(skb, GFP_KERNEL), 1, GFP_KERNEL);
}
```

---

## 6. TCP 状态机

```
TCP 状态转换：

CLOSED ──listen──▶ LISTEN
                     │
                     │accept
                     ▼
              ┌──────────────┐
              │  SYN_SENT    │◀─────┐
              └──────────────┘      │
                     │              │timeout
                     │SYN+ACK       │
                     ▼              │
              ┌──────────────┐      │
              │ SYN_RCVD     │─────┘
              └──────────────┘
                     │
                     │ACK
                     ▼
              ┌──────────────┐
              │  ESTABLISHED │
              └──────────────┘
                     │
                     │FIN
                     ▼
              ┌──────────────┐
              │ CLOSE_WAIT  │
              └──────────────┘
                     │
                     │FIN
                     ▼
              ┌──────────────┐
              │  CLOSING    │
              └──────────────┘
```

---

## 7. 半连接队列与全连接队列

```c
// net/ipv4/inet_hashtables.c — inet_csk_reqsk_queue_add
// 半连接队列（SYN queue）：
//   收到 SYN 后，socket 加入 inet_csk(sk)->icsk_accept_queue.sk_accept_queue
//   队列长度：net.ipv4.tcp_max_syn_backlog

// 全连接队列（accept queue）：
//   三次握手完成后，socket 从半连接队列移到全连接队列
//   长度：listen(socket, backlog) 的 backlog 参数
```

---

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/socket.c` | `__sys_connect` |
| `net/ipv4/af_inet.c` | `inet_stream_connect` |
| `net/ipv4/tcp_ipv4.c` | `tcp_v4_connect` |
| `net/ipv4/tcp_output.c` | `tcp_connect_init`、`tcp_transmit_skb` |

---

## 9. 西游记类比

**inet_stream_connect** 就像"取经前的拜帖仪式"——

> 悟空要去拜访某位神仙，先递上一张拜帖（发送 SYN）。如果神仙在府上，会回一张"已知晓，请进"的拜帖（收到 SYN+ACK）。悟空收到后再回一张确认帖（ACK），然后就可以进门了（ESTABLISHED）。这就是三次握手的精髓——确认双方的地址（IP）、通报能力（窗口、SACK），然后建立可靠的通信通道。如果府上太忙（半连接队满），就会把悟空拒之门外。如果进了门但主人太忙没空接待（accept 队列满），就只能在门外等着。

---

## 10. 关联文章

- **sock_create**（article 142）：socket 创建
- **tcp_sendmsg**（article 144）：连接建立后的数据发送
- **tcp_state_machine**（相关）：TCP 状态机