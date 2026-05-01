# 29-io_uring — 异步 IO 框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**io_uring** 是 Linux 5.1 引入的异步 IO 框架，解决了传统 AIO 的高延迟和功能限制问题。核心创新：通过**共享环形缓冲区（ring buffer）** 在内核和用户空间之间传递 IO 请求和完成事件，避免系统调用的开销。

doom-lsp 确认 `io_uring/io_uring.c` 包含约 145+ 个核心函数。

---

## 1. 核心数据结构

### 1.1 struct io_ring_ctx

```c
struct io_ring_ctx {
    struct io_rings    *rings;        // 共享的 SQ/CQ 环
    unsigned int        sq_entries;   // 提交队列深度
    unsigned int        cq_entries;   // 完成队列深度

    struct io_submit_state submit_state; // 批量提交状态

    struct io_alloc_cache apoll_cache;   // 缓存分配

    struct list_head    defer_list;      // 延迟提交的请求
    struct list_head    timeout_list;    // 超时请求

    struct task_struct  *submitter_task; // 提交任务的线程
    ...
};
```

### 1.2 双环设计

```
用户空间                         内核空间
─────────                      ─────────
SQ（提交队列）：                   CQ（完成队列）：
  ┌────┬────┬────┬────┐          ┌────┬────┬────┬────┐
  │op 1│op 2│    │    │          │    │    │    │    │
  └────┴────┴────┴────┘          └────┴────┴────┴────┘
        │                              ▲
        │ io_uring_enter()              │
        ▼                              │
  内核处理 SQEs                  写完成事件到 CQ
        │                              │
        └──────── 完成 ────────────────┘
```

---

## 2. 操作流程

```
io_uring 提交 IO 的完整路径：

用户空间：
  1. mmap 共享 SQ/CQ 环
  2. 填充 SQE（提交队列条目）
  3. 调用 io_uring_enter（或使用 SQPOLL 模式自动轮询）

内核：
  io_uring_enter(fd, to_submit, min_complete, flags)
    │
    ├─ io_submit_sqes(ctx, to_submit)
    │    │
    │    ├─ 从 SQ 环中读取 up to 32 个 SQE
    │    │
    │    └─ 对每个 SQE：
    │         └─ io_init_req(ctx, req, sqe)     ← 初始化请求
    │              └─ 根据 opcode 分发：
    │                   ├─ io_read / io_write    ← 文件读写
    │                   ├─ io_openat             ← 文件打开
    │                   ├─ io_send / io_recv     ← 网络
    │                   ├─ io_poll_add           ← 事件轮询
    │                   └─ io_timeout            ← 超时
    │
    └─ io_cqring_wait(ctx, min_complete)         ← 等待完成
         │
         └─ 递交完成事件到 CQ 环
              └─ io_cqring_fill_event(req, res)  ← 写完成事件
```

---

## 3. 主要特性

| 特性 | 说明 |
|------|------|
| SQPOLL | 内核线程轮询提交队列，零系统调用 |
| Fixed File | 预注册 fd，避免每次下标转换 |
| Buffer Selection | 自动选择可用缓冲区 |
| Links | 请求链（顺序依赖执行）|
| IOPOLL | 轮询模式（NVMe 等低延迟设备）|

---

## 4. 源码文件索引

| 文件 | 关键符号 |
|------|---------|
| `io_uring/io_uring.c` | 核心实现 |
| `io_uring/opdef.c` | 操作码定义 |
| `include/linux/io_uring.h` | 公共 API |
| `include/uapi/linux/io_uring.h` | 用户空间接口定义 |

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
