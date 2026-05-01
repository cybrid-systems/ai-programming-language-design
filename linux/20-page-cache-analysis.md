# 20-page_cache — 页缓存深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**page cache** 将磁盘文件数据缓存在物理内存中，避免每次读写都发生磁盘 I/O。通过 address_space 以文件页偏移为索引，存储对应的物理页。

---

## 1. 核心结构

```c
struct address_space {
    struct inode            *host;        // 所属 inode
    struct xarray           i_pages;      // 页索引（XArray）
    unsigned long           nrpages;      // 缓存页数
    struct address_space_operations *a_ops; // 读写回调
};
```

文件偏移 → XArray 索引 → struct page*

---

## 2. 读写路径

### 2.1 读

```
filemap_read(file, iter, bytes)
  │
  ├─ find_get_page(mapping, index) → xa_load()
  │    ├─ 命中 → copy_page_to_iter() → 返回
  │    └─ 未命中：
  │         ├─ page_cache_sync_readahead() → 预读
  │         ├─ a_ops->readpage(file, page) → 磁盘读
  │         └─ add_to_page_cache_lru()
  │
  └─ mark_page_accessed() → LRU 管理
```

### 2.2 写（write-back）

```
generic_perform_write(file, data, pos)
  │
  ├─ grab_cache_page_write_begin(mapping, index)
  │    └─ 查找/创建缓存页
  ├─ iov_iter_copy_from_user_atomic() → 复制数据
  ├─ a_ops->write_end() → 标记脏页
  │    └─ set_page_dirty()
  │         └─ __xa_set_mark(PAGECACHE_TAG_DIRTY)
  └─ writeback 线程稍后回写

writeback 触发时机：
  ├─ 脏页比例超限（dirty_background_ratio）
  ├─ 定时器到期（dirty_expire_interval）
  └─ 内存回收遇到脏页（直接回写）
```

---

## 3. 预读（readahead）

```
顺序读检测：file->f_ra 记录读取模式
  ├─ 首次读 → 4KB（1 页）
  ├─ 顺序读 → 窗口加倍：2, 4, 8, 16...（上限 32 页）
  └─ 随机读 → 不预读
```

---

## 4. 设计决策

| 决策 | 原因 |
|------|------|
| XArray 索引 | 标记系统（脏页标记）|
| write-back 延迟写 | 合并小写，减少 IO |
| 预读 | 隐藏磁盘延迟 |
| 脏页比例控制 | 防止内存被脏页耗尽 |

---

*分析工具：doom-lsp（clangd LSP）*
