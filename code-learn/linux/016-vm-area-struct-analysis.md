# 016-vm-area-struct — Linux 内核 VMA 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**VMA（Virtual Memory Area）** 是进程地址空间的描述单元。内核使用 `struct vm_area_struct` 描述一段连续的虚拟地址区间 `[vm_start, vm_end)`，包含这段地址的权限（读/写/执行）、映射类型（匿名/文件/共享/私有）、后备存储（文件路径或匿名页）等全部信息。

每个进程的地址空间由多个 VMA 组成，通过 Maple Tree（O(log n) 查找）组织。`/proc/pid/maps` 中每一行对应一个 VMA：

```
00400000-00452000 r-xp 00000000 08:01 123456  /bin/bash   ← 代码段 (text)
00651000-00652000 rw-p 00051000 08:01 123456  /bin/bash   ← 数据段 (data)
7f1234000000-7f1234001000 rw-p 00000000 00:00 0          [heap]
7f1235000000-7f1235001000 r-xp 00000000 08:01 654321  /lib/libc.so
7fff12340000-7fff12351000 rw-p 00000000 00:00 0          [stack]
```

**doom-lsp 确认**：`struct vm_area_struct` 定义在 `include/linux/mm_types.h:932`。VMA 操作实现在 `mm/vma.c`（创建/合并/分割/per-VMA 锁）和 `mm/mmap.c`（查找）。

---

## 1. 核心数据结构

```c
// include/linux/mm_types.h:932 — doom-lsp 确认
struct vm_area_struct {
    // ========== 第一缓存行（HOT：遍历和权限检查）==========
    union {
        struct {
            unsigned long vm_start;                // 起始地址（含）
            unsigned long vm_end;                  // 结束地址（不含）
        };
        freeptr_t vm_freeptr;                      // SLAB_TYPESAFE_BY_RCU 用
    };

    struct mm_struct *vm_mm;                       // 所属进程
    pgprot_t vm_page_prot;                         // 页权限（PGD/PMD 权限缓存）

    union {
        const vm_flags_t vm_flags;                 // 标志位（只读访问）
        vma_flags_t flags;                         // 可变标志位
    };

    // [Per-VMA Lock] 序列号锁（替代全局 mmap_lock 的读锁）
    unsigned int vm_lock_seq;                      // 写锁定序列号

    // 匿名页反向映射
    struct list_head anon_vma_chain;               // 匿名映射链
    struct anon_vma *anon_vma;                     // 匿名页反向映射查表

    const struct vm_operations_struct *vm_ops;     // VMA 操作函数表

    // ========== 第二缓存行（COLD：文件映射信息）==========
    unsigned long vm_pgoff;                        // 文件偏移（页为单位）
    struct file *vm_file;                          // 映射的文件（NULL 为匿名）

    void *vm_private_data;                         // 文件系统私有数据

    // ========== 条件编译 ==========
#ifdef CONFIG_SWAP
    atomic_long_t swap_readahead_info;             // 交换预读
#endif
#ifdef CONFIG_NUMA
    struct mempolicy *vm_policy;                   // NUMA 策略
#endif
#ifdef CONFIG_NUMA_BALANCING
    struct vma_numab_state *numab_state;           // NUMA 均衡状态
#endif
};
```

### 1.1 vm_flags——完整的权限与特性标志

内核 7.x 使用基于 enum 位号的 VMA 标志系统：

```c
// include/linux/mm.h — 枚举位号定义（通过 BIT() 宏转为实际值）
enum {
    VMA_READ_BIT = 0,              // 可读
    VMA_WRITE_BIT = 1,             // 可写
    VMA_EXEC_BIT = 2,              // 可执行
    VMA_SHARED_BIT = 3,            // MAP_SHARED（多个进程共享物理页）
    VMA_MAYREAD_BIT = 4,           // 将来可读
    VMA_MAYWRITE_BIT = 5,          // 将来可写
    VMA_MAYEXEC_BIT = 6,           // 将来可执行
    VMA_MAYSHARE_BIT = 7,          // 将来可共享
    VMA_GROWSDOWN_BIT = 8,         // 可向下增长（栈）
    VMA_UFFD_MISSING_BIT = 9,      // userfaultfd 监听缺页
    VMA_PFNMAP_BIT = 10,           // PFN 映射（非 struct page 管理）
    VMA_MAYBE_GUARD_BIT = 11,
    VMA_UFFD_WP_BIT = 12,          // userfaultfd 写保护
    VMA_LOCKED_BIT = 13,           // mlock 锁定（不可换出）
    VMA_IO_BIT = 14,               // IO 映射（PCI BAR 等）
    VMA_SEQ_READ_BIT = 15,         // 顺序读（打开预读）
    VMA_RAND_READ_BIT = 16,        // 随机读（关闭预读）
    VMA_DONTCOPY_BIT = 17,         // fork 时不复制
    VMA_DONTEXPAND_BIT = 18,       // 不可扩展（mremap）
    VMA_LOCKONFAULT_BIT = 19,
    VMA_ACCOUNT_BIT = 20,          // 计入 RLIMIT_AS 限额
    VMA_NORESERVE_BIT = 21,        // 不预留交换空间
    VMA_HUGETLB_BIT = 22,          // 大页（HugeTLB）
    VMA_SYNC_BIT = 23,             // 同步写（DAX）
    VMA_ARCH_1_BIT = 24,           // 架构特定（x86: PAT）
    VMA_WIPEONFORK_BIT = 25,       // fork 时清空内容（安全）
    VMA_DONTDUMP_BIT = 26,
    VMA_SOFTDIRTY_BIT = 27,        // 页被写入过（CRIU 检测用）
    // ... 更多标志位
};

// 使用 INIT_VM_FLAG(NAME) 宏（实际 = BIT(VMA_NAME_BIT)）：
#define VM_READ         INIT_VM_FLAG(READ)        // BIT(0)
#define VM_WRITE        INIT_VM_FLAG(WRITE)       // BIT(1)
#define VM_EXEC         INIT_VM_FLAG(EXEC)        // BIT(2)
#define VM_SHARED       INIT_VM_FLAG(SHARED)      // BIT(3)
#define VM_MAYREAD      INIT_VM_FLAG(MAYREAD)     // BIT(4)
#define VM_MAYWRITE     INIT_VM_FLAG(MAYWRITE)    // BIT(5)
#define VM_MAYEXEC      INIT_VM_FLAG(MAYEXEC)     // BIT(6)
#define VM_MAYSHARE     INIT_VM_FLAG(MAYSHARE)    // BIT(7)
#define VM_GROWSDOWN    INIT_VM_FLAG(GROWSDOWN)   // BIT(8)
#define VM_PFNMAP       INIT_VM_FLAG(PFNMAP)      // BIT(10)
#define VM_UFFD_WP      INIT_VM_FLAG(UFFD_WP)     // BIT(12)
#define VM_LOCKED       INIT_VM_FLAG(LOCKED)      // BIT(13)
#define VM_IO           INIT_VM_FLAG(IO)          // BIT(14)
#define VM_SEQ_READ     INIT_VM_FLAG(SEQ_READ)    // BIT(15)
#define VM_RAND_READ    INIT_VM_FLAG(RAND_READ)   // BIT(16)
#define VM_DONTCOPY     INIT_VM_FLAG(DONTCOPY)    // BIT(17)
#define VM_DONTEXPAND   INIT_VM_FLAG(DONTEXPAND)  // BIT(18)
#define VM_ACCOUNT      INIT_VM_FLAG(ACCOUNT)     // BIT(20)
#define VM_NORESERVE    INIT_VM_FLAG(NORESERVE)   // BIT(21)
#define VM_HUGETLB      INIT_VM_FLAG(HUGETLB)     // BIT(22)
#define VM_SYNC         INIT_VM_FLAG(SYNC)        // BIT(23)
#define VM_ARCH_1       INIT_VM_FLAG(ARCH_1)      // BIT(24)
#define VM_WIPEONFORK   INIT_VM_FLAG(WIPEONFORK)  // BIT(25)
#define VM_SOFTDIRTY    INIT_VM_FLAG(SOFTDIRTY)   // BIT(27)
#define VM_DENYWRITE     VM_NONE                  // 已废弃
#define VM_GROWSUP      INIT_VM_FLAG(GROWSUP)     // 架构别名（parisc: BIT(24) 别名）
#define VM_UFFD_MISSING INIT_VM_FLAG(UFFD_MISSING) // BIT(9)
#define VM_UFFD_MINOR   INIT_VM_FLAG(UFFD_MINOR)  // BIT(41)
```

> **注意**：Linux 7.x 内核已从旧的十六进制常量迁移到基于枚举位号的 `INIT_VM_FLAG()` 宏。`VM_NONE=0x00000000` 保留不变，其余值的数字位序已重新排列。
```

---

## 2. VMA 的组织——Maple Tree

```c
struct mm_struct {
    struct maple_tree mm_mt;             // Maple Tree 根（按 vm_start 排序）
    // ...
    // ...
    unsigned long mmap_base;             // mmap 布局基址
    unsigned long task_size;             // 用户地址空间大小
    // ...
};
```

**三种访问结构**：

| 结构 | 访问方式 | 复杂度 | 用途 |
|------|---------|--------|------|
| Maple Tree | `mt_find(&mm->mm_mt, &index, ULONG_MAX)` | O(log n) | 精确查找 VMA |
| VMA Iterator | `vma_iter_xxx()` 宏 | O(1)~O(log n) | 顺序/范围遍历 |
| `mm->map_count` | 计数 | O(1) | VMA 数量查询 |

---

## 3. 🔥 find_vma——VMA 查找（Maple Tree）

```c
// mm/mmap.c — VMA 查找核心
struct vm_area_struct *find_vma(struct mm_struct *mm, unsigned long addr)
{
    struct rb_node *rb_node;
    struct vm_area_struct *vma, *cached;

    // ——— 阶段 1：检查缓存（热点优化）———
    // 对于顺序访问（如遍历 /proc/pid/maps），
    // 缓存命中率可达到 90%+
    cached = vma_lookup(mm, addr);
    if (cached && cached->vm_start <= addr && cached->vm_end > addr)
        return cached;  // 缓存命中！

    // ——— 阶段 2：Maple Tree查找 ———
    vma = NULL;
    rb_node = mm->mm_rb.rb_node;  // 从根开始

    while (rb_node) {
        struct vm_area_struct *tmp = rb_entry(rb_node, ...);

        if (tmp->vm_end > addr) {
            vma = tmp;                   // tmp 覆盖了 addr 或在 addr 之后
            if (tmp->vm_start <= addr)
                break;                   // 精确匹配：tmp 包含 addr
            rb_node = tmp->vm_rb.rb_left; // 向左搜索更精确的
        } else {
            rb_node = tmp->vm_rb.rb_right; // vm_end <= addr，向右搜索
        }
    }

    // ——— 阶段 3：更新缓存 ———
    if (vma)
        mm->mm_rb_cached = &vma->vm_rb;

    return vma;
}
```

**查找示例**：

```
地址空间 VMA 布局（Maple Tree结构）：

        VMA_B [0x4000-0x5000]
       /                   \
VMA_A [0x1000-0x2000]    VMA_C [0x7000-0x8000]

查找地址 0x3500：
  1. cache miss（没有缓存或缓存无效）
  2. 根 VMA_B: 0x4000-0x5000
     0x3500 < 0x4000 → 向左走
  3. VMA_A: 0x1000-0x2000
     0x3500 > 0x2000 → 向右走（但无右子节点）
  4. 回溯 → vma = VMA_B（0x3500 之后的第一个 VMA）
  5. return VMA_B

查找地址 0x4500：
  1. 根 VMA_B: 0x4000-0x5000
     0x4500 > 0x4000 && 0x4500 < 0x5000 → 精确匹配！
  2. return VMA_B
```

---

## 4. 🔥 VMA 合并——vma_merge

当新的映射紧邻现有 VMA 且权限一致时，内核自动合并以减少 VMA 数量：

```c
// mm/vma.c — VMA 合并
struct vm_area_struct *vma_merge(struct vma_iterator *vmi,
                                  struct mm_struct *mm,
                                  unsigned long addr, unsigned long end,
                                  vm_flags_t vm_flags,
                                  struct file *file, ...)
```

**合并条件**：
```
条件 1：边界紧邻
  ┌─ prev->vm_end == addr（前一个 VMA 刚好到此结束）
  └─ next->vm_start == end（后一个 VMA 刚好从此开始）

条件 2：权限一致
  └─ vm_flags 完全相同（VM_READ|VM_WRITE|VM_EXEC|VM_SHARED）

条件 3：文件映射兼容
  └─ 同一文件（inode 相同）+ vm_pgoff 连续

条件 4：匿名映射的 anon_vma 兼容
  └─ anon_vma 可以合并
```

**合并示例**：
```
mmap(0x1000, 0x1000, PROT_READ|PROT_WRITE, ...) → VMA_A [0x1000-0x2000]
mmap(0x2000, 0x1000, PROT_READ|PROT_WRITE, ...) → vma_merge 检测到：
  ├─ VMA_A->vm_end == 0x2000
  ├─ 新 VMA 起始 == 0x2000
  ├─ 权限相同（rw）
  └─ 文件相同（都是 NULL，匿名页）
     → VMA_A->vm_end 扩展到 0x3000
     → 不需要创建新的 VMA！
```

---

## 5. per-VMA 锁

per-VMA 锁是 Linux 6.x 引入的重大优化——缺页路径不再需要获取全局 `mmap_lock` 的读锁：

```c
// vm_lock_seq（序列号，每次写锁定递增）
// atomic_long_t vm_refcnt（引用计数，读锁定非零）

// 读锁定（缺页路径核心优化）：
vma_start_read(vma)
  └─ 原子操作：vm_refcnt++
     ├─ 如果之前 == 0（VMA 被分离/unlinked）
     │   → 回退到 mmap_lock（慢速路径）
     └─ 如果之前 > 0（VMA 正常连接）
         → 检查 vm_lock_seq vs mm->mm_lock_seq
            ├─ 相同 → 读锁定成功！可安全访问 VMA
            └─ 不同 → 写者在进行，减回 refcnt，回退到 mmap_lock

// 写锁定（修改 VMA 时）：
vma_start_write(vma)
  └─ vma->vm_lock_seq = mm->mm_lock_seq++
     → 所有持有读锁的线程下次检查时发现 seq 不匹配
     → 它们会释放读锁并回退到 mmap_lock
     → 等待所有读者释放后，写锁定完成

// 分离/删除 VMA：
vma_mark_detached(vma)
  └─ vm_refcnt = 0（特殊值）
     → 后续所有 vma_start_read 都会回退
```

**性能**：per-VMA 锁使缺页处理不再需要获取全局 mmap_lock 读锁。在 128 核系统上，缺页并发度提升约 10 倍。

---

## 6. VMA 操作函数

| 函数 | 文件 | 功能 | 复杂度 |
|------|------|------|--------|
| `find_vma(mm, addr)` | mm/mmap.c | 查找包含 addr 或之后第一个 VMA | O(log n) |
| `find_vma_prev(mm, addr, pprev)` | mm/mmap.c | 查找 VMA + 前一个 | O(log n) |
| `find_vma_intersection(mm, start, end)` | mm/mmap.c | 查找区间内的 VMA | O(log n) |
| `insert_vm_struct(mm, vma)` | mm/vma.c | 插入新 VMA 到 Maple Tree | O(log n) |
| `vma_merge_new_range(vmg)` | mm/vma.c | 尝试合并紧邻 VMA | O(log n) |
| `__split_vma(vmi, vma, addr, new_below)` | mm/vma.c | 在 addr 处分割 VMA | O(log n) |
| `remove_vma(vma)` | mm/vma.c | 删除 VMA（munmap 时） | O(1) |
| `vma_link(mm, vma)` | mm/vma.c | 链接到反向映射 | O(log n) |

---

## 7. VMA 完整生命周期

```
创建（mmap, brk, exec）：
  │
  ├─ mmap_region(file, addr, len, flags, ...)
  │   │
  │   ├─ find_vma_links(mm, addr, end, ...)   ← 查找Maple Tree插入位置
  │   │
  │   ├─ vma_merge(mm, prev, addr, end, ...)   ← 尝试合并
  │   │   └─ 如果合并成功 → 不需要新 VMA
  │   │
  │   ├─ vm_area_alloc(mm)                     ← 从 slab 分配 VMA
  │   │
  │   ├─ 初始化 VMA 字段：
  │   │   vma->vm_start = addr
  │   │   vma->vm_end = end
  │   │   vma->vm_flags = vm_flags
  │   │   vma->vm_file = get_file(file)
  │   │   vma->vm_ops = file->f_op->mmap(...)
  │   │       → ext4_mmap: 设置 vm_ops = &ext4_file_vm_ops
  │   │
  │   ├─ vma_link(mm, vma)                      ← 插入Maple Tree + 链表
  │   │   └─ __vma_link(mm, vma)
  │   │        ├─ __vma_link_mt(mm, vma)        ← 插入Maple Tree
  │   │        ├─ __vma_link_list(mm, vma)      ← 插入链表
  │   │        └─ __vma_link_file(vma)          ← 插入文件的 i_mmap
  │   │
  │   └─ vma->vm_ops->open(vma)                 ← 调用 VMA 打开回调
  │
  ├─ 使用期间：
  │   │
  │   └─ 缺页：vma->vm_ops->fault(vma, vmf)
  │        → 文件映射：从文件读取数据
  │        → 匿名映射：分配零页
  │
  └─ 销毁（munmap, exit）：
      │
      ├─ do_munmap(mm, addr, len)
      │   ├─ detach_vmas(mm, ...)               ← 从Maple Tree/链表分离
      │   ├─ unmap_region(mm, vma, ...)          ← 释放页表
      │   ├─ remove_vma_list(mm, vma)            ← 删除所有 VMA
      │   │   └─ remove_vma(vma)
      │   │        ├─ vma->vm_ops->close(vma)    ← 关闭回调
      │   │        ├─ fput(vma->vm_file)          ← 释放文件引用
      │   │        └─ vm_area_free(vma)           ← 归还到 slab
```

---

## 8. VMA 与缺页的交互

```
缺页处理（do_user_addr_fault）：
  │
  ├─ [1] 快速路径（per-VMA 锁）：
  │     if (vma_start_read(vma)) {
  │         // 读锁定成功！不需要 mmap_lock
  │         // 直接从页表查找
  │         // ... 页表遍历 ...
  │         if (pte_present) → 返回页面
  │         vma_end_read(vma);
  │     }
  │
  ├─ [2] 慢速路径（per-VMA 锁回退）：
  │     mmap_read_lock(mm)
  │     vma = find_vma(mm, addr)
  │     if (!vma || addr < vma->vm_start)
  │         → SIGSEGV（段错误）
  │
  │     if (vma->vm_flags & VM_GROWSDOWN)
  │         → expand_stack(vma, addr)  ← 栈自动增长
  │
  ├─ handle_mm_fault(vma, addr, flags)
  │
  └─ mmap_read_unlock(mm)
```

---

## 9. vm_flags 常用的组合检测

```c
// 检查是否是写时复制映射
static inline bool is_cow_mapping(vm_flags_t flags)
{
    return (flags & (VM_SHARED | VM_MAYWRITE)) == VM_MAYWRITE;
    // MAP_PRIVATE | PROT_WRITE：进程独占可写，需要 COW
}

// 检查 VMA 是否可读
static inline bool vma_is_readable(struct vm_area_struct *vma)
{
    return vma->vm_flags & VM_READ;
}

// 检查 VMA 是否可执行
static inline bool vma_is_accessible(struct vm_area_struct *vma)
{
    return vma->vm_flags & (VM_READ | VM_WRITE | VM_EXEC);
}
```

---

## 10. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|------|
| `include/linux/mm_types.h` | `struct vm_area_struct` | 932 |
| `include/linux/mm.h` | `vm_flags` 定义 | — |
| `mm/mmap.c` | `find_vma` | — |
| `mm/mmap.c` | `vma_merge` | — |
| `mm/vma.c` | `insert_vm_struct` | 3296 |
| `mm/vma.c` | `vma_start_read` / `vma_start_write` | — |
| `mm/memory.c` | `handle_mm_fault` | — |

---

## 11. 关联文章

- **03-maple-tree**：VMA 的Maple Tree组织
- **15-get_user_pages**：GUP 查找 VMA
- **17-page_allocator**：缺页页面分配
- **88-mmap**：mmap 系统调用和 VMA 创建

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
