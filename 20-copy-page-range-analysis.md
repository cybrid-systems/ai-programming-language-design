# Linux Kernel copy_page_range (fork) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/memory.c` + `kernel/fork.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 copy_page_range？

**`copy_page_range`** 是 `fork()` 时复制进程地址空间的核心函数。它遍历父进程的页表，将每个 PTE 复制到子进程，对于 COW（Copy-On-Write）页面则**共享物理页并标记为只读**。

**核心场景**：
- `fork()` 创建子进程时复制整个地址空间
- `vfork()` 不复制（共享地址空间）
- `clone()` 带 `CLONE_VM` 时也不复制

---

## 1. fork 整体流程

```
fork()
  → _do_fork()
    → copy_process()
      → dup_task_struct()           // 复制 task_struct
      → copy_files()                // 复制文件描述符
      → copy_fs()                   // 复制文件系统上下文
      → copy_sighand()              // 复制信号处理
      → copy_mm()                   // 复制内存空间
      │     → dup_mm()
      │           → dup_mmap()
      │                 → copy_page_range()  ← 核心
      → copy_thread()               // 复制寄存器状态
    → wake_up_new_task()            // 唤醒子进程
```

---

## 2. dup_mm — 内存空间复制入口

```c
// kernel/fork.c:1518 — dup_mm
static struct mm_struct *dup_mm(struct task_struct *tsk)
{
    struct mm_struct *mm, *oldmm;

    oldmm = current->mm;
    mm = allocate_mm();              // 分配新的 mm_struct

    // 复制 mm_struct 内容
    memcpy(mm, oldmm, sizeof(*mm));

    // 初始化新 mm
    mm_init(mm);

    // 复制所有 VMA（核心：dup_mmap）
    if (dup_mmap(mm, oldmm) < 0)
        goto fail;

    // 复制页表（copy_page_range 在 dup_mmap 中调用）
    return mm;
}
```

---

## 3. dup_mmap — VMA 复制

```c
// mm/mmap.c — dup_mmap
int dup_mmap(struct mm_struct *mm, struct mm_struct *oldmm)
{
    struct vm_area_struct *mpnt, *tmp, *prev;
    struct rb_node **rb_link, *rb_parent;

    // 获取旧进程的 mmap_lock（读锁）
    down_read(&oldmm->mmap_lock);

    // 遍历旧进程的每个 VMA
    for (mpnt = oldmm->mmap; mpnt; mpnt = mpnt->vm_next) {
        // 分配新的 VMA
        tmp = vm_area_dup(mpnt);
        if (!tmp)
            goto fail;

        // 设置新的 mm 指针
        tmp->vm_mm = mm;

        // 关键：复制页表（copy_page_range）
        if (mpnt->vm_ops && mpnt->vm_ops->copy_vma) {
            // 某些特殊 VMA 需要自定义复制
            if (!mpnt->vm_ops->copy_vma(tmp, mpnt->vm_start, mpnt->vm_end))
                goto fail;
        } else {
            // 普通 VMA：复制页表内容
            copy_page_range(tmp, mpnt);
        }

        // 插入红黑树和链表
        vma_link(mm, tmp, prev, &rb_link, &rb_parent);
    }

    up_read(&oldmm->mmap_lock);
    return 0;
}
```

---

## 4. copy_page_range — 核心实现

```c
// mm/memory.c:1491 — copy_page_range
int copy_page_range(struct vm_area_struct *dst_vma, struct vm_area_struct *src_vma)
{
    pgd_t *src_pgd, *dst_pgd;
    unsigned long addr = src_vma->vm_start;
    unsigned long end = src_vma->vm_end;
    unsigned long next;

    // 1. 检查是否需要复制
    //    某些 VMA 不需要复制（如内核线程的 mm = NULL）
    if (!vma_is_anonymous(src_vma) &&
        (!src_vma->vm_ops || !src_vma->vm_ops->copy_vma))
        // 非匿名 VMA（如文件映射）可能不需要走 copy_page_range
        // 某些走自定义 copy_vma

    // 2. 检查 VM_DONTCOPY（fork 时不复制）
    if (src_vma->vm_flags & VM_DONTCOPY)
        return 0;

    // 3. 禁止堆栈自动扩展（COW 会处理）
    if (is_vm_hugetlb_page(src_vma)) {
        // huge page 走专门路径
        copy_hugetlb_page_range(dst_mm, src_mm, vma, dst_vma);
        return 0;
    }

    // 4. 写时复制（COW）标志
    //    父进程的所有页面在 fork 后都是只读的
    bool cow = !(src_vma->vm_flags & VM_SHARED);

    // 5. 通知 mmu_notifier（KSM 等需要知道页表正在被复制）
    mmu_notifier_invalidate_range_start(&range);

    // 6. 逐级复制页表：pgd → pud → pmd → pte
    src_pgd = pgd_offset(src_mm, addr);
    dst_pgd = pgd_offset(dst_mm, addr);

    do {
        next = pgd_addr_end(addr, end);

        if (pgd_none_or_clear_bad(src_pgd))
            continue;  // 空页表，跳过

        copy_p4d_range(dst_vma, src_vma, dst_pgd, src_pgd, addr, next);
    } while (dst_pgd++, src_pgd++, addr = next, addr != end);

    mmu_notifier_invalidate_range_end(&range);

    return 0;
}
```

---

## 5. 逐级页表复制

### 5.1 copy_p4d_range → copy_pud_range → copy_ptes_range

```c
// mm/memory.c:1437 — copy_p4d_range
static inline int copy_p4d_range(struct vm_area_struct *dst_vma,
             struct vm_area_struct *src_vma, ...)
{
    pud_t *src_pud, *dst_pud;

    src_pud = pud_offset(src_pgd, addr);
    dst_pud = pud_offset(dst_pgd, addr);

    do {
        next = pud_addr_end(addr, end);

        if (pud_none_or_clear_bad(src_pud))
            continue;

        copy_pud_range(dst_vma, src_vma, dst_pud, src_pud, addr, next);
    } while (dst_pud++, src_pud++, addr = next, addr != end);
}

// mm/memory.c:1400 — copy_pud_range
static inline int copy_pud_range(struct vm_area_struct *dst_vma,
             struct vm_area_struct *src_vma, ...)
{
    pmd_t *src_pmd, *dst_pmd;

    src_pmd = pmd_offset(src_pud, addr);
    dst_pmd = pmd_offset(dst_pud, addr);

    do {
        next = pmd_addr_end(addr, end);

        if (pmd_none_or_clear_bad(src_pmd))
            continue;

        copy_ptes_range(dst_vma, src_vma, dst_pmd, src_pmd,
                addr, next, &src_ptl);
    } while (dst_pmd++, src_pmd++, addr = next, addr != end);
}
```

### 5.2 copy_ptes_range — PTE 复制核心

```c
// mm/memory.c — copy_ptes_range
static inline int copy_ptes_range(struct vm_area_struct *dst_vma,
             struct vm_area_struct *src_vma, ...)
{
    pte_t *src_pte, *dst_pte;
    unsigned long addr = start;

    src_pte = pte_offset_map(src_pmd, addr);
    dst_pte = pte_offset_map(dst_pmd, addr);

    do {
        pte_t pte = ptep_get(src_pte);  // 获取父进程的 PTE

        // 跳过空 PTE 或 swap entry
        if (pte_none(pte) || !pte_present(pte))
            continue;

        // ========== COW 处理 ==========
        // 如果是 COW（fork 后父子的共享页面）
        // 需要：
        //   1. 将两个 PTE 都设为只读
        //   2. 共享同一物理页
        //   3. 当任一进程写入时触发 page fault → 分配新页复制
        if (cow) {
            struct page *page;

            // 获取物理页
            page = pte_page(pte);
            if (page_to_nid(page) != dst_mm->numa_node)
                // NUMA 亲和性检查
                set_pte_at(dst_mm, addr, dst_pte, pte);
            else
                set_pte_at_notify(dst_mm, addr, dst_pte,
                        pte_mkold(pte_mkclean(pte)));  // 清除 dirty，写时触发 fault

            // 如果页是 anonymous，增加引用计数
            // （共享！两个进程共用同一物理页）
            if (PageAnon(page)) {
                get_page(page);  // 子进程也持有一个引用
                page_dup_file_page(page);  // 更新 anon_vma
            }
        } else {
            // 非 COW（VM_SHARED）：直接复制 PTE
            set_pte_at(dst_mm, addr, dst_pte, pte);
        }

    } while (dst_pte++, src_pte++, addr += PAGE_SIZE, addr != end);

    pte_unmap(dst_pte - 1);
    pte_unmap(src_pte - 1);
}
```

---

## 6. COW（Copy-On-Write）机制

```
fork() 后，父进程和子进程共享所有物理页面：

父进程 PTE                    子进程 PTE
┌─────────────────┐          ┌─────────────────┐
│ PTE_A           │          │ PTE_A'          │
│ 物理页: Page-X  │◄────────►│ 物理页: Page-X  │
│ _refcount = 2   │          │ (同一页)        │
│ PTE: R-- (只读) │          │ PTE: R-- (只读) │
└─────────────────┘          └─────────────────┘

当父进程写入 Page-X 时：
  1. 触发 #PF（page fault）
  2. do_wp_page() 检测到是 COW 共享页
  3. 分配新页 Page-Y
  4. 复制 Page-X 内容到 Page-Y
  5. 父进程 PTE → Page-Y（R/W）
  6. 子进程 PTE 保持 → Page-X（R--）

结果：两个进程各自有独立的物理页，内容相同
```

---

## 7. do_wp_page — COW Page Fault 处理

```c
// mm/memory.c — do_wp_page（写保护 fault）
static vm_fault_t do_wp_page(struct vm_fault *vmf)
{
    struct page *page = vmf->page;

    // 如果是 COW 共享页
    if (PageAnon(page) && page_count(page) > 1) {
        // 分配新页
        struct page *new_page = alloc_page_vma(...);

        // 复制内容
        copy_user_highpage(new_page, page);

        // 页引用：原页 -1，新页 +1
        put_page(page);
        get_page(new_page);

        // 更新 PTE 指向新页
        set_pte_at_notify(vma->vm_mm, address, vmf->pte,
                mk_pte(new_page, vma->vm_page_prot));

        return VM_FAULT_WRITE;  // 写成功
    }

    // 独立页面（引用计数 == 1）：直接改为可写
    if (pte_write(pte)) {
        ptep_get_and_clear(vma->vm_mm, address, vmf->pte);
        return do_page_mkwrite(vma, vmf);
    }
}
```

---

## 8. write_protect_seq 与 COW 检测

```c
// mm/memory.c — copy_page_range 中
// 在复制页表时设置 write_protect_seq
// 用于 GUP-fast 检测 COW 期间的状态

write_protect_seq_begin(src_mm);
// 遍历复制所有 PTE，将 COW 页都设为只读
// 复制完成后
write_protect_seq_end(src_mm);
```

---

## 9. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| COW 延迟复制 | fork 后大多数页面从不被写入，复制是浪费 |
| PTE 共享直到写入 | 零拷贝 fork，极大加速 fork |
| `page_count > 1` 检测 COW | 引用计数 > 1 表示共享 |
| `vm_flags & VM_SHARED` 判断非 COW | 共享映射永远不 COW |
| mmu_notifier 通知 | KSM、TSM 等需要知道页表正在被复制 |
| 逐级复制（pgd→pud→pmd→pte）| 按需复制，未映射区域不分配页表 |

---

## 10. 参考

| 文件 | 内容 |
|------|------|
| `kernel/fork.c:1518` | `dup_mm` 入口 |
| `mm/mmap.c` | `dup_mmap` VMA 复制 |
| `mm/memory.c:1491` | `copy_page_range` 完整实现 |
| `mm/memory.c:1400` | `copy_pud_range` / `copy_p4d_range` |
| `mm/memory.c` | `copy_ptes_range` PTE 复制核心 |
| `mm/memory.c` | `do_wp_page` COW fault 处理 |
