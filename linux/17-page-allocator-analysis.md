# 17-page_allocator — 页分配器深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**页分配器（page allocator）** 管理物理内存的分配与回收，使用 **Buddy 系统**（伙伴系统）：将空闲页按 2^n 的幂次组织成链表，分配时拆分大块，释放时合并相邻小块。

doom-lsp 确认 `mm/page_alloc.c` 包含约 760 个符号。

---

## 1. 核心结构

### 1.1 struct zone

```c
struct zone {
    unsigned long          watermark[NR_WMARK]; // 水位线
    struct free_area       free_area[MAX_ORDER]; // Buddy 空闲链表
    spinlock_t             lock;
    struct per_cpu_pageset __percpu *pageset;    // Per-CPU 缓存
    struct pglist_data    *zone_pgdat;           // 所属 NUMA 节点
};
```

### 1.2 Buddy 系统

```c
struct free_area {
    struct list_head free_list[MIGRATE_TYPES]; // 按迁移类型分组
    unsigned long    nr_free;                  // 空闲块数
};
```

`MAX_ORDER` = 11（最大的连续块 = 2^10 = 1024 页 = 4MB）。

---

## 2. 分配路径

```
__alloc_pages_nodemask(gfp_mask, order, preferred_nid)
  │
  ├─ [快速路径] get_page_from_freelist()
  │    ├─ 从 Per-CPU 缓存拿（仅 order=0）
  │    └─ 从 free_area[order] 取一块
  │
  ├─ [慢速路径] __alloc_pages_slowpath()
  │    ├─ 唤醒 kswapd 回收
  │    ├─ 直接回收（direct reclaim）
  │    ├─ 内存压缩（compaction）
  │    └─ OOM killer（最后手段）
```

### 2.1 Buddy 分配原理

```
__rmqueue(zone, order)
  │
  ├─ 从 free_area[order] 取
  ├─ 如果为空 → 从 free_area[order+1] 借
  │    └─ 切成两块（buddy 分裂）
  │    └─ 一半放回 free_area[order]
  │    └─ 另一半返回
  └─ 返回页面块
```

### 2.2 Buddy 释放原理

```
__free_one_page(page, pfn, order)
  │
  ├─ 计算 buddy：buddy_pfn = pfn ^ (1 << order)
  ├─ 如果 buddy 在 free_area[order] 且可合并
  │    └─ 移除 buddy，order++，继续尝试合并
  └─ 插入 free_area[order]
```

---

## 3. Per-CPU 页缓存

对于 order=0 的最常见分配，Per-CPU 缓存避免竞争 zone->lock：

```c
struct per_cpu_pages {
    int count;              // 缓存中页数
    int high;               // 触发批量填充的水位
    int batch;              // 批量填充数
};
```

分配：从本地 CPU 缓存直接拿，不需加锁。

---

## 4. 设计决策总结

| 决策 | 原因 |
|------|------|
| Buddy 系统 | O(log n) 分裂/合并 |
| Per-CPU 缓存 | 避免锁竞争 |
| 按迁移类型分组 | 减少碎片 |
| 水位线+kswapd | 异步回收 |

---

## 5. 源码文件索引

| 文件 | 关键符号 |
|------|---------|
| `mm/page_alloc.c` | `__alloc_pages_nodemask` / `__rmqueue` / `__free_one_page` |
| `include/linux/mmzone.h` | `struct zone` / `struct free_area` |

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
