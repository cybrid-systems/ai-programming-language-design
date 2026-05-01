# 19-vfs — Linux 虚拟文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**VFS（Virtual File System，虚拟文件系统）** 是 Linux 内核中文件系统实现的统一抽象层。它定义了所有文件系统必须实现的接口（`struct file_operations`、`struct inode_operations`、`struct super_operations` 等），使得 `open()/read()/write()` 等系统调用可以不依赖底层文件系统的具体实现。

VFS 的四层抽象：
```
系统调用层（read, write, open...）
    ↓
VFS 通用层（sys_read → vfs_read → call_read_iter）
    ↓
具体文件系统（ext4_read_folio, btrfs_readpage...）
    ↓
块设备层（submit_bio → 驱动）
```

**doom-lsp 确认**：`include/linux/fs.h` 是内核最大的头文件之一，包含 `struct file`、`struct inode`、`struct dentry`、`struct super_block`、`struct file_operations` 等核心结构体。

---

## 1. 四大核心结构体

### 1.1 `struct file`——打开的文件

```c
struct file {
    struct path                     f_path;       // dentry + vfsmount
    struct inode                    *f_inode;      // 指向 inode（快捷方式）
    const struct file_operations    *f_op;         // 文件操作表
    fmode_t                         f_mode;       // FMODE_READ/WRITE/EXEC
    loff_t                          f_pos;        // 文件读写位置
    struct address_space            *f_mapping;    // 地址映射（page cache）
    unsigned int                    f_flags;       // O_RDONLY, O_NONBLOCK 等
    void                            *private_data; // 文件系统私有数据
    struct list_head                f_ep_links;    // epoll 监听链表
    // ...
};
```

每个 `open()` 系统调用创建一个 `struct file`，多个进程可共享同一文件描述符表或通过 `dup()` 指向同一个 `struct file`。

### 1.2 `struct inode`——文件元数据

```c
struct inode {
    struct hlist_node       i_hash;         // 哈希表节点（快速查找）
    struct list_head        i_sb_list;      // super_block 链表
    struct list_head        i_dentry;       // dentry 别名链表
    unsigned long           i_ino;          // inode 编号
    umode_t                 i_mode;         // 文件类型 + 权限
    struct super_block      *i_sb;          // 所属超级块
    struct address_space    *i_mapping;     // page cache 地址映射
    const struct inode_operations *i_op;    // inode 操作表
    const struct file_operations  *i_fop;   // 文件操作表
    struct file_lock_context *i_flctx;      // 文件锁
    // ...
};
```

一个物理文件对应一个 inode，无论有多少个 dentry 引用它（硬链接）。

### 1.3 `struct dentry`——目录项缓存

```c
struct dentry {
    struct hlist_bl_node    d_hash;         // dentry 哈希表
    struct dentry           *d_parent;      // 父目录 dentry
    struct qstr             d_name;         // 文件名
    struct list_head        d_subdirs;      // 子 dentry 链表
    struct list_head        d_child;        // 兄弟 dentry 链表
    struct inode            *d_inode;       // 关联的 inode
    const struct dentry_operations *d_op;   // dentry 操作
    unsigned int            d_flags;        // DCACHE_* 标志
    // ...
};
```

dentry 是路径名到 inode 的缓存映射，不写回磁盘（纯内存结构）。

### 1.4 `struct super_block`——文件系统实例

```c
struct super_block {
    struct list_head        s_list;         // 全局 super_block 链表
    dev_t                   s_dev;          // 设备 ID
    unsigned long           s_blocksize;    // 块大小
    struct file_system_type *s_type;        // 文件系统类型
    const struct super_operations *s_op;    // super_block 操作表
    struct list_head        s_inodes;       // 所有 inode 链表
    struct xarray           s_fs_info;      // 文件系统私有数据
    // ...
};
```

---

## 2. 系统调用路径

### 2.1 read() 系统调用

```
read(fd, buf, count)                          [用户空间]
  │
  └─ sys_read(fd, buf, count)                 [内核入口]
       │
       └─ ksys_read(fd, buf, count)
            │
            ├─ fdget(fd)                      ← 获取 struct file
            │   └─ current->files->fdt->fd[fd] → file
            │
            ├─ vfs_read(file, buf, count, &pos)  ← VFS 通用层
            │    │
            │    ├─ file->f_op->read_iter(file, &iter)  ← 文件系统层
            │    │    ├─ ext4_file_read_iter()
            │    │    │    └─ generic_file_read_iter()
            │    │    │         ├─ 读取 page cache
            │    │    │         └─ → article 20: page cache 详解
            │    │    │
            │    │    └─ 或者：
            │    │       filemap_read(file, iter, &pos)
            │    │
            │    └─ return bytes_read
            │
            ├─ fdput(file)                    ← 释放引用
            └─ return bytes_read
```

### 2.2 open() 系统调用

```
open(pathname, flags, mode)                   [用户空间]
  │
  └─ sys_openat(AT_FDCWD, pathname, flags, mode)
       │
       └─ do_sys_open(dfd, pathname, flags, mode)
            │
            ├─ do_filp_open(dfd, pathname, &op)
            │    │
            │    └─ path_openat(nd, op, flags)
            │         │
            │         ├─ 路径遍历：
            │         │    ├─ walk_component() → lookup_dcache() → lookup_slow()
            │         │    ├─   dentry = d_lookup(parent, name)    ← dentry 缓存
            │         │    ├─   如果没有缓存：
            │         │    │    └─ inode->i_op->lookup(dir, dentry, flags)
            │         │    │       → ext4_lookup() → 读磁盘 inode
            │         │    └─ 进入下一级目录...
            │         │
            │         ├─ dentry_open(path, flags, cred)
            │         │    ├─ alloc_file(file, path, fops)
            │         │    ├─ file->f_op = inode->i_fop  ← 设置操作表
            │         │    └─ fsnotify_open(file)         ← 通知
            │         │
            │         └─ return file
            │
            ├─ fd_install(fd, file)             ← 安装到 fd 表
            └─ return fd
```

---

## 3. file_operations——驱动文件行为

```c
// include/linux/fs.h
struct file_operations {
    loff_t (*llseek)(struct file *, loff_t, int);
    ssize_t (*read_iter)(struct kiocb *, struct iov_iter *);
    ssize_t (*write_iter)(struct kiocb *, struct iov_iter *);
    int (*open)(struct inode *, struct file *);
    int (*flush)(struct file *, fl_owner_t);
    int (*release)(struct inode *, struct file *);
    int (*mmap)(struct file *, struct vm_area_struct *);
    __poll_t (*poll)(struct file *, struct poll_table_struct *);
    int (*fsync)(struct file *, loff_t, loff_t, int datasync);
    // ...
};
```

每个文件系统注册自己的 `file_operations`：

```c
// ext4 file_operations
const struct file_operations ext4_file_operations = {
    .read_iter      = ext4_file_read_iter,
    .write_iter     = ext4_file_write_iter,
    .open           = ext4_file_open,
    .release        = ext4_release_file,
    .mmap           = ext4_file_mmap,
    .fsync          = ext4_sync_file,
    // ...
};
```

---

## 4. 源码文件索引

| 文件 | 内容 |
|------|------|
| `include/linux/fs.h` | 核心结构体 + VFS API |
| `fs/read_write.c` | read/write 系统调用 |
| `fs/open.c` | open/close 系统调用 |
| `fs/namei.c` | 路径解析 |

---

## 5. 关联文章

- **20-page-cache**：read/write 底层调用 page cache
- **66-ext4**：ext4 的 file_operations 实现
- **67-xfs**：XFS 的 VFS 接口
- **88-mmap**：mmap 的 VFS 处理

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
