# 088-mmap — Linux 内存映射（mmap）子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**mmap**（内存映射）是 Linux 中将文件或设备映射到进程地址空间的核心机制。映射后，进程可以直接通过内存读写访问文件内容——内核在缺页时自动从文件页缓存读取或通过 `fault()` 回调从设备获取。

**doom-lsp 确认**：`mm/mmap.c`（108 个符号），`mm/memory.c`（~300 个符号），`include/linux/mm.h`（~500 个符号），`include/linux/mm_types.h`（~200 个符号）。

---

## 1. 核心数据结构

### 1.1 `struct vm_area_struct` (VMA)

（`include/linux/mm_types.h` L932 — doom-lsp 确认）

每个 VMA 描述进程地址空间中的一个连续区间：

```c
struct vm_area_struct {
    unsigned long           vm_start;      // L943 — VMA 起始虚拟地址
    unsigned long           vm_end;        // L945 — VMA 结束虚拟地址

    struct rb_node          vm_rb;         // L949 — 红黑树节点（按地址排序）
    struct list_head        anonymous_list; // L952 — 匿名页链表
    struct list_head        shared;        // L956 — 共享 VMA 链表

    struct address_space    *vm_file;      // L958 — 映射的文件（NULL = 匿名映射）
    unsigned long           vm_pgoff;      // L960 — 文件内的页偏移
    unsigned long           vm_start_pgoff;// L962 — VMA 起始页偏移

    struct mm_struct        *vm_mm;        // L1027 — 所属进程的 mm_struct
    pgprot_t                vm_page_prot;  // L1030 — 页保护位（读写执行）
    unsigned long           vm_flags;      // L1031 — VMA 标志（VM_READ/WRITE/EXEC/SHARED...）

    const struct vm_operations_struct *vm_ops; // L1039 — VMA 操作（open/close/fault/map_pages...）
    unsigned long           vm_policy;     // L1066 — NUMA 内存策略

    struct list_head        vma_list;      // L1088 — 进程 VMA 链表
    struct rb_root_cached   vma_tree_cache;// L1093 — VMA 树缓存
};
```

### 1.2 `struct vm_operations_struct`——VMA 操作

```c
struct vm_operations_struct {
    void    (*open)(struct vm_area_struct *vma);     // VMA 被 fork 复制时
    void    (*close)(struct vm_area_struct *vma);    // VMA 被销毁时
    vm_fault_t (*fault)(struct vm_fault *vmf);       // 缺页处理（核心！）
    vm_fault_t (*map_pages)(struct vm_fault *vmf,    // 批量页表填充
                         pgoff_t start_pgoff, pgoff_t end_pgoff);
    int     (*page_mkwrite)(struct vm_fault *vmf);   // 页面变为可写时
    int     (*set_policy)(...);                       // NUMA 策略
};
```

---

## 2. 完整数据流

### 2.1 mmap 系统调用

```
mmap(addr, len, prot, flags, fd, offset)
  └─ ksys_mmap_pgoff
       └─ vm_mmap_pgoff
            └─ do_mmap(file, addr, len, prot, flags, pgoff)   // mm/mmap.c L336
                 │
                 ├─ 1. 参数验证
                 │    如果 len = 0 → 返回 -EINVAL
                 │    如果 flags 包含 MAP_FIXED 但地址不对齐 → 返回 -EINVAL
                 │
                 ├─ 2. 选择地址
                 │    如果 addr < mmap_min_addr → 修正
                 │    get_unmapped_area(file, addr, len, pgoff, flags)
                 │      → 找到空闲的地址区间
                 │      → 如果 file->f_op->get_unmapped_area 存在，调用文件系统的实现
                 │      → 否则使用通用算法：从 TASK_UNMAPPED_BASE 开始扫描
                 │
                 ├─ 3. 计算保护标志
                 │    vm_flags = calc_vm_prot_bits(prot) | calc_vm_flag_bits(flags)
                 │    // VM_READ | VM_WRITE | VM_EXEC | VM_SHARED ...
                 │
                 ├─ 4. 创建 VMA 并插入进程地址空间
                 │    mmap_region(file, addr, len, vm_flags, pgoff, ...)
                 │      └─ 分配 VMA: kmem_cache_zalloc(vm_area_cachep)
                 │      └─ 设置 vm_start / vm_end / vm_flags / vm_pgoff
                 │      └─ 插入红黑树（vma_tree_cache）和链表
                 │
                 ├─ 5. 文件映射的 mmap 回调
                 │    if (file) {
                 │        // 调用文件系统驱动建立映射
                 │        // 驱动可能立即建立页表（remap_pfn_range）
                 │        // 或延迟到缺页（设置 fault 回调）
                 │        vma->vm_file = file
                 │        vma->vm_ops = file->f_op->mmap(file, vma)
                 │    }
                 │
                 └─ 6. 返回映射地址
                      return addr
```

### 2.2 缺页处理——handle_mm_fault

当进程访问映射区域但页表中没有对应条目时触发：

```
handle_mm_fault(vma, addr, flags, regs)             // mm/memory.c
  └─ __handle_mm_fault(vma, addr, flags)
       └─ 根据 addr 找到对应的 PUD/PMD/PTE 层级
            └─ handle_pte_fault(vma, addr, pte, pmd, flags)
                 │
                 ├─ 如果 PTE 未映射（pte_none）：
                 │    └─ do_fault(vmf)                      // 文件映射缺页
                 │         └─ vma->vm_ops->fault(vmf)       // 驱动处理
                 │              → filemap_fault(vmf)         // 通用文件映射
                 │                   → 查找 page cache
                 │                   → 如果不命中 → 从磁盘读取
                 │                   → add_to_page_cache_lru()
                 │                   → 建立 PTE 映射
                 │
                 ├─ 如果 PTE 是 swap 条目（pte_to_swp_entry）：
                 │    └─ do_swap_page(vmf)                  // 页面被换出
                 │         → swap_read_folio()
                 │         → 建立 PTE 映射
                 │
                 ├─ 如果 PTE 已存在但写入权限不足：
                 │    └─ do_wp_page(vmf)                    // 写时复制
                 │         → 分配新页
                 │         → 复制内容
                 │         → 建立可写 PTE
                 │
                 └─ 如果 PTE 不存在且是匿名页：
                      └─ do_anonymous_page(vmf)             // 匿名映射缺页
                           → alloc_zeroed_user_highpage()
                           → 建立零填充的 PTE
```

### 2.3 munmap 数据流

```
munmap(addr, len)
  └─ do_munmap(mm, addr, len, uf)                   // mm/mmap.c L1062
       └─ __do_munmap(mm, addr, len, uf)
            ├─ 1. 找到 addr 所在 VMA
            ├─ 2. 如果 VMA 被部分覆盖 → 分裂（split VMA）
            │     split_vma(mm, vma, addr, 0)  // 前半部分
            │     split_vma(mm, vma, addr+len, 1) // 后半部分
            └─ 3. 取消映射
                  unmap_region(mm, vma, prev, start, end)
                    └─ unmap_vmas(mmu_gather, vma, start, end)
                    └─ free_pgtables(mmu_gather, vma, ...)
                  └─ remove_vma_list(mm, vma)
```

---

## 3. 四种映射类型

| 类型 | flags | 创建方式 | 数据来源 | 缺页处理 |
|------|-------|---------|---------|---------|
| 匿名映射 | MAP_ANONYMOUS \| MAP_PRIVATE | glibc malloc 大块 | 零填充页 | do_anonymous_page |
| 文件映射 | MAP_SHARED | mmap file | 文件页缓存 | filemap_fault |
| 私有文件映射 | MAP_PRIVATE | mmap file（写时复制） | 文件页缓存 + COW | filemap_fault → COW |
| 设备映射 | MAP_SHARED + 驱动 | mmap /dev/xxx | 设备内存 | 驱动的 fault 回调 |

---

## 4. VMA 红黑树查找

```c
// mm/mmap.c — 通过虚拟地址查找 VMA
struct vm_area_struct *find_vma(struct mm_struct *mm, unsigned long addr)
{
    struct rb_node *rb_node;
    struct vm_area_struct *vma;

    rb_node = mm->vma_tree_cache.rb_root.rb_node; // L1093 缓存
    while (rb_node) {
        vma = rb_entry(rb_node, ...);
        if (vma->vm_end > addr) {
            rb_node = rb_node->rb_left;  // 在左子树中
            if (addr >= vma->vm_start)
                return vma;              // 找到！
        } else {
            rb_node = rb_node->rb_right; // 在右子树中
        }
    }
    return NULL;  // 没找到
}
```

### mmap 与 brk 的地址空间范围

```
进程虚拟地址空间（x86-64）：
  ┌─────────────────────────┐
  │ 代码段 (0x400000)        │
  ├─────────────────────────┤
  │ 数据段                   │
  ├─────────────────────────┤
  │ 堆 (mm->start_brk ~     │ ← brk 控制
  │    mm->brk)             │
  ├─────────────────────────┤
  │    ...                  │
  ├─────────────────────────┤
  │ mmap 区域               │ ← mmap 分配区
  │ (TASK_UNMAPPED_BASE 起) │
  ├─────────────────────────┤
  │ 栈                      │
  └─────────────────────────┘
```

---

## 5. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct vm_area_struct` | include/linux/mm_types.h | 932 |
| `do_mmap()` | mm/mmap.c | 336 |
| `do_munmap()` | mm/mmap.c | 1062 |
| `mmap_region()` | mm/vma.c | 2829 |
| `find_vma()` | mm/mmap.c | 相关 |
| `handle_mm_fault()` | mm/memory.c | 相关 |
| `do_anonymous_page()` | mm/memory.c | 相关 |
| `do_wp_page()` | mm/memory.c | 写时复制 |
| `do_swap_page()` | mm/memory.c | swap 换入 |
| `do_fault()` | mm/memory.c | 文件映射缺页 |
| `filemap_fault()` | mm/filemap.c | 文件页缓存缺页 |
| `sys_mmap_pgoff()` | mm/mmap.c | 613 |
| `remap_pfn_range()` | mm/memory.c | 物理地址映射 |
| `munmap()` | mm/mmap.c | 相关 |
| `get_unmapped_area()` | mm/mmap.c | 相关 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-04 | 内核版本：Linux 7.0-rc1*
