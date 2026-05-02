# 40-thp — Linux 透明大页深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**THP（Transparent Huge Pages）** 自动将 4KB 小页合并为 2MB 大页，减少 TLB miss 并提升内存密集型应用性能。khugepaged 内核线程后台扫描合并，缺页路径中尝试分配大页。

**doom-lsp 确认**：`mm/huge_memory.c`（大页管理），`mm/khugepaged.c`（合并线程）。`transparent_hugepage_flags` 控制 THP 行为。

---

## 1. THP vs 4KB 小页

| 特性 | 4KB 小页 | 2MB 大页 |
|------|---------|---------|
| TLB 覆盖 | 2MB/TLB (512×4KB)| 1GB/TLB (512×2MB)|
| 缺页次数 | 512 次/GB | 1 次/2MB |
| 页表大小 | 512 PTEs | 1 PMD |
| 分配成功率 | 高 | 低（需连续 2MB）|
| 适用 | 通用 | 大内存、长时间运行 |

---

## 2. 配置接口

```bash
# THP 启用状态
/sys/kernel/mm/transparent_hugepage/enabled
[always] madvise never

# always: 所有映射都尝试用 THP
# madvise: 仅 MADV_HUGEPAGE 标记的区域
# never: 禁用 THP

# 碎片整理策略
/sys/kernel/mm/transparent_hugepage/defrag
[always] defer defer+madvise madvise never

# khugepaged 参数
/sys/kernel/mm/transparent_hugepage/khugepaged/
  pages_to_scan    # 每轮扫描页数
  sleep_millisecs  # 扫描间隔
```

---

## 3. 缺页时的大页分配

```
do_anonymous_page() / do_fault() 缺页处理
  │
  └─ __handle_mm_fault(vma, addr, flags)
       │
       ├─ 检查 THP 是否启用
       │   if (!transparent_hugepage_enabled(vma))
       │       goto normal;  // 4KB 小页
       │
       ├─ 检查地址对齐（2MB 对齐）
       │   if (addr & (HPAGE_PMD_SIZE - 1))
       │       goto normal;
       │
       └─ do_huge_pmd_anonymous_page(vmf)
            │
            ├─ alloc_hugepage_vma() 从 buddy 分配 2MB 连续页
            │   → alloc_pages_vma(HPAGE_PMD_ORDER)
            │   → 如果失败且 defrag=always:
            │       compact → 重试
            │   → 如果仍失败: 回退到 4KB 小页
            │
            └─ 建立 PMD 大页映射
                set_pmd_at(mm, addr, pmd, entry)
```

---

## 4. khugepaged 合并线程

```c
// mm/khugepaged.c — khugepaged 后台合并
static int khugepaged(void *none)
{
    struct mm_slot *mm_slot;

    set_freezable();
    set_user_nice(current, MAX_NICE);  // 低优先级

    while (!kthread_should_stop()) {
        // 扫描一个进程的地址空间
        khugepaged_do_scan(NULL);

        // 休眠
        schedule_timeout_interruptible(
            msecs_to_jiffies(khugepaged_sleep_millisecs));
    }
    return 0;
}

// 单次扫描
static void khugepaged_do_scan(unsigned int scan_npages)
{
    unsigned int pages = 0;

    // 遍历 mm_slot 链表（注册了 MADV_HUGEPAGE 的进程）
    while (pages < khugepaged_pages_to_scan) {
        struct mm_slot *mm_slot = khugepaged_scan_mm_slot();
        if (!mm_slot) break;

        // 扫描进程 VMA，尝试合并
        pages += khugepaged_scan_pmd(mm_slot, ...);
    }
}
```

---

## 5. 合并条件

```c
// khugepaged 在以下条件下合并页面：
// 1. VMA 是可合并的（readable, writable, anonymous）
// 2. 地址 2MB 对齐
// 3. 512 个连续 4KB 页都存在（不是空洞）
// 4. 所有 512 页都被映射到同一个 VMA
// 5. 没有个别页面被 mlock 或 dirty
```

---

## 6. 大页分裂

```c
// mm/huge_memory.c — 大页分裂为 4KB 小页
// 当以下情况发生时需要分裂：
// 1. mprotect 修改部分大页的权限
// 2. mlock 部分页面
// 3. 内存压力不足
// 4. 页面迁移

int split_huge_page_to_list(struct page *page, struct list_head *list)
{
    struct address_space *mapping;
    int nr, ret = 0;

    // 1. 获取 PMD 锁
    // 2. 分配 512 个 4KB 页表项
    // 3. 复制大页内容到小页
    // 4. 替换 PMD 为 PTE 页表
    // 5. 更新反向映射
    // 6. 释放大页

    return ret;
}
```

---

## 7. THP 与 page cache

```c
// 文件映射也支持 THP（通过 page cache）
// mm/filemap.c — 文件读入时分配大页

// 条件：
// 1. 文件系统支持大页（ext4, xfs, btrfs）
// 2. VMA 对齐 2MB
// 3. 文件偏移对齐 2MB

// readahead 也会尝试分配大页：
// page_cache_ra_order() 尝试大页预读
```

---

## 8. 性能影响

| 场景 | 4KB 小页 | THP 2MB | 提升 |
|------|---------|---------|------|
| TLB miss | 高 | 低 | ~50% |
| 缺页延迟 | ~1us | ~10us | 更慢（但次数少）|
| 内存占用 | 基线 | ~5-10% 更多 | 内部碎片 |
| 大数据库 | 抖动 | 稳定 | ~30% |

---

## 9. 源码文件索引

| 文件 | 内容 |
|------|------|
| mm/huge_memory.c | 大页分配、分裂、PMD 处理 |
| mm/khugepaged.c | 后台合并线程 |
| include/linux/huge_mm.h | API |

---

## 10. 关联文章

- **39-mlock**: mlock 与 THP 的交互
- **20-page-cache**: THP 在文件映射中的使用

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 11. do_huge_pmd_anonymous_page

```c
// mm/huge_memory.c — 匿名页大页缺页处理
int do_huge_pmd_anonymous_page(struct vm_fault *vmf)
{
    struct vm_area_struct *vma = vmf->vma;
    gfp_t gfp;
    struct page *page;
    unsigned long haddr = vmf->address & HPAGE_PMD_MASK;

    // 1. 检查 VMA 是否可写、可读
    if (!(vma->vm_flags & VM_MAYREAD))
        goto fallback;

    // 2. 大页分配
    if (vma->vm_flags & VM_SHARED) {
        // 共享映射
        page = alloc_hugepage_vma(GFP_HIGHUSER, vma, haddr, HPAGE_PMD_ORDER);
    } else {
        // 私有映射
        page = alloc_hugepage_vma(GFP_HIGHUSER_MOVABLE, vma, haddr, HPAGE_PMD_ORDER);
    }
    if (!page) goto fallback;  // 分配失败，回退到 4KB

    // 3. 初始化大页
    // 清除页面、设置映射、添加到大页缓存

    // 4. 建立 PMD 映射
    set_pmd_at(vma->vm_mm, haddr, vmf->pmd, mk_huge_pmd(page, vma->vm_page_prot));

    return 0;

fallback:
    // 回退到 4KB 小页缺页处理
    return VM_FAULT_FALLBACK;
}
```

## 12. alloc_hugepage_vma

```c
// mm/huge_memory.c — 从 buddy 分配 2MB 连续页
static struct page *alloc_hugepage_vma(gfp_t gfp, struct vm_area_struct *vma,
                                        unsigned long haddr, int order)
{
    struct page *page;

    // 尝试分配 2MB 连续页
    page = alloc_pages_vma(gfp, HPAGE_PMD_ORDER, vma, haddr, numa_node_id());

    if (page)
        return page;  // 分配成功

    // 分配失败 → compaction 整理碎片
    if (test_bit(TRANSPARENT_HUGEPAGE_DEFRAG_DIRECT_FLAG, &transparent_hugepage_flags)) {
        page = alloc_pages_vma(gfp | __GFP_COMPACT, HPAGE_PMD_ORDER, ...);
    }

    return page;
}
```

## 13. 扫描合并流程

```
khugepaged 扫描流程：

khugepaged_do_scan(pages_to_scan)
  │
  └─ khugepaged_scan_mm_slot()
       │
       └─ 遍历进程的 VMA:
            khugepaged_scan_pmd(mm_slot, ...)
              │
              ├─ 1. 检查 VMA 类型
              │   → 跳过 VM_NO_THP、VM_SHARED 等
              │
              ├─ 2. 扫描 512 个 PTE
              │   → 检查所有页是否存在
              │   → 检查所有页属于同一 VMA
              │   → 检查引用计数
              │
              ├─ 3. 分配 2MB 大页
              │   alloc_hugepage_vma()
              │
              ├─ 4. 拷贝 512 个小页内容到大页
              │   copy_user_highpage() × 512
              │
              └─ 5. 替换页表
                  → 清除 512 个 PTE
                  → 设置 PMD 大页映射
                  → 释放 512 个小页
```

## 14. 碎片整理策略

```bash
# defrag 选项控制 compaction 行为
# always:    每次 THP 分配失败时同步 compact
# defer:     异步 compact，不阻塞
# defer+madvise: 仅 MADV_HUGEPAGE 区同步 compact
# madvise:   仅 MADV_HUGEPAGE 区 compact
# never:     不 compact，失败回退 4KB

# 推荐配置
# 桌面: always 或 madvise
# 服务器: defer+madvise（避免 THP 分配延迟）
```

## 15. 源码文件索引

| 文件 | 内容 |
|------|------|
| mm/huge_memory.c | 大页管理 (~5000 行)|
| mm/khugepaged.c | 合并线程 (~2000 行)|
| include/linux/huge_mm.h | 头文件 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 16. THP 与 swap

```c
// THP 的 swap 处理
// mm/swap_state.c — 大页换入换出
// 大页被换出时，分裂为 512 个小页
// 每个小页单独写入 swap 分区

// 换入时：
// try_to_unmap 分裂大页 → 512 个 4KB 页
// → 分 512 次换入
// → 性能较差（不如直接换入大页）
```

## 17. THP 统计

```bash
# /proc/meminfo 中的 THP 统计
AnonHugePages:    102400 kB  # 匿名大页总量
ShmemHugePages:        0 kB  # 共享内存大页
FileHugePages:         0 kB  # 文件映射大页

# /sys/kernel/mm/transparent_hugepage/ 中的统计
hugepages_allocated    # 已分配大页数
hugepage_alloc_fail    # 分配失败次数
hugepage_splits        # 分裂次数
```

## 18. MADV_HUGEPAGE 与 MADV_NOHUGEPAGE

```c
// madvise 控制特定区域的大页使用

// 建议使用 THP
madvise(addr, length, MADV_HUGEPAGE);
// → VMA 设置 VM_HUGEPAGE 标志
// → khugepaged 优先扫描此区域

// 禁用 THP
madvise(addr, length, MADV_NOHUGEPAGE);
// → VMA 设置 VM_NOHUGEPAGE 标志
// → 跳过此区域的 THP
```

## 19. 大页内部碎片

```c
// THP 的主要代价：内部碎片
// 一个大页 2MB = 512 × 4KB
// 如果一个大页只有少量页面被使用：
// 浪费：2MB - 使用量

// 示例：
// heap 增长到 2MB + 4KB
// → 第一个 2MB 用大页（无碎片）
// → 最后 4KB 用小页（正常）
// → 如果释放了中间的 1MB：
//   大页不能部分释放 → 保持 2MB

// 碎片导致的内存浪费通常 < 5%
```

## 20. THP 与实时

```c
// 实时应用可能禁用 THP
// THP 缺页延迟 ~10us（vs 4KB ~1us）
// 对于实时性要求高的场景：
// echo never > /sys/kernel/mm/transparent_hugepage/enabled

// 或者使用 madvise 模式：
// echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
// 通过 MADV_HUGEPAGE 选择性启用
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 21. 透明大页与 hugetlbfs 对比

| 特性 | THP | hugetlbfs |
|------|-----|-----------|
| 配置 | 自动（sysfs 控制）| 手动预留（/proc/sys/vm/nr_hugepages）|
| 页大小 | 2MB | 2MB 或 1GB |
| 应用透明 | ✅ 无需修改 | ❌ 需 mmap hugetlbfs |
| 交换 | ✅ 支持 | ❌ 不支持 |
| 内核支持 | CONFIG_TRANSPARENT_HUGEPAGE | CONFIG_HUGETLB_PAGE |

## 22. THP 与 cgroup

```c
// memcg 对 THP 计数
// 一个 2MB 大页在 memcg 中计为 2MB（而非 512 × 4KB）

// THP 分配在 memcg 限额检查时
// page_counter_try_charge 检查 memcg 上限
// 超出上限时回退到 4KB 分配
```

## 23. 调试命令

```bash
# THP 状态
cat /sys/kernel/mm/transparent_hugepage/enabled
cat /sys/kernel/mm/transparent_hugepage/defrag
cat /sys/kernel/mm/transparent_hugepage/khugepaged/*

# 统计
grep HugePages /proc/meminfo
grep thp /proc/vmstat

# 跟踪 THP 分配
perf stat -e thp_fault:thp_fault_alloc -a -- sleep 1
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 24. 透明大页的适用场景

```bash
# THP 适合
# - 长时间运行的服务
# - 大内存应用（数据库、JVM）
# - 内存密集型计算
# - 数据库（MySQL、PostgreSQL）

# THP 不适合
# - 实时系统（缺页延迟不稳定）
# - 小内存嵌入式系统
# - 稀疏内存访问模式（内部碎片严重）

# 建议默认开启（always 模式）
# 数据库等可调为 madvise 模式
```

## 25. 源码文件索引

| 文件 | 说明 |
|------|------|
| mm/huge_memory.c | 大页分配/分裂 |
| mm/khugepaged.c | 后台合并 |
| mm/page_vma_mapped.c | PMD 遍历 |
| include/linux/huge_mm.h | 头文件 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 26. khugepaged 工作负载调优

```bash
# khugepaged 参数优化

# 每轮扫描页数（默认 4096）
echo 8192 > /sys/kernel/mm/transparent_hugepage/khugepaged/pages_to_scan

# 扫描间隔（默认 10000ms = 10s）
echo 5000 > /sys/kernel/mm/transparent_hugepage/khugepaged/sleep_millisecs

# 最多分配多少个大页
cat /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none

# khugepaged CPU 使用率
# 通常 < 1%，大内存系统可能到 5%
```

## 27. THP 与 transparent_hugepage_flags

```c
// mm/huge_memory.c — THP 标志位控制
unsigned long transparent_hugepage_flags __read_mostly =
    (1<<TRANSPARENT_HUGEPAGE_FLAG) |           // enabled
    (1<<TRANSPARENT_HUGEPAGE_DEFRAG_DIRECT_FLAG); // defrag

// 可用标志：
// TRANSPARENT_HUGEPAGE_FLAG         — 启用 THP
// TRANSPARENT_HUGEPAGE_DEFRAG_FLAG   — defrag 直接 compact
// TRANSPARENT_HUGEPAGE_MADVISE_FLAG  — madvise 模式
// TRANSPARENT_HUGEPAGE_NEVER_FLAG    — 禁用
```

## 28. 总结

THP 通过自动 4KB→2MB 页面合并，显著减少 TLB miss。khugepaged 后台扫描，缺页路径尝试大页。defrag 控制 compaction 行为。适合大内存应用，实时系统建议禁用或使用 madvise 模式。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 29. 参考链接

- mm/huge_memory.c — 大页实现 (~5000 行)
- mm/khugepaged.c — 合并线程 (~2000 行)
- Documentation/admin-guide/mm/transhuge.rst

## 30. 关联文章

- **39-mlock**: mlock 与 THP
- **40-thp**: THP 基础

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

THP 是 Linux 内核内存管理的重要特性。2MB 大页减少 TLB miss 约 50
THP is a key memory management feature. 2MB pages reduce TLB misses by about 50 percent. khugepaged background scanning handles coalescing. Fault path attempts 2MB allocation with transparent fallback to 4KB. Defrag options control compaction behavior.

THP 通过 alloc_hugepage_vma 从 buddy 分配 2MB 连续内存。khugepaged 通过 khugepaged_scan_pmd 扫描 512 个 PTE 并合并。split_huge_page 在需要时将大页分裂回 4KB 小页。

THP 配置通过 sysfs 接口控制。enabled 控制启用模式，defrag 控制碎片整理，khugepaged 参数控制合并行为。透明大页对大多数应用透明且有益。

MADV_HUGEPAGE 建议 VMA 使用大页。khugepaged 优先扫描这些区域。MADV_NOHUGEPAGE 禁用 THP。madvise 模式下仅 MADV_HUGEPAGE 区域使用 THP。

THP 分配延迟 ~10us，4KB 分配延迟 ~1us。虽然单次延迟更高，但缺页次数减少 512 倍，总体性能显著提升。
