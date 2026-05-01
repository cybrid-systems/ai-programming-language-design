# 23-interrupt — 中断处理深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**中断** 是硬件通知 CPU 的核心机制。Linux 中断分两半：上半部（hardirq）做最少必要操作，下半部（softirq/threaded_irq）做更多处理。

---

## 1. 核心结构

```c
struct irq_desc {
    irq_flow_handler_t  handle_irq;     // 流处理函数
    struct irqaction    *action;        // 处理动作链表
};

struct irqaction {
    irq_handler_t   handler;            // 上半部处理函数
    irq_handler_t   thread_fn;          // 线程化下半部
    struct task_struct *thread;         // 中断线程
};
```

---

## 2. 处理流程

```
硬件中断 → CPU 保存上下文 → handle_irq(desc)
  │
  ├─ desc->handle_irq(desc)
  │    ├─ handle_edge_irq（边沿触发）
  │    │    └─ action->handler(irq, dev_id)  ← 上半部
  │    │         └─ 只做最少操作：ACK、读状态寄存器
  │    │
  │    └─ handle_level_irq（电平触发）
  │         └─ 屏蔽中断 → handler → 取消屏蔽
  │
  └─ 返回时：irq_exit()
       └─ __do_softirq()  ← 处理软中断
```

---

## 3. 流处理函数

| 类型 | 函数 | 说明 |
|------|------|------|
| 边沿 | handle_edge_irq | PCI 传统中断，自动屏蔽 |
| 电平 | handle_level_irq | SoC 中断，需屏蔽直到处理完 |
| 简单 | handle_simple_irq | 无需 ACK |
| Per-CPU | handle_percpu_irq | 每 CPU 独立中断 |

---

*分析工具：doom-lsp（clangd LSP）*
