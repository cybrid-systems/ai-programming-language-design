# 16-vm_area_struct / mmap — 虚拟内存区域深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/mm_types.h` + `mm/mmap.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**vm_area_struct（VMA）** 是进程虚拟地址空间的连续区间，每个 mmap 映射的区域对应一个 VMA。通过红黑树（O(log n)）和链表（顺序遍历）双重索引。

---

## 1. 核心数据结构

### 1.1 struct vm_area_struct — VMA

```c
// include/linux/mm_types.h — vm_area_struct
struct vm_area_struct {
    // 归属
    struct mm_struct           *vm_mm;         // 所属进程（所有 VMA 共用同一个 mm_struct）
    unsigned long             vm_start;          // 起始地址（含）
    unsigned long             vm_end;           // 结束地址（不含）
    struct vm_area_struct    *vm_next;         // 按地址排序的链表（线性列表）

    // 红黑树节点
    struct rb_node            vm_rb;            // 接入 mm_rb 红黑树的节点

    // 权限与标志
    pgprot_t                 vm_page_prot;      // 页保护（PAGE_READ/PAGE_WRITE）
    unsigned long            vm_flags;          // VM_READ/VM_WRITE/VM_SHARED/...

    // 文件映射
    struct {
        struct file          *vm_file;        // 映射的文件（如果有）
        unsigned long        vm_pgoff;        // 文件内页偏移
    } shared;

    // 匿名映射
    struct anon_vma           *anon_vma;        // 匿名映射的 anon_vma
    struct list_head          anon_vma_chain;   // 匿名 VMA 链表

    // 操作函数表
    const struct vm_operations_struct *vm_ops; // VMA 操作函数表

    // 私有数据
    unsigned long             vm_private_data;    // 驱动私有数据
};
```

---

## 2. vm_flags — 关键标志

```c
// include/linux/mm.h — vm_flags
#define VM_READ          0x00000001  // 可读
#define VM_WRITE         0x00000002  // 可写
#define VM_EXEC          0x00000004  // 可执行
#define VM_SHARED        0x00000008  // 共享映射（MAP_SHARED）
#define VM_MAYREAD       0x00000010  // 可设置读
#define VM_MAYWRITE      0x00000020  // 可设置写
#define VM_MAYEXEC       0x00000040  // 可设置执行
#define VM_GROWSDOWN     0x00000100  // 向下扩展（栈）
#define VM_PFNMAP        0x00000400  // PFN 映射（设备内存）
#define VM_MIXEDMAP      0x00010000  // 混合映射（PFN + 页）
#define VM_LOCKED        0x00000020  // 已锁定（mlock）
#define VM_DONTCOPY      0x00020000  // fork 时不复制
#define VM_ACCOUNT       0x00040000  // 已记账
#define VM_NORESERVE     0x00000001  // 不预留
```

---

## 3. mm_struct — 进程内存描述符

```c
// include/linux/mm_types.h — mm_struct（相关字段）
struct mm_struct {
    // VMA 集合
    struct vm_area_struct   *mmap;            // VMA 链表头
    struct rb_root          mm_rb;           // VMA 红黑树根

    // 地址空间
    unsigned long           start_code, end_code;  // 代码段
    unsigned long           start_data, end_data;  // 数据段
    unsigned long           start_brk, brk;        // 堆
    unsigned long           start_stack;             // 栈起始

    // 统计
    unsigned long           total_vm;               // 总映射页数
    unsigned long           hiwater_vm;            // 峰值 VM

    // 页表
    pgd_t                 *pgd;                  // 页表全局目录
};
```

---

## 4. find_vma — 查找 VMA

### 4.1 find_vma — 红黑树查找

```c
// mm/mmap.c — find_vma
struct vm_area_struct *find_vma(struct mm_struct *mm, unsigned long addr)
{
    struct rb_node *rb = mm->mm_rb.rb_node;
    struct vm_area_struct *vma = NULL;

    // 二分查找：
    // - 如果 addr < vma->vm_start → 左子树
    // - 如果 addr >= vma->vm_end → 右子树
    // - 否则命中
    while (rb) {
        vma = rb_entry(rb, struct vm_area_struct, vm_rb);

        if (addr < vma->vm_start)
            rb = rb->rb_left;
        else if (addr >= vma->vm_end)
            rb = rb->rb_right;
        else {
            // 命中：addr 在 [vm_start, vm_end) 内
            return vma;
        }
    }

    return NULL;  // 找不到
}

// 时间复杂度：O(log n)，n = VMA 数量
```

### 4.2 vma_rb_insert — 插入 VMA 到红黑树

```c
// mm/mmap.c — vma_rb_insert
void vma_rb_insert(struct vm_area_struct *vma, struct rb_root *root)
{
    struct rb_node **rb = &root->rb_node;
    struct rb_node *parent = NULL;
    struct vm_area_struct *tmp;

    // 找到插入位置
    while (*rb) {
        tmp = rb_entry(*rb, struct vm_area_struct, vm_rb);
        parent = *rb;

        if (vma->vm_end <= tmp->vm_start)
            rb = &(*rb)->rb_left;
        else if (vma->vm_start >= tmp->vm_end)
            rb = &(*rb)->rb_right;
        else
            BUG();  // 与已有 VMA 冲突
    }

    rb_link_node(&vma->vm_rb, parent, rb);
    rb_insert_color(&vma->vm_rb, root);
}
```

---

## 5. mmap — 创建映射

### 5.1 sys_mmap_pgoff — 系统调用

```c
// mm/mmap.c — sys_mmap_pgoff
unsigned long sys_mmap_pgoff(unsigned long addr, unsigned long len,
                              unsigned long prot, unsigned long flags,
                              unsigned long fd, unsigned long pgoff)
{
    // 1. 验证参数（对齐、限制）
    if (offset_in_page(len))  // len 必须页对齐
        return -EINVAL;

    // 2. 调用 vm_mmap_pgoff
    return vm_mmap_pgoff(file, addr, len, prot, flags, pgoff);
}
```

### 5.2 vm_mmap_pgoff — 核心映射

```c
// mm/mmap.c — vm_mmap_pgoff
unsigned long vm_mmap_pgoff(struct file *file, unsigned long addr,
                             unsigned long len, unsigned long prot,
                             unsigned long flags, unsigned long pgoff)
{
    struct vm_area_struct *vma;

    // 1. 分配 VMA
    vma = kmem_cache_zalloc(vm_area_allocator, GFP_KERNEL);
    if (!vma)
        return -ENOMEM;

    // 2. 初始化
    vma->vm_start = addr;
    vma->vm_end = addr + len;
    vma->vm_flags = calc_vm_prot_bits(prot) | calc_vm_flag_bits(flags);
    vma->vm_file = get_file(file);  // 增加文件引用
    vma->vm_pgoff = pgoff;
    vma->vm_ops = NULL;

    // 3. 插入 mm_rb 红黑树
    vma_rb_insert(vma, &mm->mm_rb);

    // 4. 插入 mmap 链表
    list_add_tail(&vma->vm_next, &mm->mmap);

    // 5. 如果是文件映射，调用文件驱动的 mmap
    if (file && file->f_op->mmap)
        file->f_op->mmap(file, vma);

    return addr;
}
```

---

## 6. VMA 合并

### 6.1 vma_merge — 相邻 VMA 合并

```c
// mm/mmap.c — vma_merge
// 相邻的同属性 VMA 会自动合并：
//   [0x1000, 0x2000) + [0x2000, 0x3000) → [0x1000, 0x3000)
//   条件：vm_end == next->vm_start && flags 相同

// 可以合并的情况：
//   匿名映射 + 相同 anon_vma
//   文件映射 + 相同 file + 相邻偏移
```

---

## 7. 内存布局图

```
进程虚拟地址空间布局：

0x0000000000400000  ← 代码段 start_code
...                  ← 代码段
0x0000000000600000  ← 数据段 end_data
                    ← BSS
0x00007ffffffde000  ← 堆 start_brk（向上增长）→ brk
                    ← mmap 区域（匿名或文件映射）
0x00007ffffffff000  ← 最高用户地址
                    ← 栈 start_stack（向下增长）
```

---

## 8. 完整文件索引

| 文件 | 函数/结构 | 行 |
|------|----------|-----|
| `include/linux/mm_types.h` | `struct vm_area_struct` | VMA 定义 |
| `include/linux/mm_types.h` | `struct mm_struct`（VMA 部分）| mm_struct 定义 |
| `include/linux/mm.h` | `VM_READ` 等标志 | 0x00000001 等 |
| `mm/mmap.c` | `sys_mmap_pgoff` | 系统调用 |
| `mm/mmap.c` | `find_vma` | 红黑树查找 |
| `mm/mmap.c` | `vma_rb_insert` | 红黑树插入 |
| `mm/mmap.c` | `vma_merge` | VMA 合并 |

---

## 9. 西游记类比

**vm_area_struct** 就像"取经路上的驿站地图"——

> 唐朝的疆域（进程地址空间）被分成很多驿站（VMA），每个驿站有明确的管辖范围（vm_start 到 vm_end）。地图用两套索引：一本是按顺序排列的驿路本（mmap 链表），一本是按地理位置分的山川图（mm_rb 红黑树）。要找某个地址属于哪个驿站，红黑树二分查找（find_vma）比翻驿路本快得多。相邻的驿站如果是同一家客栈（相同属性），会自动合并成一个大驿站（vma_merge），这样地图更简洁。

---

## 10. 关联文章

- **page_allocator**（article 17）：VMA 的物理页分配
- **copy_page_range**（article 18）：fork 时的 COW
- **mlock**（article 39）：VM_LOCKED 标志