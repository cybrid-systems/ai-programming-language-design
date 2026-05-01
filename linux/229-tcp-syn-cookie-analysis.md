# TCP SYN Cookie 机制分析

> 基于 Linux 7.0-rc1 内核源码，文件：`net/ipv4/syncookies.c`、`net/ipv4/tcp_input.c`

## 1. 背景：TCP_MAX_SYNACK_ACK_BACKLOG 溢出攻击

在经典的 TCP 三次握手中，服务器收到 SYN 后必须在内存中分配 `struct request_sock` 保存连接信息，等待客户端的 ACK。如果攻击者发送大量 SYN 但从不回复 ACK，这些半开连接（half-open）会耗尽服务器的内存和 `listen socket` 的 backlog 队列。

Linux 的 `listen(backlog)` 默认值通常只有 128（`SOMAXCONN`），即使调大，当攻击流量达到每秒数万 SYN 时，队列仍然会在 `inet_csk_reqsk_queue_is_full()` 返回 true 时开始溢出。

SYN Cookie 的核心思想是：**服务器收到 SYN 后，不分配内存就回复一个特殊的序列号（SYN+Cookie）**，只有当服务器收到那个 Cookie ACK 并且校验通过后，才真正分配内存创建 `request_sock`。这使得攻击者无法用半开连接耗尽服务器内存。

关键代码入口在 `tcp_conn_request()`（`tcp_input.c:7598`）：

```c
// tcp_input.c:7616
syncookies = READ_ONCE(net->ipv4.sysctl_tcp_syncookies);

if (syncookies == 2 || inet_csk_reqsk_queue_is_full(sk)) {
    want_cookie = tcp_syn_flood_action(sk, rsk_ops->slab_name);
    if (!want_cookie)
        goto drop;
}
```

- `syncookies == 2`：强制始终使用 cookie（sysctl 设置为 2）
- `inet_csk_reqsk_queue_is_full(sk)`：backlog 满了，自动启用 cookie

## 2. `tcp_synq_overflow()` 与溢出标记

每当内核需要记录一次 SYNs 队列溢出时，调用 `tcp_synq_overflow()`（`tcp.h:635`）。这个函数写入一个"最后溢出时间戳"，用于后续判断是否处于 flood 状态。

```c
// tcp.h:635
static inline void tcp_synq_overflow(const struct sock *sk)
{
    unsigned int last_overflow;
    unsigned int now = jiffies;

    if (sk->sk_reuseport) {
        struct sock_reuseport *reuse;
        reuse = rcu_dereference(sk->sk_reuseport_cb);
        if (likely(reuse)) {
            last_overflow = READ_ONCE(reuse->synq_overflow_ts);
            // 每秒最多更新一次，避免过度 dirty cache line
            if (!time_between32(now, last_overflow, last_overflow + HZ))
                WRITE_ONCE(reuse->synq_overflow_ts, now);
            return;
        }
    }
    // 非 reuseport 路径：写入 tp->rx_opt.ts_recent_stamp
    last_overflow = READ_ONCE(tcp_sk(sk)->rx_opt.ts_recent_stamp);
    if (!time_between32(now, last_overflow, last_overflow + HZ))
        WRITE_ONCE(tcp_sk_rw(sk)->rx_opt.ts_recent_stamp, now);
}
```

注意它只每秒最多写入一次（通过 `time_between32` 限制）。这是因为 `ts_recent_stamp` 本来是 TCP timestamp 选项的时间戳字段，被借用为溢出标记，避免与真正的 timestamp 功能冲突。

## 3. `tcp_synq_no_recent_overflow()` — 判断是否处于 flood

```c
// tcp.h:659
static inline bool tcp_synq_no_recent_overflow(const struct sock *sk)
{
    unsigned int last_overflow;
    unsigned int now = jiffies;

    if (sk->sk_reuseport) {
        struct sock_reuseport *reuse;
        reuse = rcu_dereference(sk->sk_reuseport_cb);
        if (likely(reuse)) {
            last_overflow = READ_ONCE(reuse->synq_overflow_ts);
            // 在 [last_overflow - HZ, last_overflow + TCP_SYNCOOKIE_VALID] 区间内
            // → 最近刚溢出过，处于 flood 状态，不允许 cookie
            return !time_between32(now, last_overflow - HZ,
                                   last_overflow + TCP_SYNCOOKIE_VALID);
        }
    }
    last_overflow = READ_ONCE(tcp_sk(sk)->rx_opt.ts_recent_stamp);
    // TCP_SYNCOOKIE_VALID = MAX_SYNCOOKIE_AGE * TCP_SYNCOOKIE_PERIOD
    //                      = 2 * 60 * HZ = 120 秒
    return !time_between32(now, last_overflow - HZ,
                           last_overflow + TCP_SYNCOOKIE_VALID);
}
```

- 返回 `true` = 没有近期溢出，可以使用 cookie
- 返回 `false` = 最近刚溢出，拒绝 cookie（防止在 cookie 机制本身被攻击时继续使用）

`TCP_SYNCOOKIE_VALID` 定义在 `tcp.h:629`：

```c
#define MAX_SYNCOOKIE_AGE       2
#define TCP_SYNCOOKIE_PERIOD    (60 * HZ)   // 每 60 秒一个计数周期
#define TCP_SYNCOOKIE_VALID     (MAX_SYNCOOKIE_AGE * TCP_SYNCOOKIE_PERIOD)  // 120 秒
```

## 4. `cookie_hash()` — 6-tuple 哈希与 count 编码

SYN Cookie 的核心是一个加密安全的哈希。`cookie_hash()`（`syncookies.c:49`）使用 SipHash-2-4（由 `siphash_4u32` 实现），对 6 元组加上 count 生成 32 位哈希：

```c
// syncookies.c:49
static u32 cookie_hash(__be32 saddr, __be32 daddr, __be16 sport, __be32 dport,
                       u32 count, int c)
{
    net_get_random_once(syncookie_secret, sizeof(syncookie_secret));
    return siphash_4u32((__force u32)saddr, (__force u32)daddr,
                        (__force u32)sport << 16 | (__force u32)dport,
                        count, &syncookie_secret[c]);
}
```

- **6-tuple**：`saddr, daddr, sport, dport, count, secret[c]`
- `secret[0]` 和 `secret[1]` 是启动时一次性随机生成的 128 位密钥（`net_get_random_once`），存放在 `syncookie_secret[2]` 数组中
- `count` = `tcp_cookie_time()`，每 60 秒递增一次的时间计数器

调用方有两个不同用途：
- `c=0`：用于第一层哈希（不含 count）
- `c=1`：用于第二层哈希（含 count）

## 5. `secure_tcp_syn_cookie()` — Cookie 的生成公式

```c
// syncookies.c:84
static __u32 secure_tcp_syn_cookie(__be32 saddr, __be32 daddr, __be16 sport,
                                   __be32 dport, __u32 sseq, __u32 data)
{
    u32 count = tcp_cookie_time();
    return (cookie_hash(saddr, daddr, sport, dport, 0, 0) + sseq +
            (count << COOKIEBITS) +
            ((cookie_hash(saddr, daddr, sport, dport, count, 1) + data)
             & COOKIEMASK));
}
```

其中 `COOKIEBITS = 24`（`syncookies.c:18`），`COOKIEMASK = ((__u32)1 << 24) - 1`。

Cookie 的结构如下：

```
cookie = [count << 24] | [hash2 & 0xFFFFFF]
          ↑ 高 8 位是 count
                                  ↑ 低 24 位是含 count 的哈希 + data
```

- `data` 参数携带 MSS 索引（`mssind`），在 `__cookie_v4_init_sequence` 中传入
- `count` 每 60 秒变化一次，使得同一个 client IP 的 cookie 周期性过期，无法被重放
- `sseq`（客户端 ISN）被混入第一层哈希，防止攻击者预测 cookie 值

## 6. `__cookie_v4_init_sequence()` — MSS 编码

```c
// syncookies.c:152
u32 __cookie_v4_init_sequence(const struct iphdr *iph, const struct tcphdr *th,
                              u16 *mssp)
{
    int mssind;
    const __u16 mss = *mssp;

    for (mssind = ARRAY_SIZE(msstab) - 1; mssind ; mssind--)
        if (mss >= msstab[mssind])
            break;
    *mssp = msstab[mssind];   // 向下对齐到表中最接近的值

    return secure_tcp_syn_cookie(iph->saddr, iph->daddr,
                                 th->source, th->dest, ntohl(th->seq),
                                 mssind);   // data = mssind（0~3）
}
```

MSS 表定义在 `syncookies.c:144`：

```c
static __u16 const msstab[] = {
    536,    // 0
    1300,   // 1
    1440,   // 2: PPPoE
    1460,   // 3
};
```

MSS 被编码为表索引（0~3），而不是直接存储 MSS 值，这样可以节省空间（2 bits 就够了），剩余的位数留给其他信息。

调用路径：

```
tcp_conn_request()
  → want_cookie ? cookie_init_sequence()      // tcp.h:2566
       → tcp_synq_overflow(sk)                 // 记录溢出
       → __NET_INC_STATS(..., LINUX_MIB_SYNCOOKIESSENT)
       → ops->cookie_init_seq(skb, mss)        // → __cookie_v4_init_sequence
```

`cookie_init_sequence()` 是内联包装器，定义在 `tcp.h:2566`，它调用 `ops->cookie_init_seq` 函数指针，对于 IPv4 即 `__cookie_v4_init_sequence`。

## 7. `cookie_init_timestamp()` — SYN-ACK 时间戳编码

当 `CONFIG_SYN_COOKIES` 开启且 `tcp timestamps` 可用时，`cookie_init_timestamp()`（`syncookies.c:62`）在发送 SYN-ACK 时对 timestamp 字段进行特殊编码，携带 TCP 选项信息：

```c
// syncookies.c:62
u64 cookie_init_timestamp(struct request_sock *req, u64 now)
{
    const struct inet_request_sock *ireq = inet_rsk(req);
    u64 ts, ts_now = tcp_ns_to_ts(false, now);
    u32 options = 0;

    // 编码 WScale / SACK / ECN 到 options 字段
    options = ireq->wscale_ok ? ireq->snd_wscale : TS_OPT_WSCALE_MASK;
    if (ireq->sack_ok)
        options |= TS_OPT_SACK;
    if (ireq->ecn_ok)
        options |= TS_OPT_ECN;

    // 将 options 填入 timestamp 的低 6 位
    ts = (ts_now >> TSBITS) << TSBITS;  // 清零低 6 位
    ts |= options;
    // 如果编码后 ts 超过了当前时间，向后退一个 64-unit 周期
    if (ts > ts_now)
        ts -= (1UL << TSBITS);

    if (tcp_rsk(req)->req_usec_ts)
        return ts * NSEC_PER_USEC;
    return ts * NSEC_PER_MSEC;
}
```

Timestamp 字段 32 位中，低 6 位（`TSBITS = 6`，`syncookies.c:44`）用于编码 TCP 选项：

```
| 31 ...   6 |  5  |  4   | 3 2 1 0 |
|  Timestamp | ECN | SACK | WScale  |
```

- `WScale`：4 bits，取值 0~15（`TS_OPT_WSCALE_MASK = 0xf`）
- `SACK`：1 bit（`BIT(4)`）
- `ECN`：1 bit（`BIT(5)`）
- **注意没有 `TS_OPT_TIMESTAMP`**：如果 ACK 中带有 timestamp 选项，说明客户端本来就支持 timestamp，不需要额外编码

当原始 SYN 不带 window scaling 选项时，`wscale_ok = false`，此时 `options` 被设为 `TS_OPT_WSCALE_MASK (0xf)`，在后续解码时（`cookie_timestamp_decode`）会特殊处理为"不使用 window scaling"。

在 `tcp_output.c:3979`，`cookie_init_timestamp` 被调用来设置 SYN-ACK 的 delivery_time：

```c
// tcp_output.c:3979
if (unlikely(synack_type == TCP_SYNACK_COOKIE && ireq->tstamp_ok))
    skb_set_delivery_time(skb, cookie_init_timestamp(req, now),
                          SKB_CLOCK_MONOTONIC);
```

## 8. `__cookie_v4_check()` — ACK 阶段 Cookie 验证

当服务器收到客户端的第三次握手 ACK 时，需要从 ack_seq 中提取并验证 cookie。这一步骤发生在 `cookie_tcp_check()`（`syncookies.c:332`）中：

```c
// syncookies.c:332
static struct request_sock *cookie_tcp_check(struct net *net, struct sock *sk,
                                             struct sk_buff *skb)
{
    ...
    if (tcp_synq_no_recent_overflow(sk))   // ← 防御：检查是否处于 flood
        goto out;

    mss = __cookie_v4_check(ip_hdr(skb), tcp_hdr(skb));
    if (!mss) {
        __NET_INC_STATS(net, LINUX_MIB_SYNCOOKIESFAILED);
        goto out;
    }
    ...
}
```

`__cookie_v4_check()`（`syncookies.c:184`）执行 cookie 的逆向解析：

```c
// syncookies.c:184
int __cookie_v4_check(const struct iphdr *iph, const struct tcphdr *th)
{
    __u32 cookie = ntohl(th->ack_seq) - 1;
    __u32 seq = ntohl(th->seq) - 1;
    __u32 mssind;

    mssind = check_tcp_syn_cookie(cookie, iph->saddr, iph->daddr,
                                  th->source, th->dest, seq);

    return mssind < ARRAY_SIZE(msstab) ? msstab[mssind] : 0;
}
```

`check_tcp_syn_cookie()`（`syncookies.c:108`）负责实际的校验逻辑：

```c
// syncookies.c:108
static __u32 check_tcp_syn_cookie(__u32 cookie, __be32 saddr, __be32 daddr,
                                  __be16 sport, __be16 dport, __u32 sseq)
{
    u32 diff, count = tcp_cookie_time();

    // Step 1: 剥离第一层哈希 + sseq，得到 count 和 hash2
    cookie -= cookie_hash(saddr, daddr, sport, dport, 0, 0) + sseq;

    // cookie 现在 = (count << 24) ^ (hash2 & 0xFFFFFF)
    diff = (count - (cookie >> COOKIEBITS)) & ((__u32)-1 >> COOKIEBITS);
    // diff = 当前 count 与 cookie 中编码的 count 的差值（分钟数）
    if (diff >= MAX_SYNCOOKIE_AGE)     // 如果 diff >= 2，cookie 过期
        return (__u32)-1;

    // Step 2: 用 count - diff 重新计算第二层哈希，提取 data（mssind）
    return (cookie - cookie_hash(saddr, daddr, sport, dport,
                                 count - diff, 1)) & COOKIEMASK;
}
```

验证流程：
1. 从 `ack_seq - 1` 提取 cookie
2. 减去第一层哈希和客户端 ISN，得到 `(count << 24) | (hash2 & 0xFFFFFF)`
3. 计算 `diff = 当前count - cookie中的count`（模 2^8，因为右移后高位被截断）
4. 如果 `diff >= 2`，cookie 过期，拒绝
5. 用 `(count - diff)` 重新计算第二层哈希，与 cookie 低 24 位相减，得到 `mssind`

`MAX_SYNCOOKIE_AGE = 2` 意味着 cookie 只在最近 2 个时间周期（最多约 120 秒）内有效。

## 9. `cookie_timestamp_decode()` — 从 Timestamp 解码 TCP 选项

```c
// syncookies.c:235
bool cookie_timestamp_decode(const struct net *net,
                             struct tcp_options_received *tcp_opt)
{
    u32 options = tcp_opt->rcv_tsecr;   // 取自 ACK 的 TSval echo field

    if (!tcp_opt->saw_tstamp) {
        tcp_clear_options(tcp_opt);
        return true;
    }
    if (!READ_ONCE(net->ipv4.sysctl_tcp_timestamps))
        return false;

    tcp_opt->sack_ok = (options & TS_OPT_SACK) ? TCP_SACK_SEEN : 0;
    if (tcp_opt->sack_ok && !READ_ONCE(net->ipv4.sysctl_tcp_sack))
        return false;

    // 0xf 表示原始 SYN 没有携带 window scaling 选项
    if ((options & TS_OPT_WSCALE_MASK) == TS_OPT_WSCALE_MASK)
        return true;  // 不使用 window scaling

    tcp_opt->wscale_ok = 1;
    tcp_opt->snd_wscale = options & TS_OPT_WSCALE_MASK;

    return READ_ONCE(net->ipv4.sysctl_tcp_window_scaling) != 0;
}
```

注意 `rcv_tsecr` 是客户端 ACK 中回显的服务器 timestamp。如果原始 SYN-ACK 的 timestamp 经过 `cookie_init_timestamp` 编码，那么 `rcv_tsecr` 的低 6 位就包含了 TCP 选项信息。

## 10. Timestamp 溢出与回绕处理

`cookie_init_timestamp()`（`syncookies.c:62`）中有如下逻辑处理溢出：

```c
// syncookies.c:74
ts = (ts_now >> TSBITS) << TSBITS;  // 清零低 6 位
ts |= options;
if (ts > ts_now)                      // 如果编码后超过了当前时间
    ts -= (1UL << TSBITS);            // 退回到前一个 64-unit 周期
```

`TSBITS = 6` 意味着 timestamp 的低 6 位被用作选项编码位。`tcp_time_stamp` 每 64 单位递增一次（因为 `ts_now >> 6` 决定高 26 位）。如果清零低 6 位后重新编码的 timestamp 大于当前时间，说明当前时间已经进入了下一个 64-unit 周期，此时需要退回去以保证：`ts <= ts_now`。

在 `cookie_timestamp_decode` 中，这个回绕后的值被正常解析（因为 `rcv_tsecr` 本身是客户端回显的，客户端会按相同的规则生成）。

## 11. 攻击防护：`tcp_syncookies` 与 sysctl

`sysctl_tcp_syncookies` 控制 cookie 机制的启用程度，定义在 `net/ipv4/sysctl_net_ipv4.c:1041`：

```c
// sysctl_net_ipv4.c:1041
{
    .procname   = "tcp_syncookies",
    .data       = &init_net.ipv4.sysctl_tcp_syncookies,
    .maxlen     = sizeof(u8),
    .mode       = 0644,
    .proc_handler = proc_dou8vec_minmax,
},
```

`sysctl_tcp_syncookies` 有三个取值：

| 值 | 含义 |
|----|------|
| `0` | 关闭 SYN Cookie |
| `1` | **默认值**；backlog 满时启用 cookie（自动模式） |
| `2` | 强制始终使用 cookie，不检测 backlog 是否满 |

在 `syncookies.c:417` 的 `cookie_v4_check()` 中检查：

```c
// syncookies.c:417
if (!READ_ONCE(net->ipv4.sysctl_tcp_syncookies) ||
    !th->ack || th->rst)
    goto out;
```

- 如果 `sysctl_tcp_syncookies == 0`，直接跳过 cookie 验证
- 如果报文不是 ACK（如 RST），也跳过

同时在 `tcp_conn_request()` 中：
- `syncookies == 2`：即使 backlog 未满也强制使用 cookie
- `syncookies == 1`（默认）：只有当 `inet_csk_reqsk_queue_is_full(sk)` 时才使用

### 防护能力分析

SYN Cookie 防止的是 **memory exhaustion attack**（内存耗尽攻击），但它有以下限制：

1. **无法防止 RST 攻击**：攻击者伪造 RST 可以直接终止连接（与 cookie 无关）
2. **无法防止 ACK flood**：如果攻击者能猜出 cookie 值（高质量随机数使暴力猜解不可行），可以耗尽服务器
3. **MSS 精度受限**：只支持 4 种固定 MSS 值（536/1300/1440/1460），实际 MSS 会被向下对齐
4. **不存储 SYN 数据**：cookie 机制下，SYN 所携带的数据在第一次握手中丢失（因为服务器没有保存状态），除非使用 `TCP_LOSS` 或其他机制

### 时间窗口验证的安全性

`check_tcp_syn_cookie` 使用 `count` 差值（`diff`）来验证 cookie 的时间有效性：

- `diff < 2`：cookie 有效（最近 2 个 60 秒周期内生成）
- `diff >= 2`：cookie 过期

这意味着攻击者如果想重放一个旧 cookie，必须在 2 分钟内完成，且即使重放成功，服务器也会因为 `tcp_synq_no_recent_overflow()` 的检查而无法通过验证（如果当前正处于 flood 状态）。

## 12. 完整流程图

```
客户端                    服务器                     攻击者
  |                         |                         |
  |--- SYN --------------> |                         |
  |                         | backlog 满？           |
  |                         | → tcp_synq_overflow()  |
  |                         | ← SYN+Cookie, ack_seq=Cookie
  |                         | (不分配 request_sock)  |
  |                         |                         | X 大量伪造源 IP
  |                         |                         |
  |--- ACK (Cookie) -----> |                         |
  |                         | tcp_synq_no_recent_overflow()
  |                         | check_tcp_syn_cookie()   ← 验证 cookie
  |                         | cookie_timestamp_decode()
  |                         | → cookie_tcp_reqsk_alloc()
  |                         | → tcp_get_cookie_sock()
  |<-- 3WHS 完成 ---------> |                         |
```

## 关键数据总结

| 符号 | 值 | 说明 |
|------|----|------|
| `COOKIEBITS` | 24 | cookie 低 24 位存放 hash |
| `MAX_SYNCOOKIE_AGE` | 2 | cookie 有效期 = 2 × 60 秒 |
| `TCP_SYNCOOKIE_PERIOD` | `60 * HZ` | 计数周期 |
| `TCP_SYNCOOKIE_VALID` | `120` 秒 | 允许的时间窗口 |
| `TSBITS` | 6 | timestamp 低 6 位编码选项 |
| MSS 表 | {536, 1300, 1440, 1460} | 4 个固定值，编码为 0~3 |
| `TS_OPT_WSCALE_MASK` | `0xf` | 无 window scaling 时的标记值 |

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

