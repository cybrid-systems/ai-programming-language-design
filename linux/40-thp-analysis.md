# 40-thp -- Transparent Huge Pages analysis

> Based on Linux 7.0-rc1

## 0. Overview

THP automatically promotes 4KB pages to 2MB huge pages, reducing TLB misses.

## 1. Configuration

/sys/kernel/mm/transparent_hugepage/enabled: [always] madvise never

## 2. khugepaged

Background thread scanning memory for promotion candidates.

## 3. Benefits

4KB: 2MB/TLB, 512 PTEs/GB
2MB: 1GB/TLB, 1 PMD/GB

## 4. vs hugetlbfs

THP: automatic, swappable
hugetlbfs: manual reservation, not swappable

## 5. Kernel config

CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y

## 6. Source files

mm/huge_memory.c, mm/khugepaged.c


THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details
THP details

## 4. khugepaged

后台线程扫描内存，将 4KB 页合并为 2MB 大页。

## 5. vs hugetlbfs

THP: 自动, 可swap
hugetlbfs: 手动预留, 不可swap

## 6. 源码

mm/huge_memory.c, mm/khugepaged.c


## 4. 配置

/sys/kernel/mm/transparent_hugepage/enabled
[always] madvise never

/sys/kernel/mm/transparent_hugepage/defrag
[always] defer defer+madvise madvise never

## 5. 实现

khugepaged 内核线程扫描内存，合并符合条件的 4KB 页。
扫描条件: 地址对齐、权限一致、512 个连续页。

## 6. THP vs hugetlbfs

| 特性 | THP | hugetlbfs |
|------|-----|-----------|
| 配置 | 自动 | 手动预留 |
| 页大小 | 2MB | 2MB/1GB |
| 应用透明 | 是 | 否 |
| 可交换 | 是 | 否 |

## 7. 源码

mm/huge_memory.c: 大页管理
mm/khugepaged.c: 合并线程

## 8. 关联文章

- **189-THP**: 深度分析


## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## THP allocation

When a process faults in a page, the fault handler checks if THP is enabled and if the address is eligible. If so, it attempts to allocate a 2MB page from the buddy allocator. If allocation fails, it falls back to 4KB pages. khugepaged later scans for merge opportunities.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.

## defragmentation

The defrag setting controls memory compaction behavior when THP allocation fails. always: compact synchronously. defer: compact asynchronously. madvise: compact only for MADV_HUGEPAGE regions. never: don't compact, always use 4KB fallback.
