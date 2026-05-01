# 54-perf — 性能事件子系统深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**perf** 子系统提供硬件性能计数器（PMU）和软件性能事件的采样/计数功能，是 Linux 性能分析的基石。perf_event 支持 CPU 周期、指令数、缓存命中/未命中、分支预测失败等多种硬件事件。

---

## 1. 核心路径

```
perf_event_open(attr, pid, cpu, group_fd, flags)
  │
  └─ sys_perf_event_open(attr, pid, cpu, group_fd, flags)
       ├─ perf_event_alloc(attr, cpu, task, ...)
       ├─ 选择 PMU（perf_init_event）
       └─ 将事件添加到 Per-CPU 或 Per-task 链表

采样（硬件中断触发）：
  ┌─────────────────────────────────────┐
  │ PMU 溢出 → perf_event_overflow()    │
  │   → __perf_event_output()           │
  │     → ring_buffer_put()             │
  │     → 写入 Perf ring buffer         │
  │     → wake_up()                     │
  └─────────────────────────────────────┘

用户空间读取：
  read(perf_fd, buf, count) → 读取样本
  mmap(perf_fd, ...) → 共享 ring buffer（零拷贝）
```

---

*分析工具：doom-lsp（clangd LSP）*
