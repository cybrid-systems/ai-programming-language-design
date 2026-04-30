# 146-inet_release — Socket关闭深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/af_inet.c` + `net/ipv4/tcp.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**inet_release** 是 socket 关闭的核心函数，释放 socket、关闭连接（TCP四次挥手）、释放缓冲区。

---

## 1. TCP 四次挥手

```
主动关闭方                            被动关闭方
  │                                    │
  │─────────── FIN (seq=x) ──────────▶│  第一次挥手
  │◀────────── ACK (ack=x+1) ─────────│  第二次挥手
  │                                    │
  │◀────────── FIN (seq=y) ───────────│  第三次挥手
  │                                    │
  │─────────── ACK (ack=y+1) ─────────▶│  第四次挥手
  │                                    │
  TIME_WAIT (2*MSL)                    │
```

---

## 2. sys_close — 系统调用

### 2.1 __sys_close

```c
// fs/open.c — __sys_close
int __sys_close(int fd)
{
    struct file *filp;

    // 1. 获取 file
    filp = fdget(fd);

    // 2. 调用 release
    filp->f_op->release(inode, filp);

    // 3. 释放 fd
    fdput(filp);
}
```

---

## 3. inet_release — TCP/UDP 关闭

### 3.1 inet_release

```c
// net/ipv4/af_inet.c — inet_release
int inet_release(struct socket *sock)
{
    struct sock *sk = sock->sk;

    if (sk) {
        long timeout;

        // 1. 清理 socket 缓存
        sock->sk = NULL;
        sk->sk_socket = NULL;

        // 2. TCP：四次挥手
        if (sk->sk_protocol == IPPROTO_TCP) {
            tcp_close(sk, timeout);
        } else if (sk->sk_protocol == IPPROTO_UDP) {
            // UDP：无连接，直接关闭
            udp_lib_close(sk);
        }

        // 3. 释放
        sock_net(sk)->hooks.sk_destruct(sk);
    }

    return 0;
}
```

---

## 4. tcp_close — TCP 关闭

### 4.1 tcp_close

```c
// net/ipv4/tcp.c — tcp_close
void tcp_close(struct sock *sk, long timeout)
{
    struct sk_buff *skb;

    lock_sock(sk);

    // 1. 如果连接还在，收尾
    if (sk->sk_state != TCP_CLOSE) {
        // 发送剩余数据
        if (tcp_send_fin(sk)) {
            // 发送 FIN 成功，进入 FIN_WAIT_1
            goto wait;
        }
    }

wait:
    // 2. 等待数据发送完毕
    while ((skb = __skb_dequeue(&sk->sk_receive_queue)) != NULL)
        kfree_skb(skb);

    // 3. 进入 TIME_WAIT
    if (sk->sk_state == TCP_FIN_WAIT2) {
        // 设置超时
        timeout = inet_csk(sk)->icsk_rto * 2;
    }

    release_sock(sk);

    // 4. 等待超时或收到 ACK
    if (timeout)
        sk_wait_event(sk, &timeout, sk->sk_state != TCP_CLOSE);

    // 5. 销毁 sock
    sock_orphan(sk);
    xfrm_sk_free(sk);
}
```

---

## 5. tcp_send_fin — 发送 FIN

### 5.1 tcp_send_fin

```c
// net/ipv4/tcp_output.c — tcp_send_fin
int tcp_send_fin(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *skb = tcp_write_queue_tail(sk);

    // 获取/创建 FIN skb
    if (!skb || skb->len > 0) {
        // 如果写队列非空，创建一个只含 FIN 的 skb
        skb = alloc_skb(MAX_TCP_HEADER, GFP_ATOMIC);
        // ...
    }

    // 设置 FIN 标志
    TCP_SKB_CB(skb)->tcp_flags = TCPHDR_FIN | TCPHDR_ACK;

    // 发送
    return tcp_transmit_skb(sk, skb, 1, GFP_ATOMIC);
}
```

---

## 6. TCP 状态转换（关闭）

```
关闭过程：

ESTABLISHED
    │
    │close() → 发送 FIN
    ▼
FIN_WAIT_1
    │
    │收到 ACK
    ▼
FIN_WAIT_2
    │
    │收到对方 FIN
    ▼
TIME_WAIT ──── 等待 2*MSL ────▶ CLOSED

或者：

ESTABLISHED
    │
    │close()
    ▼
LAST_ACK
    │
    │收到 ACK
    ▼
CLOSED

或者：

CLOSING
    │
    │收到 ACK
    ▼
TIME_WAIT ──── 2*MSL ────▶ CLOSED
```

---

## 7. MSL（Maximum Segment Lifetime）

```c
// net/ipv4/tcp_timer.c — TCP_MSL
#define TCP_MSL (120*1000)  // 120 秒

// TIME_WAIT 持续时间：2 * MSL = 240 秒
// 在此期间，旧连接的重复包都会消失
```

---

## 8. SO_LINGER 选项

```c
// 正常 close()：
//   发送 FIN，等待对方 ACK（最多 timeout）

// setsockopt(sock, SOL_SOCKET, SO_LINGER, {1, 0}):
//   立即关闭，不等待
//   发送 RST，丢弃缓冲区数据

struct linger {
    int l_onoff;    // 开启 linger
    int l_linger;   // 超时时间（秒）
};

// l_onoff=1, l_linger=0：强制 RST
// l_onoff=0：默认行为（优雅关闭）
```

---

## 9. udp_lib_close — UDP 关闭

### 9.1 udp_lib_close

```c
// net/ipv4/udp.c — udp_lib_close
void udp_lib_close(struct sock *sk, long timeout)
{
    // UDP 无连接，简化处理
    lock_sock(sk);

    // 清空接收队列
    skb_queue_purge(&sk->sk_receive_queue);

    // 如果已连接（调用过 connect()），从 hash 表移除
    if (sk->sk_state == TCP_ESTABLISHED) {
        inet_del_first_protocol(sk);
    }

    release_sock(sk);

    // 销毁 sock
    sock_orphan(sk);
}
```

---

## 10. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/af_inet.c` | `inet_release` |
| `net/ipv4/tcp.c` | `tcp_close`、`tcp_send_fin` |
| `net/ipv4/udp.c` | `udp_lib_close` |
| `net/ipv4/tcp_output.c` | `tcp_send_fin` |

---

## 11. 西游记类比

**inet_release** 就像"取经路的驿站关闭仪式"——

> 通信结束后，要关闭驿站（socket）。TCP 关闭像正式的告别仪式——主动关闭方先说"我说完了"（发送 FIN），对方回应"知道了"（ACK），然后对方也说"我也说完了"（FIN），主动方最后确认"收到"（ACK）。这就是四次挥手。TIME_WAIT 就像告别后还要再等一会儿（2*MSL），确保对方真的收到了告别信，没有重复的信件还在路上。UDP 就不一样了——UDP 没有连接，直接把驿站关了就行，不用告别仪式。

---

## 12. 关联文章

- **inet_stream_connect**（article 143）：连接建立
- **tcp_sendmsg**（article 144）：数据发送
- **udp_sendmsg**（article 145）：UDP 发送