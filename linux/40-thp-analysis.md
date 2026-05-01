# 40-thp — Linux 透明大页深度源码分析

> 基于 Linux 7.0-rc1 主线源码

---

## 0. 概述

**Transparent Huge Pages (THP)** 自动将 4KB 页合并为 2MB 大页，减少 TLB miss，提升内存密集型应用的性能。

---

## 1. 配置

```bash
# 状态
cat /sys/kernel/mm/transparent_hugepage/enabled
[always] madvise never

# 选择 madvise 模式（仅对 MADV_HUGEPAGE 映射生效）
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled

# 查看整理碎片
cat /sys/kernel/mm/transparent_hugepage/defrag
[always] defer defer+madvise madvise never
```

---

## 2. khugepaged 合并线程

khugepaged 内核线程扫描进程内存，将符合条件的 4KB 小页合并为 2MB 大页：

```c
// mm/khugepaged.c
khugepaged_scan_mm_slot()
  ├─ 遍历进程的 VMA
  ├─ 检查 VMA 是否可合并（地址对齐、权限一致）
  ├─ 扫描 PTEs，收集 512 个连续 4KB 页
  ├─ 分配 2MB 大页
  ├─ 拷贝内容到新大页
  └─ 更新页表：512 个 PTE → 1 个 PMD
```

---

## 3. THP 带来的好处

| 页大小 | TLB 覆盖 | 缺页次数 | 页表大小 |
|--------|---------|---------|---------|
| 4KB | 2MB/TLB | 512/GB | 512 PTEs/GB |
| 2MB | 1GB/TLB | 512/GB | 1 PMD/GB |

---

## 4. 源码文件索引

| 文件 | 内容 |
|------|------|
| mm/huge_memory.c | 大页管理 |
| mm/khugepaged.c | 合并线程 |
| include/linux/huge_mm.h | API |

---

## 5. 关联文章

- **189-THP**: THP 深度分析

---
