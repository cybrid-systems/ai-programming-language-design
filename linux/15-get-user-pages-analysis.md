# get_user_pages / get_user_pages_fast — 锁定用户页深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/gup.c` + `mm/internal.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**get_user_pages** 将用户空间的虚拟地址转换为**物理页帧**，并锁定在内存中（`page cache`），防止被换出。

---

## 1. 核心 API

### 1.1 get_user_pages — 主接口

```c
// mm/gup.c — get_user_pages
long get_user_pages(unsigned long start, unsigned long nr_pages,
           unsigned int gup_flags, struct page **pages,
           struct vm_area_struct **vmas)
{
    return get_user_pages_remote(start, nr_pages, gup_flags, pages, vmas, NULL);
}
```

### 1.2 get_user_pages_remote — 远程（跨进程）

```c
// mm/gup.c — get_user_pages_remote
long get_user_pages_remote(struct mm_struct *mm,
    unsigned long start, unsigned long nr_pages,
    unsigned int gup_flags, struct page **pages,
    struct vm_area_struct **vmas, int *locked)
```

### 1.3 pin_user_pages — FOLL_PIN

```c
// mm/gup.c — pin_user_pages
// 与 get_user_pages 类似，但使用 FOLL_PIN 标志
// 页面被" pinning"（不能被迁移/回收）
```

---

## 2. 核心流程

```
get_user_pages(addr)
    ↓
1. 遍历 VMA：find_vma()
    ↓
2. 遍历页面范围：
   for each page:
       follow_page() → 获取 struct page*
       if (!page):
           faultin_page() → 处理 page fault
       pin_page() → 增加 page refcount
    ↓
3. 返回页面数组
```

---

## 3. follow_page — 查找物理页

```c
// mm/memory.c — follow_page
struct page *follow_page(struct vm_area_struct *vma, unsigned long address,
               unsigned int foll_flags)
{
    // 1. 获取 pmd
    pmd = *pmd_offset(pud, address);

    // 2. 如果是 hugetlb 或 THP
    if (pmd_huge(*pmd))
        return follow_huge_pmd(vma, address, pmd, foll_flags);

    // 3. 获取 pte
    pte = *pte_offset_map(pmd, address);

    // 4. 检查 pte 有效性
    if (!pte_present(pte))
        return NULL;

    // 5. 获取物理页
    page = pte_page(pte);

    return page;
}
```

---

## 4. faultin_page — 处理缺页

```c
// mm/gup.c — faultin_page
static int faultin_page(struct vm_area_struct *vma, unsigned long address,
            unsigned int *flags, int *locked)
{
    // 1. 处理 write fault（如果 FOLL_WRITE）
    if (*flags & FOLL_WRITE)
        fault_flags |= FAULT_FLAG_WRITE;

    // 2. 调用 handle_mm_fault()
    handle_mm_fault(vma, address, fault_flags);

    // 3. 检查是否成功
    if (*locked)
        *locked = 0;  // 页表已更新，需要重新获取
}
```

---

## 5. FOLL_* 标志

```c
// include/linux/mm.h
#define FOLL_READ       0x01    // 读访问
#define FOLL_WRITE      0x02    // 写访问（COW）
#define FOLL_FORCE      0x04    // 强制访问
#define FOLL_ANON       0x08    // 仅匿名页面
#define FOLL_LONGTERM   0x10    // 长期锁定（用于 DMA）
#define FOLL_POPULATE   0x20    // 缺页时自动填充
#define FOLL_PIN       0x100    // 固定（不能迁移/回收）
#define FOLL_GET        0x200    // 获取页面引用
```

---

## 6. 完整文件索引

| 文件 | 函数 |
|------|------|
| `mm/gup.c` | `get_user_pages`、`get_user_pages_remote`、`pin_user_pages` |
| `mm/memory.c` | `follow_page`、`handle_mm_fault` |
| `mm/internal.h` | 内部辅助函数 |
