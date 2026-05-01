# 47-RT Scheduler — 实时调度器深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**RT 调度器** 管理 SCHED_FIFO 和 SCHED_RR 实时进程。实时进程优先级（0-99，数字越小优先级越高）固定，不会被 CFS 进程抢占。

---

## 1. 调度策略

| 策略 | 行为 |
|------|------|
| SCHED_FIFO | 运行直到主动 yield 或被更高优先级抢占 |
| SCHED_RR | 同优先级进程时间片轮转（time slice = 100ms） |

---

## 2. 核心路径

```
选择下一个 RT 进程：
  pick_next_task_rt(rq, prev)
    └─ _pick_next_task_rt(rq)
         ├─ 从 rt_rq.active 位图查找最高优先级的非空队列
         │    └─ sched_find_first_bit(rt_rq->active)
         └─ 从该优先级队列取出第一个进程
              └─ dequeue_top_rt_rq(rq, rt_rq)
```

---

*分析工具：doom-lsp（clangd LSP）*
