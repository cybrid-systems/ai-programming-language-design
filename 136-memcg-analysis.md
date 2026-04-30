# Linux Kernel memory cgroup (memcg) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/memcontrol.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：memory.max、memory.pressure、hierarchical accounting

---

## 1. memory cgroup 核心

```c
// mm/memcontrol.c — mem_cgroup
struct mem_cgroup {
    struct cgroup_subsys_state css;        // cgroup 基类

    // 内存限制
    unsigned long           soft_limit;       // 软限制
    unsigned long           low_limit;        // 低水位
    unsigned long           high_limit;       // 高水位（memory.high）
    unsigned long           max_limit;        // 最大限制（memory.max）

    // 统计
    atomic64_t             memoryusage;       // 当前内存使用
    atomic64_t             workingsetusage;   // 工作集大小
    atomic64_t             kmemusage;         // 内核内存使用

    // 层级统计
    struct mem_cgroup_per_node *nodeinfo[0]; // per-node 统计
};
```

---

## 2. 内存计费

```c
// mm/memcontrol.c — try_charge
int try_charge(struct mem_cgroup *memcg, gfp_t gfp_mask, unsigned int nr_pages)
{
    // 1. 检查是否超过限制
    if (page_counter_charge(&memcg->memory, nr_pages)) {
        // 超过限制
        if (do_oom(memcg))
            return -ENOMEM;

        // 等待 reclaim
        try_to_free_mem_cgroup_pages(memcg, nr_pages, gfp_mask);
    }

    // 2. 层级传播
    if (parent(memcg))
        page_counter_charge(&parent(memcg)->memory, nr_pages);

    return 0;
}
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `mm/memcontrol.c` | memcg 核心实现 |
