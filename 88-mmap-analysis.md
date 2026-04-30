# Linux Kernel mmap / munmap / remap 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/mmap.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. mmap 系统调用

```c
// mm/mmap.c — sys_mmap
// void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset);

void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset)
{
    // 1. 验证参数
    // 2. 调用 vm_mmap_pgoff
    return vm_mmap_pgoff(file, addr, length, prot, flags, offset >> PAGE_SHIFT);
}
```

---

## 1. vm_mmap_pgoff

```c
// mm/mmap.c — vm_mmap_pgoff
unsigned long vm_mmap_pgoff(struct file *file, unsigned long addr,
    unsigned long len, unsigned long prot,
    unsigned long flag, unsigned long pgoff)
{
    // 1. 获取写锁
    vma = vm_area_alloc();

    // 2. 设置 VMA
    vma->vm_start = addr;
    vma->vm_end = addr + len;
    vma->vm_flags = vm_flags_for_prot(prot, flag);
    vma->vm_file = file;        // 文件映射
    vma->vm_pgoff = pgoff;      // 页偏移

    // 3. 插入 VMA 红黑树
    vma_mtree_insert(vma, mm);

    // 4. 调用文件驱动的 mmap（如果文件）
    if (file && file->f_op->mmap)
        file->f_op->mmap(file, vma);

    return addr;
}
```

---

## 2. remap_file_pages

```c
// 非线性映射：将文件页映射到任意虚拟地址
// 用于稀疏文件访问，避免顺序扫描
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `mm/mmap.c` | `sys_mmap`、`vm_mmap_pgoff`、`vma_mtree_insert` |
