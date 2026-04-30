# 18-copy_page_range — fork 时页面复制深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/memory.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**copy_page_range** 在 `fork()` 时复制父进程的 VMA 区域到子进程。核心是 **COW（Copy-On-Write）**：fork 后父子共享物理页，只读保护，直到一方写入时才真正复制。

---

## 1. COW 机制

```
fork() 后：
  父/子共享同一物理页（只读）
  ↓
任一方写入：
  触发 page fault（write fault）
  ↓
内核分配新页，复制内容（do_wp_page）
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
    // 1. hugetlb 特殊处理
    if (is_vm_hugetlb(vma))
        return copy_hugetlb_page_range(dst, src, vma);

    // 2. 共享映射：直接复制（不 COW）
    if (vma->vm_flags & VM_SHARED)
        return copy_pte_range(dst, src, vma);

    // 3. 可写区域：正常复制（可能触发 COW）
    if (vma->vm_flags & VM_WRITE)
        return copy_pte_range(dst, src, vma);

    // 4. 只读区域：共享物理页（COW 保护）
    return copy_pte_range(dst, src, vma);
}
```

---

## 3. copy_pte_range — 复制页表项

```c
// mm/memory.c — copy_pte_range
static int copy_pte_range(struct mm_struct *dst, struct mm_struct *src,
                         struct vm_area_struct *dst_vma, struct vm_area_struct *src_vma,
                         unsigned long addr, unsigned long end)
{
    // 逐 PTE 复制
    for (; addr < end; addr += PAGE_SIZE) {
        pte_t *src_pte, *dst_pte;
        pte_t pte;

        // 1. 获取源 PTE
        src_pte = get_locked_pte(src, addr, &src_ptl);
        pte = *src_pte;

        // 2. 获取/分配目标 PTE
        dst_pte = get_locked_pte(dst, addr, &dst_ptl);

        // 3. 复制 PTE
        copy_pte(src, dst, dst_pte, src_pte, addr, page);
    }
}
```

---

## 4. copy_pte — 复制单个 PTE

```c
// mm/memory.c — copy_pte
static inline void copy_pte(struct mm_struct *dst, struct mm_struct *src,
                pte_t *dst_pte, pte_t *src_pte,
                unsigned long addr, struct page *page)
{
    pte_t pte = *src_pte;

    // 获取物理页
    page = pte_page(pte);

    // 增加页引用
    get_page(page);

    // 如果源 PTE 可写：
    if (pte_write(pte)) {
        // 设置为只读（R/W 位清除）
        pte = pte_wrprotect(pte);
        // 清除脏位
        pte = pte_mkclean(pte);
    }

    // 父子共享同一物理页
    set_pte_at(dst, addr, dst_pte, pte);

    // 两个进程的 PTE 现在都指向同一个物理页，且都是只读
}
```

---

## 5. do_wp_page — 写时复制（Write Fault）

```c
// mm/memory.c — do_wp_page
static vm_fault_t do_wp_page(struct vm_fault *vmf)
{
    struct page *page = vmf->page;
    struct page *new_page;

    // 1. 获取当前 PTE
    pte_t pte = *vmf->pte;

    // 2. 如果是匿名页且只有一个用户（当前进程）：
    if (PageAnon(page) && page_mapcount(page) == 1) {
        // 只有一个用户（当前进程），直接改为可写
        pte = pte_mkyoung(pte);    // 标记年轻
        pte = pte_mkwrite(pte);    // 标记可写
        set_pte_at(vmf->vma->vm_mm, vmf->address, vmf->pte, pte);
        update_mmu_cache(vmf->vma, vmf->address, vmf->pte);
        return VM_FAULT_WRITE;
    }

    // 3. 否则（多个共享者 或 文件映射）：分配新页，复制
    new_page = alloc_page(GFP_KERNEL | __GFP_ZERO);
    copy_page(new_page, page);

    // 4. 设置新页为可写
    pte = mk_pte(new_page, vmf->vma->vm_page_prot);
    pte = pte_mkwrite(pte);
    set_pte_at(vmf->vma->vm_mm, vmf->address, vmf->pte, pte);

    // 5. 释放旧页的引用
    put_page(page);

    return VM_FAULT_WRITE;
}
```

---

## 6. 流程图

```
fork():
  copy_page_range()
    copy_pte_range()
      copy_pte()
        pte_wrprotect()  // 设置只读
        set_pte_at()       // 父子共享同一物理页

进程A 写入 addr：
  → do_page_fault()
    → do_wp_page()
      → 如果只有一个用户：直接改为可写
      → 如果多个用户：分配新页，复制内容

进程A 现在有了自己的物理页副本！
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `mm/memory.c` | `copy_page_range`、`copy_pte_range`、`copy_pte` |
| `mm/memory.c` | `do_wp_page` |

---

## 8. 西游记类比

**COW** 就像"取经队伍复制营房"——

> 悟空（父进程）fork 出一个分身（子进程）。营房（物理页）不是立即复制一份，而是两个队伍共住一个营房，门口贴上"只读"标签（pte_wrprotect）。如果悟空的分身只是看营房（读），不用真的复制，节省空间。如果分身想装修营房（写），土地神（do_wp_page）会来：先看看营房里住了几家人（page_mapcount）。如果只有分身一家，就直接把"只读"牌子换成"可读写"（pte_mkwrite）。如果还有其他人（多用户），就要重新分配一个新营房，把原来的内容复制过去，分身住新营房。这就是 Copy-On-Write——只有在真正需要写的时候才复制。

---

## 9. 关联文章

- **vm_area_struct**（article 16）：VMA 的 COW 标志
- **page_allocator**（article 17）：COW 时分配新页
- **VFS**（article 19）：fork 时通过 copy_page_range 复制文件映射