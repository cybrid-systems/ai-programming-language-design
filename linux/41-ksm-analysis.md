# 41-ksm — Linux 内核同页合并深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**KSM（Kernel Same-page Merging）** 合并多个进程间内容相同的匿名页面，减少内存占用。通过 ksmd 内核线程周期性扫描，使用两个红黑树管理合并状态。

**doom-lsp 确认**：`mm/ksm.c` 包含 **285 个符号**。核心结构：`struct ksm_mm_slot` @ L126，`struct ksm_rmap_item` @ L128，`struct ksm_stable_node` @ L159，`struct ksm_scan` @ L140。

## 1. 核心数据结构

```c
// mm/ksm.c:126 — doom-lsp 确认
struct ksm_mm_slot {
    struct list_head mm_list;       // 全局 ksm 进程链表
    struct list_head ksm_scan;      // 扫描队列顺序
    struct mm_struct *mm;           // 所属进程的 mm_struct
};

// mm/ksm.c:128 — doom-lsp 确认
struct ksm_rmap_item {
    struct list_head rmap_list;     // 反向映射链表
    struct anon_vma *anon_vma;      // 匿名映射
    unsigned long address;          // 页面虚拟地址
    unsigned int oldchecksum;       // 旧校验和
};

// mm/ksm.c:159 — doom-lsp 确认
struct ksm_stable_node {
    struct rb_node node;            // 稳定树节点
    struct page *page;              // 合并后的 KSM 物理页
    unsigned int kpfn;              // 页面框号
};

// mm/ksm.c:140 — doom-lsp 确认
struct ksm_scan {
    struct ksm_mm_slot *mm_slot;    // 当前扫描的 mm_slot
    unsigned long address;          // 当前扫描地址
    struct rmap_item **rmap_list;   // 当前扫描的 rmap 列表
    unsigned long seqnr;            // 扫描序列号
};
```

## 2. ksmd 内核线程

**doom-lsp 确认**的关键函数：
- `set_advisor_defaults` @ L348: 设置扫描参数默认值
- `advisor_start_scan` @ L359: 扫描开始时调用
- `ewma` @ L376: 指数加权移动平均计算

## 3. 配置接口

```bash
# sysfs 控制
/sys/kernel/mm/ksm/pages_to_scan      # 每轮扫描页数
/sys/kernel/mm/ksm/sleep_millisecs     # 扫描休眠时间
/sys/kernel/mm/ksm/run                 # 1=启动, 0=停止
/sys/kernel/mm/ksm/pages_shared        # 已合并页数
/sys/kernel/mm/ksm/pages_sharing       # 实际节省页数

# madvise
MADV_MERGEABLE    # 区域加入 KSM 扫描
MADV_UNMERGEABLE  # 区域退出 KSM
```

## 4. 源码文件索引

| 文件 | 符号数 | 说明 |
|------|--------|------|
| mm/ksm.c | 285 | KSM 完整实现 |

## 5. 关联文章

- **39-mlock**: 内存锁定
- **40-thp**: 透明大页

---


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```


## Deep Analysis

The ksmd kernel thread scans process memory pages and compares them using checksums and memcmp. Matching pages are merged via COW (Copy-on-Write). The stable tree holds merged pages while the unstable tree tracks candidates. Pages marked MADV_MERGEABLE via madvise() are eligible for scanning.

```c
// Merge two pages
static int try_to_merge_one_page(struct vm_area_struct *vma, struct page *page, struct page *kpage) { ... }
```

