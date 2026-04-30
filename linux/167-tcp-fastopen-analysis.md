# 167-tcp_fastopen — TCP快速打开深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/tcp_fastopen.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**TCP Fast Open（TFO）** 允许在三次握手的第一个 SYN 包中携带数据，减少连接建立的 RTT（Round-Trip Time）。适用于 HTTP 等短连接场景，首次连接需要 1 RTT，后续连接 0 RTT。

---

## 1. Fast Open 原理

```
传统 TCP（无 TFO）：
  Client ──── SYN (seq=x) ──────────────▶ Server
  Client ◀─── SYN+ACK (seq=y, ack=x+1) ─── Server   ← 等待 1 RTT
  Client ──── ACK (data) ────────────────▶ Server   ← 第二个 RTT

TCP Fast Open（有 TFO）：
  Client ──── SYN + DATA ───────────────▶ Server   ← 第一个 RTT 携带数据！
  Client ◀─── SYN+ACK + ACK ──────────── Server
  Client ──── ACK ───────────────────────▶ Server
  → 立即开始数据传输，节省 1 RTT
```

---

## 2. Fast Open Cookie

### 2.1 TFO Cookie 生成

```c
// net/ipv4/tcp_fastopen.c — fastopen_init
static void fastopen_init(void)
{
    // TFO Cookie = AES_128(secret_key, client_IP, timestamp)
    // 包含客户端 IP 和有效期

    // 服务器首次收到无 cookie 的 SYN
    // 生成 cookie 并通过 SYN+ACK 返回给客户端
}
```

### 2.2 fastopen_cookie_gen

```c
// net/ipv4/tcp_fastopen.c — fastopen_cookie_gen
static __u32 fastopen_cookie_gen(struct sock *sk,
                              struct request_sock *req)
{
    // Cookie = AES_128(key, client_ip, timestamp, server_port)
    // 只保留 4 字节，安全性靠 AES 的加密强度

    return cookie;
}
```

---

## 3. TFO 连接建立

### 3.1 tcp_v4_send_synack — 发送 SYN+ACK + Cookie

```c
// net/ipv4/tcp_fastopen.c — tcp_v4_send_synack
static int tcp_v4_send_synack(...)
{
    // 首次 SYN（无 cookie）：生成 cookie
    if (!req->tfo_cookie) {
        cookie = fastopen_cookie_gen(sk, req);
        // 放入 SYN+ACK 的 TFO option
    }
}
```

### 3.2 tcp_v4_syn_recv_sock — 收到 SYN+ACK 后

```c
// net/ipv4/tcp_fastopen.c — tcp_v4_syn_recv_sock
// 客户端收到 SYN+ACK 后，验证 cookie 并缓存
// 下次连接时，直接在 SYN 中携带数据和 cookie
```

---

## 4. TFO 数据发送

### 4.1 sendmsg + TFO

```c
// net/ipv4/tcp.c — tcp_sendmsg_fastopen
int tcp_sendmsg_fastopen(struct sock *sk, struct msghdr *msg, int *size)
{
    // 在 socket 上标记 TFO
    if (sk->sk_state == TCP_CLOSE) {
        // 使用 TFO 发送数据
        return tcp_v4_connect_fastopen(sk, msg, *size);
    }
}
```

---

## 5. sysctl 参数

```bash
# 启用 TFO（服务器）：
echo 1 > /proc/sys/net/ipv4/tcp_fastopen

# 位掩码：
# 0 = 关闭
# 1 = 客户端启用
# 2 = 服务器启用
# 3 = 两者启用

# TFO blacklist：
# /proc/sys/net/ipv4/tcp_fastopen_blackhole_timeout_set
# 设置为 1 可防止 TFO 黑洞攻击

# TFO 最大 cookie 有效期：
# /proc/sys/net/ipv4/tcp_fastopen_key
```

---

## 6. 限制与安全

```
TFO 限制：
  1. 首个 SYN 的数据大小限制（通常 < MSS）
  2. SYN 数据不能被重传
  3. cookie 有有效期（通常 14 天）

TFO 安全问题：
  1. TFO 黑洞攻击：
     防火墙丢弃带数据的 SYN
     解决方案：tcp_fastopen_blackhole_timeout_set
  2. Cookie 预测攻击：
     使用强密钥，定期轮换
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/tcp_fastopen.c` | `fastopen_cookie_gen`、`tcp_sendmsg_fastopen`、`tcp_v4_send_synack` |

---

## 8. 西游记类喻

**TCP Fast Open** 就像"取经的预授权快递"——

> 传统方式是：先派人去打招呼（1 RTT SYN），对方确认后再寄快递（第二个 RTT DATA）。TFO 像提前和对方建立信任关系，约定一个暗号（Cookie）。下次再送快递时，人和货一起出发（SYN+DATA），对方看到暗号就直接收货，不用再确认。这就是为什么 HTTP/2 和 HTTP/3 的连接时间大幅缩短——提前建立了信任，快递到了直接收。

---

## 9. 关联文章

- **inet_stream_connect**（article 143）：TCP 连接建立
- **tcp_syn_cookie**（article 156）：TFO 的 cookie 机制借鉴了 SYN Cookie