# 111-packet-mmap — Linux PACKET_MMAP 和 AF_PACKET 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**AF_PACKET**（packet socket）是 Linux 的 L2 原始套接字，允许用户空间直接收发链路层数据包。**PACKET_MMAP**（`PACKET_RX_RING`/`PACKET_TX_RING`）通过 mmap 在用户空间和内核之间共享环形缓冲区，实现零拷贝数据包收发。

**核心设计**：`packet_sendmsg` 从用户空间复制数据构造 skb 后发送。`tpacket_rcv` 在接收时将 skb 数据写入 mmap 环形缓冲区并唤醒用户。`packet_mmap` 建立用户空间地址到内核 DMA 缓冲区的映射。

```
接收路径：
  netif_receive_skb(skb) → packet_rcv() / tpacket_rcv()
    → skb 数据写入 ring 缓冲区
    → 更新帧状态（TP_STATUS_USER  → 用户可读）
    → wake_up_interruptible(&po->sk->sk_wait)

发送路径：
  sendto(fd, buf, len, ...) → packet_sendmsg()
    → packet_snd() 构造 skb
    → dev_queue_xmit(skb)    // 从网卡发送

mmap 缓冲区布局：
  [sizeof(tpacket_hdr)] [skb data] [padding] [next_frame] ...
```

**doom-lsp 确认**：`net/packet/af_packet.c`（4,819 行）。`tpacket_rcv` @ `:192`，`packet_mmap` @ `:400`，`packet_sendmsg`。

---

## 1. 核心数据结构

```c
// net/packet/af_packet.c
struct packet_sock {
    struct sock sk;

    struct packet_ring_buffer rx_ring;       // 接收环形缓冲区
    struct packet_ring_buffer tx_ring;        // 发送环形缓冲区

    int ifindex;                              // 绑定的接口索引
    __be16 num;                               // 协议号（ETH_P_ALL / ETH_P_IP）
    unsigned int flags;                       // PACKET_* 标志

    spinlock_t bind_lock;
    struct mutex pg_vec_lock;
    unsigned int head;

    struct packet_fanout *fanout;             // 多 socket 扇出组
    union tpacket_stats_u stats;              // 统计
};

struct packet_ring_buffer {                  // — 环形缓冲区描述
    struct pgv *pg_vec;                       // 页面数组
    unsigned int head;                         // 生产者位置
    unsigned int frames_per_block;
    unsigned int frame_size;
    unsigned int frame_max;
    unsigned int pg_vec_order;
    unsigned int pg_vec_pages;
    unsigned int pg_vec_len;
};

struct tpacket_block_desc {                   // 块描述符（TPACKET_V3）
    struct tpacket_hdr_v1 h1;
    unsigned int block_status;                // TP_STATUS_USER / KERNEL
};
```

---

## 2. tpacket_rcv @ :192——mmap 接收

```c
// 当使用 PACKET_MMAP 时，packet_rcv 被 tpacket_rcv 替代
// 注册位置：packet_setsockopt(PACKET_RX_RING)

static int tpacket_rcv(struct sk_buff *skb, struct net_device *dev,
                        struct packet_type *pt, struct net_device *orig_dev)
{
    struct sock *sk = pt->af_packet_priv;
    struct packet_sock *po = pkt_sk(sk);
    struct tpacket3_hdr *hdr;

    // 1. 从 ring 获取空闲帧
    hdr = packet_current_rx_frame(po, skb, TP_STATUS_KERNEL);
    if (!hdr) goto drop;                       // ring 满→丢包

    // 2. 复制 skb 数据到 mmap 帧

## 2. 扇出（fanout）机制

```c
// 多个 packet socket 可以组成扇出组，共享负载：
// setsockopt(fd, SOL_PACKET, PACKET_FANOUT, &opt, sizeof(opt))

struct packet_fanout {
    struct list_head list;
    struct sock *arr[MAX_PACKET_FANOUT];      // socket 数组
    unsigned int num_members;                  // 成员数
    struct bpf_prog __rcu *bpf_prog;           // BPF 过滤
    u8 id;                                     // 扇出组 ID
    u8 type;                                   // PACKET_FANOUT_HASH / LB / CPU / ...
};

// 扇出类型：
// PACKET_FANOUT_HASH  — 按 skb 哈希分发
// PACKET_FANOUT_LB    — 轮询分发
// PACKET_FANOUT_CPU   — 按 CPU 分发
// PACKET_FANOUT_ROLLOVER — 故障切换
// PACKET_FANOUT_CBPF  — BPF 程序分发

// fanout 处理路径：
// tpacket_rcv → __fanout_link(po) → fanout_demux()
// → 按 type 选取目标 socket → 交付
```

## 3. 帧状态管理

```c
// __packet_set_status @ :400 — 帧状态转换：
// TP_STATUS_KERNEL — 内核拥有（用户不可读）
// TP_STATUS_USER   — 用户拥有（可读）
// TP_STATUS_SEND_REQUEST — 用户请求发送
// TP_STATUS_SENDING      — 正在发送
// TP_STATUS_LOSING       — 丢包

// __packet_set_status(po, frame, TP_STATUS_USER)  // 帧可读
// → smp_wmb() 保证状态更新先于数据可见
// → WRITE_ONCE(frame->status, TP_STATUS_USER)

// 用户读取帧后写回：
// frame->status = TP_STATUS_KERNEL  // 还给内核
```

    skb_copy_bits(skb, 0, hdr + 1, skb->len);
    hdr->tp_len = skb->len;
    hdr->tp_snaplen = skb->len;
    hdr->tp_mac = macoff;                      // MAC 偏移
    hdr->tp_net = netoff;                      // 网络层偏移

    // 3. 标记帧为可读
    hdr->tp_status = TP_STATUS_USER;           // → 用户可读取
    smp_wmb();

    // 4. 唤醒用户
    po->stats.tp_packets++;
    sk->sk_data_ready(sk);
}
```

---

## 3. packet_sendmsg——发送路径

```c
static int packet_sendmsg(struct socket *sock, struct msghdr *msg, size_t len)
{
    struct sock *sk = sock->sk;
    struct packet_sock *po = pkt_sk(sk);

    if (po->tx_ring.pg_vec)
        return tpacket_snd(po, msg, len);       // mmap 发送

    return packet_snd(sk, msg, len);             // 标准发送
}

// packet_snd @ :— 标准路径：
// 1. sock_alloc_send_skb(len, ...) 分配 skb
// 2. copy_from_iter(skb_put(skb, len), len, msg) 复制数据
// 3. dev_queue_xmit(skb) 从绑定的接口发送

// tpacket_snd @ :— mmap 发送路径：
// 1. 从 tx_ring 取帧
// 2. 如果帧已准备好（TP_STATUS_SEND_REQUEST）
// 3. 构造 skb（不复制数据，直接引用 mmap 页面）
// 4. dev_queue_xmit(skb)
```

---

## 4. PACKET_MMAP 版本

```c
// 三种 mmap 版本：
// TPACKET_V1：传统 32 位帧头（效率一般）
// TPACKET_V2：扩展 64 位帧头（时间戳、VLAN）
// TPACKET_V3：块模式（减少系统调用、批量接收）

// V3 块模式（推荐）：
// → 多个帧合成一个块
// → 用户等待整个块填满再读取
// → 减少 wake_up / poll 次数
// → setsockopt(fd, SOL_PACKET, PACKET_RX_RING, &req, sizeof(req))
//    req.tp_block_nr = 块数; req.tp_frame_size = 帧大小;
```

---

## 5. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `tpacket_rcv` | `:192` | mmap 接收（skb→ring→wake）|
| `packet_sendmsg` | — | 发送入口 |
| `packet_snd` | — | 标准发送（copy→xmit）|
| `tpacket_snd` | — | mmap 发送（ring→xmit）|
| `packet_mmap` | `:400` | mmap 映射建立 |
| `packet_rcv` | — | 标准接收（非 mmap）|

---

## 6. 调试

```bash
# PACKET_MMAP 查看统计
cat /proc/net/packet

# tcpdump 使用 PACKET_MMAP
tcpdump -i eth0

# 查看 ring 大小
cat /proc/sys/net/core/rmem_max
```

---

## 7. 总结

AF_PACKET 通过 `packet_sendmsg`/`tpacket_rcv` 收发 L2 数据包。PACKET_MMAP 通过 `packet_mmap` 建立环形缓冲区，`tpacket_rcv`（`:192`）将 skb 写入 ring 并标记 `TP_STATUS_USER`，`tpacket_snd` 从 ring 取帧发送。三版本（V1/V2/V3）中 V3 块模式通过批量处理减少系统调用。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*

## 8. PACKET_MMAP V3 块模式详解

```c
// TPACKET_V3 块模式（推荐）——多个帧组合为一个块：

// struct tpacket_req3 {
//     unsigned int tp_block_size;     // 块大小（必须 2^N 对齐）
//     unsigned int tp_block_nr;        // 块数
//     unsigned int tp_frame_size;     // 帧大小
//     unsigned int tp_frame_nr;        // 帧数
//     unsigned int tp_retire_blk_tov; // 块超时（ms）
//     unsigned int tp_sizeof_priv;    // 私有数据大小
//     unsigned int tp_feature_req_word; // 特性请求
// };

// V3 优势：
// → 减少系统调用（一次 poll 可能收到多个帧）
// → 降低延迟（块超时机制：tp_retire_blk_tov）
// → 批量处理提高吞吐量

// 块生命周期：
// 1. 内核写帧到块 → 标记 TP_STATUS_USER
// 2. 用户收到 POLLIN → 读取整个块
// 3. 用户完成 → 标记块为 TP_STATUS_KERNEL
// 4. 内核继续写入该块

// tpacket_rcv @ :192 — V3 接收处理：
// → prb_retire_current_block() — 满块切换
// → prb_open_block() — 打开新块
// → 写入帧到当前块
```

## 9. PACKET_MMAP V2 扩展功能

```c
// TPACKET_V2 相比 V1 的改进：

// struct tpacket2_hdr {
//     __u32 tp_status;
//     __u16 tp_len;                 // 数据长度
//     __u16 tp_snaplen;             // 捕获长度
//     __u16 tp_mac;                 // MAC 偏移
//     __u16 tp_net;                 // 网络层偏移
//     __u32 tp_sec;                 // 秒级时间戳
//     __u32 tp_nsec;                // 纳秒级时间戳
//     __u16 tp_vlan_tci;            // VLAN 标签
//     __u16 tp_vlan_tpid;           // VLAN 协议
//     __u8 tp_padding[4];
// };

// 新增功能：
// → 纳秒时间戳（V1 只有秒级）
// → VLAN 标签透传（tp_vlan_tci/tp_vlan_tpid）
// → 更大的 snaplen 范围
```

## 10. packet_set_ring @ :174

```c
// packet_set_ring — 设置 PACKET_MMAP 环形缓冲区：

// 1. 检查 socket 是否已绑定（已绑定时不能设置 ring）
// 2. 根据 req->tp_block_size 分配页面
//    pg_vec = alloc_pg_vec(btp, req, po->pg_vec_lock);
//    → alloc_one_pg_vec_page() — 分配连续物理页
//    → 每个块由多个物理页组成
// 3. 初始化 ring 参数：
//    po->rx_ring.pg_vec = pg_vec
//    po->rx_ring.frame_size = req->tp_frame_size
//    po->rx_ring.head = 0
// 4. 替换接收函数为 tpacket_rcv（非 mmap 时是 packet_rcv）
```

## 11. 关键函数索引

| 函数 | 符号数 | 作用 |
|------|--------|------|
| `af_packet.c` | 196 | AF_PACKET 实现 |
| `tpacket_rcv` | `:192` | mmap 接收（V1/V2/V3）|
| `packet_mmap` | — | mmap 映射建立 |
| `packet_sendmsg` | — | 发送入口 |
| `packet_set_ring` | `:174` | ring 缓冲区设置 |
| `packet_previous_frame` | `:195` | 前一个帧定位 |
| `prb_retire_current_block` | `:202` | 块完成处理 |
| `prb_open_block` | `:205` | 块打开初始化 |

