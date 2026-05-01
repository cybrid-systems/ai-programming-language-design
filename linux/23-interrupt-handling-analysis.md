# 23-interrupt — 中断处理深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**中断** 是硬件通知 CPU 事件的核心机制。Linux 中断处理分为两半：
- **上半部（hardirq）**：在中断上下文中运行，必须极快，只做最必要的操作
- **下半部（softirq/tasklet/workqueue）**：稍后运行，可以做更多工作

doom-lsp 确认 `kernel/irq/` 目录包含 irqdesc/manage/chip 等多个子模块。

---

## 1. 核心数据结构

### 1.1 struct irq_desc

```c
struct irq_desc {
    struct irq_common_data  irq_common_data;
    struct irq_data         irq_data;
    unsigned int __percpu   *kstat_irqs;   // 中断统计
    irq_flow_handler_t      handle_irq;    // 中断流处理函数
    struct irqaction        *action;       // 中断处理动作链表
    unsigned int            status_use_accessors;
    ...
};
```

### 1.2 struct irqaction

```c
struct irqaction {
    irq_handler_t           handler;       // 上半部处理函数
    unsigned long           flags;         // IRQF_* 标志
    const char             *name;          // 中断名
    void                   *dev_id;        // 设备 ID
    struct irqaction       *next;          // 共享中断的链表
    irq_handler_t           thread_fn;     // 线程化下半部
    struct task_struct     *thread;        // 中断线程
    ...
};
```

---

## 2. 中断处理流程

```
硬件中断触发
  │
  ├─ CPU 硬件自动处理：
  │    ├─ 保存上下文（CS:RIP, RFLAGS）
  │    ├─ 禁用本地中断
  │    └─ 跳转到 IDT 表项 → common_interrupt
  │
  ├─ 内核入口：
  │    └─ handle_irq(desc, regs)
  │         └─ desc->handle_irq(desc)     ← 流处理函数
  │              │
  │              └─ handle_edge_irq / handle_level_irq
  │                   │
  │                   ├─ 调用 action->handler(irq, dev_id) ← 上半部
  │                   │    └─ 只能做最少操作（ACK/read HW regs）
  │                   │
  │                   ├─ 如果注册了 thread_fn：
  │                   │    └─ wake_up_process(desc->action->thread)
  │                   │         └─ 中断线程在进程上下文执行下半部
  │                   │              └─ thread_fn(irq, dev_id)
  │                   │
  │                   └─ 检查是否需要 EOI
```

---

## 3. 流处理函数

| 类型 | 函数 | 适用 |
|------|------|------|
| 边沿触发 | `handle_edge_irq` | PCI 传统中断 |
| 电平触发 | `handle_level_irq` | 某些 SoC 中断 |
| 简单 | `handle_simple_irq` | 不需要 ACK 的中断 |
| Per-CPU | `handle_percpu_irq` | 每个 CPU 独立中断 |

---

## 4. 源码文件索引

| 文件 | 关键符号 |
|------|---------|
| `kernel/irq/irqdesc.c` | 中断描述符管理 |
| `kernel/irq/manage.c` | request_irq / request_threaded_irq |
| `kernel/irq/chip.c` | 中断控制器操作 |

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
