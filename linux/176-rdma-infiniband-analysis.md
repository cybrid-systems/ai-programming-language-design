# 176-RDMA_infiniband — RDMA与InfiniBand深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/infiniband/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**RDMA（Remote Direct Memory Access）** 允许两台机器直接读写对方内存，无需 CPU 介入。InfiniBand 是最早的 RDMA 网络，RoCE（RDMA over Converged Ethernet）和 iWARP 是以太网上的 RDMA。

---

## 1. 为什么 RDMA 快

```
传统网络：
  应用 → 内核协议栈（TCP/IP）→ 网卡 DMA → 网络
  问题：CPU 参与、数据复制（多次内核/用户切换）

RDMA：
  应用 → RDMA 网卡 DMA → 网络（零拷贝、零内核）
  优点：超低延迟（微秒级）、超低 CPU 占用、高带宽
```

---

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

---

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

---

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

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/infiniband/core/cm.c` | RDMA CM（连接管理）|
| `drivers/infiniband/core/mad.c` | MAD（管理数据报）|

---

## 6. 西游记类喻

**RDMA** 就像"取经两地的直连电话"——

> 传统网络像通过天庭中转站打电话——先把话传给中转站（中内核协议栈），中转站再转给对方，延迟高、占用大。RDMA 像两地的神仙直接用专线电话——不用经过天庭中转，直接听到对方的声音。前提是两边都要在对方那里登记地址（Memory Region 注册），并且这个地址只能被授权的人访问。好处是超低延迟、超高带宽，CPU 完全不参与。

---

## 7. 关联文章

- **PCIe**（article 116）：RDMA 网卡是 PCIe 设备
- **mmu_notifier**（article 161）：RDMA 需要 mmu_notifier 跟踪内存变化