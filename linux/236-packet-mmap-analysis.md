# packet_mmap — AF_PACKET 环形缓冲区机制深度分析

> 源码基于：Linux 7.0-rc1 (`net/packet/af_packet.c` + `include/uapi/linux/if_packet.h`)
> 核心数据结构：`struct packet_sock`、`struct packet_ring_buffer`、`struct pgv`、`struct tpacket_kbdq_core`

---

## 1. 概述：为什么需要 packet_mmap？

传统 AF_PACKET socket 接收数据路径：

```
netif_receive_skb()
  → packet_rcv()
    → skb_copy_bits()         ← 每包一次拷贝
    → __skb_queue_tail()       ← 每包一次入队
    → sk->sk_data_ready()     ← 每次唤醒用户进程
```

用户调用 `recvfrom()` 时再从 `sk_receive_queue` 取出，**内核→用户空间两次拷贝**：
1. NIC DMA → skb（不可避免）
2. skb → 用户 buffer（可通过 mmap 消除）

packet_mmap 通过让用户进程直接 mmap 内核分配的页框，实现**零拷贝**（除 DMA 本身）。

---

## 2. mmap 内存布局：页框是如何映射的

### 2.1 关键数据结构

```c
// internal.h
struct pgv {
    char *buffer;          // 每个 block 的基地址（内核虚拟地址）
};

struct packet_ring_buffer {
    struct pgv           *pg_vec;          // 指向 pgv 数组，长度 = tp_block_nr
    unsigned int          head;            // 当前读位置（用户空间消费指针）
    unsigned int          frames_per_block; // 每个 block 包含的 frame 数量
    unsigned int          frame_size;       // 每个 frame 的大小
    unsigned int          frame_max;        // 最后一个 frame 的索引 (tp_frame_nr - 1)
    unsigned int          pg_vec_pages;     // 每个 block 占据的 PAGE_SIZE 页数
    unsigned int          pg_vec_len;       // block 数量 = tp_block_nr
    unsigned long        *rx_owner_map;     // V1/V2 的位图，表示 frame 是否被内核写入
    // V3 使用 tpacket_kbdq_core
    struct tpacket_kbdq_core prb_bdqc;     // V3 block 描述符队列核心
};
```

### 2.2 tpacket_req3 与内存布局的关系

```c
// if_packet.h
struct tpacket_req3 {
    unsigned int    tp_block_size;      // 每个 block 的大小（必须 PAGE_ALIGNED）
    unsigned int    tp_block_nr;         // block 数量
    unsigned int    tp_frame_size;       // 每个 frame 的大小
    unsigned int    tp_frame_nr;         // 总 frame 数 = tp_block_nr * frames_per_block
    unsigned int    tp_retire_blk_tov;   // V3: block 超时时间（ms）
    unsigned int    tp_sizeof_priv;      // V3: 每个 block 携带的私有数据大小
    unsigned int    tp_feature_req_word; // 特性标志（如 TP_FT_REQ_FILL_RXHASH）
};
```

**关键约束**：
```
tp_block_size  % PAGE_SIZE == 0           (必须是 PAGE_SIZE 的整数倍)
tp_frame_size  % TPACKET_ALIGNMENT == 0  (16 字节对齐)
frames_per_block = tp_block_size / tp_frame_size
tp_frame_nr     = tp_block_nr * frames_per_block
```

### 2.3 为什么 ring 不使用完整的 PAGE_SIZE？

block_size 必须是 PAGE_SIZE 的倍数，但 frame_size 可以任意（只要对齐）。这是因为：

1. **内存分配**：`alloc_one_pg_vec_page()` 调用 `__get_free_pages()` 按 `order` 分配 2^order 个连续物理页
2. **block vs frame**：block 是物理连续的单位（用于 V3 的 block-level 操作），frame 是逻辑记录单元
3. **mmap 对齐**：vm_insert_page 逐页映射，所以 block 必须是 PAGE_SIZE 的倍数
4. **frame 对齐**：TPACKET_ALIGNMENT=16 保证数据包头和数据都按 16 字节对齐

### 2.4 内存布局图（V1/V2）

```
用户进程 mmap 区域
+------------------------------------------------------------------+
|  rx_ring.pg_vec[0]        |  rx_ring.pg_vec[1]        | ...       |
|  (block 0)                |  (block 1)                |           |
|  tp_block_size bytes      |  tp_block_size bytes      |           |
|  +---------------------+  |  +---------------------+  |           |
|  | frame 0 | frame 1  |  |  | frame 0 | frame 1  |  |           |
|  | ...     | ...      |  |  | ...     | ...      |  |           |
|  +---------------------+  |  +---------------------+  |           |
+------------------------------------------------------------------+

每个 frame 内部布局（TPACKET_V2）：
+------------------------------------------+
| tpacket2_hdr (32 bytes aligned to 16)   |  ← tp_status, tp_len, tp_snaplen,
| sockaddr_ll (168 bytes aligned to 16)   |      tp_mac, tp_net, tp_sec, tp_nsec,
| pad to TPACKET_ALIGNMENT                |      tp_vlan_tci, tp_vlan_tpid
| MAC header (dev->hard_header_len)       |
| Payload (snaplen bytes)                  |
+------------------------------------------+
tp_hdrlen = TPACKET2_HDRLEN = TPACKET_ALIGN(32) + sizeof(sockaddr_ll) = 208
tp_reserve = 用户通过 SO_ATTACH_FILTER 设置，通常为 0
netoff = TPACKET_ALIGN(tp_hdrlen + max(maclen, 16)) + tp_reserve
```

### 2.5 packet_mmap 系统调用路径

```c
packet_mmap(file, sock, vma)
  → 遍历 rx_ring 和 tx_ring
  → 对每个 pg_vec[i].buffer 中的每一页（pg_vec_pages 页）
      vm_insert_page(vma, start + offset, page)
  → atomic_long_inc(&po->mapped)    // 映射引用计数
  → vma->vm_ops = &packet_mmap_ops  // 挂载自定义 vm_operations
```

关键：`pgv_to_page()` 处理 vmalloc vs direct mapping 的差异：

```c
static inline struct page *pgv_to_page(void *addr)
{
    if (is_vmalloc_addr(addr))
        return vmalloc_to_page(addr);   // vmalloc 路径
    return virt_to_page(addr);           // 连续页路径
}
```

**注意**：`__get_free_pages` 失败时降级到 `vmalloc`，所以同一 ring buffer 可能混合两种分配方式。`pgv_to_page()` 统一处理。

---

## 3. 发送路径：send() → ring buffer → skb

### 3.1 tpacket_snd 完整流程

```
用户空间                            内核
=========                           ====================
用户填充 frame
  tp_len, tp_status=AVAILABLE
  tp_net/tp_mac (可选)

send(fd, buf, len, 0)
  → packet_snd()
    → tpacket_snd()
      ┌─ while (1) {
      │  ph = packet_current_frame(po, &po->tx_ring, TP_STATUS_AVAILABLE)
      │    → packet_lookup_frame(rb, rb->head, TP_STATUS_AVAILABLE)
      │      → pg_vec_pos = head / frames_per_block
      │      → frame_offset = head % frames_per_block
      │      → return pg_vec[pg_vec_pos].buffer + frame_offset * frame_size
      │  if ph == NULL → wait_for_completion (阻塞模式)
      │
      │  tp_len = tpacket_parse_header(po, ph, frame_size, &data)
      │    → 从 frame 中解析 tp_len，检查 tp_net/tp_mac 偏移
      │
      │  status = TP_STATUS_SEND_REQUEST
      │  skb = sock_alloc_send_skb()        ← 分配 skb
      │
      │  tpacket_fill_skb(po, skb, ph, dev, data, tp_len, ...)
      │    → skb_reserve(skb, hlen)          ← 留出 dev header 空间
      │    → skb_put(skb, tp_len)            ← 填充数据到 skb
      │    → skb_zcopy_set_nouarg(skb, ph)   ← 将 frame 指针绑定到 skb
      │    → skb->destructor = tpacket_destruct_skb
      │
      │  __packet_set_status(po, ph, TP_STATUS_SENDING)
      │  packet_inc_pending(&po->tx_ring)
      │
      │  packet_xmit(po, skb)
      │    → dev_queue_xmit(skb) 或直接发送
      │
      │  packet_increment_head(&po->tx_ring) ← head++ (模 frame_max+1)
      │
      │  // 发送完成后（TX completion 通过 tpacket_destruct_skb 异步处理）
      │  tpacket_destruct_skb(skb)
      │    → packet_dec_pending(&po->tx_ring)
      │    → ts = __packet_set_timestamp(po, ph, skb)
      │    → __packet_set_status(po, ph, TP_STATUS_AVAILABLE | ts)
      │    → complete(&po->skb_completion)
      │
      └─ } while (msg->msg_iovlen 或更多待发帧)
```

### 3.2 发送状态机（tx_ring tp_status）

```
      用户填充 frame
          │
          ▼
   tp_status = 0 (AVAILABLE)
          │
   用户调用 send()
          │
          ▼
   tp_status = SEND_REQUEST
   (防止重复发送)
          │
   tpacket_fill_skb
   & packet_xmit
          │
          ▼
   tp_status = SENDING
   (packets pending)
          │
   TX completion
   (destructor)
          │
          ▼
   tp_status = AVAILABLE
   + timestamp 标志
```

### 3.3 关键设计：为什么需要 TP_STATUS_SEND_REQUEST？

为了支持**并发发送**和**乱序完成**：

1. 用户可能同时提交多个 frame（零拷贝场景）
2. 内核按 NIC 的发送完成顺序异步通知
3. `ph` 指针通过 `skb_zcopy_set_nouarg(skb, ph)` 绑定到 skb
4. `packet_inc_pending()` 增加 pending count，延迟 frame 回收

---

## 4. 接收路径：netif_receive_skb → ring buffer

### 4.1 从 NIC 到 packet socket 的完整调用链

```
NIC 驱动（DMA）
    → netif_receive_skb(skb)
      → __netif_receive_skb_core(skb, !!ptype)
        → list_for_each_entry_rcu(ptype, &ptype_all, list)
          → packet_type.func (packet_rcv / tpacket_rcv)

或者（设备注册了自己的 packet_type）：
    → dev_add_pack(&po->prot_hook)
      → packet_rcv(skb, dev, pt, orig_dev)       ← 非 mmap 路径
         或
         tpacket_rcv(skb, dev, pt, orig_dev)     ← mmap 路径
```

### 4.2 packet_rcv vs tpacket_rcv

在 `packet_set_ring()` 结束时决定回调函数：

```c
po->prot_hook.func = (po->rx_ring.pg_vec) ?
    tpacket_rcv : packet_rcv;     // 第 4580 行
```

| | packet_rcv | tpacket_rcv |
|---|---|---|
| 路径 | 走 sk_receive_queue | 直接写 ring buffer |
| 拷贝 | skb_copy_bits → 每次 recvfrom 拷贝 | 每次 packet 到达时拷贝到 ring |
| 阻塞 | recvfrom 阻塞等待 | poll/select 等 ring 有数据 |
| 零拷贝 | ❌ | ✅ |

### 4.3 tpacket_rcv 详细流程（V1/V2）

```c
tpacket_rcv(skb, dev, pt, orig_dev)
  → run_filter(skb, sk, snaplen)           // BPF 过滤
  → __packet_rcv_has_room()                 // 检查 ring 是否有空间
  → macoff, netoff = 计算帧头布局
  → h.raw = packet_current_rx_frame(po, skb, TP_STATUS_KERNEL, macoff+snaplen)
  │   → packet_lookup_frame(rb, rb->head, TP_STATUS_KERNEL)
  │     → 检查 pg_vec[head/frames_per_block] 中 head%frames_per_block 帧
  │     → 检查 tp_status == TP_STATUS_KERNEL？
  │
  → test_and_set_bit(slot_id, rx_owner_map) // V1/V2: 标记 frame 为"内核持有"
  → skb_copy_bits(skb, 0, h.raw + macoff, snaplen)  // 数据拷贝
  → ts_status = tpacket_get_timestamp(skb, &ts, po->tp_tstamp)
  → tpacket_fill_hdr(h, ts, ts_status, macoff, netoff)  // 填充帧头
  → smp_mb()
  → flush_dcache_page()                    // ARM/MIPS 等需要手动刷 DCache
  → __packet_set_status(po, h.raw, status | TP_STATUS_USER)
  → __clear_bit(slot_id, rx_owner_map)     // 释放 frame
  → packet_increment_rx_head(po, &po->rx_ring)
```

### 4.4 tpacket_rcv 的 Room 检查（V3 线性化关键）

```c
// __packet_rcv_has_room 决定是否丢弃或线性化
static int __packet_rcv_has_room(const struct packet_sock *po, struct sk_buff *skb)
{
    struct packet_ring_buffer *rb = &po->rx_ring;
    int val;

    if (po->tp_version <= TPACKET_V2) {
        // V1/V2: 如果当前 head 指向的 frame 还是 TP_STATUS_KERNEL，
        // 说明用户还没消费，内核不能再写 → 返回 ROOM_NONE
        if (test_bit(rb->head, rb->rx_owner_map))
            return ROOM_NONE;
        return ROOM_NORMAL;
    }
    // V3: 基于 block 状态判断
    ...
}
```

---

## 5. TPACKET_V3：Block 抽象与线性化

### 5.1 V3 的核心数据结构

```c
// V3 不再以 frame 为单位，而是以 block 为单位管理

struct tpacket_block_desc {
    __u32  version;          // 必须为 TPACKET_V3
    __u32  offset_to_priv;   // 私有数据区偏移
    union {
        struct tpacket_hdr_v1 bh1;  // block-level 元数据
    };
};

struct tpacket_hdr_v1 {
    __u32        block_status;        // BLOCK_STATUS(pbd) — 当前 block 是否可写
    __u32        num_pkts;             // 包含的数据包数量
    __u32        offset_to_first_pkt;  // 第一个包的偏移
    __u32        blk_len;              // 已使用的字节数（含填充）
    __aligned_u64 seq_num;             // 递增序号
    struct tpacket_bd_ts  ts_first_pkt;
    struct tpacket_bd_ts  ts_last_pkt;
};

struct tpacket_kbdq_core {           // block 管理核心
    struct pgv   *pkbdq;              // 指向 pg_vec 数组
    char         *pkblk_start;         // 当前 block 基地址
    char         *pkblk_end;          // 当前 block 结束地址
    char         *nxt_offset;         // 下一个可用位置
    int           kblk_size;          // block 大小
    unsigned int  max_frame_len;      // 单帧最大 = kblk_size - BLK_PLUS_PRIV
    unsigned int  knum_blocks;        // block 总数
    uint64_t      knxt_seq_num;       // 下一个序号
    struct sk_buff *skb;              // 正在填充当前 block 的 skb
    rwlock_t      blk_fill_in_prog_lock; // 防止 timer 和 rcv 并发冲突
    ktime_t       interval_ktime;     // retire 定时器间隔
    struct hrtimer retire_blk_timer;  // 超时timer
};
```

### 5.2 V3 的内存布局

```
pg_vec[i] (一个 block)
+----------------------------------------------------------+
| struct tpacket_block_desc (48 bytes, 8-aligned)         |
|   +------------------------------------------------+     |
|   | block_status | seq_num | num_pkts | blk_len    |     |
|   | ts_first_pkt | ts_last_pkt                      |     |
|   +------------------------------------------------+     |
| offset_to_priv (指向私有数据区，若 tp_sizeof_priv > 0)     |
|----------------------------------------------------------|
| [私有数据区 tp_sizeof_priv 字节]                         |
|----------------------------------------------------------|
| 数据包 1: tpacket3_hdr + sockaddr_ll + padding + payload |
| 数据包 2: tpacket3_hdr + sockaddr_ll + padding + payload |
| ...                                                      |
| 当前块已满或超时时 → flush_block() → 切换到下一 block      |
+----------------------------------------------------------+
BLK_PLUS_PRIV(sz) = ALIGN(sizeof(block_desc), 8) + ALIGN(sz, 8)
max_frame_len = kblk_size - BLK_PLUS_PRIV(tp_sizeof_priv)
```

### 5.3 V3 的"线性化"（Linearize）是什么？

V3 **不需要** 线性化！"linearize"是一个误解，V3 的设计避免了它。

真正发生的是：**数据包合并到 block 时自动处理填充对齐**：

```c
// prb_fill_curr_block 中
ppd->tp_next_offset = TOTAL_PKT_LEN_INCL_ALIGN(len);
// 计算方式：
TOTAL_PKT_LEN_INCL_ALIGN(len) = TPACKET_ALIGN(
    sizeof(tpacket3_hdr) + sizeof(sockaddr_ll) + len
)
```

**每个包的 tp_next_offset** 指向下一个包的位置，用户空间按 `tp_next_offset` 遍历，无需线性化。

### 5.4 V3 的超时（Retire）机制

```c
// prb_retire_rx_blk_timer_expired (hrtimer 回调)
  当 block 超时（默认 8ms 或根据链路速度计算）：
    → 如果 block 中有数据包（num_pkts > 0）：
        prb_retire_current_block() → prb_flush_block() → TP_STATUS_USER
        prb_dispatch_next_block()   → 开启新 block
    → 如果 block 为空：
        重新开启该 block（thaw queue）
    → 重启 timer
```

**关键锁**：`blk_fill_in_prog_lock` 防止 timer 和 `tpacket_rcv` 并发冲突：

```c
// tpacket_rcv 中填充 block 时：
read_lock(&pkc->blk_fill_in_prog_lock);
prb_run_all_ft_ops(pkc, ppd);    // 填充 VLAN/HASH 等

// timer 端：
if (BLOCK_NUM_PKTS(pbd)) {
    write_lock(&pkc->blk_fill_in_prog_lock);
    write_unlock(&pkc->blk_fill_in_prog_lock);  // 等待 fill 完成
}
```

---

## 6. tp_status 状态机：读写冲突管理

### 6.1 接收侧（rx_ring）状态

```
tp_status 值（Rx）：
  TP_STATUS_KERNEL (0)     ← 内核正在写（或已写完等待用户消费）
  TP_STATUS_USER            ← 用户已消费完，frame 可重用
  TP_STATUS_COPY            ← 数据被拷贝到 fallback skb_queue
  TP_STATUS_LOSING          ← 有丢包（用户读统计后清除）
  TP_STATUS_CSUMNOTREADY    ← skb->ip_summed == CHECKSUM_PARTIAL
  TP_STATUS_VLAN_VALID      ← tp_vlan_tci 有效
  TP_STATUS_BLK_TMO         ← V3: block 因超时被关闭
  TP_STATUS_TS_SOFTWARE     ← 软件时间戳
  TP_STATUS_TS_RAW_HARDWARE ← 硬件时间戳

V1/V2 读冲突管理：
  内核写入前：test_and_set_bit(head, rx_owner_map)  // 原子的"加锁"
  内核写完后：__packet_set_status(STATUS_USER) + clear_bit  // 解锁
  用户消费后：再次尝试读下一个 frame

V3 读冲突管理：
  以 block 为单位，block_status = TP_STATUS_KERNEL 表示"正在填充"
  用户 poll() block → status 变为 TP_STATUS_USER → 用户可以安全读取
```

### 6.2 发送侧（tx_ring）状态

```
tp_status 值（Tx）：
  TP_STATUS_AVAILABLE (0)    ← 空闲，用户可以填充
  TP_STATUS_SEND_REQUEST      ← 用户已提交，等待发送
  TP_STATUS_SENDING          ← 正在发送（有 pending skb）
  TP_STATUS_WRONG_FORMAT     ← 发送失败，格式错误

发送冲突管理（异步）：
  用户提交 → set AVAILABLE → set SEND_REQUEST
  内核取走   →  set SENDING (pending++)
  完成       →  destructor: set AVAILABLE + pending--
  如果 pending 且用户阻塞 → wait_for_completion
```

### 6.3 完整接收状态流转图

```
                          netif_receive_skb
                                │
                                ▼
              ┌─ test_bit(head, rx_owner_map)? ─┐
              │         (V1/V2)                  │
         Yes  │                                 No
              ▼                                  ▼
         丢弃 (ROOM_NONE)              packet_current_rx_frame()
                                             │
                                             ▼
                              test_and_set_bit(head) ← 内核加锁
                                             │
                                             ▼
                                   skb_copy_bits → ring
                                             │
                                             ▼
                              __packet_set_status(USER)
                              __clear_bit(head)      ← 内核解锁
                              packet_increment_head()
                                             │
                                             ▼
                                  用户 poll() 返回 EPOLLIN
                                             │
                                             ▼
                                  用户 recvfrom() / read()
                                             │
                                             ▼
                                  tp_status 仍为 USER（消费后不清除，
                                  用户空间通过观察 ring head 位置判断）
                                  下一轮内核写入时检查 test_bit
                                  若为 0（用户已消费）→ 可写
```

---

## 7. Fanout 机制：多进程共享同一个 socket

### 7.1 为什么需要 Fanout？

一个 NIC 可能需要被多个进程/线程同时监控。Fanout 允许：
- 多个 `packet_socket` 加入同一个 fanout group
- 每个数据包只被**一个**成员接收
- 避免竞争 `sk_receive_queue`

### 7.2 Fanout 类型

```c
enum {
    PACKET_FANOUT_HASH        = 0,    // 按 skb->hash 分配（L3/L4）
    PACKET_FANOUT_LB          = 1,    // 轮询（load balance）
    PACKET_FANOUT_CPU         = 2,    // 按 CPU ID 分配
    PACKET_FANOUT_RND         = 3,    // 随机
    PACKET_FANOUT_QM          = 4,    // 按 queue_mapping 分配
    PACKET_FANOUT_ROLLOVER    = 5,    // 智能 rollover
    PACKET_FANOUT_CBPF        = 6,    // 经典 BPF 程序分配
    PACKET_FANOUT_EBPF        = 7,   // 扩展 BPF 程序分配
};
```

### 7.3 Fanout 数据结构

```c
struct packet_fanout {
    possible_net_t     net;
    unsigned int       num_members;         // 当前成员数
    u32                max_num_members;     // 最大成员数
    u16                id;                  // fanout group ID
    u8                 type;               // 分配算法类型
    u8                 flags;              // ROLLOVER / DEFRAG / IGNORE_OUTGOING 等
    atomic_t           rr_cur;              // 轮询计数器（LB 模式）
    struct bpf_prog   *bpf_prog;           // BPF 程序（CBPF/EBPF）
    spinlock_t         lock;                // 保护成员数组
    struct packet_type prot_hook;          // 注册到 ptype_all
    struct sock       *arr[];               // 成员 socket 数组（RCU 保护）
};
```

### 7.4 packet_rcv_fanout 分发流程

```
packet_rcv_fanout(skb, dev, pt, orig_dev)
  → f = pt->af_packet_priv
  → num = READ_ONCE(f->num_members)
  → switch (f->type):
      HASH:   idx = __skb_get_hash_symmetric(skb) % num
      LB:     idx = atomic_inc_return(&f->rr_cur) % num
      CPU:    idx = smp_processor_id() % num
      RND:    idx = get_random_u32_below(num)
      QM:     idx = skb_get_queue_mapping(skb) % num
      ROLLOVER: 先用 primary idx，再用 __packet_rcv_has_room 查找
      CBPF/EBPF: 运行 BPF 程序得到 idx
  → po = pkt_sk(f->arr[idx])
  → po->prot_hook.func(skb, ...)   ← 调用各自 socket 的 tpacket_rcv 或 packet_rcv
```

### 7.5 Fanout 的GRO（Generic Receive Offload）处理

```
packet_rcv_fanout
  → 如果 PACKET_FANOUT_FLAG_DEFRAG 设置：
        ip_check_defrag(net, skb, IP_DEFRAG_AF_PACKET)
        → 先重组再分发（用于 IP 分片包）
```

---

## 8. 时间戳：SO_TIMESTAMPING 与 tp_reserve

### 8.1 时间戳相关标志

```c
// SO_TIMESTAMPING 选项（用户 setsockopt）
SOF_TIMESTAMPING_TX_SOFTWARE    // 发送时记录软件时间戳
SOF_TIMESTAMPING_RX_SOFTWARE    // 接收时记录软件时间戳
SOF_TIMESTAMPING_RAW_HARDWARE   // 使用硬件时间戳
SOF_TIMESTAMPING_SOFTWARE       // 使用软件时间戳
SOF_TIMESTAMPING_OPT_CMSG       // 时间戳通过 cmsg 传递
SOF_TIMESTAMPING_OPT_TSONLY     // 只记录时间戳，不传数据

// tp_status 中的时间戳标志
TP_STATUS_TS_SOFTWARE   (1 << 29)
TP_STATUS_TS_SYS_HARDWARE (1 << 30)  // 已废弃
TP_STATUS_TS_RAW_HARDWARE (1U << 31)
```

### 8.2 tpacket_get_timestamp 的选择逻辑

```c
static __u32 tpacket_get_timestamp(skb, ts, flags)
{
    // 优先使用 skb 中已有的时间戳
    if ((flags & SOF_TIMESTAMPING_RAW_HARDWARE) &&
        skb_hwtstamps(skb)->hwtstamp)
        → TP_STATUS_TS_RAW_HARDWARE

    else if ((flags & SOF_TIMESTAMPING_SOFTWARE) &&
             skb_tstamp(skb))
        → TP_STATUS_TS_SOFTWARE

    else → 返回 0（未设置时间戳）
}
```

### 8.3 tp_reserve 的作用

`tp_reserve` 是用户空间在设置 `SO_ATTACH_FILTER` 时指定的额外预留空间，通常用于 BPF 程序需要将数据移动到帧头之前。

在 `tpacket_rcv` 的 `netoff` 计算中：

```c
netoff = TPACKET_ALIGN(po->tp_hdrlen +
                       (maclen < 16 ? 16 : maclen)) +
        po->tp_reserve;   // ← 额外的预留空间
```

**这不是时间戳专用字段**，而是为将来扩展（如 TPACKET_V4 的新元数据）预留。

---

## 9. packet_mmap vs AF_INET raw socket：本质区别

| 维度 | packet_mmap (AF_PACKET) | AF_INET raw socket |
|------|------------------------|--------------------|
| **协议层** | 链路层（跳过 L3/L4） | 网络层/传输层 |
| **数据内容** | 完整 Ethernet frame（含 MAC 头） | 仅 IP header + payload |
| **DMA 目标** | skb（必须经过协议栈） | 同样是 skb |
| **零拷贝** | ring buffer mmap → 用户直接读 | recvfrom 仍需拷贝 |
| **设备过滤** | 基于 NIC 接口（ifindex） | 基于协议号 proto |
| **BPF 过滤** | 在 `packet_rcv`/`tpacket_rcv` 中运行 | 在 rawv6_rcv/raw_rcv 中运行 |
| **VLAN** | 完整保留（在 tpacket2_hdr 中有 tp_vlan_tci） | 需要额外处理 |
| **发送** | 支持（tx_ring） | 支持（sendto） |
| **广播/组播** | 自动接收（依赖网卡混杂模式） | 需加入组播组 |
| **最大snaplen** | 受 frame_size 限制（通常 65535） | 受 buffer size 限制 |

**核心区别**：
- `AF_PACKET` socket 是**链路层 socket**，直接与 NIC 驱动交互
- `AF_INET raw` socket 是**网络层 socket**，数据流经 L3 协议处理
- packet_mmap 通过 ring buffer 避免了内核→用户的最后一次拷贝
- raw socket 始终需要一次 `skb_copy_to_datagram_iovec` 或 `skb_recvmmsg`

---

## 10. 总结：各组件关系全图

```
┌─────────────────────────────────────────────────────────────────┐
│                     用户进程                                     │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐  │
│  │  mmap ring   │     │  send()      │     │  poll()/     │  │
│  │  (直接读帧)   │     │  (填充 frame) │     │  recvfrom()  │  │
│  └──────┬───────┘     └──────┬───────┘     └──────┬───────┘  │
└─────────┼─────────────────────┼─────────────────────┼──────────┘
          │ mmap()              │ sendto()            │ recvfrom()
          ▼                     ▼                     ▼
┌─────────────────────────────────────────────────────────────────┐
│                     内核                                         │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              packet_sock (struct packet_sock)            │  │
│  │  ┌────────────────┐        ┌────────────────┐             │  │
│  │  │   rx_ring      │        │   tx_ring      │             │  │
│  │  │   pg_vec[]     │        │   pg_vec[]     │             │  │
│  │  │   prb_bdqc     │        │                │             │  │
│  │  │  (V3 block)    │        │                │             │  │
│  │  └───────┬────────┘        └───────┬────────┘             │  │
│  │          │                          │                      │  │
│  │          │ tpacket_rcv              │ tpacket_snd          │  │
│  │          │ (写 ring)                │ (读 ring)            │  │
│  └──────────┼──────────────────────────┼─────────────────────┘  │
│             │                          │                         │
│             │ skb_copy_bits            │ tpacket_fill_skb       │
│             │ (DMA → ring)              │ (ring → skb)           │
│             ▼                          ▼                         │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │             netif_receive_skb()                           │  │
│  │                    │                                       │  │
│  │     ┌──────────────┴───────────────┐                     │  │
│  │     │         packet_rcv           │ ← 非 mmap 路径       │  │
│  │     │       packet_rcv_fanout     │ ← fanout 分发         │  │
│  │     │       tpacket_rcv            │ ← mmap 路径          │  │
│  │     └──────────────────────────────┘                     │  │
│  │                          │                               │  │
│  │                    NIC 驱动（DMA）                        │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

**核心设计哲学**：packet_mmap 通过两层抽象实现零拷贝：
1. **物理层**：vm_insert_page 将内核分配的页框直接映射到用户进程地址空间
2. **逻辑层**：tp_status 状态机在用户进程和内核之间实现无锁（lock-free）的单生产者单消费者队列（V1/V2 使用位图，V3 使用 block 级别的状态和 sequence number）
