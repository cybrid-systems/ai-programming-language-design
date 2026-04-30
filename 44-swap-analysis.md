# Linux Kernel Swap 与 zswap 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/swapfile.c` + `mm/zswap.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 swap？

**swap** 是将物理内存页**换出到磁盘**的机制，当内存压力时，将不活跃的页写入 swap 设备/文件，释放物理内存。

---

## 1. swap_entry — 交换条目

```c
// mm/swapfile.c — swap_info_struct
struct swap_info_struct {
    unsigned long   max;           // 最大交换空间
    unsigned long   inuse_pages;   // 已用页数
    unsigned int    prio;         // 优先级
    atomic_t        cluster_next;  // 下一个可用簇
    struct plist_head    avail_list; // 可用页链表

    /* 文件或设备 */
    struct file     *swap_file;    // 交换文件
    struct address_space *swap_file->f_mapping;

    /* 位图 */
    unsigned long   *bitmap;
    unsigned long   bitmap_last;
    struct swap_cluster_info *cluster_info;
};

// SWP_ENTRY — PTE 中的 swap 条目编码
// swap entry = (offset << SWP_TYPE_SHIFT) | SWP_TYPE
//   offset: swap 设备上的页号
//   type:  swap 设备类型（文件/分区）
```

---

## 2. swap_in / swap_out — 换入换出

```c
// mm/page_io.c — swap_readpage
int swap_readpage(struct page *page, bool do_poll)
{
    struct swap_info_struct *sis = page_swap_info(page);
    struct bio *bio;

    // 1. 获取 swap 位置
    offset = __swap_entry_to_loc(sis, page);

    // 2. 创建 bio（块 I/O 请求）
    bio = bio_alloc(sis->bdev, 1, REQ_OP_READ, GFP_KERNEL);
    bio->bi_iter.bi_sector = offset << (PAGE_SHIFT - 9);  // sector = 页号 * 8
    bio_add_page(bio, page, PAGE_SIZE, 0);

    // 3. 提交 I/O
    submit_bio_wait(bio);
}

// swap_writepage — 换出
int swap_writepage(struct page *page, struct writeback_control *wbc)
{
    // 与 swap_readpage 类似，但：
    // 1. REQ_OP_WRITE
    // 2. 检查 PG_dirty，在 swap 设备上设置脏标记
}
```

---

## 3. 换出时机

```
kswapd / direct reclaim 触发换出：
  1. zone watermark < min
  2. shrink_inactive_list() → 扫描 LRU
  3. 如果 page->mapping 是 anonymous（没有文件后备）：
     → 调用 swap_writepage() 换出
  4. 设置 PTE 为 swap entry（指向 swap 位置）
  5. 释放物理页，回到 buddy system
```

---

## 4. zswap — 压缩交换

```c
// mm/zswap.c — zswap
// zswap 在内存压力时，将要换出的页压缩存储到内存中的一个池
// 比写磁盘快，比不换出安全

// 流程：
// 1. 换出时：
//    zswap_store(page) → compress(page) → store in zpool
//    如果 zpool 满，触发 zswap_frontswap_store → 实际写入 swap 设备
// 2. 换入时：
//    检查 zswap 池是否有该页
//    如果有，解压并返回（无需访问磁盘）
```

---

## 5. 参考

| 文件 | 内容 |
|------|------|
| `mm/swapfile.c` | `swap_info_struct`、`swap_readpage`、`swap_writepage` |
| `mm/page_io.c` | `swap_readpage`、`submit_bio_wait` |
| `mm/zswap.c` | `zswap_store`、`zswap_frontswap_store` |
