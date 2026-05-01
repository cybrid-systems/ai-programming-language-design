# 21-blk-mq — 多队列块层深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**blk-mq（Block Multi-Queue）** 是 Linux 块设备层大重构。传统单队列 request_queue 在高 IOPS 下成为瓶颈——所有 CPU 竞争同一锁。blk-mq 为每 CPU 分配独立软件队列，实现近乎无锁的 IO 提交。

---

## 1. 架构

```
                submit_bio(bio)
                     │
              ┌──────┴──────┐
              │  current CPU │  ← Per-CPU blk_mq_ctx
              │  软件队列     │
              └──────┬──────┘
                     │
              ┌──────┴──────┐
              │ blk_mq_ctx  │  ← 映射到硬件队列
              │ → hctx[type]│
              └──────┬──────┘
                     │
              ┌──────┴──────┐
              │ 硬件队列     │  ← NVMe 等真实硬件队列
              │ blk_mq_hw_ctx│
              └──────┬──────┘
                     │
              ┌──────┴──────┐
              │ 驱动处理      │
              │ queue_rq()   │
              └─────────────┘
```

---

## 2. 数据流

```
submit_bio(bio)
  │
  └─ blk_mq_submit_bio(bio)
       ├─ blk_mq_get_ctx(q)              ← 当前 CPU 的软件队列
       ├─ blk_mq_map_queue(q, ...)        ← ctx → hctx 映射
       ├─ blk_mq_get_request(q, bio, ctx) ← 分配 request（tags 池）
       ├─ blk_mq_bio_to_request(rq, bio)  ← bio 转 request
       │
       ├─ [快速路径] blk_mq_try_issue_directly(hctx, rq)
       │    └─ hctx->ops->queue_rq()     ← 直接发送给驱动
       │
       └─ [排队路径] blk_mq_add_to_requeue_list(rq)
            └─ 稍后批量发送

完成路径（硬件中断）：
  hctx->ops->complete(rq)
    └─ blk_mq_complete_request(rq)
         └─ blk_mq_end_request(rq, error)
              └─ bio_endio(bio)
```

---

## 3. 设计决策

| 决策 | 原因 |
|------|------|
| Per-CPU 软件队列 | 避免锁竞争 |
| tags 池预分配 | 运行中不动态分配 |
| 直接提交优化 | 低延迟场景 |

---

*分析工具：doom-lsp（clangd LSP）*
