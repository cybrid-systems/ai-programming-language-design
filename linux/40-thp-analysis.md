# 40-THP — 透明大页深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**透明大页（THP, Transparent Huge Pages）** 自动将 4KB 的常规页合并为 2MB 的大页（x86_64），减少 TLB miss，提升内存密集型应用的性能。与手动 hugetlbfs 不同，THP 对应用程序透明。

---

## 1. 核心机制

### 1.1 大页分配路径

```
处理缺页（handle_mm_fault）：
  │
  ├─ 常规 4KB 路径：
  │    └─ handle_pte_fault() → do_anonymous_page()
  │
  └─ THP 路径（if vma->flags & VM_HUGEPAGE）：
       └─ create_huge_pmd(vmf)
            ├─ 一次分配 2MB 连续物理页（512 页）
            │    └─ alloc_hugepage_vma()
            │
            ├─ pmd = 大页页表项（覆盖 512 个 PTE）
            │    └─ set_pmd_at(mm, addr, pmd, entry)
            │
            └─ 页表只有 4 级：PGD → PUD → PMD → PTE
                 THP 跳过 PTE 级别，PMD 直接指向 2MB 物理块
```

### 1.2 碎片整理（khugepaged）

```
khugepaged 内核线程：
  │
  ├─ 扫描进程的 VMA
  │
  ├─ 如果发现 VMA 中的 512 个连续 4KB 页
  │  （满足条件：可合并、未锁定、未脏等）
  │
  └─ collapse_huge_page(vma, addr, page)
       ├─ 分配 2MB 连续大页
       ├─ 复制 512 个 4KB 页的内容
       ├─ 释放原来的常规页
       └─ 修改页表为 PMD 大页映射
```

---

## 2. 控制选项

| 选项 | 效果 |
|------|------|
| `always` | 尽可能分配 THP |
| `madvise` | 仅 MADV_HUGEPAGE 标记的 VMA |
| `never` | 禁用 THP |

---

*分析工具：doom-lsp（clangd LSP）*
