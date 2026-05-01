# 17-page_allocator — 页分配器深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**页分配器（page allocator）** 是 Linux 内存管理的基础，负责物理页框的分配与回收。Linux 使用 **Buddy 系统**（伙伴系统）管理物理内存：将空闲页按 2^n 的幂次组织成链表，分配时拆分大块，释放时合并相邻小块。

`mm/page_alloc.c` 是内核中最大的单个源文件之一，doom-lsp 确认包含 760+ 个符号。

---

## 1. 核心数据结构

### 1.1 struct zone

```c
struct zone {
    unsigned long          watermark[NR_WMARK]; // 水位线
    long                   lowmem_reserve[MAX_NR_ZONES];
    struct pglist_data    *zone_pgdat;        // 所属的 NUMA 节点
    struct per_cpu_pageset __percpu *pageset; // Per-CPU 页缓存

    struct free_area       free_area[MAX_ORDER]; // Buddy 空闲链表

    spinlock_t             lock;              // 保护 zone 数据
    ...
};
```

### 1.2 struct free_area——Buddy 核心

```c
struct free_area {
    struct list_head    free_list[MIGRATE_TYPES]; // 按迁移类型分组
    unsigned long       nr_free;                  // 空闲页数
};
```

Buddy 系统维护 `MAX_ORDER`（通常 11，即最大 2^10=1024 页）个 `free_area`，每个管理特定大小的连续空闲页块。

### 1.3 内存域（Zone）类型

| Zone | 范围 | 用途 |
|------|------|------|
| ZONE_DMA | 0-16MB | 老设备 DMA |
| ZONE_DMA32 | 0-4GB | 32 位 DMA 设备 |
| ZONE_NORMAL | 直接映射 | 常规内存分配 |
| ZONE_HIGHMEM | >4GB（32位） | 高端内存（x86 32bit）|
| ZONE_MOVABLE | 可迁移 | 避免碎片的关键 |

---

## 2. 分配路径

### 2.1 快速路径（从 Per-CPU 页缓存获取）

```
alloc_pages(gfp_mask, order)
  │
  └─ __alloc_pages_nodemask(gfp_mask, order, preferred_nid, nodemask)
       │
       ├─ [快速路径] get_page_from_freelist()
       │    │
       │    ├─ 从 preferred_zone 开始遍历
       │    │
       │    ├─ 检查 zone 水位线
       │    │    └─ zone_watermark_fast(zone, order, mark)
       │    │
       │    ├─ 优先从 Per-CPU 页缓存获取（仅 order=0）
       │    │    └─ rmqueue_bulk() → 批量从 buddy 搬移到 pcpu
       │    │
       │    ├─ 如果水位不够 → 尝试下一个 zone
       │    │
       │    └─ 找到了 → return page
       │
       ├─ [慢速路径] __alloc_pages_slowpath()
       │    │
       │    ├─ 直接回收（direct reclaim）
       │    │    └─ try_to_free_pages() → 回收页面
       │    │
       │    ├─ 内存压缩（compaction）
       │    │    └─ compact_zone_order() → 整理碎片
       │    │
       │    ├─ 触发 OOM（如果 GFP_KERNEL 且无法回收）
       │    │    └─ out_of_memory() → 选择进程杀掉
       │    │
       │    └─ 重试分配
       │
       └─ return NULL 或 失败页
```

### 2.2 Buddy 系统的核心操作

**分配**（从 buddy 拆出所需大小的块）：

```
__rmqueue(zone, order, migratetype)
  │
  ├─ 从 free_area[order] 中取出一个块
  │
  ├─ 如果 free_area[order] 为空：
  │    └─ 到 free_area[order+1] 取一个更大块
  │    └─ 从中间分裂 → 一半放回 free_area[order]
  │    └─ 另一半返回（继续分裂，直到达到目标 order）
  │
  └─ 返回页面块
```

**释放**（合并相邻的 buddy 块）：

```
__free_one_page(page, phys_addr, order, migratetype)
  │
  ├─ 计算 buddy 地址
  │    └─ buddy_pfn = page_pfn ^ (1 << order)  ← 异或操作得到 buddy
  │
  ├─ 如果 buddy 也在 free_area[order] 中且可合并：
  │    └─ 从 free_area[order] 移除 buddy
  │    └─ order++ 合并成更大块
  │    └─ 继续尝试合并（order+1）
  │
  └─ 将合并后的块插入 free_area[order]
```

Buddy 的计算：`buddy_pfn = pfn ^ (1 << order)`——相邻块的物理地址正好在 order 位上互补。

---

## 3. 水位线与回收

每个 zone 有三条水位线：

```
  内存量 ↑
         │
  WMARK_HIGH ──── zone 空闲页充足
         │
  WMARK_LOW  ──── 开始异步回收（kswapd 唤醒）
         │
  WMARK_MIN  ──── 直接回收（调用者阻塞等待）
         │
         0         内存耗尽
```

```
分配时水位检查：
  ┌──────────────┐
  │ 水位 > HIGH  │ → 从 Per-CPU 缓存直接分配
  ├──────────────┤
  │ 水位 > LOW   │ → 走正常 buddy 分配
  ├──────────────┤
  │ 水位 > MIN   │ → 唤醒 kswapd 异步回收
  ├──────────────┤
  │ 水位 < MIN   │ → 直接回收（direct reclaim）
  ├──────────────┤
  │ 无法回收     │ → 触发 OOM
  └──────────────┘
```

---

## 4. Per-CPU 页缓存

对于 order=0 的单页分配（最频繁的路径），页分配器使用 per-CPU 缓存避免锁竞争：

```c
struct per_cpu_pages {
    int count;             // 缓存中的页数
    int high;              // 高水位（触发批量填充）
    int batch;             // 批量填充/释放的页数
    struct list_head lists[MIGRATE_PCPTYPES]; // 按迁移类型
};
```

分配时从本地 CPU 缓存取——不需要加 `zone->lock`，显著提升性能。

---

## 5. 迁移类型（MIGRATE_TYPES）

Buddy 系统的每个 free_list 按迁移类型进一步细分：

| 类型 | 用途 |
|------|------|
| MIGRATE_UNMOVABLE | 不可移动的页（内核分配）|
| MIGRATE_MOVABLE | 可移动的页（用户空间）|
| MIGRATE_RECLAIMABLE | 可回收的页（dcache）|
| MIGRATE_PCPTYPES | Per-CPU 类型 |
| MIGRATE_CMA | CMA 区域 |
| MIGRATE_ISOLATE | 临时隔离 |

通过按迁移类型分组，**碎片整理的效率大幅提升**：可移动的页面可以被迁移从而合并出更大的连续块。

---

## 6. 数据流全景

```
alloc_pages(GFP_KERNEL, 0)    ← 分配 1 页（最常用）
  │
  ├─ fast path:
  │    └─ rmqueue() → 从 PCU 缓存取 → return
  │
  ├─ slow path:
  │    ├─ 从 buddy 拆 → return
  │    └─ 缺页 → kswapd/direct reclaim → OOM

free_pages(page, 0)           ← 释放 1 页
  │
  ├─ 放回 Per-CPU 缓存
  │    └─ 如果缓存超限 → 批量清回 buddy
  │
  └─ buddy 合并 → free_area[order+n]
```

---

## 7. 设计决策总结

| 决策 | 原因 |
|------|------|
| Buddy 系统 | 快速合并/分裂，O(log n) 复杂度 |
| Per-CPU 缓存 | 避免 zone->lock 竞争 |
| 按迁移类型分组 | 减少内存碎片 |
| 水位线 + kswapd | 异步回收，避免分配阻塞 |
| MAX_ORDER=11 | 最大连续块 4MB（1024页×4KB）|

---

## 8. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/mmzone.h` | `struct zone` / `struct free_area` | 结构定义 |
| `mm/page_alloc.c` | `__alloc_pages_nodemask` | 分配主入口 |
| `mm/page_alloc.c` | `__rmqueue` | Buddy 分配 |
| `mm/page_alloc.c` | `__free_one_page` | Buddy 释放/合并 |
| `mm/page_alloc.c` | `zone_watermark_fast` | 水位检查 |

---

## 9. 关联文章

- **VMA**（article 16）：缺页时从 page allocator 获取物理页
- **slab allocator**（article 36）：从 page allocator 获取 slab 页框
- **vmalloc**（article 38）：从 page allocator 获取物理页再建立映射

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
