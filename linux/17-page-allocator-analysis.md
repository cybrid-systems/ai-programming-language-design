# 17-page_allocator — Buddy System 物理页分配器深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/page_alloc.c` + `include/linux/mmzone.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Buddy System** 是 Linux 物理页分配的核心算法：
- 分配 2^order 个连续物理页
- 释放时尝试合并相邻的"伙伴"（buddy）
- O(log n) 时间复杂度

---

## 1. 核心数据结构

### 1.1 free_area — 每阶的空闲页链表

```c
// include/linux/mmzone.h — free_area
struct free_area {
    struct list_head        free_list[MIGRATE_TYPES]; // 按迁移类型分组
    unsigned long           nr_free;                 // 空闲页总数
};

#define MAX_ORDER 11  // 最大阶数（2^11 * PAGE_SIZE = 8MB on 4KB page）

// per-node per-zone 结构：
struct zone {
    struct free_area        free_area[MAX_ORDER]; // free_area[0-10]
    //   free_area[0] → 2^0 = 1 页的空闲块
    //   free_area[1] → 2^1 = 2 页的空闲块
    //   free_area[10] → 2^10 = 1024 页的空闲块

    unsigned long           watermark[NR_WATERMARK]; // 水位线
};

// 页大小（4KB）：
//   order=0:  4KB
//   order=1:  8KB
//   order=2: 16KB
//   ...
//   order=10: 4MB（单个最大分配）
```

### 1.2 watermark — 水位线

```c
// include/linux/mmzone.h — watermark
enum watermark {
    WMARK_MIN = 0,   // 低水位
    WMARK_LOW = 1,   // 中水位
    WMARK_HIGH = 2,  // 高水位
};

// 分配前检查：
if (!zone_watermark_ok(zone, order, watermark, ...))
    // 需要回收或等待
```

---

## 2. 分配算法（__rmqueue）

### 2.1 __rmqueue — 核心分配

```c
// mm/page_alloc.c — __rmqueue
static struct page *__rmqueue(struct zone *zone, unsigned int order,
                             int migratetype)
{
    // 1. 从 requested_order 开始查找
    for (current_order = order; current_order < MAX_ORDER; current_order++) {
        // 查找空闲块
        struct page *page;
        page = list_first_entry_or_null(
            &zone->free_area[current_order].free_list[migratetype],
            struct page, lru);

        if (!page)
            continue;  // 本阶没有，找更大的阶

        // 找到：从链表移除
        list_del(&page->lru);
        zone->free_area[current_order].nr_free--;

        // 2. 拆分（expand）：如果分配的阶 > 需求，拆分
        expand(zone, page, current_order, order, migratetype);

        return page;
    }
    return NULL;  // 分配失败
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
        struct page *buddy = page + size;
        list_add(&buddy->lru, &zone->free_area[high].free_list[migratetype]);
        zone->free_area[high].nr_free++;
    }
}
```

---

## 3. 释放算法（合并）

### 3.1 __free_pages — 释放页

```c
// mm/page_alloc.c — __free_pages
void __free_pages(struct page *page, unsigned int order)
{
    // 合并流程：
    while (order < MAX_ORDER-1) {
        // 计算伙伴地址：
        //   如果 page 是第 order 阶块的起始，buddy = page ^ (1 << order)
        unsigned long buddy_pfn = page_to_pfn(page) ^ (1 << order);
        struct page *buddy = page + (buddy_pfn - page_to_pfn(page));

        // 检查伙伴是否：
        //   1. 在同一个 zone
        //   2. 是同一阶（order）
        //   3. 是空闲的
        if (!page_is_buddy(page, buddy, order))
            break;  // 不能合并

        // 合并
        list_del(&buddy->lru);
        zone->free_area[order].nr_free--;

        // 上升到更大的块
        page = buddy;
        order++;
    }

    // 加入对应阶的空闲链表
    list_add(&page->lru, &zone->free_area[order].free_list);
    zone->free_area[order].nr_free++;
}
```

### 3.2 伙伴地址计算

```c
// 伙伴地址公式：
//   如果两个块大小都是 2^order
//   且物理地址连续
//   则它们的地址 XOR 2^order 会得到对方

// 例如（4KB 页）：
//   block A at PFN 0x100, block B at PFN 0x101
//   0x100 ^ 0x1 = 0x101  ✓（是伙伴）
//   0x100 ^ 0x2 = 0x102  ✗（不是伙伴）
```

---

## 4. 迁移类型（MIGRATE_TYPES）

```c
// include/linux/mmzone.h
enum migratetype {
    MIGRATE_UNMOVABLE,     // 内核分配（不可移动）
    MIGRATE_MOVABLE,       // 用户页（可移动）
    MIGRATE_RECLAIMABLE,   // 可回收的页
    MIGRATE_HIGHATOMIC,    // 高优先级原子分配
    MIGRATE_CMA,           // CMA（连续内存分配区）
    MIGRATE_ISOLATE,       // 隔离（测试用）
};

// 分配时优先从相同类型中分配，减少碎片
// 高阶分配（如 order>=3）会fallback到其他类型
```

---

## 5. 水位线和内存回收

### 5.1 zone_watermark_ok

```c
// mm/page_alloc.c — zone_watermark_ok
bool zone_watermark_ok(struct zone *zone, unsigned int order,
                      unsigned long mark, int classzone_idx, int migratetype)
{
    // 检查 zone 是否有足够的空闲页

    // 计算 watermark：
    //   watermark[WMARK_MIN] = min_free_kbytes（最小空闲）
    //   watermark[WMARK_LOW = watermark[MIN] * 125%
    //   watermark[WMARK_HIGH = watermark[MIN] * 150%

    // 如果空闲页低于低水位：
    //   触发 kswapd 异步回收
    // 如果低于最小水位：
    //   触发直接回收（direct reclaim）
}
```

---

## 6. 内存布局图

```
Buddy System 分配示例（4KB 页，order=3，即分配 2^3=8页）：

分配 request: order=3 (8 pages)

step 1: free_area[3] 有块吗？
  └─ No → step 2

step 2: free_area[4] 有块吗？
  └─ Yes（split）→ expand:
      - 把 16 页块分成两个 8 页块
      - 返回第一个 8 页块给用户
      - 第二个 8 页块加入 free_area[3]

释放时：如果伙伴空闲，合并成更大的块
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `mm/page_alloc.c` | `__rmqueue`、`expand`、`__free_pages` |
| `mm/page_alloc.c` | `zone_watermark_ok` |
| `include/linux/mmzone.h` | `struct free_area`、`struct zone` |
| `include/linux/mmzone.h` | `enum migratetype`、`enum watermark` |

---

## 8. 西游记类比

**Buddy System** 就像"天兵天将的营房分配"——

> 天兵天将的营地有大小不同的营房（2^0=1人、2^1=2人、2^2=4人……2^10=1024人）。要分配 8 个人（order=3），先看 8 人营房（free_area[3]）有没有空位。有就住进去；没有就看 16 人营房（free_area[4]），有的话分成两个 8 人营房，多出来的那个放到 8 人营房队列里。退营时，如果相邻的两个 8 人营房都空着，就合并成一个 16 人营房（这就是"buddy"的含义）。但合并只能往上合并，不能往下分。如果整个营地的空位低于警戒线（watermark），就要叫后勤（kswapd）去催促进攻的队伍腾地方。

---

## 9. 关联文章

- **slab allocator**（article 36）：基于 page allocator 的对象分配器
- **vmalloc**（article 38）：使用 page allocator 的物理页构建虚拟连续区域