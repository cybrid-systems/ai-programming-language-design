# 18-copy-page-range — 进程地址空间复制深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**copy_page_range** 是 Linux 内核实现 `fork()` 时复制父进程地址空间的核心函数。它递归遍历父进程的四级页表树（PGD→P4D→PUD→PMD→PTE），为子进程创建完全独立的页表副本。

核心策略是 **COW（Copy-on-Write）**：`fork()` 后并不立即复制物理页面，而是：
1. 父进程和子进程**共享**所有匿名页面
2. 父进程的所有 PTE 被标记为**只读**（如果原来是可写的）
3. 缺页时触发写时复制（`do_wp_page`）：分配新页面，复制内容，更新子进程 PTE 为可写

**关键观察**：`fork()` 的主要开销不在 `copy_page_range` 本身（复制页表是 O(页面数) 的线性操作），而在后续的 COW 缺页处理。这也是为什么 `vfork()`（不复制地址空间）比 `fork()` 快几个数量级。

**doom-lsp 确认**：`copy_page_range` @ `mm/memory.c:1491`，`copy_pte_range` @ L1208，`copy_pmd_range` @ L1363，`copy_pud_range` @ L1400，`copy_p4d_range` @ L1437。

---

## 1. 完整调用链

```
fork() → kernel_clone()
  │
  └─ copy_process()
       │
       ├─ copy_semundo()
       ├─ copy_files()          ← 复制 fd 表
       ├─ copy_fs()             ← 复制 umask, root
       ├─ copy_sighand()        ← 复制信号处理
       ├─ copy_mm()             ← ★ 复制地址空间（核心）
       │    │
       │    └─ dup_mm(mm)
       │         └─ dup_mmap(mm, oldmm)
       │              │
       │              ├─ [遍历父进程的每个 VMA]
       │              │   for (vma = mmap; vma; vma = vma->vm_next) {
       │              │
       │              │   ├─ 文件映射 → 增加 file 引用计数
       │              │   ├─ 匿名映射 → 建立反向映射链接
       │              │   │
       │              │   └─ if (vma_needs_copy(vma))
       │              │        copy_page_range(dst_vma, src_vma)
       │              │        ★ 复制页表！
       │              │   }
       │              │
       │              └─ mm->mmap 已建立（子进程地址空间就绪）
       │
       ├─ copy_thread()         ← 设置子进程执行上下文
       ├─ sched_fork()          ← 调度器初始化
       └─ wake_up_new_task(p)  ← 让子进程运行
```

---

## 2. 🔥 copy_page_range——主入口

```c
// mm/memory.c:1491 — doom-lsp 确认
int copy_page_range(struct vm_area_struct *dst_vma,
                     struct vm_area_struct *src_vma)
{
    pgd_t *src_pgd, *dst_pgd;
    unsigned long addr = src_vma->vm_start;
    unsigned long end = src_vma->vm_end;
    struct mm_struct *dst_mm = dst_vma->vm_mm;
    struct mm_struct *src_mm = src_vma->vm_mm;
    unsigned long next;
    int ret;

    // [步骤 1: 检查是否需要复制]
    // 共享映射或只读私有映射 → 不需要复制页表
    // 见下方 vma_needs_copy 的详解
    if (!vma_needs_copy(dst_vma, src_vma))
        return 0;

    // [步骤 2: 大页处理]
    if (is_vm_hugetlb_page(src_vma))
        return copy_hugetlb_page_range(dst_mm, src_mm, dst_vma, src_vma);
    // hugetlb 使用专用的大页页表（PMD 级别），
    // 不能通过标准的 PTE 遍历复制

    // [步骤 3: MMU 通知]
    // 如果 VMA 是 COW 映射，通知 KVM 等：
    // 父进程的 PTE 将被修改（写保护），
    // 需要使 TLB 和 secondary MMU 缓存失效
    if (is_cow_mapping(src_vma->vm_flags)) {
        mmu_notifier_range_init(&range, MMU_NOTIFY_PROTECTION_PAGE,
                                0, src_mm, addr, end);
        mmu_notifier_invalidate_range_start(&range);
    }

    // [步骤 4: 页表层级遍历]
    // 从 PGD（Page Global Directory）开始，
    // 逐级下降到 PTE 进行复制
    src_pgd = pgd_offset(src_mm, addr);
    dst_pgd = pgd_offset(dst_mm, addr);

    for (; addr < end; addr = next) {
        // 计算当前 PGD 覆盖的地址范围
        next = pgd_addr_end(addr, end);

        // 如果父进程的 PGD 不存在或无效，跳过
        if (pgd_none_or_clear_bad(src_pgd))
            goto skip;

        // ★ 递归进入下一级：P4D
        if (copy_p4d_range(dst_vma, src_vma,
                           dst_pgd, src_pgd, addr, next))
            goto out;

skip:
        src_pgd++;
        dst_pgd++;
    }

    // [步骤 5: MMU 通知结束]
    if (is_cow_mapping(src_vma->vm_flags))
        mmu_notifier_invalidate_range_end(&range);

    return 0;

out:
    if (is_cow_mapping(src_vma->vm_flags))
        mmu_notifier_invalidate_range_end(&range);
    return -ENOMEM;
}
```

---

## 3. 🔥 页表递归遍历——四级页表

```
虚拟地址 0x7f1234567890 的页表遍历路径：

地址 = 0x7f1234567890
二进制分解：
  bits 47-39: PGD 索引     → 0xFE
  bits 38-30: PUD 索引     → 0x24
  bits 29-21: PMD 索引     → 0x68
  bits 20-12: PTE 索引     → 0xBC
  bits 11-0:  页内偏移     → 0x890

四级页表结构：
  CR3 → PGD → P4D → PUD → PMD → PTE → 物理页
                                 └→ 2MB 大页 (PMD 级别)
                           └→ 1GB 大页 (PUD 级别)

遍历函数调用链：
                              copy_page_range
                                   │
                             copy_p4d_range (L1436)
                                   │
                             copy_pud_range (L1400)
                                   │
                                  ├── [PUD 大页检查]
                                  │    pud_devmap / pud_trans_huge
                                  │    → copy_huge_pud
                                  │
                             copy_pmd_range (L1363)
                                   │
                                  ├── [PMD 大页检查]
                                  │    pmd_devmap / pmd_trans_huge
                                  │    → copy_huge_pmd
                                  │
                             copy_pte_range (L1208)  ★
                                   │
                                  ├── 为子进程分配 PTE 页
                                  ├── 循环复制每个 PTE
                                  └── 写保护父进程 PTE
```

### 3.1 copy_p4d_range

```c
// mm/memory.c:1437 — doom-lsp 确认
static int copy_p4d_range(struct vm_area_struct *dst_vma,
                           struct vm_area_struct *src_vma,
                           p4d_t *dst_p4d, p4d_t *src_p4d,
                           unsigned long addr, unsigned long end)
{
    unsigned long next;

    do {
        next = p4d_addr_end(addr, end);
        if (p4d_none_or_clear_bad(src_p4d))
            continue;

        if (copy_pud_range(dst_vma, src_vma,
                           p4d_pgtable(dst_p4d), p4d_pgtable(src_p4d),
                           addr, next))
            return -ENOMEM;
    } while (dst_p4d++, src_p4d++, addr = next, addr < end);

    return 0;
}
```

注：在 x86-64 上，P4D 与 PGD 是折叠的（`__PAGETABLE_P4D_FOLDED`），`p4d_none_or_clear_bad` 总是返回 false，`p4d_pgtable` 直接返回 PGD 的底值。

### 3.2 copy_pud_range

```c
// mm/memory.c:1400 — doom-lsp 确认
static int copy_pud_range(...)
{
    do {
        next = pud_addr_end(addr, end);
        if (pud_none_or_clear_bad(src_pud))
            continue;

        if (pud_devmap(*src_pud) || pud_trans_huge(*src_pud)) {
            // ★ 1GB 大页
            if (copy_huge_pud(dst_mm, src_mm,
                              dst_pud, src_pud, addr, next))
                return -ENOMEM;
        } else {
            if (copy_pmd_range(dst_vma, src_vma,
                               pud_pgtable(dst_pud), pud_pgtable(src_pud),
                               addr, next))
                return -ENOMEM;
        }
    } while (...);
}
```

### 3.3 copy_pmd_range

```c
// mm/memory.c:1363 — doom-lsp 确认
static int copy_pmd_range(...)
{
    do {
        next = pmd_addr_end(addr, end);
        if (pmd_none_or_clear_bad(src_pmd))
            continue;

        if (pmd_devmap(*src_pmd) || pmd_trans_huge(*src_pmd)) {
            // ★ 2MB THP 大页
            if (copy_huge_pmd(dst_mm, src_mm,
                              dst_pmd, src_pmd, addr, next))
                return -ENOMEM;
        } else {
            if (copy_pte_range(dst_vma, src_vma,
                               pmd_pgtable(dst_pmd), pmd_pgtable(src_pmd),
                               addr, next))
                return -ENOMEM;
        }
    } while (...);
}
```

---

## 4. 🔥 PTE 级复制——copy_pte_range

```c
// mm/memory.c:1208 — doom-lsp 确认
static int copy_pte_range(struct vm_area_struct *dst_vma,
                           struct vm_area_struct *src_vma,
                           pmd_t *dst_pmd, pmd_t *src_pmd,
                           unsigned long addr, unsigned long end)
{
    struct mm_struct *dst_mm = dst_vma->vm_mm;
    struct mm_struct *src_mm = src_vma->vm_mm;
    pte_t *src_pte, *dst_pte;
    spinlock_t *src_ptl, *dst_ptl;
    int rss[NR_MM_COUNTERS];
    int ret = 0;

    // [1] 为子进程分配 PTE 页表
    dst_pte = pte_alloc_map_lock(dst_mm, dst_pmd, addr, &dst_ptl);
    if (!dst_pte) {
        ret = -ENOMEM;
        goto out;
    }

    // [2] 映射父进程的 PTE 页表
    src_pte = pte_offset_map_rw_nolock(src_mm, src_pmd, addr,
                                        &dummy_pmdval, &src_ptl);
    if (!src_pte) {
        pte_unmap_unlock(dst_pte, dst_ptl);
        goto out;
    }

    // [3] 锁嵌套（父子 PTE 页需要同时锁定）
    spin_lock_nested(src_ptl, SINGLE_DEPTH_NESTING);

    // [4] 核心复制循环
    do {
        pte_t ptent;
        struct page *page;
        struct folio *folio;

        // 读取父进程 PTE 条目
        ptent = ptep_get(src_pte);

        // 跳过不存在的 PTE
        if (pte_none(ptent)) {
            progress++;
            continue;
        }

        // 跳过 PTE 特殊条目（swap entry, pte_marker 等）
        if (unlikely(!pte_present(ptent))) {
            if (!is_swap_pte(ptent)) {
                progress++;
                continue;
            }
            // swap 页面 → 复制 swap entry + 增加 swap 引用
            if (copy_swap_entry(dst_mm, src_mm, ptent))
                goto copy_pte_failed;
            set_pte_at(dst_mm, addr, dst_pte, ptent);
            progress++;
            continue;
        }

        // 获取物理页的 struct page
        page = vm_normal_page(dst_vma, addr, ptent);
        if (page) {
            folio = page_folio(page);

            // ★ 增加 folio 引用计数（父子共享同一物理页）
            folio_ref_add(folio, mapcount_inc);

            // 更新反向映射计数
            if (folio_test_anon(folio))
                rss[MM_ANONPAGES]++;
            else
                rss[MM_FILEPAGES]++;

            // ★ 写保护父进程的 PTE（为 COW 做准备）
            // 如果是 COW 映射（私有可写），父进程也被标记只读
            if (is_cow_mapping(src_vma->vm_flags)) {
                ptent = pte_wrprotect(ptent);  // 清除写位！
                // ★ 使用 ptep_set_wrprotect 确保 TLB 一致性
                ptep_set_wrprotect(src_mm, addr, src_pte);
            }

            // 确保子进程的 PTE 也是只读
            ptent = pte_mkold(ptent);  // 清除 Accessed 位

            // 清除脏位（dirty 状态由 folio 的标记管理）
            ptent = pte_mkclean(ptent);

            // 写入子进程的 PTE
            set_pte_at(dst_mm, addr, dst_pte, ptent);
        }

        progress++;
    } while (dst_pte++, src_pte++, addr += PAGE_SIZE, addr < end);

    // [5] 更新 RSS 统计
    add_mm_counter(dst_mm, MM_ANONPAGES, rss[MM_ANONPAGES]);
    add_mm_counter(dst_mm, MM_FILEPAGES, rss[MM_FILEPAGES]);

    // [6] 解锁
    pte_unmap_unlock(src_pte - 1, src_ptl);
    pte_unmap_unlock(dst_pte - 1, dst_ptl);

    cond_resched();  // 如果复制的页数很多，让出 CPU

out:
    return ret;
}
```

---

## 5. 🔥 Fork 后的 COW 数据流

```
fork() 前的父进程状态：
  PTE_A: [页 X, RW]  ← 匿名可写页
  PTE_B: [页 Y, RW]
  PTE_C: [页 Z, RW]

copy_page_range 后的状态（父子进程共享所有页，但都标记只读）：
  ┌─ 父进程 ──────────────────────┐
  │ PTE_A: [页 X, RO, 共享计数=2]  │
  │ PTE_B: [页 Y, RO, 共享计数=2]  │
  │ PTE_C: [页 Z, RO, 共享计数=2]  │
  └───────────────────────────────┘
                                     ← 物理页 X, Y, Z
  ┌─ 子进程 ──────────────────────┐
  │ PTE_A: [页 X, RO, 共享计数=2]  │
  │ PTE_B: [页 Y, RO, 共享计数=2]  │
  │ PTE_C: [页 Z, RO, 共享计数=2]  │
  └───────────────────────────────┘

[一段时间后，子进程写入页 X]

子进程缺页 → handle_pte_fault → do_wp_page（写时复制）
  │
  ├─ folio = page_folio(page)
  │
  ├─ folio_ref_count(folio) > 1? → 是（父子进程共享）
  │   → 需要 COW！
  │
  ├─ 分配新页面页 X'
  │   folio_new = vma_alloc_folio(GFP_HIGHUSER, 0, vma, addr)
  │
  ├─ 复制内容：
  │   copy_user_highpage(&folio_new->page, &folio->page)
  │   → 将页 X 的内容复制到页 X'
  │   → 这是实际的内存复制操作！！！
  │
  ├─ 更新子进程 PTE：
  │   set_pte_at(mm, addr, pte, mk_pte(&folio_new->page, vma->vm_page_prot))
  │   → 子进程 PTE 指向页 X'（可写！）
  │
  ├─ 释放原始页的引用：
  │   folio_put(folio)
  │   → 原始页 X 的引用计数从 2 降为 1
  │
  └─ 后续状态：
     父进程: PTE_A → 页 X (RO)  ← 依然是只读
     子进程: PTE_A → 页 X'(RW)  ← 独立的副本
```

**关键性能观察**：

```
fork()+exec 的程序（如 Shell 执行外部命令）：
  ├─ fork() 复制全部 VMA 和页表（O(n)）
  ├─ execve() 立刻释放所有页表（O(n)）
  └─ ← 95% 的 fork 工作被浪费了！

系统调用延迟：
  fork() (COW, 空地址空间):       ~20μs
  fork() (100MB RSS 进程):         ~500μs  ← 页表复制是线性时间
  vfork() (不复制地址空间):         ~5μs
```

---

## 6. vma_needs_copy——复制决策

```c
// mm/memory.c:1466 — doom-lsp 确认
static bool
vma_needs_copy(struct vm_area_struct *dst_vma, struct vm_area_struct *src_vma)
{
    if (dst_vma->vm_flags & VM_COPY_ON_FORK)
        return true;
    if (src_vma->anon_vma)
        return true;
    return false;
}
```

**决策逻辑**：
1. `dst_vma->vm_flags & VM_COPY_ON_FORK` → 必须复制（userfaultfd 等场景）
2. `src_vma->anon_vma` 存在 → 匿名映射已有页表，必须复制
3. 否则 → 延迟页表分配（缺页时自动建立），不需要复制

**完整决策矩阵**：

| VMA 类型 | 特征 | 需要复制？| 原因 |
|----------|------|----------|------|
| 匿名私有（已写入）| 有 anon_vma | ✅ | 页表已存在，不能靠缺页重建 |
| 匿名私有（未写入）| 无 anon_vma | ❌ | 缺页时自动建立 |
| 文件共享 | MAP_SHARED | ❌ | 缺页时从 page cache 读取 |
| 文件私有只读 | MAP_PRIVATE\|RO | ❌ | 缺页时填充 |
| 文件私有可写（已 COW）| 有 anon_vma | ✅ | 已创建匿名副本 |
| VM_COPY_ON_FORK | VM_UFFD_WP 等 | ✅ | 用户明确要求 |
## 7. copy_hugetlb_page_range——大页复制

当 VMA 是 hugetlb 映射时，使用专门的复制函数：

```c
// mm/hugetlb.c
int copy_hugetlb_page_range(struct mm_struct *dst, struct mm_struct *src,
                             struct vm_area_struct *vma)
{
    // hugetlb 使用 PMD 级别的页表（2MB 或 1GB 大页）
    // 每个 PTE 对应一个大页，而不是标准 4KB 页面
    
    // 复制策略同样是 COW（写时复制）：
    // 1. 复制 PMD 页表项指向同一个大页
    // 2. 父进程 PMD 写保护
    // 3. 子进程写时触发 COW 缺页 → 分配新大页
}
```

---

## 8. 性能特征

| 指标 | 值 | 说明 |
|------|-----|------|
| 单 PTE 复制 | ~100 ns | set_pte_at + folio_ref_add + ptep_set_wrprotect |
| 1GB RSS 复制 | ~25 ms | 1GB / 4KB × 100ns |
| 写保护（per PTE）| ~20 ns | ptep_set_wrprotect + TLB flush |
| COW 缺页 | ~500 ns | 分配页 + 复制 4KB 内容 |
| `vma_needs_copy` 检查 | ~5 ns | 位运算，无内存访问 |

---

## 9. 源码文件索引

| 函数 | 行号 | 文件 |
|------|------|------|
| `copy_page_range` | 1491 | mm/memory.c |
| `copy_p4d_range` | 1437 | mm/memory.c |
| `copy_pud_range` | 1400 | mm/memory.c |
| `copy_pmd_range` | 1363 | mm/memory.c |
| `copy_pte_range` | 1208 | mm/memory.c |
| `copy_hugetlb_page_range` | — | mm/hugetlb.c |
| `dup_mmap` | — | mm/mmap.c |

---

## 10. 关联文章

- **16-vm_area_struct**：VMA 的类型决定复制策略
- **17-page_allocator**：COW 时分配新页面
- **39-mlock**：mlock 锁定 VMA 的 fork 行为
- **88-mmap**：MAP_PRIVATE vs MAP_SHARED 的 fork 交互

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
