# 196-memory_hotplug — 内存热插拔深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/memory_hotplug.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Memory Hotplug** 允许在线添加/移除内存，扩大或收缩系统内存，无需重启。

---

## 1. 热添加

```bash
# 添加内存：
echo 1 > /sys/devices/system/memory/memoryN/online

# 移除内存：
echo 0 > /sys/devices/system/memory/memoryN/online

# 查看内存节点：
cat /proc/buddyinfo
```

---

## 2. 核心函数

```c
// mm/memory_hotplug.c — online_pages
int online_pages(unsigned long pfn, unsigned long nr_pages)
{
    // 1. 设置页为可用
    for (pfn to pfn+nr_pages) {
        online_page(page, ONLINE_PUBLIC);
    }

    // 2. 重建 free area
    __online_page_set_free(pfn, nr_pages);

    // 3. 更新 buddy
    node_states[N_MEMORY] = 1;
}
```

---

## 3. 西游记类喻

**Memory Hotplug** 就像"天庭的扩建队"——

> memory hotplug 像天庭的扩建队——可以在天庭运行时，扩建新的营地（添加内存），或者收缩一些不用的营地（移除内存）。扩建和收缩都需要更新天庭的地图（buddy system），并通知各部门（各 CPU）地图变了。

---

## 4. 关联文章

- **page_allocator**（article 17）：hotplug 影响 buddy system
- **compaction**（article 191）：hotplug 可能需要 compaction 准备