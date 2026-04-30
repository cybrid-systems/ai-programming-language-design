# Linux Kernel KSM (Kernel Samepage Merging) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/ksm.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 KSM？

**KSM（Kernel Samepage Merging）** 是 Linux 2.6.32+ 引入的**内存去重**机制，将多个进程间**内容相同的匿名页**合并为单个共享页，写时复制（COW），节省内存。

**典型应用场景**：
- 虚拟机：多个 KVM guest 进程共享相同内存页（如 OS 镜像）
- 容器：多个容器运行相同程序，共享代码段
- 数据库：多个进程加载相同数据集

---

## 1. 核心数据结构

### 1.1 rmap_item — 反向映射项

```c
// mm/ksm.c — rmap_item
struct ksm_rmap_item {
    struct mm_struct *mm;           // 所属进程的 mm
    unsigned long address;         // 虚拟地址
    struct ksm_mm_slot *mm_slot;  // 所属的 MM slot
    union {
        struct {
            struct ksm_rmap_item *next;
            // 指向同一 stable node 的下一个 rmap_item
        };
        struct ksm_stable_node *stable;
        // 如果已合并到 stable node
    };
    struct hlist_node link;        // 接入 hash 链表
    unsigned int old_index;        // hash 索引（旧）
    unsigned int new_index;        // hash 索引（新）
};
```

### 1.2 stable_node — 稳定节点（合并后的共享页）

```c
// mm/ksm.c — stable_node
struct ksm_stable_node {
    struct rcu_head rcu_head;       // RCU 释放
    struct page *page;              // 合并后的物理页
    int length;                    // 合并的页数（通常 1）
    union {
        struct {
            // 使用计数（不包括临时引用）
            int nid;               // NUMA 节点
        };
        struct {
            void *unstable_tree;   // unstable tree 根（RB_ROOT）
        };
    };
    struct hlist_node hlist;       // 接入 stable_nodes 哈希表
    // 内嵌的 rmap_item
    struct ksm_rmap_item *rmap_item_list[];
};
```

### 1.3 ksm_mm_slot — 进程 MM slot

```c
// mm/ksm.c — ksm_mm_slot
struct ksm_mm_slot {
    struct mm_struct *mm;           // 所属进程
    struct ksm_rmap_item *rmap_list; // 此进程的所有 rmap_item
    struct list_head mm_node;      // 接入 mm_slot 链表
    int rmap_items;                // rmap_item 数量
};
```

---

## 2. KSM 工作原理

```
扫描流程：
1. khaled_scan_mm_slot() 遍历每个 KSM 进程的 VMA
2. 对每个 VMA 中的匿名页：
   a. 生成 hash(key = 页内容)
   b. 查 unstable_tree（红黑树）找相同内容的页
   c. 如果找到 candidate，加入 unstable tree
   d. 如果 unstable 树中相同内容的页达到阈值，合并到 stable node

合并流程：
1. cmp_and_merge_page(page) 检查是否可以合并
2. if (stable_node exists):
      - 将此进程的 rmap_item 加入 stable_node->rmap_item_list
      - 将页引用计数 -1（共享页）
   else:
      - 创建新的 stable_node
      - 将页加入 stable_nodes 哈希表
```

---

## 3. cmp_and_merge_page — 核心合并

```c
// mm/ksm.c — cmp_and_merge_page
static struct rmap_item *cmp_and_merge_page(struct page *page,
                    struct rmap_item *rmap_item)
{
    // 1. 计算 hash
    new_index = hpage_hash(page);

    // 2. 查 unstable tree 找相同内容的页
    struct stable_node *stable_node;
    stable_node = page_stable_node(page);

    if (stable_node) {
        // 页已在 stable_node 中
        // 将新的 rmap_item 加入 stable_node
        add_rmap_item_to_stable(rmap_item, stable_node);
        return NULL;
    }

    // 3. 查找或创建 stable_node
    stable_node = stable_tree_search(page);
    if (stable_node) {
        // 找到匹配的 stable_node，进行合并
        // 删除原来的 unstable tree 节点
        remove_rmap_item_from_tree(rmap_item);

        // 加入 stable_node
        add_rmap_item_to_stable(rmap_item, stable_node);

        // 触发 COW：将共享页设为只读
        stable_node->page = page;
        return rmap_item;
    }

    // 4. 未找到 stable_node，加入 unstable tree 等待
    insert_rmap_item_to_tree(rmap_item, new_index);
    return NULL;
}
```

---

## 4. COW 机制

```
KSM 合并后的页：

进程 A 的 PTE          进程 B 的 PTE          进程 C 的 PTE
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ PTE_A        │     │ PTE_B        │     │ PTE_C        │
│ Page-X (RO)  │◄───│ Page-X (RO)  │◄───│ Page-X (RO)  │
│ refcount=3   │     │ (same)       │     │ (same)       │
└──────────────┘     └──────────────┘     └──────────────┘

当进程 A 写入 Page-X 时（触发 page fault）：
  → do_wp_page()
  → PageAnonExclusive(page) → false（共享，只读）
  → 分配新页 Page-Y
  → 复制 Page-X 内容到 Page-Y
  → PTE_A → Page-Y (R/W)
  → refcount(Page-X)--
  → Page-X 现在 refcount=2，继续共享

结果：
  - 进程 A 有独立的 Page-Y
  - 进程 B 和 C 仍共享 Page-X
```

---

## 5. 扫描策略

```c
// /sys/kernel/mm/ksm/ 控制接口
// pages_to_scan：每次扫描的页数（默认 100）
// sleep_millisecs：两次扫描间隔（默认 20ms）
// run：启动/停止 KSM
// max_page_sharing：单个页最多被多少进程共享（默认 256）
// use_zero_pages：零页合并

// 扫描顺序：
// 1. 按 mm_slot 链表遍历所有注册 KSM 的进程
// 2. 每个进程按 VMA 扫描
// 3. 对每个匿名页，生成 hash，查 unstable/stable tree
```

---

## 6. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| unstable tree | 合并前需要多次扫描确认内容相同 |
| stable_node 合并 | 多次确认后加入 stable，避免重复合并开销 |
| hash 加速查找 | 不需要逐页比较内容 |
| rmap_item 追踪 | 每个进程一个 rmap_item，方便页拆分后更新 |
| PG_Owner_priv_1 (KSM) | 在 struct page 中标记 KSM 管理的页 |

---

## 7. 参考

| 文件 | 内容 |
|------|------|
| `mm/ksm.c` | `cmp_and_merge_page`、`stable_tree_search`、`insert_rmap_item_to_tree` |
| `mm/ksm.c` | `struct ksm_rmap_item`、`struct ksm_stable_node`、`struct ksm_mm_slot` |
| `mm/rmap.c` | `page_anon`、`rmap_walk`（KSM 与 rmap 交互）|
