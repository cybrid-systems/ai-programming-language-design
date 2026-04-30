# 203-dma_mapping — DMA映射深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/dma-mapping.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**DMA Mapping** 将内存页映射到设备可直接访问的地址，用于外设 DMA 传输。

---

## 1. DMA API

```c
// 分配 DMA 一致性内存：
void *dma_alloc_coherent(dev, size, &dma_handle, GFP_KERNEL);
void dma_free_coherent(dev, size, cpu_addr, dma_handle);

// 流式 DMA（临时映射）：
void *dma_map_page(dev, page, offset, size, direction);
void dma_unmap_page(dev, dma_handle, size, direction);
```

---

## 2. DMA direction

```c
DMA_TO_DEVICE   — 数据从内存到设备
DMA_FROM_DEVICE — 数据从设备到内存
DMA_BIDIRECTIONAL — 双向
DMA_NONE       — 仅用于调试
```

---

## 3. 西游记类喻

**DMA Mapping** 就像"天庭的货运通道"——

> DMA mapping 像给设备开设专属货运通道（DMA 地址）。一致性分配（dma_alloc_coherent）像长期租用的专用仓库，设备随时可访问。流式映射（dma_map_page）像临时通行证，设备用完要还回来。

---

## 4. 关联文章

- **PCI**（article 116）：PCI 设备使用 DMA
- **mmu_notifier**（article 161）：DMA 需 mmu_notifier 跟踪