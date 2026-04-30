# Linux Kernel vmalloc vs kmalloc 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/vmalloc.c` + `mm/slab.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 核心差异

| 特性 | `kmalloc` | `vmalloc` |
|------|-----------|-----------|
| 内存来源 | 物理连续 RAM（buddy system）| 虚拟连续，物理不一定连续 |
| 分配大小 | ≤ 8MB（MAX_ORDER=11）| 任意大小（受虚拟地址空间限制）|
| 性能 | 快（物理连续，硬件缓存友好）| 慢（需要建立页表映射）|
| 使用场景 | 内核数据结构、驱动 DMA | 大块缓冲区、模块加载 |
| 睡眠 | 不可睡眠（原子）| 可睡眠（可能触发 page fault）|

---

## 1. vmalloc 核心流程

### 1.1 分配流程

```c
// mm/vmalloc.c — vmalloc_node
void *vmalloc_node(unsigned long size, int node)
{
    return __vmalloc_node_noprof(size, GFP_KERNEL, page_shift, node);
}

// mm/vmalloc.c — __vmalloc_node_noprof
static void *__vmalloc_node_noprof(unsigned long size, gfp_t gfp_mask,
                    unsigned int page_shift, int node)
{
    // 1. 计算需要的页数
    unsigned long nr_pages = get_vmalloc_size(size, page_shift);

    // 2. 分配页数组（每个页的指针）
    struct page **pages = kmalloc_array(nr_pages, sizeof(*pages), ...);

    // 3. 为每页分配物理页
    for (i = 0; i < nr_pages; i++)
        pages[i] = alloc_pages_node(node, gfp_mask, page_shift - PAGE_SHIFT);

    // 4. 建立虚拟地址映射
    //    从 VMALLOC_START 开始找一段空闲虚拟地址
    //    建立 pgd→pud→pmd→pte 页表链
    //    每页映射到分配的物理页
    area = __get_vmalloc_area(size, gfp_mask, page_shift, node);
    if (!area) return NULL;

    // 5. 建立页表映射
    err = vmap_pages_range(addr, addr + size, pages, gfp_mask);

    return (void *)addr;
}
```

### 1.2 vmap — 建立页表映射

```c
// mm/vmalloc.c — vmap_pages_range
int vmap_pages_range(unsigned long addr, unsigned long end,
             struct page **pages, gfp_t gfp_mask)
{
    // 遍历每个物理页
    for (i = 0; i < nr_pages; i++) {
        // 建立页表（pgd/pud/pmd/pte）
        // set_pte(&ptent, mk_pte(pages[i], prot));
        // 确保物理页和虚拟页建立映射关系
    }
}
```

---

## 2. vmalloc 与 kmalloc 性能对比

```
kmalloc（物理连续）：
  - 分配：O(1) — 从 buddy system 的 free_area[order] 取
  - 访问：硬件缓存友好（物理连续，cache line 对齐）
  - 缺点：分配大小受限（最大 2^MAX_ORDER * PAGE_SIZE）

vmalloc（虚拟连续）：
  - 分配：O(n) — 分配 N 个物理页 + 建立 N 个页表项
  - 访问：物理页可能分散，cache 预取效果差
  - 优点：大小无限制（受虚拟地址空间限制 ~VMALLOC_SIZE）
```

---

## 3. vmalloc 地址空间布局

```
进程内核地址空间（64-bit）：

FFFFFFFFFFFFFFFF │ ← 内核镜像（text/data/bss）
                │
                │ ← vmalloc 区域
FFFFFFFFA0000000 │   VMALLOC_START = 0xFFFF A000 0000
                │   VMALLOC_END   = 0xFFFF C000 0000
                │   典型：ioremap、module space、vmalloc
                │
FFFF800000000000 │ ← vmalloc 保留区（线性映射）
                │
                │ ← 直接映射区（PAGE_OFFSET = 0xFFFF 8880 0000 0000）
                │   896MB 线性映射（物理地址直接 + offset）
FFFF880000000000 │
                │
0000000000000000 │ ← 用户空间
```

---

## 4. ioremap — IO 设备映射

```c
// 设备寄存器物理地址 → 虚拟地址
void __iomem *ioremap(phys_addr_t phys_addr, size_t size)
{
    // 与 vmalloc 类似，但：
    // 1. 不分配物理页
    // 2. 将已知的设备物理地址映射到虚拟地址
    // 3. 使用强制的 PAGE_KERNEL_IO 保护（缓存禁用）
    return __ioremap_caller(phys_addr, size, ...);
}

// iounmap
void iounmap(void __iomem *addr)
{
    vunmap(addr);  // 解除映射
}
```

---

## 5. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| vmalloc 建立页表链 | 虚拟连续但物理不一定连续，适合大块内存 |
| vmalloc 可睡眠 | 分配多个物理页可能阻塞，适合进程上下文 |
| kmalloc 原子 | 不可睡眠，保证原子性，适合中断上下文 |
| 线性映射区 | 896MB 直接映射，内核常用数据结构走这里 |

---

## 6. 参考

| 文件 | 内容 |
|------|------|
| `mm/vmalloc.c` | `vmalloc_node`、`vmap_pages_range`、`ioremap` |
| `mm/slab.c` | `kmalloc`、`kmalloc_slab` |
