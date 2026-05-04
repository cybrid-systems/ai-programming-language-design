# 077-vfio-iommu — Linux VFIO 和 IOMMU 用户空间驱动框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码 | 使用 doom-lsp 进行逐行符号解析

---

## 0. 概述

**VFIO（Virtual Function I/O）** 是 Linux 内核将物理设备直接暴露给用户空间的框架，是 QEMU/KVM PCIe 透传、DPDK、SPDK 的基础。核心思想：通过 IOMMU 将设备 DMA 地址空间映射到用户空间进程的虚拟地址空间，使用户空间驱动可以直接操作硬件。

**doom-lsp 确认**：`drivers/vfio/vfio_main.c`（核心），`drivers/vfio/pci/vfio_pci_core.c`（PCI 实现），`drivers/iommu/iommu.c`（IOMMU 层）。

---

## 1. 核心数据结构

### 1.1 `struct vfio_device`——VFIO 设备

```c
struct vfio_device {
    struct device           *dev;            // 底层物理设备
    const struct vfio_device_ops *ops;       // 操作函数表
    struct iommu_group      *group;          // IOMMU 组
    refcount_t              refcount;        // 引用计数
    unsigned int            open_count;      // 打开计数
    ...
};
```

### 1.2 `struct vfio_iommu_driver`——IOMMU 后端

```c
struct vfio_iommu_driver {
    const struct vfio_iommu_ops *ops;        // map/unmap/dma_alloc
    char                    *name;           // "iommu" 或 "type1"
};
```

IOMMU 操作（`struct vfio_iommu_ops`）：
- `map()`：将用户空间 VMA 映射到 IOMMU IOVA
- `unmap()`：解除 IOMMU 映射
- `dma_alloc()`：分配 DMA 缓冲区

---

## 2. 完整数据流

### 2.1 设备透传（QEMU/KVM 场景）

```
用户空间（QEMU）：
    open("/dev/vfio/vfio")          → VFIO 文件描述符
    ioctl(VFIO_GET_API_VERSION)
    ioctl(VFIO_SET_IOMMU, VFIO_TYPE1v2_IOMMU)

    open("/dev/vfio/16")            → 绑定 PCI 设备 0000:00:10.0
    ioctl(VFIO_DEVICE_GET_REGION_INFO)  → PCI BAR 映射
    ioctl(VFIO_DEVICE_GET_IRQ_INFO)     → MSI/MSI-X 中断

    ioctl(VFIO_IOMMU_MAP_DMA)
      └─ iommu_map(iommu_domain, iova, phys_addr, size, prot)
           → IOMMU 页表更新（硬件 IOTLB 刷新）

    mmap(vfio_fd, VFIO_PCI_BAR0_REGION)
      └─ vfio_pci_mmap()
           → remap_pfn_range() 将 PCI BAR 映射到用户空间

    // QEMU 直接操作 PCI BAR + 处理 MSI 中断
    // 无需内核介入
```

### 2.2 IOMMU 映射

```
VFIO_IOMMU_MAP_DMA iova=0x100000, size=2MB, user_addr=0x7f...
  └─ vfio_iommu_type1_map()
       └─ pin_user_pages(user_addr, ...)     // 锁定用户页面
       └─ iommu_map(domain, iova, phys, size) // 建立 DMA 映射
            └─ intel_iommu_map() 或 arm_smmu_map()
```

---

## 3. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct vfio_device` | include/linux/vfio.h | 相关 |
| `struct vfio_iommu_driver` | include/linux/vfio.h | 相关 |
| `vfio_pci_mmap()` | drivers/vfio/pci/vfio_pci_core.c | 相关 |
| `vfio_iommu_type1_map()` | drivers/vfio/vfio_iommu_type1.c | 相关 |
| `iommu_map()` | drivers/iommu/iommu.c | 相关 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
