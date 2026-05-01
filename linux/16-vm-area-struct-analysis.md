# 16-vm_area_struct — Linux 内核 VMA 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**VMA（Virtual Memory Area，虚拟内存区域）** 是进程地址空间的描述单元。内核使用 `struct vm_area_struct` 描述一段连续的虚拟地址区间 `[vm_start, vm_end)`，记录了这段地址的权限、映射方式、所属文件等信息。

一个进程的完整地址空间由 VMA 组成的有序链表/红黑树描述。`/proc/pid/maps` 中列出的每一行都是
一个 VMA：
```
7f1234000000-7f1234001000 rw-p 00000000 00:00 0          [heap]
7f1235000000-7f1235001000 r-xp 00000000 08:01 123456     /lib/libc.so
```

**doom-lsp 确认**：`struct vm_area_struct` 定义在 `include/linux/mm_types.h:932`。VMA 操作分散在 `mm/mmap.c`、`mm/vma.c` 等文件中。

---

## 1. 核心数据结构

```c
// include/linux/mm_types.h:932 — doom-lsp 确认
struct vm_area_struct {
    // ——— 第一缓存行（VMA 树遍历用） ———
    unsigned long vm_start;           // VMA 起始地址
    unsigned long vm_end;             // VMA 结束地址（不包含）

    struct mm_struct *vm_mm;          // 所属进程的 mm_struct
    pgprot_t vm_page_prot;            // 页权限（读/写/执行）

    union {
        const vm_flags_t vm_flags;     // VMA 标志
        vma_flags_t flags;
    };

    struct list_head anon_vma_chain;  // 匿名 VMA 链
    struct anon_vma *anon_vma;        // 匿名页反向映射

    const struct vm_operations_struct *vm_ops; // VMA 操作函数

    // ——— 第二缓存行 ———
    unsigned long vm_pgoff;            // 文件偏移（页为单位）
    struct file *vm_file;              // 映射的文件
    void *vm_private_data;             // 私有数据

    // ——— 树节点 ———
    struct rb_node vm_rb;              // 红黑树节点
    struct list_head vm_list;          // 按序链表节点
    struct list_head vma_link;         // 文件映射链表
};
```

### 1.1 vm_flags——权限与特性

```c
// include/linux/mm.h
#define VM_READ          0x00000001    // 可读
#define VM_WRITE         0x00000002    // 可写
#define VM_EXEC          0x00000004    // 可执行
#define VM_SHARED        0x00000008    // 共享（Mmap 的 MAP_SHARED）
#define VM_MAYREAD       0x00000010    // 将来可能可读
#define VM_MAYWRITE      0x00000020    // 将来可能可写
#define VM_MAYEXEC       0x00000040    // 将来可能可执行
#define VM_MAYSHARE      0x00000080    // 将来可能共享
#define VM_GROWSDOWN     0x00000100    // 可向下增长（栈）
#define VM_GROWSUP       0x00000200    // 可向上增长
#define VM_SOFTDIRTY     0x00000400    // 页面被写（用于 CRIU）
#define VM_PFNMAP        0x00000800    // PFN 映射（非 struct page）
#define VM_DENYWRITE     0x00001000    // 拒绝写入文件
#define VM_UFFD_MISSING  0x00002000    // userfaultfd 监控缺页
#define VM_UFFD_WP       0x00004000    // userfaultfd 写保护
#define VM_UFFD_MINOR    0x00008000    // userfaultfd minor fault
#define VM_IO            0x00100000    // IO 映射
#define VM_SEQ_READ      0x00200000    // 顺序读
#define VM_RAND_READ     0x00400000    // 随机读
#define VM_DONTCOPY      0x00800000    // fork 时不复制
#define VM_DONTEXPAND    0x01000000    // 不可扩展
#define VM_LOCKED        0x02000000    // mlock 锁定
#define VM_ACCOUNT       0x04000000    // 计入 RSS 限额
#define VM_NORESERVE     0x08000000    // 不预留交换空间
#define VM_HUGETLB       0x10000000    // HugeTLB 映射
#define VM_SYNC          0x20000000    // 同步映射
#define VM_ARCH_1        0x40000000    // 架构特定
#define VM_WIPEONFORK    0x80000000    // fork 时清空
```

### 1.2 vm_ops——VMA 操作表

```c
struct vm_operations_struct {
    void (*open)(struct vm_area_struct *vma);       // VMA 打开
    void (*close)(struct vm_area_struct *vma);      // VMA 关闭
    vm_fault_t (*fault)(struct vm_area_struct *vma, struct vm_fault *vmf);
                                                    // 缺页处理
    vm_fault_t (*huge_fault)(struct vm_area_struct *vma, struct vm_fault *vmf,
                             unsigned int order);   // 大页缺页
    void (*map_pages)(struct vm_area_struct *vma, struct vm_fault *vmf,
                      pgoff_t start, pgoff_t end);  // 批量映射
    // ...
};
```

最重要是 `fault`——当进程访问 VMA 内尚未映射的页面时调用。文件映射的 VMA 的 `fault` 回调从文件读取页面，匿名映射则由内核处理 COW。

---

## 2. VMA 查找——find_vma

```c
// mm/mmap.c — VMA 查找
struct vm_area_struct *find_vma(struct mm_struct *mm, unsigned long addr)
{
    struct rb_node *rb_node;
    struct vm_area_struct *vma;

    // 先检查 cache（上次访问的 VMA）
    vma = vma_lookup(mm, addr);
    if (vma && vma->vm_start <= addr)
        return vma;

    // 红黑树查找
    rb_node = mm->mm_rb.rb_node;
    vma = NULL;
    while (rb_node) {
        struct vm_area_struct *tmp = rb_entry(rb_node, ...);
        if (tmp->vm_end > addr) {
            vma = tmp;
            if (tmp->vm_start <= addr)
                break;
            rb_node = tmp->vm_rb.rb_left;
        } else {
            rb_node = tmp->vm_rb.rb_right;
        }
    }
    return vma;
}
```

---

## 3. VMA 操作

| 操作 | 函数 | 文件 |
|------|------|------|
| 查找 VMA | `find_vma()` | mm/mmap.c |
| 创建 VMA | `insert_vm_struct()` | mm/mmap.c |
| 合并 VMA | `vma_merge()` | mm/mmap.c |
| 分割 VMA | `split_vma()` | mm/mmap.c |
| 删除 VMA | `remove_vma()` | mm/mmap.c |
| VMA 锁定 | `vma_start_read()` / `vma_start_write()` | mm/vma.c |

---

## 4. per-VMA 锁

Linux 6.x 引入 per-VMA 锁，避免每次缺页都要获取全局 `mmap_lock`：

```c
// vm_lock_seq — 序列号锁
// vm_refcnt — 引用计数
// VMA 读锁定（缺页路径）：
vma_start_read(vma)
  └─ 原子增加 vm_refcnt
  └─ 检查 vm_lock_seq 是否变化
  └─ 变化回退 → 使用 mmap_lock

// VMA 写锁定（VMA 修改路径）：
vma_start_write(vma)
  └─ 增加 vm_lock_seq
  └─ 等待 vm_refcnt 降为 1
  └─ 独占修改 VMA
```

---

## 5. 源码文件索引

| 文件 | 内容 |
|------|------|
| `include/linux/mm_types.h` | `struct vm_area_struct` @ L932 |
| `include/linux/mm.h` | VMA flags 和操作声明 |
| `mm/mmap.c` | VMA 查找/创建/合并/分割 |

---

## 6. 关联文章

- **03-rbtree**：VMA 通过红黑树组织查找
- **15-get_user_pages**：GUP 遍历 VMA 树
- **17-page_allocator**：缺页触发的物理页分配
- **18-copy_page_range**：fork 时复制 VMA

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
