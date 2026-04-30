# memory cgroup (memcg) — 内存控制组深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/memcontrol.c` + `include/linux/memcontrol.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**memory cgroup**（memcg）是 Linux cgroup v1 的内存资源控制器，提供 per-cgroup 的内存限制和统计。

---

## 1. 核心数据结构

### 1.1 mem_cgroup — 内存控制组

```c
// mm/memcontrol.c — mem_cgroup
struct mem_cgroup {
    struct cgroup_subsys_state css;        // cgroup 基类

    // 内存限制（字节）
    unsigned long           soft_limit;       // 软限制（soft limit）
    unsigned long           low_limit;        // 低水位（low）
    unsigned long           high_limit;       // 高水位（memory.high）
    unsigned long           max_limit;        // 最大限制（memory.max）

    // 当前使用
    atomic64_t             memoryusage;       // 当前内存使用（字节）
    atomic64_t             workingset_usage; // 工作集大小（LRU 活跃页）
    atomic64_t             kmemusage;         // 内核内存使用（kmemcg）

    // per-node 统计
    struct mem_cgroup_per_node *nodeinfo[0];
};
```

### 1.2 mem_cgroup_per_node — per-node 统计

```c
// mm/memcontrol.c — mem_cgroup_per_node
struct mem_cgroup_per_node {
    // LRU（最近最少使用）链表
    struct lruvec           lruvec;

    // 统计
    atomic64_t             usage;            // 本节点内存使用
    atomic64_t             stat[NR_MEMCG_EVENTS]; // 事件计数
    //   MEMCG_LOW        = 0
    //   MEMCG_HIGH       = 1
    //   MEMCG_MAX        = 2
    //   MEMCG_OOM        = 3
};
```

---

## 2. 内存计费

### 2.1 try_charge — 尝试计费

```c
// mm/memcontrol.c — try_charge
int try_charge(struct mem_cgroup *memcg, gfp_t gfp_mask, unsigned int nr_pages)
{
    // 1. 检查 memory.high（高水位）
    if (soft_limit_exceeded(memcg)) {
        // 触发异步回收
        schedule_work(&memcg->high_work);
    }

    // 2. 尝试计费到 memcg
    if (page_counter_charge(&memcg->memory, nr_pages)) {
        // 计费失败（超过 memory.max）
        if (gfp_mask & __GFP_NOFAIL) {
            // 必须成功，等待回收
            wait_event(memcg->high_watermark,
                       !page_counter_charge(&memcg->memory, nr_pages));
        } else {
            // 返回 -ENOMEM
            return -ENOMEM;
        }
    }

    // 3. 层级传播：向父级计费
    if (parent(memcg))
        page_counter_charge(parent(memcg)->memory, nr_pages);

    return 0;
}
```

### 2.2 page_counter_charge — 计数器增加

```c
// mm/page_counter.c — page_counter_charge
bool page_counter_charge(struct page_counter *wc, unsigned long nr_pages)
{
    struct page_counter *p;

    // 从当前 cgroup 向上遍历到 root
    for (p = wc; p; p = p->parent) {
        // 使用原子操作更新计数
        if (atomic_long_add_return(nr_pages, &p->usage) > p->limit) {
            // 超过限制，回退
            atomic_long_sub(nr_pages, &p->usage);
            return false;  // 计费失败
        }
    }
    return true;  // 成功
}
```

---

## 3. OOM 处理

### 3.1 mem_cgroup_oom — OOM 触发

```c
// mm/memcontrol.c — mem_cgroup_oom
static bool mem_cgroup_oom(struct mem_cgroup *memcg, gfp_t gfp_mask, int order)
{
    // 1. 标记 OOM
    memcg->oom_memcg = memcg;
    memcg_wb_stats(memcg);  // 更新统计

    // 2. 如果是异步回收（GFP_KERNEL），触发 OOM killer
    if (!(gfp_mask & __GFP_DIRECT_RECLAIM)) {
        return false;  // 延迟 OOM
    }

    // 3. 调用内存 OOM killer
    mem_cgroup_oom_reclaim(memcg, gfp_mask, order);

    return true;
}
```

### 3.2 OOM 杀死进程

```c
// mm/memcontrol.c — mem_cgroup_oom_reclaim
static void mem_cgroup_oom_reclaim(struct mem_cgroup *memcg, gfp_t gfp_mask, int order)
{
    unsigned long nr_reclaimed;

    // 1. 尝试回收本 cgroup 的页
    nr_reclaimed = try_to_reclaim_memcg(memcg, nr_pages, gfp_mask);

    if (nr_reclaimed >= nr_pages)
        return;  // 成功回收

    // 2. 如果不够，杀死本 cgroup 中最"糟糕"的进程
    mem_cgroupOOM_wake(memcg);
}
```

---

## 4. cgroup v2 统一层级

```
cgroup v2 中，memory 控制器与其他控制器共存于同一树：
  /sys/fs/cgroup/
    /user/
      /alice/           ← alice 的所有资源（cpu、memory、io...）
      /bob/             ← bob 的所有资源
    /system.slice/      ← 系统服务
      /nginx.service/   ← nginx 的资源限制
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `mm/memcontrol.c` | `struct mem_cgroup`、`try_charge`、`mem_cgroup_oom` |
| `mm/page_counter.c` | `page_counter_charge` |
| `include/linux/memcontrol.h` | memcg 辅助函数 |