# 191-memory_compaction — 内存紧缩深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/compaction.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Memory Compaction** 将物理页移动到一起，解决内存碎片化，特别是 THP 和 CMA 需要连续大块物理内存的场景。

---

## 1. 内存碎片化

```
内存碎片化：
  物理内存分配：
    alloc_pages(2MB) ← 需要连续 2MB
    但内存中散布着小的空闲碎片
    → 分配失败

compaction：
  将已分配的页从一端移动到另一端
  留下连续的空闲区域
  → 可再次分配大块内存
```

---

## 2. compaction

```c
// mm/compaction.c — compact_node
// 1. isolate_migratepages — 从低端扫描已分配页
// 2. migrate_pages — 移动页到高端
// 3. 低端留下连续空闲区域

void compact_node(int nid)
{
    struct zone *zone = &NODE_DATA(nid)->node_zones[ZONE_NORMAL];

    compact_zone(zone, &cc);
}

static void compact_zone(struct zone *zone, struct compact_control *cc)
{
    // 低端扫描
    low_pfn = zone->compact_init_pfn;
    high_pfn = zone->compact_capture_pfn;

    while (low_pfn < high_pfn) {
        // isolate_migratepages(low_pfn)
        // migrate_pages()
    }
}
```

---

## 3. CMA（Contiguous Memory Allocator）

```
CMA 区域：
  预留给设备驱动的大块连续内存
  平时由进程使用
  设备需要时，compaction 移动页，释放 CMA

// 查看 CMA 区域：
cat /proc/buddyinfo
```

---

## 4. 西游记类喻

**Memory Compaction** 就像"天庭的仓库整理"——

> 天庭的仓库（物理内存）用久了，各种货物（页）散布在各个角落，找不到一块连续的大空地放大型设备（THP 分配）。compaction 像仓库整理员，把所有货物往一边推，整理出连续的空地区域。虽然整理时仓库（CPU）要暂停工作（内存迁移期间），但整理完后，大型设备就能放进来了。

---

## 5. 关联文章

- **THP**（article 189）：compaction 支持 THP 分配
- **page_allocator**（article 17）：compaction 优化 buddy system