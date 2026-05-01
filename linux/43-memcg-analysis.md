# 43-memcg — 内存控制组深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**memcg（Memory Cgroup）** 限制和审计 cgroup 中进程的内存使用量（包括 RSS、page cache、kernel memory 等）。

doom-lsp 确认 `mm/memcontrol.c` 包含约 393+ 个符号。

---

## 1. 核心结构

### 1.1 struct mem_cgroup

```c
struct mem_cgroup {
    struct cgroup_subsys_state css;      // cgroup 子系统状态

    struct page_counter      memory;     // 内存用量计数
    struct page_counter      memsw;      // 内存+交换计数
    struct page_counter      kmem;       // 内核内存计数

    unsigned long            soft_limit; // 软限制

    struct mem_cgroup_stat_cpu __percpu *stat; // Per-CPU 统计

    struct mem_cgroup_tree_per_node *nodeinfo[]; // NUMA 节点信息
    ...
};
```

---

## 2. 计费路径

```
分配内存时：
  │
  └─ try_charge_memcg(memcg, nr_pages, gfp_mask)
       ├─ page_counter_try_charge(&memcg->memory, nr_pages, &counter)
       │    ├─ 检查是否超过限制
       │    └─ 如果超过：
       │         ├─ 尝试回收（mem_cgroup_reclaim）
       │         └─ 仍不足 → OOM（如果 GFP_KERNEL）
       │
       └─ 更新 Per-CPU 统计（cache 优化）

释放内存时：
  └─ mem_cgroup_uncharge(page)
       └─ page_counter_uncharge(&memcg->memory, nr_pages)
```

---

*分析工具：doom-lsp（clangd LSP）*
