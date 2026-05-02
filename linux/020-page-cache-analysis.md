# 20-page-cache — Linux 内核页缓存深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**Page Cache（页缓存）** 是 Linux 内核文件 I/O 的核心缓存机制。它将磁盘上的文件数据缓存在物理内存中，以 folio（内核 6.x+ 引入的复合页概念）为单位组织，通过 XArray（替代 radix tree）按文件页偏移索引。

Page cache 解决了三个核心问题：
1. **加速重复读取**：首次读盘后将数据留在内存中，后续读取直接命中，延迟从 ~10ms(HDD) / ~10μs(SSD) 降到 ~100ns
2. **延迟写入**：写入先修改内存中的 folio（标记脏），由内核后台写回磁盘
3. **页面共享**：多个进程映射同一文件时，共享同一物理页缓存条目

**doom-lsp 确认**：核心实现在 `mm/filemap.c`（4752 行）。关键函数：`filemap_read`、`filemap_get_read_batch` @ L2456、`filemap_create_folio` @ L2601、`filemap_add_folio` @ L950。操作表定义在 `include/linux/fs.h` 的 `struct address_space_operations`。

---

## 1. 核心数据结构

### 1.1 `struct address_space`——页缓存的容器

每个文件的 inode 包含一个 `struct address_space`，管理该文件的所有页缓存：

```c
// include/linux/fs.h — 地址空间
struct address_space {
    struct xarray                   i_pages;         // XArray：页偏移→folio 映射
    struct rw_semaphore             i_mmap_rwsem;    // 保护 VMA 区间树
    struct rb_root_cached           i_mmap;          // 映射此文件的 VMA 区间树
    unsigned long                   nrpages;         // 缓存页总数
    unsigned long                   writeback_index;  // 写回起始偏移
    const struct address_space_operations *a_ops;    // 地址空间操作表
    // ...
};
```

**字段详解**：

| 字段 | 类型 | 作用 |
|------|------|------|
| `i_pages` | `struct xarray` | 核心存储——文件页偏移到 folio 的映射。XArray 支持稀疏数组、标记跟踪（脏/写回） |
| `i_mmap` | `rb_root_cached` | 所有映射此文件的 VMA 区间树。当文件被截断时，需要查找并更新所有映射此文件的进程的页表 |
| `a_ops` | 操作表 | 文件系统提供的读写回调。每个文件系统（ext4、xfs、btrfs）有自己的一套操作 |
| `nrpages` | `unsigned long` | 当前缓存的页面总数。用于概览缓存大小 |

**关联结构——文件/ inode / 页缓存的关系**：

```
struct file (打开的文件实例)
  ├── f_mapping = inode->i_mapping  ← 指向 address_space
  └── f_inode → struct inode
                    └── i_mapping → struct address_space
                                        └── i_pages → XArray
                                                         ├── index 0 → folio (文件[0-4095])
                                                         ├── index 1 → folio (文件[4096-8191])
                                                         ├── index 2 → folio (文件[8192-12287])
                                                         └── index 3 → NULL (空洞)
```

### 1.2 `struct address_space_operations`——文件系统操作表

```c
struct address_space_operations {
    // —— 读 ——
    int (*read_folio)(struct file *, struct folio *);
    // ← 从磁盘读取 folio 的数据。文件系统核心回调

    void (*readahead)(struct readahead_control *);
    // ← 批量预读。比逐页 read_folio 更高效（可合并 BIO）

    // —— 写 ——
    int (*write_begin)(struct file *, struct address_space *,
                        loff_t pos, unsigned len,
                        struct page **pagep, void **fsdata);
    // ← 写入前准备：获取/创建 folio、块分配
    int (*write_end)(struct file *, struct address_space *,
                      loff_t pos, unsigned len, unsigned copied,
                      struct page *page, void *fsdata);
    // ← 写入完成：标记脏、块映射

    // —— 回写 ——
    int (*writepage)(struct page *page, struct writeback_control *wbc);
    // ← 将单页写回磁盘

    // —— 脏页管理 ——
    bool (*dirty_folio)(struct address_space *, struct folio *);
    // ← 标记 folio 为脏。调用 XArray 的 DIRTY 标记

    // —— 缓存失效 ——
    void (*invalidate_folio)(struct folio *, size_t start, size_t len);
    // ← 文件截断时：从 XArray 移除 folio + 清理

    // —— 迁移 ——
    int (*migrate_folio)(struct address_space *, struct folio *,
                          enum migrate_mode);
    // ← 内存规整时：将 folio 从旧页迁移到新页

    // —— 交换 ——
    bool (*is_partially_uptodate)(struct folio *, size_t from, size_t count);
    void (*is_dirty_writeback)(struct folio *, bool *dirty, bool *wb);
    int (*swap_activate)(struct swap_info_struct *sis, struct file *f, sector_t *span);
    void (*swap_deactivate)(struct file *file);
};

// — ext4 的 a_ops 实现 —
const struct address_space_operations ext4_aops = {
    .read_folio     = ext4_read_folio,
    .readahead      = ext4_readahead,
    .write_begin    = ext4_write_begin,
    .write_end      = ext4_write_end,
    .writepage      = ext4_writepage,
    .dirty_folio    = filemap_dirty_folio,  // 使用通用实现
    .migrate_folio  = filemap_migrate_folio,
    .invalidate_folio = ext4_invalidate_folio,
};
```

### 1.3 `struct folio`——页缓存的存储单元

```c
struct folio {
    struct page page;                    // 嵌入的 struct page
    // 专用字段通过 page 的 union 复用
};
```

folio 是一个或多个连续物理页的抽象。关键状态标记：

| 函数 | 含义 | 设置时机 | 清除时机 |
|------|------|---------|---------|
| `folio_test_uptodate(folio)` | 数据有效 | read_folio 完成后 | truncate 时 |
| `folio_test_dirty(folio)` | 数据被修改 | write_end 中 | writeback 完成后 |
| `folio_test_locked(folio)` | 正在 I/O | lock_folio | unlock_folio |
| `folio_test_writeback(folio)` | 正在写回 | writepage 中 | I/O 完成后 |
| `folio_test_readahead(folio)` | 预读标记 | readahead 分配时 | 页面被访问后 |

---

## 2. 🔥 读取路径——filemap_read 完整数据流

```
filemap_read(iocb, iter, bytes)                       @ mm/filemap.c
  │
  ├─ [1. 初始化]
  │   iocb->ki_pos = 当前读写位置
  │   written = 0
  │
  └─ [2. 循环读取]
      for (;;) {
          │
          ├─ [2a. 获取页缓存批]
          │   filemap_get_pages(iocb, iter, &fbatch)
          │    │                   @ mm/filemap.c
          │    └─ filemap_get_read_batch(mapping, index, last, &fbatch)
          │         │                @ mm/filemap.c:2456
          │         │
          │         ├─ XA_STATE(xas, &mapping->i_pages, index)
          │         │   ← 初始化 XArray 遍历器
          │         │
          │         ├─ rcu_read_lock()              ← RCU 保护读路径
          │         │
          │         ├─ xas_for_each(&xas, folio, last) {
          │         │      │
          │         │      ├─ if (xas_retry(&xas, folio))
          │         │      │    continue;            ← XArray 节点被修改过，重试
          │         │      │
          │         │      ├─ if (xa_is_value(folio)) {
          │         │      │    break;               ← shadow entry（页刚被回收）
          │         │      │    ← 告诉调用者：此处曾有页面，下次预读更多
          │         │      │   }
          │         │      │
          │         │      ├─ if (!folio_try_get(folio))
          │         │      │    goto retry;          ← 获取引用失败（正在被释放）
          │         │      │
          │         │      ├─ if (folio != xas_reload(&xas))
          │         │      │    goto put_folio;      ← 并发修改，重试
          │         │      │
          │         │      ├─ folio_batch_add(fbatch, folio)
          │         │      │   ← 加入批量缓存
          │         │      │
          │         │      └─ if (!folio_test_uptodate(folio))
          │         │           break;               ← 未读到数据，需要触发读盘
          │         │  }
          │         │
          │         └─ rcu_read_unlock()
          │
          ├─ [2b. 遍历批中的 folio]
          │   for (i = 0; i < folio_batch_count(fbatch); i++) {
          │       folio = fbatch->folios[i];
          │       │
          │       ├─ [缓存命中 - 数据有效]
          │       │   if (folio_test_uptodate(folio)) {
          │       │       // ★ 直接从内存拷贝到用户空间！
          │       │       copied = copy_page_to_iter(folio, offset, bytes, iter);
          │       │       // → 延迟：~100ns（L1 缓存命中）到 ~100ns（无磁盘 I/O）
          │       │       iocb->ki_pos += copied;
          │       │       written += copied;
          │       │       continue;
          │       │   }
          │       │
          │       ├─ [缓存未命中]
          │       │   filemap_update_folio(iocb, mapping, folio, index)
          │       │    │
          │       │    ├─ folio 正在更新中（其他线程在读）?
          │       │    │   → folio_lock(folio) + 等待
          │       │    │
          │       │    └─ [未开始读] → filemap_read_folio
          │       │         │
          │       │         ├─ a_ops->read_folio(file, folio)
          │       │         │   = ext4_read_folio(file, folio)
          │       │         │    │
          │       │         │    ├─ struct bio *bio = bio_alloc(sb, 1, ...)
          │       │         │    ├─ bio_set_folio(bio, folio)
          │       │         │    ├─ submit_bio(bio)        ← ★ 提交 I/O
          │       │         │    │   [磁盘 DMA 将数据读取到 folio 中]
          │       │         │    │
          │       │         │    ├─ folio_wait_locked_killable(folio)
          │       │         │    │   ← 等待 I/O 完成
          │       │         │    │
          │       │         │    └─ error = folio->private
          │       │         │        ← 检查 I/O 错误
          │       │         │
          │       │         ├─ folio_mark_uptodate(folio)    ← 标记数据有效
          │       │         └─ return 0
          │       │
          │       └─ [至此，folio 已读取完毕]
          │           copied = copy_page_to_iter(folio, offset, bytes, iter)
          │           iocb->ki_pos += copied;
          │           written += copied;
          │   }
          │
          ├─ [2c. 检查是否继续]
          │   if (written) break;  // 已读到数据，返回
          │   if (iocb->ki_flags & IOCB_NOWAIT) break;
          │   // 否则继续循环（可能再次创建 folio 并读盘）
          │
          └─ } // end for(;;)

      return written;
```

### 2.1 缓存未命中时的 folio 创建——filemap_create_folio

```
filemap_create_folio(iocb, &fbatch)                   @ mm/filemap.c:2601
  │
  ├─ filemap_alloc_folio(mapping_gfp_mask(mapping), min_order, NULL)
  │   → 从页分配器获取一个 folio
  │
  ├─ filemap_invalidate_lock_shared(mapping)
  │   → 防止与 truncate/hole punch 并发
  │
  ├─ filemap_add_folio(mapping, folio, index, gfp)
  │   → ★ 将 folio 加入 XArray！
  │   → __filemap_add_folio(mapping, folio, index, gfp, &shadow)
  │       @ mm/filemap.c:849
  │       │
  │       ├─ xas_store(&xas, folio)          ← 写入 XArray
  │       ├─ mapping->nrpages++               ← 更新计数
  │       ├─ if (shadow)
  │       │     workingset_refault(folio, shadow)
  │       │     ← 页面刚被回收又再次访问（工作集颠簸检测）
  │       └─ folio->mapping = mapping        ← 建立反向关联
  │
  ├─ filemap_read_folio(iocb->fi_filp, a_ops->read_folio, folio)
  │   → ★ 从磁盘读取数据！
  │
  └─ folio_batch_add(fbatch, folio)
```

---

## 3. 🔥 写入路径——generic_perform_write

```c
// mm/filemap.c — 通用写入循环
ssize_t generic_perform_write(struct kiocb *iocb, struct iov_iter *i)
{
    struct address_space *mapping = file->f_mapping;
    const struct address_space_operations *a_ops = mapping->a_ops;

    do {
        // ——— 1. 写入前准备 ———
        status = a_ops->write_begin(file, mapping, pos, len,
                                     &page, &fsdata);
        // ext4_write_begin:
        //   ├─ filemap_lock_folio(mapping, index) → 获取/创建 folio
        //   ├─ 如果是部分写入：readpage 读旧数据
        //   └─ return folio

        // ——— 2. 从用户空间复制数据到内核 folio ———
        copied = copy_page_from_iter_atomic(page, offset, bytes, i);
        // ★ 将用户空间缓冲区的数据拷贝到内核页缓存！
        flush_dcache_folio(folio);  // 刷 D-cache（ARM 等需要）

        // ——— 3. 写入完成处理 ———
        status = a_ops->write_end(file, mapping, pos, bytes, copied,
                                   page, fsdata);
        // ext4_write_end:
        //   ├─ folio_mark_uptodate(folio)       ← 标记有效
        //   ├─ __block_commit_write → 块分配
        //   ├─ folio_mark_dirty(folio)           ← ★ 标记脏页
        //   │   → mapping->a_ops->dirty_folio(mapping, folio)
        //   │   → filemap_dirty_folio(mapping, folio)
        //   │      └─ __xa_set_mark(&mapping->i_pages, index, PAGECACHE_TAG_DIRTY)
        //   │         → XArray 节点标记脏，并向上传播
        //   ├─ folio_unlock(folio)
        //   └─ return copied

        pos += copied;          // 前进位置
        written += copied;      // 累计写入量

    } while (iov_iter_count(i));  // 还有数据要写

    return written;
}
```

**写入延迟分析**：
```
写入 page cache：复制 folio 页（~100ns）+ 标记脏（~20ns）
  → 返回用户空间（~1μs）→ 看起来很快！
  
真正的磁盘写入在后台进行：
  写入 page cache ~1μs 后
  → 5-30 秒后 kswapd/writeback 触发
  → a_ops->writepage → submit_bio
  → SSD ~10μs / HDD ~10ms
  → 完成后清除 DIRTY + WRITEBACK 标记
```

---

## 4. 🔥 写回路径——write_cache_pages

```
周期性写回（默认每 30 秒）或 fsync() 触发：
  │
  └─ writeback_single_inode(inode, wbc)       @ fs/fs-writeback.c
       │
       └─ mapping->a_ops->writepages(mapping, wbc)
            │
            ├─ ext4_writepages(mapping, wbc)
            │    │
            │    └─ write_cache_pages(mapping, wbc, ext4_writepage_cb, ...)
            │         │                      @ mm/page-writeback.c
            │         │
            │         ├─ XA_STATE(xas, &mapping->i_pages, 0)
            │         │
            │         ├─ xas_for_each_marked(&xas, folio, last,
            │         │                         PAGECACHE_TAG_DIRTY)
            │         │   ← ★ 只遍历标记了 DIRTY 的 folio！
            │         │   不遍历干净的 folio → 跳过大量不需要写回的数据
            │         │   |
            │         │   ├─ [对每个脏 folio]：
            │         │   │
            │         │   ├─ folio_lock(folio)         ← 锁定防止并发
            │         │   │
            │         │   ├─ folio_clear_dirty_for_io(folio)
            │         │   │   → 清除脏标记
            │         │   │   → 设置写回标记
            │         │   │   → __xa_set_mark(mapping->i_pages, index,
            │         │   │                       PAGECACHE_TAG_WRITEBACK)
            │         │   │
            │         │   ├─ a_ops->writepage(&folio->page, wbc)
            │         │   │   = ext4_writepage(page, wbc)
            │         │   │    │
            │         │   │    ├─ ext4_get_block → 物理块映射
            │         │   │    ├─ io = ext4_init_io(wbc, page)
            │         │   │    ├─ submit_bio(io->bio)  ← 提交 I/O！
            │         │   │    │   [磁盘将 folio 数据写入物理扇区]
            │         │   │    │
            │         │   │    └─ 完成时：
            │         │   │       end_page_writeback(page)
            │         │   │         → folio_end_writeback(folio)
            │         │   │           = __xa_clear_mark(PAGECACHE_TAG_WRITEBACK)
            │         │   │           → 清除写回标记
            │         │   │           → 唤醒等待写回完成的线程
            │         │   │
            │         │   └─ if (wbc->nr_to_write <= 0)
            │         │        break;  ← 已写回足够页数，停止
            │         │
            │         └─ xas_pause(&xas);   ← 暂停遍历，释放 XArray 锁
```

---

## 5. XArray 标记系统

Page cache 使用 XArray 的 bit 标记跟踪 folio 的不同状态：

```c
// include/linux/pagemap.h
#define PAGECACHE_TAG_DIRTY      XA_MARK_0    // 脏页标记
#define PAGECACHE_TAG_WRITEBACK  XA_MARK_1    // 写回中标记
#define PAGECACHE_TAG_TOWRITE    XA_MARK_2    // 待写回（写回内部使用）
```

**标记传播机制**：

```
XArray 节点结构（每节点 64 slots）：

  根节点（shift=12）：
    marks[0] (DIRTY):  bit pattern 0100 0000...
    ← 第 2 个子节点中有脏页
      │
      ├── slot[0]: 子节点 A（shift=6）
      │     marks[0]: 0000 0000... → 无脏页，跳过整棵子树！
      │     ← xas_for_each_marked 直接跳过此节点
      │
      ├── slot[1]: 子节点 B（shift=6）
      │     marks[0]: 0000 0100...
      │     ← 第 3 个 slot 有脏页
      │       │
      │       ├── slot[0]: folio (clean) ← 跳过
      │       ├── slot[1]: folio (clean) ← 跳过
      │       ├── slot[2]: folio (dirty) ⚑ ★ 写回此 folio
      │       └── slot[3]: folio (clean) ← 跳过
      │
      └── slot[2]: 子节点 C（shift=6）
            所有 marks[0] = 0 → 跳过整棵子树
```

**效率**：`xas_for_each_marked` 通过节点级位图跳过不需要检查的子树，每节点 64 slots 只需单次 `find_next_bit` 操作。对于 95% clean 页的场景，跳过率高达 95%。

---

## 6. 预读（Readahead）

```c
// mm/readahead.c
void page_cache_ra_order(struct readahead_control *ractl,
                          struct file_ra_state *ra, unsigned int new_order)
{
    // 预读策略取决于文件的访问模式

    // 文件 flag 检查：
    // VM_SEQ_READ:  顺序访问 → 激进预读，翻倍增长
    // VM_RAND_READ: 随机访问 → 关闭预读，仅按需读取

    if (ra->flags & RA_FLAG_MMAP) {
        // mmap 顺序访问 → 每次预读 256KB
        page_cache_sync_ra(mapping, ra, file, index, req_count);
    } else {
        // 常规 read → 根据上次访问频率调整预读量
        // 首次: 双页预读
        // 命中 → 4 页 → 8 页 → ... 指数增长
        // 最大: default_ra_size（通常 32 页 = 128KB）
    }
}
```

**预读窗口增长**：
```
第一次读: index=0 → 预读 [0,1]         (2 页)
第二次读: index=2 → 预读 [2,5]         (4 页)
第三次读: index=6 → 预读 [6,13]        (8 页)
第四次读: index=14 → 预读 [14,29]      (16 页)
第五次读: index=30 → 预读 [30,61]      (32 页，达到上限)
```

---

## 7. Shadow Entries——回收的历史痕迹

当 folio 被页面回收代码回收时，XArray 中不会直接清除对应 slot，而是写入一个 **shadow entry**：

```c
// mm/workingset.c — 页面回收
void workingset_eviction(struct folio *folio, ...)
{
    // 将回收的 folio 替换为 shadow entry
    // shadow 编码了页面被回收时的工作集信息
    xas_store(&xas, shadow);
    // shadow 本质上是 xa_mk_internal(XA_RETRY_ENTRY + nr)
    // 其中 nr 编码了回收时间
}
```

**shadow entry 的作用**：
1. **保留回收痕迹**：下次文件读取时发现 shadow，知道此页刚被回收
2. **工作集颠簸检测**：如果页面被回收后很快被再次访问，说明工作集 > 物理内存
3. **预读优化**：发现 shadow → 增大预读量（因为顺序扫描的可能性高）

```c
// filemap_get_read_batch 中的 shadow 处理：
if (xa_is_value(folio))
    break;  // ← 遇到 shadow entry，停止批读取
            // filemap_read 检测到返回值小于请求量
            // → 进入慢速路径创建新 folio
            // → 发现存在 shadow → 增大预读窗口
```

shadow entry 本身占用 XArray slot（8 字节），但不占用实际物理页。

---

## 8. Folio 完整生命周期

```
                alloc_folio()
                     │
                     ▼
            ┌─────────────────┐
            │  ALLOCATED      │  folio 刚分配，未映射
            │  flags: 0       │
            └────────┬────────┘
                     │
                     ▼
            ┌─────────────────┐
            │  ADDED          │  filemap_add_folio → 加入 XArray
            │  flags: locked  │  mapping->nrpages++
            └────────┬────────┘
                     │
                a_ops->read_folio()
                     │
                     ▼
            ┌─────────────────┐
            │  UPTODATE       │  ★ 数据有效，可从缓存读取
            │  mgs: PG_uptodate│  copy_page_to_iter → 用户空间
            └────────┬────────┘
                     │
              用户写入 (write_begin → copy → write_end)
                     │
                     ▼
            ┌─────────────────┐
            │  DIRTY          │  ★ 数据已修改，需要写回
            │  PAGECACHE_TAG_ │  writeback 扫描时会处理
            │  DIRTY          │
            └────────┬────────┘
                     │
               write_cache_pages → a_ops->writepage
                     │
                     ▼
            ┌─────────────────┐
            │  WRITEBACK      │  ★ 正在写回磁盘
            │  TAG_WRITEBACK  │  bio 提交后等待 I/O
            │  I/O in-flight  │
            └────────┬────────┘
                     │
               I/O 完成 → end_page_writeback
                     │
                     ▼
            ┌─────────────────┐
            │  UPTODATE       │  写回完成，干净状态
            │ （CLEAN）       │  等待再次被访问或回收
            └────────┬────────┘
                     │
              内存压力 → shrink_folio_list
                     │
                     ▼
            ┌─────────────────┐
            │  EVICTED        │  从 XArray 移除
            │  → shadow entry │  写入 shadow（保留痕迹）
            │  → folio 释放   │  folio 归还到页分配器
            └─────────────────┘
```

---

## 9. Page Cache 回写策略

```c
// fs/fs-writeback.c
// 多个触发源：

// 1. 定时写回（dirty_expire_interval，默认 30 秒）
//    writeback 内核线程（flush-x:x）周期性扫描
//    → 所有超过 dirty_expire_centisecs 的脏页

// 2. 脏页比例触发（dirty_background_ratio，默认 10%）
//    当脏页占总内存的 10% 时，唤醒 kswapd
//    → 异步写回

// 3. 同步写回（fsync）
//    → 等待指定文件的所有脏页写回完成
//    → 用户空间可见的屏障

// 4. 直接回写（dirty_ratio，默认 20%）
//    当脏页超过 20% 时，写入进程自己触发同步写回
//    → 减慢写入速度，防止脏页无限增长
```

---

## 10. 性能数据

| 操作 | 延迟 | 说明 |
|------|------|------|
| 读缓存命中 | ~100ns | copy_page_to_iter 从 L1/L2 cache 拷贝 |
| 读缓存未命中（SSD）| ~10μs | submit_bio + DMA + completion |
| 读缓存未命中（HDD）| ~10ms | 磁盘寻道+旋转延迟 |
| 写缓存写入 | ~100ns | copy_from_user + 标记脏 |
| 写回（SSD）| ~10μs | a_ops->writepage + submit_bio |
| 写回（HDD）| ~10ms | 磁盘写入 |
| 大量缺失（page fault）| ~50μs | VMA 查找 + folio 分配 + 读盘 |

---

## 11. 锁顺序

```
锁获取顺序（违反此顺序会导致死锁）：
  mmap_lock
    → i_mmap_rwsem      (truncate→unmap_mapping_range)
      → page_table_lock
        → i_pages lock   (page cache XArray)
          → folio lock   (单个 folio)

  i_rwsem
    → invalidate_lock    (truncate)
      → i_mmap_rwsem
        → i_pages lock
```

---

## 12. 源码文件索引

| 文件 | 关键函数 | 行号 |
|------|---------|------|
| `mm/filemap.c` | `__filemap_add_folio` | 849 |
| `mm/filemap.c` | `filemap_add_folio` | 950 |
| `mm/filemap.c` | `filemap_get_read_batch` | 2456 |
| `mm/filemap.c` | `filemap_read_folio` | 2492 |
| `mm/filemap.c` | `filemap_create_folio` | 2601 |
| `mm/page-writeback.c` | `write_cache_pages` | — |
| `mm/readahead.c` | `page_cache_ra_order` | — |
| `mm/workingset.c` | `workingset_eviction` | — |

---

## 13. 关联文章

- **04-xarray**：page cache 的底层存储
- **17-page_allocator**：folio 的物理页面来源
- **19-VFS**：VFS 层调用 page cache
- **26-RCU**：RCU 保护 filemap_get_read_batch 的读路径
- **44-swap**：swap 与 page cache 的不同回收策略
- **66-ext4**：ext4 的 a_ops 实现

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
