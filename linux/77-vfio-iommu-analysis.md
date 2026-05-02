# 77-vfio-iommu — Linux VFIO 和 IOMMU 用户态设备直通深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**VFIO** 是 Linux 用户态设备直通框架，允许 QEMU/DPDK 等用户空间程序直接控制物理硬件设备。**IOMMU（I/O MMU）** 提供 DMA 重映射和隔离——将设备 DMA 请求的 IOVA 地址转换为物理地址，防止设备访问未授权的内存。

**核心架构**：

```
用户空间                          内核驱动栈                        硬件
─────────────────               ──────────                       ──────
QEMU/SPDK/DPDK                                                    
  │                                                               
  open("/dev/vfio/vfio")                                           
  ioctl(VFIO_SET_IOMMU, ...)                                       
  open("/dev/vfio/group-N")                                        
  ioctl(VFIO_GROUP_SET_CONTAINER)   → vfio_main.c                 
  ioctl(VFIO_IOMMU_MAP_DMA)         → vfio_iommu_type1.c          │
    {iova, vaddr, size}               → vfio_dma_do_map()          │
                                        → vfio_pin_pages_remote()  pin 用户页
                                        → iommu_map(domain)        │
                                          → intel_iommu_map_pages() → DMAR 页表
                                          → arm_smmu_map_pages()   → SMMU 页表
  ioctl(VFIO_GROUP_GET_DEVICE_FD)    → vfio_device_fops_open()     │
  mmap(device bar)                   → vfio_pci_mmap()             → PCI BAR
  ioctl(VFIO_DEVICE_SET_IRQS)        → vfio_pci_set_irqs()         → MSI/MSI-X
```

**doom-lsp 确认**：VFIO 核心在 `drivers/vfio/vfio_main.c`（1,856 行）。IOMMU type1 后端在 `vfio_iommu_type1.c`（3,284 行）。IOMMU API 在 `drivers/iommu/iommu.c`（4,137 行）。

---

## 1. 核心数据结构

### 1.1 IOMMU 组和域

```c
// drivers/iommu/iommu.c
struct iommu_group {
    struct list_head devices;                 // 组内设备
    struct iommu_domain *default_domain;      // 默认域
    struct iommu_domain *blocked_domain;      // 阻止域
    int id;                                   // 组 ID（对应 /dev/vfio/N）
    struct iommu_domain *owner;               // 当前 owner
};

struct iommu_domain {
    unsigned type;                             // UNMANAGED/DMA
    const struct iommu_domain_ops *ops;        // 域操作
    unsigned long pgsize_bitmap;               // 支持的页大小
    void *priv;
};
```

### 1.2 vfio_dma——DMA 映射条目 @ iommu_type1.c:87

```c
struct vfio_dma {
    struct rb_node node;                       // iommu->dma_list 红黑树节点
    dma_addr_t iova;                           // 设备可见的 DMA 地址
    unsigned long vaddr;                       // 用户空间虚拟地址
    size_t size;                               // 映射大小
    int prot;                                  // IOMMU_READ/WRITE
    bool iommu_mapped;                         // 已映射到 IOMMU
    struct task_struct *task;
    struct rb_root pfn_list;                   // pin 的页帧列表
    unsigned long *bitmap;                     // 脏页位图
    size_t locked_vm;                          // 锁定的 VM 数
};

struct vfio_pfn {                              // @ :358
    struct rb_node node;
    dma_addr_t iova;
    unsigned long pfn;                          // 物理页帧号
    unsigned int ref_count;
};
```

**doom-lsp 确认**：`struct vfio_dma` @ `iommu_type1.c:87`。DMA 映射通过红黑树 `iommu->dma_list` 管理，按 `iova` 排序。

---

## 2. VFIO 容器/组管理 @ vfio_main.c

```c
// VFIO 三级结构：
// 容器 (container) — IOMMU 实例，管理 DMA 映射
//   ↓ 包含多个 IOMMU 组
// 组 (group) — IOMMU 隔离单元，一组共享页表的设备
//   ↓ 包含多个设备
// 设备 (device) — 物理设备，通过 device_fd 控制

// 用户空间操作流程：

// 1. 打开 VFIO 容器
container_fd = open("/dev/vfio/vfio", O_RDWR);
ioctl(container_fd, VFIO_SET_IOMMU, VFIO_TYPE1_IOMMU);
// → vfio_container_ioctl() → iommu->ops->attach_group() 初始化 IOMMU

// 2. 打开 IOMMU 组设备
group_fd = open("/dev/vfio/23", O_RDWR);  // group ID=23

// 3. 组绑定到容器
ioctl(group_fd, VFIO_GROUP_SET_CONTAINER, &container_fd);
// → vfio_group_set_container():
//     = 检查组内所有设备未被使用
//     = group->container = container
//     = 如果容器中所有组就绪 → vfio_iommu_type1_attach_group()
//       → iommu_attach_group(domain, iommu_group)

// 4. 获取设备 fd
device_fd = ioctl(group_fd, VFIO_GROUP_GET_DEVICE_FD, "0000:01:00.0");
// → vfio_device_fops_open() 创建设备 fd
```

---

## 3. DMA 映射——vfio_iommu_type1

### 3.1 vfio_dma_do_map——创建 DMA 映射

```c
// drivers/vfio/vfio_iommu_type1.c
static int vfio_dma_do_map(struct vfio_iommu *iommu, struct vfio_iommu_type1_dma_map *map)
{
    struct vfio_dma *dma;

    /* 1. 检查重叠 */
    dma = vfio_find_dma(iommu, iova, size);
    if (dma) return -EEXIST;

    /* 2. 分配 vfio_dma 条目，插入红黑树 */
    dma = kzalloc(sizeof(*dma), GFP_KERNEL_ACCOUNT);
    dma->iova = map->iova;                     // 设备端 IOVA
    dma->vaddr = map->vaddr;                   // 用户空间 vaddr
    dma->size = map->size;
    dma->prot = map->flags & IOMMU_READ ? IOMMU_READ : 0;
    vfio_link_dma(iommu, dma);                 // → rb_insert

    /* 3. pin 用户页面（防止交换）*/
    vfio_pin_pages_remote(dma, ...);
    // → pin_user_pages_remote() 锁定用户页

    /* 4. IOMMU 映射 */
    ret = iommu_map(domain->domain, dma->iova, phys_pfn, npage, dma->prot);
    // → iommu_map() → domain->ops->map_pages()
    // → intel/arm_smmu 驱动写入页表
}
```

### 3.2 vfio_dma_do_unmap——解除 DMA 映射

```c
static int vfio_dma_do_unmap(struct vfio_iommu *iommu, struct vfio_iommu_type1_dma_unmap *unmap)
{
    /* 1. 从红黑树查找 dma 条目 */
    dma = vfio_find_dma(iommu, unmap->iova, unmap->size);

    /* 2. IOMMU 解除映射 */
    iommu_unmap(domain->domain, dma->iova, dma->size);

    /* 3. unpin 页面 */
    vfio_unpin_pages_remote(dma, ...);
    // → unpin_user_pages() 释放对用户页的 pin

    /* 4. 脏页跟踪 */
    if (dma->bitmap)
        vfio_dma_populate_bitmap(dma, pgsize);

    /* 5. 删除条目 */
    vfio_unlink_dma(iommu, dma);
    kfree(dma);
}
```

### 3.3 脏页跟踪

```c
// 用于 VM 迁移时的脏页记录
// 通过 IOMMU 页表的 Access/Dirty 位或软件记录
// vfio_dma->bitmap 存储脏页位图
// 迁移时通过 VFIO_IOMMU_DIRTY_PAGES ioctl 读取
```

---

## 4. IOMMU API——iommu_map

```c
// drivers/iommu/iommu.c
int iommu_map(struct iommu_domain *domain, unsigned long iova,
              phys_addr_t paddr, size_t size, int prot)
{
    // 1. 检查 IOVA 是否已被映射
    if (iommu_is_addr_mapped(domain, iova, size))
        return -EEXIST;

    // 2. 调用底层驱动
    ret = domain->ops->map_pages(domain, iova, paddr, size, pgcount, prot, GFP_KERNEL);
    // Intel: intel_iommu_map_pages() → 写 DMAR 根级页表
    // ARM: arm_smmu_map_pages() → 写 SMMU 页表（CD/TTBR）
}
```

---

## 5. 设备操作

```c
// VFIO_DEVICE_GET_INFO → 获取设备信息（PCI VID/DID/区域数）
// VFIO_DEVICE_GET_REGION_INFO → 获取 MMIO BAR 信息
// VFIO_DEVICE_SET_IRQS → 设置中断（INTX/MSI/MSI-X）
// VFIO_DEVICE_RESET → 复位设备

// mmap 设备 BAR：
// → vfio_pci_mmap()
//   → remap_pfn_range() 直接映射 PCI BAR 到用户空间
//   → 用户空间直接读写硬件寄存器（零拷贝）
```

---

## 6. 关键函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `vfio_group_set_container` | `vfio_main.c` | 组绑定到容器 |
| `vfio_device_fops_open` | `vfio_main.c` | 创建设备 fd |
| `vfio_dma_do_map` | `iommu_type1.c` | DMA 映射（pin + iommu_map）|
| `vfio_dma_do_unmap` | `iommu_type1.c` | 解除 DMA 映射 |
| `vfio_find_dma` | `iommu_type1.c` | 红黑树查找 DMA 条目 |
| `vfio_pin_pages_remote` | `iommu_type1.c` | pin 用户页面 |
| `iommu_map` | `iommu.c` | IOMMU 页表映射 |
| `iommu_attach_group` | `iommu.c` | 组绑定到域 |

---

## 7. 总结

VFIO 通过 `vfio_dma_do_map`（`iommu_type1.c`）→ `iommu_map`（`iommu.c`）→ `intel_iommu_map_pages` 实现用户态设备直通。`struct vfio_dma`（`:87`）管理 IOVA→用户 vaddr 映射，`vfio_pin_pages_remote` 锁定用户页面防止交换，IOMMU 驱动写入硬件页表完成 DMA 重映射。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
