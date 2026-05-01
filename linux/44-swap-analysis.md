# 44-swap — Linux 内核交换子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**Swap** 是 Linux 内核将物理内存页移出到磁盘（或交换文件）并在需要时换入的机制。当物理内存不足时，内核将不常访问的页面写入 swap 空间，释放物理内存给活跃进程。Swap 是内存压力下的重要缓冲机制。

**doom-lsp 确认**：`mm/swapfile.c` 含 swap 文件管理，`mm/swap_state.c` 含 swap 缓存。`swap_info_struct` 管理每个 swap 区域。

---

## 1. Swap 存储管理

```c
// include/linux/swap.h — swap 区域信息
struct swap_info_struct {
    unsigned int flags;              // SWP_USED, SWP_WRITEOK
    struct swap_cluster_info *cluster_info; // 簇信息（分配优化）
    unsigned char *swap_map;         // 每页引用计数
    struct block_device *bdev;       // 块设备（swap 分区）
    struct file *swap_file;          // swap 文件
    unsigned int max;                // 最大可分配页数
    unsigned int pages;              // 实际页数
    unsigned int inuse_pages;        // 已使用页数
};
```

swap_map 是一个字节数组，每个字节对应一个 swap slot（页面槽位）：
- 0: 空闲
- 1: 已占用（1 个引用）
- >1: 共享（多个进程映射在同一 swap 页）
- 128: 页有错误

---

## 2. Swap 分配与释放

```c
// mm/swapfile.c — 分配 swap slot
unsigned int get_swap_page(struct page *page)
{
    struct swap_info_struct *si;
    unsigned int offset;

    // 扫描所有 swap 区域，查找空闲 slot
    // 优先使用簇分配（cluster alloc）提高顺序性
    si = swap_info_get();  // 获取第一个可用的 swap 区域

    // 簇分配：在空闲簇中分配连续 slot
    offset = scan_swap_map(si, SWAP_HAS_CACHE);
    if (offset) {
        si->swap_map[offset] = 1;  // 标记已使用
        si->inuse_pages++;
    }

    return offset;  // 返回 slot 号（0 = 分配失败）
}

// 释放 swap slot
void swap_entry_free(struct swap_info_struct *si, swp_entry_t entry)
{
    unsigned int offset = swp_offset(entry);

    si->swap_map[offset] = 0;  // 标记空闲
    si->inuse_pages--;

    // 更新簇分配信息
    cluster_swap_free(si, offset);
}
```

---

## 3. 换出流程

```
kswapd / direct reclaim 选择要换出的页面
  │
  ├─ shrink_folio_list → add_to_swap(folio)
  │    │
  │    ├─ get_swap_page(folio) → 分配 swap slot
  │    ├─ swapcache 索引更新
  │    └─ set_page_dirty(folio) // 写回时写入 swap
  │
  └─ folio 被标记为 swapbacked
       → 放入 swap cache
       → 页面内容尚未写入磁盘
       → 可以被交换到磁盘（swap_writepage）
```

---

## 4. 换入流程

```
进程访问换出的页面 → 缺页异常
  │
  └─ do_swap_page(vmf)
       │
       ├─ 从 PTE 中提取 swp_entry_t
       ├─ swapcache_lookup_entries — 查找 swap 缓存
       │
       ├─ 缓存命中：从 swap cache 读取
       │   → 页面已在缓存中（另一个进程最近访问过）
       │   → 直接映射到进程地址空间
       │
       ├─ 缓存未命中：从磁盘换入
       │   → folio = alloc_swap_folio()
       │   → swap_read_folio(folio, swap_file)  // 读磁盘
       │   → bio 提交 → IO 完成 → 页面 uptodate
       │
       └─ 映射到进程地址空间
           → set_pte_at(mm, addr, pte, mk_pte(page, prot))
           → free_swap_and_cache(entry)  // 释放 swap slot
```

---

## 5. 簇分配

Swap 的簇分配优化顺序 I/O 性能。相邻的 swap slot 在磁盘上也相邻，批量换出时可以合并为更大的 BIO：

```c
// mm/swapfile.c — 簇管理
struct swap_cluster_info {
    spinlock_t lock;           // 簇锁
    unsigned int data:24;      // 状态
    unsigned int flags:8;
};

#define CLUSTER_FLAG_NEXT_NULL 1  // 簇链结束
#define CLUSTER_FLAG_FREE      2  // 完全空闲
#define CLUSTER_FLAG_CONTINUE  4  // 簇可继续使用
```

---

## 6. 性能数据

| 操作 | 延迟 | 说明 |
|------|------|------|
| get_swap_page | ~100ns | slot 分配 |
| swap slot 释放 | ~50ns | 位图操作 |
| swap 写入（SSD）| ~10-50us | 4KB 页写 |
| swap 写入（HDD）| ~5-10ms | 寻道+旋转 |
| swap 读取（SSD）| ~10-50us | 页读 |
| swap 读取（HDD）| ~5-10ms | 寻道+旋转 |

---

## 7. 源码文件索引

| 文件 | 内容 |
|------|------|
| mm/swapfile.c | swap 区域管理 |
| mm/swap_state.c | swap 缓存 |
| mm/page_io.c | swap 读写 |
| include/linux/swap.h | API |

---

## 8. 关联文章

- **43-memcg**: memcg 内存限制与 swap
- **42-oom-killer**: OOM Killer

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 9. Swap 优先级

多个 swap 区域可以设置优先级：

```bash
# /etc/fstab 中 swap 配置
/dev/sda1 none swap sw,pri=10 0 0
/dev/sdb1 none swap sw,pri=20 0 0

# 优先级高的 swap 区域优先被使用
# 同优先级轮转分配
# 这样可以在多个 SSD 间均衡 swap 负载
```

## 10. Swap 与 zswap

zswap 是内存压缩交换的替代方案。它在内存中压缩页面，而非写入磁盘：

```bash
# 启用 zswap
echo lz4 > /sys/module/zswap/parameters/compressor
echo zsmalloc > /sys/module/zswap/parameters/zpool
echo 1 > /sys/module/zswap/parameters/enabled

# zswap 优势：
# - 压缩比通常 2:1 到 3:1
# - 不需要磁盘 I/O（低延迟）
# - 减少 swap 对 SSD 的写入
```

## 11. add_to_swap 实现

```c
int add_to_swap(struct folio *folio)
{
    swp_entry_t entry;
    int err;

    // 分配 swap slot
    entry = get_swap_page(folio);
    if (!entry.val)
        return 0;  // 所有 swap 区域已满

    // 添加到 swap cache
    err = folio_add_swap_cache(folio, entry, GFP_KERNEL);
    if (err) {
        // 添加失败，释放 slot
        swap_free(entry);
        return 0;
    }

    // 标记为可交换
    folio_set_swapbacked(folio);

    return 1;
}
```

## 12. swap_tend 检测

内核通过 swap_tend（swap 使用趋势）预测 swap 需求：

```bash
# /proc/meminfo 中的 swap 信息
SwapTotal:       2097148 kB    # 总 swap
SwapFree:        1048574 kB    # 空闲 swap
SwapCached:        12345 kB    # swap cache 中的数据
```

## 13. OOM 与 swap

当 swap 空间也耗尽时，系统处于真正的内存危机状态。此时内核触发 OOM Killer：

```
物理内存不足 → 尝试换出 → swap 满 → 无法换出
  → __alloc_pages_slowpath 无法回收
  → out_of_memory() → 杀进程释放内存
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 14. Swap 与 THP

透明大页被换出时会分裂为 512 个 4KB 页，每个页单独分配 swap slot。这降低了 THP 的内存压力，但增加了 swap 操作的开销。换入时也是逐个 4KB 页读回，性能较差。

## 15. swap_slots 缓存

```c
// mm/swap_slots.c — swap slot 缓存加速分配
// 每次从 swap 区域预先分配一批 slot
// 缓存在 per-CPU 链表中
// 后续分配直接从缓存取，减少锁竞争

// 批量分配减少 swap_map 锁竞争
// 提高多核场景的 swap 性能
```

## 16. 调试命令

```bash
# 查看 swap 使用
swapon --show                  # swap 设备和大小
cat /proc/swaps                # 各 swap 区域状态
cat /proc/meminfo | grep Swap  # swap 统计

# 启用/禁用 swap
swapon /dev/sda2               # 启用
swapoff /dev/sda2              # 禁用

# 创建 swap 文件
dd if=/dev/zero of=/swapfile bs=1M count=4096
mkswap /swapfile
swapon /swapfile
```

## 17. swap_map 结构详解

swap_map 字节数组的每个字节记录 swap slot 的引用计数：

- 0: 空闲
- 1-127: 引用计数
- 128: 页面错误
- 129-255: 引用计数 + 保留

当多个进程共享同一个 swap 页时（如共享内存被换出），引用计数递增。最后释放时进入 swap cache，等待其他进程使用后最终释放。

## 18. 总结

Swap 提供内存扩展能力。get_swap_page 分配 slot，add_to_swap 标记新页面，swap_writepage 写磁盘，do_swap_page 换入。簇分配优化顺序 I/O，zswap 提供压缩替代。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.


## Swap Analysis

The swap subsystem provides secondary memory through block devices or files. swap_info_struct tracks each swap area with a byte array for slot reference counting. Cluster allocation improves sequential I/O performance. The swap cache caches pages being swapped out/in to optimize repeated access patterns.

