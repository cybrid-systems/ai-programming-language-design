# tcp_sack — TCP 选择性确认机制分析

## 1. 概述

TCP SACK（Selective Acknowledgment，选择性确认）机制是 RFC 2018 定义的重要扩展，用于解决基础 TCP 确认机制只能确认连续数据的痛点。当网络发生丢包或乱序时，发送方若无 SACK，只能依赖超时重传所有未确认数据，效率极低。SACK 使接收方能够告知发送方哪些**非连续**的数据块已被接收，让发送方精准重传丢失的部分。

Linux 内核对 SACK 的实现分散在 `net/ipv4/tcp_input.c` 和 `include/net/tcp.h` / `include/linux/tcp.h` 中，涉及乱序队列管理、SACK 块维护、选择性确认打标签、DSACK 检测、FACK 拥塞控制等多个子模块。

---

## 2. struct tcp_sack_block 和 SACK 选项格式

### 2.1 线上格式（wire format）

TCP 选项中的 SACK 块遵循 RFC 2018 定义，格式为：

```
+---------+---------+---------+---------+
| Kind=5  | Length | Start Sequence Number (4 bytes) | End Sequence Number (4 bytes) |
+---------+---------+---------+---------+
```

每个 SACK 块占 8 字节（TCPOLEN_SACK_PERBLOCK = 8），格式为：

```c
// include/linux/tcp.h:97
struct tcp_sack_block_wire {
    __be32  start_seq;
    __be32  end_seq;
};
```

Kind=5 表示 SACK 选项。Length 字段值 = `2 + num_blocks * 8`。TCP 头部选项空间最大 40 字节，带时间戳（12 字节）时最多携带 3 个 SACK 块，不带时间戳时最多 4 个。

### 2.2 内存格式（in-memory）

解析后存放到接收端 `tcp_sock` 中的格式为：

```c
// include/linux/tcp.h:102
struct tcp_sack_block {
    u32  start_seq;
    u32  end_seq;
};
```

内存中使用主机字节序，便于直接比较操作。

### 2.3 关键宏定义

```c
// include/net/tcp.h:213-249
#define TCPOPT_SACK             5       /* SACK Block */
#define TCPOLEN_SACK_BASE       2       /* Kind + Length */
#define TCPOLEN_SACK_BASE_ALIGNED  4    /* 对齐到 4 字节边界 */
#define TCPOLEN_SACK_PERBLOCK   8       /* 每个 SACK 块长度 */
```

### 2.4 核心存储结构

```c
// include/linux/tcp.h:440-443
struct tcp_sack_block duplicate_sack[1]; /* D-SACK block（存放对端发来的 D-SACK）*/
struct tcp_sack_block selective_acks[4]; /* 最多 4 个 SACK 块（接收到的 SACK 信息）*/
struct tcp_sack_block recv_sack_cache[4]; /* SACK 块的解析缓存 */

// include/linux/tcp.h:128
u8  num_sacks;    /* 当前有效 SACK 块数量 */

// include/linux/tcp.h:121
sack_ok : 3,      /* sack_ok 标志位，bit0=TCP_SACK_SEEN，bit2=TCP_DSACK_SEEN */

// include/linux/tcp.h:107-109
#define TCP_SACK_SEEN     (1 << 0)  /* 对端支持 SACK */
#define TCP_DSACK_SEEN    (1 << 2)  /* 收到过 D-SACK */
```

### 2.5 SACK 选项解析

```c
// tcp_input.c:2220（tcp_sacktag_write_queue 函数）
int num_sacks = min(TCP_NUM_SACKS, (ptr[1] - TCPOLEN_SACK_BASE) >> 3);
```

`ptr[1]` 是 SACK 选项的 Length 字段，减 2 后除以 8 得到 SACK 块数量。`TCP_NUM_SACKS` 为 4。

---

## 3. tcp_sack_new_ofo_skb 和 ofo_queue 红黑树

### 3.1 乱序队列（Out-of-Order Queue）

当接收到的数据包序列号不连续时，skb 被存入 `out_of_order_queue`，这是一个 **红黑树**（rb_root），按 sequence number 排序：

```c
// include/linux/tcp.h:251
struct rb_root   out_of_order_queue;

// tcp.c:430（tcp_init_sock 中初始化）
tp->out_of_order_queue = RB_ROOT;

// include/linux/tcp.h:437
struct sk_buff *ooo_last_skb; /* cache rb_last(out_of_order_queue) */
```

### 3.2 数据包进入 ofo_queue

乱序包处理入口在 `tcp_input.c:5635` 附近的 `tcp_rcv_packet_process` 函数。当 `tcp_rcv_established` 判断包不在窗口内或序列号超前时，调用 `tcp_ofo_queue`（第 5273 行）。但更早期的入口在 `tcp_data_queue_ofo`（第 5360 行起）：

```c
// tcp_input.c:5360 - tcp_data_queue_ofo
if (RB_EMPTY_ROOT(&tp->out_of_order_queue)) {
    /* Initial out of order segment, build 1 SACK. */
    if (tcp_is_sack(tp)) {
        tp->rx_opt.num_sacks = 1;
        tp->selective_acks[0].start_seq = seq;    // 第5380行
        tp->selective_acks[0].end_seq = end_seq;  // 第5381行
    }
    rb_link_node(&skb->rbnode, NULL, p);
    rb_insert_color(&skb->rbnode, &tp->out_of_order_queue);
    tp->ooo_last_skb = skb;
    goto end;
}
```

首个乱序段直接创建第一个 SACK 块。若树非空，调用 `tcp_ooo_try_coalesce` 尝试合并到 `ooo_last_skb` 尾部（常见追加场景 O(1)）。否则进行红黑树二分查找插入（第 5396 行起）。

插入时的重叠处理逻辑（第 5423 行起）：
- **完全包含**：新包完全覆盖旧包，用 `rb_replace_node` 替换，触发 DSACK
- **部分重叠**：记录 DSACK
- **完全包含于旧包**：丢弃新包，触发 DSACK

覆盖其他节点后，遍历右侧节点删除被新包完全覆盖的所有旧节点（第 5469 行 `merge_right` 循环）。

### 3.3 tcp_sack_new_ofo_skb

每当新的乱序段被插入 ofo_queue 后，需要在 `selective_acks[]` 中注册 SACK 块。该函数（第 5117 行）负责维护接收端已收到的非连续块信息：

```c
// tcp_input.c:5117
static void tcp_sack_new_ofo_skb(struct sock *sk, u32 seq, u32 end_seq)
{
    struct tcp_sack_block *sp = &tp->selective_acks[0];
    int cur_sacks = tp->rx_opt.num_sacks;
    int this_sack;

    if (!cur_sacks)
        goto new_sack;

    for (this_sack = 0; this_sack < cur_sacks; this_sack++, sp++) {
        /* 尝试扩展已有的相邻 SACK 块 */
        if (tcp_sack_extend(sp, seq, end_seq)) {
            // 旋转到第一个位置
            for (; this_sack > 0; this_sack--, sp--)
                swap(*sp, *(sp - 1));
            if (cur_sacks > 1)
                tcp_sack_maybe_coalesce(tp);
            return;
        }
    }

    /* 数组满，丢弃最旧的块（在末尾）*/
    if (this_sack >= TCP_NUM_SACKS) {
        this_sack--;
        tp->rx_opt.num_sacks--;
        sp--;
    }
    /* 移位腾出头部空间 */
    for (; this_sack > 0; this_sack--, sp--)
        *sp = *(sp - 1);

new_sack:
    sp->start_seq = seq;
    sp->end_seq = end_seq;
    tp->rx_opt.num_sacks++;
}
```

- **扩展相邻块**：若新块与某个已有块相邻或重叠，扩展该块（`tcp_sack_extend`）
- **旋转**：被命中的块旋转到 `selective_acks[0]`（最常用位置），减少后续搜索次数
- **合并**：`tcp_sack_maybe_coalesce` 将相邻/重叠的多个块合并为一个（减少 SACK 块数量）
- **溢出处理**：超过 `TCP_NUM_SACKS`（4 个）时丢弃最旧的块

### 3.4 tcp_sack_extend

```c
// tcp_input.c:4962
static inline bool tcp_sack_extend(struct tcp_sack_block *sp, u32 seq,
                                   u32 end_seq)
{
    if (!after(seq, sp->end_seq) && !after(sp->start_seq, end_seq)) {
        if (before(seq, sp->start_seq))
            sp->start_seq = seq;
        if (after(end_seq, sp->end_seq))
            sp->end_seq = end_seq;
        return true;
    }
    return false;
}
```

扩展条件：`[seq, end_seq)` 与 `[sp->start_seq, sp->end_seq)` 有交集（不逆转，且新块完全在已有块左侧扩展或右侧扩展范围内）。

---

## 4. tcp_sack_remove — 删除过期 SACK 块

当 `rcv_nxt`（接收已确认的下一个序列号）推进时，原本在乱序队列中的包可能被移入接收队列，从而导致部分 SACK 块失效。`tcp_sack_remove`（第 5166 行）负责清理：

```c
// tcp_input.c:5166
static void tcp_sack_remove(struct tcp_sock *tp)
{
    struct tcp_sack_block *sp = &tp->selective_acks[0];
    int num_sacks = tp->rx_opt.num_sacks;
    int this_sack;

    /* Empty ofo queue, hence, all the SACKs are eaten. Clear. */
    if (RB_EMPTY_ROOT(&tp->out_of_order_queue)) {
        tp->rx_opt.num_sacks = 0;
        return;
    }

    for (this_sack = 0; this_sack < num_sacks;) {
        /* 检查 sack 起始是否被 rcv_nxt 覆盖 */
        if (!before(tp->rcv_nxt, sp->start_seq)) {
            int i;
            /* rcv_nxt 必须也覆盖 end_seq（否则有 bug）*/
            WARN_ON(before(tp->rcv_nxt, sp->end_seq));

            /*  Zap this SACK, by moving forward any other SACKS */
            for (i = this_sack+1; i < num_sacks; i++)
                tp->selective_acks[i-1] = tp->selective_acks[i];
            num_sacks--;
            continue;  /* 不前进 sp，当前位置换了新块 */
        }
        this_sack++;
        sp++;
    }
    tp->rx_opt.num_sacks = num_sacks;
}
```

逻辑：遍历所有 SACK 块，若 `rcv_nxt >= start_seq`，说明接收应用已获得该块的数据（在乱序包被移入 rcv_queue 后），则删除该 SACK 块（前方块前移覆盖）。当 ofo_queue 空时，直接清零所有 SACK。

---

## 5. tcp_sacktag_one — 打标签（SACK 已接收的 skb）

### 5.1 核心打标签逻辑

`tcp_sacktag_one`（第 1612 行）是 SACK 处理的核心函数，负责在**发送端的重传队列**（`sk->tcp_rtx_queue`，红黑树）上标记哪些 skb 已被 SACK 确认：

```c
// tcp_input.c:1612
static u8 tcp_sacktag_one(struct sock *sk,
                          struct tcp_sacktag_state *state, u8 sacked,
                          u32 start_seq, u32 end_seq,
                          int dup_sack, int pcount, u32 plen,
                          u64 xmit_time)
```

参数解释：
- `sacked`：当前 skb 当前的 `sacked` 标志
- `start_seq / end_seq`：SACK 块描述的序列号范围
- `dup_sack`：是否为 D-SACK
- `pcount`：GSO 分割后的数据包个数
- `plen`：有效负载长度
- `xmit_time`：发送时间戳（用于 RACK）

### 5.2 标记流程

```c
// tcp_input.c:1629
if (!(sacked & TCPCB_SACKED_ACKED)) {
    tcp_rack_advance(tp, sacked, end_seq, xmit_time);

    if (sacked & TCPCB_SACKED_RETRANS) {
        if (sacked & TCPCB_LOST) {
            /* 之前标记为 lost，但 SACK 显示已收到 → 取消 lost 和 retrans 标记 */
            sacked &= ~(TCPCB_LOST|TCPCB_SACKED_RETRANS);
            tp->lost_out -= pcount;
            tp->retrans_out -= pcount;
        }
    } else {
        /* 未重传的包被 SACK → 说明发生了乱序重排 */
        if (before(start_seq, tcp_highest_sack_seq(tp)) &&
            before(start_seq, state->reord))
            state->reord = start_seq;

        if (!after(end_seq, tp->high_seq))
            state->flag |= FLAG_ORIG_SACK_ACKED;
        if (state->first_sackt == 0)
            state->first_sackt = xmit_time;
        state->last_sackt = xmit_time;
    }

    if (sacked & TCPCB_LOST) {
        /* 正常 SACK 到达：清除 LOST 标记 */
        sacked &= ~TCPCB_LOST;
        tp->lost_out -= pcount;
    }
}
```

关键行为：
1. **原本标记为 LOST+RETRANS 的包被 SACK**：说明是虚假重传，取消这两个标记（因为数据实际已被接收）
2. **从未重传过的包被 SACK**：说明接收方先收到了后面的包（乱序），记录 `reord`（reordering 位置），触发重排检测 `tcp_check_sack_reordering`
3. **常规 SACK**：清除 LOST 标记，更新 RACK 状态

### 5.3 D-SACK 的 undo_marker 处理

```c
// tcp_input.c:1618
if (dup_sack && (sacked & TCPCB_RETRANS)) {
    if (tp->undo_marker && tp->undo_retrans > 0 &&
        after(end_seq, tp->undo_marker))
        tp->undo_retrans = max_t(int, 0, tp->undo_retrans - pcount);
    if ((sacked & TCPCB_SACKED_ACKED) &&
        before(start_seq, state->reord))
        state->reord = start_seq;
}
```

D-SACK 确认了重传包被收到时，减少 `undo_retrans` 计数器（用于后续判断是否需要真正 undo 拥塞控制）。

### 5.4 遍历方式

`sacktag_write_queue` 通过红黑树搜索遍历发送端重传队列：

```c
// tcp_input.c:2186 - tcp_sacktag_skip
return tcp_sacktag_bsearch(sk, skip_to_seq);

// tcp_input.c:2165 - tcp_sacktag_bsearch
static struct sk_buff *tcp_sacktag_bsearch(struct sock *sk, u32 seq)
{
    struct rb_node *parent, **p = &sk->tcp_rtx_queue.rb_node;
    struct sk_buff *skb;
    while (*p) {
        parent = *p;
        skb = rb_to_skb(parent);
        if (before(seq, TCP_SKB_CB(skb)->seq))
            p = &parent->rb_left;
        else if (!before(seq, TCP_SKB_CB(skb)->end_seq))
            p = &parent->rb_right;
        else
            break;
    }
    return skb ? skb : tcp_rtx_queue_head(sk);
}
```

---

## 6. 乱序到达时的 SACK 处理（tcp_enter_cwr / tcp_fackets_state）

### 6.1 reordering 检测（乱序程度度量）

乱序检测由 `tcp_check_sack_reordering`（第 1275 行）完成：

```c
// tcp_input.c:1275
static void tcp_check_sack_reordering(struct sock *sk, const u32 low_seq,
                                      const int ts)
{
    struct tcp_sock *tp = tcp_sk(sk);
    const u32 mss = tp->mss_cache;
    u32 fack, metric;

    fack = tcp_highest_sack_seq(tp);    // FACK = highest SACKed sequence
    if (!before(low_seq, fack))
        return;

    metric = fack - low_seq;
    if ((metric > tp->reordering * mss) && mss) {
        WRITE_ONCE(tp->reordering,
            min_t(u32, (metric + mss - 1) / mss,
                  READ_ONCE(sock_net(sk)->ipv4.sysctl_tcp_max_reordering)));
    }
    WRITE_ONCE(tp->reord_seen, tp->reord_seen + 1);
}
```

- `low_seq`：第一个未被 SACK 确认的序列号（重排前缘）
- `fack`：Forward ACK，即 highest SACKed sequence
- `metric`：两者之间的差距（以字节计）
- 若 metric 超过当前 `reordering * mss`，则更新 `reordering` 值（最大 `sysctl_tcp_max_reordering`，默认 300）
- `reordering` 反映**包重排的最大距离**（以 MSS 为单位）

### 6.2 prior_fack 和 FACK 概念

FACK（Forward ACK）在 Linux 中的实际含义就是 `tcp_highest_sack_seq(tp)`——已 SACK 确认的**最高**序列号。在 `tcp_clean_rtx_queue` 中使用 `prior_fack` 来衡量恢复前的高水位线：

```c
// tcp_input.c:4262, 4310
u32 prior_fack;
...
prior_fack = tcp_is_sack(tp) ? tcp_highest_sack_seq(tp) : tp->snd_una;
```

在快速恢复和 CWR 状态中，`prior_fack` 作为 `reord` 比较的基准，用于判断恢复是否已经推进到原始丢失位置。

### 6.3 tcp_enter_cwr — CWR 状态进入

当接收端对发送端施压（ECE 标志）或发生特定丢包时，发送端进入**拥塞窗口缩减**（CWR）状态：

```c
// tcp_input.c:3030
void tcp_enter_cwr(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);

    tp->prior_ssthresh = 0;
    if (inet_csk(sk)->icsk_ca_state < TCP_CA_CWR) {
        tp->undo_marker = 0;
        tcp_init_cwnd_reduction(sk);
        tcp_set_ca_state(sk, TCP_CA_CWR);
    }
}
```

调用路径：
- `tcp_try_to_open`（第 3067 行）：当 ACK 带有 ECE 标志时调用
- `tcp_fastretrans_alert`（第 3426 行）：当判断需要降低发送速率时

`tcp_init_cwnd_reduction` 设置恢复标志，`undo_marker` 清除，使后续的 SACK 不能 undo 这次拥塞控制。

### 6.4 乱序到达时的 SACK 处理流程

以接收端视角，当乱序包到达时的处理路径如下：

1. `tcp_rcv_established` → 数据包乱序
2. `tcp_data_queue_ofo`（第 5360 行）：包进入 `out_of_order_queue`，触发 `tcp_sack_new_ofo_skb`（第 5483 行）
3. 若乱序包填补了 rcv_nxt 与 ofo_queue 首元素之间的空洞，调用 `tcp_ofo_queue`（第 5273 行）将连续的包移入 rcv_queue
4. 若 rcv_nxt 推进，调用 `tcp_sack_remove`（第 5166 行）清理已确认的 SACK 块
5. 发送端的 SACK 处理：`tcp_sacktag_write_queue` → `tcp_sacktag_walk` 遍历 rtx_queue，用 `tcp_sacktag_one` 标记 skb
6. 乱序到达的 SACK 触发 `tcp_check_sack_reordering`，更新 `tp->reordering`
7. 若乱序严重，`tcp_check_sack_reordering` 可能调整 `tp->reordering`，影响后续拥塞控制决策

---

## 7. DSACK（Duplicate SACK）机制

### 7.1 什么是 DSACK

DSACK 是 RFC 2883 定义的扩展，当接收端收到一个**重复的数据段**时，通过 SACK 块告知发送端该段已被收到（即便它在之前已经 SACK 过）。这使发送端能够识别：
1. **虚假重传**：数据实际未被接收，发送端不应该减少 cwnd
2. **接收端缓存重叠**：某些情况下接收端缓存了重复数据

### 7.2 DSACK 的生成（发送端视角）

发送端在以下情况主动构造 DSACK（在发送端本地的 `duplicate_sack[0]` 中设置）：

```c
// tcp_input.c:4975 - tcp_dsack_set
static void tcp_dsack_set(struct sock *sk, u32 seq, u32 end_seq)
{
    struct tcp_sock *tp = tcp_sk(sk);

    if (tcp_is_sack(tp) && READ_ONCE(sock_net(sk)->ipv4.sysctl_tcp_dsack)) {
        if (before(seq, tp->rcv_nxt))
            mib_idx = LINUX_MIB_TCPDSACKOLDSENT;   // 序列号 < rcv_nxt（DSACK for old）
        else
            mib_idx = LINUX_MIB_TCPDSACKOFOSENT;   // 序列号 > rcv_nxt（DSACK for future）
        NET_INC_STATS(sock_net(sk), mib_idx);

        tp->rx_opt.dsack = 1;
        tp->duplicate_sack[0].start_seq = seq;
        tp->duplicate_sack[0].end_seq = end_seq;
    }
}
```

触发场景（乱序包处理中）：
- **完全重复**（第 5424 行）：新包完全被 ofo_queue 中已有包覆盖，丢弃新包并设置 DSACK
- **部分重叠**（第 5434 行）：新包与已有包部分重叠，设置 DSACK
- **新包覆盖旧包**（第 5443 行）：用 `rb_replace_node` 替换旧包，DSACK 扩展到旧包范围

### 7.3 DSACK 的解析（发送端收到 DSACK 后的处理）

```c
// tcp_input.c:1485 - tcp_check_dsack
static bool tcp_check_dsack(struct sock *sk, const struct sk_buff *ack_skb,
                            struct tcp_sack_block_wire *sp, int num_sacks,
                            u32 prior_snd_una, struct tcp_sacktag_state *state)
{
    u32 start_seq_0 = get_unaligned_be32(&sp[0].start_seq);
    u32 end_seq_0 = get_unaligned_be32(&sp[0].end_seq);
    u32 dup_segs;

    // 第一个 SACK 块的 start_seq < ack_seq → 对端收到重复数据
    if (before(start_seq_0, TCP_SKB_CB(ack_skb)->ack_seq)) {
        NET_INC_STATS(sock_net(sk), LINUX_MIB_TCPDSACKRECV);
    } else if (num_sacks > 1) {
        // 第一个 SACK 块覆盖范围大于第二个（DSACK for out-of-order）
        u32 end_seq_1 = get_unaligned_be32(&sp[1].end_seq);
        u32 start_seq_1 = get_unaligned_be32(&sp[1].start_seq);
        if (after(end_seq_0, end_seq_1) || before(start_seq_0, start_seq_1))
            return false;
        NET_INC_STATS(sock_net(sk), LINUX_MIB_TCPDSACKOFORECV);
    } else {
        return false;
    }

    dup_segs = tcp_dsack_seen(tp, start_seq_0, end_seq_0, state);
    if (!dup_segs) {
        NET_INC_STATS(sock_net(sk), LINUX_MIB_TCPDSACKIGNOREDDUBIOUS);
        return false;
    }
    NET_ADD_STATS(sock_net(sk), LINUX_MIB_TCPDSACKRECVSEGS, dup_segs);
    // 调整 undo_retrans
    if (tp->undo_marker && tp->undo_retrans > 0 &&
        !after(end_seq_0, prior_snd_una) &&
        after(end_seq_0, tp->undo_marker))
        tp->undo_retrans = max_t(int, 0, tp->undo_retrans - dup_segs);

    return true;
}
```

DSACK 有效性的两个过滤条件（`tcp_dsack_seen`，第 1232 行）：
1. DSACK 范围不超过对端最大窗口（防止放大攻击）
2. DSACK 的重复段数量 `dup_segs` 不能超过实际重传的段数 `total_retrans`（防止伪造 DSACK 阻止拥塞控制）

### 7.4 tcp_dsack_seen 的防御逻辑

```c
// tcp_input.c:1232
static u32 tcp_dsack_seen(struct tcp_sock *tp, u32 start_seq,
                          u32 end_seq, struct tcp_sacktag_state *state)
{
    u32 seq_len, dup_segs = 1;
    if (!before(start_seq, end_seq))
        return 0;

    seq_len = end_seq - start_seq;
    /* Dubious DSACK: DSACKed range greater than maximum advertised rwnd */
    if (seq_len > tp->max_window)
        return 0;
    if (seq_len > tp->mss_cache)
        dup_segs = DIV_ROUND_UP(seq_len, tp->mss_cache);
    else if (tp->tlp_high_seq && tp->tlp_high_seq == end_seq)
        state->flag |= FLAG_DSACK_TLP;

    WRITE_ONCE(tp->dsack_dups, tp->dsack_dups + dup_segs);
    /* Skip the DSACK if dup segs weren't retransmitted by sender */
    if (tp->dsack_dups > tp->total_retrans)
        return 0;

    tp->rx_opt.sack_ok |= TCP_DSACK_SEEN;
    ...
    state->flag |= FLAG_DSACKING_ACK;
    state->sack_delivered += dup_segs;
    return dup_segs;
}
```

DSACK 发送后，`FLAG_DSACKING_ACK` 标记使发送端在 `tcp_clean_rtx_queue` 中不将这些包计入真正的"新确认"，从而避免错误地增加 cwnd。

---

## 8. FACK（Forward ACK）拥塞控制

### 8.1 FACK 的定义

FACK 在 Linux 中并非独立的拥塞算法，而是一个**量化指标**——`tcp_highest_sack_seq(tp)`，即当前已 SACK 确认的最高序列号。它在多个拥塞控制相关函数中作为前向参照点（forward anchor）使用。

### 8.2 FACK 在快速恢复中的应用

在 `tcp_fastretrans_alert`（第 3358 行）和 `tcp_xmit_retransmit_queue` 中，`prior_fack` 与 `reord` 的比较决定恢复状态：

```c
// tcp_input.c:3755
if (before(reord, prior_fack))
    tcp_check_sack_reordering(sk, reord, 0);
```

`reord` 是 `tcp_sacktag_write_queue` 中维护的"乱序前沿"——第一个乱序被 SACK 的位置。若 `reord < prior_fack`，说明有数据在 `prior_fack` 之前被乱序收到，可能需要更新 reordering 指标。

### 8.3 FACK 与 Reno/Cubic 的协同

FACK 的实际影响体现在以下方面：
1. **重排检测**：`tcp_check_sack_reordering` 使用 `tcp_highest_sack_seq` 作为 `fack` 基准（第 1282 行）
2. **恢复前向边界**：在 `tcp_enter_recovery`（第 3067 行）中，`prior_fack` 确定恢复的起点
3. **undo 判断**：DSACK 到来时用 `prior_fack` 判断是否可以撤销拥塞窗口缩减

### 8.4 `tcp_highest_sack` 相关操作

```c
// include/net/tcp.h:2367
static inline u32 tcp_highest_sack_seq(struct tcp_sock *tp)
{
    if (!tp->highest_sack)
        return tp->snd_una;
    return TCP_SKB_CB(tp->highest_sack)->seq;
}

// include/net/tcp.h:2378
static inline void tcp_advance_highest_sack(struct sock *sk, struct sk_buff *skb)
{
    tcp_sk(sk)->highest_sack = skb_rb_next(skb);
}
```

`highest_sack` 指针缓存红黑树中的最高 SACKed skb，避免每次都搜索树。`tcp_sacktag_walk`（第 2159 行）中，每次成功 SACK 标记一个 skb 后，若该 skb 是当前最高 SACKed 块，则调用 `tcp_advance_highest_sack` 推进缓存。

---

## 9. limit 和攻击防护

### 9.1 SACK 块数量上限

```c
// tcp_input.c:2230
int num_sacks = min(TCP_NUM_SACKS, (ptr[1] - TCPOLEN_SACK_BASE) >> 3);
```

解析 SACK 选项时，`TCP_NUM_SACKS`（4）限制了每 ACK 中最多处理 4 个 SACK 块。`tcp_sack_new_ofo_skb`（第 5149 行）同样限制 `selective_acks[]` 最多 4 个元素，超出时丢弃最旧的块。

### 9.2 DSACK 防御：序列号范围校验

```c
// tcp_input.c:1447 - tcp_is_sackblock_valid
static bool tcp_is_sackblock_valid(struct tcp_sock *tp, bool is_dsack,
                                   u32 start_seq, u32 end_seq)
{
    /* Too far in future, or reversed */
    if (after(end_seq, tp->snd_nxt) || !before(start_seq, end_seq))
        return false;

    /* Nasty start_seq wrap-around check */
    if (!before(start_seq, tp->snd_nxt))
        return false;

    /* In outstanding window? This is valid exit for D-SACKs too. */
    if (after(start_seq, tp->snd_una))
        return true;

    if (!is_dsack || !tp->undo_marker)
        return false;

    /* ...Then it's D-SACK, and must reside below snd_una completely */
    if (after(end_seq, tp->snd_una))
        return false;

    if (!before(start_seq, tp->undo_marker))
        return true;

    /* Too old */
    if (!after(end_seq, tp->undo_marker))
        return false;
    ...
}
```

验证条件：
- **不能超越 snd_nxt**：`end_seq` 必须在发送窗口内
- **不能反向**：`start_seq < end_seq`
- **非 D-SACK**：必须落在 `(snd_una, snd_nxt)` 区间内
- **D-SACK**：可以低于 snd_una（因为是重传副本），但必须不低于 `undo_marker`（避免处理过期 DSACK）

### 9.3 DSACK 数量防伪

```c
// tcp_input.c:1252
if (tp->dsack_dups > tp->total_retrans)
    return 0;  /* 丢弃无效 DSACK */
```

发送端维护 `dsack_dups`（收到的 DSACK 覆盖段数）和 `total_retrans`（总重传段数）。若 DSACK 声称的重复段数量超过实际重传量，说明对端在伪造 DSACK，丢弃该 DSACK。这防止攻击者通过伪造大量 DSACK 阻止发送端执行拥塞控制。

### 9.4 DSACK 范围不能超过对端窗口

```c
// tcp_input.c:1240
if (seq_len > tp->max_window)
    return 0;  /* Dubious DSACK */
```

`seq_len > max_window` 的 DSACK 被视为无效（Dubious DSACK），防止放大攻击。

### 9.5 ofo_queue 内存保护

```c
// tcp_input.c:5902
/* 3) Drop at least 12.5 % of sk_rcvbuf to avoid malicious attacks. */
```

`tcp_prune_ofo_queue`（第 5906 行）在内存压力下清理乱序队列。若 ofo_queue 占用的 skb 数量超过阈值，会删除最旧的乱序包，触发 DSACK 通知对端。

### 9.6 SackBlock 合法性再检查

```c
// tcp_input.c:2263
if (!tcp_is_sackblock_valid(tp, dup_sack, sp[used_sacks].start_seq,
                            sp[used_sacks].end_seq)) {
    // MIB 计数：TCPDSACKIGNOREDNOUNDO / TCPDSACKIGNOREDOLD / TCPSACKDISCARD
    ...
}
```

在 `tcp_sacktag_write_queue` 中，每个解析出的 SACK 块都会经过合法性检查，无效块直接丢弃并上报 MIB 统计。

---

## 10. 关键数据流总览

### 10.1 接收端乱序处理路径

```
数据包乱序到达
  → tcp_data_queue_ofo()           [tcp_input.c:5360]
    → ofo_queue 红黑树插入/合并
    → tcp_dsack_set() (如果重复)
    → tcp_sack_new_ofo_skb()        [tcp_input.c:5117]
      → selective_acks[] 更新
      → tcp_sack_maybe_coalesce()
    → tcp_ofo_queue()               [tcp_input.c:5273]
      → 填补空洞，移入 rcv_queue
      → tcp_sack_remove()            [tcp_input.c:5166]
        → rcv_nxt 推进后清理过期 SACK 块
```

### 10.2 发送端 SACK 处理路径

```
收到带 SACK 选项的 ACK
  → tcp_ack_tstamp() → tcp_clean_rtx_queue()
  → tcp_sacktag_write_queue()       [tcp_input.c:2220]
    → tcp_check_dsack()              [tcp_input.c:1485]
      → tcp_dsack_seen()              [tcp_input.c:1232]
        → 有效性检查 (窗口大小/重传次数)
    → tcp_sacktag_walk()             [tcp_input.c:2092]
      → 红黑树遍历 rtx_queue
      → tcp_sacktag_one()            [tcp_input.c:1612]
        → 标记 TCPCB_SACKED_ACKED
        → 更新 lost_out / retrans_out
        → 更新 reord (乱序前沿)
      → tcp_check_sack_reordering()  [tcp_input.c:1275]
        → 更新 tp->reordering
    → tcp_verify_left_out()
```

### 10.3 关键数据结构关系图

```
tcp_sock
├── rx_opt.num_sacks              // 有效 SACK 块数量
├── selective_acks[4]             // 接收端已收到的非连续块列表
├── duplicate_sack[1]              // D-SACK 块（对端通知的重复数据）
├── recv_sack_cache[4]             // 解析缓存
├── out_of_order_queue (rb_root)   // 乱序数据红黑树
├── ooo_last_skb                   // ofo_queue 最后一个 skb（O(1) 追加）
├── highest_sack                   // 红黑树中 highest SACKed skb 指针
├── reordering                     // 当前估计的最大重排距离（MSS 个数）
├── reord_seen                     // 发生重排的事件计数
└── dsack_dups                     // 累计收到的 DSACK 覆盖段数

tcp_skb_cb::sacked                 // 每个 skb 的 SACK 状态
├── TCPCB_SACKED_ACKED             // 已被 SACK 确认
├── TCPCB_SACKED_RETRANS           // 已标记为重传
├── TCPCB_LOST                      // 丢失判定
└── TCPCB_EVER_RETRANS             // 曾被重传过
```

---

## 11. 总结

Linux 的 TCP SACK 实现是一套精密配合的机制：

1. **乱序管理**：通过红黑树 `out_of_order_queue` 高效管理乱序包，首个乱序包自动生成 SACK 块通知发送端
2. **SACK 维护**：`tcp_sack_new_ofo_skb` / `tcp_sack_remove` 精确维护 `selective_acks[]`，支持块扩展、相邻合并和溢出丢弃
3. **选择性标记**：`tcp_sacktag_one` 在发送端重传队列上打标签，支持 D-SACK 识别虚假重传，配合 RACK 完成精确丢包判定
4. **乱序量化**：`reordering` 和 `reord` 变量量化网络重排程度，动态调整后续拥塞控制行为
5. **DSACK**：接收端主动生成 DSACK，发送端严格校验（窗口大小/重传次数），防止伪造 DSACK 攻击
6. **防御**：SACK 块数量上限、`tcp_is_sackblock_valid` 合法性检查、DSACK 数量比对、内存压力下 prune ofo_queue，构成了多层次的防护体系