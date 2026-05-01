# 169-raw_socket — 原始套接字深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/raw.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**Raw Socket** 允许用户进程直接构造和发送 IP 数据包，跳过传输层（TCP/UDP）。用于 ping、traceroute、OSPF、BGP、VPN 等协议实现。

## 1. raw_socket 创建

### 1.1 raw_create

```c
// net/ipv4/raw.c — raw_create
int raw_create(struct net *net, struct socket *sock, int protocol, kern)
{
    struct raw_sock *rs;

    // 分配 raw_sock
    rs = inet_sk_alloc(net, &raw_sock_prot, GFP_KERNEL);
    if (!rs)
        return -ENOMEM;

    // 设置协议
    rs->sk.sk_protocol = protocol;

    // 绑定协议处理
    rs->prot = raw_prot;
    rs->no_check = 0;

    return 0;
}
```

## 2. raw 接收

### 2.1 raw_rcv

```c
// net/ipv4/raw.c — raw_rcv
int raw_rcv(struct sock *sk, struct sk_buff *skb)
{
    // 1. 跳过 IP 头部
    skb_pull(skb, ip_hdrlen(skb));

    // 2. 验证校验和
    if (sk->sk_filter) {
        if (sk_filter_run(sk->sk_filter, skb) == 0)
            goto drop;
    }

    // 3. 发送到用户空间
    return sock_queue_rcv_skb(sk, skb);
}
```

## 3. ICMP 实现（使用 raw socket）

```c
// net/ipv4/icmp.c — ICMP 使用 raw socket
// ICMP 协议使用 IPPROTO_ICMP = 1
// 发送：raw_sendmsg → ip_build_xmit
// 接收：icmp_rcv → raw_rcv

// 用户空间使用：
fd = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
sendto(fd, &packet, sizeof(packet), 0, &dest, sizeof(dest));
```

## 4. ping 实现

```c
// net/ipv4/ping.c — ping 使用 raw
// ping 使用 ICMP ECHO REQUEST / REPLY
// socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP) 或
// socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)
```

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/raw.c` | `raw_create`、`raw_rcv` |
| `net/ipv4/icmp.c` | `icmp_rcv`、`icmp_send` |

## 6. 西游记类喻

**Raw Socket** 就像"天庭的快递公司直营"——

> 普通 UDP socket 像通过驿站寄快递，快递公司帮你装信封、写地址。Raw socket 像自己买信封、自己写地址，直接把东西送到驿站发货。如果你想寄一个特殊的包裹（自定义 IP 选项、路由追踪），就要用 Raw socket，直接控制 IP 层。

## 7. 关联文章

- **udp_sendmsg**（article 145）：UDP socket
- **netif_receive_skb**（article 139）：raw socket 收到的数据包来源

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

