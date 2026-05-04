# Linux 内存回收机制深度分析：kswapd / LRU / 直接回收

## 概述

内存回收是 Linux 内核中最复杂、最关键的内存管理子系统之一。当系统内存不足时，内核需要从 page cache、匿名页（swap）、slab 缓存中回收内存。Linux 采用**两级回收策略**：后台 kswapd 守护进程在内存压力达到阈值时异步回收，而直接回收（direct reclaim）在内存分配失败时同步触发。

内存回收的核心问题：
1. **何时回收**：通过水位线（watermark）和 kswapd 的平衡策略判断
2. **回收什么**：从 active/inactive LRU 链表中选择 victim 页面
3. **如何回收**：通过 shrinkers 回收 slab 缓存，通过 swap 回收匿名页，通过写回回收 file 页
4. **何时停止**：水位线恢复到目标水平

## 核心数据结构

### LRU 链表（`struct lruvec`）

（`include/linux/mmzone.h` L757~780）

```c
struct lruvec {
    struct list_head    lists[NR_LRU_LISTS];    // L761 — 5 种 LRU 链表
    spinlock_t          lru_lock;               // L763 — LRU 操作的自旋锁
    unsigned long       anon_cost;              // L766 — 匿名页回收成本
    unsigned long       file_cost;              // L767 — 文件页回收成本
    atomic_long_t       nonresident_age;        // L769 — 非驻留年龄（refault 检测）
    unsigned long       refaults[ANON_AND_FILE];// L771 — refault 计数
    unsigned long       flags;                  // L773
#ifdef CONFIG_LRU_GEN
    struct lru_gen_folio lrugen;                // L775 — 多代 LRU 扩展
    struct lru_gen_mm_state mm_state;           // L777 — MMU walk 状态
#endif
};
```

5 种 LRU 链表（`include/linux/mmzone.h` L387~392）：

```
enum lru_list {
    LRU_INACTIVE_ANON  = 0,   // 不活跃匿名页（可能被换出）
    LRU_ACTIVE_ANON    = 1,   // 活跃匿名页
    LRU_INACTIVE_FILE  = 2,   // 不活跃文件页（可能被回收）
    LRU_ACTIVE_FILE    = 3,   // 活跃文件页
    LRU_UNEVICTABLE    = 4,   // 不可回收页（如 mlock）
    NR_LRU_LISTS
};
```

其中 `for_each_evictable_lru(lru)` 遍历前 4 种。

### struct scan_control

（`mm/vmscan.c` L74~130）

```c
struct scan_control {
    unsigned long   nr_to_reclaim;          // 需要回收的页数
    nodemask_t      *nodemask;              // 扫描的 NUMA 节点掩码
    struct mem_cgroup *target_mem_cgroup;   // 目标 cgroup（cgroup 回收时）
    unsigned long   anon_cost;              // 匿名页扫描成本
    unsigned long   file_cost;              // 文件页扫描成本
    unsigned int    may_deactivate:2;       // 是否可以 deactivate
    unsigned int    force_deactivate:1;     // 强制 deactivation
    unsigned int    may_writepage:1;        // 是否可以写回
    unsigned int    may_unmap:1;            // 是否可以 unmap
    unsigned int    may_swap:1;             // 是否可以 swap
    unsigned int    proactive:1;            // 用户空间触发的主动回收
    unsigned int    memcg_low_reclaim:1;    // 是否回收 memcg low 保护
    unsigned int    memcg_low_skipped:1;    // 是否跳过保护 cgroup
    unsigned int    hibernation_mode:1;     // 休眠模式下回收
    ...
};
```

### 水位线（watermark）

每个 NUMA node 的 `struct zone` 有三种水位线：

```
  ┌─ 最高水位 (high)
  │   kswapd 在 high 水位停止回收
  │
  ├─ 最低水位 (low)
  │   kswapd 在 low 水位开始回收
  │
  └─ 最小水位 (min)
      直接回收在 min 水位触发
      在 min 水位以下时，PF_MEMALLOC 才允许分配
```

水位线通过 `_watermark[NR_WMARK]` 数组和 `watermark_boost` 机制动态调整。

## kswapd — 后台回收守护进程

### 启动与唤醒

kswapd 是每个 NUMA node 的内核线程：

```c
// mm/vmscan.c — 每个 node 在初始化时创建
pgdat->kswapd = kthread_run(kswapd, pgdat, "kswapd%d", pgdat->node_id);
```

`wakeup_kswapd()` 是触发入口，在 `__alloc_pages_slowpath()` 中调用：

```
wakeup_kswapd(zone, gfp_flags, order, highest_zoneidx)
  │
  ├─ 检查是否真的需要唤醒
  │    只有 zone 的水位低于 low 时才唤醒
  │    避免不必要的唤醒（NOZONE_IDLE 优化）
  │
  └─ wake_up_interruptible(&pgdat->kswapd_wait)
```

### kswapd 主循环

```
kswapd()                                        // mm/vmscan.c
  └─ kswapd_try_to_sleep(pgdat)                 // 尝试睡眠
  └─ balance_pgdat(pgdat, order, highest_zoneidx) // 回收目标

kswapd_try_to_sleep():
  ├─ 设置 kswapd 状态为 TASK_INTERRUPTIBLE
  ├─ prepare_to_wait(&pgdat->kswapd_wait, &wait, TASK_INTERRUPTIBLE)
  ├─ 如果所有 zone 水位 > high → 实际睡眠
  ├─ 如果被唤醒（wakeup_kswapd）→ 开始回收
  └─ 如果被 freeze（kswapd_freeze）→ 退出

balance_pgdat(pgdat, order, highest_zoneidx):
  ├─ 1. 计算所需水位
  │    根据分配 order 计算目标水位（order 越大需要越高水位）
  │    考虑 watermark_boost（透明大页分配造成的水位提升）
  │
  ├─ 2. 扫描所有 zone
  │    for each zone in pgdat:
  │      if (zone 水位 < target_watermark)
  │         标记为需要回收
  │
  ├─ 3. 执行回收（核心循环）
  │    while (任何需要回收的 zone 水位仍未达标):
  │      └─ kswapd_shrinker_node(pgdat, sc)  // 回收 slab
  │      └─ shrink_node(pgdat, sc)           // 回收 LRU 页面
  │            │
  │            ├─ get_scan_count(lruvec, sc, nr)  // 确定各 LRU 的扫描量
  │            │     考虑：swappiness、anon_cost/file_cost 比例、
  │            │     refault 历史、主动/被动回收标志
  │            │
  │            ├─ shrink_list(sc, lruvec, lru)    // 扫描并回收
  │            │    └─ shrink_inactive_list(lruvec, lru, sc)
  │            │         └─ isolate_lru_folios()   // 隔离页面
  │            │         └─ shrink_folio_list()    // 真正的回收
  │            │
  │            └─ shrink_active_list(lruvec, sc, lru)
  │                  └─ 检查 refault 距离
  │                  └─ 活跃页面降级（deactivate）到不活跃链表
  │                         page_referenced() 检查是否被引用
  │                         未引用 → 移到不活跃 LRU（准备回收）
  │                         已引用 → 留在活跃 LRU
  │
  │    如果可回收页不足 → 提高扫描优先级
  │    如果无法回收（OOM）→ raise priority 到最大
  │
  └─ 4. 更新水位统计
       pgdat->kswapd_failures = fail_count
       如果连续失败 → kswapd 睡眠更长时间
```

## 直接回收（Direct Reclaim）

当 kswapd 回收不够快，`__alloc_pages_slowpath()` 在 kswapd 唤醒后仍无法分配到内存时，发起直接回收：

```
__alloc_pages_slowpath()
  └─ __alloc_pages_may_oom() → 如果不允许 OOM
  └─ __alloc_pages_direct_reclaim(gfp_mask, order, ...)
       └─ __perform_reclaim(gfp_mask, order, ...)
            └─ try_to_free_pages(zone, sc)
                 └─ do_try_to_free_pages(zonelist, sc)
                      ├─ shrink_zones(zonelist, sc)     // 扫描所有 zone
                      └─ shrink_node(pgdat, sc)         // 每个 node 的回收

                      如果回收足够 → 返回
                      否则 → 重试（可能 OOM）
```

直接回收与 kswapd 的区别：
- kswapd 在后台运行，不影响前台进程延迟
- 直接回收在分配路径中同步执行，增加内存分配延迟
- 直接回收使用 `current` 的进程上下文（可能触发 I/O 等待）
- kswapd 使用 `PF_MEMALLOC | PF_KSWAPD` 标志，可以访问保留内存

## 页面回收决策：get_scan_count()

`get_scan_count()`（`mm/vmscan.c`）决定每个 LRU 链表应该扫描多少页。核心因素：

### 1. swappiness（扫描倾向）

`/proc/sys/vm/swappiness` 控制回收匿名页 vs 文件页的倾向：

```
默认值 60，范围 0~200：
  0：从不 swap（只回收文件页）
  60：默认，会适度 swap
  200：积极 swap（与文件页同样积极）
```

在 `get_scan_count()` 中，swappiness 通过 `anon_prio` 和 `file_prio` 实现：
- `anon_prio` 基于 swappiness 值（swappiness 越大，匿名页扫描比例越高）
- `file_prio` 与 swappiness 互补（200 - swappiness）× 4

### 2. refault 距离检测

Linux 使用 **refault distance** 算法动态平衡 active/inactive 比例。当页面被回收后再次访问（refault），内核检查该页面从活跃链表被移除到重新访问之间的时间（fault gap）：
- 如果 refault 距离小于活跃链表的长度 → 活跃链表太长，应该减少
- 如果 refault 距离大于活跃链表长度 → 不活跃链表太长，活跃链表需要更多保护

```c
// mm/workingset.c — refault 检测逻辑
lruvec->refaults[workingset] 记录了上次回收的 refault 次数
通过 nonresident_age 追踪非驻留页的年龄
```

### 3. anon_cost / file_cost

每次扫描后，根据扫描结果更新成本因子：
- 扫描匿名页发现大部分不可回收（被引用、脏页）→ `anon_cost` 增加
- 扫描文件页发现大量需要回写的脏页 → `file_cost` 增加
- `get_scan_count()` 用成本因子进一步调整扫描比例，避免在"不划算"的 LRU 上浪费时间

## shrink_folio_list() — 单页回收决策

（`mm/vmscan.c` 核心函数）

当页面从 LRU 链表被隔离后，`shrink_folio_list()` 决定每个页面的处理方式：

```
shrink_folio_list(folio, lruvec, sc)
  │
  ├─ 1. 检查页面的强制保留
  │     if (folio_test_unevictable(folio)) → 跳回 LRU_UNEVICTABLE
  │     if (folio_check_references(folio, sc)) → 被引用，跳回活跃链表
  │
  ├─ 2. 检查是否被 mlock
  │     if (munlock_folio(folio)) → 无法回收
  │
  ├─ 3. 检查脏页
  │     if (folio_test_dirty(folio)):
  │       ├─ 是否允许回写？(sc->may_writepage)
  │       ├─ 是否 sync 回收模式？
  │       └─ 如果不允许回写 → 跳过（跳到 swap 缓存检查）
  │
  ├─ 4. 检查文件页
  │     if (folio_test_private(folio) && !folio_test_swapcache(folio)):
  │       ├─ 检查是否被引用
  │       └─ 释放页面
  │
  └─ 5. 匿名页处理
        if (folio_test_anon(folio) && !folio_test_swapbacked(folio)):
          └─ 如果允许 swap → try_to_unmap() + swap_out()
          └─ 如果禁用了 swap → 无法回收，跳到写回检查
        
        最终：try_to_free_swap() 或 add_to_swap() + swap_writepage()
```

处理结果：

| 结果 | 操作 | 后续 |
|------|------|------|
| 成功回收 | `__remove_mapping()` | 释放 folio 到 buddy 系统 |
| 被引用 | 跳回 active LRU | 保护 hot 页 |
| 脏页无法回写 | 留在 inactive LRU | 等 kswapd 回写 |
| unevictable | 移到 UNEVICTABLE 链表 | 不再回收 |
| swap 失败 | 留在 inactive | 等下次机会 |

## Slab 回收：shrinkers

除了 LRU 页面回收，slab 缓存（dentry、inode、buffer_head 等）通过 shrinker 接口回收：

```
kswapd_shrinker_node(pgdat, sc)
  └─ for each registered shrinker:
       do_shrink_slab(&shrink, shrinker, priority)
         └─ shrinker->count_objects()    // 统计可回收对象数
         └─ shrinker->scan_objects()     // 扫描并回收
              // 实际回收由各个 slab cache 的 shrinker 回调实现
```

典型 shrinker 示例：

| Slab 缓存 | Shrinker | 回收目标 |
|-----------|----------|---------|
| dentry | `shrink_dcache_memory()` | dentry cache |
| inode | `shrink_icache_memory()` | inode cache |
| ext4 | `ext4_es_shrinker()` | extent status tree |
| zswap | `zswap_shrinker()` | zswap pool |
| memcg | `memcg_reparent_objcgs()` | cgroup 对象 |

## 页面老化与 active/inactive 平衡

Linux 通过**二次机会（second chance）** 算法实现页面年龄跟踪：

### 页面引用检查

```c
// mm/rmap.c — page_referenced()
page_referenced(folio, is_locked, memcg, vm_flags)
  └─ rmap_walk(folio, &rwc)    // 遍历所有映射该页面的 PTE
       └─ pte_young(ptep_get(pte))  // 检查 PTE 的 Accessed 位
                                      // x86 硬件自动设置 Accessed 位
```

### active/inactive 迁移

```
页面生命周期：
  分配 → 跳转到 inactive 链表（LRU_INACTIVE_FILE 或 LRU_INACTIVE_ANON）
         ↓
  首次访问 → 检查 PTE accessed 位
              ├─ 如果最近被访问 → 提升到 active 链表
              └─ 如果未被访问 → 留在 inactive
         ↓
  shrink_active_list():
    扫描 active 链表，检查 PTE accessed 位：
    ├─ 最近被访问的 → 重置 accessed 位，留在 active 链表（第二次机会）
    └─ 未被访问的 → 降级到 inactive 链表（准备回收）
         ↓
  shrink_inactive_list():
    从 inactive 中回收页面
         ↓
  页面被回收 → 如果页面关联的是 tmpfs/swap 缓存 → 加入 workingset
```

### 工作集检测

`mm/workingset.c` 实现了内核的工作集模型。当页面被回收后又被访问（refault），`workingset_refault()` 检查该页面被回收的时间长度。

```c
// mm/workingset.c
void workingset_refault(struct folio *folio, void *shadow)
{
    // 计算 refault distance
    refault_dist = lruvec->nonresident_age - shadow_eviction_lru;
    
    // 如果 refault 发生在预期外（工作集 > 内存大小）：
    // 增加相应的 lruvec->refaults[]
    // get_scan_count() 据此调整扫描策略
    
    // 如果工作集小于可用内存：
    // 页面直接恢复到 active 链表（快速激活）
}
```

## 水位线管理

### watermark 计算

`__setup_per_zone_wmarks()` 根据 zone 大小和 `min_free_kbytes` 计算水位线：

```c
// mm/page_alloc.c
void __setup_per_zone_wmarks(void)
{
    // min = min_free_kbytes / nr_zones / pageblock_nr_pages 等
    // low  = min * 125% (或 150% 取决于 min_free_kbytes)
    // high = min * 150% (或 200%)
    // 同时考虑预留空间（hugetlb 等）
}
```

### watermark_boost

当 THP（透明大页）等巨型分配失败时，内核提升水位线以便更激进地回收，为巨型分配创造条件：

```c
// 通过 kswapd 的 watermark_boost 机制
pgdat->watermark_boost = boost;  // 提升值
```

## LRU 二代（MGLRU — Multi-Generational LRU）

Linux 6.1+ 引入了多代 LRU（`CONFIG_LRU_GEN`），对传统 active/inactive LRU 的改进：

```
传统 LRU:  [active]  ↔  [inactive]  ↔  [回收]
                ↑           ↓
             访问       老化扫描

MGLRU:  [gen 0] → [gen 1] → [gen 2] → [gen 3] → ... → [回收]
          ↑                     ↓
       +访问               所有页面统一老化
       
每个 generation 是一个 FIFO 链表
页面在访问时提升到最新 generation
老化为周期性推进 max_seq（所有页面统一 age）
```

MGLRU 的优势：
- **减少扫描**：传统 LRU 需要扫描几十万个页面来找到可回收的，MGLRU 只需要检查最老的 generation
- **更好的工作集检测**：generation 边界天然区分热点和非热点
- **更低的 CPU 开销**：每个页面只需要在 generation 切换时处理一次

## 调用链总览

```
内存分配路径触发回收：

__alloc_pages_nodemask()
  ├─ get_page_from_freelist()      // 快速路径
  │    如果没有足够的 free pages → 进入慢路径
  │
  └─ __alloc_pages_slowpath()      // 慢路径
       ├─ wake_all_kswapds()       // 唤醒所有 node 的 kswapd
       │    └─ wakeup_kswapd()     // 异步回收
       │
       ├─ __alloc_pages_direct_reclaim()  // 直接回收
       │    └─ try_to_free_pages()
       │         └─ shrink_node()          // LRU 回收
       │         └─ do_shrink_slab()       // slab 回收
       │
       ├─ __alloc_pages_direct_compact()   // 内存压缩
       │
       └─ __alloc_pages_may_oom()          // OOM kill
```

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct lruvec` | include/linux/mmzone.h | 757 |
| `enum lru_list` | include/linux/mmzone.h | 387 |
| `struct scan_control` | mm/vmscan.c | 74 |
| `kswapd()` | mm/vmscan.c | 附近 |
| `kswapd_try_to_sleep()` | mm/vmscan.c | 附近 |
| `balance_pgdat()` | mm/vmscan.c | 附近 |
| `wakeup_kswapd()` | mm/vmscan.c | 附近 |
| `shrink_node()` | mm/vmscan.c | 附近 |
| `get_scan_count()` | mm/vmscan.c | 附近 |
| `shrink_folio_list()` | mm/vmscan.c | 附近 |
| `shrink_inactive_list()` | mm/vmscan.c | 附近 |
| `shrink_active_list()` | mm/vmscan.c | 附近 |
| `isolate_lru_folios()` | mm/vmscan.c | 附近 |
| `do_shrink_slab()` | mm/vmscan.c | 附近 |
| `try_to_free_pages()` | mm/vmscan.c | 附近 |
| `workingset_refault()` | mm/workingset.c | 附近 |
| `page_referenced()` | mm/rmap.c | 附近 |
| `__setup_per_zone_wmarks()` | mm/page_alloc.c | 附近 |
| `__alloc_pages_slowpath()` | mm/page_alloc.c | 附近 |
| `watermark_boost` | include/linux/mmzone.h | (pglist_data 中) |
| `struct lru_gen_folio` | include/linux/mmzone.h | (MGLRU) |
