# 24-softirq — 软中断深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**softirq（软中断）** 是 Linux 中断下半部的实现机制之一，也是 tasklet 和 timer 的底层基础。与 hardirq 不同，softirq 在开中断的环境下运行，但仍然在原子上下文中（不能睡眠）。

内核中预定义了几种 softirq：

| 索引 | softirq | 用途 |
|------|---------|------|
| 0 | HI_SOFTIRQ | tasklet 高优先级 |
| 1 | TIMER_SOFTIRQ | 定时器 |
| 2 | NET_TX_SOFTIRQ | 网络发送 |
| 3 | NET_RX_SOFTIRQ | 网络接收 |
| 4 | BLOCK_SOFTIRQ | 块设备完成 |
| 5 | IRQ_POLL_SOFTIRQ | 中断轮询 |
| 6 | TASKLET_SOFTIRQ | tasklet |
| ... | | |

---

## 1. 核心数据结构

```c
// kernel/softirq.c
static struct softirq_action softirq_vec[NR_SOFTIRQS] __cacheline_aligned;

struct softirq_action {
    void (*action)(struct softirq_action *);  // 处理函数
};
```

每个 softirq 类型对应一个全局函数指针。

---

## 2. 触发与执行

### 2.1 触发：raise_softirq

```c
void raise_softirq(unsigned int nr)
{
    unsigned long flags;
    local_irq_save(flags);
    raise_softirq_irqoff(nr);      // 设置本 CPU 的 pending 位
    local_irq_restore(flags);
}
```

设置 `__softirq_pending` 的对应位，标记该 softirq 待处理。

### 2.2 执行：do_softirq

```
do_softirq() 在以下时机被调用：
  ├─ 中断上半部结束时（irq_exit）
  ├─ local_bh_enable() 时
  ├─ ksoftirqd 内核线程
  └─ __do_softirq()

__do_softirq() 执行流程：
  │
  ├─ 保存当前 pending 位图，清零
  ├─ 恢复中断（允许抢占）
  │
  ├─ 循环处理：
  │    └─ 遍历 pending 位，调用 softirq_vec[n].action()
  │         └─ 网络：net_rx_action / net_tx_action
  │         └─ 块设备：blk_done_softirq
  │         └─ 定时器：run_timer_softirq
  │
  ├─ 退出前检查是否有新的 pending
  │    └─ 如果有且重试次数 < MAX_SOFTIRQ_RESTART → 继续
  │    └─ 否则 → 唤醒 ksoftirqd
  │
  └─ 关闭中断，退出
```

---

## 3. tasklet——softirq 之上的便利封装

tasklet 基于 `TASKLET_SOFTIRQ`：

```c
void tasklet_action(struct softirq_action *a)
{
    // 遍历 tasklet_vec 链表
    // 执行 tasklet->func(data)
}
```

使用方式：
```c
DECLARE_TASKLET(my_tasklet, my_fn, data);
tasklet_schedule(&my_tasklet);   // 调度执行
tasklet_kill(&my_tasklet);       // 确保不再运行
```

---

## 4. 源码文件索引

| 文件 | 关键符号 |
|------|---------|
| `kernel/softirq.c` | `do_softirq` / `raise_softirq` |
| `include/linux/interrupt.h` | softirq 定义 |

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
