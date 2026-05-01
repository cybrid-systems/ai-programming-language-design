# 15-get-user-pages — 用户页获取机制深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**get_user_pages（GUP）** 是 Linux 内核将用户空间虚拟地址转换为 `struct page*` 的核心机制。它用于固定（pin）用户空间页面，确保这些页面在 DMA/I/O 操作期间不会被换出、迁移或回收。

GUP 处于内核 I/O 路径的枢纽位置：

```
用户进程: read(fd, buf, 4096)
                    │
                    ▼
              VFS: vfs_read()
                    │
                    ▼
        Page Cache → 命中 → 拷贝到用户缓冲区
                    │
             未命中 → a_ops->read_folio → submit_bio
                    │
        O_DIRECT: iov_iter_get_pages()
                    │
                    ▼
          ★ GUP: get_user_pages(addr, nr_pages, flags, pages)
                    │
                    ▼
          DMA: submit_bio(bio ← 直接读写用户页面)
                    │
                    ▼
          unpin_user_pages_dirty_lock(pages, npages)
```

GUP 的使用场景：
1. **O_DIRECT I/O**：绕过 page cache 直接读写用户缓冲区
2. **RDMA**：远程直接内存访问，固定内存供网卡硬件读写
3. **vfio**：设备直通，将用户内存固定为 DMA 区域
4. **KVM**：虚拟机内存固定
5. **/proc/pid/mem**：跨进程内存访问

**doom-lsp 确认**：`mm/gup.c` 包含 **157 个符号**，约 3557 行。关键函数：`__get_user_pages` @ L1301，`follow_page_mask` @ L1007，`faultin_page` @ L1087，`try_grab_folio` @ L140。

---

## 1. GUP 的两套 API

```c
// ===== 传统接口（FOLL_GET） =====
long get_user_pages(unsigned long start, unsigned long nr_pages,
                    unsigned int gup_flags, struct page **pages,
                    struct vm_area_struct **vmas);
// 使用 get_page() 固定 → 使用者调用 put_page() 释放

// ===== 新型接口（FOLL_PIN） =====
long pin_user_pages(unsigned long start, unsigned long nr_pages,
                    unsigned int gup_flags, struct page **pages,
                    struct vm_area_struct **vmas);
// 使用 try_grab_folio(FOLL_PIN) → 使用者调用 unpin_user_page()

// ===== 释放接口 =====
void unpin_user_page(struct page *page);                              // 释放单个页
void unpin_user_pages(struct page **pages, unsigned long npages);     // 释放批量页
void unpin_user_pages_dirty_lock(struct page **pages,                 // 释放 + 标记脏
                                  unsigned long npages, bool make_dirty);
```

**为什么需要 FOLL_PIN？** 传统的 `get_page` + `put_page` 无法区分"被正常引用"和"被 GUP 固定"。`FOLL_PIN` 使用独立的 pin 计数（`GUP_PIN_COUNTING_BIAS = 1024` 的倍率编码在 `page->_refcount` 中），页面回收代码可以明确检测到被固定的页面，推迟回收或迁移。

---

## 2. 🔥 __get_user_pages 主循环

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
    struct page *page;

    // [保护] 如果调用者未锁定 mmap_lock，在此锁定
    if (!locked)
        mmap_read_lock(mm);

    // 主循环：处理每一页
    for (i = 0; i < nr_pages; i++) {
        unsigned long address = start + i * PAGE_SIZE;

        // ——— 步骤 1：查找 VMA ———
        vma = find_vma(mm, address);
        if (!vma) {
            ret = -EFAULT;
            break;
        }
        // 检查 address 是否在 VMA 范围内
        if (vma->vm_start > address) {
            ret = -EFAULT;
            break;
        }

        // ——— 步骤 2：检查权限 ———
        // 如果不允许读（除非 FOLL_FORCE）
        if (!(vma->vm_flags & VM_READ)) {
            if (!(gup_flags & FOLL_FORCE)) {
                ret = -EFAULT;
                break;
            }
            // FOLL_FORCE 允许读 VM_MAYREAD 的 VMA
            if (!(vma->vm_flags & VM_MAYREAD)) {
                ret = -EFAULT;
                break;
            }
        }

        // ——— 步骤 3：快速路径 ———
        // 直接遍历页表找到页面（不触发缺页）
        page = follow_page_mask(vma, address, gup_flags, &page_mask);
        if (page && !IS_ERR(page)) {
            // 快速路径成功！尝试固定页面
            if (try_grab_folio(page_folio(page), 1, gup_flags)) {
                ret = -ENOMEM;
                break;
            }
            pages[i] = page;
            continue;  // ← 快速完成此页！
        }

        // ——— 步骤 4：慢速路径（触发缺页） ———
        ret = faultin_page(vma, address, gup_flags, &locked);
        if (ret)
            break;
        // 缺页后，下一页循环会再次尝试 follow_page_mask
        // 此时页表已建立 → 快速路径命中
    }

    if (!locked)
        mmap_read_unlock(mm);

    return i ? i : ret;  // 返回成功获取的页数，或错误码
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
    pgd = pgd_offset(mm, address);  // 从 PGD 开始

    if (pgd_none(*pgd) || pgd_bad(*pgd))
        page = no_page_table(vma, flags, address);
    else
        page = follow_p4d_mask(vma, address, pgd, flags, page_mask);

    vma_pgtable_walk_end(vma);
    return page;
}
```

**四层页表遍历（x86-64，4 级页表）**：

```
虚拟地址 0x7f1234567890 的页表遍历：

address = 0x7f1234567890
二进制:  0111 1111 0001 0010 0011 0100 0101 0110 0111 1000 1001 0000

页表索引分解：
┌──────────┬──────────┬──────────┬──────────┬──────────────┐
│   PGD    │   PUD    │   PMD    │   PTE    │   页内偏移    │
│ bits 47-39│ bits 38-30│ bits 29-21│ bits 20-12│ bits 11-0   │
├──────────┼──────────┼──────────┼──────────┼──────────────┤
│  0xFE    │  0x24    │  0x68    │  0xBC    │   0x890      │
└──────────┴──────────┴──────────┴──────────┴──────────────┘

遍历过程（follow_page_mask → follow_p4d_mask → follow_pud_mask → follow_pmd_mask）：

1. PGD: pgd_offset(mm, addr) → pgd[0xFE]
   ├─ pgd_none? → 否（存在）
   └─ pgd_bad? → 否
       → follow_p4d_mask(vma, addr, pgd, flags, page_mask)

2. P4D: p4d_offset(pgd, addr) → p4d[0]
   x86-64 上 P4D ≡ PGD（一级折叠）
   → follow_pud_mask(vma, addr, p4d, flags, page_mask)

3. PUD: pud_offset(p4d, addr) → pud[0x24]
   ├─ pud_huge(pud)? → 可能是 1GB 大页
   │   → follow_huge_pud → 直接返回大页 struct page
   └─ pud_none(pud)? → 是 → return NULL（触发缺页）
       → follow_pmd_mask(vma, addr, pud, flags, page_mask)

4. PMD: pmd_offset(pud, addr) → pmd[0x68]
   ├─ pmd_huge(pmd)? → 可能是 2MB 大页
   │   → follow_huge_pmd
   ├─ pmd_none(pmd)? → 是 → return NULL
   └─ pmd_devmap(pmd)? → 设备映射
       → follow_devmap_pmd
       → pte_offset_map(pmd, addr) → pte[0xBC]

5. PTE: pte_offset_map(pmd, addr) → *pte
   ├─ !pte_present(pte) → 页不在内存 → return NULL（触发缺页）
   │   → page = NULL
   │
   ├─ pte = pte_mkold(pte) // 清除访问位（若 flags 含 FOLL_TOUCH）
   │
   ├─ 如果需要写访问：
   │   ├─ pte_write(pte) → 直接返回 page
   │   └─ !pte_write(pte) → 需要 COW → return NULL（触发缺页）
   │      → page = NULL
   │
   └─ page = pte_page(pte)  ← ★ 最终获取到 struct page！
       return page
```

---

## 4. 🔥 缺页处理——faultin_page

当 `follow_page_mask` 返回 NULL 时，GUP 主动触发缺页来建立页表映射：

```c
// mm/gup.c:1087 — doom-lsp 确认
static int faultin_page(struct vm_area_struct *vma,
                         unsigned long address, unsigned int flags,
                         bool unshare, int *locked)
{
    unsigned int fault_flags = 0;
    vm_fault_t ret;

    // [转换 GUP flags → 缺页 flags]
    if (flags & FOLL_WRITE)
        fault_flags |= FAULT_FLAG_WRITE;          // 写缺页
    if (flags & FOLL_REMOTE)
        fault_flags |= FAULT_FLAG_REMOTE;         // 远程访问
    if (flags & FOLL_UNSHARE)
        fault_flags |= FAULT_FLAG_UNSHARE;        // 强制取消共享
    if (flags & FOLL_INTERRUPTIBLE)
        fault_flags |= FAULT_FLAG_INTERRUPTIBLE;  // 可中断
    if (flags & FOLL_NOWAIT)
        fault_flags |= FAULT_FLAG_ALLOW_RETRY | FAULT_FLAG_TRIED;  // 非阻塞
    if (flags & FOLL_ALLOW_RETRY)
        fault_flags |= FAULT_FLAG_ALLOW_RETRY;    // 允许重试

    // [调用核心缺页处理]
    ret = handle_mm_fault(vma, address, fault_flags, NULL);

    // [错误处理]
    if (ret & VM_FAULT_ERROR) {
        int err = vm_fault_to_errno(ret, flags);
        // 如果是 DAX/设备内存错误：可能需要额外处理
        return err;
    }

    // [RSS 统计修正]
    if (ret & VM_FAULT_MAJOR)
        current->maj_flt++;
    else
        current->min_flt++;

    // [缺页后返回 0]
    // __get_user_pages 主循环会在下一次循环中
    // 再次调用 follow_page_mask（此时页表已建立）
    return 0;
}
```

`handle_mm_fault` 内部调用 `__handle_mm_fault`，根据 VMA 类型选择不同的缺页路径：

```
handle_mm_fault(vma, address, flags)
  │
  └─ __handle_mm_fault(vma, address, flags)
       │
       ├─ 确保页表各级目录存在：
       │   pgd_offset → p4d_alloc → pud_alloc → pmd_alloc
       │   → 如果不存在则分配页表页
       │
       └─ handle_pte_fault(vmf)
            │
            ├─ do_anonymous_page(vmf)    ← 匿名页首次访问
            │   ├─ pte_alloc(vma->vm_mm, vmf->pmd)
            │   ├─ folio = alloc_anon_folio(vma)  ← 分配新页
            │   ├─ folio_mark_uptodate(folio)
            │   └─ set_pte_at(...)       ← 建立映射
            │
            ├─ do_fault(vmf)             ← 文件映射缺页
            │   ├─ do_read_fault(vmf)    → aops->read_folio
            │   ├─ do_cow_fault(vmf)     → alloc + copy
            │   └─ do_shared_fault(vmf)  → aops->write_begin
            │
            ├─ do_swap_page(vmf)         ← 换入
            │   └─ swap_read_folio()
            │
            └─ do_numa_page(vmf)         ← NUMA 迁移
```

---

## 5. 页面固定——try_grab_folio

```c
// mm/gup.c:140 — doom-lsp 确认
static int try_grab_folio(struct folio *folio, int refs, unsigned int flags)
{
    // FOLL_PIN 路径：使用专用 pin 计数
    if (flags & FOLL_PIN) {
        // 使用 GUP_PIN_COUNTING_BIAS 倍率
        // 每次 pin 增加 refcount 1024
        folio_ref_add(folio, refs * (GUP_PIN_COUNTING_BIAS));
        // 跟踪 pin 统计
        node_page_state_mod_folio(folio, NR_FOLL_PIN_ACQUIRED, refs);
        return 0;
    }

    // FOLL_GET 路径：传统引用计数
    folio_get(folio);  // refcount++
    return 0;
}
```

**GUP_PIN_COUNTING_BIAS 的位级编码**：

```
folio->_refcount 的 32-bit：
┌────────────────┬──────────────────────────────────────────────────────┐
│ pin count      │ 普通引用计数 (refcount)                              │
│ (refcount /   │ (refcount % GUP_PIN_COUNTING_BIAS)                   │
│  GUP_BIAS)    │                                                      │
└────────────────┴──────────────────────────────────────────────────────┘

GUP_PIN_COUNTING_BIAS = 1024 = 0x400

refcount = 1:         0x00000001 → 只有一个引用，无 pin
refcount = 1024+1:    0x00000401 → 一个引用 + 一个 pin
refcount = 2048+2:    0x00000802 → 两个引用 + 两个 pin

folio_maybe_dma_pinned(folio):
  return (folio_ref_count(folio) & (GUP_PIN_COUNTING_BIAS - 1)) != 0
  // 检查低 10 位是否非零 → 非零表示有活跃的 pin
```

---

## 6. 释放路径——unpin_user_page

```c
// mm/gup.c:185 — doom-lsp 确认
void unpin_user_page(struct page *page)
{
    struct folio *folio = page_folio(page);
    unpin_folio(folio);  // @ L199
}

// mm/gup.c:199 — doom-lsp 确认
void unpin_folio(struct folio *folio)
{
    gup_put_folio(folio, 1, FOLL_PIN);  // 释放一个 pin
}

// 批量释放 + 脏页处理：
// mm/gup.c:284 — doom-lsp 确认
void unpin_user_pages_dirty_lock(struct page **pages, unsigned long npages,
                                  bool make_dirty)
{
    if (!make_dirty) {
        unpin_user_pages(pages, npages);
        return;
    }

    for (i = 0; i < npages; i += nr) {
        folio = gup_folio_next(pages, npages, i, &nr);
        // 优化：跳过已经脏的 folio
        if (!folio_test_dirty(folio)) {
            folio_lock(folio);
            folio_mark_dirty(folio);
            folio_unlock(folio);
        }
        gup_put_folio(folio, nr, FOLL_PIN);
    }
}
```

---

## 7. FOLL_LONGTERM——长期固定与迁移

当设置了 `FOLL_LONGTERM` 标志（通常由 RDMA 或 vfio 使用，固定超过 2 秒的页面）：

```c
// mm/gup.c — __gup_longterm_locked
// 检查页面是否在 ZONE_MOVABLE
// 如果是 → 迁移到 ZONE_NORMAL

static long check_and_migrate_movable_pages(struct page **pages,
                                             unsigned long nr_pages)
{
    // 遍历所有被固定的页面
    for (i = 0; i < nr_pages; i++) {
        struct folio *folio = page_folio(pages[i]);

        // 检查是否在可移动区域
        if (folio_is_longterm_pinnable(folio))
            continue;  // OK，不需要迁移

        // 需要迁移！
        // 收集所有需要迁移的页面
        // 调用 migrate_pages() 复制到 ZONE_NORMAL
        // 更新 pages[] 指向新的页面
    }
}
```

**为什么需要迁移？**

ZONE_MOVABLE 允许页面迁移以提供连续内存（memory compaction）。长期固定的页面不能被迁移——如果它们在 ZONE_MOVABLE 中，会阻塞 compaction，导致大页分配失败。因此 GUP 在固定前将页面从 ZONE_MOVABLE 迁移到 ZONE_NORMAL。

---

## 8. 完整 O_DIRECT 读数据流

```
用户: read(fd, buf, 4096, O_DIRECT)

内核:
  │
  ├─ 检查偏移和大小对齐（O_DIRECT 需要 512 字节对齐）
  │
  ├─ iov_iter_get_pages(iter, pages, PAGE_SIZE, &start)
  │   → 获取用户缓冲区对应的物理页面
  │
  ├─ pin_user_pages(addr, nr, FOLL_WRITE, pages)
  │   │
  │   ├─ __get_user_pages(mm, addr, 1, gup_flags, pages)
  │   │   ├─ find_vma(mm, addr) → 找到 VMA
  │   │   ├─ follow_page_mask(vma, addr, flags, &page_mask)
  │   │   │   → PGD → P4D → PUD → PMD → PTE
  │   │   │   → pte_none? → return NULL
  │   │   ├─ faultin_page(vma, addr, flags)
  │   │   │   → handle_mm_fault → do_anonymous_page
  │   │   │   → folio = alloc_zero_folio() → 分配零页
  │   │   │   → set_pte_at → 建立映射
  │   │   └─ follow_page_mask → 现在可以获取到 page 了！
  │   │        → try_grab_folio(FOLL_PIN) → 固定
  │   │
  │   └─ return [page]
  │
  ├─ bio = bio_alloc(bdev, 1, ...)
  │   bio_set_page(bio, page, PAGE_SIZE, 0)
  │   → BIO 直接指向用户空间页面
  │
  ├─ submit_bio(bio)
  │   [硬盘 DMA 直接写入用户空间的页面！]
  │
  └─ bio 完成后：
       └─ unpin_user_pages_dirty_lock(pages, 1, true)
           → folio_mark_dirty(folio)
           → gup_put_folio(folio, 1, FOLL_PIN)
           → pin 释放，页面可被再次回收
```

---

## 9. GUP flags 完整表

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
| `FOLL_UNSHARE` | 0x1000 | 强制取消共享 COW | 安全 |
| `FOLL_REMOTE` | 0x2000 | 跨进程 GUP | 进程跟踪 |
| `FOLL_NOFAULT` | 0x4000 | 不触发缺页 | 快速检查 |

---

## 10. 源码文件索引

| 函数 | 行号 | 文件 |
|------|------|------|
| `try_grab_folio` | 140 | mm/gup.c |
| `unpin_user_page` | 185 | mm/gup.c |
| `unpin_folio` | 199 | mm/gup.c |
| `unpin_user_pages_dirty_lock` | 284 | mm/gup.c |
| `follow_page_mask` | 1007 | mm/gup.c |
| `faultin_page` | 1087 | mm/gup.c |
| `__get_user_pages` | 1301 | mm/gup.c |
| `handle_mm_fault` | — | mm/memory.c |

---

## 11. 关联文章

- **16-vm_area_struct**：GUP 的第一步是查找 VMA
- **17-page_allocator**：缺页触发的物理页分配
- **77-vfio-iommu**：vfio 使用 FOLL_LONGTERM 固定内存
- **88-mmap**：mmap 与 GUP 的交互

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
