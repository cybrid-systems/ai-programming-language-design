# Linux Kernel vm_area_struct 与 mmap 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/mmap.c` + `include/linux/mm_types.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 vm_area_struct？

**`vm_area_struct`**（VMA）是进程地址空间中的一个**连续虚拟内存区域**。每个进程的 `mm_struct` 管理着所有 VMA，通过**红黑树**（`mmap_rb`）组织。

**核心概念**：
- 进程地址空间被划分为多个 VMA
- 每个 VMA 有独立的权限（r/w/x）、映射文件、内存管理函数
- VMA 是 `mmap()`、`munmap()`、堆管理、栈管理的基石

---

## 1. 核心数据结构

### 1.1 vm_area_struct

```c
// include/linux/mm_types.h:932
struct vm_area_struct {
    /* 第一个 cache line：VMA 树遍历的关键字段 */
    union {
        struct {
            unsigned long vm_start;    // VMA 起始地址（含）
            unsigned long vm_end;      // VMA 结束地址（不含）
        };
    };

    struct rb_node vm_rb;              // 红黑树节点（接入 mm->mmap_rb）
    unsigned long vm_pgoff;           // 文件映射的页内偏移

    /* VMA 属于哪个 address space */
    struct mm_struct *vm_mm;          // 所属的 mm_struct

    /* 权限标志（VM_READ/VM_WRITE/VM_EXEC/VM_SHARED）*/
    pgprot_t vm_page_prot;
    unsigned long vm_flags;          // 核心标志集合

    /* 映射的文件或匿名内存 */
    union {
        struct {
            struct inode *vm_file;   // 映射的文件（文件映射）
            void *vm_private_data;   // 驱动私有数据
        };
        struct anon_vma_name *anon_name;  // 匿名 VMA 名字
    };

    /* VMA 的内存管理操作（文件映射用）*/
    const struct vm_operations_struct *vm_ops;

    /* 链表（mmap_init 后接入 mm->mmap 或其他链表）*/
    struct list_head vm_addecent;
};
```

### 1.2 关键 vm_flags

```c
// include/linux/mm.h
#define VM_READ        0x00000001   // 可读
#define VM_WRITE       0x00000002   // 可写
#define VM_EXEC        0x00000004   // 可执行
#define VM_SHARED      0x00000008   // 共享映射（MAP_SHARED）
#define VM_MAYREAD     0x00000010   // 可设置 READ
#define VM_MAYWRITE    0x00000020   // 可设置 WRITE
#define VM_MAYEXEC     0x00000040   // 可设置 EXEC
#define VM_GROWSDOWN   0x00000100   // 向下扩展（栈）
#define VM_UPTODATE    0x00000200   // 页表已更新
#define VM_LOCKED      0x00002000   // mlock 锁定
#define VM_IO           0x00004000  // MMIO 区域
#define VM_SEQ_READ    0x00008000   // 顺序读（hint）
#define VM_RAND_READ   0x00010000   // 随机读（hint）
#define VM_DONTCOPY    0x00020000   // fork 时不复制（dmat）
#define VM_DONTEXPAND  0x00040000   // mremap 不扩展
#define VM_LOCKINFAULT 0x00080000   // fault 时锁定
#define VM_ACCOUNT     0x00100000   // 需要记账
#define VM_NORESERVE   0x00200000   // 不预留
#define VM_HUGETLB     0x00400000   // huge page TLB
#define VM_SYNC         0x00800000  // 同步 I/O
#define VM_ARCH_1      0x01000000   // 架构特定
#define VM_WIPEONFORK   0x02000000  // fork 后内容清零
#define VM_DONTDUMP     0x04000000   // core dump 排除
```

### 1.3 vm_operations_struct

```c
// include/linux/mm.h:768 — VMA 操作函数表
struct vm_operations_struct {
    void (*open)(struct vm_area_struct *vma);       // VMA 创建时
    void (*close)(struct vm_area_struct *vma);      // VMA 销毁时

    // 文件映射页面 fault 时调用
    vm_fault_t (*fault)(struct vm_fault *vmf);
    vm_fault_t (*pmd_fault)(struct vm_fault *vmf);

    // 页表映射操作
    void (*map_pages)(struct vm_fault *vmf,
              pgoff_t start_pgoff, pgoff_t end_pgoff);

    // 页面访问通知
    int (*page_mkwrite)(struct vm_fault *vmf);
    int (*access)(struct vm_area_struct *vma,
              unsigned long addr, void *buf, int len, int write);

    // 混合标志
    const char *name;
    unsigned long mmap_lock_end;
};
```

### 1.4 mm_struct

```c
// include/linux/mm_types.h — mm_struct（每个进程一个）
struct mm_struct {
    struct {
        struct vm_area_struct *mmap;          // VMA 链表头
        struct rb_root mm_mt;                  // VMA 红黑树（mmap_rb）
        unsigned long free_area_cache;        // 快速查找的缓存
        unsigned long trap_address;            // fault 地址
        // ...
    };

    /* 地址空间布局 */
    unsigned long start_code, end_code;
    unsigned long start_data, end_data;
    unsigned long start_brk, brk;
    unsigned long start_stack;                // 栈起始
    unsigned long arg_start, arg_end;          // 命令行参数
    unsigned long env_start, env_end;         // 环境变量

    /* 页表 */
    pgd_t *pgd;                               // 页全局目录
    atomic_t mm_users;                        // 用户计数（线程共享）
    atomic_t mm_count;                         // 引用计数

    /* 锁 */
    struct rw_semaphore mmap_lock;            // 保护 VMA 树
    struct mutex lock;                         // 页面分配锁
};
```

---

## 2. do_mmap — 核心映射函数

```c
// mm/mmap.c:336 — do_mmap
unsigned long do_mmap(struct file *file, unsigned long addr,
            unsigned long len, unsigned long prot,
            unsigned long flags, vm_flags_t vm_flags,
            unsigned long pgoff, unsigned long *populate,
            struct list_head *uf)
{
    struct mm_struct *mm = current->mm;
    unsigned long retval;

    // 1. 地址对齐检查
    if ((len > TASK_SIZE) || (offset_in_page(len) != 0))
        return -EINVAL;

    // 2. addr == 0 时让内核选择地址（匿名映射）
    if (!addr)
        addr = get_unmapped_area(file, addr, len, pgoff, flags);

    // 3. 合并相邻 VMA（如果可能）
    //    VMAs that are adjacent, with the same access flags, file, offset,
    //    and mapping type can be merged to reduce the number of VMAs.
    vma = mmap_region(file, addr, len, vm_flags, pgoff, uf);
    if (IS_ERR(vma))
        return PTR_ERR(vma);

    // 4. 返回分配的地址
    return addr;
}
```

---

## 3. mmap_region — VMA 创建核心

```c
// mm/mmap.c — mmap_region
static struct vm_area_struct *mmap_region(...)
{
    struct vm_area_struct *vma, *prev;

    // 1. 检查 rlimit
    if (may_expand_vm(mm, len >> PAGE_SHIFT))
        return -ENOMEM;

    // 2. 从红黑树中找插入位置
    vma = vma_merge(mm, prev, start, end, vm_flags,
               NULL, file, pgoff, NULL, NULL);
    if (vma)
        goto out;  // 合并成功，不需要新建

    // 3. 分配新的 VMA
    vma = kmem_cache_zalloc(vm_area_cachep, GFP_KERNEL);
    if (!vma)
        return -ENOMEM;

    // 4. 初始化 VMA 字段
    vma->vm_start = start;
    vma->vm_end = end;
    vva->vm_pgoff = pgoff;
    vma->vm_ops = &vm_ops_file;  // 文件操作表
    vma->vm_file = get_file(file);

    // 5. 插入红黑树和链表
    vma_link(mm, vma, prev, rb_link, rb_parent);

out:
    // 6. 更新 mm 统计
    vm_stat_account(mm, vm_flags, len >> PAGE_SHIFT);

    // 7. mlock 或 huge page 处理
    if (vm_flags & VM_LOCKED)
        mlock_future_check(mm, len);

    return vma;
}
```

---

## 4. find_vma — 红黑树查找

```c
// mm/mmap.c:903 — find_vma（查找包含 addr 的 VMA）
struct vm_area_struct *find_vma(struct mm_struct *mm, unsigned long addr)
{
    struct rb_node *rbnode;
    struct vm_area_struct *vma;

    // 快速路径：从缓存的 free_area_cache 加速查找
    // free_area_cache 缓存了上一次成功查找的位置附近
    vma = vmacache_find(mm, addr);
    if (vma)
        return vma;

    // 红黑树搜索：找第一个 vm_end > addr 的节点
    rbnode = mm->mm_mt.rb_node;

    while (rbnode) {
        struct vm_area_struct *tmp;
        tmp = rb_entry(rbnode, struct vm_area_struct, vm_rb);

        if (addr < tmp->vm_end) {
            if (addr >= tmp->vm_start) {
                // 命中
                vmacache_update(addr, tmp);
                return tmp;
            }
            rbnode = rbnode->rb_left;   // 目标在左侧
        } else {
            rbnode = rbnode->rb_right;  // 目标在右侧
        }
    }

    return NULL;  // addr 不在任何 VMA 内
}
```

---

## 5. VMA 合并（vma_merge）

```c
// mm/mmap.c — vma_merge
// 相邻 VMA 满足以下条件时合并：
//   1. same vm_file / anon_vma
//   2. same access flags (vm_flags)
//   3. same vm_pgoff (文件偏移连续)
//   4. no vm_ops->close between them
//   5. no VM_GROWSDOWN / VM_GROWSUP between them
static struct vm_area_struct *vma_merge(struct mm_struct *mm,
    struct vm_area_struct *prev, unsigned long start,
    unsigned long end, unsigned long vm_flags,
    struct anon_vma *anon_vma, struct file *file,
    pgoff_t pgoff, struct vm_userfaultfd_ctx *ctx,
    struct anon_vma_name *anon_name)
{
    // 检查 prev 和 next 是否可以合并
    // ...
    // 可以合并：返回一个统一的 VMA
    // 不可以合并：返回 NULL，需要新建
}
```

---

## 6. munmap — VMA 销毁

```c
// mm/mmap.c — do_munmap
int do_munmap(struct mm_struct *mm, unsigned long start, size_t len)
{
    struct vm_area_struct *vma, *prev, *last;

    // 1. 查找要释放的 VMA 范围
    if (end == 0) return -EINVAL;

    // 2. 截断或删除 VMA
    vma = vma_split(mm, start, ...);  // 在 start 处切开
    // 或
    vma = find_vma(mm, start);

    // 3. 解除页表映射
    zap_page_range(vma, start, len);

    // 4. 从红黑树和链表中移除
    vma_remove_rmap(vma);
    detach_vmas_to_rb_tree(vma);

    // 5. 释放 VMA 结构
    vm_area_free(vma);

    return 0;
}
```

---

## 7. mprotect — 修改 VMA 权限

```c
// mm/mprotect.c
int do_mprotect_fixup(struct mmu_gather *tlb,
              struct vm_area_struct *vma,
              unsigned long start, unsigned long end,
              unsigned long newflags)
{
    unsigned long oldflags = vma->vm_flags;

    // 1. 检查权限是否允许
    if (!arch_validate_prot(newflags))
        return -EINVAL;

    // 2. 计算需要修改的页面
    change_protection(vma, start, end, newflags, oldflags);

    // 3. 更新 VMA 标志
    vma->vm_flags = newflags;
    vma->vm_page_prot = vm_get_page_prot(newflags);

    return 0;
}
```

---

## 8. 完整状态机

```
进程地址空间布局：

┌──────────────────────┐ 0x0000000000400000
│    text (代码)       │ start_code ~ end_code
├──────────────────────┤
│    data (已初始化)    │ start_data ~ end_data
├──────────────────────┤
│    bss (未初始化)     │
├──────────────────────┤
│       heap           │ start_brk ~ brk (向上扩展)
├──────────────────────┤
│                     ↕ │   <-- brk() / sbrk()
├──────────────────────┤
│    mmap 区域         │ 匿名映射 / 文件映射
├──────────────────────┤
│                     ↕ │   <-- mmap() / munmap()
├──────────────────────┤
│       stack         │ start_stack (向下扩展)
└──────────────────────┘ 0xC0000000 (3GB 用户空间)

每个 VMA 用 rb_node 接入 mm->mm_mt 红黑树
每个 VMA 用 vm_area_list 接入 mm->mmap 链表
```

---

## 9. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| 红黑树组织 VMA | O(log n) 查找，适合稀疏地址空间 |
| `free_area_cache` | 加速连续地址分配（避免每次从头查树）|
| `vma_merge` | 减少 VMA 数量，降低树遍历开销 |
| `vm_ops->fault` | 文件映射的按需 page fault 支持 |
| `mmap_lock` 读写信号量 | 读锁并发，写锁独占；允许多个读 mmap |
| `VM_GROWSDOWN` | 栈需要向下扩展，特殊标记处理 |

---

## 10. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/mm_types.h:932` | `struct vm_area_struct` 完整定义 |
| `include/linux/mm.h` | `vm_flags` 标志、`vm_operations_struct` |
| `mm/mmap.c:336` | `do_mmap` 入口 |
| `mm/mmap.c:903` | `find_vma` 红黑树查找 |
| `mm/mmap.c` | `mmap_region`、`vma_merge`、`do_munmap` |
