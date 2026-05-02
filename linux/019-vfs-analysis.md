# 19-vfs — Linux 虚拟文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**VFS（Virtual File System，虚拟文件系统）** 是 Linux 内核文件系统核心抽象层。它在具体文件系统（ext4, xfs, btrfs）之上定义了一组统一的数据结构和操作接口，使得 `open()/read()/write()/close()` 等 POSIX 系统调用可以不依赖底层文件系统的具体实现。

VFS 的四层架构：

```
系统调用层（sys_read, sys_write, sys_open...）
       ↓
  VFS 通用层（vfs_read, vfs_write, vfs_open...）
       ↓
  具体文件系统层（ext4_file_read_iter, xfs_file_write...）
       ↓
  通用块层（submit_bio, make_request...）
```

**doom-lsp 确认**：核心结构体定义在 `include/linux/fs.h`（1994 行，内核最大的头文件之一）。关键结构体包括 `struct file`、`struct inode`、`struct dentry`、`struct super_block`。系统调用实现在 `fs/read_write.c`、`fs/open.c`、`fs/namei.c`。

---

## 1. 四大核心结构体

### 1.1 `struct file`——打开的文件实例

```c
struct file {
    struct path             f_path;            // dentry + mount 对
    struct inode            *f_inode;          // 指向 inode（f_path 的快捷方式）
    const struct file_operations *f_op;        // 文件操作表
    spinlock_t              f_lock;            // 保护 f_pos 等字段
    fmode_t                 f_mode;            // FMODE_READ/WRITE/EXEC
    loff_t                  f_pos;             // 读写位置
    struct address_space    *f_mapping;        // 地址映射（= inode->i_mapping）
    unsigned int            f_flags;           // O_RDONLY, O_NONBLOCK 等
    void                    *private_data;     // 文件系统私有数据
    struct list_head        f_ep_links;        // epoll 监听链表
    struct fown_struct      f_owner;           // 异步 IO 所有者
    // ...
};
```

**关键**：每个 `open()` 创建一个 `struct file`。`dup()` 和 `fork()` 共享同一 `struct file`（引用计数）。`f_pos` 是进程私有的？不——它是 `struct file` 的字段，所以 `dup()` 后的两个 fd 共享同一文件位置。

### 1.2 `struct inode`——文件元数据（磁盘 inode 的内存表示）

```c
struct inode {
    struct hlist_node       i_hash;            // inode 哈希表节点
    struct list_head        i_sb_list;         // 同 super_block 的 inode 链表
    struct list_head        i_dentry;          // 引用此 inode 的 dentry 链表
    unsigned long           i_ino;             // inode 编号
    umode_t                 i_mode;            // 文件类型+权限
    kuid_t                  i_uid;             // 用户 ID
    kgid_t                  i_gid;             // 组 ID
    loff_t                  i_size;            // 文件大小
    struct timespec64       i_atime;           // 访问时间
    struct timespec64       i_mtime;           // 修改时间
    struct timespec64       i_ctime;           // 状态变更时间
    struct super_block      *i_sb;             // 所属超级块
    struct address_space    *i_mapping;        // page cache 地址空间
    const struct inode_operations  *i_op;      // inode 操作表
    const struct file_operations   *i_fop;     // 默认文件操作表
    struct file_lock_context *i_flctx;         // 文件锁上下文
    // ...
};
```

**一个物理文件 = 一个 inode**。无论在文件系统中被多少个目录引用（硬链接），只对应同一个 inode。

### 1.3 `struct dentry`——目录项缓存（纯内存结构）

```c
struct dentry {
    struct hlist_bl_node    d_hash;            // dentry 哈希表（快速路径名查找）
    struct dentry           *d_parent;         // 父目录
    struct qstr             d_name;            // 文件名（哈希值 + 字符串）
    struct list_head        d_subdirs;         // 子目录链表
    struct list_head        d_child;           // 兄弟目录链表
    struct inode            *d_inode;          // 关联的 inode
    const struct dentry_operations *d_op;      // dentry 操作表
    unsigned int            d_flags;           // DCACHE_* 标志
    // ...
};
```

**重要**：dentry 是**纯内存结构**，从不写回磁盘。它的存在是为了加速路径名到 inode 的转换。dentry 缓存（dcache）是 VFS 性能的关键。

### 1.4 `struct super_block`——文件系统实例

```c
struct super_block {
    struct list_head        s_list;            // 全局 super_block 链表
    dev_t                   s_dev;             // 设备号
    unsigned char           s_blocksize_bits;  // 块大小（移位）
    unsigned long           s_blocksize;       // 块大小（字节）
    struct file_system_type *s_type;           // 文件系统类型（ext4, xfs...）
    const struct super_operations *s_op;       // super_block 操作表
    struct list_head        s_inodes;          // 此文件系统所有 inode 链表
    struct xarray           s_fs_info;         // 文件系统私有数据
    // ...
};
```

---

## 2. 操作函数表

### 2.1 `struct file_operations`——文件操作

```c
struct file_operations {
    loff_t  (*llseek)(struct file *, loff_t, int);
    ssize_t (*read_iter)(struct kiocb *, struct iov_iter *);       // 读
    ssize_t (*write_iter)(struct kiocb *, struct iov_iter *);      // 写
    int     (*open)(struct inode *, struct file *);                // 打开
    int     (*release)(struct inode *, struct file *);             // 关闭
    int     (*flush)(struct file *, fl_owner_t);                   // flush
    int     (*fsync)(struct file *, loff_t, loff_t, int datasync); // 同步
    int     (*mmap)(struct file *, struct vm_area_struct *);       // 内存映射
    __poll_t (*poll)(struct file *, struct poll_table_struct *);   // 轮询
    int     (*lock)(struct file *, int, struct file_lock *);       // 文件锁
    // ...
};
```

每种文件系统提供自己的 `file_operations`：

```c
// ext4
const struct file_operations ext4_file_operations = {
    .read_iter  = ext4_file_read_iter,
    .write_iter = ext4_file_write_iter,
    .open       = ext4_file_open,
    .release    = ext4_release_file,
    .mmap       = ext4_file_mmap,
    .fsync      = ext4_sync_file,
};

// procfs（伪文件系统）
const struct file_operations proc_reg_file_ops = {
    .read_iter  = proc_reg_read_iter,
    .write_iter = proc_reg_write_iter,
    .open       = proc_reg_open,
    .release    = proc_reg_release,
};
```

### 2.2 `struct inode_operations`——inode 操作

```c
struct inode_operations {
    int     (*create)(struct mnt_idmap *, struct inode *,struct dentry *, umode_t, bool);
    int     (*lookup)(struct inode *, struct dentry *, unsigned int);
    int     (*link)(struct dentry *,struct inode *,struct dentry *);
    int     (*unlink)(struct inode *,struct dentry *);
    int     (*mkdir)(struct mnt_idmap *, struct inode *,struct dentry *, umode_t);
    int     (*rmdir)(struct inode *,struct dentry *);
    int     (*rename)(struct mnt_idmap *, struct inode *, struct dentry *,
                      struct inode *, struct dentry *, unsigned int);
    // ...
};
```

### 2.3 `struct super_operations`——超级块操作

```c
struct super_operations {
    struct inode *(*alloc_inode)(struct super_block *sb);       // 分配 inode
    void         (*destroy_inode)(struct inode *);               // 销毁 inode
    void         (*free_inode)(struct inode *);
    int          (*write_inode)(struct inode *, struct writeback_control *);
    void         (*dirty_inode)(struct inode *, int flags);
    int          (*sync_fs)(struct super_block *sb, int wait);   // 同步 FS
    int          (*statfs)(struct dentry *, struct kstatfs *);   // statfs
    int          (*remount_fs)(struct super_block *, int *, char *);
    void         (*put_super)(struct super_block *);             // 卸载
};
```

---

## 3. 🔥 read() 系统调用完整路径

```
read(fd, buf, count)                              [用户空间 glibc]
  │
  └─ 系统调用入口：sys_read(fd, buf, count)        @ fs/read_write.c
       │
       └─ ksys_read(fd, buf, count)                @ fs/read_write.c
            │
            ├─ [1. 获取 file 结构]
            │   fdget(fd)
            │   → current->files->fdt->fd[fd] → struct fd
            │   → f.file = struct file *
            │   → f.flags = FDPUT_FPUT (引用计数)
            │
            ├─ [2. 检查权限]
            │   if (!(file->f_mode & FMODE_READ))
            │       return -EBADF
            │
            ├─ [3. VFS 通用层]
            │   vfs_read(file, buf, count, &pos)
            │    │
            │    ├─ file_pos_read(file) → 读取 f_pos
            │    │
            │    ├─ rw_verify_area(READ, file, pos, count)
            │    │   → 检查文件锁（mandatory locking）
            │    │   → 检查 RLIMIT_FSIZE
            │    │
            │    ├─ if (file->f_op->read_iter)
            │    │       ret = file->f_op->read_iter(kiocb, iter)
            │    │   else if (file->f_op->read)
            │    │       ret = file->f_op->read(file, buf, count, pos)
            │    │   │
            │    │   ├─ ext4_file_read_iter(kiocb, iter)
            │    │   │    └─ generic_file_read_iter(kiocb, iter)
            │    │   │         ├─ O_DIRECT → ext4_direct_IO
            │    │   │         │    → get_user_pages + submit_bio
            │    │   │         │
            │    │   │         └─ 普通 I/O → filemap_read(kiocb, iter, ret)
            │    │   │              → page cache 读取
            │    │   │              → 见 article 20
            │    │   │
            │    │   └─ proc_reg_read_iter(file, iter)
            │    │        → 直接读取 procfs 缓冲区
            │    │
            │    └─ file_pos_write(file, pos) → 更新 f_pos
            │
            ├─ [4. 清理]
            │   fdput(f) → 释放 file 引用
            │
            └─ return ret
```

---

## 4. 🔥 open() 系统调用完整路径

```
open(pathname, flags, mode)                       [用户空间 glibc]
  │
  └─ sys_openat(AT_FDCWD, pathname, flags, mode)  @ fs/open.c
       │
       └─ do_sys_open(dfd, pathname, flags, mode)
            │
            └─ do_filp_open(dfd, pathname, &op)
                 │
                 └─ path_openat(nd, op, flags)    @ fs/namei.c
                      │
                      ├─ [1. 路径解析（namei）]
                      │   │
                      │   ├─ set_nameidata(nd, dfd, name)
                      │   │   → 初始化路径遍历状态
                      │   │
                      │   ├─ link_path_walk(name, nd)
                      │   │   → 逐级路径解析
                      │   │   │
                      │   │   └─ walk_component(nd, LOOKUP_FOLLOW)
                      │   │        │
                      │   │        ├─ 获取当前路径分量
                      │   │        ├─ lookup_dcache(nd, name, ...)
                      │   │        │   → d_lookup(parent, name)
                      │   │        │   → 检查 dentry 缓存
                      │   │        │
                      │   │        ├─ [缓存命中] → 使用缓存 dentry
                      │   │        │
                      │   │        └─ [缓存未命中] → lookup_slow(nd, dentry, flags)
                      │   │             │
                      │   │             ├─ inode->i_op->lookup(dir, dentry, flags)
                      │   │             │   ← ext4_lookup() 等
                      │   │             │   → 从磁盘读取 inode
                      │   │             │   → d_splice_alias(inode, dentry)
                      │   │             │
                      │   │             └─ dentry 被加入 dcache ← 缓存！
                      │   │
                      │   ├─ [到达最后路径分量]
                      │   │   → 文件名已在 nd->last
                      │   │
                      │   └─ [符号链接跟随]
                      │       → nd_jump_link → 重新开始路径解析
                      │
                      ├─ [2. 打开文件]
                      │   dentry_open(path, flags, cred)
                      │    │
                      │    ├─ alloc_file(path, flags, fops)
                      │    │   → 分配 struct file
                      │    │   → file->f_op = inode->i_fop
                      │    │   → file->f_mapping = inode->i_mapping
                      │    │
                      │    ├─ file->f_op->open(inode, file)
                      │    │   ← ext4_file_open()
                      │    │   → 文件系统初始化私有数据
                      │    │
                      │    └─ fsnotify_open(file)
                      │
                      ├─ [3. 安装到 fd 表]
                      │   fd_install(fd, file)
                      │   → current->files->fdt->fd[fd] = file
                      │
                      └─ return fd
```

---

## 5. 🔥 write() 系统调用完整路径

```
write(fd, buf, count)
  │
  └─ sys_write(fd, buf, count) → ksys_write(fd, buf, count)
       │
       ├─ fdget(fd)
       ├─ vfs_write(file, buf, count, &pos)
       │    │
       │    ├─ rw_verify_area(WRITE, file, pos, count)
       │    ├─ file_start_write(file)  ← 文件 freeze 保护
       │    │
       │    └─ if (file->f_op->write_iter)
       │            ret = file->f_op->write_iter(kiocb, iter)
       │        │
       │        ├─ ext4_file_write_iter(kiocb, iter)
       │        │    ├─ O_DIRECT → ext4_direct_IO_write
       │        │    │    → pin_user_pages + submit_bio
       │        │    │
       │        │    └─ 普通 I/O → generic_perform_write(kiocb, i)
       │        │         │
       │        │         └─ [循环写入数据]
       │        │              for (;;) {
       │        │                  a_ops->write_begin(...)
       │        │                  → ext4_write_begin:
       │        │                     分配/获取 folio
       │        │                     读取旧数据（部分写入）
       │        │
       │        │                  copy_page_from_iter_atomic(page, ...)
       │        │                  → ★ 从用户空间拷贝到内核 folio！
       │        │
       │        │                  a_ops->write_end(...)
       │        │                  → ext4_write_end:
       │        │                     folio_mark_dirty(folio)
       │        │                     block_write_end → 块分配
       │        │              }
       │        │
       │        └─ file_end_write(file)
       │
       ├─ fdput(file)
       └─ return ret
```

---

## 6. 文件描述符表管理

```c
struct files_struct {
    atomic_t        count;              // 引用计数（fork 共享时>1）
    struct fdtable   *fdt;              // 指向 fdtable
    // ...
};

struct fdtable {
    struct file         **fd;           // fd 数组（索引→file*）
    unsigned int         max_fds;       // 当前容量
    struct fdtable       *next;         // 扩容链表
    // ...
};
```

**常见操作**：
```c
// fd 分配：
fd = get_unused_fd_flags(flags);
current->files->fdt->fd[fd] = file;

// fd 关闭：
current->files->fdt->fd[fd] = NULL;
put_unused_fd(fd);
fput(file);  // 减少 file 引用计数

// fd 重定向（dup2）：
fd1 = fd2: 当前进程的 files->fdt->fd[fd2] → 指向同一 file
file 的引用计数 +1
```

---

## 7. 路径解析（namei）细节

路径解析是 VFS 最复杂的部分之一，需要考虑挂载点、符号链接、权限等多种因素：

```
路径 "/usr/bin/ls" 的解析过程：

1. 起始：当前进程的 root dentry (/, dentry of "/")
   → nd->path = root 的 dentry + mount

2. 解析 "usr"：
   → walk_component: lookup_dcache("/", "usr")
   → 如果 dentry 缓存未命中：
      → i_op->lookup(inode, dentry, 0) — ext4 读磁盘
   → dentry 对应 inode = /usr 的 inode
   → ⚠ 检查挂载点：/usr 是否挂载点？
      如果是，跨越挂载（__follow_mount_rcu）
   → 进入 /usr 目录

3. 解析 "bin"：
   → 同上，跨越挂载
   → 进入 /usr/bin 目录

4. 解析 "ls"：
   → 查找 "ls" → 找到 dentry + inode
   → 检查权限 → 创建 struct file → 返回 fd
```

---

## 8. 挂载模型

```c
struct vfsmount {
    struct dentry       *mnt_root;     // 挂载点的根 dentry
    struct super_block  *mnt_sb;       // 文件系统的 super_block
    int                 mnt_flags;     // MNT_READONLY 等
};

struct mount {
    struct hlist_node   mnt_hash;       // 挂载哈希表
    struct mount        *mnt_parent;    // 父挂载
    struct dentry       *mnt_mountpoint; // 在父文件系统中的挂载点 dentry
    struct vfsmount     mnt;            // 嵌入的 vfsmount
    // ...
};
```

**挂载层次**：
```
挂载点树：
  / (ext4 on /dev/sda1)
    ├── usr
    ├── home (ext4 on /dev/sdb1)    ← 挂载点
    │     └── user1
    └── mnt (tmpfs)
```

遍历时在 `walk_component` 中检测挂载跨越：
```
在 /home 目录查找 "user1"：
  lookup_dcache(/home, "user1") → dentry
  dentry 的挂载标志？→ 检查是否挂载点
  如果是 → __follow_mount → 跳转到被挂载文件系统的根 dentry
```

---

## 9. 源码文件索引

| 文件 | 内容 | 关键函数 |
|------|------|---------|
| `include/linux/fs.h` | 核心结构体 | file, inode, dentry, super_block |
| `fs/read_write.c` | read/write 实现 | `vfs_read`, `vfs_write` |
| `fs/open.c` | open/close 实现 | `do_dentry_open`, `dentry_open` |
| `fs/namei.c` | 路径解析 | `path_openat`, `walk_component`, `link_path_walk` |
| `fs/file.c` | fd 表管理 | `alloc_fd`, `fd_install`, `fput` |
| `fs/super.c` | 超级块管理 | `sget_fc`, `kill_sb` |

---

## 10. 关联文章

- **20-page-cache**：read/write 的 I/O 路径
- **66-ext4**：ext4 的 VFS 接口实现
- **67-xfs**：XFS 的 VFS 接口
- **98-procfs**：procfs 的 VFS 集成

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
