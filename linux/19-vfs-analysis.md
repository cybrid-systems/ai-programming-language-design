# VFS — 虚拟文件系统层深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/internal.h` + `fs/namei.c` + `fs/open.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**VFS（Virtual File System Switch）** 是 Linux 文件系统抽象层，向上提供统一 POSIX API，向下支持多种文件系统（ext4、XFS、btrfs、proc、sysfs...）。

---

## 1. 核心数据结构

### 1.1 inode — 文件元数据

```c
// include/linux/fs.h — inode
struct inode {
    umode_t                 i_mode;          // 文件类型 + 权限
    kuid_t                  i_uid;            // 用户 ID
    kgid_t                  i_gid;            // 组 ID
    loff_t                  i_size;           // 文件大小
    struct timespec64        i_atime;         // 访问时间
    struct timespec64        i_mtime;         // 修改时间
    struct timespec64        i_ctime;         // 状态改变时间
    unsigned long           i_ino;            // inode 号

    const struct inode_operations *i_op;    // inode 操作
    const struct file_operations *i_fop;    // 文件操作
    struct super_block       *i_sb;          // 所属超级块

    struct address_space     *i_data;        // 页缓存

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
    union {
        struct llist_node       fu_llist;    // 链表节点
        struct rcu_head         fu_rcuhead;  // RCU 头
    };
    struct path                 f_path;       // 路径
    struct inode              *f_inode;      // inode
    const struct file_operations *f_op;      // 文件操作
    fmode_t                  f_mode;          // 打开模式
    loff_t                   f_pos;          // 文件位置
    struct fown_struct       f_owner;        // 文件所有者
    void                    *private_data;    // 私有数据
};
```

### 1.3 dentry — 目录项

```c
// include/linux/dcache.h — dentry
struct dentry {
    unsigned int            d_flags;          // 标志
    struct inode           *d_inode;         // inode
    struct dentry          *d_parent;         // 父目录
    struct qstr            d_name;           // 文件名
    struct list_head        d_child;          // 接入父目录的链表
    struct list_head        d_subdirs;        // 子目录链表
    // ...
};
```

### 1.4 super_block — 超级块

```c
// include/linux/fs.h — super_block
struct super_block {
    struct list_head        s_list;           // 全局超级块链表
    const struct super_operations *s_op;      // 超级块操作
    const struct xattr_handler **s_xattr;      // 扩展属性
    struct dentry          *s_root;           // 根目录
    struct block_device    *s_bdev;           // 底层块设备
    void                  *s_fs_info;        // 文件系统私有数据
};
```

---

## 2. 文件操作函数表

### 2.1 file_operations

```c
// include/linux/fs.h — file_operations
struct file_operations {
    loff_t (*llseek)(struct file *, loff_t, int);
    ssize_t (*read)(struct file *, char __user *, size_t, loff_t *);
    ssize_t (*write)(struct file *, const char __user *, size_t, loff_t *);
    int (*open)(struct inode *, struct file *);
    int (*release)(struct inode *, struct file *);
    int (*fsync)(struct file *, loff_t, loff_t, int);
    // ...
};
```

### 2.2 inode_operations

```c
// include/linux/fs.h — inode_operations
struct inode_operations {
    int (*create)(struct inode *, struct dentry *, umode_t, bool);
    struct dentry * (*lookup)(struct inode *, struct dentry *);
    int (*mkdir)(struct inode *, struct dentry *, umode_t);
    int (*rename)(struct inode *, struct dentry *,
                  struct inode *, struct dentry *, unsigned int);
    // ...
};
```

---

## 3. open — 打开文件流程

```c
// fs/open.c — do_sys_openat2
long do_sys_openat2(int dfd, const char *pathname,
            struct open_flags *how)
{
    // 1. 路径解析：dentry = path_lookup(pathname)
    // 2. 分配 file：filp = file_open_alloc()
    // 3. 调用 inode->i_op->open()
    // 4. 返回 fd
}
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/fs.h` | `struct inode`、`struct file`、`struct super_block` |
| `include/linux/dcache.h` | `struct dentry` |
| `fs/namei.c` | `path_lookup`、`link_path_walk` |
| `fs/open.c` | `do_sys_openat2`、`file_open_alloc` |
