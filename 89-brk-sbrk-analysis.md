# Linux Kernel brk / sbrk — 堆管理深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/mmap.c` + `mm/util.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**brk/sbrk** 是进程堆内存的经典管理接口：`brk()` 设置进程的数据段结束地址（`mm->brk`），堆从 `mm->start_brk` 增长到 `mm->brk`。

---

## 1. 核心数据结构

```c
// include/linux/sched.h — mm_struct（堆相关字段）
struct mm_struct {
    // 堆区间
    unsigned long           start_brk;       // 堆起始地址
    unsigned long           brk;             // 堆结束地址（当前 break）
    unsigned long           start_code;      // 代码段起始
    unsigned long           end_data;        // 数据段结束
    unsigned long           arg_start;       // 命令行参数起始

    // 虚拟内存
    struct vm_area_struct  *mmap;           // VMA 链表
    struct rb_root          mm_rb;          // VMA 红黑树

    // 统计
    unsigned long           total_vm;        // 总 VM 映射
    unsigned long           hiwater_rss;     // 峰值 RSS
    unsigned long           hiwater_vm;      // 峰值 VM
};
```

---

## 2. sys_brk — brk 系统调用

```c
// mm/mmap.c — sys_brk
unsigned long sys_brk(unsigned long brk)
{
    unsigned long newbrk, oldbrk, retval;

    // 1. 参数检查
    if (brk < mm->start_brk)
        goto out;

    // 2. 对齐到页
    newbrk = PAGE_ALIGN(brk);
    oldbrk = PAGE_ALIGN(mm->brk);

    if (oldbrk == newbrk)
        goto set_brk;

    // 3. 扩展堆（newbrk > oldbrk）
    if (newbrk > oldbrk) {
        retval = do_brk_flags(oldbrk, newbrk - oldbrk, 0, mm);
        if (retval)
            goto out;
    }
    // 4. 收缩堆（newbrk < oldbrk）
    else {
        do_munmap(mm, newbrk, oldbrk - newbrk, 0);
    }

set_brk:
    mm->brk = brk;  // 设置新的 break

out:
    return mm->brk;
}
```

---

## 3. do_brk_flags — 映射新堆区间

```c
// mm/mmap.c — do_brk_flags
static inline int do_brk_flags(unsigned long addr, unsigned long len, unsigned long flags, struct mm_struct *mm)
{
    struct vm_area_struct *vma;

    // 1. 查找相邻的 VMA
    vma = vma_merge(mm, prev, addr, len, flags,
                     NULL, NULL, NULL, NULL);
    if (vma)
        return 0;

    // 2. 分配新的 VMA
    vma = vm_area_alloc(mm);
    if (!vma)
        return -ENOMEM;

    // 3. 初始化
    vma->vm_start = addr;
    vma->vm_end = addr + len;
    vma->vm_flags = flags | VM_DATA_DEFAULT;
    vma->vm_page_prot = vm_get_page_prot(vma->vm_flags);

    // 4. 插入 VMA
    vma_link(mm, vma);

    // 5. 更新统计
    vm_stat_account(mm, vm_flags, len >> PAGE_SHIFT);

    return 0;
}
```

---

## 4. glibc 实现

```c
// glibc/misc/brk.c — sbrk
void *sbrk(intptr_t increment)
{
    void *p = (void *)sys_brk(current_brk + increment);
    if ((unsigned long)p >= current_brk + increment)
        current_brk += increment;
    return (void *)current_brk;
}

// sbrk(0) 返回当前 break
// sbrk(n) 增加 n 字节堆
```

---

## 5. 内存布局图

```
进程虚拟地址空间布局：

0x0000000000400000  ← 代码段 start_code
...                 ← 代码段
0x0000000000600000  ← 数据段 end_data
                    ← BSS
                    ← 堆区（增长方向 →）
0x00007ffffffde000  ← 栈（向下增长）
                    ← 最高用户地址
```

---

## 6. 与 mmap 的区别

| 特性 | brk/sbrk | mmap |
|------|----------|------|
| 粒度 | 字节（内核页对齐） | 页 |
| 用途 | 堆（malloc 底层） | 匿名映射、文件映射 |
| 释放 | 自动收缩（glibc） | munmap 精确释放 |
| 位置 | 连续 | 可以任意位置 |

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `mm/mmap.c` | `sys_brk`、`do_brk_flags` |
| `mm/util.c` | `mm_sbrk` |
| `include/linux/sched.h` | `mm_struct`（堆字段） |