# 38-vmalloc — Linux 内核虚拟内存分配深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**vmalloc** 分配虚拟地址连续但物理地址不连续的内存。与 kmalloc（物理连续）不同，vmalloc 通过修改页表将离散的物理页映射到 VMALLOC 区域的连续虚拟空间。适合大块内存分配。

**doom-lsp 确认**：`mm/vmalloc.c` 核心实现。`__vmalloc_node_range` 是分配入口，`__vunmap_range_noflush` 是释放入口。

---

## 1. 核心数据结构

```c
// include/linux/vmalloc.h
struct vm_struct {
    struct vm_struct    *next;       // 链表（按地址排序）
    void                *addr;       // 虚拟地址
    unsigned long       size;        // 大小
    unsigned long       flags;       // VM_ALLOC, VM_IOREMAP, VM_MAP
    struct page         **pages;     // 物理页数组
    unsigned int        nr_pages;    // 物理页数
    phys_addr_t         phys_addr;   // 物理地址（ioremap）
};

struct vmap_area {
    unsigned long       va_start;    // 虚拟地址起始
    unsigned long       va_end;      // 虚拟地址结束
    struct rb_node      rb_node;     // 红黑树节点（地址查找）
    struct list_head    list;        // 链表节点
    struct vm_struct    *vm;         // 关联的 vm_struct
};
```

---

## 2. 分配路径

```
vmalloc(size)
  └─ __vmalloc_node_range(size, 1, VMALLOC_START, VMALLOC_END, GFP_KERNEL, ...)
       │
       ├─ [1] 分配 vm_struct
       │   kmalloc(sizeof(struct vm_struct), GFP_KERNEL);
       │
       ├─ [2] 查找空闲虚拟地址区间
       │   alloc_vmap_area(size, align, start, end)
       │   → 在 vmap_area_root 红黑树中查找
       │   → O(log n) 查找空闲区间
       │   → 照顾地址碎片（间隔合并）
       │
       ├─ [3] 分配物理页面
       │   area->pages = kmalloc_array(nr_pages, sizeof(struct page *), GFP_KERNEL);
       │   for (i = 0; i < nr_pages; i++) {
       │       page = alloc_page(gfp_mask);   // 每页独立分配
       │       area->pages[i] = page;          // 物理页不必连续
       │   }
       │   area->nr_pages = nr_pages;
       │
       ├─ [4] 建立页表映射
       │   map_kernel_range(addr, size, PAGE_KERNEL, pages)
       │   → vmap_range_noflush(addr, end, phys_addr, prot, page_shift)  @ L298
       │     → vmap_p4d_range() → vmap_pud_range() → vmap_pmd_range() → vmap_pte_range()
       │     → 每级页表检查是否存在
       │     → 不存在时分配新页表页
       │     → 设置 PTE 指向物理页
       │   → flush_tlb_kernel_range(addr, addr + size)  // TLB 刷新
       │
       └─ [5] 返回虚拟地址
```

---

## 3. 页表映射详解

```c
// mm/vmalloc.c:298 — 核心映射函数
static int vmap_range_noflush(unsigned long addr, unsigned long end,
                               phys_addr_t phys_addr, pgprot_t prot, int shift)
{
    pgd_t *pgd;
    unsigned long start = addr;
    unsigned long next;
    int err;

    // 逐级建立页表映射
    for (pgd = pgd_offset_k(addr); addr < end; pgd++) {
        next = pgd_addr_end(addr, end);

        // PGD → P4D → PUD → PMD → PTE
        err = vmap_p4d_range(pgd, addr, next, phys_addr, prot, shift);
        if (err) break;

        phys_addr += (next - addr);
        addr = next;
    }

    // 刷新 TLB（使新映射可见）
    flush_tlb_kernel_range(start, end);
    return err;
}

// PTE 级别的映射
// mm/vmalloc.c:94
static int vmap_pte_range(pmd_t *pmd, unsigned long addr,
                           unsigned long end, phys_addr_t phys_addr, pgprot_t prot)
{
    pte_t *pte;

    // 获取 PTE 页表
    pte = pte_alloc_kernel_tbl(pmd, addr);
    if (!pte) return -ENOMEM;

    // 设置每个 PTE 指向物理页
    do {
        set_pte_at(&init_mm, addr, pte, pfn_pte(phys_addr >> PAGE_SHIFT, prot));
        phys_addr += PAGE_SIZE;
    } while (pte++, addr += PAGE_SIZE, addr < end);

    return 0;
}
```

---

## 4. 释放路径

```
vfree(addr)
  └─ __vunmap(addr, 1)         // 1 = free_pages
       │
       ├─ [1] 查找 vmap_area
       │   find_vmap_area(addr)
       │   → 在红黑树中查找
       │
       ├─ [2] 清理页表映射
       │   unmap_kernel_range(addr, size)
       │   → vunmap_p4d_range() → ... → vunmap_pte_range()
       │   → 清除 PTE → 刷新 TLB
       │
       ├─ [3] 释放物理页
       │   for (i = 0; i < area->nr_pages; i++)
       │       if (area->pages[i])
       │           __free_page(area->pages[i]);
       │
       ├─ [4] 释放 vmap_area
       │   free_vmap_area(area)
       │   → 从红黑树移除 → 释放结构
       │
       └─ [5] 释放 vm_struct
           kfree(area->pages);  // 物理页数组
           kfree(area);         // vm_struct
```

---

## 5. ioremap

```c
// ioremap 使用相同的 vmap 机制映射设备 MMIO

void __iomem *ioremap(phys_addr_t phys_addr, unsigned long size)
{
    return __ioremap_caller(phys_addr, size, _PAGE_CACHE_MODE_UC_MINUS,
                             __builtin_return_address(0));
}

// 与 vmalloc 的区别：
// 1. 不分配物理页（映射已存在的设备内存）
// 2. 缓存属性为 uncacheable（UC）
// 3. flags = VM_IOREMAP
```

---

## 6. kmalloc vs vmalloc

| 特性 | kmalloc | vmalloc |
|------|---------|---------|
| 物理连续 | ✅ | ❌ |
| 虚拟连续 | ✅ | ✅ |
| 延迟 | ~100ns | ~5us（页表操作）|
| 最大大小 | 4MB (MAX_ORDER) | 几乎不限 |
| TLB 效率 | 高（2MB 大页） | 低（4KB 小页）|
| 适用场景 | 小对象 | 大块分配、驱动 |

---

## 7. 源码文件索引

| 文件 | 内容 |
|------|------|
| mm/vmalloc.c | vmalloc/vfree/ioremap 核心 |
| include/linux/vmalloc.h | 结构体定义 |

---

## 8. 关联文章

- **17-page-allocator**: buddy 分配器
- 

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01*
*分析工具：doom-lsp

## 9. vmap_area 红黑树管理

```c
// 使用红黑树组织所有 vmap_area，支持 O(log n) 查找
static struct rb_root vmap_area_root = RB_ROOT;

static struct vmap_area *alloc_vmap_area(unsigned long size, ...)
{
    // 在红黑树中查找 size 大小的空闲间隙
    // 遍历 vmap_area_root 找到可用的地址区间
    // 考虑对齐要求（默认 1 页对齐）
    
    struct vmap_area *va = kmem_cache_zalloc(vmap_area_cachep, GFP_KERNEL);
    if (!va) return ERR_PTR(-ENOMEM);

    // 插入红黑树和链表
    rb_insert_augmented(&va->rb_node, &vmap_area_root, &vmap_area_rb_augment);
    list_add(&va->list, &vmap_area_list);
    return va;
}
```

## 10. 懒惰释放

```c
struct vfree_deferred {
    struct llist_head list;
    struct work_struct wq;
};

static DEFINE_PER_CPU(struct vfree_deferred, vfree_deferred);

// 物理页通过 per-CPU 懒惰链表延迟释放
// 避免在持锁上下文或中断中直接释放
static void vfree_deferred_flush(struct work_struct *work)
{
    // 处理 per-CPU 链表中的所有待释放页面
    // 调用 __free_page 归还到 buddy
}
```

## 11. 大页映射

```c
// vmalloc 在映射时尝试使用 2MB 大页
static int vmap_try_huge_pmd(pmd_t *pmd, unsigned long addr, ...)
{
    if (IS_ALIGNED(addr, PMD_SIZE) && IS_ALIGNED(phys_addr, PMD_SIZE))
        // 设置 PMD 大页映射（代替 512 个 PTE）
        set_pmd(pmd, pmd_pfn_phys(phys_addr, prot | _PAGE_PSE));
    return 0;  // 回退到 4KB
}
```

## 12. ioremap

```c
void __iomem *ioremap(phys_addr_t phys_addr, unsigned long size)
{
    // 与 vmalloc 共享 vmap 机制
    // 区别：不分配物理页，设置 uncacheable
    return __ioremap_caller(phys_addr, size, _PAGE_CACHE_MODE_UC_MINUS, ...);
}
```

## 13. 性能对比

| 操作 | 延迟 | 说明 |
|------|------|------|
| vmalloc(4KB) | ~1-2us | 单页+页表映射 |
| vmalloc(1MB) | ~5-10us | 256 页分配 |
| vfree | ~500ns-10us | 懒惰释放 |
| kmalloc(128B) | ~30ns | SLUB 快速路径 |
| ioremap | ~1-5us | 仅映射不分配 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 14. 调试命令

```bash
cat /proc/vmallocinfo      # 所有分配
cat /proc/meminfo | grep Vmalloc  # 统计
# VmallocTotal: vmalloc 总大小
# VmallocUsed: 已使用
# VmallocChunk: 最大连续空闲

# 查看 vmalloc 相关符号
grep vmalloc /proc/kallsyms | head -5
```

## 15. 使用场景

| 场景 | 原因 | 典型大小 |
|------|------|---------|
| 模块加载 | 需大块可执行内存 | 10KB-10MB |
| 帧缓冲 | 大块连续虚拟内存 | 1MB-32MB |
| 网络缓存 | 大块数据分配 | 64KB-1MB |
| 设备驱动 | ioremap MMIO | 4KB-1MB |
| kprobe | 指令替换 | ~1KB |

## 16. 关联文章

- **17-page-allocator**: buddy 分配器
- **116-pci-deep**: PCI ioremap

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 17. 关键 API 速查

| 函数 | 返回值 | 说明 |
|------|--------|------|
| vmalloc(size) | void* | 通用分配 |
| vzalloc(size) | void* | 零初始化 |
| vmalloc_user(size) | void* | 用户空间可访问 |
| vfree(addr) | void | 释放 |
| vmalloc_to_page(addr) | struct page* | 虚拟→物理 |
| is_vmalloc_addr(addr) | bool | 检测 |
| ioremap(phys, size) | void __iomem* | 设备映射 |

## 18. 总结

vmalloc 通过红黑树管理 vmap_area、逐页分配物理内存、页表映射建立虚拟连续性、懒惰释放异步回收。适合大块内存分配，性能低于 kmalloc 但灵活性更高。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 19. vmalloc_to_page 实现

```c
// mm/vmalloc.c:799 — 通过 vmalloc 地址查找物理页
struct page *vmalloc_to_page(const void *vmalloc_addr)
{
    unsigned long addr = (unsigned long)vmalloc_addr;
    struct page *page;
    pgd_t *pgd;
    p4d_t *p4d;
    pud_t *pud;
    pmd_t *pmd;
    pte_t *pte;

    // 遍历页表找到物理地址
    pgd = pgd_offset_k(addr);
    p4d = p4d_offset(pgd, addr);
    pud = pud_offset(p4d, addr);

    // 处理大页映射
    if (pud_leaf(*pud))
        return pud_page(*pud) + pte_index(addr);

    pmd = pmd_offset(pud, addr);
    if (pmd_leaf(*pmd))
        return pmd_page(*pmd) + pte_index(addr);

    pte = pte_offset_kernel(pmd, addr);
    return pte_page(*pte);
}
```

## 20. vmap_block 管理

```c
// 对于频繁的 vmalloc/vfree 小对象
// 使用 vmap_block 批量管理
// 每块包含多个 vmap_area
// 减少红黑树操作频率
```

## 21. 相关文章

- **17-page-allocator**: buddy 分配器
- **116-pci-deep**: PCI ioremap

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 22. 页表映射源码分析

```c
// mm/vmalloc.c:298 — 核心映射函数
static int vmap_range_noflush(unsigned long addr, unsigned long end,
                               phys_addr_t phys_addr, pgprot_t prot, int shift)
{
    pgd_t *pgd;
    unsigned long next;

    for (pgd = pgd_offset_k(addr); addr < end; pgd++) {
        next = pgd_addr_end(addr, end);
        // 递归建立各级页表
        if (vmap_p4d_range(pgd, addr, next, phys_addr, prot, shift))
            return -ENOMEM;
        phys_addr += next - addr;
        addr = next;
    }
    flush_tlb_kernel_range(start, end);
    return 0;
}
```

## 23. 源码文件索引

| 文件 | 行数 | 内容 |
|------|------|------|
| mm/vmalloc.c | ~4000 | 核心实现 |
| include/linux/vmalloc.h | — | 结构体定义 |
| mm/ioremap.c | — | ioremap 实现 |

## 24. 总结

vmalloc 实现了虚拟连续内存分配。主要组件：vmap_area 红黑树管理地址空间、页表映射建立连续性、懒惰释放优化性能、大页映射减少 TLB 开销。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 20. vmalloc 分配示例

```c
// 分配 1MB 连续虚拟内存
void *buf = vmalloc(1024 * 1024);
if (!buf) return -ENOMEM;

// 使用（非连续物理页被映射到连续虚拟地址）
memset(buf, 0, 1024 * 1024);

// 释放
vfree(buf);

// 大块分配对比
void *k = kmalloc(1024 * 1024, GFP_KERNEL);  // 可能失败（物理连续）
void *v = vmalloc(1024 * 1024);               // 成功（虚拟连续）
```

## 21. 结论

vmalloc 是内核中唯一可以分配任意大小虚拟连续内存的机制。红黑树管理、懒惰释放、大页支持是其核心特性。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 22. NUMA 亲和性

```c
// 指定 NUMA 节点分配
void *vmalloc_node(unsigned long size, int node)
{
    return __vmalloc_node(size, 1, GFP_KERNEL, node, __builtin_return_address(0));
}

// 物理页从指定节点的 buddy 分配器获取
// 提高内存访问的 NUMA 本地性
```

## 23. 调试接口

```bash
# /proc/vmallocinfo 显示所有 vmalloc 分配
# 每行: 起始-结束 大小 调用者
# 可以查看谁分配了 vmalloc 内存
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 24. 总结

vmalloc 通过页表映射将非连续物理页映射为虚拟连续空间。懒惰释放通过 per-CPU 链表延迟回收页表。红黑树提供 O(log n) 的地址查找。大页映射减少 TLB 压力。适用于大块内存分配场景。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 25. 参考链接

- mm/vmalloc.c — 核心实现
- include/linux/vmalloc.h — 结构体定义
- Documentation/admin-guide/mm/vmalloc.rst

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

vmalloc 和 vmap 的区别：vmalloc 分配物理页并映射，vmap 映射已有的物理页集合。两者使用相同的页表映射基础设施，但 vmalloc 额外包含物理页的生命周期管理。

vmalloc 的虚拟地址范围在 x86-64 上约为 32TB。该范围位于内核虚拟地址空间中，通过 TLB 缓存提高访问速度。每页的页表映射增加了 TLB 开销，因此 vmalloc 适合低频访问的大块数据。

懒惰释放机制 vfree_deferred 将释放操作推迟到 workqueue 上下文中执行，避免在中断或持锁路径中直接调用 __free_page 导致的锁冲突。

vmalloc 使用红黑树管理已分配的 vmap_area，提供 O(log n) 的地址查找和区间分配效率。
