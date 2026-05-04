# 136-compaction — 读 mm/compaction.c

---

## 目的

内存压缩（compaction）解决的是**外部碎片**——空闲页面分散在 zone 中，没有足够大的连续区域满足 order-9（2MB）分配。Compaction 不回收页面，它移动已分配的页面来创建大的连续空洞。

---

## 双扫描器模型

compaction 用两个扫描器相对而行：

```
迁移扫描器 (migrate scanner)       空闲扫描器 (free scanner)
  zone 顶端                             zone 底部
  ↓                                      ↑
  ┌──────────────────────────────────────┐
  │ 已分配页    已分配页    空闲页       │
  │   ████████   ████████   ░░░░░░░░    │
  │   ████████   ████████   ░░░░░░░░    │
  │   ████████   ████████   ░░░░░░░░    │
  └──────────────────────────────────────┘
       ↓ migrate         ↑ isolate freepages
       ↓ pages           ↑ from buddy system
```

两个扫描器在 zone 中相向而行。当它们的 PFN 交叉时，压缩完成——此时空闲扫描器下方和迁移扫描器上方的所有页面都已压缩完毕。

---

## fast_isolate_freepages——快速空闲页提取

（`mm/compaction.c` L1521）

```c
static void fast_isolate_freepages(struct compact_control *cc)
{
    // 从 buddy 系统的空闲链表中提取页面
    // 优先取高于目标 order 的空闲块
    // 目标位置：扫描区间的上半部分（靠近空闲扫描器）
    distance = (cc->free_pfn - cc->migrate_pfn);  // 扫描区间
    low_pfn = scan_area_start(free_pfn - distance/4);  // 优选点

    // 遍历 buddy 系统的 free_area[order]，取一个块
    for (order = cc->search_order; order <= MAX_ORDER; order++) {
        page = get_page_from_free_area(area, MIGRATE_MOVABLE);
        if (page) {
            // 检查页面是否在目标范围内
            if (page_to_pfn(page) < low_pfn || page_to_pfn(page) >= min_pfn)
                continue;
            // 隔离该块（标记为 MIGRATE_ISOLATE）
            move_freepages_block(zone, page, MIGRATE_ISOLATE, NULL);
            cc->nr_freepages += 1 << order;
            return;
        }
    }
}
```

---

## 迁移类型与碎片避免

每个 pageblock（通常 2MB）有一个迁移类型，表示该块中页面的可移动性：

| 类型 | 含义 | 可迁移？ |
|------|------|---------|
| MIGRATE_UNMOVABLE | 内核分配的页面 | ❌ |
| MIGRATE_MOVABLE | 用户空间页面 | ✅ |
| MIGRATE_RECLAIMABLE | slab 缓存页面 | ❌ |
| MIGRATE_CMA | CMA 区域 | ✅ |
| MIGRATE_ISOLATE | 正在隔离 | ⚠️ 跳过 |

Compaction 只迁移 `MIGRATE_MOVABLE` 页面——这些是用户空间的匿名页和文件页，更新 PTE 即可完成迁移。内核页面（`MIGRATE_UNMOVABLE`）可能有物理地址编码在内核中，不能移动。

---

## 直接压缩 vs kcompactd

| | 直接压缩 | kcompactd |
|--|---------|-----------|
| 触发 | `__alloc_pages_slowpath` | 内核线程 |
| 同步/异步 | 同步（阻塞分配者） | 异步 |
| 优先级 | 高（分配者在等待） | 低 |
| 来源 | 应用程序分配路径 | kswapd 睡眠前唤醒 |
