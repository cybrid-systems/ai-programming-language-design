# Linux Kernel perf / PMU 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/events/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 perf？

**perf** 是 Linux 内置的**性能分析工具**，利用 PMU（Performance Monitoring Unit）硬件计数器追踪 CPU 事件：

```
perf stat -e cycles,instructions,cache-misses ./program
perf record -g ./program
perf report
```

---

## 1. perf_event

```c
// kernel/events/core.c — perf_event_open
// 用户空间：perf_event_open(perf_event_attr, pid, cpu, group_fd, flags)
long sys_perf_event_open(struct perf_event_attr *attr,
                pid_t pid, int cpu, int group_fd, unsigned long flags)
{
    // 1. 创建 perf_event
    struct perf_event *event = perf_event_alloc(attr, cpu, ...);

    // 2. 分配 PMU 硬件计数器
    hw_perf_event_init(event);

    // 3. 加入 per-CPU perf 链表
    if (cpu >= 0)
        list_add(&event->on_cpu, &per_cpu(active_pmu, cpu));
}
```

---

## 2. PMU 硬件

```
x86 PMU：
  - LBR（Last Branch Record）
  -固定计数器：cycles、instructions
  - 可编程计数器：cache-misses、branch-misses

ARM64 PMU (PMCCNTR)：
  - PMUCR_EL0 / PMUSERENR_EL0
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `kernel/events/core.c` | `sys_perf_event_open`、`perf_event_alloc` |
| `arch/x86/events/` | x86 PMU 驱动 |
| `arch/arm64/kernel/perf/` | ARM64 PMU 驱动 |
