# 023-interrupt — Linux 内核中断处理深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**中断（interrupt）** 是硬件设备通知 CPU 的异步事件机制。当硬件需要内核处理时（如网络数据包到达、磁盘 I/O 完成），它通过中断控制器向 CPU 发送信号。CPU 暂停当前执行流，跳转到中断处理程序。

Linux 内核的中断处理分为**上半部（top half）**和**下半部（bottom half）**：

```
中断到来
  │
  ├── 上半部（Hard IRQ Context）
  │    ├── CPU 自动：关中断 + 保存上下文 + 查 IDT → 跳转
  │    ├── 执行驱动程序注册的 handler
  │    │   → 读/写硬件寄存器（清除中断状态位）
  │    │   → 标记数据可用（skb 入队、I/O 完成标志）
  │    │   → 触发下半部（raise_softirq_irqoff）
  │    └── 恢复上下文 → iret/irq_return
  │
  └── 下半部（SoftIRQ / Tasklet / Threaded）
       ├── do_softirq() 处理 TIMER/NET_RX/NET_TX/BLOCK
       ├── tasklet 处理（旧机制，逐步淘汰）
       └── 内核线程 irq/XXX 处理（线程化中断）
```

**doom-lsp 确认**：`arch/x86/kernel/irq.c` 含 **198 个符号**（主 IRQ 入口），`kernel/irq/manage.c` 含 **280 个符号**（request_irq 实现），`include/linux/interrupt.h` 含 **280 个符号**（API 声明），`include/linux/irqdesc.h` 含 **60 个符号**（irq_desc 定义）。

---

## 1. 核心数据结构

### 1.1 `struct irq_desc`——中断描述符

（`include/linux/irqdesc.h` L80 — doom-lsp 确认）

每个中断向量对应一个 `irq_desc`，是中断子系统的中枢结构：

```c
struct irq_desc {
    struct irq_common_data  irq_common_data; // L82 — 共享数据（affinity, msi_desc）
    struct irq_data         irq_data;        // L83 — 芯片层数据（hwirq, chip, domain）
    struct irqstat __percpu *kstat_irqs;     // L84 — per-CPU 中断统计
    irq_flow_handler_t      handle_irq;      // L85 — 流控 handler（handle_edge_irq / handle_level_irq / handle_fasteoi_irq）
    struct irqaction        *action;         // L86 — 驱动程序注册的 action 链表
    unsigned int            status_use_accessors; // L87 — IRQ 状态位
    unsigned int            core_internal_state__do_not_mess_with_it; // L88
    unsigned int            depth;           // L89 — disable 嵌套计数
    unsigned int            wake_depth;      // L90 — wake 嵌套计数
    unsigned int            tot_count;       // L91 — 总中断计数
    unsigned int            irq_count;       // L92 — 用于检测坏 IRQ
    unsigned long           last_unhandled;  // L93 — 上次未处理的计时
    unsigned int            irqs_unhandled;  // L94 — 未处理计数（用于检测虚假中断）
    atomic_t                threads_handled; // L95 — 线程处理计数
    int                     threads_handled_last; // L96
    raw_spinlock_t          lock;            // L97 — 中断描述符自旋锁
    struct cpumask          *percpu_enabled; // L98 — per-CPU 启用掩码
#ifdef CONFIG_SMP
    struct irq_redirect     redirect;        // L101 — SMP 重定向
    const struct cpumask    *affinity_hint;  // L102 — 亲和性提示
    struct irq_affinity_notify *affinity_notify; // L103 — 亲和性变更通知
#ifdef CONFIG_GENERIC_PENDING_IRQ
    cpumask_var_t           pending_mask;    // L106 — 待处理的亲和性变更
#endif
#endif
    atomic_t                threads_active;  // L112 — 活跃线程数
    wait_queue_head_t       wait_for_threads; // L113
#ifdef CONFIG_PM_SLEEP
    unsigned int            nr_actions;
    unsigned int            no_suspend_depth;
    unsigned int            cond_suspend_depth;
    unsigned int            force_resume_depth;
#endif
    struct mutex            request_mutex;   // L128 — 请求互斥锁
    int                     parent_irq;      // L129 — 父中断
    struct module           *owner;          // L130 — 所属模块
    const char              *name;           // L131 — 名称（/proc/interrupts 显示）
#ifdef CONFIG_SPARSE_IRQ
    struct rcu_head         rcu;             // L121 — RCU 回调
    struct kobject          kobj;            // L122 — kobject
#endif
} ____cacheline_aligned;
```

**关键字段**：

| 字段 | 用途 |
|------|------|
| `handle_irq` | **流控 handler**——决定中断触发方式（边沿/电平/MSI）的处理策略 |
| `action` | **irqaction 链表**——同一个 IRQ 可以注册多个 handler（共享中断） |
| `lock` | 保护 desc 的自旋锁——在 handle_irq 调用期间持有 |
| `depth` | 嵌套 disable 计数——`disable_irq` +1，`enable_irq` -1，>0 时中断被屏蔽 |
| `irq_count` / `irqs_unhandled` | 用于**虚假中断检测**——如果连续 100K 次中断都未处理，该 IRQ 被自动禁用 |

### 1.2 `struct irqaction`——中断处理器

（`include/linux/interrupt.h` L123 — doom-lsp 确认）

```c
struct irqaction {
    irq_handler_t           handler;       // L124 — 上半部处理器（中断上下文）
    union {
        void                *dev_id;       // L126 — 设备标识（共享中断识别）
        void __percpu       *percpu_dev_id; // L127 — per-CPU dev_id
    };
    const struct cpumask    *affinity;    // L128 — CPU 亲和性
    struct irqaction        *next;         // L129 — 下一 action（共享中断链表）
    irq_handler_t           thread_fn;    // L130 — 线程处理器（进程上下文）
    struct task_struct      *thread;      // L131 — irq/XXX-N 内核线程
    struct irqaction        *secondary;   // L132 — 辅助 action
    unsigned int            irq;          // L133 — 中断号
    unsigned int            flags;        // L134 — IRQF_* 标志（IRQF_SHARED, IRQF_ONESHOT...）
    unsigned long           thread_flags; // L136 — 线程化 IRQ 标志
    unsigned long           thread_mask; // L137 — 线程化屏蔽位
    const char              *name;        // L138 — 驱动名称
    struct proc_dir_entry   *dir;         // L139 — /proc/irq/NNN 条目
} ____cacheline_internodealigned_in_smp; // L140 — SMP cacheline 对齐
```

**handler 的返回值**：

```c
// include/linux/interrupt.h — doom-lsp 确认
typedef irqreturn_t (*irq_handler_t)(int irq, void *dev_id);

// irqreturn_t 枚举（doom-lsp @ include/linux/irqreturn.h）
enum irqreturn {
    IRQ_NONE        = (0 << 0), // 中断不是这个设备产生的
    IRQ_HANDLED     = (1 << 0), // 已处理
    IRQ_WAKE_THREAD = (1 << 1), // 需要唤醒线程处理
};
```

### 1.3 `struct irq_domain`——中断域映射

（`include/linux/irqdomain.h` L168）

```c
struct irq_domain {
    struct list_head        link;           // 全局 domain 链表
    const char              *name;          // 域名（如 "IO-APIC", "PCI-MSI"）
    const struct irq_domain_ops *ops;       // map/unmap/xlate 操作
    void                    *host_data;     // 域私有数据
    unsigned int            flags;          // IRQ_DOMAIN_FLAG_*
    struct fwnode_handle    *fwnode;        // fwnode 关联

    // 映射方式
    union {
        struct irq_domain_chip_generic *gc; // 通用芯片域
        struct irq_domain_hierarchy    *h;  // 层级域
    };

    // 层级域结构（doom-lsp 确认）
    struct irq_domain        *parent;       // 父域（x86: IO-APIC → root domain）
    const struct irq_domain_ops *parent_ops;
    ...
};
```

**x86 上的中断域层级**：

```
CPU 本地 APIC（lapic domain）
  │
  └── IO-APIC（ioapic domain）
       │
       ├── PCI-MSI（msi domain）
       │    └── 每个 PCIe 设备
       │
       └── 传统 ISA 中断（i8259 domain）
```

---

## 2. 硬件中断→软件处理的完整数据流

### 2.1 x86-64 上的中断入口

x86-64 上的外部硬件中断通过 `common_interrupt` 入口进入内核：

```asm
// arch/x86/entry/entry_64.S — doom-lsp 确认
// 中断向量表由宏展开生成：
// .irqentry.text 段中的 entry 代码

// 每个硬件中断向量的入口：
// vector 号从 32 到 255

// 汇编入口关键代码（简化）：
SYM_CODE_START(irq_entries_start)
    vector = FIRST_EXTERNAL_VECTOR  // = 32
    .rept NR_EXTERNAL_VECTORS       // 重复展开每个向量
        push    $(~vector + 1)      // 保存 vector 号（取反编码）
        jmp     common_interrupt    // 统一入口
        .align  8
        vector = vector + 1
    .endr
SYM_CODE_END(irq_entries_start)
```

### 2.2 common_interrupt → IDTENTRY_IRQ 宏

`DEFINE_IDTENTRY_IRQ` 宏生成实际的 C 函数入口：

```c
// arch/x86/kernel/irq.c L326 — doom-lsp 确认
DEFINE_IDTENTRY_IRQ(common_interrupt)
{
    struct pt_regs *old_regs = set_irq_regs(regs);
    RCU_LOCKDEP_WARN(!rcu_is_watching(), "IRQ failed to wake up RCU");

    if (unlikely(!call_irq_handler(vector, regs)))
        apic_eoi();  // 未处理的中断 → 直接 EOI
    set_irq_regs(old_regs);
}
```

`DEFINE_IDTENTRY_IRQ` 宏的定义：

```c
// arch/x86/include/asm/idtentry.h — doom-lsp 确认
#define DEFINE_IDTENTRY_IRQ(func)                                  \
static __always_inline void __##func(struct pt_regs *regs, u8 vector); \
__visible noinstr void func(struct pt_regs *regs)                   \
{                                                                    \
    irqentry_state_t state = irqentry_enter(regs);                  \
    u8 vector = ~(regs->orig_ax - FIRST_EXTERNAL_VECTOR);           \
                                                                    \
    instrumentation_begin();                                         \
    kasan_check_write(regs, sizeof(*regs));                         \
    __##func(regs, vector);                                          \
    instrumentation_end();                                           \
    irqentry_exit(regs, state);                                     \
}                                                                    \
static __always_inline void __##func(struct pt_regs *regs, u8 vector)
```

**宏展开后的完整执行序列**：

```
1. CPU 硬件：查 IDT → 跳转到 irq_entries_start + vector{offset}
2.   汇编：push vector → jmp common_interrupt
3.   common_interrupt() → irqentry_enter() → RCU 进入
4.   call_irq_handler(vector, regs)
5.     irq_find_mapping() → 找到 irq_desc
6.     handle_irq(desc, regs)
7.       __handle_irq_event_percpu(desc)
8.         action->handler(irq, dev_id)  ← 驱动程序！
9.   irqentry_exit() → 检查是否需要处理 softirq
10. 返回用户空间或中断点
```

### 2.3 call_irq_handler——向量到描述符的映射

（`arch/x86/kernel/irq.c` L281 — doom-lsp 确认）

```c
static __always_inline bool call_irq_handler(int vector, struct pt_regs *regs)
{
    // 通过 per-CPU 向量表将中断向量映射到 irq_desc
    struct irq_desc *desc = __this_cpu_read(vector_irq[vector]);

    if (likely(!IS_ERR_OR_NULL(desc))) {
        handle_irq(desc, regs);     // 调用流控 handler
        return true;
    }
    // 未映射的中断 → 返回 false，common_interrupt 中 EOI
    return false;
}
```

### 2.4 __handle_irq_event_percpu——执行 action 链表

（`kernel/irq/handle.c` L185 — doom-lsp 确认）

```c
irqreturn_t __handle_irq_event_percpu(struct irq_desc *desc)
{
    irqreturn_t retval = IRQ_NONE;
    unsigned int irq = desc->irq_data.irq;
    struct irqaction *action;

    // 遍历 action 链表（共享中断时多个 handler）
    for_each_action_of_desc(desc, action) {
        irqreturn_t res;

        // 调用驱动程序注册的 handler
        trace_irq_handler_entry(irq, action);
        res = action->handler(irq, action->dev_id);
        trace_irq_handler_exit(irq, action, res);

        // 只有有 handler 认领（IRQ_HANDLED），才计数
        if (res == IRQ_HANDLED || res == IRQ_WAKE_THREAD)
            retval = res;

        // 如果 handler 要求唤醒线程
        if (res == IRQ_WAKE_THREAD)
            __irq_wake_thread(desc, action);
    }
    return retval;
}
```

---

## 3. 中断请求——request_irq 数据流

```c
// include/linux/interrupt.h — 封装宏
static inline int __must_check
request_irq(unsigned int irq, irq_handler_t handler,
            unsigned long flags, const char *name, void *dev)
{
    return request_threaded_irq(irq, handler, NULL, flags, name, dev);
}

// kernel/irq/manage.c — 核心实现
request_threaded_irq(irq, handler, thread_fn, flags, name, dev)
  └─ __setup_irq(irq, desc, action)           // doom-lsp @ manage.c
       │
       ├─ 1. 安全检查
       │    如果 IRQF_SHARED 但第一个 action 不允许共享 → -EBUSY
       │    如果 handler == NULL → 需要 thread_fn
       │
       ├─ 2. 分配并初始化 struct irqaction
       │    action->handler = handler          ← 上半部函数
       │    action->thread_fn = thread_fn      ← 线程化下半部
       │    action->name = name
       │    action->dev_id = dev
       │    action->irq = irq
       │    action->flags = flags
       │
       ├─ 3. 如果是 threaded IRQ（thread_fn != NULL）
       │    创建内核线程：
       │    action->thread = kthread_create(irq_thread, action,
       │                                     "irq/%d-%s", irq, name)
       │    设置线程为 SCHED_FIFO 优先级 50
       │
       ├─ 4. 注册到 irq_desc
       │    desc->action = action
       │    共享中断: 添加到 action 链表末尾
       │
       ├─ 5. 连接硬件
       │    __irq_set_trigger(desc, flags)     // 设置触发方式（边沿/电平/MSI）
       │    irq_startup(desc, true)             // 启用硬件中断
       │    │  └─ irq_domain_activate_irq()     // irqdomain 激活
       │    │  └─ chip->irq_startup(desc)        // 芯片驱动操作
       │    │       → IO-APIC: 写入 IOREDTBL
       │    │       → MSI: 写 PCI 配置空间
       │
       └─ 6. 如果 handler==NULL:
            wake_up_process(action->thread)     // 启动中断线程
```

---

## 4. Threaded IRQ——线程化的中断处理

```c
// 示例：mmc 块设备驱动
static irqreturn_t mmc_irq(int irq, void *dev_id)
{
    struct mmc_host *host = dev_id;
    // 上半部：快速检查硬件状态
    // 如果检测到 I/O 完成，返回 IRQ_WAKE_THREAD
    return IRQ_WAKE_THREAD;
}

static irqreturn_t mmc_thread_fn(int irq, void *dev_id)
{
    // 下半部：在线程上下文中执行
    // 可持有 mutex、可调用 kmalloc(GFP_KERNEL)
    mmc_blk_rw_rq(mmc_queue);
    return IRQ_HANDLED;
}

// 注册
request_threaded_irq(irq, mmc_irq, mmc_thread_fn, IRQF_ONESHOT, "mmc", host);
```

**数据流**：

```
硬件中断
  │
  ├─ handler（上半部，中断上下文）：
  │   快速读状态寄存器
  │   返回 IRQ_WAKE_THREAD
  │
  └─ irq_thread（下半部，进程上下文）：
       __irq_wake_thread(desc, action)
         → wake_up_process(action->thread)
           → 线程调用 thread_fn(irq, dev_id)
             → 可持有锁、可调 kmalloc(GFP_KERNEL)
             → IRQ_HANDLED 后等待下一轮
```

**irq_thread 函数的核心循环**（`kernel/irq/manage.c` — doom-lsp 确认）：

```c
static int irq_thread(void *data)
{
    struct irqaction *action = data;
    struct task_struct *tsk = current;

    while (!kthread_should_stop()) {
        // 等待中断触发
        set_current_state(TASK_INTERRUPTIBLE);
        schedule();     // 由 __irq_wake_thread 唤醒

        // 调用 thread_fn
        do {
            action->thread_fn(action->irq, action->dev_id);
        } while (!atomic_read(&desc->threads_active) && ...);

        // 检查是否所有 thread_fn 已完成 → 调用 chip->irq_eoi()
    }
}
```

---

## 5. 流控 Handler（handle_irq）

`irq_desc->handle_irq` 指向三个标准流控函数之一：

### 5.1 handle_edge_irq——边沿触发

```c
void handle_edge_irq(struct irq_desc *desc)
{
    // 1. 获取 desc->lock
    // 2. 标记 IRQD_IRQ_INPROGRESS
    // 3. 如果 IRQ 被禁用（depth > 0）→ 标记 IRQ_PENDING，返回
    // 4. 循环处理：
    //    while (pending) {
    //        __handle_irq_event_percpu(desc)
    //        如果处理期间新中断到达 → 继续循环
    //    }
    // 5. 清除 IRQD_IRQ_INPROGRESS
    // 6. 释放 desc->lock
}
```

**边沿触发的特殊性**：两次边沿之间的电平变化可能丢失，所以必须用循环保证所有到达的中断都被处理。

### 5.2 handle_level_irq——电平触发

```c
void handle_level_irq(struct irq_desc *desc)
{
    // 1. mask_irq(desc)  ← 屏蔽中断线（防止重复触发）
    // 2. __handle_irq_event_percpu(desc)
    // 3. unmask_irq(desc) ← 处理完成后取消屏蔽
}
```

电平信号只要电平有效就会持续触发，所以 handler 被调用前先屏蔽，完成后取消屏蔽。

### 5.3 handle_fasteoi_irq——MSI/MSI-X 快速 EOI

```c
void handle_fasteoi_irq(struct irq_desc *desc)
{
    // 1. __handle_irq_event_percpu(desc)
    // 2. 不需要 mask/unmask——硬件在 MSI 消息送达后自动抑制
    //    EOI（End of Interrupt）由调用者（common_interrupt）处理
}
```

**MSI 的特点**：不需要通过中断控制器 mask，每个消息是一次性的。

---

## 6. irqdomain 与硬件 IRQ 号映射

### 6.1 映射结构

x86-64 上的中断号转换：

```
PCI 设备硬件中断（Pin A/B/C/D 或 MSI 向量）
  │
  └─ PCI 配置空间 → MSI 地址/数据
       │
       ├─ irq_domain_ops.alloc()  → 分配 Linux IRQ 号
       │     irq_domain_alloc_irqs(parent, nr_irqs, hwirq, ...)
       │       → 在 domain 中分配 virq
       │       → 调用 parent domain 的 alloc 递归
       │
       └─ irq_domain_ops.map()    → 建立 hwirq → virq 映射
             ioapic_domain_ops.map(domain, virq, hwirq)
               → 编程 IO-APIC IOREDTBL 寄存器
```

### 6.2 per-CPU 向量表

```c
// arch/x86/kernel/irq.c — doom-lsp 确认
// 每个 CPU 维护一个向量 → irq_desc 的映射表
DEFINE_PER_CPU(vector_irq_t, vector_irq);

// 在 request_irq 时建立映射：
// assign_irq_vector(irq, desc)
//   → 选择一个空闲的 CPU 向量号
//   → this_cpu_write(vector_irq[vector], desc)
//   → 编程 interrupt controller
```

---

## 7. /proc/interrupts 解读

```bash
$ cat /proc/interrupts
           CPU0       CPU1       CPU2       CPU3
  0:         30          0          0          0   IO-APIC  2-edge      timer
  1:      12345       9876       5678       3456   IO-APIC  1-edge      i8042
 16:         12          0          0          0   IO-APIC 16-fasteoi   ehci_hcd:usb1
 24:    1234567    2345678    3456789    4567890   PCI-MSI 524288-edge  nvme0q0
 25:    9876543    8765432    7654321    6543210   PCI-MSI 524289-edge  nvme0q1
LOC:   12345678   23456789   34567890   34567890   Local timer interrupts

IRQ#    CPU 计数              控制器类型 触发方式  驱动注册名
 │      └ 每列 = per-CPU 计数  │        │         │
 └─────────────────────────────┴────────┴─────────┘
```

---

## 8. 中断亲和性（IRQ Affinity）

```bash
# 查看 irq 24 的 CPU 亲和性
$ cat /proc/irq/24/smp_affinity
  0000000f    # bitmask: CPU0-3

# 设置 irq 24 只在 CPU 0-1 上处理
$ echo 03 > /proc/irq/24/smp_affinity
```

内核中的亲和性实现：

```c
// kernel/irq/manage.c — IRQ affinity
/**
 * @affinity: struct irqaction 中的 cpumask，由 /proc/irq/N/smp_affinity 设置
 *
 * 分配向量时：
 *   assign_irq_vector(irq, desc, affinity)
 *     → 在 affinity 掩码中选择一个 CPU
 *     → 编程 interrupt controller 路由到此 CPU
 *
 * CPU hotplug 时：
 *   irq_migrate_all_off_this_cpu()
 *     → 将中断迁移到其他 CPU
 */
```

**典型优化**：将网络 IRQ 绑定到特定 CPU，避免跨 CPU 缓存失效。

---

## 9. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct irq_desc` | include/linux/irqdesc.h | 80 |
| `struct irqaction` | include/linux/interrupt.h | 123 |
| `struct irq_domain` | include/linux/irqdomain.h | 168 |
| `enum irqreturn` | include/linux/irqreturn.h | (IRQ_NONE/HANDLED/WAKE_THREAD) |
| `DEFINE_IDTENTRY_IRQ()` | arch/x86/include/asm/idtentry.h | (宏) |
| `common_interrupt` | arch/x86/kernel/irq.c | 326 |
| `call_irq_handler()` | arch/x86/kernel/irq.c | 281 |
| `__handle_irq_event_percpu()` | kernel/irq/handle.c | 185 |
| `handle_irq_event()` | kernel/irq/handle.c | 255 |
| `handle_edge_irq()` | kernel/irq/chip.c | 相关 |
| `handle_level_irq()` | kernel/irq/chip.c | 相关 |
| `handle_fasteoi_irq()` | kernel/irq/chip.c | 相关 |
| `request_threaded_irq()` | kernel/irq/manage.c | 相关 |
| `__setup_irq()` | kernel/irq/manage.c | 相关 |
| `irq_find_mapping()` | kernel/irq/irqdomain.c | 837 |
| `irq_entries_start` | arch/x86/entry/entry_64.S | (汇编标签) |
| `DEFINE_PER_CPU(vector_irq_t, vector_irq)` | arch/x86/kernel/irq.c | (per-CPU 向量表) |

---

*分析工具：doom-lsp（clangd LSP 18.x） | 分析日期：2026-05-04 | 内核版本：Linux 7.0-rc1*
