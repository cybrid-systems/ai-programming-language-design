# vmalloc — 内核虚拟地址空间分配深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/vmalloc.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**vmalloc** 在**虚拟地址空间**分配连续区域（物理页可不连续），适用于大块内存分配（如模块空间、kernel BSS）。

---

## 1. vmalloc vs kmalloc 对比

| 特性 | kmalloc | vmalloc |
|------|---------|---------|
| 物理地址 | 连续 | 不连续 |
| 虚拟地址 | 连续 | 连续 |
| 大小限制 | 最大 4MB（kmalloc 缓存）| 无硬限制 |
| 性能 | 快（Buddy 直接分配）| 较慢（需建立页表）|
| 使用场景 | 内核数据结构 | 模块、large buffers |

---

## 2. 核心数据结构

### 2.1 vmap_area — vmalloc 区域

```c
// include/linux/vmalloc.h — vmap_area
struct vmap_area {
    unsigned long           va_start;      // 起始虚拟地址
    unsigned long           va_end;         // 结束虚拟地址
    struct rb_node          rb_node;        // 接入 vmap_area_root
    unsigned long           vm;            // VM_ALLOC 标志
    struct list_head        list;          // 链表
    void                   *private;       // 私有数据
};
```

### 2.2 vmap_area_root — 红黑树

```c
// mm/vmalloc.c — 全局 vmalloc 区域树
static struct rb_root       vmap_area_root = RB_ROOT;
static struct list_head     vmap_area_list;  // 按地址排序的链表

// 查找：O(log n)
struct vmap_area *va = __find_vmap_area(addr);
```

---

## 3. __vmalloc_node — 分配虚拟连续区域

```c
// mm/vmalloc.c — __vmalloc_node
void *__vmalloc_node(unsigned long size, gfp_t gfp_mask, pgprot_t prot,
                     int node, ...)
{
    struct vm_struct *area;
    void *addr;

    // 1. 分配 vm_struct（管理元数据）
    area = __get_vm_area_node(size, 1, VM_ALLOC, VM_MAP_IOREMAP, ...);

    // 2. 分配物理页（每个页单独分配，物理不连续）
    for (i = 0; i < size; i += PAGE_SIZE) {
        page = alloc_pages_node(node, gfp_mask | __GFP_ZERO, 0);
        if (!page)
            goto fail;

        // 3. 建立页表映射（每个页独立映射）
        if (map_kernel_range((unsigned long)area->addr + i,
                              PAGE_SIZE, gfp_mask, page) < 0)
            goto fail;
    }

    addr = area->addr;

    // 4. 更新 vmap_area
    setup_vmalloc_vm(area, VM_ALLOC, VM_MAP_IOREMAP);

    return addr;
}
```

---

## 4. __get_vm_area_node — 分配管理结构

```c
// mm/vmalloc.c — __get_vm_area_node
static struct vm_struct *__get_vm_area_node(...)
{
    struct vm_struct *area;

    // 分配 vm_struct
    area = kzalloc(sizeof(*area), gfp_mask);

    // 从 vmap_area_root 找空闲虚拟地址范围
    area->addr = __find_vmap_area(VA_START, size, align);

    // 初始化
    area->size = size;
    area->flags = flags;
    INIT_LIST_HEAD(&area->pages);
    INIT_HLIST_NODE(&area->busy_list);

    return area;
}
```

---

## 5. vmalloc_to_page — 查物理页

```c
// mm/vmalloc.c — vmalloc_to_page
struct page *vmalloc_to_page(const void *vmalloc_addr)
{
    unsigned long va = (unsigned long)vmalloc_addr;

    // 1. 查找 vmap_area
    va &= PAGE_MASK;
    vmap_area = __find_vmap_area(va);

    // 2. 通过页表查找物理页
    //    虚拟地址 → 页表遍历 → PTE → struct page
    return vmalloc_to_pfn(vmalloc_addr) << PAGE_SHIFT;
}
```

---

## 6. vfree — 释放

```c
// mm/vmalloc.c — vfree
void vfree(void *addr)
{
    struct vm_struct *area;

    // 1. 查找 vm_struct
    area = find_vm_area(addr);
    if (!area)
        return;

    // 2. 解除页表映射
    for (i = 0; i < area->size; i += PAGE_SIZE)
        unmap_kernel_range((unsigned long)area->addr + i, PAGE_SIZE);

    // 3. 释放物理页
    free_pages(area->pages, area->nr_pages);

    // 4. 释放 vm_struct 和 vmap_area
    free_vm_area(area);
}
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `mm/vmalloc.c` | `__vmalloc_node`、`vfree`、`vmalloc_to_page` |
| `include/linux/vmalloc.h` | `struct vmap_area`、`struct vm_struct` |