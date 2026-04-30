# Linux Kernel Page Cache 与 Filemap 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/filemap.c` + `include/linux/fs.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 Page Cache？

**Page Cache** 是内核的文件数据缓存——将磁盘块映射到内存页，减少磁盘 I/O。

**核心思想**：
- 读文件：优先从 page cache 读取，cache miss 时从磁盘加载
- 写文件：写入 page cache，异步批量写回磁盘（writeback）
- 同一文件被多进程共享时，page cache 只有一份

---

## 1. address_space — 文件到页的映射

```c
// include/linux/fs.h:473 — address_space
struct address_space {
    struct inode           *host;           // 关联的 inode
    struct radix_tree_root page_tree;      // 页缓存核心：radix_tree
    spinlock_t            i_pages_lock;    // 保护 page_tree

    /* 写回控制 */
    struct wb_domain       *wb_domain;
    struct percpu_counter  nrpages;         // 缓存页数
    unsigned int           i_aio_job_size;

    /* 写回链表 */
    struct list_head       private_list;    // 用于 buffer_head 写回
    struct address_space   **private_data;

    /* 脏页追踪 */
    struct radix_tree_root  i_pages;       // GFPS 树
    unsigned long           nrpages;       // 缓存页数

    /* 操作函数表 */
    const struct address_space_operations *a_ops;
};

// address_space_operations（文件系统的页 I/O 实现）
struct address_space_operations {
    // 读取文件页到 cache
    int  (*read_folio)(struct file *, struct folio *);

    // 写回脏页
    int  (*write_begin)(struct file *, struct address_space *,
                loff_t pos, unsigned len,
                struct page **pagep, void **fsdata);
    int  (*write_end)(struct file *, struct address_space *,
                loff_t pos, unsigned copied,
                struct page *page, void *fsdata);

    // 直接 I/O
    int  (*direct_IO)(struct kiocb *, struct iov_iter *);

    // 写回
    int  (*writepages)(struct address_space *, struct writeback_control *);
    int  (*set_page_dirty)(struct page *);
    int  (*readahead)(struct readahead_control *);
};
```

---

## 2. filemap_fault — Page Fault 读文件

```c
// mm/filemap.c — filemap_fault（读文件页到 cache）
vm_fault_t filemap_fault(struct vm_fault *vmf)
{
    struct file *file = vmf->vma->vm_file;
    struct address_space *mapping = file->f_mapping;
    struct inode *inode = mapping->host;
    struct page *page;
    vm_fault_t ret;

    // 1. 查找 page cache 中是否有该页
    page = find_get_page(mapping, offset);
    if (likely(page && !PageError(page))) {
        // cache hit！
        page = __lock_page(page);  // 页被其他进程正在读，加锁
        goto out;
    }

    // 2. cache miss：分配新页
    if (!page) {
        page = page_cache_alloc(mapping);
        if (!page)
            return VM_FAULT_OOM;
    }

    // 3. 从磁盘读取（通过文件系统）
    ret = mapping->a_ops->read_folio(file, folio);
    if (ret) {
        // I/O 错误
        unlock_page(page);
        return VM_FAULT_SIGBUS;
    }

out:
    // 4. COW 处理（如果是写时复制）
    ret = do_async_mkwrite;

    // 5. 更新 PTE，映射到缓存页
    vmf->page = page;
    return VM_FAULT_LOCKED;  // 页已加锁
}
```

---

## 3. find_get_page — 缓存查找

```c
// mm/filemap.c — find_get_page
struct page *find_get_page(struct address_space *mapping, pgoff_t offset)
{
    // radix_tree_lookup 查找
    // page = radix_tree_lookup(&mapping->page_tree, offset);

    // 如果找到，增加引用计数
    // get_page(page);

    return page;
}

// mm/filemap.c — page_cache_alloc
struct page *page_cache_alloc(struct address_space *mapping)
{
    // alloc_pages(__GFP_COLD, 0)  // COLD = 不使用 per-CPU 缓存
    // 返回的页加入 page cache
}
```

---

## 4. write_begin / write_end — 写文件

```c
// mm/filemap.c — generic_perform_write（写流程）
ssize_t generic_perform_write(struct file *file,
                  struct iov_iter *i, loff_t pos)
{
    struct address_space *mapping = file->f_mapping;
    ssize_t written = 0;

    do {
        struct page *page;
        void *fsdata;
        unsigned offset = pos & (PAGE_SIZE - 1);
        unsigned bytes = min_t(size_t, PAGE_SIZE - offset, count);

        // 1. 获取要写的页（不存在则分配）
        status = a_ops->write_begin(file, mapping, pos, bytes,
                        &page, &fsdata);
        if (status)
            break;

        // 2. 从用户空间复制数据到页
        copy_page_from_iter(page, offset, bytes, i);

        // 3. 完成写入
        status = a_ops->write_end(file, mapping, pos, bytes,
                      copied, page, fsdata);

        pos += bytes;
        written += bytes;

        // 4. 如果页变脏，加入写回链表
        if (PageDirty(page))
            account_page_dirtied(page, mapping);
        unlock_page(page);
        put_page(page);

    } while (count);

    return written;
}

// ext4 写流程：
// write_begin → ext4_da_write_begin → grab_cache_folio_write_begin
// write_end   → ext4_da_write_end   → ext4_ess_extent_write_end
```

---

## 5. SetPageDirty 与 Writeback

```c
// mm/page-writeback.c — write_cache_pages
int write_cache_pages(struct address_space *mapping, ...)
{
    // 遍历 mapping->page_tree 中的所有脏页
    // 调用 a_ops->writepage() 写回每个脏页

    // writepage → block_write_full_page (ext4) / filemap_write_page
}
```

---

## 6. 完整读文件流程

```
read("/foo/bar", buf, 100);

用户空间 → VFS → 文件系统 → 页缓存

步骤：
1. sys_read() → ksys_read()
2. vfs_read() → file->f_op->read_iter()
3. ext4_file_read_iter() → generic_file_read_iter()
4. generic_perform_read() → filemap_read()
5. filemap_read():
   a. find_get_page(mapping, offset)  ← cache hit?
   b. 如果 miss：
      - page_cache_alloc() → 分配新页
      - ext4_read_folio() → 从磁盘读取
      - lock_page() → 加锁
   c. copy_page_to_iter() → 复制数据到用户空间
6. unlock_page() → put_page()

同一文件第二次读：
  - 直接 find_get_page() → cache hit
  - 无磁盘 I/O
```

---

## 7. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| address_space 用 radix_tree 组织页 | O(1) 按文件偏移查找页 |
| 页缓存一致性问题用 `i_pages_lock` | 保护 radix_tree 的并发修改 |
| write_begin/write_end 分离 | 支持日志文件系统（ext4）的两阶段提交 |
| 脏页异步写回 | 合并写、减少磁盘 I/O |
| page_cache_alloc 用 `__GFP_COLD` | 读入的页短期不用，放在冷端优先回收 |

---

## 8. 参考

| 文件 | 内容 |
|------|------|
| `mm/filemap.c` | `filemap_fault`、`find_get_page`、`generic_perform_write` |
| `include/linux/fs.h:473` | `struct address_space` |
| `mm/page-writeback.c` | `write_cache_pages`、`account_page_dirtied` |
