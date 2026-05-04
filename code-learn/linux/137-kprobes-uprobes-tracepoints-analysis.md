# Linux 动态插桩深度分析：kprobes / uprobes / tracepoints

## 概述

Linux 内核提供三层次动态插桩机制，覆盖从内核到用户空间到静态事件的完整观测需求：

```
kprobes     — 内核动态插桩：在任意内核指令位置插入探测点
uprobes     — 用户空间动态插桩：在用户程序指令位置插入探测点
tracepoints — 内核静态插桩：在内核预定义的静态位置插入探测点
```

这三者构成了 perf、ebpf、ftrace、systemtap 等所有 Linux 观测工具的底层基础设施。

## kprobes — 内核动态插桩

### struct kprobe — 探测点描述符

（`include/linux/kprobes.h` L59~85）

```c
struct kprobe {
    struct hlist_node   hlist;          // 哈希链表节点（按地址索引）
    struct list_head    list;           // 同一地址的多 handler 链表
    unsigned long       nmissed;        // 临时禁用期间错过的命中次数
    kprobe_opcode_t     *addr;          // 探测点的内核虚拟地址
    const char          *symbol_name;   // 符号名（如 "do_sys_open"）
    unsigned int        offset;         // 符号内的偏移字节数
    unsigned int        flags;          // KPROBE_FLAG_* 标志

    /* 预处理器：在目标指令执行前调用 */
    int (*pre_handler)(struct kprobe *p, struct pt_regs *regs);
    /* 后处理器：在目标指令执行后调用 */
    void (*post_handler)(struct kprobe *p, struct pt_regs *regs,
                         unsigned long flags);
    /* 错误处理器：探测点处理出错时调用 */
    int (*fault_handler)(struct kprobe *p, struct pt_regs *regs, int trapnr);
    /* 断点后单步完成时的处理 */
    int (*break_handler)(struct kprobe *p, struct pt_regs *regs);
};
```

### kprobe 的实现机制

kprobe 的核心原理是**指令替换 + 单步执行**：

```
原始代码：
  ┌─────────────────┐
  │   原始指令      │  ← addr
  └─────────────────┘

注册 kprobe 后：
  ┌─────────────────┐
  │   INT3 (0xCC)   │  ← addr（替换为断点指令）
  └─────────────────┘

执行触发时：
  1. CPU 执行到 INT3 → #BP 异常（trap 3）
  2. do_int3() → kprobe_handler()
  3.   └─ pre_handler(p, regs)     // 用户注册的处理器
  4.   └─ 单步执行原始指令
           └─ post_handler(p, regs, flags)  // 后处理器
  5.   └─ 恢复到正常执行流
```

**关键架构细节**（x86-64）：

```c
// arch/x86/kernel/kprobes/core.c
// 替换指令为 INT3 (0xCC)
void arch_prepare_kprobe(struct kprobe *p)
{
    // 1. 保存原始指令到 p->ainsn.insn[]
    // 2. 在 kprobe 单步缓冲区（ainsn）中准备副本
    // 3. 将目标地址替换为 0xCC
    *p->addr = BREAKPOINT_INSTRUCTION;
}

// 单步执行原始指令
void arch_kprobe_single_step(struct kprobe *p)
{
    // 设置 EFLAGS.TF（Trap Flag）
    regs->flags |= X86_EFLAGS_TF;
    // 设置单步缓冲区地址为返回地址
    regs->ip = (unsigned long)p->ainsn.insn;
}
```

### kretprobe — 函数返回探测

kretprobe 在函数入口和返回处分别设置探测点：

```c
struct kretprobe {
    struct kprobe       kp;             // 底层的 kprobe（入口探测）
    struct hlist_head   free_instances; // 空闲的 kretprobe_instance
    struct hlist_head   used_instances; // 正在使用的实例
    unsigned int        maxactive;      // 最大并发实例数
    int (*entry_handler)(struct kretprobe_instance *ri, struct pt_regs *regs);
    int (*handler)(struct kretprobe_instance *ri, struct pt_regs *regs);
};
```

```
register_kretprobe(func, handler)
  │
  ├─ 在 func 入口设置 kprobe（entry_handler → kretprobe_handler）
  │
  └─ 当 func 被调用时：
       ├─ 1. entry_handler 触发
       │       └─ 修改返回地址 → 指向 trampoline
       │       └─ 保存原始返回地址到 kretprobe_instance
       │
       ├─ 2. func 正常执行...
       │
       └─ 3. func 执行 ret 指令
               └─ 返回到 kretprobe_trampoline
                    └─ handler(ri, regs)    // 用户注册的返回值处理器
                    └─ 恢复到原始返回地址
```

### kprobes 事件注册流程

```
register_kprobe(p)
  └─ __register_kprobe(p)                       // kernel/kprobes.c L1671
       ├─ 1. 安全检查
       │     check_kprobe_address_safe(p)
       │     检查地址是否在内核文本段、不在 __init 段
       │
       ├─ 2. 查找或创建 aggr_kprobe（同一地址多 handler 聚合）
       │     aggr_kprobe = kprobe_table[hash_addr(p->addr)]
       │     如果已有，将 p 加入聚合列表
       │
       ├─ 3. 架构相关准备
       │     arch_prepare_kprobe(p)
       │     → 保存原始指令，准备单步缓冲区
       │
       ├─ 4. 将 kprobe 插入哈希表
       │     hlist_add_head_rcu(&p->hlist, &kprobe_table[hash])
       │
       ├─ 5. 启用探测点
       │     arch_arm_kprobe(p)
       │     → 写入 INT3 (0xCC) 到目标地址
       │
       │     // 注意：这只在当前 CPU 上生效
       │     // 其他 CPU 上的指令缓存需要刷新
       │     text_poke_bp(p->addr, INT3_INSN_CODE);
       │     // text_poke_bp 通过 stop_machine 或 IPI 刷新所有 CPU
       │
       └─ 6. 通过 synchronize_rcu() 等待所有 CPU 上的被替换指令不再执行
```

## uprobes — 用户空间动态插桩

uprobes 与 kprobes 原理相同，但操作的是用户空间地址：

### 核心流程

```
register_uprobe(path, offset, handler)
  │
  ├─ 1. 路径解析
  │     path_lookup(path) 找到目标文件的 inode
  │
  ├─ 2. 创建 uprobe 对象
  │     alloc_uprobe(inode, offset)
  │     → 在 inode + offset 处设置断点
  │
  ├─ 3. 断点设置（懒加载）
  │     set_swbp(&uprobe)
  │     → 当目标区域第一次被 mmap 时
  │     → install_breakpoint(uprobe, mm)
  │     → 在用户空间地址写入 INT3
  │
  └─ 4. 处理用户空间 INT3
        handle_swbp(regs)                         // kernel/events/uprobes.c
          └─ uprobe_notify_resume(regs)
               └─ 查找 uprobe（通过 current->mm + regs->ip）
               └─ handler_uprobe(uprobe, regs)    // 调用注册的处理器
               └─ 单步执行原始指令
               └─ 恢复执行
```

### uprobe vs kprobe 的差异

| 特性 | kprobe | uprobe |
|------|--------|--------|
| 目标 | 内核空间 | 用户空间 |
| 断点设置 | 立即生效 | 懒加载（mmap 时） |
| 触发路径 | do_int3() → kprobe_handler | 用户态 INT3 → do_int3 → uprobe_notify_resume |
| 单步执行 | 内核单步缓冲区 | 用户空间（在用户栈上执行原始指令） |
| 生命周期 | 与模块绑定 | 与 inode 绑定（文件被删除后失效） |
| 性能开销 | ~0.5μs（INT3 + 单步） | ~1μs（需要切换上下文） |

## tracepoints — 内核静态插桩

tracepoints 是**编译时定义的静态探测点**。与 kprobes 不同，它们在内核代码中以 `DECLARE_TRACE()` / `DEFINE_TRACE()` 宏定义，在被启用时插入空操作（nop），激活时替换为跳转指令。

### 定义

```c
// include/trace/events/sched.h
DECLARE_EVENT_CLASS(sched_wakeup_template,
    TP_PROTO(struct task_struct *p),
    TP_ARGS(p),
    TP_STRUCT__entry(__field(int, prio) ...),
    TP_fast_assign(__entry->prio = p->prio; ...),
    TP_printk("comm=%s pid=%d prio=%d", __entry->comm, ...)
);

DEFINE_EVENT(sched_wakeup_template, sched_wakeup,
    TP_PROTO(struct task_struct *p),
    TP_ARGS(p)
);
```

展开后的代码（伪码）：

```c
// 内核中的 tracepoint 结构
struct tracepoint __tracepoint_sched_wakeup = {
    .name = "sched_wakeup",
    .key = &__tracepoint_sched_wakeup,
    .funcs = NULL,  // 无 handler 时是空
};

// 调用点（在内核代码中）
static inline void trace_sched_wakeup(struct task_struct *p)
{
    // 如果 funcs 非空，跳转到 handler
    if (static_branch_unlikely(&__tracepoint_sched_wakeup.key))
        __traceiter_sched_wakeup(p);
}
```

`static_branch_unlikely` 使用 static key 机制：当没有 handler 注册时，它是一个 5 字节 nop（无开销）；当 handler 注册时，被 `text_poke` 修改为 5 字节跳转指令（jmp）。

### tracepoint 激活

```c
// 注册回调
tracepoint_probe_register(&__tracepoint_sched_wakeup, handler, data);

// 内部调用 tracepoint_add_func()：
//   1. 添加 func 到 tracepoint->funcs 链表
//   2. 通过 static_key_enable() 修改 static branch
//     → nop 被替换为 jmp +5
//     → 下次执行 trace_sched_wakeup() 时跳转到 __traceiter
```

### tracepoint vs kprobe

| 特性 | kprobe | tracepoint |
|------|--------|-----------|
| 定义 | 运行时动态 | 编译时静态 |
| 可用性 | 任何非 __init 函数 | 只在预定义位置 |
| 参数访问 | 通过 pt_regs 解析 | 类型安全，直接访问 |
| 稳定 API | 否（内部实现可能变化） | 是（ABI 稳定） |
| 关闭时开销 | 0（断点被移除） | 0（static branch nop） |
| 激活时开销 | ~0.5μs（INT3 + 单步） | ~0.05μs（jmp 到 handler） |
| 批量触发 | 同一地址多 handler | 链表遍历 |

## 三者在观测栈中的角色

```
            ┌───────────────┐
            │  perf / bpftool / trace-cmd  │
            └───────┬───────┘
                    │
    ┌───────────────┼───────────────┐
    │               │               │
    ▼               ▼               ▼
┌───────┐   ┌───────────┐   ┌───────────┐
│perf   │   │  eBPF     │   │ ftrace    │
│events │   │  (kprobe/ │   │ (静态/动态│
│       │   │   uprobe/ │   │  tracer)  │
│       │   │   trace-  │   │           │
│       │   │   point)  │   │           │
└───┬───┘   └─────┬─────┘   └─────┬─────┘
    │             │               │
    ▼             ▼               ▼
┌─────────────────────────────────────┐
│   kprobes / uprobes / tracepoints  │
│   (核心插桩基础设施)                │
└─────────────────────────────────────┘
    │             │               │
    ▼             ▼               ▼
内核指令     内核指令       静态事件点
(INT3)     (INT3/uaddr)   (static call)
```

## 性能开销对比

| 操作 | kprobe | kretprobe | uprobe | tracepoint |
|------|--------|-----------|--------|-----------|
| 空载（无 handler） | 0 | 0 | 0 | 0 |
| 命中（进入+退出） | ~0.5μs | ~1.0μs | ~1.5μs | ~0.05μs |
| 单 handler | ~0.7μs | ~1.3μs | ~2.0μs | ~0.1μs |
| eBPF program 执行 | +0.2-1μs | +0.2-1μs | +0.2-1μs | +0.2-1μs |

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct kprobe` | include/linux/kprobes.h | 59 |
| `register_kprobe()` | kernel/kprobes.c | 1708 |
| `__register_kprobe()` | kernel/kprobes.c | 1671 |
| `unregister_kprobe()` | kernel/kprobes.c | 相关 |
| `register_kretprobe()` | kernel/kprobes.c | 相关 |
| `handle_kprobe()` | arch/x86/kernel/kprobes/core.c | (INT3 handler) |
| `arch_prepare_kprobe()` | arch/x86/kernel/kprobes/core.c | 相关 |
| `arch_arm_kprobe()` | arch/x86/kernel/kprobes/core.c | 相关 |
| `text_poke_bp()` | arch/x86/kernel/alternative.c | 相关 |
| `struct tracepoint` | include/linux/tracepoint.h | 相关 |
| `DECLARE_EVENT_CLASS()` | include/trace/define_trace.h | (宏定义) |
| `tracepoint_probe_register()` | kernel/tracepoint.c | 相关 |
| `static_branch_unlikely()` | include/linux/jump_label.h | (static key 宏) |
| `handle_swbp()` | kernel/events/uprobes.c | (uprobe INT3 handler) |
| `uprobe_notify_resume()` | kernel/events/uprobes.c | 相关 |
| `alloc_uprobe()` | kernel/events/uprobes.c | 相关 |
| `set_swbp()` | kernel/events/uprobes.c | 相关 |
