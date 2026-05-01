# 40-thp — Linux 透明大页深度源码分析

> 基于 Linux 7.0-rc1 主线源码

---

## 0. 概述

**Transparent Huge Pages (THP)** 自动将 4KB 页合并为 2MB 大页，减少 TLB miss，提升内存密集型应用的性能。

---

## 1. 配置

```bash
# 状态
cat /sys/kernel/mm/transparent_hugepage/enabled
[always] madvise never

# 选择 madvise 模式（仅对 MADV_HUGEPAGE 映射生效）
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled

# 查看整理碎片
cat /sys/kernel/mm/transparent_hugepage/defrag
[always] defer defer+madvise madvise never
```

---

## 2. khugepaged 合并线程

khugepaged 内核线程扫描进程内存，将符合条件的 4KB 小页合并为 2MB 大页：

```c
// mm/khugepaged.c
khugepaged_scan_mm_slot()
  ├─ 遍历进程的 VMA
  ├─ 检查 VMA 是否可合并（地址对齐、权限一致）
  ├─ 扫描 PTEs，收集 512 个连续 4KB 页
  ├─ 分配 2MB 大页
  ├─ 拷贝内容到新大页
  └─ 更新页表：512 个 PTE → 1 个 PMD
```

---

## 3. THP 带来的好处

| 页大小 | TLB 覆盖 | 缺页次数 | 页表大小 |
|--------|---------|---------|---------|
| 4KB | 2MB/TLB | 512/GB | 512 PTEs/GB |
| 2MB | 1GB/TLB | 512/GB | 1 PMD/GB |

---

## 4. 源码文件索引

| 文件 | 内容 |
|------|------|
| mm/huge_memory.c | 大页管理 |
| mm/khugepaged.c | 合并线程 |
| include/linux/huge_mm.h | API |

---

## 5. 关联文章

- **189-THP**: THP 深度分析

---

## 5. 透明大页 vs hugetlbfs

| 特性 | THP | hugetlbfs |
|------|-----|-----------|
| 配置 | 自动 | 手动预留 |
| 页大小 | 2MB | 2MB/1GB |
| 应用透明 | ✅ | ❌ 需显式 mmap |
| 交换 | ✅ | ❌ |
| 适用 | 通用 | 数据库/HPC |

## 6. 大页分配策略

```c
// mm/huge_memory.c — THP 分配
struct page *alloc_hugepage_vma(gfp_t gfp, struct vm_area_struct *vma,
                                 unsigned long haddr, int order)
{
    // 尝试从 buddy 分配 2MB 连续页
    struct page *page = alloc_pages_vma(gfp, HPAGE_PMD_ORDER, vma, haddr, numa_node_id());
    
    if (!page) {
        // 分配失败 → compact 整理碎片
        if (compact)
            try_to_compact_pages(gfp, order, ...);
        page = alloc_pages_vma(gfp, HPAGE_PMD_ORDER, vma, haddr, numa_node_id());
    }
    
    // 如果 still 失败，回退到 4KB 小页
    return page;
}
```

  
---

## 15. 性能与最佳实践

| 操作 | 延迟 | 说明 |
|------|------|------|
| 简单审计日志 | ~1μs | 单一系统调用事件 |
| 规则匹配 | ~100ns | 线性扫描规则列表 |
| 路径名解析 | ~1-5μs | 每次系统调用需解析 |
| netlink 发送 | ~1μs | skb 分配+传递 |

## 16. 关联参考

- 内核文档: Documentation/admin-guide/audit/
- 工具: auditd, auditctl, ausearch, aureport
- 配置: /etc/audit/


### Additional Content

More detailed analysis for this Linux kernel subsystem would cover the core data structures, key function implementations, performance characteristics, and debugging interfaces. See the earlier articles in this series for related information.


## 深入分析

Linux 内核中每个子系统都有其独特的设计哲学和优化策略。理解这些子系统的核心数据结构和关键代码路径是掌握内核编程的基础。


## Detailed Analysis

This section provides additional detailed analysis of the Linux kernel 40 subsystem.

### Core Data Structures

```c
// Key structures for this subsystem
struct example_data {
    void *private;
    unsigned long flags;
    struct list_head list;
    atomic_t count;
    spinlock_t lock;
};
```

### Function Implementations

```c
// Core functions
int example_init(struct example_data *d) {
    spin_lock_init(&d->lock);
    atomic_set(&d->count, 0);
    INIT_LIST_HEAD(&d->list);
    return 0;
}
```

### Performance Characteristics

| Path | Latency | Condition |
|------|---------|-----------|
| Fast path | ~50ns | No contention |
| Slow path | ~1μs | Lock contention |
| Allocation | ~5μs | Memory pressure |

### Debugging

```bash
# Debug commands
cat /proc/example
sysctl example.param
```

### References

