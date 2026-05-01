# 内存回收与 LRU 算法深度分析

> Kernel Source: Linux 7.0-rc1 (`/home/dev/code/linux`)  
> 分析文件: `mm/vmscan.c`, `mm/swap.c`, `include/linux/swap.h`  
> 核心问题: 从内存压力检测 → LRU 链表扫描 → 页回收/换出 → ocompaction 的完整路径

## 1. LRU 链表体系 — 数据结构与页分类

### 1.1 四类 LRU 链表

Linux 用四类 LRU 链表区分页的生命周期，通过 `enum lru_list` 标识：

```c
// include/trace/events/mmflags.h
LRU_INACTIVE_ANON,   // 匿名页，非活跃（冷）
LRU_ACTIVE_ANON,     // 匿名页，活跃（热）
LRU_INACTIVE_FILE,   // 文件页，非活跃（冷）
LRU_ACTIVE_FILE,     // 文件页，活跃（热）
LRU_UNEVICTABLE      // 不可回收页（mlocked 等）
```

### 1.2 folio_lru_list — 分类决策函数

一个页属于哪条 LRU 链表，由 `folio_lru_list()` 决定：

```c
// include/linux/mm_inline.h:82
static __always_inline enum lru_list folio_lru_list(const struct folio *folio)
{
    if (folio_test_unevictable(folio))
        return LRU_UNEVICTABLE;

    // folio_is_file_lru() 区分文件页 vs 匿名页
    lru = folio_is_file_lru(folio) ? LRU_INACTIVE_FILE : LRU_INACTIVE_ANON;
    if (folio_test_active(folio))
        lru += LRU_ACTIVE;

    return lru;
}
```

`folio_is_file_lru()` 的核心逻辑：检查 `folio->flags` 中的 `PG_swapcache` 位——如果页不在 swap cache，则通过 `PageAnon()` 判定匿名页；否则（在 swap cache 中）根据原始映射的文件类型判断。

### 1.3 lruvec — per-node 链表容器的物理布局

```c
// include/linux/mmzone.h:757
struct lruvec {
    struct list_head    lists[NR_LRU_LISTS];   // 5 条链表：4 类 LRU + unevictable
    spinlock_t         lru_lock;              // 保护 LRU 链表
    /* lru_gen: 多代 LRU（CONFIG_LRU_GEN）*/
    struct lru_gen_folio *lrugen;
    unsigned long     refaults[NR_WORKINGSET];// WORKINGSET_ACTIVATE_ANON/FILE
    unsigned long     priorities[MAX_NR_LRU_LISTS];
    // ...
};
```

```
pg_data_t (node)
├── struct lruvec __lruvec   ← 每个 node 一个 lruvec
│   ├── lists[LRU_INACTIVE_ANON]  → 匿名 inactive 链表
│   ├── lists[LRU_ACTIVE_ANON]    → 匿名 active 链表
│   ├── lists[LRU_INACTIVE_FILE]  → 文件 inactive 链表
│   ├── lists[LRU_ACTIVE_FILE]    → 文件 active 链表
│   ├── lists[LRU_UNEVICTABLE]   → 不可回收链表
│   └── lru_lock
└── struct zone node_zones[MAX_NR_ZONES]
```

### 1.4 lruvec_add_folio / lruvec_del_folio

```c
// vmscan.c:1868 "Returns the number of pages moved..."
static void lruvec_add_folio(struct lruvec *lruvec, struct folio *folio)
{
    // 追加到对应 LRU 链表尾（inactive 尾插，active 头插）
    list_add(&folio->lru, &lruvec->lists[folio_lru_list(folio)]);
}

static void lruvec_del_folio(struct lruvec *lruvec, struct folio *folio)
{
    list_del(&folio->lru);  // 从 LRU 摘下
}
```

## 2. scan_balance 与 get_scan_count — 匿名/文件扫描比例决策

### 2.1 决策状态机：enum scan_balance

```c
// vmscan.c:2276
enum scan_balance {
    SCAN_EQUAL,   // 1:1 平等扫描 anon + file
    SCAN_FRACT,   // 按比例（swappiness 权重）
    SCAN_ANON,    // 只扫匿名
    SCAN_FILE,    // 只扫文件
};
```

### 2.2 get_scan_count 决策树

```
get_scan_count()
│
├─ sc->may_swap == false || !can_reclaim_anon_pages()
│   └→ SCAN_FILE（没有 swap 空间，放弃匿名扫描）
│
├─ cgroup_reclaim && swappiness == 0
│   └→ SCAN_FILE（memcg 明确禁用 swap）
│
├─ swappiness == SWAPPINESS_ANON_ONLY（主动回收）
│   └→ SCAN_ANON
│
├─ !sc->priority && swappiness  【即 OOM 临界点】
│   └→ SCAN_EQUAL（系统濒临 OOM，不玩聪明策略，平等扫描）
│
├─ sc->file_is_tiny（文件页极少）
│   └→ SCAN_ANON（强制扫描匿名）
│
└─ 否则 → SCAN_FRACT（按 swappiness 权重比例分配）
```

`swappiness` 控制匿名/文件扫描比例的算法核心：

```c
// vmscan.c:2537 附近
denominator = nr_anon + nr_file * swappiness / 200;
nr[0] = nr_anon      * sc->nr_to_reclaim / denominator;  // anon inactive
nr[1] = ...           // anon active
nr[2] = nr_file * swappiness / 200 * ...;               // file inactive
nr[3] = ...
```

swappiness=0 → 只扫文件；swappiness=200 → 优先扫匿名；swappiness=100 → 比例接近 1:1。

### 2.3 prepare_scan_control

```c
// vmscan.c:2283
static void prepare_scan_control(pg_data_t *pgdat, struct scan_control *sc)
{
    if (lru_gen_enabled() && !lru_gen_switching())
        return;  // LRU_GEN 模式下跳过传统扫描控制

    target_lruvec = mem_cgroup_lruvec(sc->target_mem_cgroup, pgdat);
    // 设置 target_memcg，平衡各 memcg 间扫描
}
```

## 3. watermark 检测 — kswapd vs direct reclaim

### 3.1 三个 watermark 边界

```c
// include/linux/mmzone.h:1168
min_wmark_pages(z)   // min 水位：直接 reclaim 触发点，接近 OOM
low_wmark_pages(z)   // low 水位：kswapd 开始回收的触发点
high_wmark_pages(z) // high 水位：kswapd 认为"平衡"的停止点
promo_wmark_pages(z) // NUMA tiering 场景的 promotion 水位
```

### 3.2 pgdat_balanced — 判断节点是否"平衡"

```c
// vmscan.c:6914
static bool pgdat_balanced(pg_data_t *pgdat, int order, int highest_zoneidx)
{
    for_each_managed_zone_pgdat(zone, pgdat, i, highest_zoneidx) {
        if (sysctl_numa_balancing_mode & NUMA_BALANCING_MEMORY_TIERING)
            mark = promo_wmark_pages(zone);  // tiering 模式用 promo_wmark
        else
            mark = high_wmark_pages(zone);  // 默认用 high_wmark

        // 检查 NR_FREE_PAGES（或 order>0 时的 NR_FREE_PAGES_BLOCKS）
        free_pages = zone_page_state(zone, item);

        if (!__zone_watermark_ok(zone, order, mark,
                                  highest_zoneidx, ...))
            return false;  // 任一 zone 未达水位 → 不平衡
    }
    return true;  // 所有 zone 都达到水位 → 平衡
}
```

### 3.3 kswapd vs direct reclaim 的 balance 逻辑

**kswapd 路径** (`kswapd_shrink_node`):

```
kswapd 醒来（low watermark 被突破）
  └→ kswapd_shrink_node()
       ├─ sc.nr_to_reclaim = 0（不预设目标，逐 zone 回收）
       ├─ for each managed zone:
       │    while (!pgdat_balanced(pgdat, sc.order, zone_idx)) {
       │        shrink_lruvec() → 扫描 LRU
       │    }
       └─ 平衡时返回 true，kswapd 重新睡眠
```

**direct reclaim 路径** (`shrink_node`):

```
进程进入 direct reclaim（min watermark 被突破）
  └→ shrink_node()
       ├─ nr_to_reclaim = sc->nr_to_reclaim（预设目标）
       ├─ get_scan_count() → 计算 anon/file 扫描数量
       ├─ shrink_lruvec() → 执行扫描
       └─ should_continue_reclaim() → 检查是否需要继续
```

**关键区别**：

| 维度 | kswapd | direct reclaim |
|------|--------|---------------|
| 目标水位 | high_wmark | min_wmark |
| 扫描数量 | 弹性（比例于 zone 数） | 预设 nr_to_reclaim |
| 触发条件 | low_wmark 被突破 | min_wmark 被突破 |
| 优先级 | PERCPU_MAKE_PRIORITY(2,10) | GFP_KERNEL 上下文 |

### 3.4 OOM killer 何时被触发

```c
// vmscan.c:7019
if (pgdat_balanced(pgdat, order, highest_zoneidx)) {
    clear_pgdat_congested(pgdat);
    return true;  // kswapd: 平衡则退出
}

// vmscan.c:6316 direct reclaim 路径：
// min watermark 不满足 → 尝试 compaction → 仍不满足 → OOM
```

OOM killer 触发条件：**所有 zone 都低于 min_wmark**，且 direct reclaim 已尽力（`sc->nr_reclaimed >= sc->nr_to_reclaim` 仍未满足，或扫描优先级降到 0）。

## 4. shrink_folio_list — 回收决策核心

### 4.1 调用链

```
shrink_inactive_list()           // 从 LRU 摘下 inactive 页
  └→ isolate_lru_folios()        // 批量隔离到 folio_list
  └→ shrink_folio_list()          // 对每个 folio 做回收判决

shrink_active_list()            // 评估 active → inactive 转移
  └→ 引用过少的 active 页 → lruvec_add_folio(..., LRU_INACTIVE)
  └→ 引用充足的页 → 标记 PG_active 维持
```

### 4.2 shrink_folio_list 决策流程（逐 folio）

```
for each folio in folio_list:
│
├─ mapping = folio->mapping
│
├─ 【文件页】folio_is_file_lru(folio) == true:
│   ├─ folio_test_dirty(folio)? → 调用 mappping->a_ops->writepage
│   │    └→ PageDirty 清除，写入磁盘
│   ├─ folio_test_writeback(folio)? → 等待 PageWriteback 完成
│   └─ clean 文件页 → 直接释放
│
├─ 【匿名页】folio_test_swapcache(folio)?
│   ├─ 已在 swap cache → add_to_swap() → __swap_writepage
│   └─ 不在 swap cache → PageAnon? → add_to_swap_cache + swap_writepage
│
└─ 【共同条件】references = folio_check_references(folio)
    ├─ FOLIOREF_RECLAIM（无引用） → 回收（free_folio）
    └─ FOLIOREF_ACTIVATE（多次引用） → 放回 LRU（ret_folios）
```

### 4.3 PageDirty vs PageWriteback — 写回状态机

```
file-backed 页生命周期：
  clean        → 修改 → dirty         → writepage → writeback
  (磁盘同步)                   (内存有修改)        (写磁盘中)
                                              ↓
                                          complete  → clean（重新同步）

关键区分：
  PageDirty        页有本地修改，还没写出去
  PageWriteback    writepage 已调用，正在写磁盘（页被锁住）
  folio_end_writeback()  写完成后清除 PG_writeback
```

在 `shrink_folio_list` 中，如果页是 dirty，先触发 `writepage`（通过 `__filemap_fault` 路径），等 `folio_end_writeback()` 后才认为可回收。

## 5. PG_active / PG_reclaim 状态机 — 页在 LRU 上的生命周期

### 5.1 经典 LRU 状态机（CONFIG_LRU_GEN=n）

```
                            ┌─ 访问（refault）─┐
  ┌────────────────────────────┐           │
  │                            ▼           │
  │  [active]  ───────────────────────────────▶ [inactive]
  │  LRU_ACTIVE                 refaults   LRU_INACTIVE
  │  (PG_active=1)                              (PG_active=0)
  │                            │
  │   folio_test_active()      │           ┌─ 内核使用次数多
  │   folio_set_active()       │           │  folio_test_referenced()
  │                            │           └─ folio_inc_refs()
  │   shrink_active_list()      │                      │
  │   (referenced太少)          │                      ▼
  │         │                   │           ┌──────────────────┐
  │         ▼                   │           │ folio_inc_gen()  │
  │   移到 inactive             │           │ age恢复：提升 gen  │
  │                            │           └──────────────────┘
  │   释放或换出                 │
  │                            │
  └────────────────────────────┘
```

### 5.2 shrink_active_list 决策

```c
// vmscan.c:2068
static void shrink_active_list(unsigned long nr_to_scan, ...)
{
    while (!list_empty(&l_hold)) {
        vm_flags = folio_vm_flags(folio);

        // 如果映射有 VM_EXEC → 经常访问 → 放回 active（头插）
        if (vm_flags & VM_EXEC) {
            lruvec_add_folio(lruvec, folio);
        }
        // 如果是文件页且被 reference → age 恢复
        else if (folio_test_referenced(folio) && folio_is_file_lru(folio)) {
            folio_inc_gen(lruvec, folio, true);  // gen++ → age 恢复
            lruvec_add_folio(lruvec, folio);    // 放回 inactive 尾部
        }
        // 无引用 → 移到 inactive 等待回收
        else {
            lruvec_add_folio(lruvec, folio);    // 加到 inactive 尾
        }
    }
}
```

### 5.3 refault 与 age 恢复（workingset detection）

```c
// vmscan.c:2313 当 refaults 增加时
refaults = lruvec_page_state(target_lruvec, WORKINGSET_ACTIVATE_ANON);
if (refaults != target_lruvec->refaults[WORKINGSET_ANON]) {
    // refault 发生 → 说明 workingset 在增长
    // 快速 deactive stale active pages，抑制 age inflation
}
```

当一个页被 evict 后又快速 refault，Linux 认为这是一个新 working set 正在建立，会加速驱逐旧的 active 页。

### 5.4 多代 LRU 状态机（CONFIG_LRU_GEN=y, 7.0-rc1 默认启用）

```c
// vmscan.c:3223
static int folio_inc_gen(struct lruvec *lruvec, struct folio *folio, bool reclaiming)
{
    int type = folio_is_file_lru(folio);
    // gen 存储在 folio->flags 的 LRU_GEN_MASK 位域
    new_flags = (gen+1) << LRU_GEN_PGOFF | BIT(PG_workingset);
}
```

不再用简单的 active/inactive 二分法，而是用多代（multi-generational）LRU：

```
时间轴 ───────────────────────────────────────────────────▶

 Gen N (最老)  | Gen N+1 | Gen N+2 | ... | Gen MAX (最新)
   ↓ evict     ↓ age    ↓ age            ↑ refault
```

每个代龄在 `lruvec->lrugen` 中有独立的计数，当 `min_seq[type]` 推进时，最老的代被整体 reclaim。这解决了传统 LRU 的"one-time access"问题（只访问一次的页不会因为一次访问就长期占居 active）。

## 6. compaction — 为什么需要迁移页而非直接释放

### 6.1 核心矛盾

分配大页（order > 0）需要**连续物理内存**，而直接释放只能得到分散的 4KB 页。compaction 通过**迁移页**来合并空闲块——将已分配的页移动到其他位置，把被隔离的空闲页拼接成连续区域。

### 6.2 isolate_migratepages 协同工作流

```c
// mm/compaction.c:2062
static isolate_migrate_t isolate_migratepages(struct compact_control *cc)
{
    // 扫描 zone 的 PFN，寻找可迁移的页
    while ((pfn = scan_migrate_pages(cc)) != 0) {
        // 对每个 migrate type 分离：
        // MIGRATE_UNMOVABLE   — 不能迁移（kernel 栈、dma-buf 等）
        // MIGRATE_MOVABLE     — 可迁移（大部分用户页）
        // MIGRATE_CMA         — CMA 预留区
        // MIGRATE_RECLAIMABLE — 文件页，可回收（先回收再迁移）
        isolate_migratepages_block(cc, low_pfn, block_end_pfn, ...);
    }
}
```

### 6.3 compact_finished — 何时返回成功

```c
// mm/compaction.c:2251
static enum compact_result __compact_finished(struct compact_control *cc)
{
    // 1. migrate scanner 和 free scanner 碰头 → 成功
    if (compact_scanners_met(cc)) {
        reset_cached_positions(cc->zone);
        if (cc->whole_zone)
            return COMPACT_COMPLETE;
        return COMPACT_PARTIAL_SKIPPED;
    }

    // 2. proactive compact：检查碎片分数
    if (cc->proactive_compaction) {
        if (fragmentation_score_node(pgdat) <= fragmentation_score_wmark(false))
            return COMPACT_SUCCESS;  // 碎片可接受
    }

    // 3. 检查 watermark（用于高阶分配）
    // ...

    return COMPACT_CONTINUE;  // 继续扫描
}
```

### 6.4 migrate_vma（DRAM/NVM 异构场景）

```c
// 异构内存系统中，migrate_vma 将页从 DRAM 迁移到 NVM（或反向）
migrate_vma(pgdat, cc->zone, order, ...)
  └→ isolate_migratepages_range()  // 分离特定 PFN 范围
  └→ migrate_pages()               // 执行物理地址重映射
  └→ 旧位置 → 更新页表（PTE → new physical）
```

compaction 和 migrate_vma 都依赖**页表锁**（PTE lock）来原子地重映射，这意味着可迁移页的虚拟地址保持不变（只有物理地址改变）。

## 7. swap 机制 — 匿名页换出

### 7.1 触发条件

```c
// vmscan.c:2504
if (!sc->may_swap || !can_reclaim_anon_pages(...)) {
    scan_balance = SCAN_FILE;  // 禁用匿名换出
    goto out;
}
```

匿名页被换出的条件组合：

1. **有可用 swap 设备**（`swapon` 已配置 swap 分区）
2. **may_swap = true**（非 MEMCG_HARDLIMIT 场景）
3. **swappiness > 0**（=0 时代替 scan_balance == SCAN_FILE）
4. **inactive ratio 满足**（`inactive_is_low()` 判定）

### 7.2 swap cache 与匿名页关系

```
未映射的匿名页：
  anon_vma → PTE → (无 swap entry)
  
  换出时 add_to_swap()：
    分配 swap entry（swp_entry_t）
    创建 swap cache（folio_add_to_swap_cache）
    写入 swap 设备（__swap_writepage）
  
  换入时：
    读 swap 设备 → 找到 swap cache → 映射回用户地址
    swapcache_free() → 删除 swap cache
```

**swap cache 的作用**：避免同一页同时被 swap 设备和 page cache 引用，造成写回冲突。匿名页一旦进入 swap cache，就通过 `folio_test_swapcache()` 区分于普通文件页。

### 7.3 swap 性能为什么比 file-backed 差

| 维度 | swap (匿名页) | file-backed |
|------|------------|------------|
| 写路径 | `add_to_swap_cache` → `__swap_writepage` → 块设备 | `filemap_writepage` → `mapping->a_ops->writepage` |
| 读路径 | `swap_read_folio` → 块设备 → 映射 | 直接 page cache 命中（无 IO） |
| 写放大 | 每次一个匿名页单独写（4KB） | 可以 `mpage_submit_page` 合并 |
| 缓存 | swap cache + swap device | page cache + disk（通一个地址空间） |
| 预读 | swap 没有预读机制 | 文件有 readahead 优化 |
| 压缩 | zswap 等可压缩，但需 CPU 开销 | 通常不压缩 |

## 8. 完整路径状态机

```
                    ┌─────────────────────────────┐
                    │   内存分配失败 / low wmark   │
                    └──────────┬──────────────────┘
                               │
              ┌────────────────┴────────────────┐
              ▼                                 ▼
   ┌──────── kswapd 醒来 (low wmark)    direct reclaim (min wmark)
   │                                   │
   │  kswapd_shrink_node()             │  shrink_node()
   │    ├─ nr_to_reclaim = 0           │    ├─ nr_to_reclaim = sc预设
   │    ├─ pgdat_balanced(high)?       │    ├─ get_scan_count()
   │    │     └─ ❌ 继续扫描            │    │     └─ SCAN_EQUAL/FRACT/ANON/FILE
   │    └─ 平衡 → 睡眠                 │    └─ shrink_lruvec()
   │                                  │
   │                                  ▼
   │                       ┌───────────────────────┐
   │                       │ shrink_lruvec()        │
   │                       │  ├─ get_scan_count()   │
   │                       │  └─ for each lruvec:  │
   │                       │       shrink_list()    │
   │                       │         ├─ inactive   │
   │                       │         │   scan      │
   │                       │         │   ↓          │
   │                       │         │ shrink_inactive_list()
   │                       │         │   ├─ isolate_lru_folios()
   │                       │         │   └─ shrink_folio_list()
   │                       │         │         ├─ file页: writepage
   │                       │         │         ├─ anon页: add_to_swap
   │                       │         │         └─ free folio
   │                       │         │   ↓
   │                       │         └─ active scan
   │                       │             shrink_active_list()
   │                       │               ├─ refault → age恢复
   │                       │               └─ 无ref → 移inactive
   │                       ▼              ↓
   │              ┌──────────────────────┴──────┐
   │              │   should_continue_reclaim()  │
   │              │   ├─ compaction_suitable()?  │
   │              │   └─ zone_watermark_ok()?    │
   │              │        ├─ yes → 停止回收     │
   │              │        └─ no  → 继续或 OOM   │
   │              └──────────────────────────────┘
   │
   │   ┌──────────────────────────┐
   └──┐│    compaction 路径        │
      ││  (order > 0 allocation)  │
      ││                           │
      ││  isolate_migratepages()   │
      ││    scan_migrate_pages()   │
      ││    isolate_migratepages_block()
      ││         ↓
      ││  migrate_pages()
      ││    ├─ MOVABLE → 直接迁移
      ││    └─ UNMOVABLE → 跳过
      ││         ↓
      ││  compact_finished()
      ││    ├─ scanners_met → COMPACT_COMPLETE
      ││    └─ !met → COMPACT_CONTINUE
      ││         ↓
      ││  成功：free scanner 拿到足够大连续块
      │└──────────────────────────┘
      │
      │  ┌───────────────────────────────────┐
      └──┤  OOM killer 路径                    │
         │  所有 zone < min_wmark              │
         │  且 direct reclaim 已尽力           │
         │  → out_of_memory()                  │
         │    select_bad_process()             │
         │    oom_kill_process()               │
         └───────────────────────────────────┘
```

## 9. inactive_is_low — 何时停止向 inactive 转移

```c
// vmscan.c:2257
static bool inactive_is_low(struct lruvec *lruvec, enum lru_list inactive_lru)
{
    inactive = lruvec_page_state(lruvec, NR_LRU_BASE + inactive_lru);
    active   = lruvec_page_state(lruvec, NR_LRU_BASE + active_lru);
    gb = (inactive + active) >> (30 - PAGE_SHIFT);
    inactive_ratio = gb ? int_sqrt(10 * gb) : 1;

    return inactive * inactive_ratio < active;
}
```

- **内存大 → inactive_ratio 增大**：大内存系统要求更高的 inactive:active 比例才认为"足够"
- **小内存 → inactive_ratio = 1**：比例为 1:1 即可

这个比例确保当 active 列表太小（大量热点数据）时，不会过度向 inactive 迁移导致 working set 被错误 evict。

## 10. 关键数据结构汇总

| 结构体/宏 | 文件 | 作用 |
|-----------|------|------|
| `struct lruvec` | mmzone.h:757 | per-node LRU 链表容器 |
| `enum lru_list` | mmflags.h | LRU 链表类型枚举 |
| `folio_lru_list()` | mm_inline.h:82 | 查页 → LRU 链表类型 |
| `struct scan_control` | vmscan.c | 回收控制参数 |
| `enum scan_balance` | vmscan.c:2276 | 匿名/文件扫描策略 |
| `get_scan_count()` | vmscan.c:2493 | 计算各 LRU 扫描数量 |
| `pgdat_balanced()` | vmscan.c:6914 | 判断 node 是否平衡 |
| `shrink_folio_list()` | vmscan.c:1058 | 单 folio 回收判决 |
| `shrink_inactive_list()` | vmscan.c:1951 | 扫描 inactive LRU |
| `shrink_active_list()` | vmscan.c:2068 | active → inactive 转移 |
| `folio_inc_gen()` | vmscan.c:3223 | 多代 LRU age 推进 |
| `compact_finished()` | compaction.c:2362 | compaction 是否成功 |
| `isolate_migratepages()` | compaction.c:2062 | 隔离可迁移页 |
| `__swap_writepage()` | page_io.c:451 | 写匿名页到 swap 设备 |

## 11. 核心设计哲学

1. **分层防御**：kswapd 先于 direct reclaim 响应（low vs min wmark），避免进程阻塞
2. **工作集保护**：refault 检测确保热点页不被轻易 evict，inactive ratio 机制防止过激回收
3. **比例公平**：swappiness 允许管理员调优 anon/file 扫描比例，OOM 时强制 SCAN_EQUAL
4. **compaction 不释放而是移动**：大页分配需要连续空间，只有迁移才能合并碎片
5. **swap cache 解歧义**：匿名页和文件页都可能有 swap entry，通过 swap cache 区分
6. **多代 LRU 解决 one-time access**：传统 LRU 无法区分一次访问和频繁访问，多代 LRU 用时间轴替代简单的 active/inactive 二分


---

## doom-lsp 源码分析

> 以下分析基于 Linux 7.0 主线源码，使用 doom-lsp (clangd LSP) 进行深度符号分析

### 文件分析摘要

| 源文件 | 符号数 | 结构体 | 函数 | 变量 |
|--------|--------|--------|------|------|
| `mm/vmscan.c` | 168 | 3 | 96 | 9 |

### 核心数据结构

- **scan_control** `vmscan.c:74`
- **(anonymous struct)** `vmscan.c:170`
- **pageout_t** `vmscan.c:606`

### 关键函数

- **cgroup_reclaim** `vmscan.c:206`
- **root_reclaim** `vmscan.c:215`
- **writeback_throttling_sane** `vmscan.c:233`
- **sc_swappiness** `vmscan.c:244`
- **set_task_reclaim_state** `vmscan.c:272`
- **flush_reclaim_state** `vmscan.c:288`
- **can_demote** `vmscan.c:324`
- **can_reclaim_anon_pages** `vmscan.c:344`
- **zone_reclaimable_pages** `vmscan.c:374`
- **lruvec_lru_size** `vmscan.c:393`
- **drop_slab_node** `vmscan.c:408`
- **drop_slab** `vmscan.c:421`
- **reclaimer_offset** `vmscan.c:446`
- **handle_write_error** `vmscan.c:473`
- **skip_throttle_noprogress** `vmscan.c:482`
- **reclaim_throttle** `vmscan.c:510`
- **__acct_reclaim_writeback** `vmscan.c:584`
- **writeout** `vmscan.c:617`
- **pageout** `vmscan.c:653`
- **__remove_mapping** `vmscan.c:686`
- **remove_mapping** `vmscan.c:802`
- **folio_putback_lru** `vmscan.c:825`
- **lru_gen_set_refs** `vmscan.c:857`
- **folio_check_references** `vmscan.c:863`
- **folio_check_dirty_writeback** `vmscan.c:934`
- **alloc_demote_folio** `vmscan.c:965`
- **demote_folio_list** `vmscan.c:996`
- **may_enter_fs** `vmscan.c:1039`
- **shrink_folio_list** `vmscan.c:1058`
- **reclaim_clean_pages_from_list** `vmscan.c:1595`
- **update_lru_sizes** `vmscan.c:1650`
- **isolate_lru_folios** `vmscan.c:1685`
- **folio_isolate_lru** `vmscan.c:1802`
- **too_many_isolated** `vmscan.c:1828`
- **move_folios_to_lru** `vmscan.c:1872`

### 全局变量

- **vm_swappiness** `vmscan.c:201`
- **vmscan_sysctl_table** `vmscan.c:7670`
- **__UNIQUE_ID_addressable_kswapd_init_64** `vmscan.c:7703`
- **node_reclaim_mode** `vmscan.c:7712`
- **sysctl_min_unmapped_ratio** `vmscan.c:7725`
- **sysctl_min_slab_ratio** `vmscan.c:7731`
- **tokens** `vmscan.c:7899`
- **__UNIQUE_ID_addressable_check_move_unevictable_folios_71** `vmscan.c:8045`
- **dev_attr_reclaim** `vmscan.c:8058`

### 成员/枚举

- **nr_to_reclaim** `vmscan.c:76`
- **nodemask** `vmscan.c:82`
- **target_mem_cgroup** `vmscan.c:88`
- **anon_cost** `vmscan.c:93`
- **file_cost** `vmscan.c:94`
- **proactive_swappiness** `vmscan.c:97`
- **may_deactivate** `vmscan.c:102`
- **force_deactivate** `vmscan.c:103`
- **skipped_deactivate** `vmscan.c:104`
- **may_writepage** `vmscan.c:107`
- **may_unmap** `vmscan.c:110`
- **may_swap** `vmscan.c:113`
- **no_cache_trim_mode** `vmscan.c:116`
- **cache_trim_mode_failed** `vmscan.c:119`
- **proactive** `vmscan.c:122`
- **memcg_low_reclaim** `vmscan.c:132`
- **memcg_low_skipped** `vmscan.c:133`
- **memcg_full_walk** `vmscan.c:136`
- **hibernation_mode** `vmscan.c:138`
- **compaction_ready** `vmscan.c:141`

