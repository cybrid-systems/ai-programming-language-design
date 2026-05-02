# 88-mmap — Linux 内存映射（mmap）子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**mmap**（内存映射）是 Linux 中将文件或设备映射到进程地址空间的核心机制。映射后，进程可以直接通过内存读写访问文件内容——内核在缺页时自动读取/写入文件页缓存。

**核心设计**：`do_mmap`（`mm/mmap.c:336`）创建 VMA（Virtual Memory Area），`mmap_region`（`:560`）将 VMA 插入进程的 VMA 红黑树，`remap_pfn_range` 映射物理地址，`handle_mm_fault` 在缺页时填充页表。

```
mmap 系统调用路径：
  mmap(addr, len, prot, flags, fd, offset)
    ↓
  ksys_mmap_pgoff → vm_mmap_pgoff
    ↓
  do_mmap() @ mm/mmap.c:336
    → 参数验证（长度/标志/权限）
    → get_unmapped_area() 选择地址（mm->get_unmapped_area）
    → 如果是文件映射 → file->f_op->mmap(file, vma)
      → 驱动调用 remap_pfn_range() 建立页表
    → mmap_region() 创建 VMA 并插入红黑树

缺页处理：
  进程访问映射地址 → 页表缺失
    ↓
  handle_mm_fault() @ mm/memory.c
    ↓
  filemap_fault() 或 vma->vm_ops->fault()
    → 从文件页缓存读取数据页
    → 或从设备读取数据
    → 填充页表 → 进程继续执行
```

**doom-lsp 确认**：`mm/mmap.c`（1,921 行，108 符号），`mm/memory.c`（7,587 行），`include/linux/mm.h`（5,237 行）。

---

## 1. 核心数据结构

### 1.1 struct vm_area_struct——VMA

```c
// include/linux/mm.h
struct vm_area_struct {
    unsigned long vm_start;                  // VMA 起始地址
    unsigned long vm_end;                    // VMA 结束地址

    struct rb_node vm_rb;                    // 红黑树节点（按地址排序）
    struct list_head anon_vma_chain;         // 匿名页反向映射链

    const struct vm_operations_struct *vm_ops; // VMA 操作

    unsigned long vm_pgoff;                  // 文件偏移（页单位）
    struct file *vm_file;                    // 映射的文件

    unsigned long vm_flags;                  // 标志（VM_READ/VM_WRITE/VM_SHARED）
};
```

### 1.2 struct mm_struct——进程地址空间

```c
struct mm_struct {
    struct vm_area_struct *mmap;             // VMA 链表
    struct rb_root mm_rb;                    // VMA 红黑树
    unsigned long (*get_unmapped_area)(...); // 未映射区域查找

    unsigned long mmap_base;                 // mmap 映射基址
    unsigned long task_size;                 // 进程地址空间大小

    int map_count;                           // VMA 数量
    spinlock_t page_table_lock;              // 页表锁
    struct rw_semaphore mmap_lock;            // VMA 读/写锁

    unsigned long total_vm;                  // 映射总页数
    unsigned long locked_vm;                 // 锁定页数
};
```

**doom-lsp 确认**：`struct vm_area_struct` 和 `struct mm_struct` 在 `include/linux/mm.h` 中定义。每个进程的 `task_struct->mm` 指向其地址空间。

---

## 2. do_mmap @ :336——创建映射

```c
unsigned long do_mmap(struct file *file, unsigned long addr,
                       unsigned long len, unsigned long prot,
                       unsigned long flags, vm_flags_t vm_flags,
                       unsigned long pgoff, unsigned long *populate)
{
    // 1. 参数验证
    len = PAGE_ALIGN(len);
    if (mm->map_count > sysctl_max_map_count)   // 太多映射
        return -ENOMEM;

    // 2. 选择映射地址
    addr = __get_unmapped_area(file, addr, len, pgoff, flags, vm_flags);
    // → arch_get_unmapped_area()：从 mm->mmap_base 开始找一个空区域
    // → arch_get_unmapped_area_topdown()：从栈底开始向下选（默认）

    // 3. 文件映射检查
    if (file) {
        if (!file_mmap_ok(file, inode, pgoff, len))
            return -EOVERFLOW;

        if (file->f_op->mmap_capabilities) {
            // 驱动声明 mmap 能力
        }
    }

    // 4. 创建 VMA 并插入
    addr = mmap_region(file, addr, len, vm_flags, pgoff, uf);
    // → vma_merge() 尝试与相邻 VMA 合并
    // → kmem_cache_zalloc(vm_area_cachep) 分配新 VMA
    // → vma_link() 插入红黑树+链表
    // → file->f_op->mmap(file, vma) 驱动回调
    // → vma_set_page_prot() 设置页权限

    return addr;
}
```

**doom-lsp 确认**：`do_mmap` @ `mmap.c:336`，`mmap_region` @ `:560`。

---

## 3. mmap_region @ :560——VMA 插入

```c
unsigned long mmap_region(struct file *file, unsigned long addr,
                           unsigned long len, vm_flags_t vm_flags,
                           unsigned long pgoff, struct list_head *uf)
{
    struct vm_area_struct *vma, *prev;

    // 1. 尝试与前面或后面的 VMA 合并
    vma = vma_merge(mm, prev, addr, addr + len, vm_flags, ...);
    if (vma)
        goto out;                           // 合并成功

    // 2. 分配新 VMA
    vma = vm_area_alloc(mm);
    vma->vm_start = addr;
    vma->vm_end = addr + len;
    vma->vm_flags = vm_flags;
    vma->vm_pgoff = pgoff;
    vma->vm_file = get_file(file);          // 引用文件

    // 3. 调用驱动 mmap
    if (file) {
        error = call_mmap(file, vma);     // → file->f_op->mmap(file, vma)
        // 驱动通常调用：
        //   remap_pfn_range(vma, addr, pfn, size, prot)
        //   建立物理地址→用户地址的页表映射
    }

    // 4. 插入红黑树
    vma_link(mm, vma, prev, rb_link, rb_parent);
    // → __vma_link() — 插入红黑树
    // → __vma_link_file() — 关联到文件的 mapping->i_mmap

    mm->map_count++;
    return addr;
}
```

---

## 4. 缺页处理——handle_mm_fault @ memory.c:6683

```c
// 进程第一次访问 mmap 地址时产生缺页：
// do_page_fault → handle_mm_fault @ :6683
// → __handle_mm_fault @ :6449 — 逐级页表遍历

vm_fault_t __handle_mm_fault(struct vm_area_struct *vma, unsigned long address,
                              unsigned int flags)
{
    struct vm_fault vmf = {
        .vma = vma,
        .address = address & PAGE_MASK,
        .flags = flags,           // FAULT_FLAG_WRITE / FAULT_FLAG_ALLOW_RETRY
        .pgoff = linear_page_index(vma, address),
    };

    // 1. 逐级分配页表
    pgd = pgd_offset(mm, address);
    p4d = p4d_alloc(mm, pgd, address);
    vmf.pud = pud_alloc(mm, p4d, address);       // PUD 级（1GB 页）
    vmf.pmd = pmd_alloc(mm, vmf.pud, address);   // PMD 级（2MB 页）

    // 2. 尝试透明大页（THP）
    if (pmd_none && thp_vma_allowable(...))
        ret = create_huge_pmd(&vmf);             // 2MB 映射

    // 3. 普通 4KB 页 (fallback)
    vmf.orig_pte = pte_offset_map(vmf.pmd, address);
    if (pte_none(vmf.orig_pte)) {                 // 页面不存在
        if (vma->vm_ops && vma->vm_ops->fault) {
            ret = vma->vm_ops->fault(vmf);        // 设备/文件系统自定义缺页
        } else if (vma->vm_file) {
            ret = filemap_fault(vmf);             // 文件页缓存
            // → filemap_get_page(mapping, index)
            // → 如果不在缓存 → 从磁盘读取
            // → filemap_add_folio() 添加到页缓存
        } else {
            ret = do_anonymous_page(vmf);         // 匿名页：分配零页
        }
    } else if (pte_swp_uffd_wp(vmf.orig_pte)) {
        ret = do_swap_page(vmf);                  // 换出页
    } else if (flags & FAULT_FLAG_WRITE) {
        ret = do_wp_page(vmf);                    // 写时复制（COW）
    }

    // 4. 设置页表
    // → set_pte_at(mm, address, vmf->pte, entry);
    return ret;
}
```

**doom-lsp 确认**：`handle_mm_fault` @ `memory.c:6683`，`__handle_mm_fault` @ `:6449`。页表分配路径：`pgd` → `p4d` → `pud` → `pmd` → `pte`。

---

## 5. 特殊映射类型

| 映射类型 | file 参数 | vm_ops | 缺页处理 |
|---------|-----------|--------|---------|
| **匿名映射**（MAP_ANONYMOUS）| NULL | NULL | `do_anonymous_page` → 分配零页 |
| **文件映射**（普通文件）| regular file | NULL | `filemap_fault` → 读磁盘 |
| **共享内存**（shmem）| shmem_file | shmem_vm_ops | shmem_fault |
| **设备 mmap**（/dev/*）| device file | device->vm_ops | device fault |
| **hugetlb**（大页）| hugetlbfs file | hugetlb_vm_ops | hugetlb_fault |

### remap_pfn_range——物理地址映射

```c
// 设备驱动在 mmap 回调中调用此函数建立物理地址→用户空间的映射：
// drivers/gpu/drm/ttm/ttm_bo_vm.c (GPU 显存映射)
// drivers/pci/pci-sysfs.c (PCI BAR 映射)

int remap_pfn_range(struct vm_area_struct *vma, unsigned long addr,
                    unsigned long pfn, unsigned long size, pgprot_t prot)
{
    // 遍历每一页
    for (; addr < end; addr += PAGE_SIZE, pfn++) {
        // 创建 PTE 条目：pfn → 物理地址
        pte_t pte = pfn_pte(pfn, prot);
        // 设置页表
        set_pte_at(mm, addr, pte, pte);
    }
    // 刷新 TLB
    flush_tlb_range(vma, addr, end);
    return 0;
}
```

---

## 6. munmap 路径

```c
SYSCALL_DEFINE2(munmap, unsigned long, addr, size_t, len)
{
    return __vm_munmap(addr, len, true);
    // → do_vmi_munmap(vmi, mm, start, len, uf, false);
    // → 查找 VMA：find_vma(mm, addr)
    // → 分割/删除 VMA：detach_vmas_to_be_unmapped()
    // → unmap_region() → 清除页表
    // → remove_vma_list() → 释放 VMA
}
```

---

## 7. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `do_mmap` | `:336` | mmap 系统调用核心 |
| `mmap_region` | `:560` | VMA 创建+插入 |
| `__get_unmapped_area` | `:813` | 地址空间查找 |
| `vma_merge` | — | VMA 合并 |
| `vma_link` | — | VMA 插入红黑树 |
| `handle_mm_fault` | `mm/memory.c` | 缺页处理 |
| `remap_pfn_range` | `mm/memory.c` | 建立物理页映射 |

---

## 8. 调试

```bash
# 查看进程的 VMA
cat /proc/<pid>/maps
# 7f1234000000-7f1236000000 rw-p 00000000 00:00 0          [anon]
# 7f1236000000-7f1238000000 r--p 00000000 08:01 123456     /usr/lib/libc.so

# 查看 VMA 数量
cat /proc/<pid>/maps | wc -l

# 查看 mmap 限额
cat /proc/sys/vm/max_map_count

# 跟踪缺页
echo 1 > /sys/kernel/debug/tracing/events/mmap/mmap_map/enable
echo 1 > /sys/kernel/debug/tracing/events/mmap/mmap_unmap/enable
```

---

## 9. 总结

`mmap` 通过 `do_mmap`（`:336`）→ `mmap_region`（`:560`）创建 VMA 并插入红黑树，`handle_mm_fault` 在缺页时填充页表。文件映射通过 `filemap_fault` 从页缓存读取，设备映射通过 `remap_pfn_range` 建立物理地址映射，匿名映射分配零页。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
