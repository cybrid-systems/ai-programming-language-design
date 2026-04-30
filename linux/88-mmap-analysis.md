# 88-mmap — 内存映射深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/mmap.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**mmap** 是 POSIX 标准的内存映射接口，将文件或设备映射到进程的虚拟地址空间。Linux 实现包含 `do_mmap()`（核心）、`mmap()` syscall、`brk()` syscall、以及文件映射、匿名映射、hugetlb 映射等多种类型。

---

## 1. sys_mmap — 系统调用入口

### 1.1 SYSCALL_DEFINE6(mmap)

```c
// mm/mmap.c — sys_mmap
SYSCALL_DEFINE6(mmap, unsigned long, addr, unsigned long, len,
                int, prot, int, flags, int, fd, off_t, offset)
{
    struct file *file = NULL;
    unsigned long result = -EINVAL;

    // 1. 权限检查
    if (prot & PROT_WRITE) {
        if (!(flags & MAP_SHARED))
            ; // PROT_WRITE + !MAP_SHARED = private
        if (flags & MAP_SHARED && prot & PROT_READ)
            ; // OK
    }

    // 2. 获取 file（如果是文件映射）
    if (flags & MAP_ANONYMOUS) {
        // 匿名映射，不需要 fd
        file = NULL;
    } else {
        file = fget(fd);
        if (!file)
            return -EBADF;
    }

    // 3. 调用 do_mmap
    result = do_mmap(file, addr, len, prot, flags, offset);

    return result;
}
```

---

## 2. do_mmap — 核心映射函数

### 2.1 do_mmap

```c
// mm/mmap.c — do_mmap
unsigned long do_mmap(struct file *file, unsigned long addr,
                     unsigned long len, unsigned long prot,
                     unsigned long flags, unsigned long pgoff)
{
    struct mm_struct *mm = current->mm;
    struct vm_area_struct *vma;
    unsigned long populate = 0;

    // 1. 长度对齐
    len = PAGE_ALIGN(len);
    if (len == 0)
        return -EINVAL;

    // 2. 获取可用地址空间
    addr = get_unmapped_area(file, addr, len, pgoff, flags);

    // 3. 创建 VMA
    vma = vm_mmap(file, addr, len, prot, flags, pgoff);

    // 4. 加入 VMA 树
    vma_link(mm, vma);

    return addr;
}
```

---

## 3. VMA 创建（vm_mmap）

### 3.1 vm_mmap

```c
// mm/mmap.c — vm_mmap
struct vm_area_struct *vm_mmap(struct file *file, unsigned long addr,
                               unsigned long len, unsigned long prot,
                               unsigned long flags, unsigned long pgoff)
{
    struct vm_area_struct *vma;

    if (file) {
        // 文件映射
        struct address_space *mapping = file->f_mapping;

        // 调用文件系统的 mmap
        vma = file->f_op->mmap(file, vma);
    } else {
        // 匿名映射
        vma = anon_vma_link(vma);
    }

    return vma;
}
```

---

## 4. VMA 合并（vma_merge）

### 4.1 vma_merge

```c
// mm/mmap.c — vma_merge
struct vm_area_struct *vma_merge(struct mm_struct *mm,
                                 struct vm_area_struct *prev,
                                 struct vm_area_struct *next,
                                 unsigned long addr, unsigned long len,
                                 unsigned long vm_flags)
{
    // 尝试合并相邻的 VMA
    // 条件：
    //   1. 映射类型相同（文件/匿名）
    //   2. 权限相同
    //   3. 文件偏移连续
    //   4. 来自同一文件

    if (prev->vm_end == addr &&               // 紧邻
        next->vm_start == addr + len &&        // 对侧也紧邻
        prev->vm_ops == next->vm_ops &&        // 同一操作集
        vm_flags_equal(prev->vm_flags, next->vm_flags))
    {
        // 合并
        __vma_link(mm, prev, prev->vm_end, next);
        kmem_cache_free(vm_area_cachep, next);
        return prev;
    }
}
```

---

## 5. brk 系统调用

### 5.1 SYSCALL_DEFINE1(brk)

```c
// mm/mmap.c — brk
SYSCALL_DEFINE1(brk, unsigned long, brk)
{
    unsigned long newbrk, oldbrk;
    struct mm_struct *mm = current->mm;

    mmap_write_lock_killable(mm);

    oldbrk = mm->brk;
    newbrk = PAGE_ALIGN(brk);

    if (newbrk == oldbrk)
        goto success;  // 不变

    if (brk < mm->brk) {
        // 缩小 brk：释放 VMA
        do_vmi_munmap(vmi, newbrk, oldbrk - newbrk);
    } else {
        // 扩大 brk：分配新 VMA 或扩展
        // 检查 RLIMIT_DATA 限制
        if (check_data_rlimit(...))
            goto out;

        // 调用 do_brk
        do_brk_flags(vmi, prev, oldbrk, newbrk - oldbrk);
    }

success:
    mm->brk = brk;
    mmap_write_unlock(mm);

out:
    return brk;
}
```

---

## 6. 内存映射类型

```
MAP_ANONYMOUS  — 匿名映射（无文件，/dev/zero）
MAP_SHARED     — 共享映射（写回文件）
MAP_PRIVATE    — 私有映射（COW）
MAP_FIXED      — 固定地址映射
MAP_HUGETLB   — 大页映射（hugetlbfs）
MAP_LOCKED     — 锁定内存（mlock）
MAP_NORESERVE  — 不预留 swap 空间
MAP_POPULATE   — 预映射（fault 提前触发）
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `mm/mmap.c` | `sys_mmap`、`do_mmap`、`vm_mmap`、`vma_merge` |
| `mm/mmap.c` | `sys_brk`、`do_brk_flags` |
| `mm/mmap.c` | `check_brk_limits`、`mlock_future_ok` |

---

## 8. 西游记类比

**mmap** 就像"取经队伍的营地地图"——

> 每个营地（VMA）是一个连续的地址区域（vm_start ~ vm_end）。MAP_ANONYMOUS 像凭空建营地（匿名），不依附任何建筑；MAP_SHARED 像大家共用的公共区域（写回文件）；MAP_PRIVATE 像私人营房（COW）。brk() 就是调整营地边界——扩大营地（扩大堆），缩小营地（缩小堆）。营地合并（vma_merge）就像两个相邻营地如果是同一类型，就直接合并成一个大地盘，省去管理多个小营地的开销。

---

## 9. 关联文章

- **vm_area_struct**（article 16）：VMA 数据结构
- **page_allocator**（article 17）：VMA 扩展时分配物理页