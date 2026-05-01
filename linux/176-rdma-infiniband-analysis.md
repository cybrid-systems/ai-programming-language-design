# 176-RDMA_infiniband — RDMA与InfiniBand深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/infiniband/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**RDMA（Remote Direct Memory Access）** 允许两台机器直接读写对方内存，无需 CPU 介入。InfiniBand 是最早的 RDMA 网络，RoCE（RDMA over Converged Ethernet）和 iWARP 是以太网上的 RDMA。

## 1. 为什么 RDMA 快

```
传统网络：
  应用 → 内核协议栈（TCP/IP）→ 网卡 DMA → 网络
  问题：CPU 参与、数据复制（多次内核/用户切换）

RDMA：
  应用 → RDMA 网卡 DMA → 网络（零拷贝、零内核）
  优点：超低延迟（微秒级）、超低 CPU 占用、高带宽
```

## 2. 核心概念

### 2.1 Queue Pair（QP）

```
每个 RDMA 连接有一个 Queue Pair：
  Send Queue（发送队列）
  Receive Queue（接收队列）
  Completion Queue（完成队列）

操作：
  POST_SEND：向 Send Queue 提交工作请求（WR）
  POST_RECEIVE：向 Receive Queue 提交接收请求
  CQE：工作完成后，产生 Completion Queue Entry
```

### 2.2 Verbs API

```c
// RDMA verbs（用户空间 API）：
rdma_create_qp()    // 创建 Queue Pair
rdma_post_send()    // 发送
rdma_post_recv()     // 接收
rdma_get_recv_comp() // 获取接收完成
rdma_get_send_comp() // 获取发送完成

// 内核 verbs（驱动使用）：
ib_post_send()
ib_post_recv()
```

## 3. RDMA 内存注册

### 3.1 Memory Region（MR）

```
RDMA 访问前必须注册内存：
  mr = ib_reg_mr(pd, addr, size, access_flags)

access_flags：
  IB_ACCESS_LOCAL_WRITE  = 可写
  IB_ACCESS_REMOTE_WRITE = 允许远程写
  IB_ACCESS_REMOTE_READ  = 允许远程读
```

## 4. RDMA 传输模式

```
RC（Reliable Connected）：
  点对点可靠连接
  最常用

UD（Unreliable Datagram）：
  无连接不可靠
  类似 UDP

UC（Unreliable Connected）：
  可靠连接但不保证排序

XRC（Extended Reliable Connected）：
  跨 QP 共享连接
```

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/infiniband/core/cm.c` | RDMA CM（连接管理）|
| `drivers/infiniband/core/mad.c` | MAD（管理数据报）|

## 6. 西游记类喻

**RDMA** 就像"取经两地的直连电话"——

> 传统网络像通过天庭中转站打电话——先把话传给中转站（中内核协议栈），中转站再转给对方，延迟高、占用大。RDMA 像两地的神仙直接用专线电话——不用经过天庭中转，直接听到对方的声音。前提是两边都要在对方那里登记地址（Memory Region 注册），并且这个地址只能被授权的人访问。好处是超低延迟、超高带宽，CPU 完全不参与。

## 7. 关联文章

- **PCIe**（article 116）：RDMA 网卡是 PCIe 设备
- **mmu_notifier**（article 161）：RDMA 需要 mmu_notifier 跟踪内存变化

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

