# mmap — 内存映射深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/mmap.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**mmap** 将文件或匿名内存映射到进程地址空间，是现代 Linux 内存管理的基础。

---

## 1. sys_mmap — 系统调用

```c
// mm/mmap.c — sys_mmap_pgoff
SYSCALL_DEFINE6(mmap, unsigned long, addr, unsigned long, len,
                unsigned long, prot, unsigned long, flags,
                unsigned long, fd, unsigned long, off)
{
    // 1. 验证参数
    if (len > TASK_SIZE)
        return -ENOMEM;

    // 2. 调用 vm_mmap_pgoff
    return vm_mmap_pgoff(file, addr, len, prot, flags, off >> PAGE_SHIFT);
}
```

---

## 2. vm_mmap_pgoff — 核心映射

```c
// mm/mmap.c — vm_mmap_pgoff
unsigned long vm_mmap_pgoff(struct file *file, unsigned long addr,
                            unsigned long len, unsigned long prot,
                            unsigned long flags, unsigned long pgoff)
{
    unsigned long ret;
    struct mm_struct *mm = current->mm;

    // 1. 获取写信号量
    down_write(&mm->mmap_lock);

    // 2. 调用 do_mmap
    ret = do_mmap(file, addr, len, prot, flags, pgoff);

    up_write(&mm->mmap_lock);

    return ret;
}
```

---

## 3. do_mmap — 创建 VMA

```c
// mm/mmap.c — do_mmap
unsigned long do_mmap(struct file *file, unsigned long addr,
                      unsigned long len, unsigned long prot,
                      unsigned long flags, unsigned long pgoff)
{
    struct vm_area_struct *vma;

    // 1. 检查参数
    if ((prot & PROT_READ) && (prot & PROT_WRITE))
        ; // 可读可写

    // 2. 分配 VMA
    vma = kmem_cache_zalloc(vm_area_allocator, GFP_KERNEL);

    // 3. 初始化 VMA
    vma->vm_start = addr;
    vma->vm_end = addr + len;
    vma->vm_flags = vm_flags_for_prot(prot, flags);
    vma->vm_page_prot = protection_map[vm_flags & 0xf];
    vma->vm_pgoff = pgoff;

    // 4. 调用文件特定 mmap（如果文件）
    if (file)
        file->f_op->mmap(file, vma);

    // 5. 插入红黑树
    vma_mtree_insert(vma, &mm->mm_rb);

    // 6. 更新统计
    vm_stat_update(mm, vma);

    return addr;
}
```

---

## 4. 完整文件索引

| 文件 | 函数 |
|------|------|
| `mm/mmap.c` | `sys_mmap_pgoff`、`vm_mmap_pgoff`、`do_mmap` |