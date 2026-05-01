# 35-platform-pci-bus — Linux 内核平台/PCI 总线深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**Linux 设备模型**由 platform bus、PCI bus、I2C、SPI 等总线组成。platform bus 是用于没有硬件枚举能力的设备（如 SoC 上的集成外设），PCI bus 是具有硬件配置空间的设备。

**doom-lsp 确认**：`drivers/base/platform.c` 和 `drivers/pci/` 目录。

---

## 1. Platform Bus

```c
// include/linux/platform_device.h
struct platform_device {
    const char  *name;              // 设备名
    int          id;                // 设备 ID
    struct device dev;               // 内嵌 struct device
    u32          num_resources;     // 资源数量
    struct resource *resource;       // 资源数组（IO、内存、中断）
};

// include/linux/platform_driver.h
struct platform_driver {
    int (*probe)(struct platform_device *);
    int (*remove)(struct platform_device *);
    struct device_driver driver;
};
```

### 1.1 注册示例

```c
// 设备树匹配表
static const struct of_device_id my_of_match[] = {
    { .compatible = "myvendor,mydevice" },
    {}
};

static struct platform_driver my_driver = {
    .probe  = my_probe,
    .remove = my_remove,
    .driver = {
        .name = "mydevice",
        .of_match_table = my_of_match,
    },
};
module_platform_driver(my_driver);
```

### 1.2 资源获取

```c
int my_probe(struct platform_device *pdev)
{
    struct resource *res;
    void __iomem *base;

    // 获取内存区域
    res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
    base = devm_ioremap_resource(&pdev->dev, res);

    // 获取中断号
    int irq = platform_get_irq(pdev, 0);

    // 请求中断
    devm_request_irq(&pdev->dev, irq, my_isr, 0, "mydevice", dev);

    return 0;
}
```

---

## 2. PCI Bus

```c
// include/linux/pci.h
struct pci_dev {
    u32 vendor;               // 厂商 ID
    u32 device;               // 设备 ID
    u32 subsystem_vendor;     // 子系统厂商
    u32 subsystem_device;     // 子系统设备
    unsigned int irq;          // IRQ 号
    struct resource resource[DEVICE_COUNT_RESOURCE]; // 资源（BAR）
    unsigned int pcie_cap;    // PCIe 能力
    u8 revision;              // 修订版本
};
```

### 2.1 PCI 驱动注册

```c
static struct pci_device_id my_pci_ids[] = {
    { PCI_DEVICE(0x8086, 0x1000) },  // Intel 82546
    {}
};

static struct pci_driver my_pci_driver = {
    .name       = "my_pci_drv",
    .id_table   = my_pci_ids,
    .probe      = my_pci_probe,
    .remove     = my_pci_remove,
};
module_pci_driver(my_pci_driver);
```

### 2.2 PCI 探测

```c
int my_pci_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
    // 启用设备
    pci_enable_device(pdev);
    pci_set_master(pdev);  // 启用 bus master

    // 获取 BAR 区域
    phys_addr_t mmio = pci_resource_start(pdev, 0);
    unsigned long len = pci_resource_len(pdev, 0);
    void __iomem *base = pci_iomap(pdev, 0, 0);

    // DMA 设置
    dma_set_mask(&pdev->dev, DMA_BIT_MASK(64));

    // 请求中断（MSI-X 优先）
    pci_alloc_irq_vectors(pdev, 1, 1, PCI_IRQ_MSIX | PCI_IRQ_MSI);

    return 0;
}
```

### 2.3 PCI 配置空间

```c
// 读取 PCI 配置空间
u32 vendor = pci_read_config_word(pdev, PCI_VENDOR_ID);
u16 cmd;

pci_read_config_word(pdev, PCI_COMMAND, &cmd);
cmd |= PCI_COMMAND_MASTER;
pci_write_config_word(pdev, PCI_COMMAND, cmd);
```

---

## 3. 源码文件索引

| 文件 | 内容 |
|------|------|
| drivers/base/platform.c | platform bus 核心 |
| drivers/pci/probe.c | PCI 探测 |
| drivers/pci/pci-driver.c | PCI 驱动模型 |
| include/linux/platform_device.h | platform 结构体 |
| include/linux/pci.h | PCI 结构体 |

---

## 4. 关联文章

- **116-pci-deep**：PCI 深度分析

---

*分析工具：doom-lsp*
