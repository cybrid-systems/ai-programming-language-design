# 20-page-cache — Linux 内核页缓存深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**Page Cache（页缓存）** 是 Linux 内核文件 I/O 的核心缓存机制。它将磁盘上的文件数据缓存在物理内存中，使得后续读写操作可以在内存中完成，避免慢速的磁盘 I/O。

page cache 的核心思想：文件被分成固定大小的页（通常 4KB），按文件的页偏移索引，存储在 XArray（`struct address_space.i_pages`）中。每个页缓存条目是一个 `struct folio`（新内核中替代 `struct page` 的复合页抽象）。

**doom-lsp 确认**：page cache 的核心实现在 `mm/filemap.c`。关键函数包括 `filemap_read`、`filemap_get_pages`、`filemap_map_pages`、`filemap_write_and_wait` 等。

---

## 1. 核心数据结构

### 1.1 `struct address_space`——页缓存的容器

```c
// include/linux/fs.h
struct address_space {
    struct xarray           i_pages;        // XArray：页偏移 → folio 映射
    struct rw_semaphore     i_mmap_rwsem;   // VMA 区间树保护锁
    struct rb_root_cached   i_mmap;         // 映射此文件的 VMA 区间树
    unsigned long           nrpages;        // 缓存页数量
    unsigned long           writeback_index; // 写回起始索引
    const struct address_space_operations *a_ops; // 地址空间操作表
    // ...
};
```

**关键设计**：一个文件（inode）只有一个 `address_space`。所有页缓存条目（folio）共享同一个 XArray，按文件页偏移索引。

### 1.2 `struct address_space_operations`——页缓存操作表

```c
struct address_space_operations {
    int (*writepage)(struct page *page, struct writeback_control *wbc);
    int (*read_folio)(struct file *, struct folio *);    // 从磁盘读数据
    void (*readahead)(struct readahead_control *);        // 预读
    int (*write_begin)(struct file *, struct address_space *, // 写开始
                       loff_t pos, unsigned len,
                       struct page **pagep, void **fsdata);
    int (*write_end)(struct file *, struct address_space *,  // 写结束
                     loff_t pos, unsigned len, unsigned copied,
                     struct page *page, void *fsdata);
    void (*invalidate_folio)(struct folio *, size_t start, size_t len); // 失效
    bool (*dirty_folio)(struct address_space *, struct folio *);        // 标记脏
    int (*migrate_folio)(struct address_space *, struct folio *, enum migrate_mode); // 迁移
    // ...
};
```

各文件系统实现自己的 `a_ops`：

```c
const struct address_space_operations ext4_aops = {
    .read_folio     = ext4_read_folio,
    .readahead      = ext4_readahead,
    .write_begin    = ext4_write_begin,
    .write_end      = ext4_write_end,
    .dirty_folio    = filemap_dirty_folio,
    .migrate_folio  = filemap_migrate_folio,
    // ...
};
```

### 1.3 `struct folio`——页缓存的存储单元

内核 6.x 引入了 `struct folio` 替代 `struct page` 作为页缓存的基本单元。folio 可以是一个单页（`PAGE_SIZE`）或复合页（2MB THP）：

```c
struct folio {
    struct page page;           // 嵌入 page 结构
    // folio 专用字段直接在 page 的 union 中编码
};
```

folio 的关键状态：
- **`folio_test_uptodate(folio)`**：数据已从磁盘读取完毕
- **`folio_test_dirty(folio)`**：数据已被修改，需要写回
- **`folio_test_locked(folio)`**：正在被 I/O 操作
- **`folio_test_writeback(folio)`**：正在写回磁盘

---

## 2. 🔥 读取路径——filemap_read

```
read(fd, buf, count) → sys_read → vfs_read
  │
  └─ filemap_read(file, iter, &pos)              @ mm/filemap.c
       │
       ├─ 循环直到读取够 count 字节：
       │    │
       │    ├─ filemap_get_pages(kiocb, iter, &folio_batch)
       │    │    │
       │    │    └─ filemap_get_read_batch(mapping, index, ...)
       │    │         │
       │    │         ├─ XA_STATE(xas, &mapping->i_pages, index)
       │    │         ├─ xas_for_each(&xas, folio, ...) {
       │    │         │      if (xas_retry(&xas, folio))
       │    │         │          continue;           ← 重试（RCU 保护）
       │    │         │
       │    │         │      if (xa_is_value(folio)) {
       │    │         │          // shadow entry：页面刚刚被回收
       │    │         │          // 下次预读更大范围
       │    │         │      }
       │    │         │
       │    │         │      if (folio_test_uptodate(folio))
       │    │         │          folio_batch_add(batch, folio);  ← 命中缓存！
       │    │         │  }
       │    │         │
       │    │         └─ 如果缓存未命中（folio 不在 XArray 中）：
       │    │              filemap_alloc_folio(file, gfp)  ← 分配 folio
       │    │              filemap_create_folio(file, mapping, index) ← 创建映射
       │    │                 │
       │    │                 ├─ folio = filemap_alloc_folio()
       │    │                 ├─ filemap_add_folio(mapping, folio, index, gfp)
       │    │                 │   └─ xa_store(&mapping->i_pages, index, folio, gfp)
       │    │                 │      → 将 folio 加入 XArray
       │    │                 │
       │    │                 ├─ mapping->a_ops->read_folio(file, folio)
       │    │                 │   ← ext4_read_folio: 从磁盘读入数据
       │    │                 │      └─ submit_bio: 向块设备提交 I/O
       │    │                 │
       │    │                 └─ folio 变为 uptodate
       │    │
       │    ├─ 从 folio 复制数据到用户空间：
       │    │   copy_page_to_iter(folio, offset, bytes, iter)
       │    │   ← 将内核页缓存中的数据拷贝到用户空间缓冲区
       │    │
       │    ├─ 更新统计
       │    │
       │    └─ 如果文件被另一个进程截断或删除：
       │        mapping->nrpages 变化 → 重新检查
       │
       └─ return bytes_read / 错误
```

---

## 3. 🔥 写入路径——generic_perform_write

```
write(fd, buf, count) → sys_write → vfs_write
  │
  └─ generic_perform_write(iocb, iov_iter)
       │
       └─ 循环写入数据：
            │
            ├─ a_ops->write_begin(file, mapping, pos, len, &page, &fsdata)
            │    ← ext4_write_begin:
            │       ├─ filemap_lock_folio(mapping, index)
            │       │   → 在 XArray 中查找/创建 folio
            │       │   → 如果不在缓存中：分配新 folio
            │       │   → 如果 folio 是磁盘上的旧数据：
            │       │     → ext4_get_block + 读取原有数据
            │       ├─ folio_wait_writeback(folio)  ← 等待写回完成
            │       └─ return
            │
            ├─ iov_iter_copy_from_user_atomic(page, iter, offset, len)
            │   ← 从用户空间拷贝数据到 folio！
            │
            ├─ a_ops->write_end(file, mapping, pos, len, copied, page, fsdata)
            │    ← ext4_write_end:
            │       ├─ folio_mark_uptodate(folio)    ← 数据有效
            │       ├─ folio_mark_dirty(folio)        ← 标记脏页
            │       │   → mapping->a_ops->dirty_folio(mapping, folio)
            │       │   → __xa_set_mark(&mapping->i_pages, PAGECACHE_TAG_DIRTY)
            │       │   → 在 XArray 中设置 DIRTY 标记
            │       ├─ __block_commit_write → 块分配
            │       └─ folio_unlock(folio)
            │
            └─ pos += copied; 继续循环
```

---

## 4. 写回路径——writeback

```
周期性写回（如每 30 秒）或主动 fsync()：
  │
  └─ writeback_single_inode(inode, wbc)
       │
       ├─ write_cache_pages(mapping, wbc)
       │    │
       │    └─ XA_STATE(xas, &mapping->i_pages, 0)
       │       xas_for_each_marked(&xas, folio, last, PAGECACHE_TAG_DIRTY)
       │       ← 只遍历 DIRTY 标记的 folio！
       │         │
       │         ├─ folio_lock(folio)
       │         ├─ clear_page_dirty_for_io(folio)
       │         ├─ mapping->a_ops->writepage(&folio->page, wbc)
       │         │   ← ext4_writepage: 写入磁盘
       │         │      ├─ ext4_get_block → 物理块映射
       │         │      ├─ submit_bio → 提交 I/O
       │         │      └─ 完成时：
       │         │           end_page_writeback(folio)
       │         │           ← 清除 WRITEBACK 标记
       │         │           ← __xa_clear_mark(PAGECACHE_TAG_WRITEBACK)
       │         │
       │         └─ if (wbc->nr_to_write <= 0) break
       │
       └─ 更新 inode 时间戳等
```

---

## 5. 标记系统

Page cache 使用 XArray 的标记系统跟踪不同状态的 folio：

```c
// include/linux/pagemap.h
#define PAGECACHE_TAG_DIRTY      XA_MARK_0    // 脏页
#define PAGECACHE_TAG_WRITEBACK  XA_MARK_1    // 写回中
#define PAGECACHE_TAG_TOWRITE    XA_MARK_2    // 待写回（writeback 内部用）
```

**标记传播**：标记在 XArray 节点中从叶子向上传播。如果一个节点中任何子节点有 DIRTY 标记，该节点也被标记。这使得 `xas_for_each_marked` 可以跳过不需要处理的大量子树：

```
XArray 节点结构：
  根节点
  ├── slot[0]: 节点 A（有 DIRTY ⚑，因为子节点有脏页）
  │   ├── slot[0]: folio_1 (dirty) ↑
  │   ├── slot[1]: folio_2 (clean)
  │   └── slot[2]: 节点 B（无 DIRTY）
  │       └── ... 全部 clean
  │
  ├── slot[1]: 节点 C（无 DIRTY）
  │   └── ... 全部 clean ← 整棵子树被跳过！
```

---

## 6. 预读（readahead）

```c
// mm/readahead.c
void page_cache_readahead_unbounded(struct address_space *mapping, ...)
{
    // 根据顺序访问模式预测下次需要的页面范围
    // 一次性提交多个 read_folio 请求
    
    for (i = 0; i < nr_to_read; i++) {
        filemap_create_folio(mapping, index + i);  // 创建多个 folio
    }

    // 使用批量 BIO 提交 → 磁盘可以合并 I/O
    // → 减少寻道时间 → 提高吞吐量
}
```

预读策略：
- **顺序读**：`VM_SEQ_READ` → 激进预读（最多 256KB）
- **随机读**：`VM_RAND_READ` → 关闭预读
- **首次访问**：双页预读 → 4 页 → 8 页 → ... 指数增长

---

## 7. shadow entries——保留回收痕迹

当 folio 被回收（页面回收机制），XArray 中不会直接清空 slot，而是写入一个 **shadow entry**：

```c
#define SHADOW_ENTRY   xa_mk_internal(258)  // 表示"这里曾有页面"

// page cache 删除时：
if (shadow) {
    xa_store(&mapping->i_pages, index, shadow, GFP_NOWAIT);
    // 保留 shadow 而非清除
}

// 下次读取时发现 shadow：
// → 此页刚被回收 → 预读更多页（因可能正在顺序扫描）
// → 而不是一次性触发大量缺页
```

---

## 8. 完整生命周期

```
1. 首次读: 未命中缓存
   ├─ filemap_create_folio: 分配 folio
   ├─ xa_store: 加入 XArray + 标记分配
   └─ a_ops->read_folio: 从磁盘读数据 → folio_uptodate

2. 再次读: 命中缓存
   ├─ xa_load: 直接从 XArray 获取 folio
   └─ copy_page_to_iter: 拷贝到用户空间
       → 无磁盘 I/O！

3. 写入: 
   ├─ a_ops->write_begin: 获取/创建 folio
   ├─ copy_from_user: 写入 folio
   └─ a_ops->write_end: folio_mark_dirty + PAGECACHE_TAG_DIRTY

4. 写回:
   ├─ xas_for_each_marked(PAGECACHE_TAG_DIRTY)
   ├─ a_ops->writepage: 写入磁盘
   └─ clear_page_dirty: 清除 DIRTY

5. 回收: 
   ├─ folio 从 XArray 中移除
   ├─ 写入 shadow entry（保留回收痕迹）
   └─ folio 被释放
```

---

## 9. 源码文件索引

| 文件 | 内容 | 关键函数 |
|------|------|---------|
| `mm/filemap.c` | page cache 核心 | `filemap_read`, `filemap_get_pages` |
| `mm/readahead.c` | 预读 | `page_cache_readahead_unbounded` |
| `mm/page-writeback.c` | 写回路径 | `write_cache_pages` |
| `include/linux/pagemap.h` | page cache API | — |

---

## 10. 关联文章

- **04-xarray**：page cache 的底层存储结构
- **17-page_allocator**：页面分配为 page cache 提供 folio
- **19-vfs**：VFS 层调用 page cache 完成 I/O
- **44-swap**：swap 机制与 page cache 的不同
- **66-ext4**：ext4 的 a_ops 实现

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
