# 38-vmalloc — Linux 内核虚拟内存分配深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**vmalloc** 分配虚拟地址连续但物理地址不连续的内存。与 kmalloc（物理连续）不同，vmalloc 通过修改内核页表将离散的物理页映射到连续的虚拟地址空间。适合于大块内存分配。

**doom-lsp 确认**：`mm/vmalloc.c` 包含核心实现。关键函数 `__vmalloc_node_range`。

---

## 1. kmalloc vs vmalloc

| 特性 | kmalloc | vmalloc | alloc_pages |
|------|---------|---------|-------------|
| 物理连续 | ✅ | ❌ | ✅ |
| 虚拟连续 | ✅ | ✅ | ✅ |
| 延迟 | ~100ns | ~5μs | ~50ns |
| 最大大小 | 4MB | 几乎不限 | 4MB |
| 适用场景 | 小对象 | 大对象/驱动 | 页级分配 |

---

## 2. 分配路径

```c
void *vmalloc(unsigned long size)
{
    return __vmalloc_node_range(size, 1, VMALLOC_START, VMALLOC_END,
                                 GFP_KERNEL, PAGE_KERNEL, 0, NUMA_NO_NODE,
                                 __builtin_return_address(0));
}
```

内部步骤：
```
1. alloc_vmap_area() — 在 VMALLOC 区间查找空闲虚拟地址
   使用红黑树（vmap_area_root）管理分配的区间
2. 循环分配物理页
   for (i = 0; i < nr_pages; i++)
       area->pages[i] = alloc_page(gfp_mask)
3. map_kernel_range() — 建立页表映射
   遍历每个物理页，设置 PGD→PUD→PMD→PTE
4. flush_tlb_kernel_range() — TLB 刷新
```

---

## 3. 释放路径

```c
void vfree(const void *addr)
{
    __vunmap(addr, 1);  // 1 = free_pages
    // 1. unmap_kernel_range() 清理页表
    // 2. 循环 __free_page() 释放每页
    // 3. free_vmap_area() 释放虚拟地址
}
```

---

## 4. 数据结构

```c
struct vm_struct {
    struct vm_struct    *next;      // 链表
    void                *addr;      // 虚拟地址
    unsigned long       size;       // 大小
    unsigned long       flags;      // VM_IOREMAP, VM_ALLOC
    struct page         **pages;    // 物理页数组
    unsigned int        nr_pages;   // 页数
    phys_addr_t         phys_addr;  // 物理地址（ioremap）
};

struct vmap_area {
    unsigned long va_start;
    unsigned long va_end;
    struct rb_node rb_node;         // 红黑树
    struct vm_struct *vm;
};
```

---

## 5. vmalloc 使用场景

| 场景 | 原因 |
|------|------|
| 模块加载（module_alloc）| 需要大块可执行内存 |
| 帧缓冲驱动 | 大块连续虚拟内存 |
| 网络缓冲区 | 大块内存分配 |
| /dev/mem | ioremap |

---

## 6. 源码文件索引

| 文件 | 内容 |
|------|------|
| mm/vmalloc.c | vmalloc 核心 |
| include/linux/vmalloc.h | 结构体 |

---

## 7. 关联文章

- **17-page-allocator**: 底层 buddy 分配器
- **187-vmalloc**: vmalloc 深度分析

---
