# RDMA — 远程直接内存访问深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/infiniband/core/cm.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**RDMA**（Remote Direct Memory Access）允许跨网络直接访问远程内存，零拷贝、超低延迟，用于高性能计算和存储。

---

## 1. 核心数据结构

### 1.1 ib_device — RDMA 设备

```c
// drivers/infiniband/core/cm.c — cm_id
struct cm_id {
    struct ib_device       *device;         // RDMA 设备
    struct ib_qp            *qp;            // 关联的 Queue Pair
    cm_state                state;          // 连接状态

    // 地址
    __be64                  local_id;       // 本地 ID
    __be64                  remote_id;      // 远程 ID

    // 服务类型
    enum ib_qp_type        qp_type;       // RC/UC/UD
    union ib_gid            local_gid;      // 本地 GID
    union ib_gid            remote_gid;     // 远程 GID
};
```

### 1.2 ib_qp — Queue Pair

```c
// include/rdma/ib_verbs.h — ib_qp
struct ib_qp {
    struct ib_device       *device;         // 设备
    struct ib_pd            *pd;            // Protection Domain
    struct ib_cq            *send_cq;       // 发送完成队列
    struct ib_cq            *recv_cq;       // 接收完成队列

    // 状态
    enum ib_qp_state        state;         // IB_QPS_* 状态
    //   IB_QPS_RESET = 0
    //   IB_QPS_INIT  = 1
    //   IB_QPS_RTR  = 2（Ready to Receive）
    //   IB_QPS_RTS  = 3（Ready to Send）
    //   IB_QPS_SQD  = 4（Send Queue Drain）
    //   IB_QPS_SQE  = 5（Send Queue Error）
    //   IB_QPS_ERR  = 6
};
```

---

## 2. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/infiniband/core/cm.c` | `cm_id` |
| `include/rdma/ib_verbs.h` | `ib_qp` |