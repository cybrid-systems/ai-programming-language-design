# Linux Kernel RDMA (Remote Direct Memory Access) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/infiniband/` + `drivers/rdma/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. RDMA 概述

**RDMA** 实现**零拷贝网络**：远程机器直接读写本地内存，无需 CPU 介入，绕过内核网络栈。用于 HPC（高性能计算）和 AI 训练（GPUDirect）。

---

## 1. RDMA 动词

```c
// ibverbs — 用户空间 API
struct ibv_pd      *pd;        // Protection Domain
struct ibv_cq      *cq;        // Completion Queue
struct ibv_qp      *qp;        // Queue Pair
struct ibv_mr      *mr;        // Memory Region（注册内存）

// Queue Pair (QP) — RDMA 通信端点
//  UD: Unreliable Datagram（类似 UDP）
//  RC: Reliable Connection（类似 TCP）
//  UC: Unreliable Connection
```

---

## 2. 核心操作

```c
// 注册内存
mr = ibv_reg_mr(pd, buf, size, IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_WRITE);

// 发送/接收
ibv_post_send(qp, &sge, &wr);  // RDMA 写/发送
ibv_post_recv(qp, &sge, &wr);  // 接收

// 完成通知
ibv_poll_cq(cq, 1, &wc);        // 轮询完成队列
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/infiniband/core/cm.c` | Connection Manager（RDMA CM）|
| `drivers/rdma/verbs.c` | ibverbs 核心 |
