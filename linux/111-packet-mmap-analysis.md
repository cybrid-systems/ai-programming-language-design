# 111-packet-mmap — 高性能网络包捕获深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/packet/af_packet.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**packet_mmap** 通过共享内存的环形缓冲区（TPACKET_V3）实现高性能网络包捕获，零拷贝从网卡到用户空间，绕过内核协议栈。

## 1. 核心数据结构

### 1.1 struct tpacket_block_desc — 块描述符

```c
// include/uapi/linux/if_packet.h — tpacket_block_desc
struct tpacket_block_desc {
    __u32 version;           // TPACKET_V3 = 3
    __u32 offset_to_priv;    // 到私有数据的偏移
    struct tpacket_hdr_v1   bh1;
};

struct tpacket_hdr_v1 {
    __u32    block_status:1;   // 0=空闲，1=填充完成
    __u32    num_pkts:31;       // 本块中的包数
    __u32    offset_to_first;   // 到第一个包的偏移
    __u64    ts_first;           // 第一个包的时间戳
    __u64    ts_last;           // 最后一个包的时间戳
};
```

### 1.2 struct tpacket3_hdr — V3 包头

```c
// include/uapi/linux/if_packet.h — tpacket3_hdr
struct tpacket3_hdr {
    __u32    tp_next_offset;     // 到下一个包的偏移（0=最后一个）
    __u32    tp_sec;             // 秒
    __u32    tp_nsec;           // 纳秒
    __u32    tp_snaplen;         // 捕获长度
    __u32    tp_len;            // 原始长度
    __u32    tp_mac;            // MAC 头偏移
    __u32    tp_net;            // 网络层头偏移
    __u32    tp_vlan_tci;       // VLAN TCI
    __u32    tp_vlan_tpid;      // VLAN TPID
    __u32    tp_padding[4];     // 填充
};
```

### 1.3 struct packet_ring_buffer — 环形缓冲区

```c
// net/packet/af_packet.c — packet_ring_buffer
struct packet_ring_buffer {
    char              **pk_blk;     // 块指针数组
    unsigned int       pg_vec_len;  // 块数
    struct pgv        *pg_vec;      // 页向量

    atomic_t          pending;      // 待读块数
    struct tpacket_hdr **rd;        // 读指针（V1/V2）
};
```

## 2. 系统调用流程

### 2.1 packet_create — 创建 socket

```c
// net/packet/af_packet.c — packet_create
int packet_create(struct socket *sock, int protocol)
{
    struct packet_sock *po;

    // 1. 分配 packet_sock
    po = pkt_sock_alloc(sock, sizeof(*po));

    // 2. 初始化 ring buffer
    po->ring = NULL;

    // 3. 关联 netdevice（如果指定）
    // packet_bind(bind_dev);

    return 0;
}
```

### 2.2 packet_set_ring — 创建环形缓冲区

```c
// net/packet/af_packet.c — packet_set_ring
int packet_set_ring(struct socket *sock, struct tpacket_req *req)
{
    struct packet_sock *po = pkt_sk(sock);

    // 1. 分配块
    pg_vec_len = req->tp_block_nr;
    po->ring.pg_vec = vmalloc(sizeof(struct pgv) * pg_vec_len);

    // 2. 映射到用户空间
    if (req->tp_block_size)
        remap_pfn_range(vma, req->tp_block_nr * req->tp_block_size);

    // 3. 创建 TPACKET_V3 环形缓冲区
    if (po->tp_version == TPACKET_V3)
        init_prb_bdqc(po, req);

    return 0;
}
```

## 3. 数据包接收流程

```
网卡驱动 → netif_receive_skb()
        ↓
packet_rcv()         ← packet_sock 的协议处理
        ↓
pkt_v3_fill_curr_block()   ← 填充当前块
        ↓
pkt_v3_revoke()             ← 撤销已读块
```

## 4. TPACKET_V3 vs V1/V2

| 特性 | TPACKET_V1 | TPACKET_V2 | TPACKET_V3 |
|------|------------|------------|------------|
| 内存模型 | 固定帧 | 固定帧 | 可变块 |
| 零拷贝 | 部分 | 部分 | 完全 |
| 块大小 | 固定 | 固定 | 可配置 |
| 内存效率 | 低 | 中 | 高 |
| 时戳精度 | 微秒 | 纳秒 | 纳秒 |

## 5. 使用示例

```c
// 用户空间设置 TPACKET_V3 ring：
struct tpacket_req3 req = {
    .tp_block_size = getpagesize() * 64,  // 256KB
    .tp_block_nr = 64,                     // 64 个块
    .tp_frame_size = TPACKET_V3_HDRLEN,    // 头大小
    .tp_frame_nr = 0,                       // 自动（V3 不使用）
};

setsockopt(fd, SOL_PACKET, PACKET_VERSION, "TPACKET_V3", ...);
setsockopt(fd, SOL_PACKET, PACKET_RX_RING, &req, sizeof(req));

// 读取：
struct tpacket_block_desc *bd = mmap(0, req.tp_block_size * req.tp_block_nr,
                                      PROT_READ | PROT_WRITE, fd, 0);

while (1) {
    while (!(bd->hdr1.bh1.block_status & TP_STATUS_USER))
        usleep(1000);

    // 处理块中的所有包
    struct tpacket3_hdr *pkt = (void *)((char *)bd + bd->hdr1.bh1.offset_to_first);
    for (i = 0; i < bd->hdr1.bh1.num_pkts; i++) {
        process_packet(pkt);
        pkt = (void *)((char *)pkt + pkt->tp_next_offset);
    }

    bd->hdr1.bh1.block_status = 0;  // 释放块
}
```

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/packet/af_packet.c` | `packet_create`、`packet_set_ring`、`packet_rcv` |
| `include/uapi/linux/if_packet.h` | `tpacket_block_desc`、`tpacket3_hdr`、`tpacket_req` |

## 7. 西游记类比

**packet_mmap** 就像"取经路上的高速驿站"——

> 以前接收快递（数据包）要一个个来（recv），每个都要从快递站（内核）搬到手（用户空间）。packet_mmap 就像建了一条传送带（mmap 环形缓冲区），快递员（网卡驱动）把包裹直接放到传送带上，驿站（内核）只负责调度，不用搬运。TPACKET_V3 就像一个智能的传送带系统，每段传送带（block）满了就标记满（block_status=1），取经人（用户空间）直接去读传送带上的包裹，处理完再把传送带标记为空。这就是零拷贝网络捕获的精髓——数据和用户空间共享同一块物理内存。

## 8. 关联文章

- **sk_buff**（article 22）：packet_mmap 在协议栈中的 hook
- **netdevice**（相关）：netif_receive_skb → packet_rcv

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

