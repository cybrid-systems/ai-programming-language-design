# VFIO / IOMMU — 虚拟功能 I/O 与 IOMMU 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/vfio/` + `arch/x86/kernel/amd_iommu.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**VFIO** 提供用户空间设备访问，替代传统的 KVM 设备模拟。配合 **IOMMU**（VT-d、AMD-Vi）实现：
- **DMA 隔离**：设备只能访问分配的内存
- **用户空间驱动**：绕过内核直接操作设备

---

## 1. 核心数据结构

### 1.1 vfio_device — VFIO 设备

```c
// drivers/vfio/vfio.c — vfio_device
struct vfio_device {
    struct device           *dev;           // 底层设备
    const char              *name;          // 设备名
    struct vfio_group       *group;        // 所属组
    const struct vfio_device_ops *ops;    // 操作函数

    // 标志
    unsigned long           flags;        // VFIO_DEVICE_FLAGS_*
    //   VFIO_DEVICE_FLAGS_RESET   (支持复位)
    //   VFIO_DEVICE_FLAGS_PCI     (PCI 设备)
};
```

### 1.2 vfio_group — IOMMU 组

```c
// drivers/vfio/vfio.c — vfio_group
struct vfio_group {
    // IOMMU 组（最小隔离单元）
    struct iommu_group      *iommu_group;  // IOMMU 组

    // 文件描述符
    struct file             *container_file; // 所属容器的文件

    // 组内设备
    struct list_head        device_list;   // 设备链表

    // DMA 隔离
    struct vfio_domain      *domain;       // IOMMU 域

    // 标志
    unsigned int            opened:1;      // 组是否已打开
};
```

### 1.3 vfio_iommu — IOMMU 域

```c
// drivers/vfio/vfio.c — vfio_iommu
struct vfio_iommu {
    struct vfio_domain      *domain;       // IOMMU 域
    struct list_head        domain_list;  // 域链表

    // DMA 映射
    struct rb_root          dma_list;      // DMA 区域红黑树
    unsigned long           dma_avail;     // 可用 DMA 地址

    // 保护
    struct mutex            lock;
};
```

---

## 2. IOMMU DMA 映射

### 2.1 vfio_iommu_map — 映射

```c
// drivers/vfio/vfio.c — vfio_iommu_map
static int vfio_iommu_map(struct vfio_iommu *iommu, unsigned long iova,
                           unsigned long pfn, unsigned long size)
{
    struct vfio_domain *domain = iommu->domain;

    // 1. 验证 iova 范围
    if (iova + size > iommu->dma_avail)
        return -EINVAL;

    // 2. 调用 IOMMU API 建立映射
    //    device 只能访问这些物理页
    ret = iommu_map(domain->domain, iova, pfn << PAGE_SHIFT, size, IOMMU_READ | IOMMU_WRITE);

    // 3. 加入 DMA 列表
    rb = kmalloc(sizeof(*rb), GFP_KERNEL);
    rb->iova = iova;
    rb->pfn = pfn;
    rb->size = size;
    rb_link_node(&rb->node, parent, link);
    rb_insert(&rb->node, &iommu->dma_list);

    return 0;
}
```

---

## 3. 用户空间设备访问

### 3.1 VFIO API

```c
// 用户空间流程：
// 1. 打开 /dev/vfio/vfio 容器
int container = open("/dev/vfio/vfio", O_RDWR);

// 2. 获取 IOMMU 组
int group_fd = open("/dev/vfio/36", O_RDWR);  // 组 36
ioctl(container, VFIO_SET_IOMMU, VFIO_TYPE1_IOMMU);

// 3. 把组加入容器
ioctl(group_fd, VFIO_GROUP_SET_CONTAINER, &container);

// 4. 启用组
ioctl(group_fd, VFIO_GROUP_STATUS, &status);

// 5. 获取设备
int device_fd = ioctl(group_fd, VFIO_GROUP_GET_DEVICE_FD, "0000:01:00.0");

// 6. 重置设备
ioctl(device_fd, VFIO_DEVICE_RESET);

// 7. 读取 BAR
mmap(device_fd, ..., 0, size);  // BAR 映射到用户空间
```

---

## 4. IOMMU 驱动

### 4.1 amd_iommu — AMD IOMMU

```c
// arch/x86/kernel/amd_iommu.c — amd_iommu_map
static int amd_iommu_map(struct iommu_domain *dom, unsigned long iova,
                         phys_addr_t paddr, size_t size, int prot)
{
    struct amd_iommu *iommu = to_amd_iommu(dom);
    u64pte_t *pte;
    u64 mask;

    // 1. 获取 PTE 地址
    pte = get_pte_addr(iommu, iova);

    // 2. 构建 PTE
    mask = (size - 1) | IOMMU_READ | IOMMU_WRITE | IOMMU_VALID;

    *pte = (paddr & PAGE_MASK) | mask;

    // 3. 刷新 TLB
    iommu_flush_tlb(dom);

    return 0;
}
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/vfio/vfio.c` | `struct vfio_device`、`vfio_iommu_map` |
| `arch/x86/kernel/amd_iommu.c` | `amd_iommu_map` |
| `include/linux/vfio.h` | VFIO ioctl 定义 |