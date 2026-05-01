# 18-copy_page_range — 页表复制深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**copy_page_range** 是 `fork()` 系统调用的核心内存操作。当 Linux 创建一个子进程时，需要复制父进程的页表——让子进程看到相同的内存视图，但通过 **写时复制（COW, Copy-on-Write）** 机制，物理页框本身并不立即复制。

COW 的核心思想：**父进程和子进程共享同一份物理内存，但标记为只读。当任意一方尝试写入时，触发缺页异常，此时才复制物理页。**

doom-lsp 确认 `mm/memory.c` 包含 copy_page_range 及其相关函数。

---

## 1. 核心函数：copy_page_range

```c
int copy_page_range(struct mm_struct *dst_mm, struct mm_struct *src_mm,
                    struct vm_area_struct *vma)
```

```
copy_page_range(dst_mm, src_mm, vma)
  │
  ├─ 遍历 src_mm 中 VMA 覆盖的所有页表
  │
  ├─ 对每级页表：
  │    ├─ PGD → P4D → PUD → PMD → PTE
  │
  ├─ 对每个 PTE（页表项）：
  │    │
  │    ├─ [匿名页] copy_pte_range → copy_one_pte
  │    │    ├─ 复制 PTE 到子进程的页表
  │    │    ├─ 父进程 PTE 标记为只读
  │    │    ├─ struct page->_mapcount 增加
  │    │    └─ 设置 pte_wrprotect（清除写权限）
  │    │
  │    ├─ [文件映射页] copy_pte_range
  │    │    ├─ 增加 page cache 的引用计数
  │    │    ├─ 复制 PTE
  │    │    └─ 如果 MAP_PRIVATE → 同样写保护
  │    │
  │    └─ [交换页] copy_pte_range
  │         └─ 增加交换计数，复制交换 entry
  │
  └─ return 0（成功）
```

---

## 2. 写时复制（COW）触发

子进程创建后，所有可写页面都被标记为只读。当父或子首次写入时：

```
写入操作 → CPU 触发页错误（page fault）
  │
  └─ handle_mm_fault(vma, addr, FAULT_FLAG_WRITE)
       │
       ├─ 检查 VMA 权限（VM_WRITE 是否设置）
       │
       ├─ handle_pte_fault(vmf)
       │    │
       │    ├─ 如果 PTE 不存在 → do_anonymous_page() 或 do_fault()
       │    │
       │    └─ 如果 PTE 存在但写保护 → do_wp_page()
       │         │
       │         └─ do_wp_page(vmf)
       │              │
       │              ├─ 检查引用计数（_mapcount）
       │              │
       │              ├─ 如果只有一个人引用：
       │              │    └─ 直接修改 PTE 权限为可写（取消 COW）
       │              │
       │              ├─ 如果多个人引用：
       │              │    ├─ alloc_page_vma() → 分配新物理页
       │              │    ├─ copy_user_highpage() → 复制内容
       │              │    ├─ 修改 PTE 指向新页（可写）
       │              │    └─ 原页引用计数减一
```

---

## 3. 关键细节

### 3.1 引用计数检查

```c
// mm/memory.c — do_wp_page 中的优化
if (page_mapcount(old_page) == 1) {
    // 只有这个进程在使用该页
    // 直接取消写保护即可，不需要复制
    pte = pte_mkwrite(pte);
    set_pte_at(vmf->vma->vm_mm, vmf->address, vmf->pte, pte);
    return;
}
```

如果引用计数为 1（只有当前进程），就不需要复制——直接改为可写即可。

### 3.2 透明大页（THP）的 COW

对于透明大页，copy_page_range 调用 `copy_huge_pmd`：

```c
int copy_huge_pmd(struct mm_struct *dst_mm, struct mm_struct *src_mm,
                  pmd_t *dst_pmd, pmd_t *src_pmd, unsigned long addr,
                  struct vm_area_struct *vma)
```

透明大页的 COW 需要复制整个 2MB 大页（512个 4KB 页），而不是逐 PTE 处理。

---

## 4. 数据流全景

```
fork()
  │
  ├─ dup_mm()   ← 复制 mm_struct
  │    │
  │    ├─ allocate_mm()         ← 分配新 mm_struct
  │    │
  │    ├─ dup_mmap()            ← 复制所有 VMA
  │    │    │
  │    │    └─ 对每个 VMA：
  │    │         └─ copy_page_range(dst_mm, src_mm, vma)
  │    │              │
  │    │              └─ 遍历 VMA 中所有页表
  │    │                   └─ 每个 PTE 设置写保护
  │    │
  │    └─ mm->mmap 建立完毕

父进程写入：
  → 缺页 → do_wp_page() → 复制页 → 继续

子进程写入：
  → 缺页 → do_wp_page() → 复制页 → 继续
```

---

## 5. 设计决策总结

| 决策 | 原因 |
|------|------|
| 写时复制（COW） | 避免 fork 后立即复制大量物理页 |
| 引用计数==1 优化 | 如果只有自己引用，免去复制 |
| 逐 VMA 处理 | 根据 VMA 类型（匿名/文件）采取不同策略 |
| THP 的 pmd 级别复制 | 大页的 COW 以 2MB 为单位 |

---

## 6. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `mm/memory.c` | `copy_page_range` | 页表复制 |
| `mm/memory.c` | `do_wp_page` | 写时复制缺页处理 |
| `mm/memory.c` | `copy_pte_range` | PTE 级别复制 |
| `mm/huge_memory.c` | `copy_huge_pmd` | THP 复制 |

---

## 7. 关联文章

- **VMA**（article 16）：copy_page_range 遍历 VMA 地址范围的页表
- **page_allocator**（article 17）：COW 触发时，从 buddy 分配新页
- **THP**（article 40）：透明大页的 COW 行为不同

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
