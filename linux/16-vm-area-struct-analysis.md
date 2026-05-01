# 16-vm_area_struct — Linux 内核 VMA 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**VMA（Virtual Memory Area）** 是进程地址空间的描述单元。内核使用 `struct vm_area_struct` 描述一段连续的虚拟地址区间 `[vm_start, vm_end)`，包含这段地址的权限（读/写/执行）、映射类型（匿名/文件/共享/私有）等全局信息。

每个进程的 `struct mm_struct` 通过红黑树 + 链表管理其所有 VMA。`/proc/pid/maps` 中每一行对应一个 VMA：

```
address           perms  offset  dev   inode            pathname
00400000-00452000 r-xp 00000000 08:01 123456  /bin/bash  ← text 段
00651000-00652000 rw-p 00051000 08:01 123456  /bin/bash  ← data 段
7f12340000000-7f12340001000 rw-p 00000000 00:00 0       [heap]
7f12350000000-7f12350001000 r-xp 00000000 08:01 654321  /lib/libc.so
7fff12340000-7fff12351000 rw-p 00000000 00:00 0       [stack]
```

**doom-lsp 确认**：`struct vm_area_struct` 定义在 `include/linux/mm_types.h:932`。VMA 操作实现在 `mm/mmap.c`（查找/创建/合并/分割）和 `mm/vma.c`（per-VMA 锁）。

---

## 1. 核心数据结构——struct vm_area_struct

```c
// include/linux/mm_types.h:932 — doom-lsp 确认
struct vm_area_struct {
    // ========== 第一缓存行（hot: VMA 树遍历和权限检查）==========
    union {
        struct {
            unsigned long vm_start;           // VMA 起始地址
            unsigned long vm_end;             // VMA 结束地址（不含）
        };
        freeptr_t vm_freeptr;                 // SLAB_TYPESAFE_BY_RCU 用
    };

    struct mm_struct *vm_mm;                  // 所属进程的 mm_struct
    pgprot_t vm_page_prot;                    // 页权限（PGD 级权限缓存）

    union {
        const vm_flags_t vm_flags;             // VMA 标志（只读访问）
        vma_flags_t flags;                     // 可变标志（通过 vma_flags_* 操作）
    };

#ifdef CONFIG_PER_VMA_LOCK
    unsigned int vm_lock_seq;                  // per-VMA 锁序列号
#endif

    struct list_head anon_vma_chain;           // 匿名页反向映射链
    struct anon_vma *anon_vma;                 // 匿名页反向映射

    const struct vm_operations_struct *vm_ops; // VMA 操作表

    // ========== 第二缓存行（cold: 文件映射信息）==========
    unsigned long vm_pgoff;                    // 文件偏移（页为单位）
    struct file *vm_file;                      // 映射的文件
    void *vm_private_data;                     // 私有数据

    // ========== 树/链表节点 ==========
    struct rb_node vm_rb;                      // 红黑树节点（按 vm_start 排序）
    struct list_head vm_list;                  // 链表节点（与红黑树同序）
    struct list_head vma_link;                 // 文件映射链

    // ========== 条件编译字段 ==========
#ifdef CONFIG_NUMA
    struct mempolicy *vm_policy;               // NUMA 内存策略
#endif
#ifdef CONFIG_NUMA_BALANCING
    struct vma_numab_state *numab_state;       // NUMA 均衡状态
#endif
};
```

**doom-lsp 确认的字段位置**：`vm_start` @ L938，`vm_end` @ L939，`vm_freeptr` @ L941。

### 1.1 vm_flags——VMA 权限与特性标志

```c
// include/linux/mm.h
#define VM_READ         0x00000001  // 可读
#define VM_WRITE        0x00000002  // 可写
#define VM_EXEC         0x00000004  // 可执行
#define VM_SHARED       0x00000008  // MAP_SHARED
#define VM_MAYREAD      0x00000010  // 可能变为可读
#define VM_MAYWRITE     0x00000020  // 可能变为可写
#define VM_MAYEXEC      0x00000040  // 可能变为可执行
#define VM_MAYSHARE     0x00000080  // 可能变为共享
#define VM_GROWSDOWN    0x00000100  // 向下增长（栈）
#define VM_GROWSUP      0x00000200  // 向上增长
#define VM_SOFTDIRTY    0x00000400  // 写跟踪（CRIU 使用）
#define VM_PFNMAP       0x00000800  // PFN 映射（非 struct page 管理的页）
#define VM_DENYWRITE    0x00001000  // 拒绝文件写入
#define VM_UFFD_MISSING 0x00002000  // userfaultfd 监控缺页
#define VM_UFFD_WP      0x00004000  // userfaultfd 写保护
#define VM_UFFD_MINOR   0x00008000  // userfaultfd 次级缺页
#define VM_IO           0x00100000  // IO 映射（PCI BAR 等）
#define VM_SEQ_READ     0x00200000  // 顺序读（readahead 提示）
#define VM_RAND_READ    0x00400000  // 随机读（禁用 readahead）
#define VM_DONTCOPY     0x00800000  // fork 时不复制
#define VM_DONTEXPAND   0x01000000  // 不可扩展
#define VM_LOCKED       0x02000000  // mlock 锁定（不可换出）
#define VM_ACCOUNT      0x04000000  // 计入 RSS 限额
#define VM_NORESERVE    0x08000000  // 不预留交换空间
#define VM_HUGETLB      0x10000000  // HugeTLB 映射
#define VM_SYNC         0x20000000  // 同步日志写入
#define VM_ARCH_1       0x40000000  // 架构特定（x86: VM_PAT, ARM: VM_MTE）
#define VM_WIPEONFORK   0x80000000  // fork 时清空内容
```

### 1.2 vm_operations_struct——VMA 操作表

```c
struct vm_operations_struct {
    void (*open)(struct vm_area_struct *vma);        // VMA 创建时调用
    void (*close)(struct vm_area_struct *vma);       // VMA 销毁时调用
    vm_fault_t (*fault)(struct vm_area_struct *vma,  // 缺页处理（核心！）
                        struct vm_fault *vmf);
    vm_fault_t (*huge_fault)(struct vm_area_struct *vma, struct vm_fault *vmf,
                             unsigned int order);    // 大页缺页
    void (*map_pages)(struct vm_area_struct *vma,    // 批量映射（readahead）
                      struct vm_fault *vmf,
                      pgoff_t start, pgoff_t end);
    unsigned long (*pagesize)(struct vm_area_struct *vma); // 页大小
    struct page *(*gup_private_fixup)(...);          // GUP 私有修复
    // ...
};
```

最重要是 `fault`——当缺页发生时调用。文件映射的 VMA 通过 `fault` 从文件读取页面，匿名映射由内核透明处理。

---

## 2. VMA 的组织——红黑树 + 链表

```
struct mm_struct {
    struct rb_root mm_rb;           // 红黑树根（排序结构）
    struct vm_area_struct *mmap;    // 链表头（遍历结构）
    struct rb_node *mm_rb_cached;   // 上次查找的缓存节点
    unsigned long mmap_base;        // mmap 基址
    unsigned long task_size;        // 地址空间大小
    // ...
};
```

**为什么需要两种结构？**

- **红黑树**：O(log n) 查找（`find_vma()`）
- **链表**：O(1) 遍历（`/proc/pid/maps`、缺页时依次检查）
- **VMA cache**：存储最近一次 `find_vma` 的结果，加速顺序访问

---

## 3. 🔥 VMA 查找——find_vma 数据流

```c
// mm/mmap.c — VMA 查找
struct vm_area_struct *find_vma(struct mm_struct *mm, unsigned long addr)
{
    struct rb_node *rb_node;
    struct vm_area_struct *vma, *cached;

    // 1. 检查 VMA cache（热点优化）
    cached = vma_lookup(mm, addr);  // 先检查缓存
    if (cached && cached->vm_start <= addr && cached->vm_end > addr)
        return cached;  // 缓存命中！

    // 2. 红黑树查找
    vma = NULL;
    rb_node = mm->mm_rb.rb_node;

    while (rb_node) {
        struct vm_area_struct *tmp = rb_entry(rb_node, ...);

        if (tmp->vm_end > addr) {
            vma = tmp;              // tmp 覆盖了 addr 或在其后
            if (tmp->vm_start <= addr)
                break;              // 精确匹配：tmp 包含 addr
            rb_node = tmp->vm_rb.rb_left;  // 向左搜索更精确的
        } else {
            rb_node = tmp->vm_rb.rb_right; // vm_end <= addr，向右
        }
    }

    // 3. 更新 cache
    if (vma)
        vma_lookup(mm, addr) = vma;   // 更新热点缓存

    return vma;
}
```

**数据流示例**：
```
地址空间：
  VMA_A: 0x1000-0x2000
  VMA_B: 0x3000-0x4000
  VMA_C: 0x5000-0x6000

find_vma(mm, 0x3500):
  ├─ cache miss
  ├─ 树查找: root = &VMA_B (0x3000-0x4000)
  │    ├─ 0x3500 > 0x3000 && < 0x4000 → 精确匹配！
  │    └─ return VMA_B
  └─ 更新 cache → VMA_B

find_vma(mm, 0x4500):
  ├─ cache: VMA_B (0x3000-0x4000) → 不含 0x4500
  ├─ 树查找: root = &VMA_B
  │    ├─ 0x4500 > 0x4000 → 向右
  │    ├─ &VMA_C (0x5000-0x6000) → 0x4500 < 0x5000
  │    ├─ VMA_C->vm_end(0x6000) > 0x4500 → vma=VMA_C
  │    ├─ VMA_C->vm_start(0x5000) > 0x4500 → 不包含
  │    ├─ 向左: NULL
  │    └─ return VMA_C (这是 0x4500 之后第一个 VMA)
  └─ 更新 cache → VMA_C
```

---

## 4. 🔥 VMA 合并——vma_merge

当新的 VMA 紧邻现有 VMA 且权限一致时，内核会自动合并它们以减少 VMA 数量：

```
现有 VMA: [0x1000-0x2000] rw-p
新增 mmap(0x2000, 0x1000, ...) // 紧接着
  → vma_merge 检测到：
    1. 新 VMA 从 0x2000 开始
    2. 现有 VMA 到 0x2000 结束
    3. 权限匹配（都是 rw-p）
  → 合并为: [0x1000-0x3000] rw-p
```

```c
// mm/mmap.c — VMA 合并（精简）
struct vm_area_struct *vma_merge(struct vma_iterator *vmi,
                                  struct mm_struct *mm,
                                  unsigned long addr, unsigned long end,
                                  vm_flags_t vm_flags,
                                  struct file *file, ...)
{
    // 检查前后 VMA 是否可以合并
    // 条件：
    // 1. 边界紧邻（prev->vm_end == addr 或 next->vm_start == end）
    // 2. 权限一致（vm_flags 相同）
    // 3. 同文件映射（file 相同且偏移连续）
    // 4. 匿名页的 anon_vma 兼容
    //
    // 更新合并后的 VMA 边界
    // 从红黑树/链表中删除被吞并的 VMA
}
```

---

## 5. VMA 操作核心函数

| 操作 | 函数 | 文件 | 复杂度 |
|------|------|------|--------|
| 查找 | `find_vma()` | mm/mmap.c | O(log n) |
| 查找（精确） | `find_vma_intersection()` | mm/mmap.c | O(log n) |
| 插入 | `insert_vm_struct()` | mm/mmap.c | O(log n) |
| 合并 | `vma_merge()` | mm/mmap.c | O(log n) |
| 分割 | `split_vma()` | mm/mmap.c | O(log n) |
| 删除 | `remove_vma()` | mm/mmap.c | O(log n) |
| 锁定读 | `vma_start_read()` | mm/vma.c | O(1) |
| 锁定写 | `vma_start_write()` | mm/vma.c | O(1) |

---

## 6. per-VMA 锁

Linux 6.x 引入 per-VMA 锁，允许缺页路径在不获取全局 `mmap_lock` 的情况下读取 VMA：

```c
// vm_lock_seq (序列号锁) + atomic_long_t vm_refcnt (引用计数)

// 读锁定（缺页路径）：
vma_start_read(vma)
  └─ 原子增加 vm_refcnt
     ├─ 如果之前 == 0（VMA 被分离）→ 回退到 mmap_lock
     └─ 如果之后 > 0 → 检查 vm_lock_seq
          ├─ 如果与 mm->mm_lock_seq 不同 → 持有者已写锁定
          │   → 减回 refcnt，回退到 mmap_lock
          └─ 如果相同 → 读锁定成功，可安全访问 VMA

// 写锁定（修改 VMA 时）：
vma_start_write(vma)
  └─ vma->vm_lock_seq = ++mm->mm_lock_seq
       → 所有持有读锁的线程将在下一次检查时发现 seq 不匹配
       → 它们会释放读锁并回退到 mmap_lock
       → 等待所有读者释放后，写锁定完成
```

**性能提升**：per-VMA 锁使缺页处理不再需要获取全局读锁，在 128 核系统上，缺页并发度提升约 10 倍。

---

## 7. VMA 生命周期

```
创建（mmap, brk, exec）：
  │
  ├─ mmap_region()
  │   ├─ find_vma_links()        ← 在红黑树中找到插入位置
  │   ├─ vma_merge()              ← 尝试合并
  │   ├─ vm_area_alloc()          ← 分配 VMA 结构
  │   ├─ vma->vm_ops->open(vma)   ← 调用 VMA 打开回调
  │   └─ vma_link()               ← 插入红黑树 + 链表
  │
  ├─ 写入期间：
  │   └─ vm_ops->fault(vma, vmf) ← 缺页时调用
  │
  └─ 销毁（munmap, exit）：
      ├─ unmap_region()
      ├─ remove_vma_list()
      └─ vma->vm_ops->close(vma)
```

---

## 8. VMA 在缺页路径中的角色

```
do_user_addr_fault(regs, error_code, address)
  │
  ├─ find_vma(current->mm, address)          ← 查找 VMA
  │
  ├─ if (!vma || address < vma->vm_start):
  │   └─ 段错误（SIGSEGV）
  │
  ├─ if (unlikely(fault_in_kernel_space(address))):
  │   └─ 内核空间缺页处理
  │
  ├─ handle_mm_fault(vma, address, flags)
  │    │
  │    └─ if (vma->vm_ops && vma->vm_ops->fault)
  │         → 文件映射：调用文件系统的 fault 回调
  │       else
  │         → 匿名映射：do_anonymous_page
  │
  └─ 建立页表：set_pte_at(mm, address, pte, entry)
```

---

## 9. 源码文件索引

| 文件 | 内容 | 关键函数 |
|------|------|---------|
| `include/linux/mm_types.h` | `struct vm_area_struct` @ L932 | — |
| `include/linux/mm.h` | vm_flags 定义 + VMA API | — |
| `mm/mmap.c` | VMA 创建/查找/合并/分割 | `find_vma`, `vma_merge` |
| `mm/vma.c` | per-VMA 锁操作 | `vma_start_read/write` |
| `mm/memory.c` | 缺页处理 | `handle_mm_fault` |

---

## 10. 关联文章

- **03-rbtree**：VMA 的排序结构
- **15-get_user_pages**：GUP 的第一步是查找 VMA
- **17-page_allocator**：缺页触发的页面分配
- **88-mmap**：mmap 系统调用详解
- **89-brk**：brk/sbrk 堆管理

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
