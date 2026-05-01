# 15-get-user-pages — 用户页获取机制深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**get_user_pages（GUP）** 是 Linux 内核中用于将用户空间虚拟地址转换为物理页面的核心机制。它允许内核代码锁定用户空间的页面、获取其 `struct page*` 指针，然后直接读写这些页面——绕过缺页异常处理、直接访问页面的物理内存。

GUP 在内核 I/O 路径中至关重要：

1. **直接 I/O（O_DIRECT）**：`read()/write()` 绕过 page cache 时，需要通过 GUP 固定用户缓冲区对应的物理页面
2. **RDMA**：远程直接内存访问通过 GUP 固定用户内存，然后由网卡硬件直接读写
3. **vfio**：设备直通需要 GUP 将用户进程的地址空间固定为 DMA 可访问区域
4. **KVM**：虚拟机内存通过 GUP 固定，确保虚拟机物理地址对应真实的物理内存

**doom-lsp 确认**：`mm/gup.c` 包含 **157 个符号**，是内存管理子系统中最大源文件之一。

---

## 1. GUP 的核心流程

```
get_user_pages(start, nr_pages, gup_flags, pages, vmas)
  │
  ├─ 检查参数合法性
  │
  ├─ 处理 gup_flags：
  │   ├─ FOLL_WRITE    → 需要写权限
  │   ├─ FOLL_PIN      → 使用 FOLL_PIN 接口（较新的 pin_user_pages）
  │   ├─ FOLL_LONGTERM → 长期固定页面
  │   ├─ FOLL_FORCE    → 强制获取（即使无读权限）
  │   └─ FOLL_NOWAIT   → 非阻塞
  │
  ├─ 锁定 mmap_lock（读模式）
  │
  ├─ for each page：
  │   │
  │   ├─ __get_user_pages(start, ...)      ← 核心实现
  │   │    │
  │   │    ├─ find_extend_vma(mm, start)    ← 查找 VMA
  │   │    │
  │   │    ├─ follow_page_mask(vma, addr, flags)  ← 快速路径
  │   │    │   └─ walk page table
  │   │    │        ├─ 页表存在 → folio = page_folio(pte_page(pte))
  │   │    │        ├─ 页表不存在 → 触发缺页
  │   │    │        └─ 需要 COW → 处理写时复制
  │   │    │
  │   │    ├─ 如果 follow_page 失败：
  │   │    │   └─ faultin_page(vma, addr, flags)  ← 触发缺页
  │   │    │       └─ handle_mm_fault(vma, addr, flags)
  │   │    │            ├─ 页表不存在 → 分配页
  │   │    │            ├─ 页面被换出 → 换入
  │   │    │            └─ 需要 COW → 复制页
  │   │    │
  │   │    ├─ try_grab_folio(page, flags)          ← 固定页面
  │   │    │   ├─ 增加 folio 引用计数
  │   │    │   └─ 如果 FOLL_PIN：pin 引用 + 标记为被固定
  │   │    │
  │   │    └─ pages[i] = page                      ← 返回页面指针
  │   │
  │   └─ start += PAGE_SIZE; i++
  │
  └─ 解锁 mmap_lock
```

---

## 2. 快速路径——follow_page_mask

```
follow_page_mask(vma, address, flags)
  │
  ├─ pgd_offset(mm, address)         ← PGD
  ├─ p4d_offset(pgd, address)        ← P4D
  ├─ pud_offset(p4d, address)        ← PUD
  ├─ pmd_offset(pud, address)        ← PMD
  │
  ├─ if (pmd_huge(pmd))             ← 大页（2MB）
  │   └─ follow_huge_pmd(...)
  │
  ├─ pte_offset_map(pmd, address)    ← PTE
  │
  ├─ if (!pte_present(pte))         ← 不在内存中
  │   └─ return NULL（触发缺页）
  │
  ├─ if (!pte_write(pte) && (flags & FOLL_WRITE))
  │   └─ return NULL（需要写时复制）
  │
  ├─ page = pte_page(pte)            ← 获取 struct page
  └─ return page
```

---

## 3. FOLL_PIN——新型固定 API

传统 `get_user_pages` 使用 `get_page()` 增加引用计数来固定页面。但这种方式与页面回收之间可能存在竞争。Linux 5.2 引入了 `FOLL_PIN` / `pin_user_pages` 接口：

```c
// mm/gup.c — doom-lsp 确认
long pin_user_pages(unsigned long start, unsigned long nr_pages,
                    unsigned int gup_flags, struct page **pages,
                    struct vm_area_struct **vmas);

long unpin_user_page(struct page *page);        // mm/gup.c:185
void unpin_user_pages_dirty_lock(struct page **pages,
                                  unsigned long npages, bool make_dirty);
```

**区别**：
```
get_user_pages + get_page():      普通引用计数
pin_user_pages + try_grab_folio(): 使用 FOLL_PIN 专用计数
  → 通过 folio 的 refcount 高位移位标记（与普通 get_page 不冲突）
  → 页面回收代码可以检测页面是否被 pin 住
  → 被 pin 的页面不会被 THP 合并或迁移
```

---

## 4. 解锁路径

```
unpin_user_pages(pages, npages)
  └─ for each page:
       └─ unpin_user_page(page)            @ mm/gup.c:185
            └─ folio = page_folio(page)
                 └─ unpin_folio(folio)     @ mm/gup.c:199
                      └─ gup_put_folio(folio, 1, FOLL_PIN)
                           └─ try_grab_folio 的逆操作
                                └─ folio_put(folio) × pin_count

unpin_user_pages_dirty_lock(pages, npages, make_dirty)
  └─ for each folio:
       └─ if (make_dirty && !folio_test_dirty(folio))
              folio_lock(folio)
              folio_mark_dirty(folio)
              folio_unlock(folio)
       └─ gup_put_folio(folio, ...)        ← 释放 pin
```

---

## 5. 典型使用——O_DIRECT 读

```
用户进程调用 read(fd, buf, count, O_DIRECT)

VFS 层：
  └─ blkdev_direct_IO(iocb, iter)
       │
       ├─ iov_iter_get_pages(iter, pages, ...)  ← GUP 核心
       │    └─ pin_user_pages(...)
       │         ├─ 查找用户空间地址的 VMA
       │         ├─ follow_page_mask → 页表遍历
       │         ├─ 缺页处理（如果需要）
       │         └─ try_grab_folio → 固定页面
       │
       ├─ submit_bio(bio)            ← 提交 BIO 到块设备
       │   └─ DMA 直接读取到用户页面
       │
       └─ bio 完成后：
            └─ unpin_user_pages_dirty_lock(pages, npages, true)
                 └─ folio_mark_dirty + 释放 pin
```

---

## 6. GUP flags 详解

| Flag | 值 | 含义 |
|------|-----|------|
| `FOLL_WRITE` | 0x01 | 需要写权限 |
| `FOLL_TOUCH` | 0x02 | 访问页（更新 accessed/dirty 位）|
| `FOLL_GET` | 0x04 | 获取页面引用 |
| `FOLL_DUMP` | 0x08 | 允许从 /proc/pid/mem 读取 |
| `FOLL_FORCE` | 0x10 | 即使权限不足也强制获取 |
| `FOLL_NOWAIT` | 0x20 | 非阻塞，不触发缺页 |
| `FOLL_PIN` | 0x40 | 使用 pin_user_pages 协议 |
| `FOLL_LONGTERM` | 0x100 | 长期固定页面 |
| `FOLL_SPLIT_PMD` | 0x200 | 分裂 THP 大页 |
| `FOLL_PCI_P2PDMA` | 0x400 | 允许 PCI peer-to-peer |
| `FOLL_INTERRUPTIBLE` | 0x800 | 可被信号中断 |
| `FOLL_UNSHARE` | 0x1000 | 强制取消共享 (COW) |

## 7. 源码文件索引

| 文件 | 内容 | 符号数 |
|------|------|--------|
| `mm/gup.c` | GUP 核心实现 | **157 个** |
| `include/linux/mm.h` | get_user_pages 声明 | — |

---

## 8. 关联文章

- **16-vm_area_struct**：GUP 查找 VMA
- **17-page_allocator**：缺页触发的物理页分配
- **18-copy_page_range**：COW 与 GUP 的关系
- **77-vfio-iommu**：vfio 使用 GUP 固定用户内存

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
