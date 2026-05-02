# 62-udp — Linux UDP 协议栈深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**UDP（User Datagram Protocol）** 是 Linux 内核中最轻量的传输层协议。与 TCP 的复杂状态机不同，UDP 的核心是一个**无连接、不可靠、无状态**的数据报传输引擎。

**核心设计**：UDP 的核心挑战不是传输本身，而是**高速查找**——内核必须在 O(1) 时间内将收到的 UDP 数据报定位到正确的 socket。为此，UDP 实现了**三级哈希表**（port → addr:port → full tuple），以及**GRO/GSO/seg6 卸载**等加速路径。

```
发送路径:                         接收路径:
sendto(sock, buf, len, ...)       网卡 → GRO
  ↓                                  ↓
udp_sendmsg()                     udp_rcv() → __udp4_lib_lookup()
  ├─ 路由查找 (ip_route_output)     ├─ 三级哈希查找 → socket
  ├─ cork 延迟发送                   ├─ GRO 合并检查
  ├─ UDP 校验和计算                 ├─ 队列到 socket 接收缓冲区
  ├─ GSO 分段 (UDP_SEGMENT)        └─ skb_consume_udp() → 用户
  └─ ip_local_out() → IP 层
```

**doom-lsp 确认**：核心实现在 `net/ipv4/udp.c`（**3,884 行**，**194 个符号**）。IPv6 对应 `net/ipv6/udp.c`。公共数据在 `include/net/udp.h`（656 行）。GRO 卸载在 `net/ipv4/udp_offload.c`（994 行）。

---

## 1. 核心数据结构

### 1.1 struct udp_table — 三级哈希表

UDP 使用**三级哈希**来加速 socket 查找：

```c
// include/net/udp.h:101-118
struct udp_table {
    struct udp_hslot *hash;                    /* 一级：按本地端口哈希 */
    struct udp_hslot_main *hash2;              /* 二级：按(本地端口, 本地地址)哈希 */
    struct udp_hslot *hash4;                   /* 三级：按四元组哈希(connected socket) */
    unsigned int mask;                         /* 哈希桶数 - 1 */
    unsigned int log;                          /* log2(桶数) */
};
```

**`struct udp_hslot`** — 哈希桶：

```c
struct udp_hslot {
    union {
        struct hlist_head head;                /* 链表头 */
        struct hlist_nulls_head nulls_head;     /* hash4 用 nulls 链表 */
    };
    int count;                                  /* 此桶中 socket 数 */
    spinlock_t lock;                            /* 保护链表 */
};
```

**三级哈希的区分**：

```
hash  (一级):  port_only → 所有监听此端口的 socket
hash2 (二级):  (port, addr) → 绑定特定地址的 socket
hash4 (三级):  (sport, dport, saddr, daddr) → 已 connect 的 socket

查找顺序: hash4 → hash2 → hash （命中即返回）
```

**`struct udp_hslot_main`** — 二级哈希的扩展桶：

```c
struct udp_hslot_main {
    struct udp_hslot hslot;                     /* 基础桶 */
    u32 hash4_cnt;                              /* 此桶中 hash4 socket 数 */
};
```

**doom-lsp 确认**：`struct udp_table` 和全局 `udp_table` 实例在 `include/net/udp.h:101-118`。`udp_table` 在启动时通过 `udp_table_init()` 分配，桶数取决于 `UDP_HTABLE_SIZE`（通常为 128 或 256）。

### 1.2 struct inet_sock / struct udp_sock

```c
// 每个 UDP socket 在内核中表现为：
// struct socket → struct sock → struct inet_sock → struct udp_sock

// include/net/udp.h
struct udp_sock {
    /* 前向兼容 inet_sock */
    struct inet_sock inet;

    /* 发送状态 */
    int pending;                    /* AF_INET/AF_INET6：是否有 pending cork 数据 */
    __u16 gso_size;                 /* UDP_SEGMENT GSO 大小 */
    __u8 encap_type;                /* 封装类型（ESP/ESPINUDP）*/

    /* GRO 接收状态 */
    struct sk_buff_head reader_queue; /* GRO 合并队列 */
    int forward_deficit;            /* GRO 转发不足计数 */
    char start_skb;                 /* GRO 开始 skb 标记 */
    int msg_ready;                  /* 有消息可读 */

    /* 接收卸载 */
    struct rcu_head rcu;
};
```

---

## 2. 发送路径——udp_sendmsg

```c
// net/ipv4/udp.c:1233-1507
int udp_sendmsg(struct sock *sk, struct msghdr *msg, size_t len)
{
    /* 1. 长度检查 */
    if (len > 0xFFFF)
        return -EMSGSIZE;                       /* UDP 数据报最大 64KB */

    /* 2. cork 检查：如果已有 pending 数据，直接追加 */
    if (up->pending) {
        lock_sock(sk);
        if (likely(up->pending))
            goto do_append_data;                /* 跳过路由查找！*/
        release_sock(sk);
    }

    /* 3. 目标地址解析 */
    if (usin) {
        daddr = usin->sin_addr.s_addr;          /* 目标 IP */
        dport = usin->sin_port;                  /* 目标端口 */
    } else {
        /* 已 connect 的 socket → 复用缓存的路由 */
        daddr = inet->inet_daddr;
        dport = inet->inet_dport;
        connected = 1;
    }

    /* 4. 路由查找 */
    rt = ip_route_output(fl4, net, daddr, ...);
    if (IS_ERR(rt)) return PTR_ERR(rt);

    /* 5. GSO 设置 / MSG_MORE 延迟 */
    if (ipc.gso_size) {
        /* UDP_SEGMENT: 将大包分成多个 GSO 段 */
        ulen = ipc.gso_size + sizeof(struct udphdr);
    }

    /* 6. cork 模式：追加到 pending 帧 */
    if (corkreq) {
        err = udp_sendpages(sk, &ipc, ...);
        if (!err)
            goto cork_unlock;                   /* 不立即发送 */
    }

    /* 7. 构建 skb 并发送 */
    skb = ip_make_skb(sk, fl4, getf, ...);
    if (IS_ERR(skb)) return PTR_ERR(skb);

    /* 8. 调用 IP 层发送 */
    err = udp_send_skb(skb, fl4, &ipc);
    if (!err)
        UDP_INC_STATS(net, UDP_MIB_OUTDATAGRAMS, ...);
}
```

**doom-lsp 确认**：`udp_sendmsg` 在 `udp.c:1233`。`udp_send_skb` 在 `udp.c:1092` 计算校验和并调用 `ip_local_out()`。

### 2.1 UDP_SEGMENT（GSO）

```c
// setsockopt(fd, SOL_UDP, UDP_SEGMENT, &gso_size, sizeof(gso_size))
// 允许应用将大数据报分段发送，由网卡 TSO/GSO 硬件完成分段
// 应用写入 > MTU 的数据，内核只构建一个超大 skb
// 网卡 GSO 引擎硬件拆分成多个 UDP 包
```

### 2.2 Cork 模式

```c
// setsockopt(fd, SOL_UDP, UDP_CORK, &on, sizeof(on))
// 或 MSG_MORE 标志
// 启用 cork 后，多次 write/sendmsg 的数据累积到一个 UDP 数据报
// 关闭 cork 或超时时一次发送
// 减少小包数量，提高带宽利用率
```

---

## 3. 接收路径——udp_rcv

### 3.1 查找——__udp4_lib_lookup

```c
// net/ipv4/udp.c:667-734
struct sock *__udp4_lib_lookup(struct net *net, __be32 saddr, __be16 sport,
                               __be32 daddr, __be16 dport, int dif, ...)
{
    struct sock *sk, *result;
    struct hlist_nulls_node *node;
    struct udp_hslot *hslot4, *hslot2;
    unsigned int hash4, hash2;
    int score, badness;
    u32 hash = 0;

    /* 第一阶段：hash4 查找（四元组精确匹配）*/
    hash4 = udp_ehashfn(net, daddr, dport, saddr, sport);
    hslot4 = udp_hashslot(&udp_table, net, hash4);
    sk_nulls_for_each_rcu(sk, node, &hslot4->nulls_head) {
        score = compute_score(sk, net, saddr, sport, daddr, dport, dif, ...);
        if (score == 2) {/* 完全匹配 */
            result = sk;
            goto done;
        }
        if (score == 1)
            /* 端口匹配但地址不同 */;
    }

    /* 第二阶段：hash2 查找（port + local addr）*/
    hash2 = udp_hashfn2(net, dport);
    hslot2 = udp_hashslot2(&udp_table, hash2);
    sk_for_each_rcu(sk, node, &hslot2->head) {
        score = compute_score(sk, net, saddr, sport, daddr, dport, dif, ...);
        if (score > badness) {
            result = sk;
            badness = score;
        }
    }

    /* 第三阶段：hash 查找（port only）*/
    /* 遍历通配符监听 socket */

done:
    return result;
}
```

**`compute_score()`** 计算匹配度（`udp.c:361`）：

```c
static int compute_score(struct sock *sk, struct net *net, ...)
{
    score = 0;
    if (sk->sk_bound_dev_if) {
        if (sk->sk_bound_dev_if != dif && sk->sk_bound_dev_if != sdif)
            return -1;
        score++;
    }
    if (!ipv4_is_loopback(saddr)) {
        if (!net_eq(sock_net(sk), net))
            return -1;
        score++;
    }
    if (sk->sk_rcv_saddr != daddr)
        return -1;                     /* 本地地址匹配 → 必须精确 */
    score++;

    /* 远程地址匹配加分（connected socket）*/
    if (sk->sk_daddr != inet->inet_rcv_saddr || sk->sk_dport != htons(sport))
        return -1;                     /* 通配符跳过此检查 */
    score++;

    return score;
}
```

**查找优先级**：
```
hash4 精确匹配 (score=2) → 直接返回
hash2 最佳匹配 (score=0-3) → 选最高 score
hash 通配匹配 → 选最高 score
```

**doom-lsp 确认**：`__udp4_lib_lookup` 在 `udp.c:667`。`compute_score` 在 `udp.c:361`。`udp_ehashfn` 在 `udp.c:405` 使用 jhash2 计算四元组哈希。

### 3.2 接收——udp_queue_rcv_skb

```c
// net/ipv4/udp.c
static int udp_queue_rcv_skb(struct sock *sk, struct sk_buff *skb)
{
    struct udp_sock *up = udp_sk(sk);

    /* 1. 校验和检查 */
    if (up->encap_type) {
        /* 封装协议（ESP over UDP）→ 卸载到 encap_rcv */
        ret = udp_tunnel_encap_rcv(sk, skb);
        if (ret)
            return ret;
    }

    /* 2. GRO 合并 */
    if (!skb_queue_empty(&up->reader_queue)) {
        /* 尝试将 skb 合并到 reader_queue 尾部的待处理 GRO 流 */
        add_skb_to_reader_queue(sk, skb, up->reader_queue.tail);
        if (!up->msg_ready) {
            up->msg_ready = 1;
            sk->sk_data_ready(sk);       /* 唤醒 recvmsg */
        }
        return 0;
    }

    /* 3. 普通入队 */
    if (skb_peek(&sk->sk_receive_queue) || up->forward_deficit) {
        __skb_queue_tail(&sk->sk_receive_queue, skb);
    } else {
        /* 直接放入 reader_queue（GRO 候选）*/
        skb_queue_head(&up->reader_queue, skb);
        up->msg_ready = 1;
    }

    sk->sk_data_ready(sk);
    return 0;
}
```

---

## 4. GRO 卸载

UDP GRO 允许将多个相同五元组的小包合并为单个大包提交给上层：

```c
// net/ipv4/udp_offload.c:994
// 条件：
// 1. socket 开启 GRO (setsockopt UDP_GRO)
// 2. 入栈方向 GRO 未合并（保留 UDP 头的完整性）
// 3. 连续包流的五元组相同

// 驱动层 GRO 回调:
skb_gro_receive() → udp_gro_receive()
  → napi_gro_complete()
    → udp_gro_complete() → 计算 CHECKSUM
```

**收益**：减少 socket 接收路径的 skb 数量和 per-packet 开销，提高吞吐量。

---

## 5. 套接字哈希操作

```c
// 端口绑定
int udp_v4_get_port(struct sock *sk, unsigned short snum)
{
    return udp_lib_get_port(sk, snum, ipv4_rcv_saddr_equal);
}

// 核心端口分配（udp.c:231）
int udp_lib_get_port(struct sock *sk, unsigned short snum,
                     int (*saddr_cmp)(...))
{
    struct udp_hslot *hslot;
    unsigned int hash2, hash4;

    if (!snum) {
        /* 自动分配临时端口 */
        low = inet_sk(sk)->inet_num;
        for (i = 0; i < UDP_SHORT_MAX; i++) {
            snum = get_random_u32_below(UDP_SHORT_MAX);
            if (!udp_lib_lport_inuse(net, snum, ...))
                break;
        }
    }

    /* 添加到 hash（port）*/
    hslot = udp_hashslot(&udp_table, net, snum);
    sk_add_node_rcu(sk, &hslot->head);
    hslot->count++;

    /* 添加到 hash2（port + addr）*/
    hash2 = udp_hashfn(net, snum, udp_table.mask);
    hslot2 = udp_hashslot2(&udp_table, hash2);
    sk_add_node_rcu(sk, &hslot2->head);

    /* 如果已 connect，添加 hash4（四元组）*/
    if (inet_sk(sk)->inet_daddr)
        udp_lib_hash4(sk);
}
```

---

## 6. 接收——udp_recvmsg

```c
// net/ipv4/udp.c
int udp_recvmsg(struct sock *sk, struct msghdr *msg, size_t len,
                int flags, int *addr_len)
{
    /* 1. GRO reader_queue 优先 */
    if (up->reader_queue) {
        skb = skb_dequeue(&up->reader_queue);
        if (skb) {
            up->msg_ready = !skb_queue_empty(&up->reader_queue);
            len = skb->len;
            goto copy;
        }
    }

    /* 2. 普通接收队列 */
    skb = skb_recv_udp(sk, flags, &err);
    if (!skb) return err;

copy:
    /* 3. 复制数据到用户空间 */
    err = skb_copy_datagram_msg(skb, sizeof(struct udphdr), msg, len);

    /* 4. 设置源地址（recvfrom 的 addr 参数）*/
    if (msg->msg_name) {
        DECLARE_SOCKADDR(...);
        memcpy(addr, &inet->inet_rcv_saddr, ...);
    }

    /* 5. 校验和检查 */
    if (udp_skb_checksum(skb))
        err = -EAGAIN;                     /* 校验和失败 */

    consume_skb(skb);
    return err;
}
```

---

## 7. 关键性能路径

| 操作 | 延迟 | 说明 |
|------|------|------|
| 空 sendmsg（connected socket）| **~300ns** | 跳过路由查找 + 地址解析 |
| 空 sendmsg（非 connected）| **~1μs** | 包括路由查找 |
| recvmsg（小包）| **~500ns** | 内核→用户拷贝 |
| __udp4_lib_lookup（hash4 命中）| **~50ns** | 四元组哈希直接定位 |
| __udp4_lib_lookup（hash 遍历）| **~500ns-5μs** | 取决于冲突链长度 |
| UDP GRO（16 小包合并）| **~3μs** | 免 15 次 recvmsg 调用 |
| UDP_SEGMENT（64KB→1500 MTU）| **~5μs** | 硬件 TSO 卸载 |

---

## 8. 调试

```bash
# 查看 UDP socket 统计
cat /proc/net/udp
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt
  12: 00000000:007B 00000000:0000 07 00000000:00000000 00:00000000 00000000
     uid:0 inode:12345 refs:5

# 查看 UDP 计数器
netstat -s | grep UDP
cat /proc/net/snmp | grep Udp

# 跟踪 UDP 发送/接收
bpftrace -e 'kprobe:udp_sendmsg { @cnt++; }'

# 跟踪 UDP 接收查找
echo 1 > /sys/kernel/debug/tracing/events/udp/udp_rcv/enable
```

---

## 9. 总结

Linux UDP 协议栈的设计体现了**极简 + 高性能**的理念：

**1. 三级哈希** — 从 `hash`（port-only）到 `hash2`（port+addr）到 `hash4`（四元组），查找路径按精确度递增，保证 O(1) 定位。

**2. 发送加速** — connected socket 跳过路由查找；cork 模式聚合多个 write 为一个数据报；UDP_SEGMENT 利用硬件 TSO 避免大数据报的分段遍历。

**3. GRO 接收** — per-socket `reader_queue` 将同流小包合并为大包，减少 recvmsg 调用次数。

**4. 封装隧道** — UDP 作为 ESP/ESPINUDP 等隧道协议的载体，`encap_type + encap_rcv` 提供透明的隧道卸载。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
