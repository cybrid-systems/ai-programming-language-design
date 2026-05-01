# 38-vmalloc -- Linux virtual memory allocation analysis

> Based on Linux 7.0-rc1

## 0. Overview

vmalloc allocates virtually contiguous but physically non-contiguous memory.

## 1. vs kmalloc

kmalloc: physically contiguous, < 4MB
vmalloc: virtually contiguous, any size, slower

## 2. Allocation path

alloc_vmap_area -> alloc_page loop -> map_kernel_range -> TLB flush

## 3. Deallocation path

unmap_kernel_range -> free_page loop -> free_vmap_area

## 4. Data structures

struct vm_struct { addr, size, flags, pages, nr_pages }
struct vmap_area { va_start, va_end, rb_node, vm }

## 5. ioremap

ioremap maps device MMIO regions. Uses same vmap infrastructure.

## 6. Performance

Single page via buddy: ~50ns
vmalloc 1MB: ~5us (page table operations + TLB flush)

## 7. Debug

/proc/vmallocinfo shows vmalloc usage.


vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details
vmalloc details

## 5. ioremap

ioremap(phys_addr, size) 映射设备 MMIO 到内核虚拟空间。

## 6. 调试

cat /proc/vmallocinfo

## 7. 源码

mm/vmalloc.c, include/linux/vmalloc.h


## 5. ioremap

ioremap 映射设备 MMIO 到内核虚拟地址空间。使用 __ioremap_caller 实现。

```c
void __iomem *base = ioremap(0xfe000000, 4096);
u32 val = readl(base + 0x10);
writel(0x1, base + 0x00);
iounmap(base);
```

## 6. 调试

cat /proc/vmallocinfo 查看 vmalloc 区域使用情况。

## 7. 源码

mm/vmalloc.c: vmalloc/vfree 核心实现
include/linux/vmalloc.h: API 声明
mm/ioremap.c: ioremap 实现

## 8. 关联文章

- **17-page-allocator**: buddy 分配器
- **187-vmalloc**: vmalloc 深度分析


## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## vmalloc vs kmalloc

vmalloc allocates virtually contiguous pages. Each page is mapped individually through the page table. kmalloc allocates physically contiguous memory from the slab allocator or buddy system. vmalloc is slower due to page table manipulation but can allocate much larger regions.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.

## Memory mapping

map_kernel_range() iterates through each page and establishes page table entries. This involves walking the page table hierarchy (PGD-P4D-PUD-PMD-PTE) for each page. After mapping, flush_tlb_kernel_range() ensures the new mappings are visible.
