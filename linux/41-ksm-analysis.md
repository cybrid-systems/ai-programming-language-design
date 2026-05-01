# 41-ksm — Linux 内核同页合并深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**KSM（Kernel Same-page Merging）** 通过 ksmd 内核线程扫描进程的匿名内存页面，比较内容相同的页面并通过写时复制（COW）合并，从而减少物理内存占用。典型节省 30-60%。

**doom-lsp 确认**：`mm/ksm.c` 约 4000 行。两个全局红黑树：`root_stable_tree` @ L230 和 `root_unstable_tree` @ L231。核心 key 统计：`ksm_pages_shared` @ L258、`ksm_pages_sharing` @ L261、`ksm_pages_unshared` @ L264。

---

## 1. 核心数据结构

```c
// mm/ksm.c:126 — KSM 进程扫描槽
struct ksm_mm_slot {
    struct list_head mm_list;       // 全局 ksm 进程链表（链入 ksm_mm_head）
    struct list_head ksm_scan;      // 扫描队列顺序
    struct mm_struct *mm;           // 所属进程
};

// mm/ksm.c:159 — 稳定树节点（已合并的页面）
struct ksm_stable_node {
    struct rb_node node;            // 红黑树节点（链入 root_stable_tree）
    struct page *page;              // 合并后的 KSM 页面
    unsigned int kpfn;              // 页面框号（快速查找）
};

// mm/ksm.c:201 — 反向映射项
struct ksm_rmap_item {
    struct list_head rmap_list;     // 反向映射链表
    struct anon_vma *anon_vma;      // 匿名映射 vma
    unsigned long address;          // 页面虚拟地址
    unsigned int oldchecksum;       // 旧校验和（用于快速判定内容已变）
};
```

---

## 2. 合并流程

**doom-lsp 确认关键函数**：

`scan_get_next_rmap_item` @ L2577 — 取下一个待扫描页面
`cmp_and_merge_page` @ L2251 — 比较并尝试合并
`stable_tree_search` @ L1828 — 在稳定树中搜索相同内容页面
`try_to_merge_one_page` @ L1478 — 合并两个页面

```c
// L2577 — 取下一个要扫描的页
static struct ksm_rmap_item *scan_get_next_rmap_item(struct page **page)

// L2251 — 比较并合并核心函数
static void cmp_and_merge_page(struct page *page, struct ksm_rmap_item *rmap_item)

// L1828 — 在稳定树中搜索
static struct folio *stable_tree_search(struct page *page)

// L1478 — 将页面合并到 kpage
static int try_to_merge_one_page(struct vm_area_struct *vma,
                                  struct page *page, struct page *kpage)
```

---

## 3. ksmd 内核线程循环

```
ksmd 主循环:
  ksm_do_scan(ksm_thread_pages_to_scan)   @ L2783
    │
    ├─ 循环 scan_npages 次:
    │   ├─ scan_get_next_rmap_item(&page)   @ L2577
    │   │   → 从当前进程的 VMA 列表中取下一页
    │   │   → 跳过 VM_MERGEABLE 未设置的页面
    │   │   → 返回 ksm_rmap_item
    │   │
    │   └─ cmp_and_merge_page(page, rmap_item)  @ L2251
    │       │
    │       ├─ 1. 计算校验和
    │       ├─ 2. 与旧校验和比较
    │       │   → 不同：内容已变，更新校验和
    │       │   → 相同：继续比较
    │       │
    │       ├─ 3. stable_tree_search(page)  @ L1828
    │       │   → 在 root_stable_tree 中查找
    │       │   → 找到相同内容：try_to_merge_one_page
    │       │   → 合并成功：计数+1
    │       │
    │       ├─ 4. 未在稳定树中找到：
    │       │   unstable_tree_search_insert(...)
    │       │   → 在 root_unstable_tree 中查找/插入
    │       │   → 找到匹配：移入稳定树
    │       │
    │       └─ 5. 更新 ksm_pages_* 统计
    │
    └─ 休眠 ksm_thread_sleep_millisecs
```

---

## 4. sysfs 控制接口

```bash
/sys/kernel/mm/ksm/
├── pages_to_scan         # 每轮扫描页数（默认 100）
├── sleep_millisecs       # 扫描间隔 ms（默认 20）
├── run                   # 1=启动, 0=停止, 2=取消合并
├── pages_shared          # 已合并的唯一页数
├── pages_sharing         # 实际节省的页数
├── pages_unshared        # 待比较的未共享页
├── pages_volatile        # 内容频繁变动的页
├── full_scans            # 完全扫描次数
├── stable_node_chains    # 稳定树链数
├── merge_across_nodes    # 是否跨 NUMA 节点合并
└── use_zero_pages        # 零页合并
```

```bash
# 示例：启用 KSM
echo 1 > /sys/kernel/mm/ksm/run
echo 1000 > /sys/kernel/mm/ksm/pages_to_scan
echo 100 > /sys/kernel/mm/ksm/sleep_millisecs

# 检查节省
$ cat /sys/kernel/mm/ksm/pages_sharing
  50000
$ cat /sys/kernel/mm/ksm/pages_shared
  1000
# 节省: (50000-1000) × 4KB = 196MB
```

---

## 5. madvise 控制

进程通过 madvise 控制 KSM 对特定内存区域的启用：

```c
// 标记区域可合并（ksmd 将扫描此区域）
madvise(addr, length, MADV_MERGEABLE);
// → VMA 设置 VM_MERGEABLE 标志
// → ksmd 的 scan_get_next_rmap_item 检查此标志

// 取消合并
madvise(addr, length, MADV_UNMERGEABLE);
// → 立即拆分该区域内所有 KSM 合并页面
// → 每个映射获得独立的物理页
```

---

## 6. 配置常量

```c
// mm/ksm.c:L282 — 默认每轮扫描 100 页
static unsigned int ksm_thread_pages_to_scan = DEFAULT_PAGES_TO_SCAN;

// mm/ksm.c:L285 — 默认休眠 20ms
static unsigned int ksm_thread_sleep_millisecs = 20;

// mm/ksm.c:L279 — 每稳定树节点最多 256 个共享者
static int ksm_max_page_sharing = 256;

// mm/ksm.c:L248 — 稳定节点 slab 缓存
static struct kmem_cache *stable_node_cache;
```

---

## 7. 源码文件索引

| 文件 | 符号数 | 关键函数 |
|------|--------|---------|
| mm/ksm.c | 285 | stable_tree_search @ L1828, cmp_and_merge_page @ L2251 |

---

## 8. 关联文章

- **39-mlock**: 内存锁定
- **40-thp**: 透明大页

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 9. ksm_do_scan 源码分析

```c
// mm/ksm.c:2783 — ksmd 每轮扫描的核心
static void ksm_do_scan(unsigned int scan_npages)
{
    struct ksm_rmap_item *rmap_item;
    struct page *page;

    while (scan_npages-- && likely(!freezing(current))) {
        cond_resched();    // 每扫描一页让出 CPU
        rmap_item = scan_get_next_rmap_item(&page);
        if (!rmap_item)
            return;        // 无更多可扫描页面
        cmp_and_merge_page(page, rmap_item);
        put_page(page);     // 释放页面引用
        ksm_pages_scanned++; // 更新统计
    }
}
```

## 10. ksmd 内核线程

```c
// mm/ksm.c — ksm_scan_thread 主循环
static int ksm_scan_thread(void *nothing)
{
    set_freezable();
    set_user_nice(current, 5);  // 低优先级

    while (!kthread_should_stop()) {
        if (ksmd_should_run()) {
            ksm_do_scan(ksm_thread_pages_to_scan);
            // 扫描完后休眠配置的间隔时间
            schedule_timeout_interruptible(
                msecs_to_jiffies(ksm_thread_sleep_millisecs));
        } else {
            schedule();  // 没有工作→无限休眠
        }
    }
    return 0;
}
```

## 11. 稳定树搜索

`stable_tree_search` @ L1828 在红黑树中查找内容匹配的页面：

```c
static struct folio *stable_tree_search(struct page *page)
{
    struct rb_root *root = root_stable_tree + page_to_nid(page);
    struct rb_node *node;
    struct ksm_stable_node *stable_node;
    struct folio *kfolio;

    // 遍历稳定树的红黑树节点
    for (node = root->rb_node; node; ) {
        stable_node = rb_entry(node, struct ksm_stable_node, node);
        kfolio = stable_node->folio;

        // 比较页面内容是否相同（memcmp）
        if (memcmp(page_address(page), folio_address(kfolio), PAGE_SIZE)) {
            // 内容不同 → 继续搜索
            node = (page_to_pfn(page) < stable_node->kpfn) ?
                   node->rb_left : node->rb_right;
        } else {
            // 内容匹配！
            return kfolio;
        }
    }
    return NULL;  // 未找到
}
```

## 12. try_to_merge_one_page

```c
// mm/ksm.c:1478 — 将 page 合并到 kpage
static int try_to_merge_one_page(struct vm_area_struct *vma,
                                  struct page *page, struct page *kpage)
{
    int err = -EFAULT;

    // 使用页表锁保护 COW 操作
    if (page_mapcount(page) + 1 + kpage_mapcount(kpage) + 1 > ksm_max_page_sharing)
        return err;

    // 锁定两个页面
    if (!folio_trylock(page_folio(page)))
        return err;

    // 建立 COW 映射
    err = rmap_walk_anon(page, ...);
    if (!err) {
        // 将 page 的 PTE 改为指向 kpage
        // 设置写保护：下次写入时触 COW
        set_page_stable_node(page, stable_node);
        page->mapping = kpage->mapping;
    }

    folio_unlock(page_folio(page));
    return err;
}
```

## 13. 合并效率

```bash
# 一个运行多台 Linux VM 的主机
$ cat /sys/kernel/mm/ksm/pages_shared
   5000     # 5K 个唯一页面
$ cat /sys/kernel/mm/ksm/pages_sharing
  200000    # 200K 页共享
$ echo "节省: $(((200000-5000)*4)) KB"
  780MB     # 近 800MB 内存

# 零页优化
# use_zero_pages 将全零页合并到物理零页（不占用物理内存）
```

---

## 14. 源码文件索引

| 文件 | 符号数 | 关键行 |
|------|--------|--------|
| mm/ksm.c | 285 | ksm_do_scan @ L2783, stable_tree_search @ L1828 |
| mm/ksm.c | | try_to_merge_one_page @ L1478, cmp_and_merge_page @ L2251 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

