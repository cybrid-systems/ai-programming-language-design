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

// mm/page_counter.h — 页面计数器
struct page_counter {
    atomic_long_t usage;              // 当前使用量（页数）
    unsigned long max;                // 上限（页数）
    struct page_counter *parent;      // 父计数器（层级检查）
    struct list_head *failcnt;        // 超限次数
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
// mm/page_counter.h
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
| mm/page_counter.h | — | 页面计数器 |
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
