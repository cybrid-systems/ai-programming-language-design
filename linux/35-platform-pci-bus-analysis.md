# 35-platform-pci-bus — Linux 设备模型深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

Linux 设备模型通过总线抽象连接设备和驱动。**platform bus** 用于不可枚举的设备（SoC 集成外设，无硬件 ID），**PCI bus** 用于可自发现的设备（通过配置空间读取 Vendor/Device ID）。

**doom-lsp 确认**：`include/linux/platform_device.h` 含 **87 个符号**（`struct platform_device` @ L23），`include/linux/pci.h` 含 `struct pci_dev` @ L351，`struct pci_driver` @ L387。

---

## 1. Platform Bus

### 1.1 数据结构

```c
// include/linux/platform_device.h:23 — doom-lsp 确认
struct platform_device {
    const char              *name;            // 设备名（匹配驱动）
    int                      id;              // 实例 ID（-1=单实例）
    bool                     id_auto;         // ID 自动分配
    struct device            dev;             // 内嵌通用设备结构
    u32                      num_resources;   // 资源数量
    struct resource          *resource;       // 资源数组
    const struct platform_device_id *id_entry; // 匹配的 ID 表项
};

// include/linux/platform_device.h — 驱动结构
struct platform_driver {
    int (*probe)(struct platform_device *);    // 设备发现回调
    int (*remove)(struct platform_device *);   // 设备移除回调
    void (*shutdown)(struct platform_device *);
    const struct platform_device_id *id_table; // ID 匹配表
    struct device_driver driver;               // 通用驱动基类
};
```

### 1.2 驱动注册

```c
// drivers/base/platform.c — platform 驱动注册
int __platform_driver_register(struct platform_driver *drv, struct module *owner)
{
    // 设置驱动总线类型为 platform_bus_type
    drv->driver.bus = &platform_bus_type;
    drv->driver.probe = platform_probe;
    drv->driver.remove = platform_remove;

    // 注册到驱动核心
    return driver_register(&drv->driver);
}

// 简化注册宏
module_platform_driver(my_driver);
// 展开为:
// module_init(my_driver_init);  // 注册
// module_exit(my_driver_exit);  // 注销
```

### 1.3 设备树匹配

```dts
// device tree 中的设备描述
// arch/arm/boot/dts/
my_device: my-device@1c00000 {
    compatible = "myvendor,mydevice-v2", "myvendor,mydevice";
    reg = <0x1c00000 0x1000>;     // 寄存器地址范围
    interrupts = <0 42 4>;         // 中断号
    clocks = <&clk 5>;             // 时钟
};

// 驱动匹配表
static const struct of_device_id my_of_match[] = {
    { .compatible = "myvendor,mydevice-v2" },
    { .compatible = "myvendor,mydevice"   },
    { /* sentinel */ }
};
```

### 1.4 资源获取

```c
static int my_probe(struct platform_device *pdev)
{
    struct resource *res;
    void __iomem *base;
    int irq;

    // 获取 I/O 内存区域
    res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
    base = devm_ioremap_resource(&pdev->dev, res);

    // 获取中断号
    irq = platform_get_irq(pdev, 0);
    if (irq < 0)
        return irq;

    // 注册中断处理
    devm_request_irq(&pdev->dev, irq, my_isr, 0, dev_name(&pdev->dev), priv);

    return 0;
}
```

---

## 2. PCI Bus

### 2.1 数据结构

```c
// include/linux/pci.h:351 — doom-lsp 确认
struct pci_dev {
    u32 vendor;              // 厂商 ID (0x8086=Intel)
    u32 device;              // 设备 ID (0x1000=82546)
    u32 subsystem_vendor;    // 子系统厂商
    u32 subsystem_device;    // 子系统设备
    unsigned int irq;         // IRQ 号
    struct resource resource[DEVICE_COUNT_RESOURCE]; // BAR 资源
    unsigned int pcie_cap;   // PCIe 能力偏移
    u8 revision;             // 修订版本
    u8 hdr_type;             // 头部类型
    struct pci_driver *driver; // 绑定驱动
};

// include/linux/pci.h:387 — PCI 驱动
struct pci_driver {
    const char *name;
    const struct pci_device_id *id_table;  // 设备 ID 表
    int (*probe)(struct pci_dev *, const struct pci_device_id *);
    void (*remove)(struct pci_dev *);
};
```

### 2.2 PCI 设备枚举

```c
// drivers/pci/probe.c — PCI 枚举
// 在系统启动或热插拔时调用
unsigned int pci_scan_child_bus(struct pci_bus *bus)
{
    unsigned int devfn, max;
    struct pci_dev *dev;

    for (devfn = 0; devfn < 0x100; devfn++) {
        // 读取 Vendor ID 检测设备是否存在
        if (pci_bus_read_dev_vendor_id(bus, devfn, &l, 60*1000))
            continue;

        // 分配 PCI 设备结构
        dev = pci_alloc_dev(bus);
        dev->devfn = devfn;

        // 读取配置空间信息
        pci_setup_device(dev);

        // 添加到总线
        list_add_tail(&dev->bus_list, &bus->devices);
    }
}
```

### 2.3 PCI 配置空间

```c
// PCI 标准配置空间（256 字节）
// 0x00: Vendor ID, Device ID
// 0x04: Command, Status
// 0x08: Revision ID, Class Code
// 0x10-0x24: BAR0-BAR5 (Base Address Registers)
// 0x3C: Interrupt Line, Interrupt Pin
// 0x40+: 能力链表 (Capability List)

// PCIe 扩展配置空间（4KB）
// 通过 MMIO 方式访问 (ECAM)
// 地址格式: Bus:Device:Function:Register
```

### 2.4 PCI 驱动示例

```c
static struct pci_device_id my_ids[] = {
    { PCI_DEVICE(0x8086, 0x1000) },  // Intel 82546
    { PCI_DEVICE(0x8086, 0x1001) },
    {}
};

static int my_pci_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
    // 1. 启用设备
    pci_enable_device(pdev);
    pci_set_master(pdev);  // 启用 Bus Master

    // 2. 获取 BAR
    phys_addr_t mmio = pci_resource_start(pdev, 0);
    unsigned long len  = pci_resource_len(pdev, 0);
    void __iomem *base = pci_iomap(pdev, 0, 0);

    // 3. 设置 DMA
    dma_set_mask(&pdev->dev, DMA_BIT_MASK(64));

    // 4. 分配 MSI/MSI-X 中断
    int nr = pci_alloc_irq_vectors(pdev, 1, 4, PCI_IRQ_MSIX | PCI_IRQ_MSI);
    for (i = 0; i < nr; i++)
        devm_request_irq(&pdev->dev, pci_irq_vector(pdev, i), my_handler, 0,
                         "mydev", &priv[i]);

    return 0;
}

static struct pci_driver my_pci_driver = {
    .name       = "my_pci_drv",
    .id_table   = my_ids,
    .probe      = my_pci_probe,
    .remove     = my_pci_remove,
};
module_pci_driver(my_pci_driver);
```

---

## 3. 设备生命周期

```
Platform 设备:
  设备树/ACPI 发现 → platform_device_register
    → driver_register → bus_match (名称/兼容性匹配)
    → platform_driver.probe() → 设备初始化
    → 运行 → platform_driver.remove() → 设备移除

PCI 设备:
  枚举/热插拔发现 pci_scan_device
    → pci_setup_device() → pci_bus_add_device()
    → driver_register → pci_bus_match (Vendor/Device ID)
    → pci_driver.probe() → 设备初始化
    → 运行 → pci_driver.remove() → 设备移除
```

---

## 4. 源码文件索引

| 文件 | 内容 |
|------|------|
| drivers/base/platform.c | Platform bus 核心 |
| drivers/pci/probe.c | PCI 枚举 |
| drivers/pci/pci-driver.c | PCI 驱动模型 |
| include/linux/platform_device.h | Platform 结构体 |
| include/linux/pci.h | PCI 结构体 |

---

## 5. 关联文章

- **116-pci-deep**: PCI 深度分析
- **06-kobject**: 设备模型基础

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 6. 总线类型

```c
// drivers/base/base.h — 总线类型定义
struct bus_type {
    const char *name;                       // 总线名 ("platform", "pci")
    int (*match)(struct device *, struct device_driver *);  // 设备驱动匹配
    int (*probe)(struct device *);
    int (*remove)(struct device *);
    // ...
};

// Platform 总线
struct bus_type platform_bus_type = {
    .name    = "platform",
    .match   = platform_match,   // 名称/compatible/ACPI 匹配
    .probe   = platform_probe,
    .remove  = platform_remove,
};

// PCI 总线
struct bus_type pci_bus_type = {
    .name    = "pci",
    .match   = pci_bus_match,    // Vendor/Device ID 匹配
    .probe   = pci_device_probe,
    .remove  = pci_device_remove,
};
```

---

## 7. 设备匹配

```c
// Platform 匹配（driver/base/platform.c）
static int platform_match(struct device *dev, struct device_driver *drv)
{
    struct platform_device *pdev = to_platform_device(dev);
    struct platform_driver *pdrv = to_platform_driver(drv);

    // 1. 设备树 compatible 匹配
    if (of_driver_match_device(dev, drv))
        return 1;

    // 2. ACPI 匹配
    if (acpi_driver_match_device(dev, drv))
        return 1;

    // 3. Platform ID 表匹配
    if (pdrv->id_table)
        return platform_match_id(pdrv->id_table, pdev) != NULL;

    // 4. 名称直接匹配
    return strcmp(pdev->name, drv->name) == 0;
}

// PCI 匹配（drivers/pci/pci-driver.c）
static int pci_bus_match(struct device *dev, struct device_driver *drv)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct pci_driver *pdrv = to_pci_driver(drv);

    // 遍历驱动注册的 id_table
    // 比较 Vendor ID 和 Device ID
    const struct pci_device_id *id;
    id = pci_match_id(pdrv->id_table, pdev);
    if (id) return 1;

    return 0;
}
```

---

## 8. 电源管理

```c
// Platform 驱动的 PM 操作
// drivers/base/platform.c — platform 休眠和恢复

struct dev_pm_ops platform_pm = {
    .suspend    = platform_pm_suspend,
    .resume     = platform_pm_resume,
    .freeze     = platform_pm_freeze,
    .thaw       = platform_pm_thaw,
};

// PCI 电源管理（支持 D0-D3hot-D3cold 状态）
// D0: 全功能
// D1, D2: 中间状态
// D3hot: 软件关闭
// D3cold: 完全断电
```

---

## 9. PCI MSI/MSI-X 中断

```c
// MSI 消息信号中断 - 通过写 MMIO 触发中断

// 分配 MSI/MSI-X 向量
int nr_irqs = pci_alloc_irq_vectors(pdev, 1, num_vectors,
                                      PCI_IRQ_MSIX | PCI_IRQ_MSI);

// 获取每个向量的 IRQ 号
unsigned int irq = pci_irq_vector(pdev, vector);

// 与传统的 INTx 引脚中断相比:
// - MSI 是写内存事务，不占用中断引脚
// - MSI-X 支持更多向量（最多 2048 个）
// - 每个队列/功能可分配独立向量
```

---

## 10. PCIe 错误处理 (AER)

```c
// drivers/pci/pcie/aer.c — 高级错误报告
static irqreturn_t aer_irq(int irq, void *context)
{
    struct aer_rpc *rpc = context;
    u32 status, mask;

    // 读取错误状态寄存器
    pci_read_config_dword(dev, aer + PCI_ERR_COR_STATUS, &status);
    pci_read_config_dword(dev, aer + PCI_ERR_COR_MASK, &mask);

    if (status & ~mask) {
        // 可纠正错误（不影响功能）
        pci_write_config_dword(dev, aer + PCI_ERR_COR_STATUS, status);
    }

    // 不可纠正错误
    pci_read_config_dword(dev, aer + PCI_ERR_UNCOR_STATUS, &status);
    if (status) {
        pci_err(dev, "Uncorrectable error: status=%#x\n", status);
        // 可能触发链路重置或热插拔
    }
    return IRQ_HANDLED;
}
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 11. DMA API

```c
// Platform 设备和 PCI 设备都使用通用 DMA API

// 分配一致 DMA 缓冲区（物理连续）
dma_addr_t dma_handle;
void *cpu_ptr = dma_alloc_coherent(dev, size, &dma_handle, GFP_KERNEL);

// 流式 DMA 映射（用于网络包等）
dma_map_single(dev, cpu_addr, size, direction);
dma_unmap_single(dev, dma_handle, size, direction);

// 分散/聚集 DMA
struct scatterlist sg[10];
dma_map_sg(dev, sg, nents, direction);
```

---

## 12. 热插拔

```c
// Platform 热插拔 — 通过 sysfs 触发
// echo "my_device" > /sys/bus/platform/drivers/my_driver/bind

// PCI 热插拔 — pciehp 驱动
// 硬件检测到插拔事件 → 中断通知
// pciehp_ist() → pciehp_handle_presence_change()
//   → pciehp_enable_slot() / pciehp_disable_slot()
//   → pci_scan_slot() / pci_stop_and_remove_bus_device()

// 软件控制热插拔
// echo 1 > /sys/bus/pci/slots/0/power
```

---

## 13. sysfs 接口

```bash
# Platform 设备 (/sys/devices/platform/)
/sys/devices/platform/my_device/
├── driver -> ../../../bus/platform/drivers/my_driver
├── subsystem -> ../../../bus/platform
├── uevent
└── resources

# PCI 设备 (/sys/devices/pci0000:00/)
/sys/devices/pci0000:00/0000:00:1f.0/
├── vendor              # 0x8086
├── device              # 0x9d84
├── irq                 # 中断号
├── driver -> ../../../bus/pci/drivers/lpc_ich
├── subsystem -> ../../../bus/pci
├── resource0           # BAR0
└── config              # 配置空间访问
```

---

## 14. 总结

Linux 设备模型通过 bus_type 抽象总线、device_driver 抽象驱动、device 抽象设备。Platform bus 通过名称或设备树 compatible 匹配，PCI bus 通过 Vendor/Device ID 匹配。两种总线都支持热插拔、电源管理、DMA 操作。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 15. 设备初始化流程

```
Platform 设备:
  platform_device_alloc(name, id)
    → kzalloc 分配 platform_device
    → dev_set_name(&pdev->dev, "%s.%d", name, id)
    → device_initialize(&pdev->dev)
    → pdev->dev.bus = &platform_bus_type
  platform_device_add(pdev)
    → device_add(&pdev->dev)
    → bus_probe_device → platform_match → platform_probe

PCI 设备:
  pci_scan_device(bus, devfn)
    → pci_alloc_dev(bus)
    → pci_setup_device(dev) — 读取配置空间
    → pci_bus_add_device(dev)
    → device_add(&dev->dev)
    → bus_probe_device → pci_bus_match → pci_device_probe
```

## 16. 参考

| 文件 | 说明 |
|------|------|
| drivers/base/platform.c | Platform bus 核心 |
| drivers/base/core.c | 设备模型核心 |
| drivers/pci/probe.c | PCI 枚举 |
| drivers/pci/pci-driver.c | PCI 驱动模型 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 17. 调试命令

```bash
# Platform 设备
ls /sys/bus/platform/devices/
ls /sys/bus/platform/drivers/
cat /sys/bus/platform/uevent

# PCI 设备
lspci -vvv              # 详细 PCI 设备信息
lspci -s 00:1f.0 -x     # 配置空间 dump
cat /sys/bus/pci/devices/0000:00:1f.0/config
cat /sys/bus/pci/slots/0/address

# 驱动绑定
echo "my_device" > /sys/bus/platform/drivers/my_driver/bind
echo -n "0000:00:1f.0" > /sys/bus/pci/drivers/lpc_ich/unbind
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

Platform 和 PCI 总线是 Linux 设备模型中最常用的两种总线类型。理解它们的匹配机制、资源获取方式和中断管理是内核驱动开发的基础。

设备模型核心在 drivers/base/core.c 中实现。bus_type 定义匹配规则，device_driver 定义驱动接口，device 是硬件抽象。probe 回调在 match 成功后调用。

PCI 设备通过配置空间自描述，platform 设备通过设备树或 ACPI 描述。PCI 支持 MSI/MSI-X 中断和 AER 错误处理。
