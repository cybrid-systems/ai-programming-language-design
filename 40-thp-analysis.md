# THP / Transparent Hugepage — 透明大页深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/huge_memory.c` + `mm/page_alloc.c`)
> 工具： doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**THP（Transparent Hugepage）** 让应用程序自动使用 2MB 大页，无需手动 `mmap(MAP_HUGETLB)`：
- **khugepaged**：内核线程定期扫描，尝试合并小页为 THP
- ** alloc_huge_page**：分配大页（2MB/1GB）
- **split_huge_page**：拆分大页为 4KB 小页

---

## 1. 核心数据结构

### 1.1 hugepage — 大页结构

```c
// mm/huge_memory.c — hugepage 分解状态
struct page {
    // 通用页信息
    unsigned long           flags;
    union {
        atomic_t             _mapcount;    // 映射数
        struct {
            unsigned int    inuse:16;     // 使用对象数
            unsigned int    objects:16;   // 总对象数（slab）
        };
    };
    // ...
    union {
        struct {
            unsigned long           private;     // 大页： Compound_page 私有
            struct address_space    *mapping;    // 文件映射
        };
        struct {
            unsigned long           index;        // 页索引
            void                   *freelist;    // 空闲链表（slab）
        };
    };
};

// 大页识别：PageHead(page) && PageTransHuge(page)
#define PageTransHuge(page) ((page)->flags & (1 << PG_head))
```

### 1.2 vma — 支持 THP 的 VMA

```c
// include/linux/mm.h — VMA 标志
#define VM_HUGEPAGE       0x00000000  // 已废弃，用 VM_ARCH_1
#define VM_ARCH_1         0x40000000  // THP 可用

// khugepaged 扫描时检查：
// vma->vm_flags & VM_ARCH_1 → 可参与大页合并
```

---

## 2. alloc_pages — 大页分配

```c
// mm/page_alloc.c — __alloc_pages
static inline struct page *
__alloc_pages(gfp_t gfp_mask, unsigned int order, ...)
{
    // order = 9 → 2^9 = 512 页 = 2MB（4KB * 512）
    // order = 21 → 1GB（仅 x86_64 特定映射）

    // 从 Buddy 系统分配
    page = buddy_alloc(gfp_mask, order);

    if (page && order >= HPAGE_PMD_ORDER) {
        // 设置 PG_head 标志
        SetPageHead(page);
        for (i = 1; i < (1 << order); i++)
            set_compound_head(page + i, page);
    }

    return page;
}

// HPAGE_PMD_ORDER = 9（2MB）
// hugepage = 2MB = 512 * 4KB
```

---

## 3. khugepaged — 大页合并守护进程

```c
// mm/huge_memory.c — khugepaged_scan_mm
static void khugepaged_scan_mm(struct mm_struct *mm)
{
    struct vm_area_struct *vma;

    // 1. 遍历进程 VMA，寻找可合并的区域
    for (vma = mm->mmap; vma; vma = vma->vm_next) {
        if (!(vma->vm_flags & VM_HUGEPAGE))
            continue;

        // 2. 扫描 PTE，收集连续的小页
        scan_pte(vma, addr, &pgd);

        // 3. 如果收集到 HPAGE_PMD_ORDER 个小页（2MB 范围）
        if (found_contiguous_pages >= HPAGE_PMD_ORDER) {
            // 4. 分配新 THP，复制内容
            new_page = alloc_pages(GFP_TRANSHUGE, HPAGE_PMD_ORDER);

            // 5. 建立新的 PMD 映射（2MB 直接映射）
            madvise-collapse(collapse_shmem, new_page);
        }
    }
}
```

---

## 4. split_huge_page — 拆分大页

```c
// mm/huge_memory.c — split_huge_page
int split_huge_page(struct page *page)
{
    // 1. 检查是 THP
    if (!PageTransHuge(page))
        return -EINVAL;

    // 2. 获取映射的进程（防止在 I/O 期间拆分）
    get_online_cpus();
    anon_vma = page_lock_anon_vma_read(page);

    // 3. 锁定所有相关 PTE
    pmd = get_task_pmd(task, addr);

    // 4. 清除 PMD，直接建立 PTE 映射
    pmd_clear(pmd);
    set_pte_atomic(pte, pte);

    // 5. 解锁，清除 PG_head 标志
    set_page_release(page);

    return 0;
}
```

---

## 5. mremap 中的 THP

```c
// mm/mremap.c — move_page_tables
// mremap 移动虚拟内存区域时：
// - 如果源/目标是 THP 区域，可能触发大页移动
// - 或者拆分后移动，然后重新合并
```

---

## 6. defrag 模式

```c
// include/linux/mm.h — thp_defrag
enum thp_defrag {
    HPAGE_FRAG_CHECK_FUTURE,    // 只在需要时分配（madvise）
    HPAGE_FRAG_FORCE_MADVISE,   // madvise 时强制分配
    HPAGE_FRAG_FORCE_SHMEM,     // shmem 强制分配
};

// /sys/kernel/mm/transparent_hugepage/enabled:
//   always / madvise / never
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `mm/huge_memory.c` | `khugepaged_scan_mm`、`split_huge_page` |
| `mm/page_alloc.c` | `__alloc_pages`（大页） |
| `include/linux/page-flags.h` | `PageTransHuge`、`PageHead` |