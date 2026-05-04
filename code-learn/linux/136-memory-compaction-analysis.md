# Linux 内存压缩与透明大页深度分析

## 概述

内存压缩（Memory Compaction）是 Linux 内核用于**整理物理内存碎片**的机制。与页面回收不同，compaction 不减少内存使用量，而是通过移动已分配的页面来创建更大的连续物理区域。它的主要消费者是 THP（透明大页）的分配——需要 2MB（x86-64）的连续物理内存。

compaction 的工作原理类似于 mark-and-sweep：扫描内存区域，隔离可移动的页面，然后迁移它们到空闲区域，释放在目标位置的大块连续内存。

## 核心数据结构

### struct compact_control — 压缩控制参数

（`mm/internal.h`）

```c
struct compact_control {
    struct list_head    freepages;      // 收集到的空闲页链表
    struct list_head    migratepages;   // 收集到的待迁移页链表

    unsigned long       nr_freepages;   // 空闲页计数
    unsigned long       nr_migratepages;// 待迁移页计数

    unsigned long       free_pfn;       // 空闲扫描起始 PFN（从 zone 底部向上）
    unsigned long       migrate_pfn;    // 迁移扫描起始 PFN（从 zone 顶部向下）

    unsigned int        order;          // 目标阶数（order-9 = 2MB 大页）
    unsigned int        highest_zoneidx;// 最高 zone 索引
    int                 prio;           // 优先级（0=最高，影响扫描范围）
    int                 retries;        // 重试次数

    /* 标志位 */
    unsigned int        alloc_flags;    // 分配标志
    unsigned int        alloc_pfn;      // 目标分配 PFN
    bool                direct_compaction; // 是否直接压缩（vs kcompactd）
    bool                proactive;      // 主动压缩（proactive compaction）
    bool                whole_zone;     // 扫描整个 zone
    bool                ignore_skip_hint; // 忽略跳过提示
    bool                ignore_blocked; // 忽略被阻止的页面
    bool                no_set_skip_hint; // 不设置跳过提示
    bool                finish_pageblock; // 完成当前 pageblock
    ...
};
```

**两个扫描器的概念**：compaction 同时启动两个扫描器：
1. **空闲扫描器（free scanner）**：从 zone 底部向上扫描，收集空闲页面
2. **迁移扫描器（migrate scanner）**：从 zone 顶部向下扫描，收集可移动的页面

当两个扫描器相遇时，compaction 完成。

### struct pageblock_flags — 页面块标志

每个 pageblock（通常 2MB，即 order-9）有一个迁移类型标志：

```c
enum migratetype {
    MIGRATE_UNMOVABLE,      // 不可移动（内核分配的页面）
    MIGRATE_MOVABLE,        // 可移动（用户空间页面、匿名页）
    MIGRATE_RECLAIMABLE,    // 可回收（slab 缓存页面）
    MIGRATE_PCPTYPES,       // per-CPU 缓存页面类型
    MIGRATE_CMA,            // CMA（Contiguous Memory Allocator）
    MIGRATE_ISOLATE,        // 正在隔离（跳过）
};
```

compaction 优先从 `MIGRATE_MOVABLE` pageblock 中迁移页面，因为：
- 用户空间页面映射可以通过页表更新轻松重定位
- 内核页面（`MIGRATE_UNMOVABLE`）可能包含物理地址硬编码的指针
- `MIGRATE_ISOLATE` 页面正在被隔离，需跳过

## Compaction 的完整数据流

### 触发路径

Compaction 的触发有以下三种路径：

```
1. 直接压缩（direct_compact）：
   __alloc_pages_slowpath()
     └─ __alloc_pages_direct_compact(gfp_mask, order, ...)
          └─ try_to_compact_pages(ac, cc)
               └─ compact_zone(cc)         // 同步压缩

2. kcompactd 后台压缩：
   kcompactd()
     └─ kcompactd_do_work(pgdat)
          └─ compact_zone(cc)              // 异步压缩

3. 主动压缩（proactive compaction）：
   sysctl_compaction_proactiveness / 或定期触发
     └─ compact_nodes()
          └─ kcompactd_do_work()
```

### compact_zone() — 单次压缩循环

（`mm/compaction.c` 核心函数）

```
compact_zone(cc)
  │
  ├─ 1. 检查是否适合压缩
  │     compaction_suitable(zone, order, cc->alloc_flags)
  │     ├─ 空闲页面总数是否足够？
  │     └─ 碎片程度是否达到阈值？
  │
  ├─ 2. 初始化扫描位置
  │     cc->free_pfn = zone 底部
  │     cc->migrate_pfn = zone 顶部（last_migrated_pfn）
  │     cc->last_migrated_pfn = 上次停止位置
  │
  ├─ 3. 主循环：空闲扫描器 vs 迁移扫描器
  │     while (cc->free_pfn < cc->migrate_pfn) {
  │         │
  │         ├─ 步骤 A：空闲扫描
  │         │     isolate_freepages(cc)
  │         │       ├─ fast_isolate_freepages(cc)  // 快速路径：从 buddy 分配器取
  │         │       └─ isolate_freepages_block(cc) // 慢速路径：扫描 pageblock
  │         │             ├─ 检查 pageblock 类型
  │         │             ├─ 从 buddy 系统隔离空闲页面
  │         │             └─ 添加到 cc->freepages 链表
  │         │
  │         ├─ 步骤 B：迁移扫描
  │         │     isolate_migratepages(cc)
  │         │       └─ isolate_migratepages_block(cc)
  │         │             ├─ 遍历 PTEs，跳过：
  │         │             │   ├─ 未映射的页面
  │         │             │   ├─ 不可移动的页面（PageBuddy, PageUnevictable）
  │         │             │   ├─ 锁竞争失败
  │         │             │   └─ 长钉页面（THP 的拆分状态）
  │         │             └─ 可移动页面 → 添加到 cc->migratepages
  │         │
  │         ├─ 步骤 C：迁移页面
  │         │     if (cc->nr_migratepages > 0) {
  │         │         migrate_pages(&cc->migratepages, ...)
  │         │           └─ for each page in migratepages:
  │         │                 ├─ 分配新的物理页面（从 freepages 取）
  │         │                 ├─ 拷贝页面内容（copy_highpage）
  │         │                 ├─ 更新页表映射（remap_page）
  │         │                 └─ 释放原页面（free_unref_page）
  │         │     }
  │         │
  │         └─ 步骤 D：更新进度
  │               update_cached_migrate(cc)
  │               记录 current_migrate_pfn → last_migrated_pfn
  │         }
  │
  └─ 4. 返回结果
        enum compact_result:
          COMPACT_SUCCESS     — 成功创建了目标大小的连续页
          COMPACT_PARTIAL     — 部分成功，但仍可能有碎片
          COMPACT_SKIPPED     — 跳过（不适合压缩）
          COMPACT_CONTENDED   — 竞争导致无法继续
          COMPACT_COMPLETE    — 整个 zone 扫描完毕
```

### fast_isolate_freepages() — 快速空闲页提取

（`mm/compaction.c` L1521）

```c
static void fast_isolate_freepages(struct compact_control *cc)
{
    unsigned int order = cc->order;
    struct zone *zone = page_zone(pfn_to_page(cc->migrate_pfn));
    struct free_area *area;

    // 从 buddy 系统的空闲链表中直接取
    // 优先取高于目标 order 的空闲块
    for (order = cc->order; order <= MAX_ORDER; order++) {
        area = &(zone->free_area[order]);
        if (list_empty(&area->free_list[MIGRATE_MOVABLE]))
            continue;

        // 取一个空闲块
        page = list_first_entry(&area->free_list[MIGRATE_MOVABLE],
                                struct page, buddy_list);
        // 隔离该块
        move_freepages_block(zone, page, MIGRATE_ISOLATE, NULL);
        ...
        return;
    }
}
```

这个快速路径避免了对 pageblock 的完整扫描，直接从 buddy 系统拿到空闲页面，显著提升 compaction 效率。

## 透明大页（THP）与 compaction 的关系

THP 分配是 compaction 的主要消费者：

### THP 分配路径

```
khugepaged 或 用户空间触发：
  __do_huge_pmd_anonymous_page(vma, haddr, pmd)
    └─ alloc_hugepage_vma(gfp, vma, haddr, ...)
         └─ __alloc_pages(gfp, HPAGE_PMD_ORDER, ...)
              └─ get_page_from_freelist()
                   需要 2MB（order-9）连续页面

   如果分配失败 → 触发 compaction：
     try_to_compact_pages();
     └─ compact_zone() 尝试创建 2MB 连续区域

   如果 compaction 成功 → 重试分配
   如果 compaction 失败 → 退回 4KB 页面
```

THP 相关的关键参数：

```c
// include/linux/huge_mm.h
#define HPAGE_PMD_ORDER  (PMD_SHIFT - PAGE_SHIFT)  // x86-64: 9 (2MB)
#define HPAGE_PMD_NR     (1 << HPAGE_PMD_ORDER)    // 512 个 4KB 页面

// 控制 knobs:
// /sys/kernel/mm/transparent_hugepage/enabled  [always] [madvise] [never]
// /sys/kernel/mm/transparent_hugepage/defrag   [always] [defer] [defer+madvise] [madvise] [never]
// /sys/kernel/mm/transparent_hugepage/khugepaged/defrag [0|1]
// /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs
// /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs
```

### khugepaged — 后台 THP 整合

khugepaged 是内核线程，定期扫描内存并尝试将连续的 4KB 页面合并为 THP：

```
khugepaged()
  └─ khugepaged_scan_mm_slot()
       └─ 遍历进程的 VMA
            └─ khugepaged_scan_file()   // 文件映射页
            └─ khugepaged_scan_pmd()    // 匿名页
                 └─ 检查 2MB 范围内所有 512 个 PTE
                      ├─ 所有页面都驻留在内存中？
                      ├─ 所有页面都是可移动的？
                      ├─ 地址对齐到 2MB？
                      → 如果是，调用 collapse_huge_page()
                           └─ 分配 2MB 页面
                           └─ 拷贝 512 个页面内容
                           └─ 替换 PMD 映射
                           └─ 释放 512 个原页面
```

## 页面迁移核心：migrate_pages()

（`mm/migrate.c`）

页面迁移是 compaction 的核心操作，也是内存热插拔、CMA、numa balancing 的共享基础设施：

```c
int migrate_pages(struct list_head *from, new_page_fn get_new_page,
                  free_page_fn put_new_page, ...)
{
    int retry = 1;
    int nr_failed = 0;

    while (retry) {
        retry = 0;
        list_for_each_entry_safe(page, page2, from, lru) {
            // 1. 锁定原页面
            lock_page(page);

            // 2. 分配新页面
            newpage = get_new_page(page, ...);

            // 3. 进行架构相关的页面迁移
            if (PageAnon(page)) {
                // 匿名页：拷贝内容 + rmap 更新
                migrate_page_copy(newpage, page);
                try_to_migrate(page, ...);
            } else {
                // 文件页：需要回写
                migrate_page(newpage, page);
                if (!PageUptodate(page))
                    wait_on_page_writeback(page);
            }

            // 4. 替换页表映射
            remove_migration_pte(page, newpage, ...);

            // 5. 释放原页面
            putback_lru_page(newpage);
            unlock_page(page);
            put_page(page);
        }
    }
    return nr_failed;
}
```

## Compaction 的优化策略

### 1. 缓存迁移偏移（cached migrate PFN）

每次 compaction 完成后，记录扫描停止的位置（`last_migrated_pfn`）。下次从该位置继续，而不是每次都从头扫描整个 zone。这避免了重复扫描已压缩过的区域。

```c
// mm/compaction.c — update_cached_migrate()
static void update_cached_migrate(struct compact_control *cc)
{
    struct zone *zone = cc->zone;
    unsigned long old = zone->compact_cached_migrate_pfn;

    if (cc->migrate_pfn > old)
        zone->compact_cached_migrate_pfn = cc->migrate_pfn;
}
```

### 2. 跳过提示（skip hint）

每个 pageblock 有一个 skip 位。如果 compaction 在某个 pageblock 上无法迁移任何页面，设置 skip 位，下次跳过：

```c
// mm/compaction.c
static void update_pageblock_skip(struct compact_control *cc,
    struct page *page, unsigned long nr_isolated, bool migrate_scanner)
{
    if (!nr_isolated) {
        set_pageblock_skip(page);
        cc->no_set_skip_hint = true;
    }
}
```

### 3. 碎片指数（fragmentation index）

`fragmentation_index()` 计算给定 order 分配在该 zone 中的成功概率：

```
index = 1 - (free_pages * 2^order) / (required_pages)
index = 0 → 碎片不严重（压缩意义不大）
index = 1 → 碎片严重（需要压缩）
```

### 4. 主动压缩（proactive compaction）

通过 `/proc/sys/vm/compaction_proactiveness`（0~100）控制：

```c
// mm/compaction.c — kcompactd 定期执行
if (proactive_compaction) {
    // 计算碎片程度
    fragmentation_score = ...;
    // 如果超过阈值，触发后台 compaction
    if (fragmentation_score > proactive_compact_trigger)
        kcompactd_do_work(pgdat);
}
```

## Compaction 与页面回收的协作

```
          内存不足
              │
              ├─ direct_reclaim() — 页面回收
              │   释放 page cache / swap out → 增加 free pages
              │
              ├─ direct_compact() — 内存压缩
              │   不增加 free pages，但减少碎片
              │   回收需要 free pages 作为迁移目标
              │
              └─ OOM — 最后手段
```

两者互相依赖：回收提供额外的空闲页面（作为迁移目标），compaction 整合空闲页面（满足大块分配）。

## 关键性能特征

### 正面影响
- **大页命中率提升**：减少 TLB miss（THP 覆盖 2MB 范围，减少 512 次 TLB 访问）
- **内存效率**：大页减少页表开销（一个 PMD 代替 512 个 PTE）
- **首次访问性能**：在页面分配时 compaction 的成功直接影响分配延迟

### 负面影响
- **CPU 开销**：compaction 的扫描和页面迁移是 CPU 密集的
- **TLB 抖动**：大量 PTE 更新导致 TLB shootdown（跨 CPU IPI）
- **延迟抖动**：直接压缩在分配路径中同步执行，增加分配延迟

### 调优参数

| 参数 | 路径 | 默认值 | 说明 |
|------|------|--------|------|
| `compaction_proactiveness` | `/proc/sys/vm/` | 20 | 主动压缩强度 0~100 |
| `compact_unevictable_allowed` | `/proc/sys/vm/` | 1 | 是否压缩不可驱逐页 |
| `extfrag_threshold` | `/proc/sys/vm/` | 500 | 外部碎片阈值 |
| `khugepaged/alloc_sleep_millisecs` | `/sys/kernel/mm/transparent_hugepage/` | 10000 | khugepaged 分配睡眠 |
| `khugepaged/scan_sleep_millisecs` | `/sys/kernel/mm/transparent_hugepage/` | 10000 | khugepaged 扫描睡眠 |
| `defrag` | `/sys/kernel/mm/transparent_hugepage/` | defer | THP 的碎片整理策略 |

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct compact_control` | mm/internal.h | 相关 |
| `compact_zone()` | mm/compaction.c | 核心 |
| `compaction_suitable()` | mm/compaction.c | 相关 |
| `isolate_freepages()` | mm/compaction.c | 相关 |
| `fast_isolate_freepages()` | mm/compaction.c | 1521 |
| `isolate_freepages_block()` | mm/compaction.c | 574 |
| `isolate_migratepages()` | mm/compaction.c | 相关 |
| `isolate_migratepages_block()` | mm/compaction.c | 855 |
| `migrate_pages()` | mm/migrate.c | 相关 |
| `compaction_deferred()` | mm/compaction.c | 141 |
| `kcompactd()` | mm/compaction.c | 相关 |
| `kcompactd_do_work()` | mm/compaction.c | 相关 |
| `try_to_compact_pages()` | mm/compaction.c | 相关 |
| `__alloc_pages_direct_compact()` | mm/page_alloc.c | 相关 |
| `update_pageblock_skip()` | mm/compaction.c | 相关 |
| `khugepaged()` | mm/khugepaged.c | 相关 |
| `collapse_huge_page()` | mm/khugepaged.c | 相关 |
| `khugepaged_scan_pmd()` | mm/khugepaged.c | 相关 |
| `alloc_hugepage_vma()` | mm/huge_memory.c | 相关 |
| `enum migratetype` | include/linux/mmzone.h | MIGRATE_* 定义 |
| `HPAGE_PMD_ORDER` | include/linux/huge_mm.h | (x86-64: 9) |
| `__do_huge_pmd_anonymous_page()` | mm/huge_memory.c | 相关 |
