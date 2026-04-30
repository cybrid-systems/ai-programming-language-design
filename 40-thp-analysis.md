# Linux Kernel THP (Transparent HugePages) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/huge_memory.c` + `mm/khugepaged.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 THP？

**THP（Transparent HugePages）** 是 Linux 2.6.38+ 引入的特性，**透明**地将多个 4KB 页合并为 2MB 大页，减少 TLB miss，提升性能。

**关键特点**：
- 对应用程序透明（大多数情况下）
- 匿名内存（anonymous）和文件映射（shmem/tmpfs）都支持
- `khugepaged` 后台线程主动将 4KB 页 collapses 成 2MB 页
- 可以通过 `madvise(MADV_HUGEPAGE)` 建议使用

---

## 1. 核心数据结构

### 1.1 PMD 条目（Huge Page 表项）

```c
// arch/arm64/include/asm/pgtable-hwdef.h — ARM64 PMD 条目
#define PMD_TYPE_MASK        (_AT(pmdval_t, 3) << 1)
#define PMD_TYPE_SECTION     (_AT(pmdval_t, 1) << 1)  // 2MB block
#define PMD_TABLE            (_AT(pmdval_t, 3) << 1)  // 页表

// x86_64 PUD 条目（Huge Page = 1GB 或 PMD = 2MB）
#define PUD_TYPE_MASK        (_AT(pudval_t, 7))
#define PUD_TYPE_HUGEPAGE   (_AT(pudval_t, 1))  // 1GB huge page
#define PUD_TYPE_SECTION    (_AT(pudval_t, 3))  // 1GB block

// PMD 条目关键字段
struct {
    unsigned long pfn:55;      // 页帧号
    unsigned long soft:1;     // 软标志
    unsigned long fixed:10;   // 保留
} s;
```

### 1.2 folio（THP 表示）

```c
// include/linux/mm.h — folio（THP 表示）
struct folio {
    struct page page;  // 第一个子页
    // ...
};

// THP 的 struct page（compound page）
struct page {
    unsigned long flags;                  // PG_head / PG_tail
    unsigned long compound_head;          // 如果是 tail page，指向 head
    unsigned short compound_order;         // 大小（order），THP 通常 = 9（512*4K=2MB）
    unsigned short compound_pincount;     // 引用计数

    // THP 内容
    void *private;                       // 释放函数
};

// PG_head：表示这是 huge page 的第一个子页
// PG_tail：表示这是 huge page 的后续子页
```

---

## 2. THP collapse — khugepaged 将 4KB 合并为 2MB

### 2.1 khugepaged 后台线程

```c
// mm/khugepaged.c — khugepaged_scan_mm_slot
static void khugepaged_scan_mm_slot(struct khugepaged_mm_slot *mm_slot)
{
    struct mm_struct *mm = mm_slot->mm;
    struct vm_area_struct *vma;

    // 1. 获取一个 VMA（需要是 anonymous 且有 MADV_HUGEPAGE 标志）
    vma = find_extend_vma(mm, khugepaged_scan_address);

    // 2. 扫描 VMA 内的 PTE，收集 4KB 页
    //    每次扫描最多 512 个页（2MB / 4KB）
    collapse_pte_mm(mm, vma, addr);

    // 3. 如果收集满 2MB，触发 collapse
    //    collapse_huge_page(mm, addr);
}

// mm/khugepaged.c — collapse_huge_page
static void collapse_huge_page(struct mm_struct *mm, unsigned long addr)
{
    // 1. 分配一个 2MB 的 THP
    new_folio = alloc_hugepage_vma(GFP_TRANSHUGE, vma, HPAGE_PMD_ORDER);

    // 2. 获取所有涉及的 4KB 页（get_user_pages）
    // 3. 复制所有 4KB 页内容到 2MB 页
    copy_user_huge_page(new_folio, old_pages, addr);

    // 4. 将 2MB 页插入页表（替换原来的 512 个 PTE）
    set_pmd(pmd, mk_huge_pmd(new_folio, prot));

    // 5. 释放原来的 4KB 页
    for (i = 0; i < HPAGE_PMD_NR; i++)
        put_page(old_pages[i]);

    // 6. 刷新 TLB
    flush_tlb_range(mm, addr, addr + HPAGE_PMD_SIZE);
}
```

---

## 3. THP page fault

```c
// mm/huge_memory.c — do_huge_pmd_wp_page
static vm_fault_t do_huge_pmd_wp_page(struct vm_fault *vmf)
{
    struct page *page;

    // 1. 如果 PMD 是干净的且可写的（共享），进行 COW
    if (pmd_trans_huge(*vmf->pmd) && pmd_write(*vmf->pmd)) {
        // COW：分配新的 THP，复制内容
        new_page = alloc_hugepage_vma(GFP_TRANSHUGE, vma, HPAGE_PMD_ORDER);
        copy_user_huge_page(new_page, page, vmf->address);

        // 设置新的 PMD
        set_pmd_at(vma->vm_mm, vmf->address, vmf->pmd,
                mk_huge_pmd(new_page, vma->vm_page_prot));

        // 释放旧 THP
        put_page(page);
    }
}
```

---

## 4. THP split — 拆分大页

```c
// mm/huge_memory.c — split_huge_pmd
void split_huge_pmd(struct vm_area_struct *vma, pmd_t *pmd, unsigned long address)
{
    // 当需要修改部分 THP 时触发（如 mprotect、mremap）
    // 将 2MB PMD 拆分为 512 个 4KB PTE

    page = pmd_page(*pmd);  // 获取 THP head page
    for (i = 0; i < HPAGE_PMD_NR; i++) {
        pte_t *pte = pte_offset_map(pmd, address + i * PAGE_SIZE);
        set_pte(pte, mk_pte(page + i, prot));  // 每个 PTE 指向子页
        pte_unmap(pte);
    }

    // 清除 PMD 的 huge 页标志
    pmd_clear(pmd);
    flush_tlb_range(mm, address, address + HPAGE_PMD_SIZE);
}
```

---

## 5. THP 内存布局

```
普通 4KB 页表：
  pgd → pud → pmd → pte → struct page（4KB）

THP（2MB）页表：
  pgd → pud → pmd ———→ struct folio（2MB）
                            （512 个 4KB 子页，compound page）
                            （PG_head = 1, PG_tail = 1 for each）
```

---

## 6. madvise(MADV_HUGEPAGE)

```c
// 应用程序提示内核对指定区域使用 THP
madvise(addr, len, MADV_HUGEPAGE);
// 设置 VM_HUGEPAGE 标志
// khugepaged 会优先扫描此 VMA
// page fault 时会自动分配 THP
```

---

## 7. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| PG_head / PG_tail | compound page 共享元数据，省内存 |
| khugepaged 后台扫描 | 主动合并，应用程序无需感知 |
| madvise(MADV_HUGEPAGE) | 让用户提示哪些区域值得合并 |
| THP split on COW/write | 写时复制时需要拆分，保护共享大页 |
| PG_unevictable | THP 合并期间临时锁定页，防止被换出 |

---

## 8. 参考

| 文件 | 内容 |
|------|------|
| `mm/huge_memory.c` | `do_huge_pmd_wp_page`、`split_huge_pmd`、`collapse_huge_page` |
| `mm/khugepaged.c` | `khugepaged_scan_mm_slot`、`collapse_huge_page` |
| `include/linux/mm.h` | `PG_head`、`PG_tail`、`compound_order` |
| `arch/arm64/include/asm/pgtable-hwdef.h` | PMD_TYPE_SECTION 定义 |
