# Linux Kernel get_user_pages 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/gup.c` + `mm/memory.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 概述

`get_user_pages`（GUP）将用户空间虚拟地址转换为物理页框，并**pin**住这些页（增加引用计数），使内核可以安全访问。

**核心问题 GUP 要解决**：
1. 用户空间页可能不在内存（需要 `handle_mm_fault` 分配）
2. 用户空间页可能正在被 `fork()` → COW（需要检测写保护）
3. 多个 CPU 同时 GUP 需要并发安全（folio refcount）
4. DMA/RDMA 需要长时间 pin，不能被 ` Buddy allocator` 回收

---

## 1. API 体系

```c
// 慢路径（会触发 page fault）
get_user_pages(start, nr_pages, gup_flags, pages)
  → 当前进程 mm，mmap_lock 由函数内部获取/释放

get_user_pages_unlocked(start, nr_pages, gup_flags, pages)
  → 调用者持有 mmap_lock，函数不自动管理锁

get_user_pages_remote(mm, start, nr_pages, gup_flags, pages, locked)
  → 可操作其他进程的 mm，支持 FOLL_REMOTE

// 快路径（不触发 fault，依赖页已在内存）
get_user_pages_fast_only(start, nr_pages, gup_flags, pages)
  → 必须 FOLL_GET | FOLL_FAST_ONLY
  → 失败直接返回 0，不回退到慢路径

get_user_pages_fast(start, nr_pages, gup_flags, pages)
  → 失败会回退到 __get_user_pages
```

---

## 2. FOLL_* 标志详解

```c
// include/linux/mm_types.h:1862
enum {
    FOLL_WRITE       = 1 << 0,   // 要求 PTE 可写
    FOLL_GET         = 1 << 1,   // refcount++，用 put_page() 释放
    FOLL_DUMP        = 1 << 2,   // 零页/文件映射错误返回，不是 anon error
    FOLL_FORCE      = 1 << 3,   // 强制读取（绕过部分 permission check）
    FOLL_TOUCH       = 1 << 4,   // 访问时标记 PTE young（更新 accessed_bit）
    FOLL_MLOCK       = 1 << 5,   // mlock 页到内存
    FOLL_PIN        = 1 << 9,   // pin 追踪，用 unpin_user_page() 释放
    FOLL_FAST_ONLY  = 1 << 10,  // 快路径失败不回退
    FOLL_REMOTE     = 1 << 11,  // 远程 mm（非当前进程）
    FOLL_UNLOCKABLE = 1 << 12,  // 可以释放 mmap_lock（FAULT_FLAG_ALLOW_RETRY）
    FOLL_INTERRUPTIBLE = 1 << 13, // fault 可被非致命信号中断
    FOLL_LONGTERM   = 1 << 14,  // 长期 pin（用于 RDMA）
    FOLL_PCI_P2DMA  = 1 << 15,  // PCI peer-to-peer DMA
    // ...
};
```

**FOLL_GET vs FOLL_PIN 的根本区别**：

```
FOLL_GET：
  - folio_ref_count(folio)++
  - 释放：put_page() → folio_put()
  - 适用于：临时访问（iovec 操作等）
  - 问题：refcount++ 后页可能在任何时候被回收（如果 refcount 归零）

FOLL_PIN：
  - folio->_pincount（独立的 atomic_t）+= refs
  - node_stat NR_FOLL_PIN_ACQUIRED += refs
  - 释放：unpin_user_page() → folio_put_pincount()
  - 适用于：DMA/RDMA 等长时间 pin 场景
  - Buddy allocator 看到 pincount > 0 不会回收该页
```

---

## 3. __get_user_pages 完整循环

```c
// mm/gup.c:1354
static long __get_user_pages(struct mm_struct *mm,
        unsigned long start, unsigned long nr_pages,
        unsigned int gup_flags, struct page **pages,
        int *locked)
{
    long ret = 0, i = 0;
    struct vm_area_struct *vma = NULL;
    unsigned long page_mask = 0;

    if (!nr_pages)
        return 0;

    start = untagged_addr_remote(mm, start);  // 忽略 top bits（tagged address）

    // FOLL_GET 和 FOLL_PIN 互斥
    VM_WARN_ON_ONCE((gup_flags & (FOLL_PIN | FOLL_GET)) == (FOLL_PIN | FOLL_GET));

    do {
        struct page *page;
        unsigned int page_increm;

        // ============================================
        // 步骤 1：VMA 查找（跨 VMA 边界时重新查找）
        // ============================================
        if (!vma || start >= vma->vm_end) {
            // MADV_POPULATE 路径
            if (gup_flags & FOLL_MADV_POPULATE) {
                vma = vma_lookup(mm, start);
                if (!vma) { ret = -ENOMEM; goto out; }
                if (check_vma_flags(vma, gup_flags)) { ret = -EINVAL; goto out; }
                goto retry;  // 不释放锁
            }

            // 普通查找
            vma = gup_vma_lookup(mm, start);
            if (!vma && in_gate_area(mm, start)) {
                // 内核映射区域（vsyscall/exec-map）
                ret = get_gate_page(mm, start & PAGE_MASK, gup_flags, &vma,
                            pages ? &page : NULL);
                if (ret) goto out;
                page_mask = 0;
                goto next_page;
            }

            if (!vma) {
                ret = -EFAULT;  // 地址不在任何 VMA 内
                goto out;
            }

            ret = check_vma_flags(vma, gup_flags);
            if (ret) goto out;
        }

retry:
        // ============================================
        // 步骤 2：信号检测 + 调度让步
        // ============================================
        if (fatal_signal_pending(current)) {
            ret = -EINTR;
            goto out;
        }
        cond_resched();  // 允许调度，防止长时占用 CPU

        // ============================================
        // 步骤 3：follow_page_mask — 页表遍历
        // ============================================
        page = follow_page_mask(vma, start, gup_flags, &page_mask);
        if (!page || PTR_ERR(page) == -EMLINK) {
            // 页不在内存，或 huge page 链接数超限
            ret = faultin_page(vma, start, gup_flags,
                       PTR_ERR(page) == -EMLINK, locked);
            switch (ret) {
            case 0:         // fault 成功，重试 follow
                goto retry;
            case -EBUSY:    // mmap_lock 已释放，需要重新获取
            case -EAGAIN:   // 同上
                vma = NULL; // 强制重新查找 VMA
                goto retry;
            case -ENOENT:   // 孔洞/对齐问题
                goto next_page;
            default:
                goto out;
            }
        }

        // ============================================
        // 步骤 4：页在内存，增加引用计数
        // ============================================
        if (PTR_ERR(page) == -EEXIST)
            goto next_page;  // 不增加 ref，直接跳过

        if (IS_ERR(page)) {
            ret = PTR_ERR(page);
            goto out;
        }

        // 成功获取页，增加引用
        ret = get_user_pages_folio(mm, folio, gup_flags, pages ? &pages[i] : NULL);
        if (ret < 0) {
            // refcount 增加失败（通常是 ENOMEM）
            goto out;
        }
        // ret = 获取的 folio 数量（通常是 1，THP 时 > 1）
        i += ret;
        page_mask = ret - 1;  // page_mask 记录跨越的页数

next_page:
        // 前进到下一页
        if (page_mask)
            page_increm = 1 + page_mask;  // THP 跨越多页
        else
            page_increm = 1;

        start += page_increm * PAGE_SIZE;
        nr_pages -= page_increm;

    } while (nr_pages > 0);

out:
    // 处理过程中可能需要回退某些页
    if (nr_pages > 0)
        nr_pages = 0;
    if (ret < 0 && pages && i > 0)
        gup_failed(pages, i, gup_flags);  // 释放已成功的页

    return ret < 0 ? ret : i;  // 返回成功获取的页数
}
```

---

## 4. follow_page_mask — PTE 遍历引擎

```c
// mm/gup.c:1007 — follow_page_mask
static struct page *follow_page_mask(struct vm_area_struct *vma,
              unsigned long address, unsigned int flags,
              unsigned long *page_mask)
{
    pgd_t *pgd;
    struct mm_struct *mm = vma->vm_mm;
    struct page *page;

    vma_pgtable_walk_begin(vma);  // 内存屏障 + pgtable.h 兼容

    // ========== 页表遍历：pgd → pud → pmd → pte ==========
    pgd = pgd_offset(mm, address);
    if (!pgd_present(*pgd)) goto out_no_page;

    pud = pud_offset(pgd, address);
    if (!pud_present(*pud)) goto out_no_page;

    pmd = pmd_offset(pud, address);

    // ========== PMD 级大页处理（THP / huge page）==========
    if (pmd_huge(*pmd) && gup_flags & (FOLL_GET | FOLL_PIN)) {
        // THP（Transparent Huge Page）或 huge page
        page = gup_huge_pmd(pmd, flags, page_mask);
        // gup_huge_pmd 返回整个 THP 对应的 page，
        // page_mask 记录跨越的 PAGE_SIZE 页数
        goto out;
    }

    // ========== PTE 遍历 ==========
    if (pmd_none(*pmd)) goto out_no_page;

    pte = pte_offset_map(pmd, address);

    // ========== 权限检查 ==========
    if (!pte_present(*pte)) {
        // 页不在内存（swap entry / none pte）
        page = NULL;
        goto unmap;
    }

    // FOLL_WRITE 检查
    if ((flags & FOLL_WRITE) && !pte_write(*pte))
        goto unmap;

    // FOLL_GET 但页不可读
    if ((flags & FOLL_GET) && !pte_read(*pte))
        goto unmap;

    // FOLL_TOUCH：标记 accessed
    if (flags & FOLL_TOUCH) {
        if (!(flags & FOLL_WRITE))
            ptep_set_access_flags(vma, address, pte, pte_val(*pte) | PTE_AFD, flags & FOLL_WRITE);
        else
            pte_mkyong(*pte);  // 标记 young
    }

    // ========== special page 检查 ==========
    if (pte_special(*pte))
        goto unmap;  // 跳转到 slow GUP

    // ========== 获取 struct page* ==========
    page = pte_page(*pte);

    // ========== huge page page_mask 计算 ==========
    if (PageHuge(page)) {
        // compound_nr_pages = huge_page_size(page) / PAGE_SIZE
        *page_mask = compound_nr_pages(page) - 1;
    } else if (PageTransHuge(page)) {
        // THP，但 PTE 不是 huge（已经被拆开）
        *page_mask = (1 << compound_order(page)) - 1;
    }

unmap:
    pte_unmap(pte);
out:
    vma_pgtable_walk_end(vma);
    return page;
out_no_page:
    page = NULL;
    goto out;
}
```

**返回值语义**：
```
返回 struct page*        → 成功（页在内存）
返回 NULL              → 页不在内存，需要 faultin
返回 ERR_PTR(-EMLINK)  → huge page 链接数超限
返回 ERR_PTR(-EEXIST)  → folio 正在拆分，跳过
```

---

## 5. faultin_page — Page Fault 处理

```c
// mm/gup.c:1087 — faultin_page
static int faultin_page(struct vm_area_struct *vma,
        unsigned long address, unsigned int flags, bool unshare,
        int *locked)
{
    unsigned int fault_flags = 0;
    vm_fault_t ret;

    // FOLL_NOFAULT：只检查，不触发 fault（用于 gup 调试）
    if (flags & FOLL_NOFAULT)
        return -EFAULT;

    // ========== 构建 fault_flags ==========
    if (flags & FOLL_WRITE)
        fault_flags |= FAULT_FLAG_WRITE;
    if (flags & FOLL_REMOTE)
        fault_flags |= FAULT_FLAG_REMOTE;
    if (flags & FOLL_UNLOCKABLE) {
        fault_flags |= FAULT_FLAG_ALLOW_RETRY | FAULT_FLAG_KILLABLE;
        if (flags & FOLL_INTERRUPTIBLE)
            fault_flags |= FAULT_FLAG_INTERRUPTIBLE;
    }
    if (flags & FOLL_MLOCK)
        fault_flags |= FAULT_FLAG_MLOCK;
    if (flags & FOLL_POPULATE)
        fault_flags |= FAULT_FLAG_POPULATE;

    // ========== 调用 handle_mm_fault ==========
    ret = handle_mm_fault(vma, address, fault_flags);

    // ========== 处理返回值 ==========
    if (ret & VM_FAULT_COMPLETED) {
        // 页已成功分配并映射
        // locked 仍由 handle_mm_fault 管理
        return 0;
    }

    if (ret & VM_FAULT_RETRY) {
        // mmap_lock 已释放（FAULT_FLAG_ALLOW_RETRY）
        // 必须重新获取锁才能继续
        *locked = 0;  // 通知调用者锁已释放
        return -EBUSY;
    }

    if (ret & VM_FAULT_OOM)
        return -ENOMEM;

    if (ret & VM_FAULT_SIGSEGV)
        return -EFAULT;

    return 0;
}
```

---

## 6. handle_mm_fault → __handle_mm_fault → do_fault

```c
// mm/memory.c:6683 — handle_mm_fault（入口）
vm_fault_t handle_mm_fault(struct vm_area_struct *vma, unsigned long address,
               unsigned int flags, struct pt_regs *regs)
{
    struct mm_struct *mm = vma->vm_mm;
    vm_fault_t ret;

    __set_current_state(TASK_RUNNING);

    if (flags & FAULT_FLAG_VMA_LOCK) {
        // 使用 VMA lock（更细粒度，RT 下用）
        vma_init_lock(vma);
        ret = __handle_mm_fault(vma, address, flags);
    } else {
        // 使用 mmap_lock
        ret = __handle_mm_fault(vma, address, flags);
    }

    return ret;
}

// mm/memory.c:6449 — __handle_mm_fault（核心）
static vm_fault_t __handle_mm_fault(struct vm_area_struct *vma,
        unsigned long address, unsigned int flags)
{
    struct vm_fault vmf = {
        .vma = vma,
        .address = address & PAGE_MASK,  // 页对齐
        .real_address = address,
        .flags = flags,
        .pgoff = linear_page_index(vma, address),
        .orig_pte = __pte(0),  // 填充
    };

    // pgd → pud → pmd → pte 分配（按需分配）
    pgd = pgd_offset(mm, address);
    pud = pud_alloc(mm, pgd, address);
    if (!pud) return VM_FAULT_OOM;

    pmd = pmd_alloc(mm, pud, address);
    if (!pmd) return VM_FAULT_OOM;

    // PTE 不存在？分配并填充
    if (pmd_none(*pmd)) {
        ret = do_fault(&vmf);
        goto out;
    }

    // PTE 存在但 swap？
    if (pmd_present(*pmd)) {
        if (pmd_trans_huge(*pmd)) {
            // THP 页
            if (flags & FAULT_FLAG_WRITE) {
                // COW：THP 拆分
                ret = do_huge_pmd_anonymous_page(&vmf);
            } else {
                // 只读访问
                ret = do_huge_pmd_wp_page(&vmf);
            }
            goto out;
        }
        goto retry;
    }

    // 页表项不在内存（swap）
    if (pmd_none(*pmd)) {
        ret = do_fault(&vmf);
    } else {
        // COW 或文件映射
        if (flags & FAULT_FLAG_WRITE) {
            ret = do_cow_fault(&vmf);
        } else {
            ret = do_fault(&vmf);
        }
    }

out:
    return ret;
}
```

### 6.1 do_fault 子路径

```c
// mm/memory.c:5997 — do_fault（分发）
static vm_fault_t do_fault(struct vm_fault *vmf)
{
    // 判断 fault 类型
    if (!vmf->vma->vm_ops->fault) {
        // 无 fault handler → anon 或 swap
        if (!vmf->vma->vm_file)
            return do_anonymous_page(vmf);
        return do_read_fault(vmf);
    }

    if (vmf->flags & FAULT_FLAG_WRITE)
        return do_cow_fault(vmf);  // COW

    if (vmf->flags & FAULT_FLAG_MKWRITE) {
        // 写时复制到 COW 页
        return do_cow_fault(vmf);
    }

    return do_read_fault(vmf);  // 只读访问文件
}

// mm/memory.c:5873 — do_read_fault（文件映射，只读）
static vm_fault_t do_read_fault(struct vm_fault *vmf)
{
    // filemap_fault → page_cache_ra() → 预读
    ret = vma->vm_ops->fault(vmf);  // 调用文件系统 fault handler
    if (ret == VM_FAULT_RETRY) goto retry;
    // ret = VM_FAULT_LOCKED（已给页加锁）
}

// mm/memory.c:5905 — do_cow_fault（写时复制）
static vm_fault_t do_cow_fault(struct vm_fault *vmf)
{
    // 分配新页
    new_page = alloc_pages(mmap_gfp_mask(vma), 0);

    // 复制内容
    copy_user_highpage(new_page, old_page);

    // 设置 PTE
    set_pte_at(vma->vm_mm, address, vmf->pte, mk_pte(new_page, vma->vm_page_prot));
    pte_mkwrite(pte_mkdirty(*vmf->pte));
}

// mm/memory.c:5947 — do_shared_fault（写文件映射，需要 mark dirty）
static vm_fault_t do_shared_fault(struct vm_fault *vmf)
{
    ret = do_read_fault(vmf);        // 先分配页
    if (ret != VM_FAULT_LOCKED) return ret;
    // 文件系统：mark_page_accessed + set_page_dirty
    // ext4: ext4_da_update_reserve_space()
    // xfs: xfs_page_cache_write_setuid()
}
```

---

## 7. FOLL_PIN 追踪机制 — folio + pincount

### 7.1 folio 的 refcount 体系

```c
// folio 有两套独立的引用计数：

// 1. refcount_t _refcount（通用引用计数）
folio_ref_count(folio)         // 普通引用
folio_ref_add(folio, n)       // 增加引用
folio_ref_put(folio, n)       // 减少引用，归零时释放到 buddy

// 2. atomic_t _pincount（FOLL_PIN 专用 pin 计数）
folio_pincount(folio)          // 获取 pincount
folio_has_pincount(folio)     // 是否有 pincount
folio_put_pincount(folio, n)  // 减少 pincount

// 页回收条件：
//   refcount == 0 && pincount == 0 → 页可回收
//   pincount > 0 → 即使 refcount == 0，页也不能回收
```

### 7.2 try_get_folio — folio 获取

```c
// mm/gup.c:74 — try_get_folio
static inline struct folio *try_get_folio(struct page *page, int refs)
{
    struct folio *folio;

retry:
    folio = page_folio(page);  // page → folio（忽略 compound 页）

    // 稳定引用检查：folio 在获取 ref 期间不能被拆分
    if (WARN_ON_ONCE(folio_ref_count(folio) < 0))
        return NULL;
    if (unlikely(!folio_ref_try_add(folio, refs)))  // 原子增加
        return NULL;

    // 重新检查：folio_ref_try_add 成功后，folio 可能已被拆分
    if (unlikely(page_folio(page) != folio)) {
        // folio 被拆分，撤销操作
        folio_put_refs(folio, refs);
        goto retry;
    }

    return folio;
}
```

### 7.3 gup_put_folio — folio 释放

```c
// mm/gup.c:102 — gup_put_folio
static void gup_put_folio(struct folio *folio, int refs, unsigned int flags)
{
    if (flags & FOLL_PIN) {
        if (is_zero_folio(folio))
            return;  // 零页不计数

        // 记录到 VM node stat
        node_stat_mod_folio(folio, NR_FOLL_PIN_RELEASED, refs);

        // 减少 pincount
        if (folio_has_pincount(folio))
            atomic_sub(refs, &folio->_pincount);
        else
            // folio 没有 pincount 字段，回退到 refcount
            folio_ref_sub_and_test(folio, refs);
    } else if (flags & FOLL_GET) {
        folio_put(folio);  // 普通释放
    }
}
```

### 7.4 NR_FOLL_PIN_ACQUIRED / NR_FOLL_PIN_RELEASED

```c
// 这两个是 vm_event 计数，用于监控 GUP 行为
// 通过 /proc/vmstat 或 perf 可见

// 获取时：
node_stat_mod_folio(folio, NR_FOLL_PIN_ACQUIRED, refs);
// 释放时：
node_stat_mod_folio(folio, NR_FOLL_PIN_RELEASED, refs);

// 用途：
//   - 检测 GUP 泄漏（pin 未释放）
//   - 监控 DMA pin 使用量
//   - 调试页回收问题（pincount > 0 但页被回收）
```

---

## 8. get_user_pages_fast_only — 架构相关快路径

### 8.1 gup_fast_pgd_range — 递归页表遍历

```c
// mm/gup.c:3092 — gup_fast_pgd_range
static void gup_fast_pgd_range(unsigned long addr, unsigned long end,
        unsigned int flags, struct page **pages, int *nr)
{
    pgd_t *pgdp;
    pgdp = pgd_offset(current->mm, addr);
    do {
        pgd_t pgd = pgdp_get(pgdp);  // 原子读取 pgd

        if (!pgd_access_permitted(pgd, flags & FOLL_WRITE))
            break;

        // huge page 处理（p4d/pud）
        if (pgd_huge(pgd)) {
            // 尝试获取 huge page
            if (!gup_huge_pgd(pgd, pgdp, addr, end, flags, pages, nr))
                break;  // 失败，需要回退
            continue;
        }

        // 继续下一级
        if (!gup_fast_p4d_range(pgd, addr, next, flags, pages, nr))
            break;

    } while (pgdp++, addr = next, addr != end);
}
```

### 8.2 gup_fast_pte_range — PTE 级快取

```c
// mm/gup.c:2829 — gup_fast_pte_range（x86_64 典型实现）
static int gup_fast_pte_range(pmd_t pmd, pmd_t *pmdp, unsigned long addr,
        unsigned long end, unsigned int flags, struct page **pages, int *nr)
{
    pte_t *ptep, *ptem;
    int ret = 0;

    ptem = ptep = pte_offset_map(&pmd, addr);
    if (!ptep) return 0;

    do {
        pte_t pte = ptep_get(ptep);  // 原子读取

        // ========== 权限检查 ==========
        if (pte_protnone(pte))
            goto pte_unmap;  // PROT_NONE → 回退到慢路径
        if (!pte_access_permitted(pte, flags & FOLL_WRITE))
            goto pte_unmap;
        if (pte_special(pte))
            goto pte_unmap;  // special page → 回退

        // ========== 获取 page ==========
        page = pte_page(pte);
        if (WARN_ON_ONCE(page_to_nid(page) != numa_node_id()))
            goto pte_unmap;  // NUMA 检查

        // ========== 增加 folio refcount ==========
        if (!try_get_page(page))  // folio_ref_try_add
            goto pte_unmap;

        // ========== 设置 page mask（THP）==========
        if (PageTransHuge(page) && PageHead(page)) {
            // THP
            refs = GUP_PIN_COUNTING_BIAS * compound_nr_pages(page);
            // ...
        }

        pages[*nr] = page;
        (*nr)++;

    } while (ptep++, addr += PAGE_SIZE, addr != end);

    ret = 1;
pte_unmap:
    pte_unmap(ptem);
    return ret;
}
```

### 8.3 write_protect_seq — fork() 检测

```c
// mm/gup.c:3165 — fork 期间 write_protect 检测
if (gup_flags & FOLL_PIN) {
    unsigned int seq;

    // raw_seqcount_begin 读取 sequence counter
    if (!raw_seqcount_try_begin(&current->mm->write_protect_seq, seq)) {
        // 获取失败（正在被写保护修改）
        gup_fast_unpin_user_pages(pages, nr_pinned);
        return 0;  // 回退到慢路径
    }

    // 检查 fork() 后是否有写保护
    if (read_seqcount_retry(&current->mm->write_protect_seq, seq)) {
        // fork() 发生，COW 页被写保护修改
        gup_fast_unpin_user_pages(pages, nr_pinned);
        return 0;
    }
}
```

**write_protect_seq 机制**：
```
fork() 时：copy_page_range()
  → __copy_process()
    → write_protect_seq_begin(mm)
    → 写保护所有 COW 页
    → write_protect_seq_end(mm)
  → 每次 write_protect_seq 改变，GUP-fast 检测到必须回退
```

---

## 9. 完整调用状态机

```
get_user_pages(addr, nr_pages, FOLL_GET | FOLL_WRITE, pages)
  │
  └─ __get_user_pages_locked(mm, addr, nr_pages, pages, &locked, flags)
        │
        └─ __get_user_pages(mm, addr, nr_pages, flags, pages, locked)
              │
              ├─ follow_page_mask(vma, addr, flags, &page_mask)
              │     │
              │     ├─ pgd→pud→pmd→pte 遍历
              │     ├─ pte_access_permitted() → 否 → NULL（需要 fault）
              │     ├─ pte_special() → 是 → NULL（需要 fault）
              │     └─ 成功 → try_get_page() → folio_ref_try_add()
              │           ├─ 成功 → 返回 struct page*
              │           └─ folio 被拆分 → goto retry
              │
              ├─ follow_page_mask 返回 NULL
              │     └─ faultin_page(vma, addr, flags)
              │           └─ handle_mm_fault(vma, addr, FAULT_FLAG_WRITE)
              │                 ├─ __handle_mm_fault()
              │                 │     ├─ pgd/pud/pmd_alloc()（按需分配）
              │                 │     ├─ do_fault() → do_read_fault() → filemap_fault()
              │                 │     │     └─ page_cache_lookup() / 分配新页
              │                 │     ├─ do_cow_fault() → alloc_pages() + copy_user_highpage()
              │                 │     └─ do_huge_pmd_anonymous_page()（THP）
              │                 │
              │                 ├─ VM_FAULT_RETRY → *locked=0, return -EBUSY
              │                 └─ VM_FAULT_COMPLETED → return 0
              │
              ├─ faultin 返回 -EBUSY
              │     └─ *locked = 0，vma = NULL，重新获取锁，goto retry
              │
              └─ retry：
                   ├─ 可能重新获取 mmap_lock
                   ├─ 重新查找 VMA
                   └─ 重新 follow_page_mask（这次页已在内存）
```

---

## 10. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| folio + refcount 双计数 | refcount 普通引用 / pincount DMA pin，各司其职 |
| `folio_ref_try_add` | 失败时自动重试，防止 folio 在增加期间被拆分 |
| `write_protect_seq` | fork() 时写保护检测，防止 GUP-fast 读取到临时的 COW 状态 |
| `cond_resched()` 在循环中 | GUP 可能跨越大量页，长时间占用 CPU |
| `vma_pgtable_walk_begin/end` | 遍历页表时需要内存屏障，防止 TOCTOU |
| FOLL_PIN 用 `node_stat` 追踪 | 通过 vmstat 可观测 pin 泄漏 |
| gup_fast 不获取 mmap_lock | 直接读页表，不需要锁（架构特定页表是 lockless 的）|
| `FAULT_FLAG_ALLOW_RETRY` | 允许 faultin 释放 mmap_lock，避免死锁（锁继承场景）|

---

## 11. 参考

| 文件 | 内容 |
|------|------|
| `mm/gup.c:1354` | `__get_user_pages` 完整主循环 |
| `mm/gup.c:1007` | `follow_page_mask` 页表遍历 |
| `mm/gup.c:1087` | `faultin_page` page fault 触发 |
| `mm/gup.c:74` | `try_get_folio` folio 获取 + folio 拆分重试 |
| `mm/gup.c:102` | `gup_put_folio` FOLL_PIN pincount 释放 |
| `mm/gup.c:2829` | `gup_fast_pte_range` 架构快路径 PTE 遍历 |
| `mm/gup.c:3092` | `gup_fast_pgd_range` 递归页表快取 |
| `mm/memory.c:6683` | `handle_mm_fault` 入口 |
| `mm/memory.c:6449` | `__handle_mm_fault` 页表分配 + do_fault 分发 |
| `mm/memory.c:5997` | `do_fault` 子路径分发 |
| `mm/memory.c:5873` | `do_read_fault` / `do_cow_fault` / `do_shared_fault` |
| `include/linux/mm_types.h:1862` | `FOLL_*` 标志枚举 |
