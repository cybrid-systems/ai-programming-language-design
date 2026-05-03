# 023-interrupt-handling — Linux 内核中断处理深度源码分析

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
  │    ├── 关中断 → 保存上下文
  │    ├── 执行驱动程序注册的 handler
  │    │   → 读/写硬件寄存器（清除中断状态）
  │    │   → 标记数据可用
  │    │   → 触发下半部（raise_softirq）
  │    └── 开中断 → 恢复上下文 → iret
  │
  └── 下半部（SoftIRQ Context）
       ├── 软中断处理（do_softirq）
       ├── tasklet 处理
       └── 工作队列（线程上下文）
```

**doom-lsp 确认**：中断核心实现在 `kernel/irq/` 目录。入口函数在 `arch/x86/kernel/irq.c`（`common_interrupt` @ L326）。API 定义在 `include/linux/interrupt.h`。

---

## 1. 中断硬件架构（x86-64）

### 1.1 APIC（高级可编程中断控制器）

现代 x86 系统使用 APIC 架构管理中断：

```
                      ┌───────────────────────┐
                      │    IO-APIC            │
                      │   (I/O APIC)          │
                      │   24 个引脚            │
                      │   IRQ 0-23            │
                      └─────────┬─────────────┘
                                │
                    ┌───────────┴───────────┐
                    │                       │
              ┌─────▼─────┐          ┌─────▼─────┐
              │ LAPIC CPU0│          │ LAPIC CPU1│
              │ (Local      │          │            │
              │  APIC)    │          │            │
              └───────────┘          └───────────┘

LAPIC 功能：
  ├── LVT（Local Vector Table）: 定时器、性能计数器等本地中断
  ├── IRR（Interrupt Request Register）: 待处理中断
  ├── ISR（In-Service Register）: 正在处理的中断
  └── TPR（Task Priority Register）: 优先级屏蔽
```

### 1.2 IDT（Interrupt Descriptor Table）

每个 CPU 有一个 IDT，将中断向量号映射到处理函数入口：

```c
// arch/x86/include/asm/desc.h
struct idt_entry {
    u16 offset_low;      // 处理函数地址低 16 位
    u16 segment;         // CS 段选择子
    u16 ist:3,           // Interrupt Stack Table
        zero:5,
        type:5,          // 门类型（中断门/陷阱门）
        dpl:2,           // 描述符权限级别
        p:1;             // Present
    u16 offset_mid;      // 处理函数地址中 16 位
    u32 offset_high;     // 处理函数地址高 32 位
    u32 reserved;
};
```

IDT 条目类型：
- **中断门（Interrupt Gate）**：进入时关中断（`IF=0`），iret 时恢复
- **陷阱门（Trap Gate）**：不修改 IF 标志
- **任务门（Task Gate）**：硬件任务切换（已废弃）

---

## 2. 🔥 完整中断处理数据流（x86-64）

```
硬件设备触发中断信号
  │
  └─ IO-APIC 接收中断 → 转换到 LAPIC
       │
       ├─ LAPIC 检查 IRR 和 TPR（优先级匹配？）
       │
       ├─ LAPIC 通过 APIC 总线/LVT 发送中断到 CPU
       │   目标 CPU 由 IRQ affinity 决定
       │
       └─ [在此 CPU 上]
            │
            ├─ CPU 完成当前指令                               [~1-10ns]
            │
            ├─ CPU 硬件自动保存：                              [~10ns]
            │   → RSP, RIP, RFLAGS, CS 被推入内核栈
            │   → IF=0（关中断）
            │   → 切换到 IST（Interrupt Stack Table）栈
            │
            ├─ 根据中断向量号查询 IDT
            │   → 第 vector 个 IDT 条目
            │
            ├─ 跳到 IDT 条目指定的入口
            │   │
            │   └─ 汇编入口（arch/x86/entry/entry_64.S）:
            │        │
            │        ├─ ERROR_CODE 入栈（x86 错误码）
            │        ├─ 中断向量号入栈
            │        │
            │        └─ CALL common_interrupt()
            │             │
            │             └─ DEFINE_IDTENTRY_IRQ(common_interrupt)
            │                  @ arch/x86/kernel/irq.c:326
            │                  │
            │                  ├─ [DEFINE_IDTENTRY_IRQ 宏展开：
            │                  │   irqentry_enter() → 标记中断上下文]
            │                  │
            │                  ├─ __this_cpu_read(vector_irq[vector])
            │                  │   (在 call_irq_handler() 中，根据向量号获取 IRQ 描述符)
            │                  │
            │                  ├─ call_irq_handler(vector, regs)
            │                  │   └─ handle_irq(desc, regs)         [L258]
            │                  │       │
            │                  │       ├─ if (desc->handle_irq)
            │                  │    │     desc->handle_irq(desc, regs)
            │                  │    │     ← handle_fasteoi_irq 等
            │                  │    │        │
            │                  │    │        ├─ [级别触发中断处理]
            │                  │    │        │   handle_level_irq():
            │                  │    │        │   → mask_ack_irq()    ← 屏蔽+确认
            │                  │    │        │   → handle_irq_event()
            │                  │    │        │   → unmask_irq()     ← 取消屏蔽
            │                  │    │        │
            │                  │    │        ├─ [边沿触发中断处理]
            │                  │    │        │   handle_edge_irq():
            │                  │    │        │   → ack_irq()        ← 确认
            │                  │    │        │   → handle_irq_event()
            │                  │    │        │
            │                  │    │        └─ [快速 EOI（MSI/MSI-X）]
            │                  │    │            handle_fasteoi_irq():
            │                  │    │            → handle_irq_event()
            │                  │    │            → eoi_irq()       ← End Of Interrupt
            │                  │    │
            │                  │    └─ handle_irq_event(desc)     [核心]
            │                  │         │
            │                  │         ├─ raw_spin_lock(&desc->lock)
            │                  │         │
            │                  │         ├─ action = desc->action  ← 驱动程序注册的 handler 链表
            │                  │         │
            │                  │         ├─ for_each_handler(action) {
            │                  │         │    │
            │                  │         │    ├─ [★ 上半部：执行驱动程序处理函数]
            │                  │         │    │   ret = action->handler(irq, action->dev_id)
            │                  │         │    │   ← 例：nvme_irq()
            │                  │         │    │   ← 或：ata_interrupt()
            │                  │         │    │   ← 或：usb_hcd_irq()
            │                  │         │    │   ← 返回值：IRQ_HANDLED / IRQ_WAKE_THREAD / IRQ_NONE
            │                  │         │    │
            │                  │         │    ├─ [如果 handler 返回 IRQ_WAKE_THREAD]
            │                  │         │    │   → wake_up_process(desc->threads_handled)
            │                  │         │    │   → 唤醒中断线程（threaded IRQ）
            │                  │         │    │
            │                  │         │    └─ action = action->next
            │                  │         │  }
            │                  │         │
            │                  │         └─ raw_spin_unlock(&desc->lock)
            │                  │
            │                  ├─ [DEFINE_IDTENTRY_IRQ 宏结尾：
            │                  │   irqentry_exit() → 恢复上下文]
            │                  │
            │                  ├─ [返回 __common_interrupt] -> 汇编 IRETQ
            │                  │
            │                  ├─ [中断处理结束后遇到 irq_exit()：
            │                  │   → 触发下半部处理]
            │                  │   if (softirq_pending())
            │                  │     invoke_softirq()              ← 处理软中断
            │                  │     → do_softirq() (见 article 24)
            │                  │
            │                  └─ 汇编返回：
            │                       └─ IRETQ
            │                       │
            │                       └─ 汇编返回：
            │                            └─ IRETQ
            │                                 → 恢复 RFLAGS, RIP, RSP, CS
            │                                 → 回到被中断的代码
```

---

## 3. 注册中断处理函数

```c
// include/linux/interrupt.h

// ——— 标准注册 ———
int request_irq(unsigned int irq, irq_handler_t handler,
                unsigned long flags, const char *name, void *dev);

// ——— threaded IRQ（内核线程下半部） ———
int request_threaded_irq(unsigned int irq,
                          irq_handler_t handler,       // 上半部（可 NULL）
                          irq_handler_t thread_fn,     // 线程化处理
                          unsigned long flags,
                          const char *name, void *dev);
```

**请求流程**（`request_threaded_irq`）：

```
request_threaded_irq(irq, handler, thread_fn, flags, name, dev)
  │
  └─ __setup_irq(irq, desc, action)           @ kernel/irq/manage.c
       │
       ├─ [1] 权限检查
       ├─ [2] 分配 struct irqaction
       │   action->handler = handler            ← 上半部
       │   action->thread_fn = thread_fn        ← 下半部（线程）
       │   action->name = name
       │   action->dev_id = dev
       │
       ├─ [3] 如果是 threaded IRQ：
       │   创建内核线程：
       │   action->thread = kthread_create(irq_thread, action,
       │                                    "irq/%d-%s", irq, name)
       │
       ├─ [4] 启用中断（连接硬件）：
       │   __irq_set_trigger(desc, flags)       ← 设置触发方式
       │   irq_startup(desc, true)              ← 启用硬件中断
       │
       └─ [5] 如果 handler==NULL 且 thread_fn!=NULL：
           唤醒中断线程：
           wake_up_process(action->thread)      ← 线程启动
```

---

## 4. Threaded IRQ——线程化的中断处理

传统中断处理需要在中断上下文中快速执行。Threaded IRQ 允许将大部分工作推迟到内核线程中：

```c
// 示例：mmc 块设备驱动
static irqreturn_t mmc_irq(int irq, void *dev_id)
{
    struct mmc_host *host = dev_id;
    // 上半部：快速检查硬件状态
    // 如果检测到 I/O 完成，返回 IRQ_WAKE_THREAD
    return IRQ_WAKE_THREAD;  // ← 触发下半部线程
}

static irqreturn_t mmc_thread_fn(int irq, void *dev_id)
{
    // 下半部：在线程上下文中执行
    // 可持有 mutex、可休眠
    mmc_blk_rw_rq(mmc_queue);
    return IRQ_HANDLED;
}

// 注册为 threaded IRQ：
request_threaded_irq(irq, mmc_irq, mmc_thread_fn, ...);
// handler 在中断上下文执行
// thread_fn 在内核线程 "irq/xx-mmc" 中执行
```

**数据流**：

```
硬件中断
  │
  ├─ handler（上半部，中断上下文）：
  │   快速读取状态寄存器
  │   返回 IRQ_WAKE_THREAD
  │
  └─ irq_thread（下半部，进程上下文）：
       wake_up_process(irq_thread)
       → 线程调用 thread_fn
       → 可持有锁、可调用 kmalloc(GFP_KERNEL)
       → 可同步等待 I/O
```

---

## 5. /proc/interrupts 解读

```bash
$ cat /proc/interrupts
           CPU0       CPU1       CPU2       CPU3
  0:         30          0          0          0   IO-APIC  2-edge      timer
  1:      12345       9876       5678       3456   IO-APIC  1-edge      i8042
  8:          1          0          0          0   IO-APIC  8-edge      rtc0
 16:         12          0          0          0   IO-APIC 16-fasteoi   ehci_hcd:usb1
 24:    1234567    2345678    3456789    4567890   PCI-MSI 524288-edge  nvme0q0
 25:    9876543    8765432    7654321    6543210   PCI-MSI 524289-edge  nvme0q1
NMI:          0          0          0          0   Non-maskable interrupts
LOC:   12345678   23456789   34567890   45678901   Local timer interrupts
```

| 列 | 含义 |
|----|------|
| `IRQ#` | 中断向量号 |
| `CPU0-3` | 各 CPU 处理的中断次数 |
| 控制器 | IO-APIC / PCI-MSI / LAPIC |
| 类型 | `edge` / `fasteoi` / `level` |
| 名称 | 注册的驱动名称 |

---

## 6. 中断亲和性（IRQ Affinity）

```bash
# 查看 irq 24 的 CPU 亲和性
$ cat /proc/irq/24/smp_affinity
  0000000f    # bitmask: CPU0-3

# 设置 irq 24 只在 CPU 0-1 上处理
$ echo 03 > /proc/irq/24/smp_affinity
```

在内核中，亲和性通过 `irq_desc->irq_common_data.affinity` 控制：

```c
// 中断分配逻辑
// 默认：在 CPU 之间轮询分配
// 可手动设置：绑定特定中断到特定 CPU

// 网络性能优化：将 NIC RX 队列中断分别绑定到不同 CPU
// → 每个 CPU 处理自己的 RX 队列
// → 避免跨 CPU 缓存失效
```

---

## 7. 中断处理的实时性保障

### 7.1 中断嵌套与优先级

```c
// Linux 允许高优先级中断打断低优先级中断处理
// 但在 do_IRQ() 执行期间中断是关闭的
// IRQ 的优先级 = 中断向量号（0-255）
// 向量号越低优先级越高

// 中断向量分配：
//   0-31:   异常和陷阱（不可屏蔽）
//   32-127: 设备中断
//   128:    系统调用（int 0x80）
//   129-238: 设备中断（MSI/MSI-X）
//   239-255: 特殊中断（LOC, NMI 等）
```

### 7.2 中断屏蔽

裸机驱动可以使用 `local_irq_save` / `local_irq_restore` 显式控制中断开关：

```c
unsigned long flags;
local_irq_save(flags);   // 关中断 + 保存状态
// 临界区（不会被中断打断）
local_irq_restore(flags); // 恢复中断

// 变体：
local_irq_disable();      // 只关中断
local_irq_enable();       // 只开中断

// 中断上下文检测：
// in_interrupt()    ← 是否在中断/软中断上下文
// in_irq()          ← 是否在硬中断上下文
// in_softirq()      ← 是否在软中断上下文
```

### 7.3 中断延迟测量

```bash
# 查看最大中断延迟
$ cat /proc/latency_stats
  IRQ 16: max=125μs, total=12345μs, count=1000

# 使用 ftrace 跟踪中断关闭时间
$ echo irqsoff > /sys/kernel/debug/tracing/current_tracer
$ cat /sys/kernel/debug/tracing/trace
  ...
```

---

## 8. 源码文件索引

| 文件 | 内容 | 关键符号 |
|------|------|---------|
| `include/linux/interrupt.h` | API 声明 | `request_irq`, `request_threaded_irq` |
| `kernel/irq/manage.c` | IRQ 管理 | `__setup_irq`, `irq_thread` |
| `kernel/irq/chip.c` | 中断控制器操作 | `handle_level_irq`, `handle_edge_irq`, `handle_fasteoi_irq` |
| `arch/x86/kernel/irq.c` | x86 中断入口 | `common_interrupt` @ L326 |
| `arch/x86/entry/entry_64.S` | 汇编入口 | `common_interrupt` @ L398 |
| `arch/x86/include/asm/desc.h` | IDT 格式 | `struct idt_entry` |
| `arch/x86/kernel/apic/io_apic.c` | IO-APIC | |

---

## 9. 关联文章

- **24-softirq**：中断下半部的软中断机制
- **25-hrtimer**：LAPIC 定时器中断
- **26-RCU**：RCU 与中断的交互（rcu_irq_enter/exit）
- **109-vlan-vxlan**：网络中断的处理

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
