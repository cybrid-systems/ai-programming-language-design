# 213-VFIO_iommu — VFIO/IOMMU深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/vfio/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**VFIO** 是用户空间设备访问框架，配合 IOMMU 实现安全的设备直通（PCI passthrough）。

---

## 1. VFIO

```c
// VFIO API：
// 打开 IOMMU 组：
fd = open("/dev/vfio/vfio", O_RDWR);

// 获取 IOMMU info：
ioctl(fd, VFIO_GET_INFO_IOMMU, &info);

// 将设备添加到组：
ioctl(fd, VFIO_DEVICE_ATTACH, &device_info);

// 读取 BAR：
ioctl(fd, VFIO_DEVICE_GET_REGION_INFO, &region);
```

---

## 2. IOMMU

```
VFIO + IOMMU：
  - IOMMU 将设备 DMA 地址映射到物理地址
  - 防止设备访问越界内存
  - 支持 PCI passthrough（设备直通虚拟机）
```

---

## 3. 西游记类喻

**VFIO/IOMMU** 就像"天庭的镖局担保"——

> VFIO/IOMMU 像镖局的担保系统——每个镖车（设备 DMA）都要在镖局（IOMMU）登记，镖局担保只有登记过的镖车才能进出。没有担保的镖车可能走错路、进入不该进的地方（安全隔离）。

---

## 4. 关联文章

- **PCI**（article 116）：VFIO 用于 PCI 设备
- **KVM**（相关）：VFIO 用于虚拟机设备直通