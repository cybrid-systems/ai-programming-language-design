# 172-tcp_congestion_control — 拥塞控制算法深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/tcp_cubic.c` + `net/ipv4/tcp_cong.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**TCP 拥塞控制** 防止发送方压垮网络。CUBIC 是 Linux 默认算法，结合了 BIC 的窗口控制和 Reno 的友好性。算法通过调整拥塞窗口（cwnd）来控制发送速率。

## 1. 核心概念

```
cwnd（拥塞窗口）：
  发送方可以发送的未确认数据量
  cwnd 越大，发送速率越高

ssthresh（慢启动阈值）：
  cwnd < ssthresh：慢启动（指数增长）
  cwnd >= ssthresh：拥塞避免（线性增长）

RTT（往返时延）：
  发送数据到收到 ACK 的时间
```

## 2. CUBIC 算法

### 2.1 窗口增长函数

```
CUBIC 窗口增长：
  W(t) = C * (t - K)^3 + Wmax

  t = 从上次拥塞事件后的时间
  K = (Wmax * β / C)^(1/3)
  Wmax = 拥塞前的窗口大小
  C = 0.4（缩放因子）
  β = 0.7（拥塞后窗口减少比例）

窗口减少：
  发生拥塞后：Wmax = cwnd
  cwnd = cwnd * β
```

### 2.2 cubic_update

```c
// net/ipv4/tcp_cubic.c — cubic_update
static void cubic_update(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    u32 delta, cubic_aim;
    u64 t, w;

    // 计算时间差
    t = (ktime_us_delta(tp->tcp_mstamp, tp->tcp_clock_base)) / USEC_PER_MSEC;

    // 计算 K
    tp->t_loss_cwnd = tp->snd_cwnd;
    tp->t_loss_cwnd_saved = tp->snd_ssthresh;

    // CUBIC 目标窗口
    cubic_aim = cubic_cwnd(tp, t);

    // 如果目标大于当前窗口，线性增长
    if (cubic_aim > tp->snd_cwnd)
        tp->snd_cwnd = min(cubic_aim, tp->snd_cwnd + 1);
}
```

## 3. Reno 算法（参考）

```
Reno：
  慢启动：cwnd += 1 每 ACK（指数）
  拥塞避免：cwnd += 1 每 RTT（线性）

当检测到拥塞（3个重复ACK）：
  Reno：cwnd = cwnd / 2，ssthresh = cwnd
  重新进入拥塞避免
```

## 4. BBR（Bottleneck Bandwidth and RTT）

```
BBR（自 Linux 4.19）：
  不依赖丢包来判断拥塞
  维护两个估计：
    - Bottleneck Bandwidth（最大带宽）
    - Minimum RTT（最小延迟）

  目标：正好在网络容量边界发送
  pacing_rate = BDP = BW * min_rtt
```

## 5. 算法切换

```bash
# 查看当前算法：
cat /proc/sys/net/ipv4/tcp_congestion_control
# cubic

# 查看可用算法：
cat /proc/sys/net/ipv4/tcp_available_congestion_control
# reno cubic bbr

# 切换：
sysctl net.ipv4.tcp_congestion_control=bbr

# 持久化：
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
```

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/tcp_cubic.c` | `cubic_update`、`bictcp_cong_avoid` |
| `net/ipv4/tcp_cong.c` | `tcp_register_congestion_ops` |

## 7. 西游记类喻

**CUBIC** 就像"取经路的自适应车速"——

> CUBIC 像一辆智能快递车，能根据路况（网络拥塞程度）自动调整车速。如果路上很空（CUBIC 增长快），就加速；如果开始堵了（cwnd 接近网络容量），就慢慢加速到最优速度。如果遇到拥塞（丢包），就记下这次最堵的程度（Wmax = 堵之前的速度），然后把速度降到 70%（β=0.7），重新加速。加速时也不是一直猛踩油门，而是按 CUBIC 曲线慢慢加速，避免再次拥堵。这就是为什么 CUBIC 比传统 Reno 在高带宽高延迟网络中表现好得多。

## 8. 关联文章

- **tcp_retransmit**（article 148）：拥塞控制触发重传
- **tcp_timestamps**（article 162）：BBR 使用 RTT 测量

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

