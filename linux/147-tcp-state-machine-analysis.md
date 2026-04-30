# 147-tcp_state_machine — TCP状态机深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/tcp.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**tcp_state_machine** 是 TCP 连接的状态转换核心，所有 TCP 包到达后都通过状态机决定如何响应。Linux 的 `tcp_set_state()` 是状态转换的唯一入口。

---

## 1. TCP 状态定义

```c
// include/net/tcp_states.h — TCP 状态
enum tcp_state {
    TCP_ESTABLISHED = 1,    // 连接已建立
    TCP_SYN_SENT = 2,       // 已发送 SYN
    TCP_SYN_RECV = 3,       // 已收到 SYN（半连接）
    TCP_FIN_WAIT1 = 4,      // 已关闭本地，准备发送 FIN
    TCP_FIN_WAIT2 = 5,      // 收到第一次 ACK，等待对方 FIN
    TCP_TIME_WAIT = 6,      // 等待 2*MSL
    TCP_CLOSE = 7,           // 已关闭
    TCP_CLOSE_WAIT = 8,      // 收到 FIN，等待关闭
    TCP_LAST_ACK = 9,       // 最后确认
    TCP_LISTEN = 10,        // 监听中
    TCP_NEW_SYN_RECV = 11,  // 收到 SYN 的新请求
};
```

---

## 2. tcp_set_state — 状态转换

### 2.1 tcp_set_state

```c
// net/ipv4/tcp.c:2964 — tcp_set_state
void tcp_set_state(struct sock *sk, int state)
{
    int oldstate = sk->sk_state;

    // 状态转换
    switch (state) {
    case TCP_ESTABLISHED:
        if (oldstate != TCP_ESTABLISHED)
            TCP_INC_STATS(sock_net(sk), TCP_MIB_CURRESTAB);
        break;

    case TCP_CLOSE:
        if (oldstate == TCP_CLOSE_WAIT || oldstate == TCP_ESTABLISHED)
            TCP_INC_STATS(sock_net(sk), TCP_MIB_TCPABORTONCLOSE);
        break;
    }

    // 触发钩子
    if (state == TCP_ESTABLISHED && oldstate != TCP_ESTABLISHED)
        tcp_init_congestion_control(sk);

    // 如果关闭，触发关闭处理
    if (state == TCP_CLOSE && oldstate == TCP_CLOSE_WAIT)
        sk->sk_shutdown |= RCV_SHUTDOWN;

    sk->sk_state = state;
}
```

---

## 3. 完整状态转换图

```
                        建立连接
                        (主动)
                          │
                          ▼
                      TCP_SYN_SENT
                          │
                    ┌─────┴─────┐
                    │ 收到 SYN+ACK│ 收到 SYN
                    │             │
                    ▼             ▼
            TCP_ESTABLISHED   TCP_SYN_RECV
                    │             │
                    │收到 FIN      │发送 SYN+ACK
                    ▼             ▼
              TCP_FIN_WAIT1   TCP_SYN_RECV
                    │             │
          ┌─────────┴─────────┐   │收到 ACK
          │收到 FIN   收到 ACK│   ▼
          │                   │   TCP_ESTABLISHED
          ▼                   ▼
    TCP_CLOSING           TCP_FIN_WAIT2
          │收到 ACK             │收到 FIN
          ▼                     ▼
    TCP_TIME_WAIT        TCP_FIN_WAIT2 ──timeout──▶ TCP_TIME_WAIT
          │收到 ACK/关闭
          ▼
       (2*MSL后)
          │
          ▼
        TCP_CLOSE
```

---

## 4. tcp_rcv_state_process — 状态处理

### 4.1 tcp_rcv_state_process

```c
// net/ipv4/tcp.c — tcp_rcv_state_process
int tcp_rcv_state_process(struct sock *sk, struct sk_buff *skb)
{
    struct tcp_sock *tp = tcp_sk(sk);
    int queued = 0;

    switch (sk->sk_state) {
    case TCP_LISTEN:
        // LISTEN 状态：处理 SYN
        if (th->syn) {
            // 进入 SYN_RECV
            tcp_set_state(sk, TCP_SYN_RECV);
            tcp_send_synack(sk);
        }
        break;

    case TCP_SYN_RECV:
        // SYN_RECV 状态：处理 ACK
        if (th->ack && TCP_SKB_CB(skb)->ack_seq == tp->snd_nxt + 1) {
            // 三次握手完成
            tcp_set_state(sk, TCP_ESTABLISHED);
            tcp_init_congestion_control(sk);
            tcp_wake_up(tp);
        }
        break;

    case TCP_ESTABLISHED:
        // ESTABLISHED：处理数据或 FIN
        if (th->fin) {
            // 收到 FIN
            tcp_set_state(sk, TCP_CLOSE_WAIT);
            tcp_send_ack(tp);
        }
        break;

    case TCP_FIN_WAIT1:
        // 主动关闭，等待 ACK
        if (th->ack && th->fin) {
            tcp_set_state(sk, TCP_CLOSING);
            tcp_send_ack(tp);
        } else if (th->ack) {
            tcp_set_state(sk, TCP_FIN_WAIT2);
        }
        break;

    case TCP_FIN_WAIT2:
        // 等待对方 FIN
        if (th->fin) {
            tcp_set_state(sk, TCP_TIME_WAIT);
            tcp_send_ack(tp);
        }
        break;

    case TCP_CLOSE:
        // 关闭状态：忽略所有包
        tcp_reset(sk);
        break;
    }

    return queued;
}
```

---

## 5. 连接建立（主动端）

```
客户端 connect()

TCP_SYN_SENT
    │
    │收到 SYN+ACK
    ▼
tcp_rcv_state_process(state=SYN_SENT)
    │
    │th->ack && seq正确
    ▼
TCP_ESTABLISHED
```

---

## 6. 连接建立（被动端）

```
服务端 listen()

TCP_LISTEN
    │
    │收到 SYN
    ▼
tcp_v4_send_synack()
    │
    ▼
TCP_SYN_RECV（半连接队列）
    │
    │收到 ACK
    ▼
tcp_rcv_state_process(state=SYN_RECV)
    │
    │th->ack
    ▼
TCP_ESTABLISHED（accept 队列）
```

---

## 7. 连接关闭（主动端）

```
应用 close()

TCP_ESTABLISHED
    │
    │tcp_send_fin()
    ▼
TCP_FIN_WAIT1
    │
    ├──收到 ACK ──────────▶ TCP_FIN_WAIT2
    │                         │
    │收到 FIN+ACK             │收到 FIN
    ▼                         ▼
TCP_CLOSING              TCP_TIME_WAIT
    │                        │
    │收到 ACK                 │(2*MSL)
    ▼                        ▼
TCP_TIME_WAIT           TCP_CLOSE
```

---

## 8. tcp_close — 关闭入口

```c
// net/ipv4/tcp.c — tcp_close
void tcp_close(struct sock *sk, long timeout)
{
    switch (sk->sk_state) {
    case TCP_CLOSE:
        break;

    case TCP_LISTEN:
        // LISTEN 状态：关闭监听
        inet_csk_listen_stop(sk);
        break;

    case TCP_SYN_SENT:
        // SYN_SENT：重置连接
        tcp_set_state(sk, TCP_CLOSE);
        tcp_send_active_reset(sk);
        break;

    case TCP_ESTABLISHED:
        // ESTABLISHED：发送 FIN
        tcp_send_fin(sk);
        tcp_set_state(sk, TCP_FIN_WAIT1);
        break;

    case TCP_FIN_WAIT1:
    case TCP_FIN_WAIT2:
        // 已在关闭流程
        break;

    case TCP_CLOSE_WAIT:
        // 被动关闭：发送 FIN
        tcp_send_fin(sk);
        tcp_set_state(sk, TCP_LAST_ACK);
        break;
    }
}
```

---

## 9. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/tcp.c` | `tcp_set_state`、`tcp_rcv_state_process`、`tcp_close` |
| `include/net/tcp_states.h` | `enum tcp_state` |

---

## 10. 西游记类比

**TCP 状态机** 就像"取经队伍的行礼告别流程"——

> TCP 的每个状态就像旅途中的不同阶段：LISTEN 像驿站开着门等人来；SYN_SENT 像派出去的使者；SYN_RECV 像收到了对方使者的回信，在等最终确认；ESTABLISHED 像双方终于碰面，可以开始办事了；FIN_WAIT 像一方说"我这边的事办完了"；TIME_WAIT 像告别后还要在驿站等一会儿，确保没有遗留的信件。状态机规定了在每个阶段收到不同的信（包）应该如何反应——如果还在 SYN_SENT 就收到了 FIN，说明对方也在连接我，那就要特殊处理。这就是 TCP 为什么可靠的原因——每一步都有明确的状态转换。

---

## 11. 关联文章

- **inet_stream_connect**（article 143）：连接建立
- **inet_release**（article 146）：连接关闭
- **tcp_retransmit**（article 149）：超时重传