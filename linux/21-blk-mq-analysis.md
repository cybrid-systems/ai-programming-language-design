# 21-blk-mq — 多队列块层深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**blk-mq（Block Multi-Queue）** 是 Linux 块设备层在多核时代的大重构。传统单队列（request_queue）在高 IOPS 场景下成为瓶颈——所有 CPU 竞争同一个锁。blk-mq 为每个 CPU/硬件队列分配独立的提交队列，实现无锁或近乎无锁的 IO 提交。

doom-lsp 确认 `block/blk-mq.c` 包含约 734+ 个符号，`include/linux/blk-mq.h` 定义了核心接口。

---

## 1. 核心数据结构

### 1.1 blk_mq_hw_ctx（硬件队列）

```c
struct blk_mq_hw_ctx {
    struct blk_mq_ctxs      *ctxs;       // 关联的软件队列
    struct request_queue    *queue;      // 所属的 request_queue
    struct blk_mq_tags      *tags;       // 请求标签池
    struct list_head         hctx_list;  // 链表节点
    unsigned int             queue_num;  // 队列编号
    void                    *driver_data;// 驱动私有数据
    ...
};
```

### 1.2 blk_mq_ctx（软件队列——Per-CPU）

```c
struct blk_mq_ctx {
    struct list_head         rq_list;       // 待处理请求链表
    unsigned int             cpu;           // 绑定的 CPU
    struct blk_mq_hw_ctx    *hctxs[HCTX_MAX_TYPES]; // 映射到的硬件队列
    ...
};
```

---

## 2. 数据流：IO 提交到完成

```
submit_bio(bio)                         ← 通用块层入口
  │
  ├─ blk_mq_submit_bio(bio)
  │    │
  │    ├─ 选择软件队列
  │    │    └─ blk_mq_get_ctx(q)         ← 当前 CPU 的 blk_mq_ctx
  │    │
  │    ├─ 选择硬件队列
  │    │    └─ blk_mq_map_queue(q, ...)  ← ctx → hctx 映射
  │    │
  │    ├─ 分配 request（从 tags 池取）
  │    │    └─ blk_mq_get_request(q, bio, ctx)
  │    │
  │    ├─ 填充 request（bio 转 request）
  │    │    └─ blk_mq_bio_to_request(rq, bio)
  │    │
  │    ├─ [快速路径] 直接插入硬件队列
  │    │    └─ blk_mq_try_issue_directly(hctx, rq)
  │    │         └─ hctx->ops->queue_rq(hctx, &bd)  ← 驱动发送命令
  │    │
  │    └─ [排队路径] 加入软件队列，稍后批量发送
  │         └─ blk_mq_add_to_requeue_list(rq, ...)
  │              └─ 触发 IPI（处理器间中断）或等待轮询
  │
IO 完成（硬件中断）：
  └─ hctx->ops->complete(rq)            ← 驱动回调
       └─ blk_mq_complete_request(rq)
            └─ blk_mq_end_request(rq, error)
                 └─ bio_endio(bio)       ← 通知上层

```

---

## 3. 设计决策总结

| 决策 | 原因 |
|------|------|
| Per-CPU 软件队列 | 避免锁竞争 |
| 队列映射（ctx→hctx）| CPU 亲和性，减少 cache miss |
| tags 池预分配 | 避免运行中动态分配 |
| 直接提交优化 | 减少队列深度，降低延迟 |

---

## 4. 源码文件索引

| 文件 | 关键符号 |
|------|---------|
| `include/linux/blk-mq.h` | blk-mq 接口定义 |
| `block/blk-mq.c` | `blk_mq_submit_bio` |
| `block/blk-core.c` | `submit_bio` 入口 |

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
