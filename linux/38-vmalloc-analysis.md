# 38-vmalloc — Linux 内核虚拟地址分配深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**vmalloc** 分配虚拟地址连续但物理地址不连续的内存。与 kmalloc（物理连续，来自 buddy）不同，vmalloc 通过修改页表将离散的物理页映射到 VMALLOC 区域的连续虚拟地址空间。适合于大块内存分配，性能低于 kmalloc。

**doom-lsp 确认**：`mm/vmalloc.c` 包含核心实现。关键函数 `__vmalloc_node_range`、`vmalloc`、`vfree`。

---

## 1. kmalloc vs vmalloc

| 特性 | kmalloc | vmalloc |
|------|---------|---------|
| 物理连续 | ✅ 连续 | ❌ 离散 |
| 虚拟连续 | ✅ | ✅ |
| 延迟 | ~100ns | ~5μs（页表操作）|
| 最大大小 | 4MB（MAX_ORDER）| 几乎无限制 |
| TLB 效率 | 高（一页可映射 2MB/1GB）| 低（每 4KB 需 TLB）|

---

## 2. 分配路径

```
vmalloc(size)
  └─ __vmalloc_node_range(size, align, VMALLOC_START, VMALLOC_END, ...)
       │
       ├─ 1. 搜索空闲虚拟地址区间
       │   alloc_vmap_area(size, align, start, end)
       │   → 在 vmap_area 红黑树中查找空闲区间
       │   → O(log n)
       │
       ├─ 2. 分配物理页
       │   for (每个要分配的区域页) {
       │       page = alloc_page(gfp_mask);
       │       area->pages[i] = page;
       │   }
       │   → 每页独立从 buddy 获取
       │   → 物理页可能来自不同的 pageblock
       │
       ├─ 3. 建立页表映射
       │   map_kernel_range(addr, size, PAGE_KERNEL, pages)
       │   → __map_mapping_single
       │     → 遍历虚拟地址区间
       │     → 为每页设置 PGD→P4D→PUD→PMD→PTE
       │     → flush_tlb_kernel_range（TLB 刷新）
       │
       └─ 4. 返回虚拟地址
```

---

## 3. 释放路径

```
vfree(addr)
  └─ __vunmap(addr, 1)      // 1=free_pages
       │
       ├─ 查找 vmap_area
       ├─ unmap_kernel_range(addr, size)  // 清理页表
       ├─ for each page:
       │   __free_page(page)              // 释放每页到 buddy
       └─ free_vmap_area(area)            // 释放 vmap_area
```

---

## 4. 数据结构

```c
// include/linux/vmalloc.h
struct vm_struct {
    struct vm_struct    *next;
    void                *addr;       // 虚拟地址
    unsigned long       size;        // 大小
    unsigned long       flags;       // VM_IOREMAP, VM_ALLOC
    struct page         **pages;     // 物理页数组
    unsigned int        nr_pages;    // 页数
    phys_addr_t         phys_addr;   // 物理地址（仅 ioremap）
};

struct vmap_area {
    unsigned long       va_start;    // 起始地址
    unsigned long       va_end;      // 结束地址
    struct rb_node      rb_node;     // 红黑树节点
    struct list_head    list;        // 链表
    struct vm_struct    *vm;         // 关联的 vm_struct
};
```

---

## 5. 源码文件索引

| 文件 | 内容 |
|------|------|
| mm/vmalloc.c | vmalloc 核心实现 |
| include/linux/vmalloc.h | 结构体定义 |

---

## 6. 关联文章

- **17-page-allocator**: buddy 分配器
- **187-vmalloc**: vmalloc 深度分析

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01*
