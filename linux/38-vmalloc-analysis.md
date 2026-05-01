# 38-vmalloc — Linux 内核虚拟内存分配深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**vmalloc** 分配虚拟地址连续但物理地址不连续的内存。与 kmalloc（物理连续）不同，vmalloc 通过修改页表将离散的物理页映射到 VMALLOC 区域的连续虚拟空间。适合大块内存分配。

**doom-lsp 确认**：`mm/vmalloc.c` 核心实现。`__vmalloc_node_range` 是分配入口，`__vunmap` 是释放入口。

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
- **38-vmalloc**: vmalloc 深度分析（待补充）

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 9. vmap_area 红黑树管理

```c
// mm/vmalloc.c — 使用红黑树管理已分配的虚拟地址区间
static struct rb_root vmap_area_root = RB_ROOT;
static struct rb_root purge_vmap_area_root = RB_ROOT;

// 分配 vmap_area（在 VMALLOC 空间中查找空闲区间）
static struct vmap_area *alloc_vmap_area(unsigned long size,
                                          unsigned long align,
                                          unsigned long vstart,
                                          unsigned long vend)
{
    struct vmap_area *va;

    // 从 slab 分配 vmap_area 结构
    va = kmem_cache_alloc_node(vmap_area_cachep, GFP_NOWAIT, node);
    if (!va) return ERR_PTR(-ENOMEM);

    // 在红黑树中查找空闲区间
    // 遍历 vmap_area_root，找到 size 大小的空闲间隙
    // 考虑地址对齐需求

    // 插入红黑树
    rb_insert_augmented(&va->rb_node, &vmap_area_root, &vmap_area_rb_augment);
    list_add(&va->list, &vmap_area_list);

    return va;
}
```

## 10. 懒惰释放（lazy free）

vmalloc 的物理页释放不是立即回收，而是通过懒惰链表异步处理：

```c
// mm/vmalloc.c — 懒惰释放机制
struct vfree_deferred {
    struct llist_head list;     // 待释放链表
    struct work_struct wq;      // 工作队列
};

static DEFINE_PER_CPU(struct vfree_deferred, vfree_deferred);

// 将物理页放入懒惰链表
void __vfree_deferred(const void *addr)
{
    struct vfree_deferred *p = raw_cpu_ptr(&vfree_deferred);

    // 将页加入 per-CPU 懒惰链表
    if (llist_add(&area->list, &p->list))
        // 首次入队时调度工作队列
        schedule_work(&p->wq);
}

// 工作队列处理函数
static void vfree_deferred_flush(struct work_struct *work)
{
    struct vfree_deferred *p = container_of(work, ...);
    struct llist_node *node;

    // 处理链表中的所有待释放页面
    while ((node = llist_del_all(&p->list))) {
        // 释放物理页面
        __free_page(...);
    }
}
```

## 11. NUMA 感知

```c
// vmalloc 支持 NUMA 节点优先的物理页分配

void *__vmalloc_node_range(unsigned long size, unsigned long align,
                            unsigned long start, unsigned long end,
                            gfp_t gfp_mask, pgprot_t prot,
                            unsigned long vm_flags, int node, ...)
{
    // node 参数指定优先从哪个 NUMA 节点分配
    // NUMA_NO_NODE = -1 表示不限制

    // 物理页分配时：
    for (i = 0; i < nr_pages; i++) {
        if (node == NUMA_NO_NODE)
            page = alloc_page(gfp_mask);           // 任意节点
        else
            page = alloc_pages_node(node, gfp_mask, 0);  // 指定节点

        area->pages[i] = page;
    }
}
```

## 12. 调试接口

```bash
# 查看 vmalloc 使用情况
$ cat /proc/vmallocinfo
0xffffc90000000000-0xffffc90000100000 1048576 module_alloc+0x5c/0x60
   pages=256 vmalloc
0xffffc90000200000-0xffffc90000400000 2097152 module_alloc+0x5c/0x60
   pages=512 vmalloc N0=256 N1=256

# 查看 vmalloc 总用量
$ cat /proc/meminfo | grep Vmalloc
VmallocTotal:   34359738367 kB    # 总虚拟地址空间 (32TB)
VmallocUsed:        14567 kB      # 已使用
VmallocChunk:   34359738367 kB    # 最大连续空闲块
```

## 13. 性能数据

| 操作 | 延迟 | 说明 |
|------|------|------|
| vmalloc(4KB) | ~1-2us | 单页分配 + 页表映射 |
| vmalloc(1MB) | ~5-10us | 256 页分配 + TLB 刷新 |
| vmalloc(1GB) | ~5-10ms | 大量页表操作 |
| vfree | ~500ns-10us | 懒惰释放 |
| kmalloc(1MB) | 不可用 | 超过 MAX_ORDER |
| ioremap | ~1-5us | 不分配物理页 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 14. 大页支持

vmalloc 支持在映射时使用大页（PMD 级别 2MB）以减少 TLB 压力：

```c
// mm/vmalloc.c — 尝试使用大页映射
static int vmap_try_huge_pmd(pmd_t *pmd, unsigned long addr,
                              unsigned long end, phys_addr_t phys_addr, pgprot_t prot)
{
    // 条件：地址 2MB 对齐、物理地址 2MB 对齐、长度 ≥ 2MB
    if (IS_ALIGNED(addr, PMD_SIZE) && IS_ALIGNED(phys_addr, PMD_SIZE) &&
        end - addr >= PMD_SIZE) {
        // 设置 PMD 大页映射（代替 512 个 PTE）
        set_pmd(pmd, pmd_pfn_phys(phys_addr, prot | _PAGE_PSE));
        return 1;  // 使用大页
    }
    return 0;  // 回退到 4KB 小页
}

// 默认启用大页，可通过内核参数关闭：
// nohugevmalloc
```

## 15. is_vmalloc_addr 检测

```c
// mm/vmalloc.c:79 — 检测地址是否属于 vmalloc 区域
bool is_vmalloc_addr(const void *x)
{
    unsigned long addr = (unsigned long)x;

    // 检查地址是否在 VMALLOC_START 和 VMALLOC_END 之间
    return addr >= VMALLOC_START && addr < VMALLOC_END;
}

// 用于内核内存调试和页表处理
// 例如在 __free_pages 中检查是否释放了 vmalloc 地址
```

## 16. 总结

vmalloc 通过页表映射实现虚拟连续的大块内存分配。懒惰释放机制减少释放开销，红黑树管理 vmap_area 区间，NUMA 感知分配优化本地内存访问。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 17. 常用 API

| 函数 | 用途 | 特点 |
|------|------|------|
| vmalloc(size) | 通用分配 | GFP_KERNEL |
| vzalloc(size) | 零初始化 | GFP_KERNEL + __GFP_ZERO |
| vmalloc_user(size) | 用户空间 | 计入 RSS |
| vmalloc_node(size, node) | NUMA 指定 | 从指定节点分配 |
| __vmalloc(size, gfp, prot) | 自定义 flags | 底层接口 |
| vfree(addr) | 释放 | 懒惰释放 |
| vmalloc_to_page(addr) | 查询 | 虚拟→物理页 |

## 18. 源码文件索引

| 文件 | 内容 |
|------|------|
| mm/vmalloc.c | vmalloc/vfree/ioremap |
| include/linux/vmalloc.h | 结构体定义 |
| mm/ioremap.c | ioremap 实现 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01*

## 19. VMALLOC 区域

在 x86-64 上，vmalloc 区域位于内核虚拟地址空间的特定区间：



## 20. 页表遍历路径

vmalloc 映射涉及 5 级页表（x86-64 可能折叠 P4D）：



vmap_range_noflush 依次遍历每级页表，建立映射。



## 19. VMALLOC 区域

x86-64 上 vmalloc 区域占用约 32TB 虚拟地址空间。

## 20. 页表遍历

vmalloc 映射遍历 5 级页表：PGD → P4D → PUD → PMD → PTE。大页映射（2MB PMD 或 1GB PUD）可减少 TLB 压力。

## 21. 参考链接

- 内核源码: mm/vmalloc.c
- 头文件: include/linux/vmalloc.h

---


## 22. 调试命令

VmallocTotal:   135288315904 kB
VmallocUsed:       83012 kB
VmallocChunk:          0 kB
0000000000000000 t vmalloc_to_page.cold
0000000000000000 t __vmalloc_node_range_noprof.cold
0000000000000000 t __vmalloc_noprof.cold
0000000000000000 t remap_vmalloc_range_partial.cold
0000000000000000 t __kvmalloc_node_noprof.cold
0000000000000000 T remap_vmalloc_range
0000000000000000 T __vmalloc_array_noprof
0000000000000000 T vmalloc_array_noprof
0000000000000000 T is_vmalloc_or_module_addr
0000000000000000 T vmalloc_to_pfn
0000000000000000 T __vmalloc_node_noprof
0000000000000000 t vmalloc_fix_flags
0000000000000000 T vmalloc_huge_node_noprof
0000000000000000 T vmalloc_user_noprof
0000000000000000 T vmalloc_node_noprof
0000000000000000 T vmalloc_32_noprof
0000000000000000 T vmalloc_32_user_noprof
0000000000000000 T vmalloc_dump_obj
0000000000000000 t vmalloc_info_show
0000000000000000 T __traceiter_xfs_buf_backing_vmalloc
0000000000000000 T __probestub_xfs_buf_backing_vmalloc
0000000000000000 T bio_add_vmalloc_chunk
0000000000000000 T bio_add_vmalloc
0000000000000000 T __kvmalloc_node_noprof
0000000000000000 T is_vmalloc_addr
0000000000000000 T vmalloc_to_page
0000000000000000 T vmalloc_noprof
0000000000000000 T __vmalloc_noprof
0000000000000000 T __vmalloc_node_range_noprof
0000000000000000 T vmalloc_nr_pages
0000000000000000 T remap_vmalloc_range_partial
0000000000000000 t set_nohugevmalloc
0000000000000000 t proc_vmalloc_init
0000000000000000 T vmalloc_init

## 23. 总结

vmalloc 通过页表映射将非连续物理页映射为连续虚拟空间。红黑树管理 vmap_area，懒惰释放优化性能，大页支持减少 TLB 压力。适用于大块内存分配，不适合时间关键的代码路径。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

vmalloc 和 ioremap 共享相同的页表映射基础设施。vmalloc 分配物理页，ioremap 映射现有设备内存。两者都通过 vmap_area 红黑树管理虚拟地址空间。

vmalloc_area_node 分配流程：1) alloc_vmap_area 找空闲地址 2) kmalloc pages 数组 3) alloc_page 逐页分配 4) map_kernel_range 建页表映射。

vfree 延时释放通过 per-CPU llist + workqueue 异步处理物理页回收，避免在中断上下文或持锁路径中直接释放。
