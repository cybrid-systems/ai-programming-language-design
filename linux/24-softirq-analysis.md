# 24-softirq — 软中断深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**softirq（软中断）** 是中断下半部的核心机制。与 hardirq 不同，softirq 在开中断下运行，但仍处于原子上下文（不能睡眠）。

预定义类型：HI(0)、TIMER(1)、NET_TX(2)、NET_RX(3)、BLOCK(4)、IRQ_POLL(5)、TASKLET(6)。

---

## 1. 触发与执行

```
raise_softirq(nr)           ← 触发
  └─ 设置 __softirq_pending 对应位

do_softirq() 在以下时机执行：
  ├─ irq_exit()（上半部返回时）
  ├─ local_bh_enable()
  └─ ksoftirqd 内核线程

__do_softirq() 执行：
  ├─ 保存 pending 位图，清零
  ├─ for_each_set_bit(pending_bit)
  │    └─ softirq_vec[bit].action()
  ├─ 如果又触发了 pending
  │    └─ 重试 < MAX_SOFTIRQ_RESTART 次
  └─ 否则 → 唤醒 ksoftirqd
```

---

## 2. tasklet

tasklet 基于 TASKLET_SOFTIRQ（索引 6）：

```c
DECLARE_TASKLET(name, function, data);
tasklet_schedule(&t);       // 调度
tasklet_hi_schedule(&t);    // 高优先级
tasklet_kill(&t);           // 确保停止
```

---

*分析工具：doom-lsp（clangd LSP）*
