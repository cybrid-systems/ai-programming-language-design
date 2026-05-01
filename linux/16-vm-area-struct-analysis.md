# 16-vm_area_struct — 虚拟内存区域深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**vm_area_struct（VMA）** 描述进程虚拟地址空间中的一个连续区域。每个进程的地址空间由若干 VMA 组成——代码段、堆、栈、mmap 区域等各对应一个 VMA。

VMA 是内存管理中最重要的数据结构之一，它连接了**虚拟地址**和**物理内存**之间的映射关系。

doom-lsp 确认 `include/linux/mm_types.h` 定义 VMA 相关结构，`mm/mmap.c` 和 `mm/memory.c` 实现 VMA 操作，共包含约 800+ 个符号。

---

## 1. 核心数据结构

### 1.1 struct vm_area_struct

```c
struct vm_area_struct {
    unsigned long          vm_start;      // 起始虚拟地址
    unsigned long          vm_end;        // 结束虚拟地址（不含）
    
    struct vm_area_struct *vm_next;       // 进程 VMA 链表中的下一个
    struct vm_area_struct *vm_prev;       // 上一个
    
    struct rb_node         vm_rb;         // 红黑树节点（快速查找）
    
    unsigned long          vm_flags;      // 权限标志 (VM_READ/WRITE/EXEC/SHARED)
    
    struct file           *vm_file;       // 映射的文件（文件映射）
    unsigned long          vm_pgoff;      // 文件内偏移（页为单位）
    
    const struct vm_operations_struct *vm_ops; // VMA 操作回调
    
    struct anon_vma       *anon_vma;      // 匿名映射的反向映射
    
    struct mm_struct      *vm_mm;         // 所属的 mm_struct
    unsigned long          vm_page_prot;  // 页表权限（从 vm_flags 转换而来）
    ...
};
```

### 1.2 VMA 的组织方式

每个 VMA 通过两种结构被索引：

```
mm_struct 中的 VMA 组织：
  ┌─────────────────────────┐
  │ mm->mmap (链表)         │──→ VMA1 → VMA2 → VMA3 → ...  ← 线性遍历
  │                         │
  │ mm->mm_rb (红黑树根)    │──→ [VMA1] [VMA2] [VMA3] ...  ← O(log n) 查找
  │                         │
  │ mm->map_count           │──  VMA 总数
  └─────────────────────────┘
```

链表用于遍历所有 VMA，红黑树用于按地址快速查找。

---

## 2. 关键操作

### 2.1 find_vma（按地址查找 VMA）

```c
struct vm_area_struct *find_vma(struct mm_struct *mm, unsigned long addr)
```

```
find_vma(mm, addr)
  │
  ├─ 从 mm->mm_rb 红黑树中查找
  │    └─ 返回第一个 vm_end > addr 的 VMA
  │
  └─ 如果没有找到 → 返回 NULL
```

这是最常用的 VMA 查找函数——缺页处理、权限检查等都需要通过它获知某个地址属于哪个 VMA。

### 2.2 mmap 系统调用流程

```
sys_mmap(addr, length, prot, flags, fd, offset)
  │
  ├─ 检查权限/参数
  │
  ├─ do_mmap(file, addr, len, prot, flags, ...)
  │    │
  │    ├─ 查找空闲地址区间
  │    │    └─ 使用 unmapped_area() / unmapped_area_topdown()
  │    │
  │    ├─ 分配新的 VMA
  │    │    └─ kmem_cache_alloc(vm_area_cachep)
  │    │
  │    ├─ 设置 vm_start, vm_end, vm_flags, vm_file, vm_pgoff
  │    │
  │    ├─ 插入到 mm->mmap 链表和 mm->mm_rb 红黑树
  │    │    └─ vma_link(mm, vma)
  │    │
  │    ├─ 处理文件映射
  │    │    └─ file->f_op->mmap(file, vma)  ← 文件系统回调
  │    │
  │    └─ 返回映射后的起始地址
```

### 2.3 do_munmap（解除映射）

```
do_munmap(mm, addr, len)
  │
  ├─ find_vma_links(mm, addr, &vma, &prev, &rb_link, &rb_parent)
  │    └─ 找到受影响的 VMA
  │
  ├─ split_vma()                          ← 如果需要部分解除
  │    └─ 将 VMA 在 addr/addr+len 处分裂
  │
  ├─ unmap_region()                       ← 解除页表映射
  │    └─ zap_page_range() → 清除 PTE
  │
  └─ remove_vma_list()                   ← 删除 VMA 结构
```

---

## 3. VMA 的 vm_operations_struct

```c
struct vm_operations_struct {
    void (*open)(struct vm_area_struct *vma);          // VMA 被复制时
    void (*close)(struct vm_area_struct *vma);         // VMA 被删除时
    vm_fault_t (*fault)(struct vm_fault *vmf);         // 缺页处理
    vm_fault_t (*huge_fault)(struct vm_fault *vmf);    // 透明大页缺页
    void (*map_pages)(struct vm_fault *vmf, pgoff_t start, pgoff_t end);
    unsigned long (*pagesize)(struct vm_area_struct *vma);
    ...
};
```

最重要的是 `fault` 回调——当 VMA 区域内发生缺页时，这个函数负责填充物理页。

---

## 4. VMA 权限标志（vm_flags）

```c
#define VM_READ      0x00000001    // 可读
#define VM_WRITE     0x00000002    // 可写
#define VM_EXEC      0x00000004    // 可执行
#define VM_SHARED    0x00000008    // 共享映射（MAP_SHARED）
#define VM_MAYREAD   0x00000010    // 将来可能可读
#define VM_MAYWRITE  0x00000020    // 将来可能可写
#define VM_MAYEXEC   0x00000040    // 将来可能可执行
#define VM_GROWSDOWN 0x00000100    // 向下增长（栈）
#define VM_PFNMAP    0x00000400    // 纯 PFN 映射（无 struct page）
#define VM_DENYWRITE 0x00000800    // 禁止文件写入
...
```

---

## 5. 数据类型流

```
进程 A 的用户空间：
  ┌──────────────────────┐  0x7fff00000000  (栈)
  │ VMA: [stack]         │  RW
  ├──────────────────────┤  0x7f0000000000
  │ VMA: [libc.so]       │  R-X  (文件映射)
  ├──────────────────────┤
  │ VMA: [heap]           │  RW   (匿名映射)
  ├──────────────────────┤
  │ VMA: [data]           │  RW   (文件映射)
  ├──────────────────────┤
  │ VMA: [text]           │  R-X  (文件映射)
  └──────────────────────┘  0x400000

mmap = 创建新 VMA
munmap = 删除 VMA
缺页 → 根据 VMA 填充物理页
fork → 复制所有 VMA（copy_page_range）
```

---

## 6. 设计决策总结

| 决策 | 原因 |
|------|------|
| 链表 + 红黑树双组织 | 遍历快且查找快 |
| 区间 [start, end) | 半开区间便于计算长度 |
| vm_operations_struct | 文件系统和匿名映射可以定制缺页行为 |
| vm_flags 位掩码 | 快速检查权限 |
| vm_file + vm_pgoff | 统一文件映射和匿名映射 |

---

## 7. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/mm_types.h` | `struct vm_area_struct` | 定义 |
| `mm/mmap.c` | `find_vma` / `do_mmap` / `do_munmap` | VMA 操作 |
| `mm/memory.c` | `handle_mm_fault` | 缺页入口 |

---

## 8. 关联文章

- **page_allocator**（article 17）：VMA 缺页时从 buddy 获取页面
- **page_cache**（article 20）：文件映射 VMA 的缺页由 page cache 填充
- **mmap**（article 79）：mmap 系统调用详解

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
