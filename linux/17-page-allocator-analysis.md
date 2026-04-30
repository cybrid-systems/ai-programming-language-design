# page allocator — Buddy 系统分配器深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/page_alloc.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Buddy Allocator** 是 Linux 物理页分配的核心算法：
- 分配 2^order 个连续物理页
- 释放时尝试合并相邻的伙伴（buddy）
- O(log n) 时间复杂度

---

## 1. 核心数据结构

### 1.1 free_area — 每阶的空闲页链表

```c
// include/linux/mmzone.h — free_area
struct free_area {
    struct list_head        free_list[MIGRATE_TYPES]; // 按迁移类型分组
    unsigned long           nr_free;                    // 空闲页总数
};

#define MAX_ORDER 11  // 最大阶数（每阶 4KB * 2^order）

// per-node per-zone 结构：
struct zone {
    struct free_area        free_area[MAX_ORDER]; // free_area[0-10]
    unsigned long           watermark[NR_WATERMARK]; // 水位线
    // ...
};
```

### 1.2 空闲链表数组

```
zone->free_area[0].free_list  → 2^0 = 1 页的空闲块
zone->free_area[1].free_list  → 2^1 = 2 页的空闲块
zone->free_area[2].free_list  → 2^2 = 4 页的空闲块
...
zone->free_area[10].free_list → 2^10 = 1024 页的空闲块
```

---

## 2. 分配算法（buddy）

### 2.1 __rmqueue — 从 Buddy 分配

```c
// mm/page_alloc.c — __rmqueue
static struct page *__rmqueue(struct zone *zone, unsigned int order)
{
    // 1. 从 requested_order 开始查找
    for (current_order = order; current_order < MAX_ORDER; current_order++) {
        // 查找空闲块
        page = list_first_entry_or_null(
            &zone->free_area[current_order].free_list[migratetype],
            struct page, lru);

        if (!page)
            continue;

        // 找到：从链表移除
        list_del(&page->lru);
        zone->free_area[current_order].nr_free--;

        // 2. 拆分：如果分配的阶 > 需求，拆分
        expand(zone, page, current_order, order, migratetype);

        return page;
    }
    return NULL;
}
```

### 2.2 expand — 拆分

```c
// mm/page_alloc.c — expand
static inline void expand(struct zone *zone, struct page *page,
             int low, int high, unsigned int order, int migratetype)
{
    size_t size = 1 << high;  // 当前块大小

    while (high > order) {
        high--;                  // 降阶
        size >>= 1;               // 大小减半

        // 拆出的"伙伴"加入低一阶的空闲链表
        buddy = page + size;
        list_add(&buddy->lru, &zone->free_area[high].free_list[migratetype]);
        zone->free_area[high].nr_free++;
    }
}
```

---

## 3. 释放算法（合并）

### 3.1 buddy 算法

```
释放页 P（order=n）：
    while (n < MAX_ORDER-1):
        buddy = page ^ (1 << n)  // 伙伴 = P + 2^n 或 P - 2^n
        if (伙伴在相同阶且空闲):
            // 合并
            remove from free_list
            page = min(page, buddy)
            n++
        else:
            break

    // 加入 free_list[n]
    add to free_area[n].free_list
```

---

## 4. 水位线（Watermark）

```c
// include/linux/mmzone.h — watermark
enum watermark {
    WMARK_MIN = 0,   // 低水位
    WMARK_LOW = 1,   // 中水位
    WMARK_HIGH = 2,   // 高水位
};

// 分配前检查：
if (!zone_watermark_ok(zone, order, watermark, ...))
    // 需要回收或等待
```

---

## 5. 完整文件索引

| 文件 | 函数 |
|------|------|
| `mm/page_alloc.c` | `__rmqueue`、`expand`、`__free_pages`、`zone_watermark_ok` |
| `include/linux/mmzone.h` | `struct free_area`、`struct zone` |
