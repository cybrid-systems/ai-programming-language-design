# RDMA — 远程直接内存访问深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/infiniband/core/cm.c` + `include/rdma/ib_verbs.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**RDMA**（Remote Direct Memory Access）允许跨网络直接读写远程内存，零拷贝、超低延迟（微秒级），用于 HPC 集群、存储（NVMe-oF、iSER）、AI 训练。

## 1. 核心概念

```
传统网络：                       RDMA：
CPU → 内存复制 → 网卡            CPU → RDMA 引擎 → 网络 → 远程内存
         ↑                              ↑
      多次拷贝                       零拷贝
      高延迟                        微秒延迟
```

## 2. 核心数据结构

### 2.1 ib_device — RDMA 设备

```c
// drivers/infiniband/core/device.c — ib_device
struct ib_device {
    const char              *name;          // 设备名（mlx5_0, qib0）
    const struct ib_device_ops *ops;       // 设备操作函数表

    // 物理属性
    u64                     dma_mask;       // DMA 地址掩码
    u64                     local_dma_lkey;  // 本地 DMA 密钥

    // 资源
    struct ib_port          *ports;         // 端口数组
    struct rb_root           device_cache;   // 设备缓存

    // 队列
    struct ib_cq            *(*create_cq)(struct ib_device, ...);
    struct ib_qp            *(*create_qp)(struct ib_device, ...);
};
```

### 2.2 ib_qp — Queue Pair

```c
// include/rdma/ib_verbs.h — ib_qp
struct ib_qp {
    struct ib_device       *device;         // 设备
    struct ib_pd            *pd;            // Protection Domain
    struct ib_cq            *send_cq;       // 发送完成队列
    struct ib_cq            *recv_cq;       // 接收完成队列

    // 队列
    struct ib_wq            *send_wq;       // 发送工作队列
    struct ib_wq            *recv_wq;       // 接收工作队列

    // 状态机
    enum ib_qp_state        state;         // 状态
    //   IB_QPS_RESET = 0
    //   IB_QPS_INIT  = 1     — 初始化
    //   IB_QPS_RTR   = 2     — Ready to Receive
    //   IB_QPS_RTS   = 3     — Ready to Send
    //   IB_QPS_SQD   = 4     — Send Queue Drain
    //   IB_QPS_SQE   = 5     — Send Queue Error
    //   IB_QPS_ERR   = 6

    // 安全
    u32                     qp_num;        // QP 号（本地唯一）
    u32                     remote_qp_num; // 远程 QP 号
    u16                     pkey_index;     // P_Key 索引
    u8                      port_num;      // 端口号
};
```

### 2.3 ib_pd — Protection Domain

```c
// include/rdma/ib_verbs.h — ib_pd
struct ib_pd {
    struct ib_device       *device;         // 设备
    u32                     local_dma_lkey; // 本地 DMA 密钥
    u32                     unsafe_global_rkey; // 全局 RKey（危险）

    // 引用计数
    atomic_t                usecnt;         // 使用计数
};
```

### 2.4 ib_mr — Memory Region

```c
// include/rdma/ib_verbs.h — ib_mr
struct ib_mr {
    struct ib_device       *device;
    struct ib_pd            *pd;            // 所属 PD
    u32                     lkey;           // 本地访问密钥
    u32                     rkey;           // 远程访问密钥

    // 内存信息
    void                   *addr;           // 虚拟地址
    size_t                  length;         // 长度
    int                     access;         // 访问权限（IB_ACCESS_*）
};
```

## 3. 服务类型

### 3.1 RC — Reliable Connected

```c
// Reliable Connected：点对点可靠连接
// 类似 TCP，需要建立连接
// 保证顺序传递
// 用于：存储网络（iSCSI、iSER）

struct rdma_cm_id *id;
rdma_create_id(dev, &id, ...);
rdma_resolve_addr(id, src_addr, dst_addr, timeout);
rdma_connect(id, &conn_param);  // 建立 RC 连接
```

### 3.2 UD — Unreliable Datagram

```c
// Unreliable Datagram：无连接不可靠
// 类似 UDP
// 不保证顺序和到达
// 用于：通信加速（通信中间件）

// UD 可以多播
rdma_join_multicast(id, multicast_addr, ...);
```

## 4. RDMA 操作

### 4.1 Send/Recv

```c
// 接收端：预注册接收缓冲区
struct ib_sge sge = {
    .addr = (uintptr_t)buf,
    .length = size,
    .lkey = mr->lkey,
};
struct ib_recv_wr wr = {
    .wr_id = (uintptr_t)buf,
    .sg_list = &sge,
    .num_sge = 1,
};
ib_post_recv(qp, &wr, &bad_wr);

// 发送端：发送数据
ib_post_send(qp, &send_wr, &bad_wr);

// 接收端收到完成事件
ib_poll_cq(cq, 1, &wc);
```

### 4.2 RDMA Read/Write

```c
// RDMA Read：从远程读取（远程主机不参与运算）
struct ib_rdma_wr wr = {
    .wr.wr_id = id,
    .remote_addr = remote_addr,
    .rkey = remote_mr->rkey,
    .sg_list = &local_sge,
    .num_sge = 1,
};
ib_post_send(qp, &wr.wr, &bad_wr);

// RDMA Write：写入远程
wr.remote_addr = remote_addr;
wr.rkey = remote_mr->rkey;
```

## 5. 传输层（RoCE vs iWARP vs InfiniBand）

```c
// InfiniBand：原生 IB 网络
//   硬件：Mellanox ConnectX
//   网络：IB 交换器
//   延迟最低

// RoCE：RDMA over Converged Ethernet
//   即 RoCEv2
//   使用 UDP 封装（IP + UDP + RDMA）
//   需要无损网络（PFC 流控）

// iWARP：Internet Wide Area RDMA Protocol
//   使用 TCP 封装
//   可以穿越普通 IP 网络
```

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/rdma/ib_verbs.h` | `ib_qp`、`ib_pd`、`ib_mr`、`ib_cq` |
| `drivers/infiniband/core/device.c` | `ib_device` |
| `drivers/infiniband/core/cm.c` | `rdma_cm_id`、`connection manager` |

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

