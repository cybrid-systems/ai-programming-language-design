# 23-interrupt — 中断处理深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/irq/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

Linux 中断处理采用分层架构：**硬件中断** → **irq_desc** → **irq_chip** → **handle_** → **中断处理函数**。

---

## 1. 核心数据结构

### 1.1 irq_desc — 中断描述符

```c
// include/linux/irqdesc.h — irq_desc
struct irq_desc {
    struct irq_data         irq_data;        // 中断信息
    unsigned int            irq;              // 中断号
    unsigned int            node;             // NUMA 节点

    // 处理函数
    irq_flow_handler_t      handle_irq;      // 主处理函数（edge/high/level）
    irq_preflow_handler_t    *preflow_handler; // 前置处理
    irq_handler_t           *action;          // 链表（用户注册的中断处理）

    // 状态
    unsigned int            status_use_accessors;
    //   IRQ_DISABLED    = 中断被禁用
    //   IRQ_PENDING     = 中断被挂起
    //   IRQ_INPROGRESS  = 正在处理

    // chip
    struct irq_chip         *chip;           // 中断控制器芯片
    struct irq_domain       *domain;         // IRQ domain 映射
};
```

### 1.2 irq_chip — 中断控制器芯片

```c
// include/linux/irq.h — irq_chip
struct irq_chip {
    const char            *name;           // 芯片名（如 "IO-APIC"）
    unsigned int           (*irq_startup)(struct irq_data *);
    void                  (*irq_shutdown)(struct irq_data *);
    void                  (*irq_enable)(struct irq_data *);
    void                  (*irq_disable)(struct irq_data *);
    void                  (*irq_ack)(struct irq_data *);         // 应答中断
    void                  (*irq_mask)(struct irq_data *);         // 屏蔽
    void                  (*irq_unmask)(struct irq_data *);       // 取消屏蔽
    void                  (*irq_eoi)(struct irq_data *);         // EOI（中断结束）
};
```

### 1.3 irqaction — 中断处理函数

```c
// include/linux/interrupt.h — irqaction
struct irqaction {
    irq_handler_t           handler;         // 中断处理函数
    void                   *dev_id;         // 设备 ID（用于共享中断）
    struct irqaction        *next;          // 下一个处理函数（共享多个设备）
    unsigned long           flags;           // IRQF_SHARED 等
    const char             *name;            // 设备名（/proc/interrupts 显示）
};
```

---

## 2. 中断处理流程

### 2.1 handle_edge_irq — 边沿触发中断

```c
// kernel/irq/chip.c — handle_edge_irq
void handle_edge_irq(struct irq_desc *desc)
{
    struct irq_chip *chip = desc->chip;

    // 1. 检查是否在处理中
    if (irq_check_status(desc, IRQ_INPROGRESS)) {
        // 已经在处理中，只标记 pending
        irq_set_status(desc, IRQ_PENDING);
        return;
    }

    // 2. mask + ack
    chip->irq_mask_ack(&desc->irq_data);

    // 3. 设置 INPROGRESS
    irq_set_status(desc, IRQ_INPROGRESS);

    // 4. 调用 handle_irq_event
    handle_irq_event(desc);

    // 5. unmask
    chip->irq_unmask(&desc->irq_data);
}
```

### 2.2 handle_irq_event — 处理中断事件

```c
// kernel/irq/handle.c — handle_irq_event
int handle_irq_event(struct irq_desc *desc)
{
    int ret = IRQ_HANDLED;
    struct irqaction *action;

    // 遍历所有注册的中断处理函数
    action = desc->action;
    do {
        if (action->flags & IRQF_SHARED) {
            // 共享中断：检查是否是本设备的中断
        }

        ret = action->handler(irq, action->dev_id);
        if (ret == IRQ_HANDLED) {
            action->flags |= IRQF_SHARED;
        }

        action = action->next;
    } while (action);

    return ret;
}
```

---

## 3. 线程化中断（Threaded IRQ）

### 3.1 request_threaded_irq

```c
// kernel/irq/manage.c — request_threaded_irq
int request_threaded_irq(unsigned int irq, irq_handler_t handler,
                         irq_handler_t thread_fn,
                         unsigned long flags, const char *name, void *dev)
{
    struct irqaction *action;

    // 1. 分配 irqaction
    action = kzalloc(sizeof(*action), GFP_KERNEL);
    action->handler = handler;         // 主处理函数（可选）
    action->thread_fn = thread_fn;   // 线程函数
    action->flags = flags;
    action->name = name;
    action->dev_id = dev;

    // 2. 创建线程
    if (thread_fn) {
        action->thread = kthread_run(thread_fn, dev, "irq/%d-%s", irq, name);
    }

    // 3. 注册
    return setup_irq(irq, action);
}
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/irqdesc.h` | `struct irq_desc` |
| `include/linux/irq.h` | `struct irq_chip` |
| `include/linux/interrupt.h` | `struct irqaction` |
| `kernel/irq/chip.c` | `handle_edge_irq`、`handle_level_irq` |
| `kernel/irq/handle.c` | `handle_irq_event` |
| `kernel/irq/manage.c` | `request_threaded_irq` |

---

## 5. 西游记类比

**中断处理** 就像"取经路上的紧急军情"——

> 每个妖怪据点（设备）都有紧急信号灯（irq）和守门人（irq_chip）。有紧急情况时，守门人拉响警报（中断），天神（CPU）看到后，先 mask + ack（确认收到），然后根据警报类型（edge/level）决定怎么处理。如果是边沿触发（有人在门口晃了一下），天神直接去找相应部门的中断处理函数（handler）处理；如果设置了线程化中断，天神就把任务交给专门的信使（kthread）去处理，自己继续巡逻。

---

## 6. 关联文章

- **softirq**（article 24）：底半部处理
- **kthread**（article 14）：线程化中断