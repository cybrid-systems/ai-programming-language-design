# Linux Kernel Interrupt Handling (irq_desc) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/irq/` + `include/linux/irqdesc.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是中断处理？

Linux 中断处理体系：
- **硬中断**（Hard IRQ）：硬件触发的中断，上半部（top half）
- **软中断**（Softirq）：延迟执行的软件中断，下半部（bottom half）
- **IRQ Descriptor**：管理每个 IRQ 号对应的中断处理

---

## 1. irq_desc — IRQ 描述符

```c
// include/linux/irqdesc.h — irq_desc
struct irq_desc {
    struct irq_common_data   irq_common_data;
    struct irq_data          irq_data;       // IRQ 数据（chip、handler 等）
    unsigned int            __percpu    *kstat_irqs;  // 中断统计
    irq_flow_handler_t       handle_irq;    // 中断流处理函数
    struct irqaction        *action;       // 中断处理动作链表
    unsigned int            flags;
    const char              *name;           // 中断名字（如 "eth0"）
} ____cacheline_internodealigned_in_smp;

// irqaction — 每个中断源的处理动作
struct irqaction {
    irq_handler_t           handler;       // 中断处理函数
    void                    *dev_id;       // 设备 ID（用于共享中断）
    struct irqaction         *next;        // 下一个 action（共享中断）
    unsigned int            irq;           // IRQ 号
    unsigned int            flags;
    const char              *name;         // 设备名
    void                    *handler_data;
};
```

---

## 2. handle_irq — 中断流处理

```c
// kernel/irq/chip.c — handle_edge_irq（边沿触发）
void handle_edge_irq(struct irq_desc *desc)
{
    raw_spin_lock(&desc->lock);

    // 1. 清除 pending 标志
    desc->istate &= ~IRQD_IRQ_INPROGRESS;

    // 2. 遍历 action 链表，调用每个 handler
    for (action = desc->action; action; action = action->next) {
        irqreturn_t result;

        result = action->handler(irq, action->dev_id);
        if (result == IRQ_HANDLED)
            break;  // 处理完成
    }

    raw_spin_unlock(&desc->lock);
}

// kernel/irq/handle.c — __handle_irq_event_percpu
irqreturn_t __handle_irq_event_percpu(struct irq_desc *desc)
{
    irqreturn_t retval = IRQ_NONE;

    // 1. 调用 handle_irq（流处理）
    for (action = desc->action; action; action = action->next) {
        irqreturn_t res;

        res = action->handler(irq, action->dev_id);
        retval |= res;
    }

    // 2. 更新统计
    kstat_incr_irqs_this_cpu(desc);

    return retval;
}
```

---

## 3. 中断流处理函数

```c
// 边沿触发（GPIO、网卡等）
handle_edge_irq()
//  电平触发（电平传感器等）
handle_level_irq()
//  简单流处理
handle_simple_irq()
//  线程化中断
handle_fasteoi_irq()
//  主从控制器（ARM GIC）
handle_percpu_devid_irq()
```

---

## 4. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| `irqaction` 链表支持共享中断 | 多个设备可以共享同一 IRQ（PCI INTx）|
| `handle_irq` 流处理分离 | 边沿/电平/EOI 等不同触发方式不同处理 |
| `dev_id` 区分设备 | 共享中断时区分哪个设备触发了 |
| `kstat_irqs` per-CPU 统计 | 避免锁竞争，统计精确到 CPU |

---

## 5. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/irqdesc.h` | `struct irq_desc` |
| `kernel/irq/handle.c` | `__handle_irq_event_percpu` |
| `kernel/irq/chip.c` | `handle_edge_irq`、`handle_level_irq` |
