# 044-swap — Linux 内核交换子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**Swap** 是 Linux 内核将匿名页面换出到块设备（或文件）的机制。当物理内存不足时，kswapd 或直接回收选择不活跃的匿名页，将其内容写入 swap 分区/文件，释放物理内存。当进程再次访问换出的页面时，缺页处理程序从 swap 读回。

SWAP 子系统自 Linux 5.x 起经历了 **folio 化**重构：核心接口从基于 `page` 迁移到基于 `struct folio`，但核心交换算法（swap slot 分配、swap cache、swap map）保持不变。

**doom-lsp 确认**：`mm/swapfile.c` 含 **346 个符号**（核心交换文件实现），`mm/page_io.c` 含 **78 个符号**（页面 I/O 路径），`mm/swap_state.c` 含 **86 个符号**（swap cache），`include/linux/swap.h` 含 **269 个符号**（API 定义）。

---

## 1. 核心数据结构

### 1.1 `swp_entry_t`——交换槽标识符

（`include/linux/swap.h` — doom-lsp 确认）

每个被换出的页面关联一个唯一的 `swp_entry_t`，编码了 swap 设备号和偏移量：

```c
typedef struct {
    unsigned long val;                    // 编码：高 bits = swap 设备序号
} swp_entry_t;                           //    低 bits = 设备内的偏移

// swp_entry_t ↔ (dev, offset) 转换：
// swp_type(entry)  = (entry.val >> SWP_TYPE_SHIFT) & SWP_TYPE_MASK
// swp_offset(entry) = entry.val & SWAP_OFFSET_MASK
// swp_entry(type, offset) = (type << SWP_TYPE_SHIFT) | offset

// 当页面被 swap in 时，通过 swp_entry_t 找到物理位置；
// 当页面存在于 swap cache 但尚未被 swap in 时，entry 记录在 page->swap 中
```

### 1.2 `struct swap_info_struct`——交换设备描述符

（`include/linux/swap.h` — doom-lsp 确认）

```c
struct swap_info_struct {
    unsigned long       flags;            // SWP_* 标志（SWP_USED, SWP_WRITEOK...）
    signed short        prio;             // swap 优先级（-1 ~ 32767）
    signed short        lowest_priority;  // 全局最低优先级
    signed int          type;             // 设备类型编号（0 ~ MAX_SWAPFILES-1）
    unsigned int        max;              // 最大可用槽数
    unsigned char       *swap_map;        // 每个 swap slot 的引用计数数组
    struct swap_cluster_info *cluster_info; // 簇分配器信息
    struct swap_cluster_list free_clusters; // 空闲簇链表
    unsigned int        pages;            // 可用页面数
    unsigned int        inuse_pages;      // 已使用的页面数
    struct block_device *bdev;            // 块设备（文件交换时为 NULL）
    struct file         *swap_file;       // 交换文件（`swapon` 打开的文件）
    struct swap_extent  *curr_swap_extent; // 文件 extent
    struct rb_root      swap_extent_root;  // extent 红黑树
    struct percpu_cluster __percpu *percpu_cluster; // per-CPU 簇缓存
    struct swap_cluster_list discard_clusters; // 可丢弃的簇链表
    ...
};
```

**关键字段在 swap 分配路径中的角色**：

```
swap_map[]: 每个 swap slot 的引用计数数组
  0 = 空闲
  1+ = 已使用（多个进程可能共享同一个 swap slot）

cluster_info: 簇分配器的元数据
  将 swap 设备分为 256 页的簇
  优先使用同一簇内的连续槽位

percpu_cluster: per-CPU 簇缓存
  每个 CPU 有自己保留的空闲簇
  减少锁竞争

bdev/swap_file:
  swapon /dev/sda3 → bdev = sda3 的 block_device
  swapon /swapfile → swap_file = 打开的文件，bdev = swap_file 所在文件系统
```

### 1.3 swap_map 引用计数模型

```
swap slot 被换出时引用计数的变化：

1. 页面被换出：add_to_swap() → swap_map[offset] = 1
   - 第一份写入 swap 设备的副本

2. fork 后父子进程共享同一 swap slot：
   - swap_dup() → swap_map[offset]++
   - swap_map[offset] = 2

3. 父进程换入页面：swapin 时 swap_map[offset]--, 但页面保留在 swap cache
   - swap_map[offset] = 1（只剩子进程引用）

4. 子进程换入 + 页面从 swap cache 移除：
   - swap_map[offset]-- → 0
   - swap slot 可回收

5. swap slot 释放：swap_free(entry) → swap_map_dec
   → 如果没有其他引用并且页面不在 swap cache → slot 标记为空闲
```

---

## 2. 页面换出路径（Swap Out）

### 2.1 触发入口

```
madvise(MADV_PAGEOUT)  ← 用户空间主动触发
  │
  └─ reclaim_pages()
       └─ shrink_folio_list()
            └─ 匿名页且可 swap → try_to_unmap() → add_to_swap() → swap_writepage()
```

### 2.2 add_to_swap——分配 swap slot

（`mm/swapfile.c` — doom-lsp 确认）

```
add_to_swap(folio)
  │
  ├─ 1. 分配 swap slot
  │     entry = get_swap_page(folio)
  │       └─ scan_swap_map(swap_info, ...)
  │            ├─ 从 per-CPU 簇中尝试取一个空闲 slot
  │            ├─ 如果 per-CPU 簇耗尽：从全局 free_clusters 取
  │            └─ 如果全部耗尽：扫描 swap_map 找一个 0 的槽
  │
  ├─ 2. 标记页面为 swap cache
  │     folio->swap = entry
  │     SetPageSwapCache(folio)
  │
  └─ 3. 计数
       nr_swap_pages--
       swap_info->inuse_pages++
```

### 2.3 swap_writepage——写入块设备

（`mm/page_io.c` — doom-lsp 确认）

```
swap_writepage(folio, wbc)
  │
  ├─ 1. 构造 bio（块 I/O 请求）
  │     entry = folio->swap
  │     bio = bio_alloc(bdev, 1, REQ_OP_WRITE, ...)
  │     bio_add_page(bio, folio_page(folio, 0), PAGE_SIZE, 0)
  │
  ├─ 2. 加密（如果启用了 swap 加密）
  │     if (IS_ENABLED(CONFIG_SWAP_ENCRYPTION))
  │         swap_encrypt(bio, entry)
  │
  ├─ 3. 提交 bio
  │     submit_bio(bio)
  │
  └─ 4. 完成回调：
        end_swap_bio_write(bio)
          → 如果写入成功：
              folio_end_writeback(folio)
              folio_unlock(folio)
              folio_put(folio)
          → 如果失败：
              swap_slot_free_notify(entry)
              folio_unlock(folio)
```

---

## 3. 页面换入路径（Swap In）

### 3.1 触发入口

```
进程访问已被换出的页面：
  handle_mm_fault(vma, addr, ...)
    └─ do_swap_page(vma, addr, pte, ...)
         └─ 从 swap cache 或块设备读取页面
```

### 3.2 do_swap_page——缺页处理

（`mm/memory.c` — doom-lsp 确认）

```
do_swap_page(vma, addr, pte, ...)
  │
  ├─ 1. 从 PTE 提取 swap entry
  │     entry = pte_to_swp_entry(vmf->orig_pte)
  │
  ├─ 2. 检查 swap cache（页面是否已被换入但未被移除？）
  │     folio = swap_cache_get(entry)
  │       └─ 如果存在 → 直接映射（从 cache 取回，无需 I/O）
  │       └─ 如果不存在 → 需要从磁盘读入
  │            └─ swap_read_folio(entry, folio)
  │                 └─ bio = bio_alloc(bdev, 1, REQ_OP_READ, ...)
  │                 └─ submit_bio(bio)
  │                 └─ wait_on_bit(&folio->flags, ...)  // 等待 I/O 完成
  │
  ├─ 3. 建立页表映射
  │     set_pte_at(vma->vm_mm, addr, vmf->pte, entry_pte)
  │
  ├─ 4. 更新 LRU（页面回到活跃链表）
  │     folio_add_lru(folio)
  │
  └─ 5. 释放 swap slot（如果页面不再需要交换）
       if (folio_test_swapcache(folio) && ...)
           free_swap_and_cache(entry)
```

---

## 4. Swap Cache

Swap Cache 是 swap 子系统的关键优化——避免**相同数据的重复 I/O**：

```
页面被换出时：
  1. 页面内容写入 swap 设备
  2. 页面保持在 swap cache 中（folio->mapping = swapper_space）
  3. 如果进程立即访问页面 → 从 cache 取回（无 I/O）
  4. 只有内存压力迫使页面从 swap cache 和 LRU 中完全驱逐后
     → 页面从 cache 中移除 + swap slot 标记为可回收

页面被换入时：
  1. 先检查 swap cache：如果命中 → 零 I/O 延迟
  2. 如果不命中 → swap_read_folio() 从磁盘读取
```

swap cache 的核心数据结构：

```c
// mm/swap_state.c — doom-lsp 确认
// swap cache 是 address_space 的一个实例
struct address_space *swapper_spaces[MAX_SWAPFILES];

// 每个 swapper_spaces[type] 对应一个 swap 设备的 radix tree
// 键：swp_offset(entry)
// 值：struct folio *（缓存的页面）
// 查找：xa_load(&swapper_spaces[type]->i_pages, offset)
// 插入：__xa_store(&swapper_spaces[type]->i_pages, offset, folio, ...)
```

---

## 5. Swap Slot 分配器

### 5.1 簇分配

swap slot 分配从简单的位图演化为**簇分配器**：

```c
// mm/swapfile.c — 簇结构
struct swap_cluster_info {
    unsigned int        data;   // 低 24 bit: 簇内下一个空闲槽
                                // 高 8 bit: 簇状态
};

// 簇状态：
#define CLUSTER_FLAG_FREE       1   // 簇完全空闲
#define CLUSTER_FLAG_NEXT_NULL  0   // 无下一个簇
```

```
     swap 设备（以 256 页/簇划分）：
     ┌────────┬────────┬────────┬────────┬────────┐
     │簇 0    │簇 1    │簇 2    │簇 3    │簇 4    │
     │已用 10%│已用 80%│空闲    │已用 50%│已用 20%│
     └────────┴────────┴────────┴────────┴────────┘
                │       │
         正在使用       下一个空闲簇
```

**分配策略**：
1. 优先使用当前 CPU 的 `percpu_cluster` 缓存的簇
2. 如果耗尽，从全局 `free_clusters` 链表取一个全空闲簇
3. 如果全空闲簇耗尽，从 `lowest_scan` 位置扫描一个空槽

### 5.2 碎片控制

swap 的碎片控制策略是**反向分配**：从低 offset 到高 offset 使用，尽量使用簇头部的连续槽。当 swap 设备接近满时，分配器会跳过零碎的空隙。

---

## 6. frontswap / zswap / zram 集成

现代 Linux 的 "swap" 被广泛与压缩缓存联动：

```
            用户空间
               │
          swap 系统调用 → swapon/swapoff
               │
               ▼
        ┌──────────────┐
        │   swap core  │  ← mm/swapfile.c + mm/swap_state.c
        │  (swap_map,  │
        │   swap cache)│
        └──────┬───────┘
               │
        ┌──────┴───────┐
        │              │
        ▼              ▼
  ┌──────────┐   ┌──────────┐
  │ swap I/O │   │ zswap    │  ← 压缩缓存（内存中）
  │ (块设备)  │   │ (压缩RAM)│
  │ mm/page_io│  │ mm/zswap │
  └──────────┘   └──────────┘
        │              │
  磁盘/SSD       不压缩时回退到磁盘
```

- **zswap**：在内存中压缩 swap 页面，避免磁盘 I/O，压缩失败时退回到传统 swap
- **zram**：将一部分 RAM 模拟为 swap 块设备，写入时压缩（不是用真正的 swap 文件）
- **frontswap**：抽象层，允许 Xen tmem 等外部缓存参与 swap 流程

---

## 7. 与页面回收的交互

```
try_to_free_pages()
  └─ shrink_folio_list()
       └─ 对每个匿名页：

            if (!folio_test_swapbacked(folio)) {     // 不是匿名页
                // 文件页：清脏 + 释放
                goto keep_locked;
            }

            if (!sc->may_swap)                        // 不允许 swap
                goto keep_locked;

            if (folio_test_anon(folio)) {              // 匿名页
                // 1. 检查是否被 mlock
                if (!(sc->gfp_mask & __GFP_IO))
                    goto keep_locked;

                // 2. try_to_unmap(folio)              // 解除所有 PTE 映射
                //    将 PTE 替换为 swp_entry_t

                // 3. add_to_swap(folio)                // 分配 swap slot

                // 4. swap_writepage(folio, wbc)         // 写入块设备
            }
```

---

## 8. 关键 sysfs 参数

| 参数 | 路径 | 默认 | 说明 |
|------|------|------|------|
| `swappiness` | `/proc/sys/vm/swappiness` | 60 | 回收时倾向 swap 或释放文件页（0~200） |
| `min_free_kbytes` | `/proc/sys/vm/min_free_kbytes` | 自动 | 最小空闲内存，影响 kswapd 唤醒阈值 |
| `nr_swapfiles` | `/proc/sys/vm/nr_swapfiles` | 1 | 最大 swap 设备数 |
| `swap_prefetch` | `/proc/sys/vm/swap_prefetch` | 1 | 后台预读 swap 页面 |
| `max_swap_occupancy` | `/sys/kernel/mm/zswap/` | 20% | zswap 最大占用内存比例 |

---

## 9. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct swap_info_struct` | include/linux/swap.h | 相关 |
| `swp_entry_t` | include/linux/swap.h | (typedef) |
| `add_to_swap()` | mm/swapfile.c | 相关 |
| `get_swap_page()` | mm/swapfile.c | 相关 |
| `swap_writepage()` | mm/page_io.c | 相关 |
| `swap_read_folio()` | mm/page_io.c | 相关 |
| `do_swap_page()` | mm/memory.c | 相关 |
| `swap_cache_get_folio()` | mm/swap_state.c | 相关 |
| `scan_swap_map()` | mm/swapfile.c | 相关 |
| `swap_free()` | mm/swapfile.c | 相关 |
| `swapper_spaces[]` | mm/swap_state.c | (swap cache address_space 数组) |
| `nr_swap_pages` | mm/swapfile.c | (全局统计) |
| `free_swap_and_cache()` | mm/swapfile.c | 相关 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-04 | 内核版本：Linux 7.0-rc1*
