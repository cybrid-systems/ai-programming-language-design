# Linux Kernel VFIO / IOMMU 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/vfio/` + `drivers/iommu/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. VFIO / IOMMU

**VFIO** 是用户空间设备驱动的**安全框架**，将设备直通（passthrough）给虚拟机或用户空间进程。**IOMMU**（如 Intel VT-d、AMD-Vi）提供 DMA 地址重映射和隔离。

---

## 1. 核心结构

```c
// drivers/vfio/vfio.c — vfio_device
struct vfio_device {
    struct kref         refcount;
    const char           *name;
    struct vfio_device_ops *ops;   // 设备操作（read/write/mmio）
    struct eventfd_ctx  *iringsfd;   // 中断事件fd
    void                *device_data; // 设备私有数据
};

// vfio_iommu — IOMMU 上下文
struct vfio_iommu {
    struct list_head        domain_list;   // IOMMU domain 链表
    struct iommu_group    *iommu_group;  // IOMMU 组（共享页表的设备）
    struct vfio_domain    *external_domain;
};
```

---

## 2. IOMMU DMA 重映射

```
设备 DMA 请求：
  IO虚拟地址(IOVA) → IOMMU 页表查找 → 物理地址(PA)

VT-d 页表：
  4级页表：PML4 → PDPT → PDT → PT
  每级支持：1GB / 2MB / 4KB 粒度
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/vfio/vfio.c` | VFIO 核心 |
| `drivers/vfio/iommu-legacy.c` | VFIO IOMMU 驱动 |
| `drivers/iommu/intel-iommu.c` | Intel VT-d 驱动 |
| `include/linux/iommu.h` | IOMMU API |
