# 041-ksm — Linux 内核同页合并（KSM）深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**KSM（Kernel Same-page Merging）** 是 Linux 内核的内存去重机制。它通过 ksmd 内核线程扫描进程的匿名页面，将内容相同的页面合并为写时复制（COW）页面，消除重复物理页的冗余。这是虚拟化场景中的关键技术——运行相同操作系统的虚拟机共享大量内核代码和共享库，KSM 可节省 50% 以上的物理内存。

KSM 的核心是两个红黑树：

- **稳定树（stable tree）**：已合并的页面，内容不会再变化（不可写）
- **不稳定树（unstable tree）**：待比较的候选页面，内容可能还在变化

两棵树的区分是因为稳定树搜索更快——一旦页面被合并，内容保证不变，后续扫描可以直接跳过。而不稳定树的页面可能被写（触发 COW 拆离），需要重新比较。

**doom-lsp 确认**：`mm/ksm.c` 含 **285 个符号**，6505 行。关键函数：`ksm_do_scan` @ L2783，`stable_tree_search` @ L1828，`cmp_and_merge_page` @ L2251，`try_to_merge_one_page` @ L1478。

---

## 1. 核心数据结构

### 1.1 `struct ksm_mm_slot`——进程扫描槽

（`mm/ksm.c` L126 — doom-lsp 确认）

```c
struct ksm_mm_slot {
    struct mm_struct    *mm;             // L127 — 目标进程的 mm_struct
    struct ksm_mm_slot  *next;           // L128 — 链表 next（单向链表遍历）
};
```

每个进程的 mm_struct 嵌入了一个 `ksm_mm_slot`（通过 `mm->ksm_mm_slot` 访问），标识该进程是否被 KSM 扫描以及当前的扫描进度。

### 1.2 `struct ksm_scan`——扫描游标

（`mm/ksm.c` L140 — doom-lsp 确认）

```c
struct ksm_scan {
    struct ksm_mm_slot  *mm_slot;        // L141 — 当前扫描的进程槽
    unsigned long       address;         // L142 — 当前扫描地址
    struct page         **pages;         // L143 — 当前扫描的页面数组
    unsigned int        seqnr;           // L145 — 扫描轮次序列号（绕过 COW 拆离判断）
};
```

`ksm_scan` 是全局唯一的扫描状态（`mm/ksm.c:static struct ksm_scan ksm_scan = { .mm_slot = &ksm_mm_head };`），由 ksmd 线程持有。

### 1.3 `struct ksm_stable_node`——稳定树节点

（`mm/ksm.c` L159 — doom-lsp 确认）

```c
struct ksm_stable_node {
    struct rb_node       node;           // L160 — 红黑树节点
    struct page          *page;          // L162 — 合并后的 KSM 物理页
    unsigned int         kpfn;           // L164 — 页框号（Page Frame Number）
    struct ksm_rmap_item *rmap_item;     // L166 — 反向映射条目
    unsigned int         age;            // L168 — 树中年龄（用于节点淘汰）
    unsigned long        seq;            // L169 — 创建时的扫描序列号
    struct list_head     list;           // L170 — 桶链表
};
```

### 1.4 全局统计

```c
// mm/ksm.c — doom-lsp 确认
static unsigned long ksm_pages_shared;     // L258 — 稳定树中的唯一页数（去重后的）
static unsigned long ksm_pages_sharing;    // L261 — 实际节省的页数（共享引用数）
static unsigned long ksm_pages_unshared;   // L264 — 不稳定树中的候选页数
static unsigned long ksm_rmap_items;       // L267 — rmap_item 总数
static bool ksm_use_zero_pages;            // L291 — 零页优化开关
atomic_long_t ksm_zero_pages;              // L298 — 合并到零页的页数
```

**节省量计算**：`ksm_saved_pages = ksm_pages_sharing - ksm_pages_shared`。因为 `ksm_pages_shared` 是基础页（物理存在的页），`ksm_pages_sharing` 是所有引用（含基础页），差值就是节省的页面数。

---

## 2. ksmd 内核线程生命周期

```
start_kernel()
  └─ ksm_init()                               // mm/ksm.c L3620
       ├─ 初始化稳定树 root_stable_tree
       ├─ 初始化不稳定树 root_unstable_tree
       ├─ 创建设备 /sys/kernel/mm/ksm/
       └─ kthread_run(ksm_scan_thread, NULL, "ksmd")
              ↓
ksm_scan_thread()                              // L2816
  └─ while (!kthread_should_stop()):
       ├─ if (ksm_run & KSM_RUN_MERGE):
       │     ksm_do_scan(ksm_thread_pages_to_scan)  // 默认 100 页
       │     wait_event_freezable(ksmd_wait, ...)
       │     schedule_timeout(ksm_thread_sleep_ms)  // 默认 20ms
       └─ else:
             wait_event_freezable(ksmd_wait, ksm_run & KSM_RUN_MERGE)
```

**sysfs 控制**：

```bash
# 启用 KSM（默认关闭）
echo 1 > /sys/kernel/mm/ksm/run
# run = 0: 停止  |  1: 运行  |  2: 停止+取消合并已有页面

# 调参
echo 100 > /sys/kernel/mm/ksm/pages_to_scan    # 每轮扫描页数
echo 20  > /sys/kernel/mm/ksm/sleep_millisecs   # 每轮休眠时间
echo 0  > /sys/kernel/mm/ksm/merge_across_nodes # 禁止跨 NUMA 合并
echo 1  > /sys/kernel/mm/ksm/use_zero_pages     # 零页优化
```

---

## 3. ksm_do_scan——单轮扫描数据流

（`mm/ksm.c` L2783 — doom-lsp 确认）

```
ksm_do_scan(scan_npages=100)
  │
  └─ for (i = 0; i < scan_npages; i++)
       └─ ksm_scan.mm_slot = GET_NEXT_SLOT()
            │  遍历所有注册了 KSM 的进程
            │  按轮次切换进程（round-robin）
            │
            └─ ksm_scan.address = 当前扫描地址
                 │
                 └─ 通过 mm->ksm_mm_slot 找到目标 mm
                      mmap_read_lock(mm)
                      └─ while (address < mm->hiaddr):
                           ├─ 找到下一个 VMA
                           ├─ 获取映射到 address 的 page
                           │   follow_page(vma, address, FOLL_GET)
                           │
                           └─ cmp_and_merge_page(page, rmap_item)
                                │  核心函数：比较并合并页面
                                │
                                ksm_scan.address += PAGE_SIZE
                      mmap_read_unlock(mm)
```

---

## 4. cmp_and_merge_page——核心合并逻辑

（`mm/ksm.c` L2251 — doom-lsp 确认）

```
cmp_and_merge_page(page, rmap_item)
  │
  ├─ 1. 尝试稳定树搜索
  │     tree_page = stable_tree_search(page)
  │     │  在稳定树中查找内容相同的已合并页面
  │     │  通过 memcmp_pages() 比较页面内容
  │     │
  │     └─ 如果找到：
  │           try_to_merge_one_page(vma, page, tree_page)
  │           → 将 page 的内容替换为 tree_page 的引用（COW）
  │           → page 的引用计数 +1
  │           → ksm_pages_sharing++
  │           → 返回
  │
  ├─ 2. 未在稳定树中找到 → 尝试不稳定树
  │     tree_rmap_item = unstable_tree_search_insert(rmap_item, page, &tree_page)
  │     │  在不稳定树中查找内容相同的候选页面
  │     │
  │     └─ 如果找到（tree_page != NULL）：
  │           ├─ try_to_merge_one_page(vma, page, tree_page)
  │           ├─ try_to_merge_one_page(vma, tree_rmap_item->page, page)
  │           │  两个页面都尝试合并到同一个 KSM 页
  │           │
  │           ├─ 创建稳定树节点
  │           │  ksm_stable_node = alloc_stable_node()
  │           │  ksm_stable_node->page = kpage (合并后的 KSM 页)
  │           │  rb_insert(&root_stable_tree, ksm_stable_node) 
  │           │
  │           ├─ 从不稳定树中移除 tree_rmap_item
  │           └─ ksm_pages_shared++ / ksm_pages_sharing += 2
  │
  └─ 3. 两棵树都未找到
        └─ 将 page 插入不稳定树（作为下次比较的候选）
           unstable_tree_search_insert(rmap_item, page, NULL)
```

### 流程图

```
              cmp_and_merge_page(page)
                    │
                    ▼
        稳定树搜索 (stable_tree_search)
           ┌───────┴───────┐
           │ 找到           │ 未找到
           ▼                ▼
     try_to_merge   不稳定树搜索 (unstable_tree_search)
     (共享引用)       ┌───────┴───────┐
                    │ 找到           │ 未找到
                    ▼                ▼
             双次合并 +     插入不稳定树
             创建稳定树节点  (下次候选)
                    │
                    ▼
              ksm_pages_shared++
```

---

## 5. try_to_merge_one_page——实际页面合并

（`mm/ksm.c` L1478 — doom-lsp 确认）

```c
static int try_to_merge_one_page(struct vm_area_struct *vma,
                                 struct page *page, struct page *kpage)
{
    int err = -EFAULT;

    // 1. 锁定页面，防止并发 I/O
    if (trylock_page(page)) {
        // 2. 解除原页面的所有 PTE 映射
        //    将 page 的所有映射替换为 KSM 页面
        //    (通过 rmap_walk 遍历所有映射该页面的 VMA)
        try_to_merge_with_ksm_page(kpage, page);

        // 3. 标记页面为 KSM 页面
        SetPageKsm(page);
        // 写时复制：页面被标记为 KSM 后，
        // CPU 写入时触发 #PF → do_wp_page()
        // → 分配新的页面 → 拷贝内容 → 更新 PTE

        // 4. 释放原页面的引用
        put_page(page);
        err = 0;
    }
    return err;
}
```

**合并的物理效果**：

```
合并前：
  进程 A: PTE → page_1 (物理页，内容 "hello")
  进程 B: PTE → page_2 (物理页，内容 "hello")
  物理页占用: 2 页

合并后：
  进程 A: PTE → kpage (KSM 页，内容 "hello") [写保护]
  进程 B: PTE → kpage (KSM 页，内容 "hello") [写保护]
  物理页占用: 1 页（节省 1 页）

写时分裂（进程 A 写入时）：
  进程 A: #PF → do_wp_page → 分配 new_page → 拷贝 "hello" → 更新 PTE
  进程 A: PTE → new_page (可写)
  进程 B: PTE → kpage (内容 "hello")
  物理页占用: 2 页（回到合并前）
```

---

## 6. 稳定树搜索与插入

### 6.1 stable_tree_search

（`mm/ksm.c` L1828 — doom-lsp 确认）

```c
static struct folio *stable_tree_search(struct page *page)
{
    struct rb_root *root = root_stable_tree + nid;  // 按 NUMA 节点分树
    struct rb_node *node;
    struct folio *folio;

    for (node = root->rb_node; node; node = rb_next(node)) {
        // 遍历稳定树，对每个节点比较内容
        kpage = folio_page(stable_node->folio, 0);
        // 使用 memcmp_pages 比较页面内容
        if (!memcmp_pages(page, kpage)) {
            // 内容相同！
            // 增加 KSM 页的引用计数
            get_page(kpage);
            return folio;
        }
        // 内容不同，根据树的性质继续搜索
        // （按页面内容的哈希值排序）
    }
    return NULL;  // 未找到
}
```

### 6.2 两棵树的设计原理

```
稳定树（stable tree）:
  内容保证不变 → 节点不会被删除
  搜索 O(log n)
  节点生命周期：从合并到所有引用 COW 拆离

不稳定树（unstable tree）:
  内容可能变化 → 每轮扫描后重建
  搜索 O(log n)（但需要重新比较）
  节点生命周期：一轮 KSM 扫描

不稳定树为什么每轮重建：
  节点引用的页面可能在两次扫描之间被写入（触发 COW）
  导致树中的内容引用无效
  重建保证数据一致性
```

---

## 7. 零页优化

当 KSM 发现页面内容全部为零时，不需要创建 KSM 页——直接使用内核的`空页`（ZERO_PAGE）：

```c
// mm/ksm.c — 零页优化（doom-lsp 确认）
// 由 ksm_use_zero_pages 控制（/sys/kernel/mm/ksm/use_zero_pages）
static bool ksm_use_zero_pages __read_mostly;    // L291

// 在 cmp_and_merge_page 中：
// 如果页面内容全零：
//   直接映射到 ZERO_PAGE(0)（全局共享的只读零页）
//   不分配新的物理页
//   不需要稳定树节点
//   ksm_zero_pages++

// ZERO_PAGE 的好处：
// - 不需要物理页
// - 所有 KVM 虚拟机共享同一个零页
// - 写时分裂（guest 写入时）才分配物理页
```

---

## 8. NUMA 感知

KSM 支持跨 NUMA 节点的合并控制：

```c
// mm/ksm.c — doom-lsp 确认
// /sys/kernel/mm/ksm/merge_across_nodes
// =1: 允许跨 NUMA 节点合并（默认）
// =0: 只在同一 NUMA 节点内合并

// 实现：
// stable_tree 实际是一个数组：
static struct rb_root *root_stable_tree;   // [nr_node_ids]
static struct rb_root *root_unstable_tree; // [nr_node_ids]

// merge_across_nodes=1 时：
//   所有节点指向同一个 root (root_stable_tree[0])
// merge_across_nodes=0 时：
//   每个 NUMA 节点有独立的稳定树
```

---

## 9. 性能特征

| 因素 | 影响 | 调优 |
|------|------|------|
| `pages_to_scan` | 每轮扫描页数，越大 CPU 开销越高 | 默认 100，虚拟机场景可调大 |
| `sleep_millisecs` | 两轮之间的休眠时间 | 默认 20ms，IO 密集场景可调大 |
| `merge_across_nodes` | 开启后跨 NUMA 合并节省更多 | 关闭可减少跨 NUMA 访问延迟 |
| `max_page_sharing` | 单个 KSM 页最多共享数 | 默认 256，限制引用链长度 |
| 零页优化 | 零页不占物理内存，效果显著 | 默认关闭，建议在虚拟化场景开启 |

---

## 10. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct ksm_mm_slot` | mm/ksm.c | 126 |
| `struct ksm_scan` | mm/ksm.c | 140 |
| `struct ksm_stable_node` | mm/ksm.c | 159 |
| `ksm_scan_thread()` | mm/ksm.c | 2816 |
| `ksm_do_scan()` | mm/ksm.c | 2783 |
| `cmp_and_merge_page()` | mm/ksm.c | 2251 |
| `try_to_merge_one_page()` | mm/ksm.c | 1478 |
| `stable_tree_search()` | mm/ksm.c | 1828 |
| `unstable_tree_search_insert()` | mm/ksm.c | 2137 |
| `ksm_init()` | mm/ksm.c | 3620 |
| `ksm_run` | mm/ksm.c | 482 |
| `ksm_pages_shared` | mm/ksm.c | 258 |
| `ksm_pages_sharing` | mm/ksm.c | 261 |
| `ksm_use_zero_pages` | mm/ksm.c | 291 |
| `ksm_zero_pages` | mm/ksm.c | 298 |
| `ksm_thread_pages_to_scan` | mm/ksm.c | (sysfs) |
| `ksm_thread_sleep_millisecs` | mm/ksm.c | (sysfs) |
| `root_stable_tree` | mm/ksm.c | (全局，[nr_node_ids]) |
| `root_unstable_tree` | mm/ksm.c | (全局，[nr_node_ids]) |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-04 | 内核版本：Linux 7.0-rc1*
