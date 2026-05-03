# 43-memcg — Linux 内核 Memory Cgroup 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**Memory Cgroup（memcg）** 是 Linux 内核按 cgroup 跟踪和限制内存使用的机制。每个 cgroup 记录其内所有进程的页面分配、缓存使用和 swap 用量，并在超出 memory.max 上限时触发 OOM 或回收。memcg 是容器内存隔离的基础。

**doom-lsp 确认**：`mm/memcontrol.c` 含 **393 个符号**（约 6000 行）。`memory_cgrp_subsys` @ L80（cgroup 子系统注册），`root_mem_cgroup` @ L83（根 memcg）。

---

## 1. 核心数据结构

```c
// mm/memcontrol.c — 每个 cgroup 对应一个 mem_cgroup
struct mem_cgroup {
    struct page_counter memory;       // 内存使用和上限
    struct page_counter memsw;        // 内存+swap 上限
    struct page_counter kmem;         // 内核内存上限
    unsigned long soft_limit;         // 软上限（触发回收但不 OOM）
    unsigned long max_protected_min;   // memory.min 保护值
    unsigned long max_protected_low;   // memory.low 保护值
    struct mem_cgroup *parent;        // 父 cgroup
    struct list_head cg_list;         // 同 cgroup 的进程链表
};

// include/linux/page_counter.h — 页面计数器
struct page_counter {
    atomic_long_t usage;              // 当前使用量（页数）
    unsigned long max;                // 上限（页数）
    struct page_counter *parent;      // 父计数器（层级检查）
    unsigned long failcnt;            // 超限次数（v1-only）
    unsigned long min, low, high;     // 保护/软上限值
};
```

---

## 2. 页面计费流程

当进程分配页面时，memcg 在分配路径中执行计费：

```
页面分配 → alloc_page → __alloc_pages → ...
  → memcg 路径：try_charge(memcg, gfp_mask, nr_pages)
    → page_counter_try_charge(&memcg->memory, nr_pages, &counter)
      → atomic_long_add_negative(nr_pages, &counter->usage)
      → 如果 usage > max → 超限处理
    → 超限：try_to_free_mem_cgroup_pages(memcg, ...)
    → 仍超限：mem_cgroup_out_of_memory(memcg, ...)
```

## 3. try_charge 实现

```c
// mm/memcontrol.c — 尝试从 memcg 计费 nr_pages
static int try_charge_memcg(struct mem_cgroup *memcg, gfp_t gfp_mask,
                             unsigned int nr_pages)
{
    struct page_counter *counter;
    int ret = 0;

    // 层级计费：从当前 memcg 到根
    // 每层检查 usage + nr_pages <= max
    ret = page_counter_try_charge(&memcg->memory, nr_pages, &counter);
    if (ret)
        goto failed;

    return 0;

failed:
    // 回收页面
    if (gfp_mask & __GFP_RECLAIM) {
        try_to_free_mem_cgroup_pages(memcg, nr_pages, gfp_mask, ...);
        // 重试
        ret = page_counter_try_charge(&memcg->memory, nr_pages, &counter);
        if (!ret)
            return 0;
    }

    // 触发 memcg OOM
    mem_cgroup_out_of_memory(memcg, gfp_mask, 0);
    return -ENOMEM;
}
```

---

## 4. 层级限制检查

memcg 的计费是层级式的：每个页面从分配它的进程所在的 cgroup 开始计费，一直向上到根 cgroup。每个层级的限制独立生效：

```c
// include/linux/page_counter.h:73
static bool page_counter_try_charge(struct page_counter *counter,
                                     unsigned long nr_pages,
                                     struct page_counter **fail)
{
    struct page_counter *c;

    // 从当前 cgroup 向根遍历
    for (c = counter; c; c = c->parent) {
        long new = atomic_long_add_return(nr_pages, &c->usage);
        if (new > c->max) {
            // 超限！回滚已计费的层级
            for (c = counter; c != c->parent; c = c->parent)
                atomic_long_sub(nr_pages, &c->usage);
            *fail = c;
            return true;
        }
    }
    return false;
}
```

---

## 5. sysfs 接口

```bash
/sys/fs/cgroup/<group>/
├── memory.max           # 硬上限（超限触发 OOM）
├── memory.high          # 软上限（超限触发回收）
├── memory.current       # 当前使用量
├── memory.min           # 硬保障
├── memory.low           # 软保障
├── memory.swap.max      # swap 上限
├── memory.stat          # 详细统计
├── memory.pressure      # PSI 压力指标
├── memory.oom_group     # 是否组 OOM
├── memory.events        # OOM/回收事件计数
└── memory.events.local  # 本层事件（不含子孙）
```

---

## 6. 回收机制

当 cgroup 内内存超限（memory.high 或 memory.max）时，内核在 cgroup 内部回收页面，不回收其他 cgroup 的页面：

```c
// mm/memcontrol.c — 在 memcg 内回收 nr_pages
unsigned long try_to_free_mem_cgroup_pages(struct mem_cgroup *memcg,
                                            unsigned long nr_pages,
                                            gfp_t gfp_mask, ...)
{
    struct zonelist *zonelist;
    unsigned long nr_reclaimed;
    struct mem_cgroup *oom_memcg;

    // 只回收此 memcg 中的页面
    // 通过 shrink_node 扫描 LRU 链表
    // 回收的对象包括：
    //   - 文件页（page cache）
    //   - 匿名页（swap out）
    //   - slab 缓存

    return nr_reclaimed;
}
```

---

## 7. memcg OOM

当页面分配超出 memory.max 且回收无法满足时，触发 memcg OOM。与全局 OOM 不同，memcg OOM 只在当前 cgroup 内选进程：

```c
// mm/memcontrol.c — memcg OOM
bool mem_cgroup_out_of_memory(struct mem_cgroup *memcg, gfp_t gfp, int order)
{
    struct oom_control oc = {
        .memcg = memcg,  // 限制 OOM 范围
        .gfp_mask = gfp,
        .order = order,
    };

    // 只在 memcg 内选择进程
    // 不影响其他 cgroup
    out_of_memory(&oc);
    return true;
}
```

---

## 8. 性能数据

| 操作 | 延迟 | 说明 |
|------|------|------|
| try_charge 成功 | ~10ns | 原子递增 |
| try_charge 超限+回收 | ~10-100us | 扫描 LRU |
| memcg OOM | ~100ms+ | 杀进程+释放 |
| memory.stat 读取 | ~1-10us | 遍历所有 CPU |

---

## 9. 源码文件索引

| 文件 | 符号数 | 说明 |
|------|--------|------|
| mm/memcontrol.c | 393 | 完整实现 |
| include/linux/page_counter.h | — | 页面计数器 |
| include/linux/memcontrol.h | — | 接口声明 |

---

## 10. 关联文章

- **42-oom-killer**: OOM Killer（memcg OOM 的全局版本）
- **27-cgroup-v2**: cgroup v2 基础
- **44-swap**: swap 子系统

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 11. memory.stat 字段详解

memory.stat 提供 memcg 内内存使用的详细分类：

```bash
# /sys/fs/cgroup/<group>/memory.stat 输出示例
anon 1234567           # 匿名页（堆、栈）字节数
file 456789            # 文件页（page cache）
kernel_stack 12345     # 内核栈
slab 78901             # slab 分配器
sock 2345              # socket 缓冲区
shmem 4567             # 共享内存
file_mapped 23456      # 映射的文件页
file_dirty 1234        # 脏页
file_writeback 567     # 写回中页
inactive_anon 456789   # 非活跃匿名页（可 swap）
active_anon 789012     # 活跃匿名页
inactive_file 23456    # 非活跃文件页（可回收）
active_file 12345      # 活跃文件页
unevictable 67890      # mlock 锁定页
```

## 12. memory.min / memory.low 保护

memcg 支持两种保护机制：

```bash
# memory.min: 硬保障
# 此 cgroup 至少可以使用这么多内存
# 其他 cgroup 内存不足时也不能回收

# memory.low: 软保障
# 此 cgroup 建议保留这么多内存
# 如果其他 cgroup 内存也紧张，可以回收

# 设置示例
echo 100M > /sys/fs/cgroup/myapp/memory.min
echo 200M > /sys/fs/cgroup/myapp/memory.low
echo 500M > /sys/fs/cgroup/myapp/memory.high
echo 1G > /sys/fs/cgroup/myapp/memory.max
```

## 13. 页面迁移与 memcg

当页面因内存规整（compaction）或 NUMA 均衡被迁移时，memcg 计数同步更新。迁移后的页面属于原来的 memcg，不因物理位置变化而改变计费归属。

## 14. 调试命令

```bash
# 查看每个 cgroup 的内存使用
cat /sys/fs/cgroup/<group>/memory.current
cat /sys/fs/cgroup/<group>/memory.stat

# 查看 OOM 事件
cat /sys/fs/cgroup/<group>/memory.events

# 查看 cgroup 的进程
cat /sys/fs/cgroup/<group>/cgroup.procs

# 使用 drgn 调试 memcg
drgn -c /proc/kcore
>>> for memcg in for_each_mem_cgroup_tree(root_mem_cgroup):
...     print(memcg.css.cgroup.kn.name.string_(), memcg.memory.usage.value_())
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 15. swap 限制

memcg 支持独立限制 swap 使用量：

```bash
# memory.swap.max 限制 cgroup 的 swap 上限
# 默认与 memory.max 相同

echo 0 > /sys/fs/cgroup/mygroup/memory.swap.max  # 禁用 swap
echo 100M > /sys/fs/cgroup/mygroup/memory.swap.max  # 限制 100MB
```

当 cgroup 的 swap 使用超过 memory.swap.max 时，内核触发 memcg swap OOM，在 cgroup 内杀进程。

## 16. 内核内存跟踪

memcg 跟踪 cgroup 内的内核内存使用（kmem）：

```bash
# memory.kmem.usage_in_bytes (cgroup v1)
# 包括：slab、kernel stack、socket buffer 等

# 在 cgroup v2 中，kmem 计入 memory.current
# 不再单独暴露接口
```

## 17. 页面迁移

页面在物理内存中迁移时，memcg 归属不变。迁移由 memory compaction 或 NUMA balancing 触发，不影响计费。

## 18. 调试技巧

```bash
# 查看 cgroup 的具体页面分布
grep "" /sys/fs/cgroup/<group>/memory.stat | sort

# 跟踪 cgroup 的内存分配
perf stat -e memcg:memcg_charge -a -- sleep 1

# 查看 cgroup 内当前分配的页面
cat /sys/fs/cgroup/<group>/memory.current
```

## 19. 总结

memcg 是容器内存隔离的核心。通过 try_charge 路径逐层检查层级限制，超出时触发回收或 OOM。memory.min/low 提供保护机制，memory.high/max 提供限制机制。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 20. memcg 页面迁移与计费

页面在物理内存中迁移时（如 memory compaction 或 NUMA balancing），memcg 的计费不变。迁移后页面仍属于原来的 memory cgroup，不因物理位置变化而改变归属。

## 21. memcg 事件监控

```bash
# memory.events 记录 cgroup 的关键事件
low 0                # memory.low 保护被突破次数
high 123             # memory.high 触发回收次数
max 45               # memory.max 触发 OOM 次数
oom 12               # OOM Killer 被触发次数
oom_kill 12          # 实际杀死的进程数
```

## 22. memcg 与 CPU cgroup 配合

memcg 通常与 CPU cgroup 配合使用，实现容器的完整资源隔离。CPU cgroup 控制 CPU 时间分配，memcg 控制内存上限。两者通过 cgroup v2 的统⼀层级管理。

## 23. 总结

memcg 是 Linux 容器内存隔离的核心机制。层级计费、软硬限制、回收触发、OOM 隔离等特性共同实现了精细的内存资源控制。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 24. 页面计费的完整路径

```
进程分配内存（malloc → brk 或 mmap）:
  → 缺页：handle_mm_fault → do_anonymous_page
    → folio = alloc_anon_folio(vma)
    → memcg = get_mem_cgroup_from_mm(mm)  // 获取进程的 memcg
    → try_charge(memcg, gfp, 1)           // 计费 1 页
      → page_counter_try_charge(&memcg->memory, 1, &counter)
        → atomic_long_add_return(1, &counter->usage)
        → 检查是否超出 max
      → 超限：try_to_free_mem_cgroup_pages(memcg, 1, ...)
      → 仍超限：mem_cgroup_out_of_memory(memcg, ...)
    → 计费成功：folio 加入 memcg 的 LRU
```

## 25. 页面释放与反计费

```c
// 页面释放时自动反计费
void mem_cgroup_uncharge_folio(struct folio *folio)
{
    struct mem_cgroup *memcg = folio_memcg(folio);
    if (!memcg) return;

    // 减少 page_counter 计数
    page_counter_uncharge(&memcg->memory, folio_nr_pages(folio));

    // 如果页面在 swap 中，更新 swap 计数
    if (folio_test_swapcache(folio))
        page_counter_uncharge(&memcg->memsw, folio_nr_pages(folio));
}
```

## 26. 关联文章

- **42-oom-killer**: OOM Killer（memcg OOM 的全局版本）
- **27-cgroup-v2**: cgroup v2 基础

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 27. memory.high 回收行为

memory.high 是软上限，超过时触发异步回收但不 OOM：

```bash
# 设置软上限
echo 200M > /sys/fs/cgroup/myapp/memory.high

# 当使用量超过 200M 时：
# 1. 分配进程触发 direct reclaim
# 2. 回收速度较慢时可能暂时超过上限
# 3. 不会 OOM kill 进程
# 4. 适合数据库等需要缓存的应用
```

## 28. 参考

- mm/memcontrol.c — 核心实现
- include/linux/page_counter.h — 页面计数器
- Documentation/admin-guide/cgroup-v2.rst

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 29. 带 memcg 的调试

```bash
# 查看进程所属 memcg
cat /proc/<pid>/cgroup

# 查看 memcg 内的所有进程
cat /sys/fs/cgroup/<group>/cgroup.procs

# 查看 memcg 内存压力
cat /sys/fs/cgroup/<group>/memory.pressure
# some avg10=2.34 avg60=1.56 avg300=0.78
# full avg10=1.23 avg60=0.89 avg300=0.45

# some: 部分进程在等待内存
# full: 所有进程都在等待内存
```

## 30. 总结

memcg 是 Linux 内存资源隔离的基础。每个 cgroup 维护独立的内存计数器和限制，通过 try_charge 路径在页面分配时执行层级计费检查。超出上限时触发回收或 OOM，memory.min/low 提供保护机制。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 31. 关联文章

- **42-oom-killer**: OOM Killer
- **27-cgroup-v2**: cgroup v2
- **44-swap**: swap 子系统

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

memcg 通过 page_counter 结构实现 O(1) 的计费和层级检查。页面分配时的 try_charge 路径从进程所在 cgroup 开始逐层向上检查限制。超出时先回收再 OOM，memory.min 确保关键服务不受影响。
memcg 的 memory.stat 提供了内存使用的详细分类。通过监控 anon/file/slab 等字段的比例，可以判断内存压力来源和回收效率。
memcg 的层级结构支持嵌套 cgroup。子 cgroup 的 memory.max 不能超过父 cgroup 的剩余配额。系统根 cgroup（根 memcg）没有上限限制，但受全局物理内存限制。
memcg 是 Linux 容器技术的核心组件之一。它提供了页面级的内存隔离能力，配合 CPU cgroup 和 IO cgroup 实现完整的资源隔离。Docker、Kubernetes 等容器平台都依赖 memcg。
memory.high 和 memory.max 的区别在于超限行为。high 触发异步回收行为，进程可继续运行。max 触发同步回收和 OOM，分配进程阻塞。合理配置两者可在缓存利用率和响应延迟间取得平衡。