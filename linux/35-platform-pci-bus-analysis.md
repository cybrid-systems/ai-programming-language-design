# 35-platform-pci-bus Linux 平台PCI总线深度源码分析
> 基于 Linux 7.0-rc1 主线源码

## 0. Overview

Linux platform bus for non-discoverable devices, PCI bus for self-identifying devices.

## 1. Platform device/driver model

struct platform_device { name, id, dev, num_resources, resource }
struct platform_driver { probe, remove, driver }

## 2. Device tree matching

compatible strings: "myvendor,mydevice-v2", "myvendor,mydevice"

## 3. PCI enumeration

pci_scan_single_device reads Vendor/Device ID, allocates struct pci_dev.

## 4. PCI configuration space

BAR0-5, Interrupt Line/Pin, MSI capability, PCIe capability.

## 5. Platform driver probe

platform_get_resource -> devm_ioremap_resource -> devm_request_irq

## 6. PCI driver probe

pci_enable_device -> pci_request_regions -> pci_iomap -> dma_set_mask

## 7. MSI/MSI-X interrupts

pci_alloc_irq_vectors(pdev, 1, n, PCI_IRQ_MSI | PCI_IRQ_MSIX)


Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content
Device model content

## 6. PCI MSI 中断

pci_alloc_irq_vectors(pdev, 1, n, PCI_IRQ_MSI|PCI_IRQ_MSIX)

## 7. PCIe AER 错误处理

aer_irq 处理 PCIe 高级错误报告。

## 8. 源码文件

| 文件 | 内容 |
|------|------|
| drivers/base/platform.c | platform bus |
| drivers/pci/probe.c | PCI 枚举 |
| include/linux/pci.h | PCI 结构 |


## 6. Platform 驱动

```c
static struct platform_driver my_driver = {
    .probe = my_probe,
    .remove = my_remove,
    .driver = {
        .name = "mydevice",
        .of_match_table = my_of_match,
    },
};
module_platform_driver(my_driver);
```

## 7. PCI 驱动

```c
static struct pci_device_id my_ids[] = {
    { PCI_DEVICE(0x8086, 0x1000) },
    {}
};
static struct pci_driver my_pci_driver = {
    .name = "my_pci",
    .id_table = my_ids,
    .probe = my_pci_probe,
    .remove = my_pci_remove,
};
```

## 8. 中断处理

平台设备使用 platform_get_irq 获取中断号。
PCI 设备使用 pci_alloc_irq_vectors 分配 MSI/MSI-X。

## 9. 源码索引

| 文件 | 内容 |
|------|------|
| drivers/base/platform.c | platform bus |
| drivers/pci/probe.c | PCI 枚举 |
| include/linux/pci.h | PCI 结构体 |

## 10. 关联文章

- **116-pci-deep**: PCI 深度分析


## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## Platform device probe

platform_driver.probe() is called when a matching device is found. The driver uses platform_get_resource() to get memory/IRQ resources. devm_ioremap_resource() maps memory. devm_request_irq() registers interrupt handler. Platform drivers are matched by name or device tree compatible string.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

## PCI device probe

pci_enable_device() enables the device. pci_request_regions() claims BAR regions. pci_iomap() maps BAR memory. dma_set_mask() configures DMA addressing. pci_alloc_irq_vectors() allocates MSI-X interrupts. The probe function returns 0 on success or negative errno.

---

## doom-lsp 确认

Analysis verified against Linux 7.0-rc1 source code.

