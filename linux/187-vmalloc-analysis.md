# 187-vmalloc — vmalloc深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/vmalloc.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**vmalloc** 在虚拟内存中分配连续区域，但物理内存不一定连续。适用于内核需要大块连续虚拟内存的场景（如模块加载、大缓冲区）。

---

## 1. vmalloc vs kmalloc

```
kmalloc：
  物理连续
  最多 4MB（MAX_ORDER=10）
  使用 buddy system
  快速，但容易碎片化

vmalloc：
  物理不连续（3-4层页表）
  虚拟连续（通常从 VMALLOC_START 开始）
  用于大缓冲区（>4MB）
  较慢（需要建立页表）

alloc_pages：
  直接分配物理页
  物理连续，虚拟连续
```

---

## 2. vmalloc 实现

```c
// mm/vmalloc.c — vmalloc_node
void *vmalloc_node(unsigned long size, int node)
{
    return __vmalloc_node(size, GFP_KERNEL, NUMA_NO_NODE);
}

void *__vmalloc_node(unsigned long size, gfp_t gfp_mask, int node)
{
    // 1. 计算需要的页数
    nr_pages = size >> PAGE_SHIFT;

    // 2. 分配页（per-CPU 或 buddy）
    pages = alloc_pages_node(node, gfp_mask, order);

    // 3. 建立页表映射（3-4层）
    for (each page) {
        map_vm_area(page, PAGE_KERNEL);
    }

    // 4. 返回虚拟起始地址
    return (void *)area->addr;
}
```

---

## 3. vm_struct

```c
// mm/vmalloc.c — vm_struct
struct vm_struct {
    unsigned long       addr;           // 虚拟起始地址
    unsigned long       size;           // 总大小
    unsigned long       flags;           // VM_* 标志
    struct page       **pages;          // 页数组
    unsigned int        num_pages;       // 页数
    struct vm_struct   *next;           // 链表
};
```

---

## 4. VMALLOC_START / VMALLOC_END

```
虚拟地址空间布局（x86_64）：
  0xFFFF800000000000 +

  0xFFFF800000000000: kernel text
  0xFFFF880000000000: vmalloc 区域（128 TB）
  0xFFFFC90000000000: vmemmap
  0xFFFFEA0000000000: modules 区域
```

---

## 5. vfree

```c
// mm/vmalloc.c — vfree
void vfree(const void *addr)
{
    // 1. 找到 vm_struct
    find_vm_area(addr);

    // 2. 解除页表映射
    unmap_vm_area();

    // 3. 释放物理页
    for (each page) {
        put_page(page);
    }
}
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `mm/vmalloc.c` | `vmalloc_node`、`__vmalloc`、`vfree` |
| `mm/vmalloc.c` | `struct vm_struct` |

---

## 7. 西游记类喻

**vmalloc** 就像"天庭的跨区域仓库"——

> vmalloc 像一个跨多个城市的虚拟仓库。仓库的编号是连续的（虚拟连续），但货物实际上可能放在不同的仓库（物理不连续）。好处是可以有很大的虚拟空间（128TB），缺点是取货时要查好几本账（多级页表），比在同一个仓库里取货（kmalloc）慢。当需要分配巨大的缓冲区（>4MB）时，就用 vmalloc，虽然慢一点，但不会因为找不到连续的大块物理空间而失败。

---

## 8. 关联文章

- **page_allocator**（article 17）：vmalloc 底层使用 alloc_pages
- **ioremap**（相关）：ioremap 映射 I/O 设备内存