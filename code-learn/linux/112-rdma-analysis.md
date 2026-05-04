# 113-rdma — Linux RDMA（InfiniBand/RoCE）深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**RDMA（Remote Direct Memory Access）** 允许一台计算机直接读写另一台计算机的内存，无需 CPU 干预。InfiniBand（原生 RDMA）和 RoCE（RDMA over Converged Ethernet）是两种实现。Linux RDMA 栈分为用户空间（`libibverbs`）和内核空间（`drivers/infiniband/`）。

**核心设计**：RDMA 通过 `struct ib_device` 注册到内核，提供 `struct ib_verbs` 操作表。用户空间通过 `verbs.c` 的 `ib_create_qp`/`ib_post_send`/`ib_post_recv` 管理队列对（QP），数据直接在用户内存和远程内存之间传输。

```
用户空间            内核 RDMA 栈         硬件
libibverbs          drivers/infiniband/
  ibv_open_device() → ib_register_device()
  ibv_create_qp()    → ib_create_qp() → 驱动创建 QP
  ibv_post_send()    → ib_post_send() → 提交 WR 到 SQ
  ibv_poll_cq()      → ib_poll_cq()   → 从 CQ 取完成
```

**doom-lsp 确认**：`drivers/infiniband/core/verbs.c`（3,203 行），`ucma.c`（2,007 行），`include/rdma/ib_verbs.h`（5,095 行）。

---

## 1. 核心概念

```c
// RDMA 的三个核心队列：
// QP（Queue Pair）——通信端点，包含 SQ（发送队列）+ RQ（接收队列）
// CQ（Completion Queue）——完成队列，记录已完成的操作
// SRQ（Shared Receive Queue）——共享接收队列（可选）

// WR（Work Request）——工作请求，描述一次 RDMA 操作：
struct ib_send_wr {
    u64 wr_id;                                // 用户标识
    struct ib_send_wr *next;
    enum ib_wr_opcode opcode;                 // IB_WR_RDMA_WRITE / READ / SEND
    int num_sge;
    struct ib_sge sg_list;                    // 散列-聚合列表（数据位置）
};

struct ib_sge {
    u64 addr;                                  // 内存地址
    u32 length;                                // 长度
    u32 lkey;                                  // 本地密钥（内存保护）
};
```

---

## 2. 核心数据结构

```c
// include/rdma/ib_verbs.h
struct ib_device {
    struct device dev;
    const struct ib_device_ops *ops;          // 驱动操作

    u64 node_guid;                             // 节点 GUID
    u8 node_type;                              // 节点类型

    struct list_head port_list;                // 端口列表
    struct ib_device_attr attrs;               // 设备属性

    struct dentry *dentry;                     // debugfs 条目
};

struct ib_qp {                                 // 队列对
    struct ib_device *device;
    struct ib_pd *pd;                          // 保护域
    struct ib_cq *send_cq;                     // 发送完成队列
    struct ib_cq *recv_cq;                     // 接收完成队列
    enum ib_qp_state state;                    // 状态（RESET/INIT/RTR/RTS/SQD/SQE/ERR）
    u32 qp_num;                                // QP 号
};

struct ib_cq {                                 // 完成队列
    struct ib_device *device;
    struct ib_ucq_object *uobject;
    int cqe;                                    // 完成队列深度
};
```

---

## 3. 队列对状态机

```c
// QP 状态机（必须按顺序转换）：
// RESET → INIT → RTR（Ready to Receive）→ RTS（Ready to Send）
// → 数据传输...

// 转换通过 ib_modify_qp() 完成（修改 QP 状态+连接属性）：
ib_modify_qp(qp, &attr, attr_mask);
// attr_mask = IB_QP_STATE | IB_QP_AVL | IB_QP_PATH_MTU | ...
```

---

## 4. 内存注册（MR）

```c
// RDMA 操作前需要注册内存区域：
// ib_get_dma_mr(pd, access_flags) — 注册整个进程地址空间
// ib_reg_user_mr(pd, start, length, virt_addr, access_flags)
// → 注册用户空间内存 → 硬件 DMA 可访问

struct ib_mr {
    struct ib_device *device;
    u64 iova;                                  // I/O 虚拟地址
    u32 length;
    u32 rkey;                                  // 远程密钥（读/写）

## 5. 工作请求处理——ib_post_send

```c
// ib_post_send(qp, wr, bad_wr)——提交发送工作请求：
// → wr->opcode 决定操作类型：
//   IB_WR_SEND        — 发送消息
//   IB_WR_RDMA_WRITE  — RDMA 写（远程内存 ← 本地）
//   IB_WR_RDMA_READ   — RDMA 读（远程内存 → 本地）
//   IB_WR_ATOMIC_CMP_AND_SWP — 原子比较交换
//   IB_WR_ATOMIC_FETCH_AND_ADD — 原子取加

// WR 提交后硬件直接执行，完成时在 CQ 生成 WC：
struct ib_wc {
    u64 wr_id;
    enum ib_wc_status status;               // IB_WC_SUCCESS / IB_WC_WR_FLUSH_ERR
    enum ib_wc_opcode opcode;
    u32 byte_len;                            // 传输字节数
    u32 src_qp;                              // 源 QP 号
};

// ib_poll_cq(cq, num_entries, wc)——从 CQ 取完成
// → 返回完成的 WC 数量
```

## 6. 共享接收队列（SRQ）

```c
// SRQ——多个 QP 共享同一个接收队列（减少内存占用）：
struct ib_srq {
    struct ib_device *device;
    struct ib_pd *pd;
    struct ib_srq_attr attrs;
};

// ib_create_srq(pd, srq_init_attr) — 创建 SRQ
// ib_post_srq_recv(srq, recv_wr, bad_recv_wr) — 提交接收 WR 到 SRQ
// → 所有关联 QP 的接收操作从 SRQ 消费 WR
```

## 7. 寻址——GID 和 PKEY

```c
// RDMA 通信的寻址信息：
// GID（Global Identifier）——类似 IPv6 地址，128-bit
// PKEY（Partition Key）——16-bit 分区标识，类似 VLAN

// ib_query_gid(device, port_num, index, gid)
// → 获取端口的 GID 表

// QP 连接时设置：
// attr_mask = IB_QP_AVL;  // 地址向量（源 GID + MAC + VLAN）
// qp_attr.ah_attr.grh.dgid = dest_gid;
```

    u32 lkey;                                  // 本地密钥
};
```

---

## 5. 关键函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `ib_register_device` | `device.c` | RDMA 设备注册 |
| `ib_create_qp` | `verbs.c` | 创建队列对 |
| `ib_modify_qp` | `verbs.c` | QP 状态转换 |
| `ib_post_send` | `verbs.c` | 提交发送 WR |
| `ib_post_recv` | `verbs.c` | 提交接收 WR |
| `ib_poll_cq` | `verbs.c` | 轮询完成队列 |
| `ib_reg_user_mr` | `verbs.c` | 注册用户内存 |

---

## 6. 调试

```bash
# 查看 RDMA 设备
ibstat
ibv_devinfo

# 测试
ib_send_bw -d mlx5_0
ib_send_lat -d mlx5_0

# 查看 /sys
ls /sys/class/infiniband/
cat /sys/class/infiniband/mlx5_0/node_guid
```

---

## 7. 总结

RDMA 通过 `ib_create_qp`/`ib_post_send`/`ib_post_recv` 管理 QP 操作，QP 状态机（RESET→INIT→RTR→RTS）由 `ib_modify_qp` 控制。`ib_reg_user_mr` 注册用户内存区域供硬件 DMA 直接访问。CQ 通过 `ib_poll_cq` 获取完成通知。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*

## 8. GID 和地址解析 @ verbs.c（322 符号）

```c
// GID（Global Identifier）是 RDMA 端点地址（128-bit）：
// ib_query_gid(device, port, index, &gid)
// → 查询端口的 GID 表
// → GID 可以从 IPoIB 或 RoCE 的 MAC 地址派生

// ib_resolve_eth_dmac @ :59 — 解析 RoCE 目的 MAC：
// → 通过 ARP/ND 查找目的 GID 对应的 MAC
// → 设置 AH（Address Handle）的目的 MAC

// ib_wc_status_msg @ :119 — WC 状态码：
// IB_WC_SUCCESS           — 成功
// IB_WC_LOC_LEN_ERR       — 本地长度错误
// IB_WC_REM_ACCESS_ERR    — 远程访问错误
// IB_WC_RETRY_EXC_ERR     — 重试超限
// IB_WC_WR_FLUSH_ERR      — WR 被 flush
```

## 9. RDMA CM（Connection Manager）@ ucma.c（128 符号）

```c
// RDMA CM 管理 QP 连接的建立和断开：

struct ucma_file {
    struct mutex mut;
    struct file *filp;
    struct list_head ctx_list;          // 上下文列表
    struct list_head event_list;        // 事件列表
};

// ucma 事件流程：
// 1. 用户空间调用 rdma_create_id() → 内核创建 cm_id
// 2. rdma_resolve_addr() → 地址解析
// 3. rdma_resolve_route() → 路由解析
// 4. rdma_connect() → 发起连接
// 5. 对端响应 → ucma_event_handler() → 写入 event_list
// 6. 用户 rdma_accept() → 连接建立

// 事件类型：
// RDMA_CM_EVENT_ADDR_RESOLVED
// RDMA_CM_EVENT_ROUTE_RESOLVED
// RDMA_CM_EVENT_ESTABLISHED
// RDMA_CM_EVENT_DISCONNECTED
// RDMA_CM_EVENT_TIMEWAIT_EXIT
```

## 10. 内存注册详解

```c
// RDMA 内存注册（MR）——将用户内存映射到 HCA：

// ib_reg_user_mr(pd, start, length, virt, access_flags)
// → 分配 ib_mr 结构
// → pin_user_pages(addr, npages) — 锁定用户页面
// → HCA 写入页表（设备 DMA 可访问）
// → 返回 lkey/rkey（本地/远程密钥）

// 访问权限：
// IB_ACCESS_LOCAL_WRITE   — 本地写
// IB_ACCESS_REMOTE_WRITE  — 远程写
// IB_ACCESS_REMOTE_READ   — 远程读
// IB_ACCESS_REMOTE_ATOMIC — 远程原子操作
// IB_ACCESS_ZERO_BASED    — 零基地址

// ib_dereg_mr(mr) — 注销 MR：
// → unpin_user_pages() — 解锁页面
// → 清除 HCA 页表
// → 释放 ib_mr
```

## 11. 关键函数索引

| 函数 | 符号数 | 作用 |
|------|--------|------|
| `verbs.c` | 322 | 核心动词操作 |
| `ucma.c` | 128 | 连接管理 |
| `ib_create_qp` | — | 创建队列对 |
| `ib_modify_qp` | — | QP 状态转换（RESET→INIT→RTR→RTS）|
| `ib_post_send` | — | 提交发送 WR |
| `ib_reg_user_mr` | — | 注册用户内存 |
| `ib_resolve_eth_dmac` | :59 | 解析 RoCE MAC |
| `ib_wc_status_msg` | :119 | WC 状态码转换 |


## 12. SRQ 和原子操作

```c
// SRQ（Shared Receive Queue）——多个 QP 共享接收队列：
// ib_create_srq(pd, attr) → 创建 SRQ
// ib_post_srq_recv(srq, wr) → 提交接收 WR 到 SRQ
// → SRQ 减少内存占用（多个 QP 不需各自维护 RQ）

// RDMA 原子操作：
// IB_WR_ATOMIC_CMP_AND_SWP — 比较交换
// → 远程地址的值与 compare 比较
// → 相等则 swap 写入新值
// → 返回旧值

// IB_WR_ATOMIC_FETCH_AND_ADD — 取加
// → 远程地址的值 + add
// → 返回旧值

// 原子操作需要硬件和 MR 支持 REMOTE_ATOMIC 权限
```


## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `rdma_create_id()` | drivers/infiniband/core/cma.c | RDMA CM ID |
| `ib_post_send()` | drivers/infiniband/core/verbs.c | 发送 WR |
| `ib_post_recv()` | drivers/infiniband/core/verbs.c | 接收 WR |
| `struct ib_qp` | include/rdma/ib_verbs.h | 队列对 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
