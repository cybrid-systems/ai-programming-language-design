# 38-vmalloc — 虚拟地址连续内存分配深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**vmalloc** 分配**虚拟地址连续、物理地址可能不连续**的内存区域。与 kmalloc（物理连续，小对象）不同，vmalloc 用于大块内存分配（> 1MB），物理页可以分散在内存各处。

---

## 1. 核心流程

```
vmalloc(size)
  │
  ├─ __vmalloc_node(size, 1, GFP_KERNEL, node)
  │    │
  │    ├─ 计算需要的页面数
  │    │
  │    ├─ 分配虚拟地址区间
  │    │    └─ __get_vm_area_node(size, ...)
  │    │         └─ 从 vmalloc 虚拟地址空间分配区间
  │    │
  │    ├─ 分配物理页
  │    │    └─ __vmalloc_area_node(area, gfp_mask, node)
  │    │         ├─ 逐页 alloc_page()
  │    │         └─ map_vm_area(area, prot, pages)
  │    │              └─ 建立页表映射（物理页 → 虚拟页）
  │    │
  │    └─ return area->addr
```

---

## 2. 关键区别

| 特性 | kmalloc | vmalloc |
|------|---------|---------|
| 物理连续 | ✅ | ❌ |
| 分配大小 | ≤ 4MB | 任意 |
| 速度 | 快 | 慢（需建页表）|
| 适用场景 | 小对象、DMA | 大缓冲区、模块加载 |

---

*分析工具：doom-lsp（clangd LSP）*
