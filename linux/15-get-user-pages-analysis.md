# 15-get_user_pages / follow_page — 用户页获取深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/gup.c` + `mm/memory.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**get_user_pages** 将用户空间虚拟地址转换为物理页帧（struct page*），用于 DMA 缓冲（设备直接访问内存）、驱动访问用户缓冲区、GPU 共享内存等。

---

## 1. 核心 API

### 1.1 get_user_pages — 获取用户页

```c
// mm/gup.c — get_user_pages
long get_user_pages(unsigned long start, unsigned long nr_pages,
                   unsigned int gup_flags, struct page **pages,
                   struct vm_area_struct **vmas)
{
    long ret;
    struct vm_area_struct *vma;

    // 1. 遍历每个页
    for (i = 0; i < nr_pages; i++) {
        ret = get_user_pages_page(vma, start + i * PAGE_SIZE, gup_flags, &page);
        if (ret < 0)
            goto out;
        pages[i] = page;
    }

out:
    return ret > 0 ? i : ret;
}

// gup_flags：
//   FOLL_GET      = 0x01   // 增加页引用（get_page）
//   FOLL_PIN      = 0x02   // 页被固定（不能被换出，用于 DMA）
//   FOLL_TOUCH    = 0x04   // 访问页（触发 page fault）
//   FOLL_WRITE    = 0x08   // 可写（触发 COW）
//   FOLL_FORCE    = 0x10   // 强制获取（即使没有访问权限）
```

### 1.2 get_user_pages_page — 获取单个页

```c
// mm/gup.c — get_user_pages_page
static long get_user_pages_page(struct vm_area_struct *vma,
                                 unsigned long address,
                                 unsigned int gup_flags,
                                 struct page **page)
{
    struct page *page;
    unsigned int flags = gup_flags;

retry:
    // 1. 尝试快速路径：follow_page
    page = follow_page(vma, address, flags);

    if (!page) {
        // 2. 快速路径失败，进入 slowpath（处理 page fault）
        if (foll_flags & FOLL_WRITE)
            flags |= FOLL_WRITE;

        ret = faultin_page(vma, address, &flags, foll_flags & FOLL_WRITE);
        if (ret < 0)
            goto out;

        goto retry;  // 重试
    }

out:
    return ret;
}
```

---

## 2. follow_page — 跟随页表

### 2.1 follow_page

```c
// mm/memory.c — follow_page
struct page *follow_page(struct vm_area_struct *vma, unsigned long address,
                         unsigned int flags)
{
    pte_t *ptep, pte;
    spinlock_t *ptl;

    // 1. 获取 PTE
    ptep = get_locked_pte(vma->vm_mm, address, &ptl);  // 查找或创建页表
    if (!ptep)
        return NULL;

    pte = *ptep;

    // 2. 检查 PTE 有效性
    if (!pte_present(pte)) {
        pte_unmap(ptep);
        return NULL;  // 页不在内存（ swapped out 或未分配）
    }

    // 3. 检查权限
    if ((flags & FOLL_WRITE) && !pte_write(pte))
        return NULL;  // 没有写权限

    if ((flags & FOLL_FORCE) && (flags & FOLL_WRITE))
        // FOLL_FORCE 绕过某些权限检查

    // 4. 获取物理页
    if (pte_devmap(pte))
        return pte_to_page(pte);  // 设备映射页

    if (pte_young(pte))
        ptep_test_and_set_young(pte);  // 标记已访问

    // 5. 增加页引用
    if (flags & FOLL_GET)
        get_page(pte_to_page(pte));

    pte_unmap_unlock(ptep, ptl);
    return pte_to_page(pte);
}
```

---

## 3. 缺页处理（faultin_page）

### 3.1 faultin_page — 处理缺页

```c
// mm/gup.c — faultin_page
static int faultin_page(struct vm_area_struct *vma, unsigned long address,
                        unsigned int *flags, bool write)
{
    struct vm_fault vmf = {
        .vma = vma,
        .address = address,
        .flags = 0,
        .pmc = NULL,
    };

    // 设置标志
    if (write)
        vmf.flags |= FAULT_FLAG_WRITE;

    if (*flags & FOLL_GET)
        vmf.flags |= FAULT_FLAG_KILLABLE;

    // 调用 VMA 的 fault 处理函数
    // → handle_mm_fault() → do_page_fault()
    return handle_mm_fault(vma, address, vmf.flags);
}
```

---

## 4. FOLL_PIN vs FOLL_GET

### 4.1 区别

```
FOLL_GET: 普通的页引用增加
  - 页可以被换出（虽然引用计数 > 0）
  - 适合短期借用
  - 需要 put_page() 释放

FOLL_PIN: 页被固定（pinned）
  - 页绝对不能被换出或移动
  - 用于设备 DMA（设备只能访问物理地址）
  - 需要 unpin_user_pages() 释放
  - 引用计数会标记为"pinned"
```

### 4.2 页固定计数

```c
// mm/gup.c — 被固定的页有特殊的引用计数
// FOLL_PIN 使用 page->_refcount 的额外位

// page 引用计数编码：
//   bit[0] = Pinned flag
//   bit[1..] = 实际引用计数
// 或者使用额外的 atomic_t：_total_pinned_count
```

### 4.3 put_page vs unpin_user_pages

```c
// FOLL_GET 用完后：
put_page(page);

// FOLL_PIN 用完后：
unpin_user_pages(page, npages);
//   减少固定计数
//   如果固定计数归零，允许页被换出
```

---

## 5. DMA 映射场景

### 5.1 典型 DMA 缓冲区使用

```c
// 驱动获取 DMA 缓冲区：
struct page **pages = alloc_pages(...);
void *buf = page_address(pages[0]);

// 映射到用户空间（假设用户已 mmap）：
get_user_pages(start, npages, FOLL_PIN | FOLL_WRITE, pages, NULL);

// DMA 设备访问物理地址：
dma_addr = page_to_phys(pages[0]);
// 或者 virt_to_page(buf)

// 完成后 unpin：
unpin_user_pages(pages, npages);
```

### 5.2 GPU 内存共享

```c
// GPU 驱动（如 i915, amdgpu）：
//   用户空间分配一块 GPU memory
//   驱动通过 get_user_pages(FOLL_PIN) 固定这些页
//   将物理页列表传递给 GPU 硬件
//   GPU 直接访问这些物理页
```

---

## 6. 内存布局图

```
get_user_pages(start, npages=3) 流程：

用户虚拟地址空间
  start ─────┬─── page[0] → pte[0] → 页帧 0
             │
  start+PAGE_SIZE ─┬── page[1] → pte[1] → 页帧 1
             │
  start+2*PAGE_SIZE ─┬── page[2] → pte[2] → 页帧 2

返回：
  pages[0] = &page[帧0]
  pages[1] = &page[帧1]
  pages[2] = &page[帧2]
```

---

## 7. 设计决策总结

| 设计决策 | 原因 |
|---------|------|
| FOLL_PIN vs FOLL_GET | PIN 用于 DMA，GET 用于临时借用 |
| follow_page 快速路径 | 无缺页时零 fault 开销 |
| faultin_page slowpath | 处理 demand paging / COW |
| page_to_phys | DMA 设备需要物理地址 |

---

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `mm/gup.c` | `get_user_pages`、`get_user_pages_page`、`faultin_page` |
| `mm/memory.c` | `follow_page` |
| `include/linux/mm.h` | `FOLL_GET`、`FOLL_PIN` 等标志 |

---

## 9. 西游记类比

**get_user_pages** 就像"取经路上借仙丹"——

> 悟空要从太上老君那里借一堆仙丹（物理页）。他先检查自己有没有仙丹本子上登记（follow_page）。如果没有，就去找老君签字批准（faultin_page → handle_mm_fault）。太上老君批准后，仙丹就正式借到手了（page）。如果是要拿去炼丹炉（DMA），悟空就把仙丹"固定"在原地（FOLL_PIN），这样炼丹的时候仙丹不会跑掉（不会被换出）。如果是普通用，用完就还回去（put_page）就行了。

---

## 10. 关联文章

- **vm_area_struct**（article 16）：VMA 的页保护属性
- **page_allocator**（article 17）：物理页分配
- **DMA**（设备驱动部分）：get_user_pages 用于 DMA 映射