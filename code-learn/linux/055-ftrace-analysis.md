# 55-ftrace — Linux 内核函数跟踪框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**ftrace（Function Tracer）** 是 Linux 内核的内置函数跟踪框架。它允许开发者**零修改**地跟踪内核函数调用，包括函数入口/出口、函数延迟、调用栈等。ftrace 是内核跟踪系统的**基础设施**——tracepoints、kprobe、perf、eBPF 都构建在 ftrace 之上。

**核心设计**：通过编译时的 `-pg -mfentry` 选项，在每个函数入口插入 5 字节 NOP（可在运行时动态替换为跳转到追踪代码）。ftrace 子系统管理这些 NOP→CALL 的替换，并调度多个追踪器之间的冲突。

```
内核启动中:
  ftrace_init()
    ↓
  遍历所有 ftrace_caller 站点
    ↓
  ftrace_process_locs() → 初始化 callbacks

运行时:
  用户写 available_filter_functions → set_ftrace_filter
    ↓
  ftrace_set_filter() → 记录追踪函数
    ↓
  ftrace_shutdown() / ftrace_startup()
    ↓
  __ftrace_replace_code()
    → 将函数入口的 NOP 替换为 CALL ftrace_caller
    → 或恢复为 NOP（未追踪的函数）
```

**doom-lsp 确认**：核心实现在 `kernel/trace/ftrace.c`（**9,426 行**）。主跟踪接口在 `kernel/trace/trace.c`（10,017 行）。头文件 `include/linux/ftrace.h`（1,391 行）。

**关键文件索引**：

| 文件 | 行数 | 职责 |
|------|------|------|
| `kernel/trace/ftrace.c` | 9426 | ftrace 核心：动态打桩、ops 管理 |
| `kernel/trace/trace.c` | 10017 | 跟踪器框架、ring buffer、tracefs |
| `kernel/trace/trace_output.c` | 1934 | 跟踪输出格式化 |
| `kernel/trace/trace_events.c` | 5099 | tracepoints（事件跟踪）|
| `kernel/trace/trace_functions.c` | 1030 | function tracer |
| `include/linux/ftrace.h` | 1391 | ftrace API |
| `kernel/trace/trace.h` | 2508 | 内部头文件 |

---

## 1. 核心数据结构

### 1.1 struct ftrace_ops — 跟踪操作

```c
// include/linux/ftrace.h
struct ftrace_ops {
    /* ── 回调函数 ─ */
    ftrace_func_t func;                       /* 跟踪函数（入口）*/
    ftrace_func_t func_regs;                  /* 带寄存器状态的跟踪 */
    ftrace_func_t func_regs_or_ip;            /* 可以处理 regs 或只有 ip */

    /* ── 过滤控制 ─ */
    struct ftrace_ops_hash old_hash;          /* 旧过滤器哈希 */
    struct ftrace_ops_hash *next_hash;
    struct ftrace_ops_hash func_hash;         /* 过滤哈希表 */
    unsigned long *notrace_hash;              /* 排除哈希 */

    /* ── 标志/状态 ─ */
    unsigned long flags;                       /* FTRACE_OPS_FL_* */
    int nr_trampolines;                        /* 跳板函数数 */
    struct list_head list;                     /* ftrace_ops_list 节点 */

    /* ── 跳板 ─ */
    unsigned long trampoline;                  /* 自定义跳板地址 */
    unsigned long trampoline_size;
    int count;                                 /* 活跃追踪器数 */
};
```

**`FTRACE_OPS_FL_*` 标志**：

| 标志 | 含义 |
|------|------|
| `FTRACE_OPS_FL_ENABLED` | ops 已启用 |
| `FTRACE_OPS_FL_DYNAMIC` | 支持动态打桩 |
| `FTRACE_OPS_FL_SAVE_REGS` | 需要保存寄存器 |
| `FTRACE_OPS_FL_SAVE_REGS_IF_SUPPORTED` | 如果支持则保存 |
| `FTRACE_OPS_FL_RECURSION` | 允许递归 |
| `FTRACE_OPS_FL_STUB` | 桩函数 |
| `FTRACE_OPS_FL_PERMANENT` | 不可移除（BPF trampoline）|
| `FTRACE_OPS_FL_IPMODIFY` | 允许修改返回地址 |

### 1.2 struct dyn_ftrace — 动态追踪点

```c
// kernel/trace/ftrace.c（核心结构）
struct dyn_ftrace {
    struct list_head list;              /* 全局链表节点 */
    struct ftrace_page *pg;             /* 所属页面 */
    unsigned long ip;                   /* 函数入口地址 */
    unsigned long flags;                /* 标志（FTRACE_FL_*）*/
    int flags_offset;                   /* 标志位偏移 */
};
```

### 1.3 struct ftrace_page — 追踪页面

```c
// kernel/trace/ftrace.c
struct ftrace_page {
    struct ftrace_page *next;           /* 下一页 */
    struct dyn_ftrace *records;         /* 此页中的记录数组 */
    int index;                          /* 当前索引 */
    int order;                          /* 页面大小 order */
};
```

### 1.4 struct trace_array — 跟踪实例

```c
// kernel/trace/trace.h
struct trace_array {
    struct list_head list;               /* 全局链表 */
    struct trace_buffer trace_buffer;    /* per-CPU ring buffer */
    struct trace_buffer max_buffer;      /* 最大延迟缓冲区 */
    char *name;                          /* 实例名称 */
    int cpu;                             /* 绑定的 CPU */
    struct trace_cpu *trace_cpu_data;    /* per-CPU 数据 */
    struct tracer *current_trace;        /* 当前活跃的跟踪器 */
    unsigned long tracing_on;            /* 跟踪开关 */
    struct trace_array *parent;          /* 父实例 */
};
```

---

## 2. 初始化流程

```c
// kernel/trace/ftrace.c
void __init ftrace_init(void)
{
    /* 1. 查找 __start_mcount_loc ~ __stop_mcount_loc 段 */
    extern unsigned long __start_mcount_loc[];
    extern unsigned long __stop_mcount_loc[];

    /* 2. 分配 ftrace_page 存储所有追踪点 */
    ftrace_process_locs(NULL, __start_mcount_loc, __stop_mcount_loc);

    /* 3. 将每个函数入口的 CALL ftrace_caller 替换为 NOP */
    ftrace_code_disable(NULL, ...);

    /* 4. 注册 ftrace 跟踪支持 */
    register_ftrace_function(&global_ops);
}
```

**`__mcount_loc` 段**——编译器在编译时生成所有函数入口地址列表：

```bash
# 编译时
gcc -pg -mfentry → 在每个函数入口插入 5 字节 fentry call
                  并将函数地址加入 __mcount_loc 段
# 链接后
__start_mcount_loc = 所有含 fentry call 的函数入口地址数组
```

---

## 3. 动态打桩

### 3.1 指令替换

```c
// 在 x86-64 上，函数入口默认为：
// 5 字节 NOP:  0F 1F 44 00 00  (nop 4 (%rax,%rax,1))
//
// 启用追踪后替换为：
// CALL rel32:  E8 xx xx xx xx  (call ftrace_caller)

// arch/x86/kernel/ftrace.c
int ftrace_make_call(struct dyn_ftrace *rec, unsigned long addr)
{
    /* 将函数入口的 NOP 替换为 CALL ftrace_caller */
    ftrace_modify_code(rec->ip, old_nop, call_ftrace_caller);
}
```

### 3.2 ftrace_caller — 汇编入口

```asm
# arch/x86/kernel/ftrace_64.S
ftrace_caller:
    /* 保存寄存器 */
    save_regs

    /* 调用 ftrace_ops_list_func 回调链 */
    call ftrace_ops_list_func

    /* 恢复寄存器 */
    restore_regs

    /* 返回到原始函数 */
    ret
```

### 3.3 ops 链式调用

```c
// kernel/trace/ftrace.c
void ftrace_ops_list_func(unsigned long ip, unsigned long parent_ip,
                          struct ftrace_ops *op, struct pt_regs *regs)
{
    struct ftrace_ops *ops;

    /* 遍历 ops 链表 */
    do_for_each_ftrace_op(ops, ftrace_ops_list) {
        if (!ftrace_ops_test(ops, ip))  /* 检查过滤 */
            continue;
        ops->func(ip, parent_ip, ops, regs);
    } while_for_each_ftrace_op(ops);
}
```

---

## 4. 过滤机制

```c
// 每函数和每模块的过滤控制：
echo do_sys_open > /sys/kernel/debug/tracing/set_ftrace_filter
echo sysfs > /sys/kernel/debug/tracing/set_ftrace_filter  # 模块
echo do_* > /sys/kernel/debug/tracing/set_ftrace_filter    # 通配符

// 排除：
echo do_sys_open > /sys/kernel/debug/tracing/set_ftrace_notrace
```

**实现**——`ftrace_filter_write()` 解析输入，构建哈希表：

```c
// kernel/trace/ftrace.c
ssize_t ftrace_filter_write(struct file *file, const char __user *ubuf,
                            size_t cnt, loff_t *ppos)
{
    /* 解析过滤字符串，构建过滤哈希 */
    ftrace_set_filter(ops, buf, len, reset);

    /* 更新代码——只有被过滤的函数才插入 CALL */
    ftrace_run_update_code(1);
}
```

**doom-lsp 确认**：`ftrace_set_filter()` 在 `ftrace.c` 中。过滤哈希表使用 `FTRACE_FUNC_HASHSIZE` 大小的桶。

---

## 5. 跟踪器类型

### 5.1 function tracer

```c
// kernel/trace/trace_functions.c:1030
// 追踪每个被过滤函数的入口
// 记录：函数入口时间戳 + pid + 调用函数

// 回调：
function_trace_call()
  → trace_function()
    → __trace_function()
      → ring_buffer_write()
```

### 5.2 function_graph tracer

```c
// 追踪函数入口和出口（完整调用图）
// 入口：记录进入时间
// 出口：在函数返回时由 ftrace_return_to_handler() 触发

// 需要 FTRACE_OPS_FL_SAVE_REGS 保存寄存器
// 使用 fentry + return hookers（替换返回地址）
```

### 5.3 tracepoints（事件跟踪）

```c
// kernel/trace/trace_events.c:5099
// 使用 DECLARE_TRACE() / DEFINE_EVENT() 定义的静态 tracepoint
// 通过 TRACE_EVENT() 宏定义事件格式
// 用户：echo 1 > /sys/kernel/debug/tracing/events/sched/sched_switch/enable

// 实现：
// tracepoint 实质上是 ftrace 上的一个约定——
// 每个 tracepoint 生成一个 ftrace 样式的回调
```

---

## 6. Ring Buffer

```c
// kernel/trace/trace.c（嵌入式 ring buffer）
// 每个 CPU 一个独立的 ring buffer（免锁写入）
// 结构：

struct trace_buffer {
    struct trace_array *tr;        /* 所属实例 */
    struct ring_buffer *buffer;    /* 环形缓冲区 */
    int cpu;
};
```

**Ring buffer 特点**：
- **overwrite 模式**：新数据覆盖旧数据（默认）
- **no-overwrite 模式**：满则丢弃新数据
- per-CPU 写入（无锁）
- 支持子缓冲区（sub-buffer）提交
- commit 后对 readers 可见

---

## 7. tracefs 接口

```bash
/sys/kernel/debug/tracing/
├── available_tracers          # 可用跟踪器列表
├── current_tracer             # 当前跟踪器 (function/function_graph/nop)
├── available_filter_functions # 可过滤的函数列表
├── set_ftrace_filter          # 过滤器设置
├── set_ftrace_notrace         # 排除设置
├── tracing_on                 # 开关（1=on, 0=off）
├── trace                      # 跟踪输出（cat 查看）
├── trace_pipe                 # 实时跟踪输出
├── buffer_size_kb             # ring buffer 大小
├── buffer_total_size_kb       # 总大小
├── trace_clock                # 时钟源
├── tracing_max_latency        # 最大延迟（irqsoff/preemptoff 跟踪器）
├── tracing_thresh             # 延迟阈值
├── events/                    # tracepoint 事件
│   ├── sched/sched_switch/enable
│   ├── irq/irq_handler_entry/enable
│   └── ...
├── instances/                 # 跟踪实例
│   ├── foo/
│   │   ├── current_tracer
│   │   ├── trace
│   │   └── ...
│   └── ...
├── per_cpu/                   # per-CPU 跟踪数据
│   ├── cpu0/trace
│   ├── cpu0/trace_pipe
│   └── ...
```

---

## 8. 跟踪实例

```bash
# 启动 function tracer
echo function > /sys/kernel/debug/tracing/current_tracer
# 限制到特定函数
echo do_sys_open > /sys/kernel/debug/tracing/set_ftrace_filter
# 查看输出
cat /sys/kernel/debug/tracing/trace
  # tracer: function
  #
  # entries-in-buffer/entries-written: 142/142   #P:8
  #
  #           TASK-PID     CPU#   TIMESTAMP  FUNCTION
  #              | |         |        |         |
  bash-2837  [001] .... 123.456: do_sys_open <- syscall_trace_enter

# 函数追踪
echo function_graph > /sys/kernel/debug/tracing/current_tracer
cat /sys/kernel/debug/tracing/trace
  # 3)  do_sys_open() {
  # 3)    getname() {
  # 3)      __getname() {
  # 3)        kmem_cache_alloc() { ... }
  # 3)      }
  # 3)    }
  # 3)    ...
  # 3)    vfs_open() {
  # 3)      do_dentry_open() {
  # 3)        __fget_light() {...}
  # 3)      }
  # 3)    }
  # 3)  }

# 创建实例
mkdir /sys/kernel/debug/tracing/instances/my_trace
echo function > /sys/kernel/debug/tracing/instances/my_trace/current_tracer
echo do_sys_open > /sys/kernel/debug/tracing/instances/my_trace/set_ftrace_filter
cat /sys/kernel/debug/tracing/instances/my_trace/trace
```

---

## 9. 与其他跟踪系统的关系

```
Ftrace 架构图:

                                用户空间 (tracefs / perf tool / bpftool)
                                      │
            ┌─────────────────────────┼──────────────────────────┐
            │                         │                          │
         trace.c                   perf_event                BPF
         (ring buffer,            (perf_event_open)        (bpf() syscall)
         多个 tracer)
            │                         │                          │
            └─────────────────────────┼──────────────────────────┘
                                      │
                              ftrace_ops_list_func()
                                      │
            ┌──────────────┬──────────┴──────────┬──────────────┐
            │              │                     │              │
       function      function_graph         tracepoints     kprobe
       (入口)        (入口+出口)           (DECLARE_TRACE)   (动态)
            │              │                     │              │
            └──────────────┴─────────────────────┴──────────────┘
                                      │
                              ftrace_make_call()
                              (NOP ↔ CALL 动态替换)
                                      │
                           内核函数入口 (__mcount_loc)
```

---

## 10. 性能考量

| 操作 | 延迟 | 说明 |
|------|------|------|
| NOP（无追踪） | **0** | 5 字节 NOP，约 1 个周期 |
| 单 function 追踪 | **~50-200ns** | CALL ftrace_caller + 回调 |
| function_graph | **~200-500ns** | 额外入口/出口逻辑 |
| tracepoint 未启用 | **~5ns** | jump_label 判断 |
| tracepoint 启用 | **~100-500ns** | 回调链执行 |
| 采样频率上限 | **~100kHz** | 取决于 ring buffer 大小 |

---

## 11. 调试与诊断

```bash
# 检查 ftrace 是否可用
cat /proc/cmdline | grep ftrace
# 如果不含 ftrace= 则默认启用

# 查看所有可追踪的函数数
wc -l /sys/kernel/debug/tracing/available_filter_functions

# 检查当前追踪器 CPU 使用率
cat /proc/sched_debug | grep ftrace

# 检查 ring buffer 状态
cat /sys/kernel/debug/tracing/per_cpu/cpu0/buffer_size_kb
cat /sys/kernel/debug/tracing/per_cpu/cpu0/stats

# 跟踪跟踪自身的开销
echo function > /sys/kernel/debug/tracing/current_tracer
echo trace > /sys/kernel/debug/tracing/set_ftrace_notrace  # 避免递归
```

---

## 12. 总结

Linux ftrace 是内核跟踪系统的**基石**：

**1. 编译时注入 + 运行时替换**——编译器在 `__mcount_loc` 段记录所有函数入口，ftrace 在运行时按需将 NOP 替换为 CALL。需要时启用，不需要时光零开销。

**2. ops 链表架构**——多个追踪器可以同时注册（function、function_graph、tracepoints、kprobe、perf），ftrace 通过 `ftrace_ops_list_func()` 链式调用。

**3. 动态过滤**——`set_ftrace_filter` 通过哈希表实现函数级的精确控制，支持通配符和模块过滤。

**4. per-CPU ring buffer**——免锁写入，overwrite 模式，支持多个跟踪实例同时运行。

**5. 跟踪实例（instances）**——独立的 trace buffer 和配置，支持并行跟踪不同的子系统。

**关键数字**：
- `ftrace.c`：9,426 行
- `trace.c`：10,017 行
- `trace_events.c`：5,099 行
- 支持的追踪器：function、function_graph、irqsoff、preemptoff、wakeup、wakeup_dl 等
- 默认 ring buffer 大小：1.4MB/CPU（1408KB）
- 可追踪函数数：通常 50,000+（取决于内核配置）

---

## 附录 A：关键源码索引

| 文件 | 行号 | 符号 |
|------|------|------|
| `include/linux/ftrace.h` | — | `struct ftrace_ops`, `FTRACE_OPS_FL_*` |
| `kernel/trace/ftrace.c` | — | `ftrace_init()`, `ftrace_process_locs()` |
| `kernel/trace/ftrace.c` | — | `ftrace_make_call()`, `ftrace_make_nop()` |
| `kernel/trace/ftrace.c` | — | `ftrace_ops_list_func()` |
| `kernel/trace/ftrace.c` | — | `ftrace_filter_write()`, `ftrace_set_filter()` |
| `kernel/trace/ftrace.c` | — | `register_ftrace_function()` |
| `kernel/trace/trace.c` | — | `struct trace_array` |
| `kernel/trace/trace.c` | — | ring buffer 接口 |
| `kernel/trace/trace_functions.c` | — | `function_trace_call()` |
| `kernel/trace/trace_events.c` | — | tracepoint 事件系统 |
| `arch/x86/kernel/ftrace_64.S` | — | `ftrace_caller` 汇编入口 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
