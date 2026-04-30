# interrupt / irq_desc — 中断处理深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/irq/` + `include/linux/irq.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

Linux 中断处理分为**上半部**（硬中断，irq_desc）和**下半部**（软中断/Tasklet/Workqueue）。

---

## 1. 核心数据结构

### 1.1 irq_desc — 中断描述符

```c
// include/linux/irq.h — irq_desc
struct irq_desc {
    struct irq_common_data    irq_common_data;
    struct irq_data          irq_data;          // 中断数据
    struct irq_chip          *chip;             // 中断控制器芯片操作
    struct irq_domain        *domain;           // IRQ 域映射
    void                    *handler_data;       // 芯片私有数据
    unsigned int            irq;               // IRQ 编号
    unsigned long           threads_oneshot;     // 线程化标记
    struct irqaction        *action;            // 中断处理链表
    struct delayed_work     threaded_resend;     // 延迟重发
    struct irq_affinity_notify *affinity_notify; // CPU 亲和性通知
};
```

### 1.2 irq_chip — 中断控制器操作

```c
// include/linux/irq.h — irq_chip
struct irq_chip {
    const char              *name;              // 芯片名（如 "gic"）
    void                   (*irq_startup)(struct irq_data *);
    void                   (*irq_shutdown)(struct irq_data *);
    void                   (*irq_enable)(struct irq_data *);
    void                   (*irq_disable)(struct irq_data *);
    void                   (*irq_ack)(struct irq_data *);
    void                   (*irq_mask)(struct irq_data *);
    void                   (*irq_mask_ack)(struct irq_data *);
    void                   (*irq_unmask)(struct irq_data *);
    void                   (*irq_eoi)(struct irq_data *);  // GIC: End Of Interrupt
    int                    (*irq_set_affinity)(struct irq_data *, const struct cpumask *, bool);
    int                    (*irq_retrigger)(struct irq_data *);
    int                    (*irq_set_type)(struct irq_data *, unsigned int flow_type);
    // ...
};
```

### 1.3 irqaction — 中断处理动作

```c
// include/linux/interrupt.h — irqaction
struct irqaction {
    irq_handler_t          handler;             // 中断处理函数
    void                  *dev_id;             // 设备标识
    struct irqaction        *next;              // 下一个 action（共享中断）
    irq_handler_t           thread_fn;           // 线程化处理函数
    struct task_struct     *thread;             // 处理线程
    struct irqaction        *secondary;         // 次级 action
    unsigned long          flags;               // IRQF_* 标志
    const char             *name;               // 设备名（/proc/interrupts 显示）
};
```

---

## 2. 中断处理流程

### 2.1 handle_irq — 主入口

```c
// kernel/irq/irqdesc.c — generic_handle_irq
void generic_handle_irq(struct irq_desc *desc)
{
    if (desc->action && desc->action->thread_fn)
        // 线程化中断：唤醒线程
        irq_thread_check_affinity(desc);
    else
        // 非线程化：直接调用 handler
        desc->action->handler(irq, desc->action->dev_id);
}
```

### 2.2 handle_edge_irq — 边沿触发

```c
// kernel/irq/irqdesc.c — handle_edge_irq
void handle_edge_irq(struct irq_desc *desc)
{
    spin_lock(&desc->lock);

    if (desc->istate & IRQS_PENDING) {
        // 清除挂起状态
        desc->istate &= ~IRQS_PENDING;

        // 调用 chip 的 ack
        desc->chip->irq_ack(&desc->irq_data);

        // 遍历 action 链表
        handle_irq_event(desc);

        // 如果在处理期间又有新中断，再次挂起
        if (desc->istate & IRQS_PENDING)
            note_pending_irq(desc);
    }

    spin_unlock(&desc->lock);
}
```

### 2.3 handle_irq_event — 执行中断处理

```c
// kernel/irq/irqdesc.c — handle_irq_event
irqreturn_t handle_irq_event(struct irq_desc *desc)
{
    irqreturn_t ret = IRQ_NONE;

    for_each_action_of_desc(desc, action) {
        ret = action->handler(irq, action->dev_id);
        if (ret != IRQ_HANDLED)
            break;
    }

    return ret;
}
```

---

## 3. 线程化中断（IRQF_ONESHOT）

```c
// kernel/irq/manage.c — irq_thread
static int irq_thread(void *data)
{
    while (!kthread_should_stop()) {
        if (desc->istate & IRQS_PENDING) {
            // 清除挂起
            desc->istate &= ~IRQS_PENDING;

            // 调用线程处理函数
            action->thread_fn(irq, action->dev_id);

            // 完成，发出 EOI
            desc->chip->irq_eoi(&desc->irq_data);
        }

        schedule();
    }
}
```

---

## 4. IRQ 域（IRQ Domain）

```c
// kernel/irq/irqdomain.c — irq_domain
struct irq_domain {
    const char              *name;
    const struct irq_domain_ops *ops;     // 映射操作
    unsigned int             hwirq_base;  // 硬件 IRQ 起始编号
    unsigned int             size;         // IRQ 数量
    struct irq_domain       *parent;     // 父域（级联）
    // ...
};
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/irq.h` | `struct irq_desc`、`struct irq_chip` |
| `include/linux/interrupt.h` | `struct irqaction` |
| `kernel/irq/irqdesc.c` | `generic_handle_irq`、`handle_edge_irq` |
| `kernel/irq/manage.c` | `irq_thread` |
