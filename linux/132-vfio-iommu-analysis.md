# Linux Kernel VFIO / IOMMU 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/vfio/` + `drivers/iommu/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：VFIO、IOMMU、device passthrough、VT-d、DMA 重映射

---

## 0. VFIO 概述

**VFIO** 是用户空间设备驱动的安全框架，实现设备直通（passthrough）。

```
传统：设备 DMA → 物理内存（可能被恶意利用）
VFIO：设备 DMA → IOMMU → 虚拟地址 → 受保护物理内存
```

---

## 1. 核心数据结构

### 1.1 vfio_device — VFIO 设备

```c
// drivers/vfio/vfio.c — vfio_device
struct vfio_device {
    struct kref           refcount;             // 引用计数
    const char            *name;                // 设备名
    const struct vfio_device_ops *ops;        // 设备操作
    struct vfio_group    *group;              // 所属组
    struct vfio_container *container;          // 所属容器
    struct device         *device;              // 底层设备
    struct list_head      group_next;          // 组内链表
    struct list_head      container_next;       // 容器内链表
    unsigned long         flags;                // 标志
};
```

### 1.2 vfio_group — VFIO 组

```c
// drivers/vfio/vfio.c — vfio_group
struct vfio_group {
    // IOMMU 组（共享页表的设备集合）
    struct iommu_group   *iommu_group;         // 行 65

    // 容器
    struct vfio_container *container;          // 行 68

    // 命名空间
    struct vfio_namespace *namespace;          // 行 71

    // 文件描述符
    struct file           *filp;               // 行 74

    // 引用计数
    int                    users;               // 行 77

    // 设备列表
    struct list_head       device_list;        // 行 80

    // 文件描述符列表
    struct list_head       file_list;          // 行 83

    // 设备类型
    unsigned int           type;               // 行 86
};
```

### 1.3 vfio_iommu — VFIO IOMMU

```c
// drivers/vfio/vfio_iommu.c — vfio_iommu
struct vfio_iommu {
    struct vfio_container  *container;         // 所属容器

    // IOMMU domain
    struct iommu_domain   *domain;            // IOMMU 域

    // IOMMU 组列表
    struct list_head       domain_list;       // domain 链表

    // DMA 映射
    struct rb_root         dma_list;           // DMA 映射红黑树

    // 互斥
    struct mutex           lock;               // 保护 domain_list

    // 标志
    unsigned int           flags;               // VFIO_IOMMU_*
};
```

---

## 2. IOMMU DMA 重映射

```c
// Intel VT-d 页表（4级）：
// PML4（Page Map Level 4）→ 512 GB
// PDPT（Page Directory Pointer）→ 1 GB
// PDT（Page Directory）→ 2 MB
// PT（Page Table）→ 4 KB

// DMA 重映射：
// IO Virtual Address (IOVA) → Physical Address (PA)

// iommu_map()：
// iommu_domain->domain->iommu_map(domain, iova, phys, size, prot);

// iommu_unmap()：
// iommu_domain->domain->iommu_unmap(domain, iova, size);
```

---

## 3. VFIO 设备打开流程

```c
// ioctl:
VFIO_GROUP_SET_CONTAINER → 将组加入容器
VFIO_DEVICE_ATTACH_IOASID → 附加 IOASID
VFIO_DEVICE_GET_INFO → 获取设备信息
VFIO_DEVICE_GET_IRQ_INFO → 获取中断信息
VFIO_DEVICE_BIND_IOMMU_FD → 绑定 IOMMU FD
VFIO_DEVICE_FEATURE_STORE → 存储设备特性
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `drivers/vfio/vfio.c` | VFIO 核心 |
| `drivers/vfio/vfio_iommu.c` | VFIO IOMMU |
| `drivers/iommu/intel-iommu.c` | Intel VT-d |
| `include/linux/iommu.h` | IOMMU API |
