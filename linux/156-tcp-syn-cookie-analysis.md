# 156-tcp_syn_cookie — SYN Cookie深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/syncookies.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**SYN Cookie** 是 Linux 防御 SYN Flood 攻击的技术：在 SYN Queue 满时，不保存 SYN 半连接，而是将连接参数编码到 SYN+ACK 的序列号中，收到正确的 ACK 才建立连接。

---

## 1. SYN Flood 攻击原理

```
SYN Flood：
  攻击者发送大量 SYN，但不完成三次握手
  半连接队列（SYN Queue）被打满
  正常用户的 SYN 无法被接受 → 服务不可用

防御：
  1. 增大 SYN Queue
  2. 启用 SYN Cookie（本文）
  3. tcp_syncookies = 2（强制启用）
```

---

## 2. SYN Cookie 原理

```
正常三次握手：
  Client ──SYN(seq=x)──────────────────▶ Server
  Client ◀──SYN+ACK(seq=y, ack=x+1)──── Server
  Client ──ACK(ack=y+1)──────────────▶ Server
  → 连接建立

SYN Cookie：
  Server ──SYN+ACK(seq=cookie)──────▶ Client
           (cookie = f(src_ip, dst_ip, src_port, dst_port, timestamp, MSS))
  如果 Client 返回正确的 ACK(ack=cookie+1)
  → 连接建立
  如果 Client 不返回 ACK 或 ACK 错误
  → 半连接不被保存 → 不占用内存
```

---

## 3. 核心算法

### 3.1 cookie_v4_init_sequence — 生成 Cookie

```c
// net/ipv4/syncookies.c — cookie_v4_init_sequence
__u32 cookie_v4_init_sequence(struct sk_buff *skb, __u16 *mssp)
{
    struct tcp_options_received tcp_opt;
    struct inet_request_sock *ireq;
    __u32 seq;

    // 1. 解析 MSS
    tcp_parse_options(skb, &tcp_opt, 0, NULL);

    // 2. 生成 Cookie
    // Cookie = MD5(src_ip, dst_ip, src_port, dst_port, timestamp) % 2^24
    // 高 5 位：时间戳（每 64 秒递增）
    // 中 10 位：MSS 编码
    // 低 19 位：秒级计数

    seq = secure_tcp_syn_cookie(iph->saddr, iph->daddr,
                                th->source, th->dest,
                                ntohl(th->seq));

    // 加上 MSS 编码
    seq |= (__u32)(*mssp << 24);

    // 加上时间戳（低 5 位）
    seq |= (((u32)TCP_COOKIE_PERIOD - 1) & 0x1F);

    return seq;
}
```

### 3.2 secure_tcp_syn_cookie — 哈希函数

```c
// net/ipv4/syncookies.c — secure_tcp_syn_cookie
__u32 secure_tcp_syn_cookie(__be32 saddr, __be32 daddr,
                             __be16 sport, __be16 dport, __u32 sseq)
{
    u32 length = (ntohs(dport) << 16) + ntohs(sport);
    u32 hash;
    __u32 tmp;

    // TCP Cookie = (seq_base + MD5) % 2^24
    // 包含：src_ip, dst_ip, sport, dport, sseq, timestamp_secret

    hash = jhash_3words((__force u32)saddr,
                         (__force u32)daddr,
                         length,
                         TCP_COOKIE_PERIOD);

    tmp = (hash ^ sseq) + (secret1 + (secret2 << 16));
    tmp = tmp ^ ((tmp >> 17) ^ (tmp >> 14) ^ (tmp >> 13));
    tmp = (tmp ^ (tmp << 6) ^ (tmp << 3)) >> 10;

    return (seq + tmp) & TCP_SYN_COOKIE_MASK;
}
```

---

## 4. 验证 Cookie（收到 ACK）

### 4.1 cookie_v4_check — 验证 ACK

```c
// net/ipv4/syncookies.c — cookie_v4_check
struct sock *cookie_v4_check(struct sock *sk, struct sk_buff *skb,
                            __u32 cookie)
{
    struct tcp_options_received tcp_opt;
    struct inet_request_sock *ireq;
    __u32 seq;
    int mss;

    // 1. 从 cookie 中提取 MSS
    mss = (cookie & 0x3FF) >> 12;  // 提取 MSS 编码
    mss = mss_guess_table[mss];    // 查表获取实际 MSS

    // 2. 验证 cookie 时间戳
    if ((cookie >> 24) != ((TCP_COOKIE_PERIOD - 1) & 0x1F))
        return NULL;

    // 3. 验证 ACK
    // cookie' = secure_tcp_syn_cookie(src, dst, sport, dport, ack-1)
    // 如果 cookie' == cookie（低 24 位）
    // → ACK 有效
    seq = ntohl(th->ack_seq) - 1;

    if (!secure_tcp_syn_cookie(saddr, daddr, sport, dport, seq))
        return NULL;  // 无效 ACK

    // 4. 恢复连接
    req = cookie_tcp_reqsk_alloc(sk, skb, &addr);
    if (!req)
        return NULL;

    // 设置 MSS
    ireq->mss = mss;

    // 建立连接
    tcp_v4_syn_recv_sock(req);

    return icsk->icsk_accept_queue.rskq_accept_head;
}
```

---

## 5. MSS 编码表

```c
// net/ipv4/syncookies.c — MSS 猜测表
static const u16 mss_guess_table[16] = {
    536,    // 0: 典型 MTU 576 - 40(IP+TCP头)
    1300,   // 1: 常见宽带 MTU
    1440,   // 2: 典型 MTU
    1460,   // 3: 常见 MTU (以太网 MTU1500)
    1500,   // 4: 最大 MTU
    1500,   // 5: 保持
    1700,   // 6: VPN 头
    2000,   // 7: FDDI
    4352,   // 8: HiFDDI
    65535,  // 9: 最大可能 MSS
    ...
};
```

---

## 6. sysctl 参数

```bash
# 启用 SYN Cookie（仅在 SYN Queue 满时使用）：
echo 1 > /proc/sys/net/ipv4/tcp_syncookies

# 始终使用 SYN Cookie（强制）：
echo 2 > /proc/sys/net/ipv4/tcp_syncookies

# 关闭 SYN Cookie：
echo 0 > /proc/sys/net/ipv4/tcp_syncookies

# 半连接队列长度：
cat /proc/sys/net/ipv4/tcp_max_syn_backlog
```

---

## 7. SYN Cookie 限制

```
SYN Cookie 限制：
  1. 不支持 TCP 选项（如 Window Scaling、SACK）
     → 只有 16 种固定的 MSS 值
  2. 不支持某些 TCP 扩展
  3. 时间戳会被覆盖（高 5 位复用）
  4. 连接建立后需要重新设置 window

实际影响：
  - 无法使用 Window Scaling → 限制大带宽连接
  - 无法使用 SACK → 影响丢包重传效率
  - 适合低带宽、抗攻击场景
```

---

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/syncookies.c` | `cookie_v4_init_sequence`、`secure_tcp_syn_cookie`、`cookie_v4_check` |

---

## 9. 西游记类喻

**SYN Cookie** 就像"天庭的预约凭证"——

> 正常情况下，天庭的客房（SYN Queue）会记录每个预约的客人（半连接）。但如果有人恶意预约了很多房间不入住（攻击者发大量 SYN），客房会被占满，真正需要住宿的客人（正常用户）无法预约。SYN Cookie 的做法是：不记录预约人信息，而是发给他一张特殊的预约凭证（cookie），凭证上用暗号记录了预约时间（时间戳）、房间大小（MSS）和房间号（序列号）。客人下次凭这张凭证来时（ACK），天庭先验证暗号是否正确，正确才让他入住。恶意预约者没有正确的暗号（ACK 不对），凭证就失效了。好处是天庭不用记录大量的预约信息（节省内存），坏处是没法给客人提供最好的房间（无法用 Window Scaling）。

---

## 10. 关联文章

- **inet_stream_connect**（article 143）：TCP 连接建立
- **tcp_state_machine**（article 147）：SYN_RECV 状态
- **netfilter**（相关）：SYN Cookie 是防御 SYN Flood 的网络层手段