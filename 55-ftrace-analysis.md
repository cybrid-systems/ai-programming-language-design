# Linux Kernel ftrace / tracepoints 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/trace/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 ftrace？

**ftrace** 是 Linux 内核的**函数级追踪框架**，通过 GCC 的 `-pg`（mcount）和动态改写 `NOP` 实现函数入口追踪。

---

## 1. tracepoints

```c
// include/trace/events/sched.h — trace_sched_switch
DECLARE_TRACE(sched_switch,
    TP_PROTO(struct task_struct *prev, struct task_struct *next),
    TP_ARGS(prev, next));

// 定义 tracepoint 在代码中的位置
// 不启用时：NOP（零开销）
// 启用时：调用 trace_sched_switch()
```

---

## 2. function_graph tracer

```c
// kernel/trace/ftrace.c — ftrace_graph_call
// 改写函数入口：
// - 启用：call graph_function
// - 禁用：NOP
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `kernel/trace/trace.c` | ftrace 核心 |
| `kernel/trace/trace_events.c` | tracepoints |
| `kernel/trace/fgraph.c` | function graph |
