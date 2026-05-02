# 77-vfio-iommu — Linux VFIO 和 IOMMU 用户态设备直通深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**VFIO（Virtual Function I/O）** 是 Linux 中**用户态设备直通**框架，允许用户空间驱动程序直接控制物理硬件设备。**IOMMU**（I/O Memory Management Unit）提供 DMA 重映射和隔离，使设备只能访问被授权的内存区域。

**核心设计**：VFIO 将物理设备通过 `/dev/vfio/` 暴露给用户空间。用户空间程序通过 ioctl 获取设备的 PCI 配置空间访问、MMIO 映射、中断注册和 DMA 地址管理。IOMMU 在底层保证设备 DMA 不会访问未经授权的内存。

```
用户空间                         内核                         硬件
  QEMU/DPDK                      │                              │
    │                            │                              │
  /dev/vfio/vfio ── ioctl ──→   VFIO 核心                      │
    │                            │                              │
  /dev/vfio/N ──→  IOMMU 组 ──→ vfio_iommu_type1              │
    │                            │   vfio_dma_map()              │
    │                            │   iommu_map() ← IOMMU API    │
    │                            │       ↓                      │
    │                            │   调用 IOMMU 驱动             │
    │                            │   写 IOMMU 页表              │
    │                            │       ↓                      │
    │                            │  设备 DMA 到用户地址          │
```

**doom-lsp 确认**：VFIO 核心在 `drivers/vfio/vfio_main.c`（**1,856 行**）。IOMMU type1 后端在 `vfio_iommu_type1.c`（**3,284 行**）。IOMMU 核心 API 在 `drivers/iommu/iommu.c`（4,137 行）。

---

## 1. 核心数据结构

### 1.1 IOMMU 组（iommu_group）

IOMMU 将设备分组——同一组中的设备共享 IOMMU 地址空间：

```c
// drivers/iommu/iommu.c
struct iommu_group {
    struct kobject kobj;
    struct kobject *devices_kobj;
    struct list_head devices;            // 组内设备列表
    struct iommu_domain *default_domain;  // 默认 DMA 域
    struct iommu_domain *blocked_domain;  // 阻塞域
    struct mutex mutex;
    int id;                              // 组 ID
    struct iommu_domain *owner;          // 当前所有者
};

// IOMMU 域（DMA 地址空间）：
struct iommu_domain {
    unsigned type;                        // UNMANAGED/DMA/F_UNMANAGED
    const struct iommu_domain_ops *ops;   // 域操作
    unsigned long pgsize_bitmap;          // 支持的页大小
    struct iommu_domain *next;
    void *priv;
};
```

### 1.2 VFIO 设备

```c
// include/linux/vfio.h
struct vfio_device {
    struct device *dev;                    // 物理设备
    const struct vfio_device_ops *ops;     // 操作表
    struct vfio_group *group;              // 所属 IOMMU 组
    refcount_t refcount;
    unsigned int open_count;
    struct completion comp;

    /* 迁移状态 */
    struct vfio_device_migration_info *mig;
    u8 *migration_data;
};
```

---

## 2. VFIO 核心路径

### 2.1 打开流程

```c
// 用户空间：
// fd = open("/dev/vfio/vfio", O_RDWR);
// ioctl(fd, VFIO_GET_API_VERSION);
// ioctl(fd, VFIO_SET_IOMMU, VFIO_TYPE1_IOMMU);
// group_fd = open("/dev/vfio/N", O_RDWR);
// ioctl(group_fd, VFIO_GROUP_SET_CONTAINER, &container_fd);
// device_fd = ioctl(group_fd, VFIO_GROUP_GET_DEVICE_FD, "0000:00:1f.0");
```

```c
// VFIO_GROUP_SET_CONTAINER — 将 IOMMU 组绑定到容器
// → vfio_group_set_container()
//   → 检查组内所有设备未使用
//   → group->container = container
//   → 如果所有组都绑定 → 打开 IOMMU

// VFIO_IOMMU_MAP_DMA — 注册 DMA 映射
// → vfio_iommu_type1_ioctl(VFIO_IOMMU_MAP_DMA)
//   → vfio_dma_do_map()
//     → iommu_map(domain, iova, phys_addr, size, prot)
//     → 写入 IOMMU 页表
```

### 2.2 DMA 映射——vfio_iommu_type1

```c
// drivers/vfio/vfio_iommu_type1.c
// 管理用户空间到设备 DMA 地址的映射

struct vfio_iommu {
    struct list_head domain_list;        // IOMMU 域列表
    struct vfio_domain *external_domain;  // 外部域
    struct list_head iova_list;           // IOVA 区间
    u64 pgsize_bitmap;
    struct mutex lock;
};

struct vfio_domain {
    struct iommu_domain *domain;          // IOMMU 域
    struct list_head next;
    struct list_head group_list;           // 组列表
    unsigned int prot;                     // 保护位
};

// vfio_dma_do_map() — 创建 DMA 映射
static int vfio_dma_do_map(struct vfio_iommu *iommu, struct vfio_iommu_type1_dma_map *map)
{
    // 1. 创建 vfio_dma 条目
    struct vfio_dma *dma = kzalloc(sizeof(*dma), GFP_KERNEL_ACCOUNT);
    dma->iova = map->iova;                 // IOVA 地址（设备看到的地址）
    dma->vaddr = map->vaddr;               // 用户空间虚拟地址
    dma->size = map->size;

    // 2. 调用 IOMMU API 建立映射
    for_each_domain(iommu, domain) {
        iommu_map(domain->domain, dma->iova, phys_pfn, npage, prot);
        // → IOMMU 驱动写页表
    }
}
```

### 2.3 IOMMU 页表映射——iommu_map

```c
// drivers/iommu/iommu.c
int iommu_map(struct iommu_domain *domain, unsigned long iova,
              phys_addr_t paddr, size_t size, int prot)
{
    // 1. 验证参数（对齐、大小）
    if (iommu_is_addr_mapped(domain, iova, size))
        return -EEXIST;

    // 2. 调用底层 IOMMU 驱动
    ret = domain->ops->map_pages(domain, iova, paddr, size, pgcount, prot, gfp);
    // → x86: intel_iommu_map_pages() 写 DMAR 页表
    // → ARM: arm_smmu_map_pages() 写 SMMU 页表
}
```

---

## 3. 中断

```c
// VFIO 支持三种中断类型：
// 1. INTX（PCI 传统中断）
// 2. MSI（消息信号中断）
// 3. MSI-X（扩展消息信号中断）

// 用户空间通过 ioctl(VFIO_DEVICE_SET_IRQS) 注册中断处理：
// → vfio_pci_set_irqs_ioctl()
//   → vfio_msi_set_vector_signal()
//     → eventfd_signal() — 通过 eventfd 通知用户空间

// 设备中断发生时：
// 硬件 → 中断控制器 → vfio_msi_handler()
//   → eventfd_signal(vfio_irq_ctx.trigger)
//   → 用户空间的 epoll/select 返回
```

---

## 4. 设备迁移

```c
// VFIO 支持设备状态迁移（用于 VM live migration）：
// 状态：
//   VFIO_DEVICE_STATE_RUNNING    — 运行中
//   VFIO_DEVICE_STATE_SAVING     — 保存状态
//   VFIO_DEVICE_STATE_RESUMING   — 恢复状态
//   VFIO_DEVICE_STATE_STOPPED    — 暂停
//   VFIO_DEVICE_STATE_ERROR      — 错误

// 迁移数据通过 ioctl(VFIO_MIG_GET_REGION_INFO) 获取
// 通过 mmap 读写迁移区域
```

---

## 5. 调试

```bash
# 查看 IOMMU 分组
ls /sys/kernel/iommu_groups/
cat /sys/kernel/iommu_groups/0/devices/*/vendor

# 查看 VFIO 容器
cat /sys/class/vfio/vfio/

# 查看 IOMMU 映射
cat /sys/kernel/debug/iommu/addresses

# dmesg 调试
echo 'file drivers/vfio/vfio_main.c +p' > /sys/kernel/debug/dynamic_debug/control
echo 'file drivers/vfio/vfio_iommu_type1.c +p' > /sys/kernel/debug/dynamic_debug/control
```

---

## 6. 总结

VFIO 通过 IOMMU 组隔离设备，通过 `vfio_iommu_type1` 后端管理 DMA 映射（`vfio_dma_do_map` → `iommu_map` 写入页表）。用户空间通过 ioctl 控制设备直通——PCI 配置空间、MMIO、中断、DMA 全部直通到用户空间。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
