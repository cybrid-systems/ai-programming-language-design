# 16-vm_area_struct — 虚拟内存区域深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**vm_area_struct（VMA）** 描述进程虚拟地址空间中一个连续区域。每个进程的地址空间由多个 VMA 组成——代码段、堆、栈、mmap 区域各对应一个 VMA。

VMA 连接了虚拟地址和物理内存：缺页处理时根据 VMA 类型（匿名/文件映射）决定如何填充物理页。

doom-lsp 确认 `include/linux/mm_types.h` 定义 VMA 核心结构，`mm/mmap.c` 含 ~800+ 符号。

---

## 1. 数据结构

### 1.1 struct vm_area_struct

```c
struct vm_area_struct {
    unsigned long          vm_start;       // 起始地址
    unsigned long          vm_end;         // 结束地址（不含）
    struct vm_area_struct *vm_next;        // 链表（mm->mmap）
    struct vm_area_struct *vm_prev;
    struct rb_node         vm_rb;          // 红黑树（mm->mm_rb）
    unsigned long          vm_flags;       // VM_READ/WRITE/EXEC/SHARED
    struct file           *vm_file;        // 文件映射
    unsigned long          vm_pgoff;       // 文件内偏移
    const struct vm_operations_struct *vm_ops; // 缺页处理回调
    struct anon_vma       *anon_vma;       // 匿名映射反向映射
    struct mm_struct      *vm_mm;          // 所属 mm
};
```

### 1.2 双重索引

```
mm->mmap (链表) ←→ VMA → VMA → VMA → ...   遍历
mm->mm_rb (红黑树) ←→ [VMA][VMA][VMA]...   查找
```

链表用于顺序遍历（`/proc/pid/maps`），红黑树用于按地址快速查找（缺页处理）。

---

## 2. 核心操作

### 2.1 find_vma（`mm/mmap.c`）

```
find_vma(mm, addr)
  │
  ├─ 从 mm->mm_rb 红黑树中找到第一个 vm_end > addr 的 VMA
  │    └─ 二分查找 → O(log n)
  │
  └─ 如果没有 → 返回 NULL
```

### 2.2 mmap 流程

```
do_mmap(file, addr, len, prot, flags, ...)
  │
  ├─ get_unmapped_area() → 查找空闲区间
  ├─ kmem_cache_alloc(vm_area_cachep) → 分配 VMA
  ├─ 设置 vm_start/end/flags/file/pgoff
  ├─ vma_link(vma) → 插入 mm->mmap + mm->mm_rb
  └─ file->f_op->mmap(file, vma) → 文件系统回调
```

---

## 3. vm_flags 关键标志

| 标志 | 值 | 含义 |
|------|-----|------|
| VM_READ | 0x01 | 可读 |
| VM_WRITE | 0x02 | 可写 |
| VM_EXEC | 0x04 | 可执行 |
| VM_SHARED | 0x08 | 共享映射 |
| VM_GROWSDOWN | 0x100 | 向下增长（栈）|
| VM_PFNMAP | 0x400 | 纯物理页映射 |
| VM_DENYWRITE | 0x800 | 禁止写文件 |

---

## 4. 设计决策总结

| 决策 | 原因 |
|------|------|
| 链表+红黑树双组织 | 遍历和查找兼顾 |
| vm_ops 回调 | 文件系统和匿名映射可定制缺页行为 |
| [start, end) 区间 | 标准半开区间，方便计算长度 |

---

## 5. 源码文件索引

| 文件 | 关键符号 |
|------|---------|
| `include/linux/mm_types.h` | `struct vm_area_struct` |
| `mm/mmap.c` | `find_vma` / `do_mmap` / `do_munmap` |

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
