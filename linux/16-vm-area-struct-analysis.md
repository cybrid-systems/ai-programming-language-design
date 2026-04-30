# vm_area_struct / mmap — 虚拟内存区域深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/mm_types.h` + `mm/mmap.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**vm_area_struct（VMA）** 是进程虚拟地址空间的**连续区间**，每个 mmap 映射的区域对应一个 VMA。

---

## 1. 核心数据结构

### 1.1 vm_area_struct — 虚拟内存区域

```c
// include/linux/mm_types.h — vm_area_struct
struct vm_area_struct {
    struct mm_struct           *vm_mm;        // 所属进程
    unsigned long             vm_start;       // 起始地址（含）
    unsigned long             vm_end;         // 结束地址（不含）
    struct vm_area_struct    *vm_next;       // 按地址排序的链表
    struct rb_node            vm_rb;          // 接入 mm_rb 红黑树

    pgprot_t                 vm_page_prot;    // 页保护
    unsigned long            vm_flags;        // VM_READ/VM_WRITE/VM_SHARED...

    struct {
        struct file          *vm_file;      // 映射的文件（如果有）
        unsigned long        vm_pgoff;      // 文件内页偏移
    } shared;

    struct anon_vma           *anon_vma;    // 匿名映射的 anon_vma
    struct list_head          anon_vma_chain; // 匿名 VMA 链表

    const struct vm_operations_struct *vm_ops; // VMA 操作函数表

    unsigned long             vm_private_data; // 驱动私有数据
};
```

### 1.2 vm_flags — 标志位

```c
// include/linux/mm.h
#define VM_READ          0x00000001  // 可读
#define VM_WRITE         0x00000002  // 可写
#define VM_EXEC          0x00000004  // 可执行
#define VM_SHARED        0x00000008  // 共享映射
#define VM_MAYREAD       0x00000010  // 可设置读
#define VM_MAYWRITE      0x00000020  // 可设置写
#define VM_MAYEXEC       0x00000040  // 可设置执行
#define VM_GROWSDOWN     0x00000100  // 向下扩展（栈）
#define VM_PFNMAP        0x00000400  // PFN 映射（设备内存）
#define VM_MIXEDMAP      0x00010000  // 混合映射
```

---

## 2. 查找 VMA

### 2.1 find_vma — 查找覆盖 addr 的 VMA

```c
// mm/mmap.c — find_vma
struct vm_area_struct *find_vma(struct mm_struct *mm, unsigned long addr)
{
    struct rb_node *rb = mm->mm_rb.rb_node;
    struct vm_area_struct *vma = NULL;

    // 在红黑树中查找
    while (rb) {
        vma = rb_entry(rb, struct vm_area_struct, vm_rb);

        if (addr < vma->vm_end)
            rb = rb->rb_left;
        else
            rb = rb->rb_right;
    }

    return vma;
}
```

---

## 3. mmap — 创建映射

```c
// mm/mmap.c — sys_mmap
unsigned long sys_mmap(unsigned long addr, unsigned long len,
               unsigned long prot, unsigned long flags,
               unsigned long fd, unsigned long offset)
{
    // 1. 验证参数
    // 2. 调用 vm_mmap_pgoff
    return vm_mmap_pgoff(file, addr, len, prot, flags, offset >> PAGE_SHIFT);
}

unsigned long vm_mmap_pgoff(struct file *file, unsigned long addr,
                  unsigned long len, unsigned long prot,
                  unsigned long flags, unsigned long pgoff)
{
    // 1. 分配 VMA
    vma = vm_area_alloc();

    // 2. 初始化 VMA
    vma->vm_start = addr;
    vma->vm_end = addr + len;
    vma->vm_flags = vm_flags_for_prot(prot, flags);
    vma->vm_file = file;
    vma->vm_pgoff = pgoff;

    // 3. 插入红黑树
    vma_mtree_insert(vma, &mm->mm_rb);

    // 4. 如果是文件映射，调用文件驱动的 mmap
    if (file && file->f_op->mmap)
        file->f_op->mmap(file, vma);

    return addr;
}
```

---

## 4. VMA 合并

相邻的同属性 VMA 会自动合并：

```c
// mm/mmap.c — vma_merge
struct vm_area_struct *vma_merge(struct mm_struct *mm,
    struct vm_area_struct *prev, unsigned long start, ...)
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/mm_types.h` | `struct vm_area_struct` |
| `include/linux/mm.h` | `VM_READ` 等标志 |
| `mm/mmap.c` | `sys_mmap`、`vm_mmap_pgoff`、`find_vma`、`vma_merge` |
