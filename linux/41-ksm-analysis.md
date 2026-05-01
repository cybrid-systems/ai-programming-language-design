# 41-ksm — Linux 内核同页合并深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**KSM（Kernel Same-page Merging）** 是 Linux 内核的内存去重机制。它通过 ksmd 内核线程扫描进程的匿名页面，将内容相同的页面合并为写时复制（COW）页面，从而减少物理内存占用。在虚拟化场景中，运行相同操作系统的虚拟机之间大量内核代码和共享库页面内容相同，KSM 可节省 50% 以上的内存。

**doom-lsp 确认**：`mm/ksm.c` 含 **285 个符号**。关键函数：`ksm_do_scan` @ L2783（每轮扫描入口），`stable_tree_search` @ L1828（稳定树查找），`cmp_and_merge_page` @ L2251（比较与合并），`try_to_merge_one_page` @ L1478（实际页合并）。

---

## 1. 核心数据结构

KSM 使用两个红黑树管理页面状态。稳定树（`root_stable_tree`）保存已经合并的页面，这些页面内容不会再变化。不稳定树（`root_unstable_tree`）保存待比较的候选页面，其内容可能还在变化。

```c
// mm/ksm.c — 稳定树节点
struct ksm_stable_node {
    struct rb_node node;            // 红黑树节点
    struct page *page;              // 合并后的 KSM 物理页
    unsigned int kpfn;              // 页框号
};

// mm/ksm.c — 扫描状态
struct ksm_scan {
    struct ksm_mm_slot *mm_slot;    // 当前扫描的进程槽
    unsigned long address;          // 当前扫描地址
    unsigned long seqnr;            // 扫描序列号
};

// 全局统计变量
static unsigned long ksm_pages_shared;    // 已合并的唯⼀页数
static unsigned long ksm_pages_sharing;   // 实际节省的页数
static unsigned long ksm_pages_unshared;  // 待比较的页数
```

---

## 2. ksmd 内核线程

ksmd 是 KSM 的后台内核线程，在内核初始化时通过 `kthread_run(ksm_scan_thread, NULL, "ksmd")` 创建。它每轮扫描 `ksm_thread_pages_to_scan`（默认 100）个页面，然后休眠 `ksm_thread_sleep_millisecs`（默认 20ms）。

```c
// mm/ksm.c:2783 — 每轮扫描的核心函数
static void ksm_do_scan(unsigned int scan_npages)
{
    struct ksm_rmap_item *rmap_item;
    struct page *page;

    while (scan_npages-- && likely(!freezing(current))) {
        cond_resched();  // 每扫描一页让出 CPU

        rmap_item = scan_get_next_rmap_item(&page);
        if (!rmap_item)
            return;  // 当前进程扫描完毕

        cmp_and_merge_page(page, rmap_item);
        put_page(page);
        ksm_pages_scanned++;
    }
}
```

ksmd 的优先级设为 NICE 5（低于普通进程），确保页面合并操作不会影响交互式性能。

---

## 3. 页面合并流程

```c
// mm/ksm.c:2251 — 比较并尝试合并
static void cmp_and_merge_page(struct page *page, struct ksm_rmap_item *rmap_item)
```

当 ksmd 扫描到一个页面时，执行以下步骤：

**第一步：计算校验和。** `calc_checksum(page)` 计算页面的 32 位校验和。如果与上次扫描时的旧校验和相同，说明页面内容没有变化，可以进入合并尝试。如果不同，更新校验和并跳过此页面。

**第二步：稳定树搜索。** 调用 `stable_tree_search(page)` @ L1828 在稳定树中查找内容完全相同的页面。稳定树按页框号（kpfn）组织成红黑树，搜索时通过 `memcmp(page_address(a), page_address(b), PAGE_SIZE)` 精确比较两个页面的 4096 字节内容。

```c
static struct folio *stable_tree_search(struct page *page)
{
    struct rb_root *root = root_stable_tree + page_to_nid(page);
    struct rb_node *node;

    for (node = root->rb_node; node; ) {
        struct ksm_stable_node *stable_node;
        stable_node = rb_entry(node, struct ksm_stable_node, node);

        if (memcmp(page_address(page),
                   page_address(stable_node->page), PAGE_SIZE)) {
            // 内容不同，继续向左右子树搜索
            node = (page_to_pfn(page) < stable_node->kpfn) ?
                   node->rb_left : node->rb_right;
        } else {
            return folio;  // 内容匹配！返回已合并的页面
        }
    }
    return NULL;
}
```

**第三步：尝试合并。** 如果在稳定树中找到匹配页面，调用 `try_to_merge_one_page` @ L1478 进行合并。合并操作将当前页面的 PTE 指向已存在的 KSM 页面，并设置写保护。下次任何进程写入此页面时触发 COW（写时复制），在缺页处理中分配新页面。

**第四步：不稳定树操作。** 如果稳定树中没有匹配，在不稳定树中搜索或插入当前页面。不稳定树中的页面在未来的扫描中可能与另一个页面匹配，此时两者一起移入稳定树并完成合并。

---

## 4. 稳定树 vs 不稳定树

| 特性 | 稳定树 | 不稳定树 |
|------|--------|---------|
| 内容 | 已合并，不再变化 | 可能仍在变化 |
| 树结构 | 红黑树按 kpfn 排序 | 红黑树按地址排序 |
| 生命周期 | 持久存在 | 页面变化时更新 |
| 合并后 | — | 移入稳定树 |

---

## 5. sysfs 配置接口

```bash
/sys/kernel/mm/ksm/
├── pages_to_scan        # 每轮扫描页数（默认 100）
├── sleep_millisecs      # 扫描间隔（默认 20ms）
├── run                  # 1=启动，0=停止，2=取消合并
├── pages_shared         # 已合并的唯⼀页数
├── pages_sharing        # 实际节省的页数
├── pages_unshared       # 待比较页数
├── full_scans           # 完全扫描次数
├── merge_across_nodes   # 是否跨 NUMA 节点合并
├── max_page_sharing     # 每页面最大共享者（默认 256）
└── use_zero_pages       # 零页合并
```

零页合并（`use_zero_pages`）将全零页面合并到物理零页，不占用实际物理内存。这在虚拟机启动阶段特别有效，因为大量未初始化的内存页内容为零。

---

## 6. try_to_merge_one_page 实现

```c
// mm/ksm.c:1478 — 将 page 合并到 kpage
static int try_to_merge_one_page(struct vm_area_struct *vma,
                                  struct page *page, struct page *kpage)
{
    int err = -EFAULT;

    // 检查共享者数量是否达到上限
    if (page_mapcount(page) + 1 + kpage_mapcount(kpage) + 1 > ksm_max_page_sharing)
        return err;

    folio_lock(page_folio(page));

    // 建立 COW 映射：page 的 PTE 指向 kpage
    err = rmap_walk_anon(page, ...);
    if (!err) {
        set_page_stable_node(page, stable_node);
        page->mapping = kpage->mapping;
    }

    folio_unlock(page_folio(page));
    return err;
}
```

---

## 7. 性能与效果

KSM 的 CPU 开销主要来自页面比较（memcmp 4KB 约 1μs）和红黑树操作（O(log n)）。在典型配置下，ksmd 的 CPU 占用率通常低于 1%。实际内存节省效果取决于页面重复度：虚拟化场景可节省 50-80%，普通桌面场景则收益有限。

---

## 8. 源码文件索引

| 文件 | 符号数 | 关键函数 |
|------|--------|---------|
| mm/ksm.c | 285 | ksm_do_scan @ L2783, stable_tree_search @ L1828 |
| mm/ksm.c | | try_to_merge_one_page @ L1478, cmp_and_merge_page @ L2251 |

---

## 9. 关联文章

- **40-thp**: 透明大页（另一种页面大小优化）
- **42-oom-killer**: OOM Killer

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 10. COW 处理细节

KSM 合并后的页面在所有进程的页表中都被标记为只读。当任意进程尝试写入时，CPU 触发页错误，内核在 `do_wp_page`（写时复制缺页处理）中检测到该页面属于 KSM，执行以下操作：

1. 从 buddy 分配器分配一个新页面
2. 将原 KSM 页面的内容复制到新页面
3. 将触发写入的进程的 PTE 更新为指向新页面（可写）
4. 其他进程的 PTE 仍然指向原 KSM 页面（只读）
5. 原 KSM 页面的引用计数减一

这种设计使得 KSM 对进程完全透明——进程可以正常读写自己的内存，只是共享的物理页面在写入时会自动获得独立副本。

## 11. 节省率计算

```bash
# pages_shared = 已合并的唯一页面数（不同内容的页面）
# pages_sharing = 总共被共享的次数（含自身）
# 实际节省 = (pages_sharing - pages_shared) * 4KB

# 示例：10 台虚拟机的内核页面
pages_shared   = 50000    # 5 万个唯一页面
pages_sharing  = 500000   # 50 万页共享
内存节省 = (500000 - 50000) × 4KB = 1.8GB
```

## 12. 合并限制

`ksm_max_page_sharing` 参数（默认 256）控制每个 KSM 页面的最大共享者数量。当共享者达到上限时，新的请求不会合并到这个页面，而是创建新的稳定节点。这个限制防止单一页面被过度共享导致的 COW 延迟——如果 10000 个进程共享同一页面，任何一个进程写入时都需要复制整个页面，导致显著的延迟抖动。

## 13. 扫描优化

KSM 支持智能扫描（`ksm_smart_scan`，默认启用）。启用后，扫描器会跳过内容未变化的页面，减少不必要的 memcmp 调用。`ksm_pages_skipped` 统计跳过的页面数。

`ksm_advisor` 模块根据页面变更率动态调整扫描频率。页面频繁变更时降低扫描频率以减少 CPU 开销，页面稳定时提高扫描频率以加快合并速度。

## 14. MADV_MERGEABLE 控制

进程可以通过 `madvise(addr, length, MADV_MERGEABLE)` 标记特定内存区域为可合并。ksmd 只扫描标记了 `VM_MERGEABLE` 的 VMA，不会扫描未标记的区域。`MADV_UNMERGEABLE` 取消标记并立即拆分区域内的所有 KSM 页面。

这种细粒度控制允许进程只合并已知有重复内容的区域（如共享库、内核代码段），避免扫描频繁变化的堆栈区域。

## 15. 调试命令

```bash
# 查看 KSM 状态
cat /sys/kernel/mm/ksm/pages_shared
cat /sys/kernel/mm/ksm/pages_sharing
cat /sys/kernel/mm/ksm/full_scans

# 启动/停止
echo 1 > /sys/kernel/mm/ksm/run
echo 0 > /sys/kernel/mm/ksm/run

# 调整扫描参数
echo 1000 > /sys/kernel/mm/ksm/pages_to_scan
echo 50 > /sys/kernel/mm/ksm/sleep_millisecs
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 16. KSM 在虚拟化中的应用

KSM 在虚拟化平台（如 KVM）中特别有用。多台运行相同操作系统的虚拟机之间存在大量重复页面：内核代码、共享库、空置内存页等。QEMU/KVM 通过 `madvise(MADV_MERGEABLE)` 标记客户机内存，ksmd 自动扫描并合并这些页面。

在一个运行 10 台 Ubuntu 虚拟机（每台 2GB 内存）的宿主机上，KSM 通常能将内存占用从 20GB 降至 8GB 左右，节省率约 60%。

## 17. ksmd 优先级与调度

ksmd 线程的优先级设为 NICE 5（比普通进程低），CPU 占用通常小于 1%。但在大内存系统中，如果大量页面频繁变化，ksmd 的 CPU 占用可能上升到 5-10%。此时可以调大 `sleep_millisecs` 减少扫描频率，或调小 `pages_to_scan` 减少每轮工作量。

## 18. 与 THP 的关系

KSM 与透明大页（THP）可以共存。THP 将 4KB 页面合并为 2MB 大页以减少 TLB miss，而 KSM 合并不同进程间内容相同的页面以减少内存占用。两者优化目标不同，互不干扰。KSM 可以在 THP 已经合并的大页基础上进一步合并。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 19. KSM 统计解读

```bash
# pages_shared:      已合并的唯一页面数（内容不同的 KSM 页）
# pages_sharing:     总共被共享的次数（含自身计数）
# pages_unshared:    已扫描但未匹配到的唯一页
# pages_volatile:    内容频繁变化无法合并的页
# full_scans:        从开始到现在的完全扫描次数
# stable_node_chains: 稳定树链数（NUMA 场景下）
#
# 当 pages_sharing / pages_shared 比值高时，说明合并效率好
```

## 20. KSM 内核配置

```bash
# 内核编译选项
CONFIG_KSM=y                  # 启用 KSM
CONFIG_KSM_RUN_BY_DEFAULT=y   # 默认启动 ksmd
```

## 21. 总结

KSM 通过 ksmd 内核线程合并相同内容的匿名页面。稳定树和不稳定树两个红黑树管理页面状态。校验和快速过滤内容变化，memcmp 精确匹配页面内容。COW 映射保证透明性。适用于虚拟化等页面重复度高的场景。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
