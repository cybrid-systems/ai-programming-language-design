# 145-udp_sendmsg — UDP发送深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/udp.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**udp_sendmsg** 是 UDP 数据报发送的核心函数。UDP 是无连接的，每个数据报独立发送（sendto），不建立连接、不重传、不保证顺序。

## 1. UDP vs TCP 对比

| 特性 | UDP | TCP |
|------|-----|-----|
| 连接 | 无连接 | 面向连接（三次握手）|
| 可靠性 | 不可靠，可能丢包 | 可靠，丢包重传 |
| 顺序 | 无顺序保证 | 顺序保证 |
| 拥塞控制 | 无 | 有（cwnd）|
| MTU | 受 MTU 限制 | MSS 自动分段 |
| 头部 | 8 字节 | 20+ 字节 |
| 速度 | 快（无重传）| 慢（有重传）|

## 2. struct udp_sock — UDP sock

```c
// include/linux/udp.h — udp_sock
struct udp_sock {
    struct inet_connection_sock inet_conn;
    //   uprobe1: UDP 探针1
    //   uprobe2: UDP 探针2

    // UDP 特定
    int               pending;            // 是否在发送中
    __be16            cksum;             // 校验和（0=禁用）

    // 绑定hash（用于快速查找）
    struct hlist_nulls_node node;         // 接入 udp_hash
    struct hlist_nulls_node udp_table_entry;

    // 源端口（用于 recv 时的反向查找）
    __be16            inet_num;          // 源端口

    // 选项
    unsigned long     flags;             // UDP_*
    struct {
        unsigned int  gc:1;              // 垃圾回收
    } __aligned(4);
};
```

## 3. udp_sendmsg — 发送入口

### 3.1 udp_sendmsg

```c
// net/ipv4/udp.c — udp_sendmsg
int udp_sendmsg(struct sock *sk, struct msghdr *msg, size_t len)
{
    struct inet_sock *inet = inet_sk(sk);
    struct udp_sock *up = udp_sk(sk);
    struct sockaddr_in *usin = (struct sockaddr_in *)msg->msg_name;
    __be32 daddr, saddr;
    __be16 dport, sport;
    int oif;
    int err;

    // 1. 获取目的地址
    if (usin) {
        if (msg->msg_namelen < sizeof(*usin))
            return -EINVAL;
        daddr = usin->sin_addr.s_addr;
        dport = usin->sin_port;
        oif = sk->sk_bound_dev_if;
    } else {
        // connected UDP：使用 connect() 时设置的目的地址
        daddr = inet->inet_daddr;
        dport = inet->inet_dport;
        oif = sk->sk_bound_dev_if;
    }

    // 2. 路由查找
    struct flowi4 fl4 = {
        .daddr = daddr,
        .saddr = inet->inet_saddr,
        .fl4_sport = inet->inet_sport,
        .fl4_dport = dport,
        .flowi4_oif = oif,
    };
    err = ip_route_output_flow(net, &fl4, sk);
    if (err)
        goto out;

    // 3. 检查长度
    if (len > 65535 - sizeof(struct udphdr))
        return -EMSGSIZE;

    // 4. 获取/分配 skb
    struct sk_buff *skb;
    skb = sock_alloc_send_skb(sk, alloc_size, msg->msg_flags & MSG_DONTWAIT, &err);

    // 5. 构建 UDP 头
    struct udphdr *uh = skb_put(skb, sizeof(*uh));
    uh->source = inet->inet_sport;
    uh->dest = dport;
    uh->len = htons(len + sizeof(*uh));
    uh->check = 0;  // 稍后计算

    // 6. 复制用户数据
    err = memcpy_from_msg(skb_put(skb, len), msg, len);

    // 7. 计算校验和
    if (up->csum) {
        uh->check = udp_csum(skb);
        if (uh->check == 0)
            uh->check = CSUM_MANGLED_0;
    }

    // 8. 发送
    return ip_send_skb(skb);
}
```

## 4. UDP 校验和计算

### 4.1 udp_csum

```c
// net/ipv4/udp.c — udp_csum
__sum16 udp_csum(struct sk_buff *skb)
{
    struct udphdr *uh = udp_hdr(skb);
    unsigned int ulen = ntohs(uh->len);
    unsigned int csum = 0;

    // UDP 伪头部校验和：
    //   [源IP(4) | 目的IP(4) | 0 | 协议(1) | UDP长度(2)]
    //   + UDP 头 + 数据

    csum = csum_partial(uh, sizeof(*uh), 0);
    csum = csum_tcpudp_magic(iph->saddr, iph->daddr,
                              ulen, IPPROTO_UDP, csum);

    return csum_fold(csum);
}
```

## 5. ip_send_skb — 发送

```c
// net/ipv4/ip_output.c — ip_send_skb
int ip_send_skb(struct net *net, struct sk_buff *skb)
{
    int err;

    // 1. 设置 TTL
    iph->ttl = ip_select_ttl(inet, &rt->dst);

    // 2. 添加 IP 选项（如果有）
    ip_options_build(skb, ip_options, daddr, rt, 0);

    // 3. 发送
    err = __ip_local_out(dev_net(skb->dev), skb);
}
```

## 6. UDP 分片

### 6.1 UDP MTU 限制

```
UDP 最大数据报：
  MTU = 1500（以太网）
  IP 头 = 20 字节
  UDP 头 = 8 字节
  最大 UDP payload = 1500 - 20 - 8 = 1472 字节

如果应用发送 > 1472 字节：
  IP 层会自动分片
  每个分片 < 1480 字节（1500 - 20）

分片后，UDP 头只出现在第一个分片
每个分片有自己的 IP 头（Identification + MF 标志 + Offset）
```

## 7. UDP GSO（分片卸载）

### 7.1 udp4_ufo_fragment

```c
// net/ipv4/udp_offload.c — udp4_ufo_fragment
struct sk_buff *udp4_ufo_fragment(struct sk_buff *skb,
                                   netdev_features_t features)
{
    // 如果设备支持 UDP 分片卸载（NETIF_F_UFO）
    // 在硬件中分片
    // 否则在软件中分片
}
```

## 8. UDP 的 socket 选项

```c
// UDP 特有选项：
SO_REUSEADDR  // 地址复用
SO_REUSEPORT  // 端口复用
SO_SNDBUF     // 发送缓冲大小
SO_RCVBUF     // 接收缓冲大小
SO_NO_CHECK   // 禁用校验和
SO_MARK       // 标记
IP_MTU_DISCOVER  // MTU 发现
IP_PKTINFO       // 数据包信息
```

## 9. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/udp.c` | `udp_sendmsg`、`udp_csum` |
| `net/ipv4/ip_output.c` | `ip_send_skb` |
| `net/ipv4/udp_offload.c` | `udp4_ufo_fragment` |
| `include/linux/udp.h` | `struct udp_sock` |

## 10. 西游记类比

**udp_sendmsg** 就像"驿站快递"——

> UDP 就像驿站寄送快递员，不建立连接、不确认、不重传。每个包裹（UDP 数据报）自己独立，带有自己的地址标签（UDP 头：源/目的端口）。如果中途丢了，就丢了，不会重发；如果顺序乱了，就乱了。好处是快——不用等确认，不用重传，直接送。UDP 的校验和（uh->check）就像快递单上的封条，收到时检查封条是否完好（校验和正确），如果封条破了（校验和错误）就扔掉。

## 11. 关联文章

- **udp_recvmsg**（相关）：UDP 数据接收
- **tcp_sendmsg**（article 144）：TCP 发送（对比）
- **netif_receive_skb**（article 139）：数据包接收

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

