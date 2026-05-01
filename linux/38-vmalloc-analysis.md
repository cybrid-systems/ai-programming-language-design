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

## 8. ioremap——设备内存映射

```c
// ioremap 将设备 MMIO 区域映射到内核虚拟地址空间
void __iomem *ioremap(phys_addr_t phys_addr, unsigned long size)
{
    return __ioremap_caller(phys_addr, size, _PAGE_CACHE_MODE_UC_MINUS,
                             __builtin_return_address(0));
}

// 映射完成后，通过 readl/writel 访问设备寄存器
void __iomem *base = ioremap(0xfe000000, SZ_4K);
u32 val = readl(base + 0x10);   // 读设备寄存器
writel(0x1, base + 0x00);       // 写设备寄存器
iounmap(base);                   // 取消映射
```

## 9. 物理连续 vs 非连续

```c
// 物理连续分配（DMA 需要）：
dma_addr_t dma_handle;
void *cpu_addr = dma_alloc_coherent(dev, size, &dma_handle, GFP_KERNEL);
// → 返回虚拟地址连续、物理地址也连续的内存
// → 适合 DMA 操作

// vmalloc 的物理地址不连续：
void *virt = vmalloc(size);
// → 虚拟地址连续，物理地址可能不连续
// → 不能直接用于 DMA
// → 对于大多数 CPU 访问场景没问题
```

## 10. 调试

```bash
# 查看 vmalloc 区域使用
$ cat /proc/vmallocinfo
0xffffc90000000000-0xffffc90000100000 1048576  module_alloc+0x5c/0x60
0xffffc90000200000-0xffffc90000300000 1048576  module_alloc+0x5c/0x60

# 查看虚拟内存区域分布
$ cat /proc/meminfo | grep Vmalloc
VmallocTotal:   34359738367 kB
VmallocUsed:        12345 kB
```

## 11. 源码文件索引

| 文件 | 内容 |
|------|------|
| mm/vmalloc.c | vmalloc 核心 |
| include/linux/vmalloc.h | API |
| mm/ioremap.c | ioremap 实现 |


## 12. vmap 区块管理

```c
// mm/vmalloc.c — vmap_area 管理
// 使用红黑树组织所有已分配的 VMAP 区域
static struct rb_root vmap_area_root = RB_ROOT;
static struct list_head vmap_area_list = LIST_HEAD_INIT(vmap_area_list);

// 分配 vmap_area
static struct vmap_area *alloc_vmap_area(unsigned long size, ...)
{
    struct vmap_area *va = kmem_cache_alloc(vmap_area_cachep, GFP_NOWAIT);
    
    // 在红黑树中查找空闲区间
    // → 使用 RB 树快速定位
    // → 处理可能的碎片（相邻空闲区间合并）
    
    // 插入红黑树
    rb_insert_augmented(&va->rb_node, &vmap_area_root, &vmap_area_rb_augment);
    list_add(&va->list, &vmap_area_list);
    
    return va;
}
```

## 13. 物理页的懒惰清理

```c
// vmalloc 的物理页释放策略
// 不是立即回收到 buddy
// 而是缓存到 llist（lock-free 链表）中异步释放

// 缓存释放：将页面放入惰性链表
static DEFINE_PER_CPU(struct page *, vfree_deferred_pages[FREE_N_PAGES]);

// flush_work 周期性处理
static void vfree_deferred_flush(struct work_struct *work)
{
    struct page *page;
    while ((page = llist_del_first(&vfree_deferred_pages))) {
        __free_page(page);
    }
}
```

  
---

## 15. 性能与最佳实践

| 操作 | 延迟 | 说明 |
|------|------|------|
| 简单审计日志 | ~1μs | 单一系统调用事件 |
| 规则匹配 | ~100ns | 线性扫描规则列表 |
| 路径名解析 | ~1-5μs | 每次系统调用需解析 |
| netlink 发送 | ~1μs | skb 分配+传递 |

## 16. 关联参考

- 内核文档: Documentation/admin-guide/audit/
- 工具: auditd, auditctl, ausearch, aureport
- 配置: /etc/audit/

