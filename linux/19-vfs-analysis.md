# 19-VFS — 虚拟文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**VFS（Virtual File System，虚拟文件系统）** 是 Linux 文件系统的核心抽象层。它定义了所有文件系统必须实现的接口，使得 `open/read/write/close` 等系统调用可以统一地作用于 ext4、XFS、btrfs、NFS 等不同文件系统。

VFS 的核心对象模型由四个主要结构体构成：

```
文件系统视角：
  super_block → inode → dentry → file

用户视角：
  fd → file → dentry → inode → super_block
```

doom-lsp 确认 `include/linux/fs.h` 包含 1650+ 个符号（内核中最大的头文件之一），实现分散在 `fs/` 下的多个文件中。

---

## 1. 核心数据结构

### 1.1 struct super_block——文件系统实例

```c
struct super_block {
    dev_t                   s_dev;        // 设备号
    unsigned long           s_blocksize;  // 块大小
    struct file_system_type *s_type;      // 文件系统类型（如 ext4）
    struct super_operations *s_op;        // 超级块操作

    struct dentry          *s_root;       // 根 dentry
    struct list_head        s_inodes;     // 所有 inode 链表
    struct list_head        s_dentry_lru; // dentry LRU 链表

    struct block_device    *s_bdev;       // 底层块设备
    ...
};
```

### 1.2 struct inode——文件元数据

```c
struct inode {
    umode_t                i_mode;        // 文件类型+权限
    uid_t                  i_uid;         // 所有者 UID
    gid_t                  i_gid;         // 组 GID
    loff_t                 i_size;        // 文件大小
    struct timespec64      i_atime;       // 最后访问时间
    struct timespec64      i_mtime;       // 最后修改时间
    struct timespec64      i_ctime;       // 最后状态改变时间

    const struct inode_operations *i_op;  // inode 操作
    const struct file_operations  *i_fop; // 默认文件操作

    struct address_space   *i_mapping;    // 地址空间（page cache）
    struct address_space    i_data;       // 内嵌 address_space

    struct hlist_node      i_hash;        // inode 哈希表节点
    struct list_head       i_dentry;      // 关联的 dentry 链表
    ...
};
```

### 1.3 struct dentry——目录项

```c
struct dentry {
    unsigned char          d_flags;       // 标志
    struct hlist_bl_node   d_hash;        // dentry 哈希表
    struct dentry         *d_parent;      // 父目录 dentry
    struct qstr            d_name;        // 文件名
    struct inode          *d_inode;       // 关联的 inode（NULL=负 dentry）

    const struct dentry_operations *d_op; // dentry 操作
    struct super_block    *d_sb;          // 所属超级块
    struct list_head       d_child;       // 父目录的 child 链表

    union {
        struct hlist_node d_alias;        // inode 的别名链表
    };
    ...
};
```

### 1.4 struct file——打开的文件描述

```c
struct file {
    struct path            f_path;        // dentry + mount
    const struct file_operations *f_op;   // 文件操作
    loff_t                 f_pos;         // 当前读写位置
    struct address_space  *f_mapping;     // 地址空间

    unsigned int           f_flags;       // O_* 标志
    fmode_t                f_mode;        // FMODE_* 模式
    ...
};
```

---

## 2. 核心操作路径

### 2.1 open 系统调用

```
sys_open(filename, flags, mode)
  │
  ├─ do_sys_open()
  │    ├─ get_unused_fd_flags()       ← 分配文件描述符
  │    │
  │    ├─ do_filp_open(dfd, filename, &op)
  │    │    │
  │    │    ├─ path_openat(nd, op, flags)
  │    │    │    │
  │    │    │    ├─ 路径解析（path_walk）
  │    │    │    │    │
  │    │    │    │    ├─ 逐分量查找：
  │    │    │    │    │    ├─ __lookup_slow() / __d_lookup()
  │    │    │    │    │    │    ├─ 先在 dentry cache 查找
  │    │    │    │    │    │    └─ miss → inode->i_op->lookup()
  │    │    │    │    │    └─ 移动到下一级
  │    │    │    │    │
  │    │    │    │    ├─ 处理符号链接、挂载点、.. 等特殊情况
  │    │    │    │    └─ 最终到达目标 dentry
  │    │    │    │
  │    │    │    ├─ 获取 inode 权限检查
  │    │    │    │
  │    │    │    ├─ dentry_open(path, flags, cred)
  │    │    │    │    ├─ 分配 struct file
  │    │    │    │    ├─ file->f_op = inode->i_fop
  │    │    │    │    └─ file->private_data（FS 特定）
  │    │    │    │
  │    │    │    └─ return file
  │    │    │
  │    │    └─ 返回 file
  │    │
  │    └─ fd_install(fd, file)        ← 关联 fd 和 file
  │
  └─ return fd
```

### 2.2 read 系统调用

```
sys_read(fd, buf, count)
  │
  ├─ fdget(fd)                         ← 通过 fd 找到 struct file
  │
  ├─ file->f_op->read_iter(file, &iter)
  │    │
  │    ├─ 通用实现：generic_file_read_iter()
  │    │    │
  │    │    └─ 从 page cache 读取
  │    │         ├─ filemap_read()
  │    │         │    ├─ 通过 address_space 找到缓存页
  │    │         │    ├─ page_cache_next_entry() 查找页
  │    │         │    ├─ 如果命中 → 直接复制到用户空间
  │    │         │    └─ 如果未命中 → 触发 page_cache_sync_readahead()
  │    │         │
  │    │         └─ copy_page_to_iter() 复制到用户空间
  │    │
  │    └─ 文件系统特化：ext4_file_read_iter() 等
  │
  └─ 返回已读字节数
```

---

## 3. dentry cache（dcache）

dentry cache 是 VFS 性能的关键。它缓存已解析的路径名→inode 映射，避免每次访问都触发磁盘 IO。

```
路径解析示例：
  /home/user/file.txt

  1. 从根 dentry (/) 开始
  2. dentry cache 查找 "home" → 命中
  3. dentry cache 查找 "user" → 命中
  4. dentry cache 查找 "file.txt" → 命中 → 直接返回 inode

  全部命中 = 0 次磁盘 IO（纯内存操作）
```

dcache 使用 hash table + LRU 链表管理。当内存压力大时，回收 dentry 缓存。

---

## 4. 四种对象的关系

```
super_block (每个文件系统实例)
  │
  ├─ s_root ──→ dentry (根目录)
  │                │
  │                ├─ d_inode ──→ inode (根目录 inode)
  │                │               │
  │                │               └─ i_mapping ──→ address_space (page cache)
  │                │
  │                └─ d_child ──→ dentry (子目录/文件)
  │                                  │
  │                                  ├─ d_name = "file.txt"
  │                                  └─ d_inode ──→ inode (文件 inode)
  │                                                   │
  │                                                   └─ i_mapping ──→ address_space
  │
  fd → struct file (打开一个文件)
       └─ f_path.dentry ──→ dentry
       └─ f_mapping ──→ address_space
```

---

## 5. 设计决策总结

| 决策 | 原因 |
|------|------|
| 四种对象分离 | 解耦路径解析、元数据、打开状态 |
| dentry cache | 加速路径解析 |
| inode→address_space | 统一 page cache 管理 |
| file_operations 回调 | 每个文件系统可自定义行为 |

---

## 6. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/fs.h` | 四种核心结构 | 定义 |
| `fs/namei.c` | `path_openat` / `path_walk` | 路径解析 |
| `fs/open.c` | `do_sys_open` | 打开文件 |
| `fs/read_write.c` | `vfs_read` / `vfs_write` | 读写 |
| `fs/dcache.c` | dentry cache 操作 | dcache |

---

## 7. 关联文章

- **page_cache**（article 20）：VFS 的读写操作通过 page cache 实现
- **dentry**（article 208）：dcache 详解
- **inode**（article 162）：inode 的生命周期

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
