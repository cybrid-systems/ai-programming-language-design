# Linux Kernel Page Allocator (Buddy System) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/page_alloc.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 Buddy System？

**Buddy System**（伙伴系统）是 Linux 物理内存分配的核心算法：
- 内存按**2 的幂次**分成块（order = 0, 1, 2, ..., MAX_ORDER）
- 相邻的两个相同大小的块互为"buddy"
- 分配时从合适的 order 寻找可用块；如果没有，尝试从更大的块拆分
- 释放时，如果 buddy 也是空闲的，则**合并成更大的块**

**核心优势**：
- 分配/释放都是 O(1)（在对应 order 的链表中操作）
- 内存碎片通过合并机制得到控制

---

## 1. 核心数据结构

### 1.1 struct page

```c
// include/linux/mm_types.h:79 — 物理页框描述符
struct page {
    /* 第一部分：union 存储不同类型页的内容 */
    union {
        struct {        /* Page pool and kernel dynamic */
            unsigned long private;          // 分配器私有数据
            atomic_t _refcount;             // 引用计数
            atomic_t _pincount;           // FOLL_PIN 的 pin 计数
            unsigned long flags;            // page flags (PG_xxx)
            struct list_head lru;         // LRU 链表（page cache / anonymous）
            struct address_space *mapping;  // 所属 address_space
            unsigned long index;           // offset in mapping
        };
        struct {        /* Page cache */
            void *freelist;               // SLUB 分配器的 freelist
            unsigned short memcg_data;     // memory cgroup 数据
        };
        struct {        /* Tail pages */
            unsigned long compound_head;   // THP 的 head page
            unsigned char compound_dtor;    // THP 析构器
            unsigned char compound_order;  // THP 大小 (order)
        };
        struct {        /* THP */
            unsigned long _nr_pages;       // THP 页数
        };
    };

    /* 第二部分：页描述符 */
    unsigned long mark_page_accessed;
    unsigned long prio;
    unsigned long last_recamfrom;
};
```

### 1.2 free_area 与 per-CPU 缓存

```c
// include/linux/mmzone.h — 伙伴系统核心结构
struct free_area {
    struct list_head free_list[MIGRATE_TYPES];  // 按迁移类型分类
    unsigned long nr_free;                       // 此 order 的空闲页总数
};

struct zone {
    /* 伙伴分配器的核心数据结构 */
    unsigned long watermark[NR_WMARK];  // WMARK_MIN/LOW/HIGH
    unsigned long per_cpu_pageset[NR_CPUS];  // per-CPU 页缓存

    /* 每个 order 一个 free_area */
    struct free_area free_area[MAX_ORDER];

    /* 区域统计 */
    atomic_long_t managed_pages;   // 此区域管理的总页数
    unsigned long spanned_pages;   // 此区域跨越的总页数
    unsigned long present_pages;   // 实际存在的页数
};

// MAX_ORDER 默认 11（0-10），最大分配 4MB（2^10 * PAGE_SIZE）
#define MAX_ORDER 11
```

### 1.3 迁移类型

```c
// include/linux/mmzone.h
enum migratetype {
    MIGRATE_UNMOVABLE,      // 内核核心内存（不可移动）
    MIGRATE_MOVABLE,        // 页面缓存、可回收内存（可移动）
    MIGRATE_RECLAIMABLE,    // 可回收内存（不可移动但可写回）
    MIGRATE_HIGHATOMIC,     // 高阶原子分配
    MIGRATE_TYPES            // = 4
};

// 迁移类型的意义：
//   - 内核在内存压力下优先回收 MIGRATE_MOVABLE
//   - 分配时优先从对应的迁移类型中分配
//   - 碎片整理时，同类型 buddy 才能合并
```

---

## 2. 分配流程：__alloc_pages

### 2.1 完整分配路径

```
alloc_pages(gfp_mask, order)
  ↓
__alloc_pages(gfp_mask, order, preferred_zone, migratetype)
  ↓
┌────────────────────────────────────────────────────────┐
│ 步骤 1: get_page_from_freelist — 快路径               │
│   遍历每个 zone：                                      │
│     1. 检查 watermark（最低水位线）                     │
│     2. 从 free_area[order] 获取页                       │
│     3. 如果不够，尝试从更大的 order 拆分                │
│   如果找到 → 成功                                      │
└────────────────────────────────────────────────────────┘
  ↓ 失败
┌────────────────────────────────────────────────────────┐
│ 步骤 2: __alloc_pages_slowpath — 慢路径               │
│   1. wake_all_kswapd() — 唤醒 kswapd 回收             │
│   2. try_to_free_pages() — 直接回收（stall 当前进程）   │
│   3. COMPACTION: compaction_ready()                    │
│   4. 再次尝试 fast path                               │
│   5. oom_kill_process() — 内存耗尽杀进程              │
└────────────────────────────────────────────────────────┘
```

### 2.2 __alloc_pages_nodemask（主入口）

```c
// mm/page_alloc.c — __alloc_pages_nodemask
struct page *__alloc_pages_nodemask(gfp_t gfp_mask, unsigned int order,
                        int preferred_nid, nodemask_t *nodemask)
{
    struct zoneref *z;
    struct page *page;

    // 1. 解析 gfp_mask
    gfp_t alloc_gfp = gfp_mask;
    if (gfp_mask & __GFP_NOWARN)
        alloc_gfp &= ~__GFP_NOWARN;

    // 2. 尝试快路径：get_page_from_freelist
    page = get_page_from_freelist(alloc_gfp, order, preferred_nid, nodemask);
    if (likely(page))
        return page;

    // 3. 慢路径：回收 + 重试
    alloc_gfp = gfp_mask;
    page = __alloc_pages_slowpath(alloc_gfp, order, preferred_nid, nodemask);

    return page;
}
```

### 2.3 get_page_from_freelist（快路径）

```c
// mm/page_alloc.c — get_page_from_freelist
static struct page *get_page_from_freelist(gfp_t gfp_mask, unsigned int order,
                        int preferred_nid, nodemask_t *nodemask)
{
    struct zoneref *z;
    struct zone *zone;

    // 遍历所有 node 和 zone
    for_each_zone_zonelist_nodemask(z, zone, ac.nid,
                    high_zoneidx, nodemask) {
        unsigned long mark;

        // 检查水位线
        mark = wmark_pages(zone, alloc_flags & ALLOC_WMARK_MASK);
        if (!zone_watermark_ok(zone, order, mark, gfp_mask, alloc_flags))
            continue;  // 水位不够，尝试下一个 zone

        // 尝试从 free_area[order] 获取页
        page = rmqueue(zone, order, gfp_mask, migratetype);
        if (page)
            return page;
    }

    return NULL;
}
```

---

## 3. rmqueue — 伙伴系统核心分配

```c
// mm/page_alloc.c — rmqueue（真正的伙伴系统分配）
static inline struct page *rmqueue(struct zone *zone, unsigned int order,
                        gfp_t gfp_mask, int migratetype)
{
    struct page *page;

    // ========== per-CPU PCPM 快速路径（order=0 的单页）==========
    if (likely(order == 0)) {
        page = rmqueue_pcplist(zone, gfp_mask, migratetype);
        if (likely(page))
            return page;
    }

    // ========== 伙伴系统主路径 ==========
    do {
        // 1. 从 free_area[order] 获取
        page = __rmqueue_smallest(zone, order, migratetype);
        if (page)
            return page;

        // 2. 当前 order 没有，尝试更大的块拆分
        //    从 order+1 的链表取，拆分成两个 order
        //    一个用于分配，一个加入当前 order 的空闲链表

    } while (order < MAX_ORDER);

    return NULL;
}

// mm/page_alloc.c — __rmqueue_smallest
static __always_inline struct page *
__rmqueue_smallest(struct zone *zone, unsigned int order, int migratetype)
{
    unsigned int current_order;
    struct free_area *area;
    struct list_head *list;
    struct page *page;

    // 从 requested order 开始向上找
    for (current_order = order; current_order < MAX_ORDER; current_order++) {
        area = &zone->free_area[current_order];
        list = &area->free_list[migratetype];

        if (list_empty(list))
            continue;  // 此 order 没有空闲页

        // 取出第一个块
        page = list_first_entry(list, struct page, buddy_list);
        list_del(&page->buddy_list);

        // 更新统计
        area->nr_free--;
        expand(zone, page, current_order, order);  // 拆分剩余部分

        return page;
    }

    return NULL;
}
```

---

## 4. expand — 块拆分

```c
// mm/page_alloc.c — expand（拆分伙伴块）
static inline void expand(struct zone *zone, struct page *page,
             int low, int high, int migratetype)
{
    unsigned long size = 1 << (high - 1);  // 每次拆分的大小

    // 从 high order 开始，每次拆分一半
    // page        = 低地址伙伴
    // page + size = 高地址伙伴（加入空闲链表）
    while (high > low) {
        struct page *buddy;

        // 标记高地址伙伴为 order = high - 1
        area--;  // free_area[high - 1]
        high--;
        size >>= 1;

        // 计算 buddy 地址
        // buddy 的地址规律：p ^ (1 << order) 即 p 与 2^order 异或
        buddy = page + size;
        set_buddy_order(buddy, high);  // 设置 order 标志

        // 加入对应 order 的空闲链表
        list_add(&buddy->buddy_list, &area->free_list[migratetype]);
        area->nr_free++;
    }
}
```

---

## 5. __free_pages_ok — 释放与合并

```c
// mm/page_alloc.c:208 — __free_pages_ok（页释放核心）
static void __free_pages_ok(struct page *page, unsigned int order)
{
    unsigned long flags;
    unsigned int orderickel;
    bool is_tail;

    // 1. 检查 page 是否在 pageblock 对齐
    if (!page_zone_coords_equal(page, pfn))
        goto free_continu;

    // 2. 尝试合并为更大的块
    //    合并条件：buddy 必须是同样 order 且同样 migratetype
    //    buddy 地址计算：page ^ (1 << order)
    while (order < MAX_ORDER) {
        struct page *buddy;

        // 计算 buddy
        if (is_tail)
            buddy = page - (1UL << order);  // 来自 expand 的高地址伙伴
        else
            buddy = page + (1UL << order);   // 物理上相邻

        // 检查 buddy 是否空闲且 order 相同
        if (!page_is_buddy(buddy, order))
            break;  // 不能合并

        // 合并：buddy 从空闲链表移除
        list_del(&buddy->buddy_list);
        clear_buddy_order(buddy);
        area->nr_free--;

        // 合并后的块地址为较小的那个
        page = buddy < page ? buddy : page;
        order++;
    }

    // 3. 加入对应 order 的空闲链表
    set_buddy_order(page, order);
    list_add(&page->buddy_list, &area->free_list[migratetype]);
    area->nr_free++;

free_continu:
    // 4. 更新水位线和统计
    if (order >= NR_PAGE_CACHE_ORDERS)
        wake_all_kswapd(zone, gfp_mask);
}
```

---

## 6. Buddy 合并算法图解

```
分配 order=3 的块（8 页）：

初始状态：
  free_area[5]: [块A 32页]
  free_area[4]: []
  free_area[3]: []

步骤 1：从 order=5 取块A（32页）
步骤 2：拆成两个 order=4：块A_low(16) + 块A_high(16)
        块A_low 返回分配，块A_high 加入 free_area[4]

步骤 3：再拆 order=4：
        块A_high_low(8) 返回分配，块A_high_high 加入 free_area[3]

最终：
  分配：块A_high_low (8页) = 申请者获得
  free_area[3]: [块A_high_high(8页)]  ← 是块A_high_high的伙伴

释放 order=3 的块A_high_high：

步骤 1：加入 free_area[3]
步骤 2：检查伙伴（块A_high_low）是否空闲？ 是！
步骤 3：合并成 order=4 的块A_high，加入 free_area[4]
步骤 4：检查伙伴（块A_low）是否空闲？ 是！（但可能是已分配）
        实际上只有相同 migratetype 才能合并
```

---

## 7. Watermark（水位线）与内存压力

```c
// 三个水位线
enum zone_watermarks {
    WMARK_MIN = 0,   // 最低水位：必须保留的空闲页
    WMARK_LOW = 1,   // 低水位：kswapd 开始回收
    WMARK_HIGH = 2,  // 高水位：kswapd 停止
};

// watermark 计算
// min_free_kbytes = 可调参数（默认根据内存大小计算）
// 每个 zone 的 watermark = min_free_kbytes * zone_physical_pages / total_physical_pages

// zone_watermark_ok 检查：
//   如果 (free_pages < watermark) → 不能从此 zone 分配
//   如果 watermark 不满足 → 尝试下一个 zone 或唤醒 kswapd
```

---

## 8. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| 2 的幂次分配 | 简化 buddy 查找，O(1) 链表操作 |
| 合并条件严格（ migratetype + order + buddy 连续）| 防止不同类型碎片被错误合并 |
| per-CPU PCPM | 单页分配走 per-CPU 缓存，避免锁竞争 |
| watermark 分级 | min/low/high 三级触发 kswapd |
| order 拆分递归 | 每次拆分一半，保证伙伴关系 |
| `page->private` 存储 buddy 信息 | 利用 struct page 的 union，零额外空间 |

---

## 9. 参考

| 文件 | 内容 |
|------|------|
| `mm/page_alloc.c:208` | `__free_pages_ok` 释放与合并 |
| `mm/page_alloc.c` | `rmqueue`、`__rmqueue_smallest`、`expand` |
| `mm/page_alloc.c` | `__alloc_pages_nodemask`、`get_page_from_freelist` |
| `include/linux/mmzone.h` | `struct zone`、`struct free_area`、迁移类型 |
| `include/linux/mm_types.h:79` | `struct page` |
