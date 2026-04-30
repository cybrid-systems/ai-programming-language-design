# copy_page_range — fork 时页面复制深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/memory.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**copy_page_range** 在 `fork()` 时复制父进程的 VMA 区域到子进程，核心是 **COW（Copy-On-Write）** 机制。

---

## 1. COW 机制

```
fork() 后：
  父/子共享同一物理页（只读）
  ↓
任一方写入：
  触发 page fault
  ↓
内核分配新页，复制内容
  ↓
写入方获得自己的私有副本
```

---

## 2. copy_page_range — 复制 VMA

```c
// mm/memory.c — copy_page_range
int copy_page_range(struct mm_struct *dst, struct mm_struct *src,
           struct vm_area_struct *vma)
{
    struct page *page;

    // 1. 跳过不需要复制的区域
    if (is_vm_hugetlb(vma))
        return copy_hugetlb_page_range(dst, src, vma);

    if (vma->vm_flags & VM_SHARED)
        return copy_pte_range(dst, src, vma);

    if (vma->vm_flags & VM_WRITE)
        return copy_pte_range(dst, src, vma);

    // 2. 逐 PTE 复制
    for (addr = vma->vm_start; addr < vma->vm_end; addr += PAGE_SIZE) {
        pte = get_locked_pte(src, addr, &src_ptl);

        // 3. 对于只读页面（VM_READ/VM_EXEC）：
        //    直接共享，不复制（COW）
        if (pte_write(pte)) {
            // 可写：分配新页（延迟到写时）
        }

        // 4. 复制 PTE
        copy_pte(src, dst, src_pte, dst_pte, addr, page);
    }
}
```

---

## 3. copy_pte — 复制单个 PTE

```c
// mm/memory.c — copy_pte
static inline void copy_pte(struct mm_struct *dst, struct mm_struct *src,
                pte_t *src_pte, pte_t *dst_pte,
                unsigned long addr, struct page *page)
{
    pte_t pte = *src_pte;

    // 获取物理页
    page = pte_page(pte);

    // 获取页引用
    get_page(page);

    // 如果可写但不共享：
    // → 设置为只读（R/W 位清除）
    // → 设置 _PAGE_BIT_RW = 0
    // → 设置 _PAGE_BIT_DIRTY = 0（脏位清除）
    if (pte_write(pte))
        pte = pte_wrprotect(pte);

    // 父子共享同一物理页
    set_pte_at(dst, addr, dst_pte, pte);
}
```

---

## 4. 写时复制（Write Fault）

```c
// mm/memory.c — do_wp_page
static vm_fault_t do_wp_page(struct vm_fault *vmf)
{
    // 1. 获取当前 PTE
    pte_t pte = *vmf->pte;

    // 2. 如果是共享页：
    if (PageAnon(vmf->page) && page_mapcount(vmf->page) == 1) {
        // 只有一个用户（当前进程），直接改为可写
        make_page writable(vmf->page);
        return VM_FAULT_WRITE;
    }

    // 3. 否则，分配新页，复制内容
    new_page = alloc_page(GFP_KERNEL);
    copy_page(new_page, vmf->page);

    // 4. 设置新页为可写
    make_page writable(new_page);

    return VM_FAULT_WRITE;
}
```

---

## 5. 完整文件索引

| 文件 | 函数 |
|------|------|
| `mm/memory.c` | `copy_page_range`、`copy_pte`、`do_wp_page` |
