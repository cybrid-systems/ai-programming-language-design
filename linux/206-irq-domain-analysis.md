# 206-irq_domain — 中断域深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/irq/irqdomain.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**irq_domain** 管理硬件中断号到 Linux 中断号的映射，支持级联中断控制器（如 GPIO → GIC → CPU）。

---

## 1. irq_domain

```c
// kernel/irq/irqdomain.c — irq_domain
struct irq_domain {
    struct list_head link;
    const char *name;
    irq_hw_number_t hwirq_base;    // 硬件中断起始
    unsigned int size;
    const struct irq_domain_ops *ops;
    void *host_data;

    // 映射类型
    enum {
        IRQ_DOMAIN_MAP_LEGACY,    // 固定映射
        IRQ_DOMAIN_MAP_TREE,      // 级联树
        IRQ_DOMAIN_MAP_LINEAR,    // 线性映射
    } type;
};
```

---

## 2. GPIO 中断域级联

```
GPIO 控制器：
  GPIO 编号 → irq_domain → Linux IRQ 编号
                  ↓
            GIC 中断控制器
                  ↓
            CPU 中断号

例子：
  GPIO pin 23 → irq_domain.map(GPIO23) → Linux IRQ 150
  → request_threaded_irq(150, handler)
```

---

## 3. 西游记类喻

**irq_domain** 就像"天庭的中转站编号系统"——

> irq_domain 像把地方藩王的编号（硬件中断号）映射到天庭的挂号系统（Linux IRQ）。地方有不同的藩王（GPIO、PCIe GIC），每个藩王有自己的编号体系。irq_domain 就是把各藩王的编号统一映射到天庭的标准编号。

---

## 4. 关联文章

- **interrupt**（article 23）：irq_domain 是中断处理的一部分
- **PCI**（article 116）：PCIe MSI 使用 irq_domain