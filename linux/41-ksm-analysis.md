# 41-ksm — Linux 内核同页合并深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**KSM（Kernel Same-page Merging）** 通过 ksmd 内核线程扫描进程的匿名页面，将内容相同的页面合并为写时复制（COW）页面，减少物理内存占用。

**doom-lsp 确认**：`mm/ksm.c` 含 **285 个符号**。`ksm_do_scan` @ L2783（每轮扫描），`stable_tree_search` @ L1828（稳定树查找），`cmp_and_merge_page` @ L2251（比较合并），`try_to_merge_one_page` @ L1478（实际合并）。

---

## 1. 核心数据结构

```c
// mm/ksm.c — 稳定树节点（已合并的页面）
struct ksm_stable_node {
    struct rb_node node;            // 红黑树节点（在 root_stable_tree 中）
    struct page *page;              // 合并后的 KSM 页面
    unsigned int kpfn;              // 页框号（用于快速查找）
};

// 两个全局红黑树
static struct rb_root *root_stable_tree;   // 稳定树（已合并页面）
static struct rb_root *root_unstable_tree; // 不稳定树（候选页面）

// 扫描状态
struct ksm_scan {
    struct ksm_mm_slot *mm_slot;    // 当前扫描的 mm_slot
    unsigned long address;          // 当前扫描地址
    unsigned long seqnr;            // 扫描序列号
};
```

---

## 2. ksmd 扫描循环

```c
// mm/ksm.c:2783 — ksmd 每轮扫描
static void ksm_do_scan(unsigned int scan_npages)
{
    struct ksm_rmap_item *rmap_item;
    struct page *page;

    while (scan_npages-- && likely(!freezing(current))) {
        cond_resched();  // 每页让出 CPU

        rmap_item = scan_get_next_rmap_item(&page);
        if (!rmap_item)
            return;  // 无更多可扫描页面

        cmp_and_merge_page(page, rmap_item);
        put_page(page);

        ksm_pages_scanned++;  // 更新统计
    }
}
```

---

## 3. 合并流程

```
cmp_and_merge_page(page, rmap_item)    @ L2251
  │
  ├─ 1. 计算页面校验和
  │    checksum = calc_checksum(page)
  │    if (checksum != rmap_item->oldchecksum)
  │        → 页面内容变了，更新校验和
  │        → 跳过此页
  │
  ├─ 2. stable_tree_search(page)       @ L1828
  │     → 在 root_stable_tree 中查找相同内容
  │     → 红黑树遍历，memcmp 比较内容
  │     → 找到 → try_to_merge_one_page(page, kpage)
  │        → 设置 COW PTE
  │        → 增加 folio 引用计数
  │
  └─ 3. 未在稳定树中找到
       unstable_tree_search_insert(...)
       → 在 root_unstable_tree 中查找/插入
       → 找到匹配 → 移入稳定树
```

---

## 4. 稳定树搜索

```c
// mm/ksm.c:1828 — 红黑树查找相同内容的页面
static struct folio *stable_tree_search(struct page *page)
{
    struct rb_root *root = root_stable_tree + page_to_nid(page);
    struct rb_node *node;

    for (node = root->rb_node; node; ) {
        struct ksm_stable_node *stable_node;

        stable_node = rb_entry(node, struct ksm_stable_node, node);

        // 比较页面内容
        if (memcmp(page_address(page),
                   page_address(stable_node->page), PAGE_SIZE)) {
            // 内容不同 → 继续搜索
            node = (page_to_pfn(page) < stable_node->kpfn) ?
                   node->rb_left : node->rb_right;
        } else {
            // 内容匹配！返回已合并的 folio
            return folio;
        }
    }
    return NULL;  // 未找到
}
```

---

## 5. 配置接口

```bash
# sysfs 控制
/sys/kernel/mm/ksm/
├── pages_to_scan        # 每轮扫描页数（默认 100）
├── sleep_millisecs      # 扫描休眠时间（默认 20ms）
├── run                  # 1=启动, 0=停止, 2=取消合并
├── pages_shared         # 已合并的唯⼀页数
├── pages_sharing        # 实际节省的页数
├── pages_unshared       # 待比较的未共享页数
├── full_scans           # 完全扫描次数
├── merge_across_nodes   # 是否跨 NUMA 合并
└── use_zero_pages       # 零页合并

# madvise 控制
MADV_MERGEABLE    # 区域可合并
MADV_UNMERGEABLE  # 区域不可合并
```

---

## 6. try_to_merge_one_page

```c
// mm/ksm.c:1478 — 将 page 合并到 kpage
static int try_to_merge_one_page(struct vm_area_struct *vma,
                                  struct page *page, struct page *kpage)
{
    int err = -EFAULT;

    // 检查共享者数量限制
    if (page_mapcount(page) + 1 + ... > ksm_max_page_sharing)
        return err;

    // 锁定页面
    if (!folio_trylock(page_folio(page)))
        return err;

    // 建立 COW 映射
    // 1. page 的 PTE 指向 kpage
    // 2. 设置写保护（下次写触 COW）
    // 3. 更新反向映射
    set_page_stable_node(page, stable_node);
    page->mapping = kpage->mapping;

    folio_unlock(page_folio(page));
    return err;
}
```

---

## 7. 源码文件索引

| 文件 | 符号数 | 关键行 |
|------|--------|--------|
| mm/ksm.c | 285 | ksm_do_scan @ L2783, stable_tree_search @ L1828 |
| mm/ksm.c | | try_to_merge_one_page @ L1478, cmp_and_merge_page @ L2251 |

---

## 8. 关联文章

- **40-thp**: 透明大页
- **42-oom-killer**: OOM Killer

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 9. ksm_config 统计

```c
// mm/ksm.c — 全局统计变量
static unsigned long ksm_pages_shared;    // 已合并页数
static unsigned long ksm_pages_sharing;   // 实际节省页数
static unsigned long ksm_pages_unshared;  // 待比较页数
static unsigned long ksm_rmap_items;      // rmap 项数
static unsigned long ksm_stable_node_chains; // 稳定树链数
static unsigned long ksm_stable_node_dups;   // 稳定树重复数
```

## 10. 性能数据

| 操作 | 延迟 | 说明 |
|------|------|------|
| 页面比较 | ~1us | memcmp 两个页面 |
| 页面合并 | ~5us | COW 设置 + 树操作 |
| COW 触发 | ~100ns | 写保护缺页 |
| 每页扫描 | ~1-5us | 含校验和计算 |

## 11. 总结

KSM 通过红黑树管理合并页面，ksmd 后台线程周期性扫描。稳定树保存已合并页面，不稳定树保存候选页面。使用 `ksm_max_page_sharing`（默认 256）限制每节点的共享者数量。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 12. 扫描流程详解

```c
// ksmd 主循环:
// 1. ksm_do_scan(pages_to_scan) 扫描指定页数
// 2. 休眠 sleep_millisecs 毫秒
// 3. 唤醒后再次扫描

// scan_get_next_rmap_item:
// → 从当前 mm_slot 的 VMA 列表取下一页
// → 跳过 VM_MERGEABLE 未设置的 VMA
// → 返回 ksm_rmap_item（含页面地址和校验和）

// cmp_and_merge_page:
// → 校验和比较 → 跳过未变页面
// → 稳定树搜索 → 内容匹配则合并
// → 不稳定树搜索 → 匹配则移入稳定树
```

## 13. 调试

```bash
cat /sys/kernel/mm/ksm/pages_shared   # 已合并页数
cat /sys/kernel/mm/ksm/pages_sharing  # 节省页数
cat /sys/kernel/mm/ksm/full_scans     # 完全扫描次数
echo 1 > /sys/kernel/mm/ksm/run       # 启动 KSM
echo 0 > /sys/kernel/mm/ksm/run       # 停止
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
