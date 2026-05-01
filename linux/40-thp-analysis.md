# 40-thp — Linux 透明大页深度源码分析

> 基于 Linux 7.0-rc1 主线源码

---

## 0. 概述

**Transparent Huge Pages (THP)** 自动将 4KB 页面合并为 2MB 大页，减少 TLB miss，提升内存密集型应用的性能。

---

## 1. 配置

```bash
# 查看 THP 状态
cat /sys/kernel/mm/transparent_hugepage/enabled
[always] madvise never

# 使用 madvise 模式（仅 MADV_HUGEPAGE 映射）
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
```

---

## 2. 实现机制

khugepaged 内核线程周期性扫描内存，将符合条件的 4KB 页合并为 2MB 大页。

---

## 3. 源码文件索引

| 文件 | 内容 |
|------|------|
| mm/khugepaged.c | 大页合并线程 |
| mm/huge_memory.c | 大页内存管理 |

---

## 4. 关联文章

- **189-THP**: THP 深度分析

---

*分析工具：doom-lsp*
