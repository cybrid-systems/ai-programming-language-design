# 20-page_cache — 页缓存深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**页缓存（page cache）** 是 Linux 内核中文件系统性能的核心。它将磁盘上的文件数据缓存在物理内存中，避免每次读写都触发磁盘 I/O。

page cache 的本质：**通过 `address_space` 将文件偏移量（索引）映射到物理内存页（`struct page*`）**。文件 read 优先从 page cache 中查找，只有未命中时才从磁盘读取。

doom-lsp 确认 `include/linux/pagemap.h` 和 `mm/filemap.c` 是 page cache 的核心实现，共包含 500+ 个符号。

---

## 1. 核心数据结构

### 1.1 struct address_space——page cache 的核心

```c
struct address_space {
    struct inode            *host;        // 所属的 inode
    struct xarray           i_pages;      // 页缓存的核心：页的 XArray 索引
    struct rb_root_cached   i_mmap;       // 共享映射的 VMA 红黑树
    unsigned long           nrpages;      // 缓存页总数

    struct address_space_operations *a_ops; // 页面操作回调

    unsigned long           flags;        // AS_* 标志

    spinlock_t              i_pages_lock; // 保护 i_pages
    ...
};
```

`i_pages` 是 page cache 的核心——一个 XArray，以文件页偏移为索引，存储 `struct page*`。

### 1.2 struct address_space_operations

```c
struct address_space_operations {
    int (*writepage)(struct page *page, struct writeback_control *wbc);
    int (*readpage)(struct file *file, struct page *page);
    int (*writepages)(struct address_space *, struct writeback_control *);
    int (*readahead)(struct readahead_control *);
    int (*write_begin)(struct file *, struct address_space *, ...);
    int (*write_end)(struct file *, struct address_space *, ...);
    void (*invalidatepage)(struct page *, unsigned int, unsigned int);
    int (*releasepage)(struct page *, gfp_t);
    ...
};
```

每个文件系统实现这些回调来支持 page cache。

---

## 2. 读路径

### 2.1 filemap_read——通用文件读取

```
filemap_read(file, iov_iter, bytes)
  │
  ├─ 循环读取：
  │    │
  │    ├─ 获取要读取的页范围（start, end）
  │    │
  │    ├─ [命中] find_get_page(mapping, index)
  │    │    │
  │    │    ├─ xa_load(&mapping->i_pages, index) ← XArray 查找
  │    │    │
  │    │    ├─ 如果找到 → page_cache_get() → 增加引用
  │    │    └─ 如果未命中 → goto 缺页
  │    │
  │    ├─ [缺页] page_cache_sync_readahead()
  │    │    │
  │    │    ├─ 触发预读（readahead）
  │    │    │
  │    │    └─ a_ops->readpage(file, page) ← 文件系统从磁盘读
  │    │
  │    ├─ [复制] copy_page_to_iter(page, offset, bytes, iter)
  │    │    └─ 将页内容复制到用户空间缓冲区
  │    │
  │    ├─ mark_page_accessed(page)           ← 标记访问（影响 LRU）
  │    │
  │    └─ 继续读取下一页，直到 bytes 读完
```

---

## 3. 写路径

### 3.1 通用文件写入（带缓写的 write-back）

```
filemap_write(file, iov_iter, bytes)
  │
  ├─ [写入缓存] iomap_write_iter / generic_perform_write
  │    │
  │    ├─ grab_cache_page_write_begin(mapping, index)
  │    │    │
  │    │    ├─ 在 page cache 中查找或创建页
  │    │    │    └─ pagecache_get_page(mapping, index, FGP_LOCK|FGP_WRITE|FGP_CREAT)
  │    │    │         └─ __page_cache_alloc(gfp) → 分配新页
  │    │    │         └─ add_to_page_cache_lru(page, mapping, index) → 加入 XArray + LRU
  │    │    │
  │    │    └─ return locked page
  │    │
  │    ├─ a_ops->write_begin(file, mapping, pos, len, &page, &fsdata)
  │    │    └─ 文件系统准备写入（如 ext4 预留块）
  │    │
  │    ├─ iov_iter_copy_from_user_atomic(page, iov_iter, offset, copied)
  │    │    └─ 从用户空间复制数据到页缓存
  │    │
  │    ├─ a_ops->write_end(file, mapping, pos, len, copied, page, fsdata)
  │    │    └─ 文件系统处理脏页
  │    │
  │    └─ page_cache_release(page)           ← 释放临时引用
  │
  └─ [回写] 脏页在稍后由 writeback 机制写入磁盘
       └─ bdi_writeback → wb_workfn → writeback_sb_inodes
            └─ a_ops->writepage(page, wbc)    ← 文件系统写回磁盘
```

---

## 4. 预读（Read Ahead）

预读是 page cache 性能的关键优化——检测顺序读取模式，提前加载后续页面：

```
顺序读取检测：
  │
  ├─ file->f_ra (struct file_ra_state) 记录读模式
  │    ├─ start        ← 当前预读起始
  │    ├─ size         ← 预读窗口大小
  │    ├─ async_size   ← 异步预读触发阈值
  │    └─ prev_pos     ← 上次读取位置
  │
  ├─ 当前请求:
  │    └─ 如果 prev_pos + 1 == 当前页 → 顺序读
  │
  ├─ 触发预读:
  │    └─ page_cache_sync_readahead(mapping, ra, filp, index, req_count)
  │         ├─ ondemand_readahead(ra, mapping, filp, index, req_count)
  │         │    ├─ 顺序检测：
  │         │    │    └─ try_context_readahead() → 检查是否顺序
  │         │    │
  │         │    ├─ 初始读（首次）→ 先读 4KB（1 页）
  │         │    ├─ 顺序读模式 → 窗口加倍（2, 4, 8, 16... 直到上限）
  │         │    └─ 随机读 → 不预读
  │         │
  │         └─ ra_submit(ra, mapping, filp)
  │              └─ __do_page_cache_readahead()
  │                   ├─ 分配 n 页
  │                   ├─ add_to_page_cache_lru()
  │                   └─ a_ops->readpage() 批量提交
```

---

## 5. 回写（Writeback）

脏页不会立即写入磁盘，而是通过 writeback 机制异步回写：

```
脏页产生：
  write_end() 标记页面为脏
  └─ set_page_dirty(page)
       └─ __set_page_dirty_nobuffers()
            └─ xa_lock_irqsave(&mapping->i_pages_lock)
            └─ __xa_set_mark(&mapping->i_pages, index, PAGECACHE_TAG_DIRTY)
            └─ xa_unlock_irqrestore(...)

writeback 触发：
  ┌─────────────────────────────────────┐
  │ 定时器（dirty_expire_interval）      │→ 唤醒 flusher 线程
  │ 脏页比例超限（dirty_background_ratio）│→ 唤醒 flusher 线程
  │ 直接 reclaim 遇到脏页               │→ 同步回写
  └─────────────────────────────────────┘
```

---

## 6. 数据类型流

```
读文件：
  read(fd, buf, 4096)
    → filemap_read()
      → find_get_page(mapping, index)    ← XArray 查找索引页
        → 命中: copy_page_to_iter()
        → 未命中: a_ops->readpage(page)  ← 磁盘 I/O
          → mark_page_accessed()         ← LRU 管理

写文件：
  write(fd, buf, 4096)
    → generic_perform_write()
      → grab_cache_page_write_begin()     ← 分配/获取页
      → iov_iter_copy_from_user_atomic()  ← 复制数据
      → a_ops->write_end()               ← 标记脏页
    → 稍后回写:
      → a_ops->writepage()               ← 写入磁盘
```

---

## 7. 设计决策总结

| 决策 | 原因 |
|------|------|
| XArray 索引页缓存 | O(log n) 查找，支持标记系统 |
| write-back（延迟写） | 合并多次小写入，减少磁盘 I/O |
| 预读（readahead） | 隐藏磁盘延迟，提升顺序读性能 |
| 脏页标记（XA_MARK_0） | 快速查找需要回写的页 |
| LRU 管理 | 内存压力下回收最近最少使用的页 |

---

## 8. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/pagemap.h` | 页缓存 API | 声明 |
| `include/linux/fs.h` | `struct address_space` | 核心结构 |
| `mm/filemap.c` | `filemap_read` / `filemap_write` | 读写入口 |
| `mm/filemap.c` | `find_get_page` / `pagecache_get_page` | 查找/获取页 |
| `mm/readahead.c` | `ondemand_readahead` | 预读算法 |

---

## 9. 关联文章

- **VFS**（article 19）：VFS 的读写操作通过 page cache 实现
- **XArray**（article 04）：page cache 使用 XArray 作为底层存储
- **writeback**（article 159）：脏页回写机制

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
