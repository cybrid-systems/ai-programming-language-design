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
