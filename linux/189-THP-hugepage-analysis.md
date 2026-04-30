# 189-THP_hugepage — 透明大页深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/huge_memory.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**THP（Transparent HugePages）** 自动将多个 4KB 页合并成 2MB 大页，减少页表开销，提升 TLB 命中率。

---

## 1. THP vs 普通页

```
普通页：4KB
THP：2MB（512个普通页）

TLB 条目：
  4KB 页面：每个条目覆盖 4KB
  2MB THP：每个条目覆盖 2MB = 512x 覆盖

性能收益：
  - TLB 命中率提高（减少 TLB miss）
  - 页表占用减少（一个 PTE → 一个 PMD）
  - 内存带宽提升（一次预取 2MB）
```

---

## 2. khugepaged

```c
// mm/huge_memory.c — khugepaged
// 后台守护进程，自动将符合条件的匿名页合并成 THP

// 扫描条件：
//   - 是匿名映射（file-backed 不合并）
//   - VMA 足够大（>VMA_MIN_SIZE）
//   - 页都是干净的、连续的

// collapse_huge_page() 核心：
//   1. 分配 2MB 连续物理页
//   2. 将 512 个 4KB 页内容复制到 2MB 页
//   3. 替换页表（PMD 级别）
//   4. 释放原来的 512 个 4KB 页
```

---

## 3. MADV_HUGEPAGE / MADV_NOHUGEPAGE

```c
// 建议内核启用 THP：
madvise(addr, len, MADV_HUGEPAGE);

// 建议内核禁用 THP：
madvise(addr, len, MADV_NOHUGEPAGE);
```

---

## 4. 西游记类喻

**THP** 就像"天庭的集装箱化仓储"——

> 以前每个小妖怪住一个小营房（4KB 页），天庭要找妖怪，得查 512 个营房地址（T  B miss）。THP 像把 512 个小营房合并成一个大连排房（2MB THP），天庭只需要记住一个地址，就能找到所有人。好处是找妖怪快（TLB 高命中率），坏处是如果某个小妖怪搬走了（页被换出），整个大连排房都要动一下。

---

## 5. 关联文章

- **page_allocator**（article 17）：THP 底层使用 page allocator
- **KSM**（相关）：THP 和 KSM 都管理大页