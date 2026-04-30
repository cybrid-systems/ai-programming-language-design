# 19-VFS — 虚拟文件系统层深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/namei.c` + `fs/open.c` + `include/linux/fs.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**VFS（Virtual File System Switch）** 是 Linux 文件系统抽象层，向上提供统一 POSIX API（open/read/write/close），向下支持多种文件系统（ext4、XFS、btrfs、proc、sysfs）。

---

## 1. 核心数据结构

### 1.1 inode — 文件元数据

```c
// include/linux/fs.h — inode
struct inode {
    // 标识
    umode_t                 i_mode;          // 文件类型 + 权限
    kuid_t                  i_uid;            // 用户 ID
    kgid_t                  i_gid;            // 组 ID
    loff_t                  i_size;           // 文件大小
    struct timespec64        i_atime;         // 访问时间
    struct timespec64        i_mtime;         // 修改时间
    struct timespec64        i_ctime;         // 状态改变时间
    unsigned long           i_ino;            // inode 号（FS 唯一）

    // 操作函数表
    const struct inode_operations *i_op;    // inode 操作（create/mkdir/rename）
    const struct file_operations *i_fop;    // 文件操作（read/write）
    struct super_block       *i_sb;          // 所属超级块

    // 页缓存
    struct address_space     *i_data;        // 页缓存（XA array）

    // 设备/管道/套接字
    union {
        struct pipe_inode_info *i_pipe;      // 管道
        struct cdev            *i_cdev;      // 字符设备
        struct block_device    *i_bdev;       // 块设备
        void                  *i_private;    // 私有数据
    };
};
```

### 1.2 file — 打开的文件

```c
// include/linux/fs.h — file
struct file {
    // 路径
    struct path             f_path;          // 路径（dentry + vfsmount）
    struct file_operations  *f_op;           // 文件操作（read/write/open/...）

    // 位置
    loff_t                  f_pos;          // 当前文件偏移

    // 统计
    unsigned int            f_flags;          // open 时的标志
    fmode_t                f_mode;            // 打开模式

    // 私有数据
    void                   *private_data;     // 驱动私有数据
};
```

### 1.3 dentry — 目录项

```c
// include/linux/dcache.h — dentry
struct dentry {
    // 标识
    struct inode           *d_inode;         // 关联的 inode
    struct qstr            d_name;           // 文件名（不含父路径）
    unsigned char          d_iname[256];     // 短文件名缓存

    // 父子关系
    struct dentry         *d_parent;        // 父目录
    struct list_head       d_children;       // 子目录链表

    // 哈希
    struct hlist_node       d_hash;           // 接入 dentry_hashtable

    // 父目录链表
    struct list_head       d_subdirs;        // 子链表
    struct list_head       d_alias;          // inode 的 alias 链表

    // 状态
    unsigned int           d_flags;           // DCACHE_*
};
```

### 1.4 super_block — 超级块

```c
// include/linux/fs.h — super_block
struct super_block {
    // 文件系统
    const struct super_operations *s_op;    // 超级块操作
    const struct xattr_handler **s_xattr;     // 扩展属性

    // 根目录
    struct dentry         *s_root;           // 根目录 dentry

    // 统计
    unsigned long           s_blocksize;       // 块大小
    unsigned long           s_maxbytes;        // 最大文件大小
    void                   *s_fs_info;       // 文件系统私有数据
};
```

---

## 2. file_operations — 文件操作函数表

```c
// include/linux/fs.h — file_operations
struct file_operations {
    // 基础
    struct module           *owner;
    loff_t               (*llseek)(struct file *, loff_t, int);
    ssize_t              (*read)(struct file *, char __user *, size_t, loff_t *);
    ssize_t              (*write)(struct file *, const char __user *, size_t, loff_t *);
    int                   (*open)(struct inode *, struct file *);
    int                   (*release)(struct inode *, struct file *);

    // I/O
    ssize_t              (*read_iter)(struct kiocb *, struct iov_iter *);
    ssize_t              (*write_iter)(struct kiocb *, struct iov_iter *);

    // 同步
    int                   (*fsync)(struct file *, loff_t, loff_t, int);
    int                   (*flush)(struct file *, fl_owner_t id);

    // 异步 I/O
    int                   (*fasync)(int, struct file *, int);
};
```

---

## 3. open 系统调用流程

### 3.1 do_sys_open

```c
// fs/open.c — do_sys_open
long do_sys_open(int dfd, const char __user *filename, int flags, umode_t mode)
{
    struct filename *name = getname(filename);
    struct file *f;
    int fd;

    // 1. 分配 fd
    fd = get_unused_fd_flags(flags);

    // 2. 打开文件
    f = do_filp_open(dfd, name, &op, flags);
    if (IS_ERR(f))
        goto out;

    // 3. 安装 fd → file 映射
    fd_install(fd, f);

    return fd;

out:
    put_unused_fd(fd);
    return PTR_ERR(f);
}
```

### 3.2 do_filp_open — 路径查找

```c
// fs/namei.c — do_filp_open
struct file *do_filp_open(int dfd, struct filename *pathname,
                          const struct open_flags *op, int flags)
{
    struct dentry *dentry;
    struct path path;

    // 1. 路径解析：找到文件的 dentry
    dentry = path_lookupat(dfd, pathname, flags, &path);
    if (IS_ERR(dentry))
        return ERR_CAST(dentry);

    // 2. 分配 file 结构
    f = alloc_file(&path, flags, &def_fops);
    if (!f)
        return ERR_PTR(-ENFILE);

    // 3. 调用文件系统的 open
    if (f->f_op->open)
        error = f->f_op->open(inode, f);

    return f;
}
```

---

## 4. read/write 系统调用流程

### 4.1 sys_read

```c
// fs/read_write.c — ksys_read
ssize_t ksys_read(unsigned int fd, char __user *buf, size_t count)
{
    struct file *file;
    ssize_t ret;

    // 1. 获取 file
    file = fget(fd);

    // 2. 检查文件是否可读
    if (file->f_mode & FMODE_READ)
        ret = vfs_read(file, buf, count, &file->f_pos);

    fput(file);
    return ret;
}
```

### 4.2 vfs_read

```c
// fs/read_write.c — vfs_read
ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)
{
    ssize_t ret;

    // 1. 检查 offset
    if (file->f_op->llseek)
        // llseek 可能修改 pos

    // 2. 调用 file_operations->read 或 read_iter
    if (file->f_op->read)
        ret = file->f_op->read(file, buf, count, pos);
    else if (file->f_op->read_iter)
        ret = do_sync_read(file, buf, count, pos);

    return ret;
}
```

---

## 5. inode_operations — inode 操作

```c
// include/linux/fs.h — inode_operations
struct inode_operations {
    // 创建/删除
    int                   (*create)(struct inode *, struct dentry *, umode_t, bool);
    int                   (*lookup)(struct inode *, struct dentry *);
    int                   (*mkdir)(struct inode *, struct dentry *, umode_t);
    int                   (*rmdir)(struct inode *, struct dentry *);
    int                   (*rename)(struct inode *, struct dentry *,
                                     struct inode *, struct dentry *, unsigned int);
    // 属性
    int                   (*getattr)(const struct path *, struct kstat *, __u32, unsigned int);
    int                   (*setattr)(struct dentry *, struct iattr *);
};
```

---

## 6. 内存布局图

```
VFS 数据结构关系：

            super_block (s_root)
                    │
                    ↓
               dentry (根目录)
                    │
                    ├── dentry (子目录/文件)
                    │       │
                    │       └── inode
                    │               │
                    └── ...           ├── i_op (inode_operations)
                                    ├── i_fop (file_operations)
                                    └── i_data (address_space / page cache)

file descriptor table (per process):
  fd=0 ──→ file* ──→ dentry + f_op
  fd=1 ──→ file* ──→ dentry + f_op
  fd=2 ──→ file* ──→ dentry + f_op
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/fs.h` | `struct inode`、`struct file`、`struct dentry`、`struct super_block` |
| `include/linux/fs.h` | `struct file_operations`、`struct inode_operations` |
| `fs/namei.c` | `do_filp_open`、`path_lookupat` |
| `fs/open.c` | `do_sys_open` |
| `fs/read_write.c` | `vfs_read`、`ksys_read` |

---

## 8. 西游记类比

**VFS** 就像"取经队伍通用的通行证系统"——

> 不管是去东海龙宫（ext4）、火焰山（XFS）、还是天庭的档案馆（proc），都使用同一套通行证（VFS）。每到一个地方（文件系统），首先用同一套地图查找术（path_lookupat）找到目的地（dentry），然后验证通行证上写的权限（inode.i_mode）。如果通行证上写着"可读"，就能看档案；如果写着"可写"，就能修改。每个地方的具体规定（ext4 的日志、XFS 的 B+树）都是当地的事，但通行证的格式是统一的。这就是 VFS 的精髓：统一的 API，不同的文件系统实现。

---

## 9. 关联文章

- **page_cache**（article 20）：inode.i_data 是页缓存
- **dentry**（VFS 部分）：dentry_hashtable 使用 hlist 存储
- **block layer**（存储部分）：VFS 与块设备的接口