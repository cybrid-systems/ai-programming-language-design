# 179-ftrace — 函数追踪深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/trace/ftrace.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**ftrace** 是 Linux 内核的官方追踪框架，提供函数追踪、事件追踪、函数图（function graph）等。

---

## 1. ftrace 架构

```
ftrace 层次：
  ┌─────────────────────┐
  │  DebugFS (/sys/kernel/tracing/)  │  用户接口
  ├─────────────────────┤
  │     Tracer (function/fgraph/...) │  追踪器
  ├─────────────────────┤
  │     Ftrace Hook (ftrace_ops)     │  函数钩子
  ├─────────────────────┤
  │     MCOUNT / NOP               │  编译器插桩
```

---

## 2. 函数追踪

```bash
# 启用函数追踪：
echo function > /sys/kernel/tracing/current_tracer

# 设置追踪的函数：
echo schedule > /sys/kernel/tracing/set_ftrace_filter

# 查看：
cat /sys/kernel/tracing/trace_pipe

# 关闭：
echo nop > /sys/kernel/tracing/current_tracer
```

---

## 3. ftrace_ops

```c
// kernel/trace/ftrace.c — ftrace_ops
struct ftrace_ops {
    ftrace_func_t    func;              // 回调函数
    unsigned long    flags;              // FTRACE_OPS_*
    void            *private;            // 私有数据

    // 过滤
    struct ftrace_hash  *filtered;
    struct ftrace_hash  *notrace;
};
```

---

## 4. 函数图（Function Graph）

```bash
# 启用函数图追踪：
echo function_graph > /sys/kernel/tracing/current_tracer

# 输出示例：
#  1)    0.123 us |  schedule() {
#  2)    0.089 us |    update_rq_clock();
#  2)    0.456 us |  }
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/trace/ftrace.c` | `ftrace_trace_function`、`register_ftrace_function` |
| `kernel/trace/trace_functions.c` | `function_tracer_init` |

---

## 6. 西游记类喻

**ftrace** 就像"天庭的千里眼"——

> ftrace 像玉帝的千里眼，能实时看到每个神仙（函数）什么时候开始做事、什么时候做完。function tracer 记录每个函数的起止时间，function_graph tracer 则记录函数之间的调用关系，像一棵调用树。这对于分析性能问题特别有用——哪个函数调用链最耗时，一目了然。

---

## 7. 关联文章

- **eBPF**（article 177）：ftrace 可作为 eBPF 的后端
- **perf**（article 178）：perf 用于硬件事件采样