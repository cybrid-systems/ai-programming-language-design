# memcg — 内存控制组深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/memcontrol.c` + `include/linux/memcontrol.h`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**memcg（Memory Cgroup）** 是 cgroup v1 的内存控制器，为每个 cgroup 提供独立的内存限制和统计。

---

## 1. 核心数据结构

### 1.1 mem_cgroup — 控制组内存状态

```c
// include/linux/memcontrol.h — mem_cgroup
struct mem_cgroup {
    // cgroup 基础
    struct cgroup_subsys_state    css;             // 基类
    struct mem_cgroup             *parent;         // 父组

    // 使用量统计
    atomic64_t                     memory.usage;   // 当前内存使用（字节）
    atomic64_t                     memory.stat[NR_MEMCG_STAT]; // 详细统计
    atomic64_t                     memory.events;   // 事件计数（OOM 等）
    unsigned long                  memory.low;     // 下限（软限制）
    unsigned long                  memory.high;     // 上限（触发回收）

    // 限制
    unsigned long                  memory.min;     // 最小保留
    unsigned long                  memory.max;     // 硬限制
    unsigned long                  soft_limit;     // 软限制

    // 层级 LRU
    struct mem_cgroup_lru_state    lru;             // LRU 链表

    // socket 压力
    unsigned long                  socket_pressure; // socket 内存压力

    // OOM
    struct OOM_control {
        bool                enabled;               // OOM 是否启用
        struct task_struct  *chosen;               // 被杀的进程
        unsigned long       killed;               // 是否已杀
    } oom;
};
```

### 1.2 memory_stat — 详细统计

```c
// mm/memcontrol.c — memory.stat
enum mem_cgroup_stat_item {
    MEMCG_CACHE,              // Page cache
    MEMCG_RSS,                // Anonymous + swap cache
    MEMCG_RSS_HUGE,           // Anonymous huge
    MEMCG_SHMEM,              // Shared memory
    MEMCG_FILE_MAPPED,        // File-backed
    MEMCG_FILE_DIRTY,         // Dirty pages
    MEMCG_FILE_WRITEBACK,     // Writeback pages
    NR_MEMCG_STAT,
};
```

---

## 2. 页面统计（page_counter）

```c
// include/linux/page_counter.h — page_counter
struct page_counter {
    atomic_long_t             usage;       // 当前使用（页数）
    unsigned long             limit;       // 限制（页数）
    unsigned long             soft_limit;  // 软限制
    unsigned long             min;         // 最小保留
    unsigned long             max;         // 硬限制

    struct page_counter       *parent;     // 父 counter
    unsigned long             failcnt;    // 触发次数
};
```

---

## 3. 收费（charge）流程

### 3.1 mem_cgroup_charge — 页面收费

```c
// mm/memcontrol.c — mem_cgroup_charge
int mem_cgroup_charge(struct page *page, struct mem_cgroup *memcg,
                      gfp_t gfp_mask)
{
    // 1. 找到正确的 memcg（如果是 thread，可能不是根 memcg）
    if (!memcg)
        memcg = get_mem_cgroup_from_mm(current->mm);

    // 2. 检查限制
    if (!page_counter_try_charge(&memcg->memory, 1, &counter)) {
        // 超过限制 → 触发 reclaim
        mem_cgroup_oom(memcg, gfp_mask);
        goto force_reclaim;
    }

    // 3. 设置 page->mem_cgroup
    page->mem_cgroup = memcg;

    // 4. 加入 memcg LRU
    mem_cgroup_add_lru(page);

    return 0;
}
```

---

## 4. 层级合并（Hierarchical Reclaim）

```c
// mm/memcontrol.c — mem_cgroup_oom_reclaim
static bool mem_cgroup_oom_reclaim(struct mem_cgroup *memcg, ...)
{
    // 1. 计算本层 + 所有子层总使用量
    long nr_pages = mem_cgroup_read_events(memcg, MEMCG_OOM);

    if (mem_cgroup_exceeds_swap_limit(memcg))
        // 如果超 swap limit，优先 reclaim swap
        nr_pages += try_to_free_mem_cgroup_pages(memcg, nr_pages, gfp_mask);

    return nr_pages > 0;
}
```

---

## 5. OOM 处理

```c
// mm/memcontrol.c — mem_cgroup_oom
static void mem_cgroup_oom(struct mem_cgroup *memcg, gfp_t mask)
{
    // 1. 检查是否启用 OOM
    if (!memcg->oom.enabled)
        return;

    // 2. 设置当前任务
    memcg->oom.chosen = current;

    // 3. 发送 SIGKILL（如果无法恢复）
    if (mask & __GFP_FS) {
        mem_cgroup_kmem_disconnect(memcg);
        mem_cgroup_run_oom_killer(memcg);
    }
}
```

---

## 6. 软限制（soft_limit）

```c
// mm/memcontrol.c — mem_cgroup_soft_limit_tree
static struct mem_cgroup *mem_cgroup_soft_limit_tree(struct mem_cgroup *memcg)
{
    // soft_limit 树：按使用量排序
    // 当内存压力时，从超 soft_limit 的组开始 reclaim
    // 最先 reclaim 使用量超 soft_limit 最多的组
}
```

---

## 7. /sys/fs/cgroup/ 接口

```
/sys/fs/cgroup/memory/<cgroup>/
├── memory.limit_in_bytes        ← 内存限制
├── memory.soft_limit_in_bytes   ← 软限制
├── memory.min_in_bytes         ← 最小保留
├── memory.max_in_bytes         ← 硬限制
├── memory.current              ← 当前使用
├── memory.events              ← OOM 等事件数
├── memory.stat                 ← 详细统计
├── memory.pressure             ← 内存压力
└── memory.swap.current         ← Swap 使用
```

---

## 8. 与 cgroup v2 的区别

| 特性 | cgroup v1 memcg | cgroup v2 memory |
|------|----------------|-----------------|
| 层级 | 每个控制器独立树 | 统一层级 |
| 软限制 | 有 | 无（需要用户空间实现）|
| OOM | 基于 memcg | 基于 cgroup2 |
| 压力检测 | 有 | 有 |

---

## 9. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/memcontrol.h` | `struct mem_cgroup`、`enum mem_cgroup_stat_item` |
| `include/linux/page_counter.h` | `struct page_counter` |
| `mm/memcontrol.c` | `mem_cgroup_charge`、`mem_cgroup_oom` |