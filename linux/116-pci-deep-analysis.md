# PCI — 外设组件互连深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/pci/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**PCI/PCIe** 是连接外设的系统总线标准，PCIe 是其高速版本（串行、点对点）。

---

## 1. 核心数据结构

### 1.1 pci_dev — PCI 设备

```c
// include/linux/pci.h — pci_dev
struct pci_dev {
    struct device           dev;           // 基类
    struct pci_bus          *bus;          // 所属总线
    struct pci_slot         *slot;         // 物理槽

    // 地址
    unsigned int           devfn;          // device（0-31） + function（0-7）
    u16                     vendor;         // 厂商 ID
    u16                     device;         // 设备 ID
    u16                     subsystem_vendor; // 子系统厂商
    u16                     subsystem_device; // 子系统设备

    // BAR（基址寄存器）
    struct resource         resource[6];   // BAR0-BAR5
    unsigned long           *irq;           // 中断线

    // 状态
    unsigned int            error_state;    // PCI_ERROR_* 状态
};
```

### 1.2 pci_driver — PCI 驱动

```c
// include/linux/pci.h — pci_driver
struct pci_driver {
    const char              *name;          // 驱动名
    const struct pci_device_id *id_table;   // 支持的设备 ID 表
    int                     (*probe)(struct pci_dev *dev, const struct pci_device_id *id);
    void                    (*remove)(struct pci_dev *dev);
    int                     (*suspend)(struct pci_dev *dev);
    int                     (*resume)(struct pci_dev *dev);
};
```

---

## 2. BAR 空间映射

```c
// drivers/pci/setup_bus.c — pci_remap_bridge_window
static int pci_remap_bridge_window(struct pci_dev *dev, int bar)
{
    // 读取 BAR
    resource_size_t base = pci_resource_start(dev, bar);
    resource_size_t size = pci_resource_len(dev, bar);

    // 映射到 CPU 地址空间
    void __iomem *addr = ioremap(base, size);
}
```

---

## 3. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/pci.h` | `pci_dev`、`pci_driver` |
| `drivers/pci/setup_bus.c` | `pci_remap_bridge_window` |