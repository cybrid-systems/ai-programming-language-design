# ftrace — 内核函数跟踪深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/trace/ftrace.c` + `kernel/trace/trace.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**ftrace** 是 Linux 内核的**函数级追踪框架**，基于编译时插入的动态探针（NOP → callback）工作。

---

## 1. 核心概念

### 1.1 NOP → callback 替换

```c
// ftrace 工作原理：
// 1. 编译时：所有函数入口插入 NOP（无操作）
// 2. 启用时：NOP → CALL ftrace_handler（通过页表修改实现原子替换）
// 3. ftrace_handler 调用注册的 callback
// 4. 恢复执行
```

---

## 2. 核心数据结构

### 2.1 ftrace_ops — 追踪操作

```c
// include/linux/ftrace.h — ftrace_ops
struct ftrace_ops {
    // 函数链表
    struct ftrace_ops       *next;        // 下一个 ops

    // 回调函数
    void                    (*func)(unsigned long ip, unsigned long parent_ip,
                                    struct ftrace_ops *op, struct pt_regs *regs);

    // 过滤
    unsigned long           filter;       // 函数掩码（过滤哪些函数）
    unsigned long           notrace;      // 不追踪的函数掩码

    // 标志
    unsigned int            flags;        // FTRACE_OPS_* 标志
    struct ftrace_func_hash  func_hash;   // 函数哈希表
};
```

### 2.2 ftrace_page — 追踪页

```c
// kernel/trace/ftrace.c — ftrace_page
struct ftrace_page {
    struct ftrace_page      *next;        // 链表
    unsigned int            size;         // 记录数
    unsigned int            index;         // 当前索引
    struct dyn_ftrace       *records;     // dyn_ftrace 数组
};
```

### 2.3 dyn_ftrace — 动态函数描述

```c
// kernel/trace/ftrace.c — dyn_ftrace
struct dyn_ftrace {
    unsigned long           ip;           // 函数入口地址
    unsigned long           flags;        // FL_* 标志
    struct ftrace_page      *page;        // 所属页
    unsigned int            ref;          // 引用计数
    char                    name[128];    // 函数名（调试用）
};
```

---

## 3. 启用追踪

### 3.1 ftrace_startup — 启动

```c
// kernel/trace/ftrace.c — ftrace_startup
static int ftrace_startup(struct ftrace_ops *ops)
{
    // 1. 设置所有匹配函数的回调
    for (f = ftrace_pages; f; f = f->next) {
        for (i = 0; i < f->index; i++) {
            if (!match(f->records[i]))
                continue;

            // 2. NOP → CALL 替换（修改.text）
            modify_ftrace_call(f, ops, ftrace_call);
        }
    }

    // 3. 启用
    ops->func(current_ip, parent_ip, ops, regs);
    ops->flags |= FTRACE_OPS_ENABLED;
}
```

---

## 4. 事件追踪（tracepoint）

```c
// include/trace/events/*.h — TRACE_EVENT
#define TRACE_EVENT(name, proto, args, struct, print, ...) \
    struct trace_##name { ... } \
    static inline void trace_##name(proto) \
    { \
        if (trace_##name##_enabled()) \
            __trace_##name(args); \
    }

// 使用示例：
// TRACE_EVENT(sched_switch, ...)
// 在调度时调用 trace_sched_switch(...) → 写入 ring buffer
```

---

## 5. ftrace 文件系统

```
/sys/kernel/debug/tracing/
├── available_events      ← 可用事件
├── available_filter_functions ← 可追踪的函数
├── current_tracer        ← 当前追踪器（function / hwlat / ...）
├── function_profile_enabled ← 函数分析
├── set_ftrace_filter      ← 设置要追踪的函数（*boot* *schedule*）
├── set_ftrace_notrace     ← 设置不追踪的函数
├── trace                  ← 输出（cat trace 查看）
├── trace_options          ← 选项（sym-offset, raw)
└── tracing_on             ← 启用/停用（0/1）
```

---

## 6. function graph tracer

```c
// kernel/trace/ftrace.c — function_graph_enter
static void function_graph_enter(unsigned long ip, unsigned long parent_ip,
                                  struct ftrace_ops *op, struct pt_regs *regs)
{
    struct ftrace_graph_ent trace = {
        .func = ip,
        .depth = current->curr_ret_stack++,
    };

    // 记录入口
    push_return_trace(ip, parent_ip);

    // 调用回调（如果有 function_graph_cb）
    if (ops->tracing)
        ops->tracing(ops, &trace);
}

// 退出时：
static void ftrace_return_to_handler(unsigned long ip, unsigned long parent_ip)
{
    // 记录退出时间
    pop_return_trace();
}
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/trace/ftrace.c` | `ftrace_startup`、`ftrace_ops` |
| `kernel/trace/trace.c` | trace_open/close, trace_read |
| `include/linux/ftrace.h` | `struct ftrace_ops`、`struct dyn_ftrace` |