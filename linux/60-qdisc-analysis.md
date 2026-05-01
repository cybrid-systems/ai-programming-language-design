# 60-qdisc — 流量控制队列规则深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**qdisc（Queueing Discipline）** 是 Linux 流量控制的核心，控制网络数据包在设备队列中的发送顺序和速率。pfifo_fast（默认）、HTB、TBF、RED 等都是 qdisc 的实现。

---

## 1. 核心路径

```
发送路径：
  dev_queue_xmit(skb)
    │
    └─ __dev_xmit_skb(skb, dev, txq)
         ├─ qdisc->enqueue(skb)           ← 入队
         └─ qdisc->dequeue()              ← 出队发送
              └─ 驱动发送（ndo_start_xmit）

qdisc 类型：
  ┌─────────────────────────────────────────┐
  │ pfifo_fast: 3 个优先级 Band，FIFO 出队   │
  │ HTB:       层次令牌桶（带宽控制）          │
  │ TBF:       令牌桶过滤器（速率限制）         │
  │ RED:       随机早期检测（避免拥塞）         │
  │ fq_codel:  公平排队 + CoDel              │
  └─────────────────────────────────────────┘
```

---

*分析工具：doom-lsp（clangd LSP）*
