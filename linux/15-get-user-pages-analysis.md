# 15-get-user-pages — 用户页获取机制深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**get_user_pages（GUP）** 是 Linux 内核中将用户空间虚拟地址转换为 `struct page*` 的核心机制。它锁定用户空间的物理页面，使得这些页面在 I/O 操作期间不会被换出、迁移或回收。

GUP 在整个内核 I/O 路径中处于枢纽位置：

```
用户进程                        内核
   │                             │
   │ read(fd, buf, 8192)         │
   │                             │
   │          ──→ VFS 层         │
   │                  │          │
   │                  └── GUP ───┤← 核心：锁定用户页面
   │                             │
   │                  ┌── BIO ───┤
   │                  │          │ DMA 设备
   │          ←─ 完成 ─┘         │ 直接读写用户内存
```

GUP 在内核中有两条 API 路径：
1. `get_user_pages` + `put_page`：传统接口（`FOLL_GET`）
2. `pin_user_pages` + `unpin_user_page`：新型接口（`FOLL_PIN`）

**doom-lsp 确认**：`mm/gup.c` 包含 **157 个符号**，是内核 MM 子系统中最重要的源文件之一。关键函数包括 `follow_page_mask` @ L1007，`faultin_page` @ L1087，`__get_user_pages` @ L1301。

---

## 1. 核心概念——页面固定（page pinning）

GUP 的本质是**增加页面的引用计数**，防止页面被回收。有两种固定方式：

```c
// FOLL_GET 方式（传统）：
get_page(page);           // page_count 从 N → N+1
put_page(page);           // page_count 从 N+1 → N

// FOLL_PIN 方式（新型）：
// 使用专门的 pin 计数，与普通引用计数分离
try_grab_folio(page, 1, FOLL_PIN);   // 标记 pin
unpin_user_page(page);                // 释放 pin
```

**为什么需要 FOLL_PIN？**

传统的 `get_page` + `put_page` 存在竞态：页面回收代码无法区分"被偶然增加引用"和"被 GUP 固定"。`FOLL_PIN` 使用独立的 pin 计数（通过在 `page->_refcount` 中编码），页面回收代码可以明确检测到被固定的页面，推迟回收。

---

## 2. 🔥 完整调用链——__get_user_pages

```c
// mm/gup.c:1301 — doom-lsp 确认
static long __get_user_pages(struct mm_struct *mm,
                              unsigned long start, unsigned long nr_pages,
                              unsigned int gup_flags, struct page **pages,
                              struct vm_area_struct **vmas,
                              int *locked)
{
    long ret = 0, i = 0;
    struct vm_area_struct *vma = NULL;

    // 锁定 mmap_lock（如果尚未锁定）
    if (!locked)
        mmap_read_lock(mm);

    for (i = 0; i < nr_pages; i++) {
        unsigned long address = start + i * PAGE_SIZE;
        struct page *page;

        // ——— 步骤 1：查找 VMA ———
        vma = find_vma(mm, address);
        if (!vma || vma->vm_start > address) {
            ret = -EFAULT;
            break;
        }

        // ——— 步骤 2：检查权限 ———
        if (!(vma->vm_flags & VM_READ) &&
            !((gup_flags & FOLL_FORCE) && (vma->vm_flags & VM_MAYREAD)))
            return -EFAULT;

        // ——— 步骤 3：尝试快速路径 ———
        // follow_page_mask 直接遍历页表找到页面
        page = follow_page_mask(vma, address, gup_flags, &page_mask);
        if (page && !IS_ERR(page)) {
            // 快速路径成功！固定页面
            if (try_grab_folio(page_folio(page), 1, gup_flags))
                break;
            pages[i] = page;
            continue;
        }

        // ——— 步骤 4：慢速路径（触发缺页） ———
        ret = faultin_page(vma, address, gup_flags, &locked);
        // faultin_page 内部调用 handle_mm_fault
        // → 分配或换入页面
        // → 建立页表映射
        // → 从页表再次获取

        if (ret)
            break;
    }

    if (!locked)
        mmap_read_unlock(mm);

    return i ? i : ret;
}
```

---

## 3. 🔥 页表遍历——follow_page_mask

```c
// mm/gup.c:1007 — doom-lsp 确认
static struct page *follow_page_mask(struct vm_area_struct *vma,
                                      unsigned long address,
                                      unsigned int flags,
                                      unsigned long *page_mask)
{
    pgd_t *pgd;
    struct mm_struct *mm = vma->vm_mm;

    vma_pgtable_walk_begin(vma);

    pgd = pgd_offset(mm, address);      // PGD 页全局目录

    if (pgd_none(*pgd) || pgd_bad(*pgd))
        page = no_page_table(vma, flags, address);
    else
        page = follow_p4d_mask(vma, address, pgd, flags, page_mask);
        // → follow_p4d_mask → follow_pud_mask → follow_pmd_mask
        // → 每层检查是否存在、是否为大页
        // → 最后到 PTE 层

    vma_pgtable_walk_end(vma);
    return page;
}
```

**页表遍历的完整链路**（x86-64，4 级页表）：

```
follow_page_mask(address)
  │
  ├─ pgd_offset(mm, address)      → PGD 基址 + 索引 (bits 39-47)
  │
  ├─ p4d_offset(pgd, address)     → P4D（x86-64 上等价于 PGD）
  │
  ├─ pud_offset(p4d, address)     → PUD 索引 (bits 30-38)
  │   ├─ pud_huge(pud) → follow_huge_pud  ← 1GB 大页
  │   └─ pud_none(pud) → no_page_table
  │
  ├─ pmd_offset(pud, address)     → PMD 索引 (bits 21-29)
  │   ├─ pmd_huge(pmd) → follow_huge_pmd  ← 2MB 大页
  │   ├─ pmd_none(pmd) → no_page_table
  │   └─ pmd_devmap(pmd) → follow_devmap_pmd ← 设备映射
  │
  └─ pte_offset_map(pmd, addr)    → PTE 索引 (bits 12-20)
      ├─ pte_present(pte)         → 页面在内存中
      │    ├─ pte_write(pte) || !(flags & FOLL_WRITE) → page = pte_page(pte)
      │    └─ 需要写但只读 → return NULL（触发 COW）
      ├─ pte_none(pte)            → 页面未映射 → return NULL（触发缺页）
      └─ pte_swp_uffd_wp(pte)    → userfaultfd 写保护
```

---

## 4. 🔥 缺页处理——faultin_page

当 `follow_page_mask` 返回 NULL（页面不在内存或页表不存在），GUP 触发缺页：

```c
// mm/gup.c:1087 — doom-lsp 确认
static int faultin_page(struct vm_area_struct *vma,
                         unsigned long address, unsigned int flags,
                         bool unshare, int *locked)
{
    unsigned int fault_flags = 0;
    vm_fault_t ret;

    // 转换 GUP flags 为缺页 flags
    if (flags & FOLL_WRITE)
        fault_flags |= FAULT_FLAG_WRITE;     // 写缺页
    if (flags & FOLL_REMOTE)
        fault_flags |= FAULT_FLAG_REMOTE;    // 远程访问
    if (flags & FOLL_UNSHARE)
        fault_flags |= FAULT_FLAG_UNSHARE;   // 强制取消共享
    if (flags & FOLL_INTERRUPTIBLE)
        fault_flags |= FAULT_FLAG_INTERRUPTIBLE; // 可中断

    // 调用核心缺页处理函数
    ret = handle_mm_fault(vma, address, fault_flags, NULL);

    if (ret & VM_FAULT_ERROR) {
        // 映射 DAX 或设备内存时重新检查
        if (ret & VM_FAULT_NEEDDSYNC) {
            // ...
        }
        return -EFAULT;
    }

    if (ret & VM_FAULT_MAJOR)
        current->min_flt--;  // 计为主缺页
    else
        current->maj_flt--;  // 计为次缺页

    // 缺页完成后，再次尝试 follow_page_mask（步骤 3）
    // __get_user_pages 的主循环会处理重试
    return 0;
}
```

**缺页处理内部**（`handle_mm_fault` → `__handle_mm_fault`）：

```
handle_mm_fault(vma, address, flags)
  │
  ├─ __handle_mm_fault(vma, address, flags)
  │    │
  │    ├─ pgd_offset / p4d_alloc / pud_alloc / pmd_alloc
  │    │   → 确保页表路径上的每级目录都存在
  │    │
  │    ├─ handle_pte_fault(vmf)
  │    │    │
  │    │    ├─ do_anonymous_page(vmf)        ← 匿名映射缺页
  │    │    │   └─ 分配一个零页面或 COW 页面
  │    │    │
  │    │    ├─ do_fault(vmf)                  ← 文件映射缺页
  │    │    │   ├─ do_read_fault → aops->read_folio
  │    │    │   ├─ do_cow_fault → 分配页 + 复制
  │    │    │   └─ do_shared_fault → aops->write_begin
  │    │    │
  │    │    ├─ do_swap_page(vmf)              ← 换入页面
  │    │    │   └─ swap_read_folio → 从交换分区读入
  │    │    │
  │    │    └─ do_numa_page(vmf)              ← NUMA 迁移
  │    │
  │    └─ 建立页表映射：
  │        pte_unmap_same(vmf) / set_pte_at(mm, address, vmf->pte, entry)
  │
  └─ return 0
```

---

## 5. 页面固定——try_grab_folio

```c
// mm/gup.c:140 — doom-lsp 确认
static int try_grab_folio(struct folio *folio, int refs, unsigned int flags)
{
    if (flags & FOLL_PIN) {
        // FOLL_PIN：使用 pin 计数
        folio_ref_add(folio, refs * (GUP_PIN_COUNTING_BIAS));
        // GUP_PIN_COUNTING_BIAS = 1024
        // 每个 pin = refs × 1024，与普通引用区分
        // 页面回收代码检查 refcount % 1024 判断是否被 pin
        node_page_state_mod_folio(folio, NR_FOLL_PIN_ACQUIRED, refs);
    } else {
        // FOLL_GET：传统引用计数
        folio_get(folio);  // refcount++
    }
    return 0;
}
```

**为什么 GUP_PIN_COUNTING_BIAS = 1024？**

因为 `page->_refcount` 的 overflow 风险。1024 是一个安全的安全倍数——一个页面几乎不可能被 1024 个以上的用户同时 pin 住。回收代码检测 `refcount & (GUP_PIN_COUNTING_BIAS - 1)`：如果非零，表示有活跃的 pin。

---

## 6. 🔥 完整 I/O 路径——O_DIRECT 读

```
用户调用 read(fd, buf, 4096, O_DIRECT)
  │
  └─ vfs_read() → __vfs_read() → call_read_iter()
       │
       └─ blkdev_read_iter() → generic_file_read_iter()
            │
            ├─ iov_iter_get_pages(iter, pages, PAGE_SIZE, &start)
            │    │                     @ lib/iov_iter.c
            │    └─ pin_user_pages(addr, nr, FOLL_WRITE, pages)
            │         │
            │         ├─ mmap_read_lock(mm)
            │         │
            │         ├─ __get_user_pages(mm, addr, nr, gup_flags, pages)
            │         │    │
            │         │    ├─ 循环每页：
            │         │    │   ├─ follow_page_mask ← 页表遍历
            │         │    │   │   ├─ 命中 → try_grab_folio(FOLL_PIN) → 成功
            │         │    │   │   └─ 未命中 → faultin_page → handle_mm_fault
            │         │    │   │       ├─ do_anonymous_page → 分配零页
            │         │    │   │       │   → try_grab_folio(FOLL_PIN)
            │         │    │   │       │   → pages[i] = page
            │         │    │   │       └─ do_fault → aops->read_folio
            │         │    │   │           → try_grab_folio(FOLL_PIN)
            │         │    │   │           → pages[i] = page
            │         │    │   └─ i++ → 继续下一页
            │         │    │
            │         │    └─ return npages
            │         │
            │         └─ mmap_read_unlock(mm)
            │
            ├─ [现在 pages[] 指向用户空间页面]
            │   BIO 被设置为直接从这些页面读数据
            │
            ├─ submit_bio(bio)
            │   [硬件 DMA 将数据直接写入 pages[]]
            │
            └─ BIO 完成回调：
                 └─ iov_iter_advance(iter, bytes)
                 └─ unpin_user_pages_dirty_lock(pages, npages, true)
                      │
                      ├─ for each page:
                      │   ├─ if (make_dirty):
                      │   │      folio_lock(folio)
                      │   │      folio_mark_dirty(folio)
                      │   │      folio_unlock(folio)
                      │   └─ gup_put_folio(folio, 1, FOLL_PIN)
                      │        = folio_ref_sub(folio, GUP_PIN_COUNTING_BIAS)
                      │        = 释放 pin 计数
                      │
                      └─ 页面可被回收
```

---

## 7. GUP flags 全面

| Flag | 值 | 含义 | 使用场景 |
|------|-----|------|---------|
| `FOLL_WRITE` | 0x01 | 需要写权限 | O_DIRECT 写 |
| `FOLL_TOUCH` | 0x02 | 更新 accessed/dirty 位 | /proc/pid/mem |
| `FOLL_GET` | 0x04 | 获取页面引用 | 传统 GUP |
| `FOLL_DUMP` | 0x08 | 允许读取无权限页 | 核心转储 |
| `FOLL_FORCE` | 0x10 | 强制（忽略权限）| /proc/pid/mem 写 |
| `FOLL_NOWAIT` | 0x20 | 非阻塞，不触发缺页 | 快速路径 |
| `FOLL_PIN` | 0x40 | 使用 pin 计数 | pin_user_pages |
| `FOLL_LONGTERM` | 0x100 | 长期固定 > 2秒 | RDMA, vfio |
| `FOLL_SPLIT_PMD` | 0x200 | 分裂 THP | 大页处理 |
| `FOLL_PCI_P2PDMA` | 0x400 | 允许 P2P DMA | NVMe 等 |
| `FOLL_INTERRUPTIBLE` | 0x800 | 可被信号中断 | 长时间等待 |
| `FOLL_UNSHARE` | 0x1000 | 强制取消共享(COW) | 安全 |
| `FOLL_REMOTE` | 0x2000 | 跨进程 GUP | 进程跟踪 |
| `FOLL_NOFAULT` | 0x4000 | 不触发缺页 | 快速检查 |

---

## 8. FOLL_LONGTERM——长期固定

当 `FOLL_LONGTERM` 被设置（通常由 RDMA 或 vfio 使用）：

```c
// mm/gup.c —— __gup_longterm_locked
if (flags & FOLL_LONGTERM) {
    // 将页面迁移到可移动区域
    // 不允许从 ZONE_MOVABLE 固定（因为会阻止内存规整）
    ret = check_and_migrate_movable_pages(pages, nr_pages);
}
```

**为什么需要迁移？** 被长期固定的页面不能迁移。如果这些页面在 ZONE_MOVABLE 中，会阻止内存规整（memory compaction），导致系统无法分配连续的大页。因此 GUP 在固定前将页面从 ZONE_MOVABLE 迁移到 ZONE_NORMAL。

---

## 9. 释放路径完整对比

| 固定方式 | 固定函数 | 释放函数 | 脏页处理 |
|---------|---------|---------|---------|
| FOLL_GET | `get_user_pages()` | `put_page()` | 手动 set_page_dirty |
| FOLL_PIN | `pin_user_pages()` | `unpin_user_page()` | `unpin_user_pages_dirty_lock()` |

---

## 10. 源码文件索引

| 文件 | 关键函数 | 行号 |
|------|---------|------|
| `mm/gup.c` | `try_grab_folio` | 140 |
| `mm/gup.c` | `unpin_user_page` | 185 |
| `mm/gup.c` | `unpin_user_pages_dirty_lock` | 284 |
| `mm/gup.c` | `follow_page_mask` | 1007 |
| `mm/gup.c` | `faultin_page` | 1087 |
| `mm/gup.c` | `__get_user_pages` | 1301 |
| `mm/memory.c` | `handle_mm_fault` | — |

---

## 11. 关联文章

- **16-vm_area_struct**：GUP 的第一步是查找 VMA
- **17-page_allocator**：缺页触发的物理页分配
- **77-vfio-iommu**：vfio 使用 GUP 固定用户内存
- **88-mmap**：mmap MAP_SHARED 与 GUP 的交互

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
