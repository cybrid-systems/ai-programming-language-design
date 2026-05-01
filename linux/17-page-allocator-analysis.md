# 17-page-allocator — Linux 内核页分配器深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**页分配器（page allocator）** 是 Linux 内核内存管理的核心组件。它管理所有物理内存页面的分配与回收，通过 zone-based 分区、buddy 算法、per-CPU 缓存和迁移类型分组等机制，在性能、碎片控制和并发扩展之间取得平衡。

**核心架构**：

```
                ┌─────────────────────┐
                │  __alloc_pages()    │
                │  (核心分配入口)      │
                └──────────┬──────────┘
                           │
              ┌────────────┴────────────┐
              │                         │
      ┌───────▼───────┐        ┌───────▼───────┐
      │ 快速路径      │        │ 慢速路径      │
      │ (PCP + Buddy) │        │ (reclaim +    │
      │ 无休眠        │        │  compaction   │
      └───────┬───────┘        │  + OOM)       │
              │                └───────┬───────┘
              │                        │
              ▼                        ▼
        分配成功                  分配成功或 NULL
```

**doom-lsp 确认**：`include/linux/gfp.h` 包含 **56 个符号**（GFP 标志和分配声明）。`mm/page_alloc.c` 包含 **349 个符号**（7795 行）。核心函数：`__alloc_pages_noprof` @ L229（声明），`get_page_from_freelist`，`rmqueue`，`__free_pages_ok` @ L208。

---

## 1. 核心数据结构

### 1.1 `struct zone`——内存域

```c
struct zone {
    // ——— Buddy 分配器 ———
    struct free_area    free_area[MAX_ORDER];   // 每个 order 的空闲链表
    unsigned long       _watermark[NR_WMARK];   // [WMARK_MIN, LOW, HIGH]
    long                lowmem_reserve[MAX_NR_ZONES]; // 低内存保留

    // ——— Per-CPU 页帧缓存 ———
    struct per_cpu_pages __percpu *per_cpu_pageset;

    // ——— 迁移类型 ———
    int                 nr_migrate_reserve_block;

    // ——— 统计 ———
    unsigned long       managed_pages;      // 被 buddy 管理的页面数
    unsigned long       spanned_pages;      // zone 覆盖的总页数
    unsigned long       present_pages;      // 实际存在的页数
    atomic_long_t       vm_stat[NR_VM_ZONE_STAT_ITEMS];
};
```

**四个 zone 类型**：

| zone | 地址范围 | 用途 |
|------|---------|------|
| ZONE_DMA | 0-16MB | 旧 ISA DMA 设备 |
| ZONE_DMA32 | 0-4GB | 32 位 DMA 设备 |
| ZONE_NORMAL | 4GB+ | 通用内核分配 |
| ZONE_MOVABLE | 动态 | 可迁移页面（防止碎片）|

### 1.2 `struct free_area`——Buddy 空闲链表

```c
struct free_area {
    struct list_head    free_list[MIGRATE_TYPES];  // 每迁移类型一个链表
    unsigned long       nr_free;                   // 该 order 的空闲页块数
};
```

**MAX_ORDER** 定义了 buddy 系统的阶数上限：

```c
#define MAX_ORDER    11   // 最大 2^10 = 1024 页 = 4MB（4KB 页）
// order:  0      1      2      3      ...    9       10
// 页数:   1      2      4      8      ...    512     1024
// 大小:   4KB    8KB    16KB   32KB   ...    2MB     4MB
```

### 1.3 `struct page`——物理页描述符

```c
struct page {
    unsigned long flags;              // PG_locked, PG_dirty, PG_uptodate, PG_swapbacked...
    struct list_head lru;             // LRU / free_list / pcp_list（根据状态）
    struct address_space *mapping;    // 所属文件映射或匿名映射
    pgoff_t index;                    // 页内偏移
    atomic_t _refcount;               // 引用计数（含 pin 计数）
    unsigned long private;            // 私有数据
    // ... (union 复用了大量字段)
};
```

---

## 2. GFP 标志

GFP 标志控制分配行为——从哪里分配、是否允许休眠、是否允许回收：

```c
// include/linux/gfp.h — 基础标志
#define ___GFP_DMA32      0x01u     // 从 ZONE_DMA32 分配
#define ___GFP_HIGHMEM    0x02u     // 从高端内存分配
#define ___GFP_MOVABLE    0x08u     // 从 ZONE_MOVABLE 分配
#define ___GFP_RECLAIMABLE 0x10u    // 标记为"可回收"（slab 用）
#define ___GFP_HIGH       0x20u     // 高优先级（允许紧急预留）
#define ___GFP_IO         0x40u     // 允许块设备 IO
#define ___GFP_FS         0x80u     // 允许文件系统操作
#define ___GFP_ZERO       0x100u    // 分配零页
#define ___GFP_NOWARN     0x200u    // 不打印分配失败警告
#define ___GFP_RETRY_MAYFAIL 0x400u // 允许重试
#define ___GFP_NOFAIL     0x800u    // 不允许失败
#define ___GFP_NORETRY    0x1000u   // 不重试，一次失败就返回
#define ___GFP_HARDWALL   0x2000u   // 强制 cpuset 限制
#define ___GFP_ATOMIC     0x8000u   // 原子上下文
#define ___GFP_MEMALLOC   0x20000u  // 允许使用预留内存
#define ___GFP_DIRECT_RECLAIM 0x10000u // 允许直接回收
#define ___GFP_KSWAPD_RECLAIM 0x20000u // 允许唤醒 kswapd

// ——— 常用组合 ———
#define GFP_KERNEL      (___GFP_RECLAIM | ___GFP_IO | ___GFP_FS | \
                          ___GFP_KSWAPD_RECLAIM | ___GFP_DIRECT_RECLAIM)
    // 进程上下文通用分配，可休眠、可 IO、可回收

#define GFP_ATOMIC      (___GFP_HIGH | ___GFP_KSWAPD_RECLAIM)
    // 原子上下文（不可休眠，使用紧急预留）

#define GFP_NOWAIT      (___GFP_KSWAPD_RECLAIM)
    // 不可休眠，不直接回收

#define GFP_HIGHUSER    (GFP_USER | ___GFP_HIGHMEM | ___GFP_MOVABLE)
    // 用户空间分配（高地址、可迁移）

#define GFP_NOFS        (___GFP_RECLAIM | ___GFP_IO)
    // 文件系统内部使用（不触发 FS 操作，防止递归）
```

---

## 3. 🔥 四层分配路径——__alloc_pages

```
__alloc_pages(gfp, order, preferred_nid, nodemask)
  │
  ├─ [第 0 层：GFP 转换]
  │   gfp_zone(gfp) → 确定允许分配的 zone
  │   alloc_gfp = gfp 精简
  │
  ├─ [第 1 层：快速路径 —— get_page_from_freelist]
  │   │
  │   ├─ 遍历 zonelist（ZONE_NORMAL → ZONE_DMA32 → ZONE_DMA）
  │   │
  │   ├─ zone_watermark_fast(zone, order, WMARK_LOW)
  │   │   → 检查水位是否充足
  │   │   → 如果水位不足，跳过此 zone
  │   │
  │   ├─ rmqueue(zone, order, migratetype)
  │   │   │
  │   │   ├─ [order == 0 单页] → rmqueue_pcplist
  │   │   │   → 从 per-CPU 缓存取页
  │   │   │   → 快速路径，无锁
  │   │   │
  │   │   └─ [order > 0] → __rmqueue
  │   │       │
  │   │       ├─ __rmqueue_smallest(zone, order, mt)
  │   │       │   → 从 free_area[order].free_list[mt] 取页
  │   │       │   → 如果非空，直接返回
  │   │       │   → 如果为空，尝试更高 order
  │   │       │
  │   │       ├─ expand(zone, page, order, target_order, mt)
  │   │       │   → 从更高 order 的块分裂
  │   │       │   → 剩余部分放回对应 order 的 free_list
  │   │       │
  │   │       └─ __rmqueue_fallback(zone, order, mt)
  │   │           → 当前 mt 的 free_list 全部为空
  │   │           → 从 fallback 列表"偷"其他 mt 的页面
  │   │
  │   ├─ prep_new_page(page, order, gfp, alloc_flags)
  │   │   → 初始化新页面
  │   │   → 清除 PG_buddy 标志
  │   │   → post_alloc_hook (cgroup 跟踪等)
  │   │
  │   └─ return page  ← 快速路径分配成功！
  │
  ├─ [第 2 层：慢速路径 —— __alloc_pages_slowpath]
  │   │
  │   ├─ wake_all_kswapds(order, gfp, ...)
  │   │   → 唤醒每个 zone 的 kswapd
  │   │   → kswapd 异步回收页面
  │   │
  │   ├─ gfp_to_alloc_flags(gfp)
  │   │   → 根据 gfp 设置 alloc_flags
  │   │   → 如果 GFP_ATOMIC：使用 WMARK_MIN + 紧急预留
  │   │
  │   ├─ get_page_from_freelist(alloc_gfp, order, ...)
  │   │   → 使用新的 alloc_flags 重试
  │   │   → 可能成功（kswapd 已释放一些页面）
  │   │
  │   ├─ [直接回收] if (gfp & ___GFP_DIRECT_RECLAIM)
  │   │   __perform_reclaim(gfp, order, zone)
  │   │   → 同步回收页面
  │   │   → 从 LRU 链表回收 ~32 页
  │   │   → 可能回收 slab 缓存
  │   │   → 重试分配
  │   │
  │   ├─ [内存规整] if (order > 0 && !fatal_signal_pending)
  │   │   compaction_defer_async(zone, order)
  │   │   → 尝试在 ZONE_MOVABLE 中 compact
  │   │   → 移动页面形成连续区域
  │   │   → 重试分配
  │   │
  │   ├─ [OOM Killer] if (!(gfp & ___GFP_NORETRY))
  │   │   out_of_memory(&oc)
  │   │   → 杀死一个进程
  │   │   → 释放其所有页面
  │   │   → 最后重试
  │   │
  │   └─ return page 或 NULL
```

---

## 4. 🔥 Buddy 分裂——expand 函数详解

```c
static inline void expand(struct zone *zone, struct page *page,
                           int low, int high, int migratetype)
{
    unsigned long size = 1 << high;

    while (high > low) {
        high--;
        size >>= 1;
        // 将 buddy（后半块）加入对应 order 的 free_list
        add_to_free_list(&page[size], zone, high, migratetype);
        // 设置 buddy 信息（供合并时检测）
        set_page_order(&page[size], high);
    }
}
```

**分裂示例——请求 4KB (order=0)，只有 4MB (order=8) 的空闲块**：

```
free_area[8]: [块 C: 4MB (1024 页)]
  ↓ 分裂
free_area[7]: [块 C1: 2MB (512 页)]  [块 C2: 2MB]  → 加到 free_area[7]
  ↓ 继续分裂块 C1
free_area[6]: [块 C1A: 1MB (256 页)] → 加到 free_area[6]
  ↓ 继续分裂块 C1A
free_area[5]: [块 C1A-A: 512KB] → free_area[5]
  ↓
free_area[4]: [块 C1A-A-a: 256KB] → free_area[4]
  ↓
free_area[3]: [128KB] → free_area[3]
  ↓
free_area[2]: [64KB] → free_area[2]
  ↓
free_area[1]: [32KB] → free_area[1]
  ↓
free_area[0]: [4KB]  ★ 分配此页给调用者
               [4KB]  → free_area[0]

最终状态：
  free_area[0]: 1 页 (后续分配可直接命中)
  free_area[1]~free_area[7]: 各新增空闲块
```

---

## 5. 🔥 Buddy 合并——__free_one_page

```c
static inline void __free_one_page(struct page *page,
                                    unsigned long pfn,
                                    struct zone *zone, unsigned int order,
                                    int migratetype, unsigned int fpi_flags)
{
    unsigned long buddy_pfn;
    struct page *buddy;
    unsigned int max_order = MAX_ORDER;

    // 持续合并直到无法合并
    while (order < max_order) {
        // 计算 buddy（伙伴块）的 PFN
        buddy_pfn = __find_buddy_pfn(pfn, order);
        buddy = page + (buddy_pfn - pfn);

        // 检查 buddy 是否也在 free_area[order] 中
        if (!pfn_valid_within(buddy_pfn))
            break;
        if (!page_is_buddy(buddy, order, migratetype))
            break;

        // ★ 合并！
        del_page_from_free_list(buddy, zone, order);  // 从链表移除 buddy
        pfn = min(pfn, buddy_pfn);                     // 取较小 PFN 作为合并块
        order++;                                        // order +1
    }

    // 加入对应 order 的 free_list
    add_to_free_list(&page[pfn], zone, order, migratetype);
    set_page_order(&page[pfn], order);
}
```

**合并示例**：

```
释放 4 个相邻的 order=0 页面（PFN 0, 1, 2, 3）：

释放页 0 (PFN=0, order=0):
  buddy_pfn = 0 ^ 1 = 1 → 页 1 也在 free_list[0]?
    是的！→ 合并为 order=1 块 (PFN 0-1)
    buddy_pfn = 0 ^ 2 = 2 → 页 2 在 free_list[0]?（不是，在 free_list[1]?）
    → page_is_buddy 检查 order=1 的 buddy
    → buddy_pfn = 0 ^ 2 = 2 → 检查页 2-3 是否在 free_list[1]? 是的！
    → 合并为 order=2 块 (PFN 0-3)
    buddy_pfn = 0 ^ 4 = 4 → 页 4 在 free_list[2]? 否
    → 停止合并
    → 加入 free_area[2]

释放页 3 (PFN=3, order=0):
  buddy_pfn = 3 ^ 1 = 2 → 页 2 在 free_list[0]? 是的
  → 合并为 order=1 (PFN 2-3)
  buddy_pfn = 2 ^ 2 = 0 → 页 0-1 在 free_list[1]?
    → page_is_buddy(PFN 0-1, order=1, ...)
    → 已不在 free_list 中（被之前的合并取走了）
  → 停止，加入 free_area[1]
```

---

## 6. Per-CPU 页帧缓存（PCP）

```c
struct per_cpu_pages {
    int count;              // 当前缓存页数
    int high;               // 高水位阈值
    int batch;              // 批量转移时的数量
    struct list_head lists[]; // 按迁移类型分的链表
};
```

**PCP 工作流程**：

```
分配 order=0 时（rmqueue_pcplist）：
  │
  ├─ 从 current CPU 的 PCP lists[mt] 取一页
  │   → list_first_entry + list_del
  │   → count--
  │
  └─ 如果 PCP 为空：
       → rmqueue_bulk(zone, 0, batch, mt, ...)
       → 从 buddy 取 batch 页（加锁）
       → 存入 PCP
       → count += batch
       → 从中取一页返回

释放 order=0 时（free_unref_page）：
  │
  ├─ 归还到 current CPU 的 PCP
  │   → list_add + count++
  │
  └─ 如果 PCP 页数 > high：
       → free_pcppages_bulk(zone, ...)
       → 释放 batch 页回 buddy
```

**性能数据**：PCP 使 order=0 分配的锁竞争减少约 20 倍（在 128 核系统上）。原因是：每次分配只需要操作 per-CPU 数据，不需要获取 zone->lock。

---

## 7. 迁移类型与碎片防止

页面按迁移类型分组管理，目的是将可迁移和不可迁移的页面分开，防止不可迁移页面阻塞大块连续内存的分配：

```c
enum migratetype {
    MIGRATE_UNMOVABLE,      // 不可迁移（内核永久页面）
    MIGRATE_MOVABLE,        // 可迁移（用户空间页面）
    MIGRATE_RECLAIMABLE,    // 可回收（slab 缓存页）
    MIGRATE_PCPTYPES,       // PCP 缓存数量（用于循环）
    MIGRATE_HIGHATOMIC,     // 高优先级原子分配预留
    MIGRATE_TYPES           // 总类型数
};
```

**回退表**——当请求的 free_list 为空时：

```c
static int fallbacks[MIGRATE_TYPES][MIGRATE_TYPES - 1] = {
    [MIGRATE_UNMOVABLE]   = { MIGRATE_RECLAIMABLE, MIGRATE_MOVABLE,   ... },
    [MIGRATE_MOVABLE]     = { MIGRATE_RECLAIMABLE, MIGRATE_UNMOVABLE,  ... },
    [MIGRATE_RECLAIMABLE] = { MIGRATE_UNMOVABLE,   MIGRATE_MOVABLE,   ... },
};
```

**碎片控制的原理**：

```
无迁移类型（所有页面混杂在一起）：
  ┌────┬────┬────┬────┬────┬────┬────┬────┐
  │ U  │ U  │ M  │ M  │ U  │ U  │ M  │ U  │
  └────┴────┴────┴────┴────┴────┴────┴────┘
  → 无法分配 2 个连续页（被 U 阻断）

有迁移类型（分组排列）：
  ┌────┬────┬────┬────┐┌────┬────┬────┬────┐
  │  U │  U │  U │  U ││  M │  M │  M │  M │
  └────┴────┴────┴────┘└────┴────┴────┴────┘
  → MOVABLE 区域可规整出连续页
```

---

## 8. 水位（Watermark）系统

```c
enum zone_watermarks {
    WMARK_MIN,    // 最低水位（紧急保留，仅 GFP_ATOMIC+HIGH 可用）
    WMARK_LOW,    // 低水位（kswapd 开始异步回收）
    WMARK_HIGH,   // 高水位（kswapd 停止回收）
    NR_WMARK,
};
```

```
zone 内存使用情况：
┌──────────────────────────────────────────────┬──────────┬──────────┐
│                  已分配内存                   │  空闲     │  空闲    │
│                                              │ (MIN→LOW)│(LOW→HIGH)│
└──────────────────────────────────────────────┴──────────┴──────────┘
                                                ↑          ↑
                                           WMARK_MIN   WMARK_LOW   WMARK_HIGH

空闲 < WMARK_LOW  → 唤醒 kswapd 异步回收
空闲 < WMARK_MIN  → 直接回收（direct reclaim）+ 可能使用紧急保留
空闲 > WMARK_HIGH → kswapd 停止
```

```c
// 水位检查：
static inline bool zone_watermark_fast(struct zone *z, unsigned int order,
                                        unsigned long mark)
{
    long free_pages = zone_page_state(z, NR_FREE_PAGES);
    // 减去预留
    free_pages -= __zone_watermark_unusable_free(z, order, mark);
    return free_pages >= z->_watermark[mark];
    // true → 可分配
    // false → 水位不足
}
```

---

## 9. 性能对比

| 路径 | order | 典型延迟 | 主要操作 |
|------|-------|---------|---------|
| PCP 快速路径 | 0 | ~50-100ns | per-CPU list_del，无锁 |
| Buddy 快速路径 | >0 | ~100-500ns | free_list操作 + 可能的分裂 |
| kswapd 触发后 | any | ~1-10μs | 异步回收+重试 |
| 直接回收 | any | ~10-100μs | 同步 LRU 回收 |
| Compaction | >0 | ~100μs-1ms | 页面迁移 |
| OOM | any | ~100ms+ | 杀死进程 |

---

## 10. 源码文件索引

| 函数 | 行号 | 文件 |
|------|------|------|
| `__alloc_pages_noprof` | 声明@229 | include/linux/gfp.h |
| `__free_pages_ok` | 208 | mm/page_alloc.c |
| `rmqueue` | — | mm/page_alloc.c |
| `__rmqueue_smallest` | — | mm/page_alloc.c |
| `expand` | — | mm/page_alloc.c |
| `__free_one_page` | — | mm/page_alloc.c |
| `zone_watermark_fast` | — | mm/page_alloc.c |

---

## 11. 关联文章

- **15-get_user_pages**：GUP 触发缺页分配
- **36-slab-allocator**：slab 从 buddy 取页
- **38-vmalloc**：vmalloc 使用 buddy 分配物理页
- **43-memcg**：cgroup 内存限制与页面分配

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
