# page cache / filemap — 页缓存深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/filemap.c` + `include/linux/pagemap.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**page cache** 是内核的**磁盘文件缓存**，通过 VFS 的 `address_space` 实现，将磁盘块映射到内存页。

---

## 1. 核心数据结构

### 1.1 address_space — 文件页缓存

```c
// include/linux/fs.h — address_space
struct address_space {
    struct inode           *host;              // 所属 inode
    struct xarray          i_pages;           // 页缓存（XArray）
    unsigned long          nrpages;           // 缓存页数
    pgoff_t                find_get_entry_idx; // 查找缓存
    const struct address_space_operations *a_ops; // 操作函数表
    // ...
};
```

### 1.2 address_space_operations

```c
// include/linux/fs.h — address_space_operations
struct address_space_operations {
    int (*writepage)(struct page *, struct writeback_control *);
    int (*readpage)(struct file *, struct page *);
    int (*readahead)(struct file *, struct page *);
    int (*writepages)(struct address_space *, struct writeback_control *);
    int (*set_page_dirty)(struct page *);
    // ...
};
```

---

## 2. 读文件流程

### 2.1 generic_file_read_iter

```c
// mm/filemap.c — generic_file_read_iter
ssize_t generic_file_read_iter(struct kiocb *iocb, struct iov_iter *iter)
{
    // 1. 检查缓存
    //    page = find_get_entry(mapping, index);
    //    if (page) → 页已在缓存
    //    else → 页不在缓存，需要读取

    // 2. 读取磁盘
    page = read_cache_page(mapping, index, filler, NULL);

    // 3. 复制到用户空间
    copy_page_to_iter(page, offset, bytes, iter);
}
```

### 2.2 read_cache_page — 读取页到缓存

```c
// mm/filemap.c — read_cache_page
struct page *read_cache_page(struct address_space *mapping,
                pgoff_t index,
                int (*filler)(void *, struct page *),
                void *data)
{
    // 1. 查找缓存页
    page = find_get_entry(mapping, index);
    if (page)
        return page;

    // 2. 分配新页
    page = page_cache_alloc(mapping);

    // 3. 添加到缓存
    add_to_page_cache_lru(page, mapping, index, GFP_KERNEL);

    // 4. 读取磁盘内容
    filler(data, page);

    return page;
}
```

---

## 3. 写文件流程

### 3.1 generic_perform_write

```c
// mm/filemap.c — generic_perform_write
ssize_t generic_perform_write(struct file *file,
                struct iov_iter *iter, loff_t pos)
{
    // 1. 按页对齐写入
    // 2. 调用 ->writepage() 或 ->writepages()
    // 3. 更新 i_size
}
```

---

## 4. 页缓存查找

### 4.1 find_get_entry

```c
// mm/filemap.c — find_get_entry
struct page *find_get_entry(struct address_space *mapping, pgoff_t index)
{
    // XArray 查找
    page = xa_load(&mapping->i_pages, index);
    if (page && likely(!PageError(page)))
        return page;

    return NULL;
}
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/fs.h` | `struct address_space`、`struct address_space_operations` |
| `mm/filemap.c` | `generic_file_read_iter`、`read_cache_page`、`find_get_entry` |
