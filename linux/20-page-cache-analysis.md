# 20-page_cache — 页缓存深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/filemap.c` + `include/linux/fs.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**page_cache** 是 Linux 内核的磁盘文件缓存：将磁盘块缓存在内存页中，加速文件读写。核心是 **address_space**（文件到页的映射），使用 **XArray** 存储页帧。

---

## 1. 核心数据结构

### 1.1 struct address_space — 地址空间

```c
// include/linux/fs.h — address_space
struct address_space {
    struct inode           *host;              // 关联的 inode
    struct xarray          i_pages;            // 页缓存（XArray）
    //   索引 = 文件内页偏移（page_index）
    //   值 = struct page*

    // 写回
    struct radix_tree_root  i_pages;             // XArray 替代了 radix_tree
    struct writeback_control *i_wb;           // 写回控制
    spinlock_t              i_size_lock;       // 保护 i_size

    // 统计
    atomic_t                truncate_count;      // 截断计数
    unsigned long           nrpages;            // 缓存页数
};
```

### 1.2 struct page — 页帧

```c
// include/linux/mm_types.h — page（缓存相关字段）
struct page {
    // 缓存状态
    struct {
        struct address_space *mapping;   // 所属 address_space（NULL = 匿名页）
        pgoff_t            index;         // 在文件内的页偏移
    };

    // 状态标志
    unsigned long          flags;         // PG_locked / PG_uptodate / ...

    // LRU（最近最少使用）链表
    struct list_head        lru;           // 接入 inode 或 swap 的 LRU

    // 页引用
    atomic_t                _refcount;     // 引用计数
};
```

---

## 2. 页缓存查找

### 2.1 find_get_entry — 查找页

```c
// mm/filemap.c — find_get_entry
struct page *find_get_entry(struct address_space *mapping, pgoff_t index)
{
    // 1. 从 XArray 查找
    struct page *page;
    page = xa_load(&mapping->i_pages, index);

    if (page && !IS_ERR(page)) {
        // 增加页引用
        get_page(page);
        return page;
    }

    return NULL;  // 未缓存
}
```

### 2.2 find_get_entries — 批量查找

```c
// mm/filemap.c — find_get_entries
unsigned find_get_entries(struct address_space *mapping, pgoff_t start,
                          unsigned int nr_entries, struct page **entries)
{
    // 从 XArray 批量查找
    // 返回指向 nr_entries 个页的指针数组
    return find_get_entries(mapping, start, nr_entries, entries);
}
```

---

## 3. 页缓存插入

### 3.1 add_to_page_cache — 添加页到缓存

```c
// mm/filemap.c — add_to_page_cache
int add_to_page_cache(struct page *page, struct address_space *mapping,
                      pgoff_t index, gfp_t gfp)
{
    int error;

    // 1. 设置 page 的 mapping 和 index
    page->mapping = mapping;
    page->index = index;

    // 2. 加入 XArray
    error = xa_insert(&mapping->i_pages, index, page, gfp);
    if (error)
        goto err;

    // 3. 更新统计
    mapping->nrpages++;

    return 0;

err:
    page->mapping = NULL;
    return error;
}
```

---

## 4. read_cache_page — 读取一页

### 4.1 read_cache_page — 读文件页

```c
// mm/filemap.c — read_cache_page
struct page *read_cache_page(struct address_space *mapping,
                            pgoff_t index,
                            int (*filler)(void *, struct page *),
                            void *data)
{
    struct page *page;

    // 1. 查找缓存
    page = find_get_entry(mapping, index);
    if (page)
        return page;

    // 2. 分配新页
    page = page_cache_alloc(mapping);
    if (!page)
        return ERR_PTR(-ENOMEM);

    // 3. 从磁盘读取
    error = filler(data, page);
    if (error)
        goto err;

    // 4. 加入缓存
    error = add_to_page_cache(page, mapping, index, GFP_KERNEL);
    if (error)
        goto err;

    return page;

err:
    put_page(page);
    return ERR_PTR(error);
}
```

---

## 5. 写回机制

### 5.1 filemap_fdatawrite — 写回脏页

```c
// mm/filemap.c — filemap_fdatawrite
int filemap_fdatawrite(struct address_space *mapping)
{
    // 遍历所有脏页，写回到磁盘
    // 使用 i_pages 的 XArray 迭代

    return xa_for_each_range(&mapping->i_pages, index, page) {
        if (PageDirty(page))
            writepage(page, wbc, NULL);
    }
}
```

### 5.2 writepage — 单页写回

```c
// mm/filemap.c — writepage
int writepage(struct page *page, struct writeback_control *wbc, void *data)
{
    struct address_space *mapping = page->mapping;
    struct inode *inode = mapping->host;

    // 调用文件系统的写回函数
    if (mapping->a_ops->writepage)
        return mapping->a_ops->writepage(page, wbc);

    // 否则调用通用写回
    return mapping->f_op->fsync(page, wbc);
}
```

---

## 6. 内存布局图

```
文件读写 page_cache 流程：

用户读文件 /foo/bar.dat (内容在磁盘)：

  1. find_get_entry(i_pages, page_index=0)
       ↓
     XArray lookup → NULL（未缓存）
       ↓
  2. read_cache_page()
       ↓
     alloc_page() → 分配 struct page
       ↓
  3. filesystem.readpage() → 从磁盘读入
       ↓
  4. add_to_page_cache(page)
       ↓
     XArray insert: i_pages[0] = page
       ↓
  5. 返回 page 给用户

后续读同一页：
  find_get_entry() → XArray lookup → 直接返回
  ↑ 零磁盘 I/O
```

---

## 7. LRU 缓存淘汰

### 7.1 inode 会话的 LRU

```c
// mm/filemap.c — inode_add_lru
// page_cache 的 LRU 由 inode 的 LRU 间接管理
// inode 结构中有 page 链表
// 当内存压力时，kswapd 扫描 LRU，释放页帧
```

---

## 8. XArray 应用

```c
// 页缓存的 XArray 操作：

// 插入：
xa_insert(&mapping->i_pages, index, page, GFP_KERNEL);

// 查找：
page = xa_load(&mapping->i_pages, index);

// 删除：
xa_erase(&mapping->i_pages, index);

// 迭代：
xa_for_each(&mapping->i_pages, index, page) {
    // 处理每一页
}
```

---

## 9. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `mm/filemap.c` | `find_get_entry`、`read_cache_page`、`add_to_page_cache` |
| `mm/filemap.c` | `filemap_fdatawrite`、`writepage` |
| `include/linux/fs.h` | `struct address_space` |

---

## 10. 西游记类比

**page_cache** 就像"取经队伍的地图缓存"——

> 唐僧去西天取经，每到一个地方（文件系统），都要翻当地的地图（文件）。地图太大，不可能每次都从藏经阁（磁盘）里拿，所以当地土地神会把常用地图缓存起来（页缓存）。如果地图在缓存里（find_get_entry → XArray lookup），直接用；如果没有，就从藏经阁借一份（read_cache_page → filesystem.readpage），然后放在当地保管（add_to_page_cache）。如果地图被涂改过（脏页），就定期归还给藏经阁（writepage）。藏经阁（磁盘）很大，但翻地图很慢；土地神的桌子（内存）小，但翻得快——这就是页缓存的意义。

---

## 11. 关联文章

- **VFS**（article 19）：address_space 是 inode 的成员
- **XArray**（article 04）：address_space.i_pages 使用 XArray
- **page_allocator**（article 17）：页帧是 Buddy System 分配的