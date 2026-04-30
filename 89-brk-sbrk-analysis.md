# Linux Kernel brk / sbrk 堆管理 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/mmap.c` + `mm/util.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. brk 系统调用

```c
// mm/mmap.c — sys_brk
// int brk(void *addr);

unsigned long sys_brk(unsigned long brk)
{
    struct mm_struct *mm = current->mm;
    unsigned long old_brk = mm->brk;  // 当前堆指针

    // 1. new_brk 必须 >= old_brk
    if (brk < mm->brk)
        return -EINVAL;

    // 2. 扩展堆
    //    arch/powerpc: do_brk() → 直接映射物理页
    //    arch/x86: vm_brk_flags() → mmap_region()
    return do_brk(old_brk, new_brk - old_brk);
}
```

---

## 2. glibc sbrk

```c
// glibc sbrk() 是 brk() 的包装：
void *sbrk(intptr_t increment)
{
    void *old = current_brk;
    if (brk(old + increment) < 0)
        return (void *)-1;
    return old;
}
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `mm/mmap.c` | `sys_brk`、`do_brk` |
| `mm/util.c` | `current_brk` |
