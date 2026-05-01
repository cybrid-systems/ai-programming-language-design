# 25-hrtimer — 高精度定时器深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**hrtimer（High-Resolution Timer）** 提供纳秒级精度的定时器。与基于 jiffies 的传统定时器不同，hrtimer 使用红黑树组织，由硬件高精度事件定时器驱动。

---

## 1. 核心结构

```c
struct hrtimer {
    struct timerqueue_node  node;        // 红黑树节点
    ktime_t                 _softexpires;// 最早到期时间
    ktime_t                 expires;     // 最迟到时间
    enum hrtimer_restart   (*function)(struct hrtimer *); // 回调
    struct hrtimer_clock_base *base;     // 时钟基
};
```

---

## 2. 操作流程

```
hrtimer_start(timer, expires, mode)
  │
  ├─ 从红黑树移除旧定时器（如果存在）
  ├─ 插入 clock_base 的红黑树（O(log n)）
  └─ 如果是最早到期的定时器
       └─ hrtimer_reprogram() → 设置硬件定时器

到期处理（__hrtimer_run_queues）：
  ├─ 从红黑树取出所有到期的定时器
  ├─ 执行 timer->function(timer)
  ├─ 检查返回值：
  │    ├─ HRTIMER_RESTART → 重新插入
  │    └─ HRTIMER_NORESTART → 不做处理
  └─ 设置下一个到期时间
```

---

*分析工具：doom-lsp（clangd LSP）*
