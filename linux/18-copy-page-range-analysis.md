# 18-copy-page-range — 进程地址空间复制深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**copy_page_range** 是 Linux 内核实现 `fork()` 时复制父进程地址空间的核心函数。它递归遍历父进程的页表树（PGD→P4D→PUD→PMD→PTE），为子进程创建完全独立的页表副本。

核心策略是 **COW（Copy-on-Write）**：`fork()` 后并不立即复制物理页面，而是让父子进程共享所有页面，并将父进程的所有页表项标记为只读。当任一进程尝试写入时，触发写时复制缺页，在缺页处理中复制页面。

**doom-lsp 确认**：`copy_page_range` @ `mm/memory.c:1490`，其内部调用链为 `copy_page_range→copy_p4d_range→copy_pud_range→copy_pmd_range→copy_pte_range`。

---

## 1. 完整调用栈

```
fork() → kernel_clone() → copy_process()
  └─ copy_mm()
       └─ dup_mm()
            └─ dup_mmap()
                 └─ copy_page_range(dst_vma, src_vma)  @ mm/memory.c:1490
                      │
                      ├─ [VMA 类型检查]
                      │   vma_needs_copy(dst_vma, src_vma)
                      │   → 决定是否需要复制（私有映射需要 COW，
                      │     共享映射不需要）
                      │
                      ├─ [大页处理]
                      │   if (is_vm_hugetlb_page(src_vma))
                      │       return copy_hugetlb_page_range(...)
                      │       // hugetlb 专用页表复制
                      │
                      ├─ [MMU 通知]
                      │   mmu_notifier_invalidate_range_start(...)
                      │   // 通知 KVM 等：父进程页表正在变化
                      │
                      ├─ [页表层级遍历]
                      │   copy_p4d_range(dst_vma, src_vma,
                      │                  dst_pgd, src_pgd,
                      │                  addr, end)
                      │    │
                      │    ├─ for each P4D entry in range:
                      │    │    ├─ copy_pud_range(...)
                      │    │    │    ├─ for each PUD entry:
                      │    │    │    │   ├─ [PUD 大页检查]
                      │    │    │    │   │   if (pud_devmap || pud_trans_huge)
                      │    │    │    │   │       copy_huge_pud
                      │    │    │    │   │
                      │    │    │    │   └─ copy_pmd_range(...)
                      │    │    │    │        ├─ for each PMD entry:
                      │    │    │    │        │   ├─ [PMD 大页检查]
                      │    │    │    │        │   │   if (pmd_trans_huge)
                      │    │    │    │        │   │       copy_huge_pmd
                      │    │    │    │        │   │   if (pmd_devmap)
                      │    │    │    │        │   │       copy_huge_pmd
                      │    │    │    │        │   │
                      │    │    │    │        │   └─ copy_pte_range(...)  @ L1208
                      │    │    │    │        │        ← 最内层：PTE 级复制！
                      │    │    │    │        │           |
                      │    │    │    │        └─ 循环下一个 PMD
                      │    │    │    └─ 循环下一个 PUD
                      │    │    └─ 循环下一个 P4D
                      │
                      ├─ [MMU 通知结束]
                      │   mmu_notifier_invalidate_range_end(...)
                      │
                      └─ return 0
```

---

## 2. 🔥 PTE 级复制——copy_pte_range

```c
// mm/memory.c:1208 — doom-lsp 确认
copy_pte_range(dst_vma, src_vma, dst_pmd, src_pmd, addr, end)
{
    // 1. 分配子进程的 PTE 页表
    dst_pte = pte_alloc_map_lock(dst_mm, dst_pmd, addr, &dst_ptl);
    if (!dst_pte) return -ENOMEM;

    // 2. 映射父进程的 PTE 页表
    src_pte = pte_offset_map_rw_nolock(src_mm, src_pmd, addr, &src_ptl);

    // 3. 循环复制每个 PTE：
    for (; addr < end; addr += PAGE_SIZE) {
        ptent = ptep_get(src_pte);                // 读父进程 PTE
        page = vm_normal_page(dst_vma, addr, ptent); // 获取 struct page

        if (page) {
            folio = page_folio(page);
            // 增加 folio 引用计数
            folio_ref_add(folio, mapcount_inc);

            if (unlikely(folio_test_swapcache(folio))) {
                // 交换缓存中的页面 → 增加引用
            }

            // 设置子进程 PTE
            // 对于私有映射（COW）：清除 PTE 的写权限
            if (is_cow_mapping(vma->vm_flags)) {
                ptent = pte_wrprotect(ptent);       // 清除写位！
                // 父进程的 PTE 也在 fork() 过程中被写保护
            }
        }

        // 写入子进程页表
        set_pte_at(dst_mm, addr, dst_pte, ptent);
        
        src_pte++;
        dst_pte++;
    }

    // 4. 更新 RSS 统计
    add_mm_counter(dst_mm, MM_ANONPAGES, rss[MM_ANONPAGES]);
    // ...
}
```

**doom-lsp 确认的关键行**：`copy_pte_range` @ L1208，`copy_pmd_range` @ L1363，`copy_pud_range` @ L1400，`copy_p4d_range` @ L1436。

---

## 3. 🔥 Fork 后的 COW 数据流

```
fork() 后父子进程页表状态：

父进程原始：     ┌─── 页 A (rw) ──┬─── 页 B (rw) ──┬─── 页 C (rw) ──┐
                 └───────────────┴───────────────┴───────────────┘

copy_page_range 后：
                  ┌─── 页 A (ro) ──┬─── 页 B (ro) ──┬─── 页 C (ro) ──┐ ← 父进程
父子共享物理页面  └───────────────┴───────────────┴───────────────┘
（但都标记只读）   ┌──────────────────────────────────────────────────┐
                  ├─── 页 A (ro) ──┬─── 页 B (ro) ──┬─── 页 C (ro) ──┤ ← 子进程
                  └──────────────────────────────────────────────────┘
                  共享同一物理页面（page->_refcount = 2）

子进程写入页 A（触发缺页）：
  handle_mm_fault → do_wp_page (write-protect page fault)
    ├─ 分配新页面页 A'
    ├─ copy_user_highpage(A' ← A)     ← 复制原页面内容
    ├─ 更新子进程 PTE：A' 设为可写
    ├─ 父进程 PTE 不变（仍指向 A，只读）
    └─ page_A 引用计数 -1

                   ┌─── 页 A (ro) ──┬─── ... ← 父进程（原始页）
                   └───────────────┘
                   ┌─── 页 A' (rw) ─┬─── ... ← 子进程（COW 复制页）
                   └───────────────┘
```

---

## 4. VMA 复制决策

`vma_needs_copy` 决定哪些 VMA 需要复制页表：

```c
static inline bool vma_needs_copy(struct vm_area_struct *dst_vma,
                                   struct vm_area_struct *src_vma)
{
    // 只有私有可写映射需要 COW 复制
    // 共享映射的页表直接通过 do_wp_page 处理
    // 只读私有映射不需要修改
    return (src_vma->vm_flags & (VM_SHARED | VM_MAYWRITE)) == VM_MAYWRITE;
}
```

| 映射类型 | 需要复制 | 原因 |
|---------|---------|------|
| 私有可写（MAP_PRIVATE \| PROT_WRITE）| ✅ | 需要 COW |
| 私有只读（MAP_PRIVATE \| PROT_READ）| ❌ | 只读共享安全 |
| 共享（MAP_SHARED）| ❌ | 文件映射，页表由 VMA 共享 |

---

## 5. 性能考虑

| 操作 | 复杂度 | 影响因素 |
|------|--------|---------|
| `copy_page_range` | O(VMA + PTE) | 进程地址空间大小 |
| 单 PTE 复制 | O(1) | set_pte_at + folio_ref_add |
| COW 缺页（写时） | O(1) | 分配新页 + 复制内容 |
| 大页复制 | O(1) | 复制 PMD/PUD 而非 PTE |

---

## 6. 源码文件索引

| 函数 | 行号 | 文件 |
|------|------|------|
| `copy_page_range` | 1490 | mm/memory.c |
| `copy_p4d_range` | 1436 | mm/memory.c |
| `copy_pud_range` | 1400 | mm/memory.c |
| `copy_pmd_range` | 1363 | mm/memory.c |
| `copy_pte_range` | 1208 | mm/memory.c |
| `copy_hugetlb_page_range` | — | mm/hugetlb.c |

---

## 7. 关联文章

- **16-vm_area_struct**：VMA 的类型决定了复制策略
- **17-page_allocator**：COW 时分配新页面
- **39-mlock**：mlock 锁定页面的 fork 行为
- **88-mmap**：MAP_PRIVATE vs MAP_SHARED

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
