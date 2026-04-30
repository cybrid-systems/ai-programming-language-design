# KSM — 内核同页合并深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/ksm.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**KSM（Kernel Samepage Merging）** 合并多个进程相同的内存页，节省内存。典型用途：虚拟机（QEMU/KVM）内存去重。

---

## 1. 核心数据结构

### 1.1 stable_node — 合并后的稳定节点

```c
// mm/ksm.c — stable_node
struct stable_node {
    struct rb_node          node;          // 接入 stable_root 红黑树
    struct page            *page;          // 合并后的物理页
    unsigned long           checksum;       // 内容的校验和（快速比较）
    struct rcu_head         rcu;           // RCU 释放
    struct hlist_node       hlist;         // hash 链表
    void                   *slot[1];       // Stable slot（stable tree）
};
```

### 1.2 unstable_node — 未合并的候选

```c
// mm/ksm.c — unstable_node
struct unstable_node {
    struct hlist_node       hlist;         // 接入 hash 链表
    struct rcu_head         rcu;           // RCU 释放
    unsigned long           checksum;      // 内容校验和
    void                   *slot[1];       // 指向不稳定树中的节点
};
```

### 1.3 全局根

```c
// mm/ksm.c — 全局 KSM 数据
struct rb_root           stable_root = RB_ROOT;  // 稳定节点树
struct rb_root           unstable_tree = RB_ROOT; // 不稳定节点树
struct hlist_head       *stable_hash;   // stable_node hash 表
struct hlist_head       *unstable_hash; // unstable_node hash 表

// 扫描参数
unsigned int            ksm_thread_pages_to_scan = 256; // 每次扫描页数
unsigned int            ksm_thread_sleep_ms = 2000;    // 扫描间隔
```

---

## 2. ksm_scan — 扫描流程

```c
// mm/ksm.c — ksm_scan_thread
static int ksm_scan_thread(void *data)
{
    while (!kthread_should_stop()) {
        // 1. 扫描一个页（256 页/次）
        page = get_next_page();

        if (!page || PageKsm(page))
            continue;

        // 2. 计算校验和（快速预检）
        checksum = memcmp_checksum(page);

        // 3. 在 unstable_tree 中查找匹配
        unstable = rb_lookup(unstable_tree, checksum);
        if (unstable) {
            // 4. 深度比较内容
            if (memcmp(page, unstable->page, PAGE_SIZE) == 0) {
                // 5. 合并：映射到同一物理页
                unstable->page = page;
                // 删除 unstable_node，加入 stable_node
            }
        } else {
            // 6. 加入 unstable_tree，等待匹配
            unstable_node_new(page, checksum);
        }

        // 7. 定期写回脏页
        if (page_is_dirty(page))
            ksm_write_page(page);
    }
}
```

---

## 3. 合并（KSM merge）

```c
// mm/ksm.c — ksm_merge_page
static int ksm_merge_page(struct page *page, struct stable_node *stable)
{
    // 1. 锁定 stable_node
    spin_lock(&stable->lock);

    // 2. 让所有映射此 page 的进程建立 COW
    //    （其他进程保留各自的副本）
    try_to_unmap(page, TTU_IGNORE_ACCESS);

    // 3. 建立共享映射
    //    所有进程的下一次 page fault → 建立共享映射 → page 变为 KSM page
    page_add_new_anon_rmap(page, stable->vma, address);

    // 4. 清除 PageKsm 前的脏标志
    ClearPageDirty(page);

    // 5. 建立 PMD/PTEs 映射到 stable->page
    //    所有参与者现在共享同一物理页

    spin_unlock(&stable->lock);

    return 0;
}
```

---

## 4. proc 接口

```
/sys/kernel/mm/ksm/
├── run                  ← 0=停止, 1=运行（madvise 区域）, 2=运行（所有区域）
├── pages_to_scan        ← 每次扫描页数（默认 256）
├── sleep_ms             ← 扫描间隔（默认 2000ms）
├── max_page_sharing     ← 单页最大共享者（默认 256）
├── pages_shared         ← 共享页数
├── pages_sharing        ← 正在被共享的页数
└── pages_volatile       ← 不稳定（频繁修改）页数
```

---

## 5. madvise 启用

```c
// 用户空间：
madvise(addr, len, MADV_MERGEABLE);
// 告诉 KSM 这个区域可以参与合并
madvise(addr, len, MADV_UNMERGEABLE);
// 告诉 KSM 不再合并
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `mm/ksm.c` | `ksm_scan_thread`、`ksm_merge_page` |
| `mm/ksm.c` | `stable_node`、`unstable_node` |