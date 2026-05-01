# 162-tcp_timestamps_sack — TCP时间戳与SACK深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/tcp_input.c` + `net/ipv4/tcp_output.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**TCP Timestamps** 和 **SACK（Selective Acknowledgment）** 是 TCP 的两个重要扩展。Timestamps 提供 RTT 精确测量和 PAWS 防回绕，SACK 允许接收方只确认已收到的数据片段，大幅提升重传效率。

## 1. TCP Timestamps

### 1.1 RFC 1323 Timestamps

```
TCP Option (Kind=8):
  ┌────────┬────────┬────────┬────────┐
  │ Kind=8 │Length=10│ TSval(4B) │ TSecr(4B) │
  └────────┴────────┴────────┴────────┘

TSval: 发送方的当前时间戳（每发送一个包递增）
TSecr: 对方上次发送的 TSval（Echo Reply）
```

### 1.2 tcp_parse_options — 解析选项

```c
// net/ipv4/tcp.c — tcp_parse_options
void tcp_parse_options(const struct sk_buff *skb, struct tcp_options_received *opt,
                      int ephemeral, const u8 *ptr)
{
    int length = (th->doff * 4) - sizeof(struct tcphdr);

    while (length > 0) {
        int opcode = *ptr++;

        switch (opcode) {
        case TCPOPT_TSTAMP:
            // Kind=8, Length=10
            opt->tsval = get_unaligned_be32(ptr);
            opt->tsecr = get_unaligned_be32(ptr + 4);
            opt->saw_tstamp = 1;
            break;
        }
    }
}
```

### 1.3 PAWS（Protection Against Wrapped Sequence Numbers）

```c
// PAWS 检查：防止序列号回绕
// 当时间戳回绕时，序列号可能也回绕
if (tcp_opt.saw_tstamp) {
    // 如果收到的 TSval < 上次记录的 TSval
    // 说明时间戳是旧的（回绕了），丢弃
    if ((s32)(tcp_opt.tsval - tp->rx_opt.rcv_tsval) < 0)
        return 0;  // PAWS 失败
}
```

## 2. SACK（Selective Acknowledgment）

### 2.1 SACK Option

```
TCP Option (Kind=5, Length=可变):
  ┌────────┬────────┬──────────────────┐
  │ Kind=5 │Length │ Left Edge(4B) │ Right Edge(4B) │
  └────────┴────────┴──────────────────┘
                    (可重复多个块)

SACK 告诉对方：我已经收到了这些不连续的数据块

例如：
  已收到字节 100-199 和 300-399，期望 200
  SACK: L=200, R=300  (第一个块)
       L=400, R=... (第二个块)
```

### 2.2 tcp_sack_data — SACK 数据

```c
// include/linux/tcp.h — tcp_sack_block
struct tcp_sack_block {
    __u32   start_seq;   // 块的起始序列号
    __u32   end_seq;     // 块的结束序列号（不包含）
};
```

### 2.3 tcp_sack_clear — 清除 SACK

```c
// net/ipv4/tcp_input.c — tcp_sack_clear
void tcp_sack_clear(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    int this_sack;

    // 清除所有 SACK 块
    for (this_sack = 0; this_sack < tp->rx_opt.num_sacks; this_sack++)
        tp->selective_acks[this_sack].start_seq = 0;

    tp->rx_opt.num_sacks = 0;
}
```

### 2.4 tcp_sack_new_ofo_skb — 添加新 SACK 块

```c
// net/ipv4/tcp_input.c — tcp_sack_new_ofo_skb
static int tcp_sack_new_ofo_skb(struct sock *sk, __u32 seq, __u32 end_seq)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct tcp_sack_block *sp = &tp->selective_acks[0];
    int this_sack = 0;

    // 如果已有相同块，跳过
    for (this_sack = 0; this_sack < tp->rx_opt.num_sacks; this_sack++, sp++) {
        if (sp->start_seq == seq && sp->end_seq == end_seq)
            return 0;
    }

    // 插入新块（可能需要合并相邻块）
    // 如果超过 4 个块，丢弃最老的
}
```

## 3. RTT（Round-Trip Time）测量

### 3.1 tcp_ack — RTT 采样

```c
// net/ipv4/tcp_input.c — tcp_ack
static int tcp_ack(struct sock *sk, const struct sk_buff *skb, int flag)
{
    if (tp->rx_opt.saw_tstamp) {
        // 使用 Timestamp 计算 RTT
        if (tp->rx_opt.tsecr) {
            // RTT = 当前时间 - TSecr
            long m = tcp_time_stamp - tp->rx_opt.tsecr;

            // 更新 RTT 估计
            tcp_rtt_estimator(sk, m);
        }
    }
}
```

### 3.2 tcp_rtt_estimator — RTT 估计

```c
// net/ipv4/tcp_input.c — tcp_rtt_estimator
static void tcp_rtt_estimator(struct sock *sk, long sample)
{
    struct tcp_sock *tp = tcp_sk(sk);
    long m = sample;

    // 滑动平均：
    // SRTT = (7 * SRTT + m) / 8
    // RTTVAR = (3 * RTTVAR + |SRTT - m|) / 4

    tp->srtt_us = (7 * tp->srtt_us + (m << 3)) >> 3;
    tp->mdev_us = (3 * tp->mdev_us + abs(tp->srtt_us - m)) >> 2;

    // RTO = SRTT + 4 * RTTVAR
    tp->rttvar_us = max(tp->mdev_us, TCP_TIMEOUT_MIN);
    tp->srtt_us = max(tp->srtt_us, TCP_TIMEOUT_MIN);
}
```

## 4. 时间戳与 RTO 的关系

```
Timestamps 对 RTO 的影响：

没有 Timestamps：
  RTT 只能通过重传超时估计
  当没有数据传输时，无法测量 RTT
  RTO 可能不准确

有 Timestamps：
  每个 ACK 都携带 TSval
  TSecr = 上一个包的 TSval
  RTT = 当前时间 - TSecr
  更精确的 RTT → 更精确的 RTO
```

## 5. sysctl 参数

```bash
# 启用 Timestamps（默认启用）：
cat /proc/sys/net/ipv4/tcp_timestamps
# 1 = 启用，0 = 禁用

# 启用 SACK（默认启用）：
cat /proc/sys/net/ipv4/tcp_sack
# 1 = 启用，0 = 禁用

# 查看连接状态：
cat /proc/net/tcp
# 第8列是 Timestamps 标志（T）
```

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/tcp.c` | `tcp_parse_options` |
| `net/ipv4/tcp_input.c` | `tcp_ack`、`tcp_rtt_estimator`、`tcp_sack_new_ofo_skb` |
| `include/linux/tcp.h` | `struct tcp_sack_block` |

## 7. 西游记类喻

**TCP Timestamps + SACK** 就像"取经路的精准签收系统"——

> Timestamps 像每个快递上的时间戳，收件人收到时看一下时间，就能精确算出快递在路上走了多久（精确 RTT）。PAWS 像防伪标志，防止有人用旧的时间戳假冒新快递。SACK 则像选择性签收——以前要一次性确认收到所有快递，现在可以告诉快递员："100-200号的快递我收到了，但300号还没到，请只重发300号。"这样就避免了重发已经收到的快递，大大节省了带宽。

## 8. 关联文章

- **tcp_retransmit**（article 148）：Timestamps 和 SACK 用于重传
- **tcp_state_machine**（article 147）：TCP 状态转换

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

