# 178-perf — 性能事件分析深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/events/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**perf** 是 Linux 的性能分析工具，基于硬件 PMU（Performance Monitoring Unit），支持硬件/软件性能事件采样、热点函数分析、缓存分析。

---

## 1. perf_event_open 系统调用

```c
// perf_event_open — 创建性能监控事件
// SYSCALL_DEFINE5(perf_event_open, ...)
struct perf_event_attr {
    __u32 type;                // PERF_TYPE_*
    __u64 config;             // 事件配置
    __u64 sample_period;       // 采样周期
    __u64 sample_type;        // 采样类型
    int  pid;                  // 监控进程
    int  cpu;                 // 监控 CPU
};

// 类型：
//   PERF_TYPE_HARDWARE  — 硬件事件（CPU 周期、指令等）
//   PERF_TYPE_SOFTWARE — 软件事件（上下文切换、页面错误等）
//   PERF_TYPE_TRACEPOINT — tracepoint
//   PERF_TYPE_HW_CACHE — 硬件缓存事件
```

---

## 2. 硬件事件

```bash
# perf list 查看可用事件：
perf list

# 常用硬件事件：
#   cycles        — CPU 周期
#   instructions — 指令数
#   cache-references — 缓存引用
#   cache-misses  — 缓存未命中
#   branches     — 分支
#   branch-misses — 分支预测失败

# 使用：
perf stat -e cycles,instructions,cache-misses ls
perf record -g -e cycles ./myprogram
perf report
```

---

## 3. perf record

```c
// perf record 使用：
// 1. mmap() 创建采样缓冲区
// 2. 每次事件触发，perf 采样程序计数器（IP）
// 3. 保存到 ring buffer
// 4. 数据写入 perf.data

// -g 选项启用栈回溯（DWARF unwind）
// -a 全系统
// -C cpu 指定 CPU
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/events/core.c` | `perf_event_open`、`perf_read` |
| `kernel/perf_event.c` | 事件监控核心 |

---

## 5. 西游记类喻

**perf** 就像"天庭的计时官"——

> perf 像天庭的计时官（PMU），记录每个神仙（CPU）在每个时刻在做什么。cycles 记录走了多少步（时钟周期），instructions 记录念了多少咒（执行的指令），cache-misses 记录念咒时忘词的次数（缓存未命中）。perf stat 就像看整个天庭的统计数据，perf record 像在每个关键步骤做笔记，perf report 像看完笔记后画出一个热力图，告诉玉帝哪些环节最耗时。

---

## 6. 关联文章

- **ftrace**（相关）：ftrace 更多用于内核追踪
- **eBPF**（article 177）：perf 与 BPF 结合