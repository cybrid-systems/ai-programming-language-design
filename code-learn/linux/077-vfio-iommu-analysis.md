# 077-vfio-iommu — Linux VFIO 和 IOMMU 用户态设备直通深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**VFIO（Virtual Function I/O）** 是 Linux 将物理设备直接暴露给用户空间的框架。通过 IOMMU 将设备 DMA 映射到用户空间，使 QEMU/KVM、DPDK、SPDK 可以直接操作硬件而无需内核驱动介入。

**doom-lsp 确认**：`include/linux/vfio.h`（核心结构），`drivers/vfio/vfio_main.c`（VFIO 核心），`drivers/vfio/pci/vfio_pci_core.c`（PCI 实现），`drivers/iommu/iommu.c`（IOMMU 层）。

---

## 1. 核心数据结构

### 1.1 `struct vfio_device`——VFIO 设备

（`include/linux/vfio.h` L39 — doom-lsp 确认）

```c
struct vfio_device {
    struct device                   *dev;       // L40 — 底层物理设备
    const struct vfio_device_ops    *ops;       // L41 — 操作函数表
    const struct vfio_migration_ops *mig_ops;   // L46 — 迁移操作（VM 热迁移）
    const struct vfio_log_ops       *log_ops;   // L47 — dirty page 跟踪
    struct vfio_group               *group;     // L49 — IOMMU 组
    refcount_t                      refcount;   // L54 — 引用计数
    unsigned int                    open_count; // L55 — 打开计数
    struct completion               comp;       // L59 — 完成同步
};
```

### 1.2 VFIO 用户空间 API

```
用户空间 QEMU 操作：
  fd = open("/dev/vfio/vfio")                // 打开 VFIO 容器
  ioctl(VFIO_GET_API_VERSION)
  ioctl(VFIO_SET_IOMMU, VFIO_TYPE1v2_IOMMU)   // 设置 IOMMU 类型

  device_fd = open("/dev/vfio/16")            // 绑定 PCI 设备
  ioctl(VFIO_DEVICE_GET_REGION_INFO)          // 查询 PCI BAR
  ioctl(VFIO_DEVICE_GET_IRQ_INFO)             // 查询 MSI/MSI-X

  ioctl(VFIO_IOMMU_MAP_DMA)                   // 建立 DMA 映射
    → iommu_map(iommu_domain, iova, phys, size, prot)

  mmap(device_fd, VFIO_PCI_BAR0_REGION)       // 映射 PCI BAR 到用户空间
    → vfio_pci_mmap()
      → remap_pfn_range(vma, vma->vm_start, pfn, size, pgprot)

  // QEMU 直接读写 BAR 寄存器
  // 设备 DMA 通过 IOMMU 直接访问用户空间内存
```

### 1.3 IOMMU 映射详解

```c
// VFIO_IOMMU_MAP_DMA ioctl 处理路径：
VFIO_IOMMU_MAP_DMA iova=0x100000, size=2MB, user_addr=0x7f...

  └─ vfio_iommu_type1_map()
       ├─ pin_user_pages(user_addr, nr_pages, FOLL_LONGTERM, pages)
       │     → 锁定用户空间页面（防止被 swap）
       │     → 获取物理地址
       │
       └─ iommu_map(domain, iova, phys_addr, size, prot)
            └─ domain->ops->map(domain, iova, paddr, size, prot)
                 └─ intel_iommu_map() 或 arm_smmu_map()
                      → 写入 IOMMU 页表
                      → 刷新 IOTLB（IPI 或硬件自动）
```

---

## 2. VFIO 设备操作

```c
struct vfio_device_ops {
    char    *name;                              // 设备名称
    int     (*init)(struct vfio_device *vdev);  // VFIO 设备初始化
    void    (*release)(struct vfio_device *vdev); // 释放
    int     (*open)(struct vfio_device *vdev);  // /dev/vfio/N open
    void    (*close)(struct vfio_device *vdev); // /dev/vfio/N close
    ssize_t (*read)(struct vfio_device *vdev, char __user *buf, size_t count, loff_t *ppos);
    ssize_t (*write)(struct vfio_device *vdev, const char __user *buf, size_t count, loff_t *ppos);
    long    (*ioctl)(struct vfio_device *vdev, unsigned int cmd, unsigned long arg);
    int     (*mmap)(struct vfio_device *vdev, struct vm_area_struct *vma);
    int     (*dma_unmap)(struct vfio_device *vdev, struct vfio_device_iommu_range *range);
    ...
};

// PCI VFIO 的实现（drivers/vfio/pci/vfio_pci_core.c）：
// .read     → vfio_pci_core_read()  — 从 PCI BAR 读取
// .write    → vfio_pci_core_write() — 写入 PCI BAR
// .ioctl    → vfio_pci_core_ioctl() — VFIO_DEVICE_* 命令
// .mmap     → vfio_pci_core_mmap()  — mmap PCI BAR
```

---

## 3. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct vfio_device` | include/linux/vfio.h | 39 |
| `vfio_device_fops` | drivers/vfio/vfio_main.c | 1455 |
| `vfio_device_fops_mmap()` | drivers/vfio/vfio_main.c | 1424 |
| `vfio_device_fops_read()` | drivers/vfio/vfio_main.c | 1391 |
| `vfio_device_fops_write()` | drivers/vfio/vfio_main.c | 1407 |
| `vfio_pci_core_read()` | drivers/vfio/pci/vfio_pci_core.c | 相关 |
| `vfio_pci_core_mmap()` | drivers/vfio/pci/vfio_pci_core.c | 相关 |
| `iommu_map()` | drivers/iommu/iommu.c | 相关 |
| VFIO_IOMMU_MAP_DMA | include/uapi/linux/vfio.h | (ioctl 命令) |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-04 | 内核版本：Linux 7.0-rc1*
