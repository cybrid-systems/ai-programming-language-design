# Linux Kernel VFS (Virtual File System Switch) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/*.c` + `include/linux/fs.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 VFS？

**VFS（Virtual File System Switch）** 是 Linux 内核的**文件系统抽象层**。它统一了 ext4、XFS、Btrfs、NFS、CIFS 等所有文件系统的接口，让用户空间的 `open()`/`read()`/`write()` 对所有文件系统都有效。

**核心思想**：
- 所有文件系统都实现相同的 VFS 接口
- 内核通过 VFS 接口操作文件，不需要知道底层文件系统细节
- dentry 缓存加速路径名查找

---

## 1. 四大核心对象

```
VFS 四大对象：
┌─────────────────────────────────────────────────────┐
│  super_block     │ 一个挂载点对应一个 super_block    │
│  (文件系统实例)   │ ext4_sb / xfs_sb / nfs_sb       │
├─────────────────────────────────────────────────────┤
│  inode           │ 一个文件对应一个 inode           │
│  (文件元数据)     │ 文件属性、指向数据块的指针        │
├─────────────────────────────────────────────────────┤
│  dentry          │ 一个路径组件对应一个 dentry      │
│  (目录项缓存)     │ /a/b/c → 三个 dentry           │
├─────────────────────────────────────────────────────┤
│  file            │ 一个打开的文件对应一个 file      │
│  (打开的文件)     │ 包含当前读写位置、文件描述符      │
└─────────────────────────────────────────────────────┘
```

---

## 2. super_block — 文件系统实例

```c
// include/linux/fs.h — super_block
struct super_block {
    struct list_head    s_list;         // 全局超级块链表
    dev_t               s_dev;         // 设备号（如 /dev/sda1）
    unsigned char       s_blocksize_bits;  // 块大小 bits
    unsigned long       s_blocksize;    // 块大小（512/1024/4096）
    loff_t              s_maxbytes;    // 文件最大大小

    /* 文件系统类型 */
    struct file_system_type *s_type;   // ext4 / xfs / ...
    const struct super_operations *s_op; // 文件系统操作函数表
    const struct dquot_operations *dq_op;
    const struct export_operations *s_export_op;

    /* 根目录 inode */
    struct dentry       *s_root;        // 根目录的 dentry

    /* inode 和 dentry 缓存 */
    struct radix_tree_root  s_inode_rwsem;   // inode 读写锁
    struct list_head    s_inodes;      // 所有 inode 链表
    struct list_head    s_dentry_lru;  // dentry LRU 缓存

    /* 挂载信息 */
    struct hlist_head   s_mounts;       // 此 super_block 上的所有挂载
    void               *s_fs_info;     // 文件系统私有数据（ext4_sb_info 等）
    unsigned int        s_iflags;
    u64                 s_time_min;    // 文件时间范围
    u64                 s_time_max;
    u32                 s_time_extra;
};
```

### 2. super_operations — 文件系统操作表

```c
// include/linux/fs.h — super_operations
struct super_operations {
    // inode 操作
    struct inode *(*alloc_inode)(struct super_block *sb);
    void           (*destroy_inode)(struct inode *);

    // 删除和写回
    void           (*put_super)(struct super_block *);  // 卸载时调用
    int            (*sync_fs)(struct super_block *sb, int wait);  // 数据写回
    int            (*freeze_super)(struct super_block *sb);
    int            (*unfreeze_super)(struct super_block *sb);

    // inode 写回
    int            (*write_inode)(struct inode *, struct writeback_control *);
    void           (*evict_inode)(struct inode *);  // 删除 inode 时

    // quota
    int            (*quota_write)(struct super_block *, int, ...)
};
```

---

## 3. inode — 文件元数据

```c
// include/linux/fs.h — inode
struct inode {
    umode_t            i_mode;          // 文件类型 + 权限
    unsigned short      i_opflags;

    kuid_t             i_uid;          // 用户 ID
    kgid_t             i_gid;          // 组 ID
    loff_t             i_size;         // 文件大小

    /* 时间戳 */
    struct timespec64   i_atime;        // 访问时间
    struct timespec64   i_mtime;        // 修改时间
    struct timespec64   i_ctime;        // 改变时间
    struct timespec64   i_btime;        // 创建时间（如果支持）

    unsigned long       i_blocks;       // 文件占用的块数
    unsigned short      i_bytes;        // 最后一个块的已用字节
    blkcnt_t           i_blocksize;    // 块大小
    unsigned char       i_blkbits;

    /* 引用计数 */
    atomic_t            i_count;        // inode 引用计数
    atomic_t            i_dio_count;   // 直接 I/O 计数
    struct list_head    i_lru;         // inode LRU 链表
    struct list_head    i_wb_list;     // writeback 链表

    /* 映射 */
    const struct inode_operations   *i_op;   // inode 操作函数表
    const struct file_operations   *i_fop;  // 默认文件操作
    struct super_block              *i_sb;  // 所属 super_block

    /* 文件锁 */
    struct file_lock_context       *i_flctx;
    struct address_space            *i_data;  // 页缓存映射
    struct list_head                i_pages;  // 页链表

    /* 设备/管道/套接字特殊文件 */
    union {
        struct pipe_inode_info  *i_pipe;
        struct block_device     *i_bdev;
        struct cdev             *i_cdev;
        void                    *i_rdev;
    };

    /* inode 号 */
    unsigned long            i_ino;      // inode 号（在同一文件系统内唯一）
    unsigned int            i_nlink;    // 硬链接 数

    /* 扩展属性 */
    struct mutex            i_mutex;
    unsigned long           i_state;
    unsigned int            i_flags;
};
```

### 3.1 inode_operations — 文件操作

```c
// include/linux/fs.h — inode_operations
struct inode_operations {
    // 创建/删除
    int            (*create)(struct inode *, struct dentry *,
                   umode_t, bool);      // 创建普通文件
    struct dentry *(*lookup)(struct inode *, struct dentry *, unsigned int flags);
    int            (*link)(struct dentry *, struct inode *, struct dentry *);
    int            (*unlink)(struct inode *, struct dentry *);
    int            (*mkdir)(struct inode *, struct dentry *, umode_t);
    int            (*rmdir)(struct inode *, struct dentry *);

    // 符号链接
    int            (*symlink)(struct inode *, struct dentry *, const char *);
    int            (*readlink)(struct dentry *, char __user *, int);

    // 重命名
    int            (*rename)(struct inode *, struct dentry *,
                   struct inode *, struct dentry *, unsigned int);

    // 属性
    int            (*setattr)(struct dentry *, struct iattr *);
    int            (*getattr)(struct mnt_idmap *, const struct path *, ...)
    int            (*permission)(struct inode *, int);
    int            (*setxattr)(struct dentry *, const char *, ...)
    ssize_t        (*getxattr)(struct dentry *, const char *, ...);
};
```

---

## 4. dentry — 目录项缓存

### 4.1 为什么需要 dentry？

```
路径名解析：/a/b/c

每次 open("/a/b/c") 需要：
  1. 查找 /     → 根目录 inode（从 super_block->s_root）
  2. 查找 "a"   → 查 dentry 缓存（命中则跳过 inode lookup）
  3. 查找 "b"   → 同上
  4. 查找 "c"   → 命中 inode

dentry 缓存加速：
  - 相同路径重复访问 → dentry 已缓存，直接命中
  - 内核不需要每次都调用文件系统的 lookup()
```

### 4.2 dentry 结构

```c
// include/linux/dcache.h — dentry
struct dentry {
    /* 硬链接计数 */
    atomic_t d_count;               // 此 dentry 的引用计数
    unsigned int d_flags;           // DCACHE_xxx 标志

    /* dentry 状态 */
    struct inode *d_inode;          // 关联的 inode（可能为 NULL）
    struct dentry *d_parent;        // 父目录

    /* 名称（变长）*/
    struct qstr d_name;             // 文件名

    /* 与同目录其他 dentry 的链接 */
    struct list_head d_child;       // 接入父目录的 d_subdirs
    struct list_head d_subdirs;     // 子目录链表

    /* LRU 链表 */
    struct list_head d_lru;         // 接入 dentry_unused

    /* 哈希链表 */
    struct hlist_node d_hash;       // dentry_hashtable 中的节点
    struct hlist_node d_alias;      // inode->i_dentry 中的节点

    /* 操作函数表 */
    const struct dentry_operations *d_op;

    /* 文件系统私有数据 */
    void *d_fsdata;

    /* 挂载点 */
    struct path d_path;             // 挂载点路径
};
```

### 4.3 dentry 状态机

```
dentry 有三种状态：

1. NEGATIVE（负状态）
   - d_inode = NULL
   - dentry 已分配，但对应的文件已被删除
   - 用途：快速确认文件不存在（避免重复 lookup）

2. POSITIVE（正状态）
   - d_inode != NULL
   - dentry 与文件关联
   - 如果被引用（d_count > 0），不能被回收

3. 第活状态（in use）
   - d_count > 0
   - dentry 被使用，不能从 dcache 移除

dentry LRU 回收：
   - 长时间不用的 dentry 被加入 LRU
   - 内存压力时从 LRU 尾部驱逐
   - 被驱逐前如果 d_inode 改变，需要写回
```

---

## 5. file — 打开的文件

```c
// include/linux/fs.h — file
struct file {
    union {
        struct llist_node   fu_llist;   // 文件链表
        struct rcu_head     fu_rcuhead;  // RCU 释放
    };

    /* 文件描述符信息 */
    struct path            f_path;      // 包含 dentry 和 mnt
    struct inode          *f_inode;    // 关联的 inode
    const struct file_operations *f_op; // 文件操作函数表

    /* 读写状态 */
    loff_t                f_pos;        // 当前文件偏移
    unsigned int          f_flags;      // open() 的 flags
    fmode_t               f_mode;       // open() 的 mode（r/w/x）

    /* 锁 */
    spinlock_t            f_lock;
    struct mutex          f_pos_lock;
    struct fown_struct     f_owner;

    /* I/O */
    struct address_space  *f_mapping;   // 页缓存
    void                 *private_data; // 驱动私有数据

    /* writeback */
    struct writeback_info f_wb_info;
    struct list_head      f_io_list;
};
```

### 5.1 file_operations — 文件操作

```c
// include/linux/fs.h — file_operations
struct file_operations {
    // 读写（最常用）
    ssize_t (*read)(struct file *, char __user *, size_t, loff_t *);
    ssize_t (*write)(struct file *, const char __user *, size_t, loff_t *);

    // 异步 I/O
    ssize_t (*read_iter)(struct kiocb *, struct iov_iter *);
    ssize_t (*write_iter)(struct kiocb *, struct iov_iter *);

    // 目录操作
    int     (*iterate)(struct file *, struct dir_context *);
    int     (*iterate_shared)(struct file *, struct dir_context *);

    // 文件控制
    long    (*unlocked_ioctl)(struct file *, unsigned int, unsigned long);
    long    (*compat_ioctl)(struct file *, unsigned int, unsigned long);

    // mmap
    int     (*mmap)(struct file *, struct vm_area_struct *);

    // 其他
    int     (*open)(struct inode *, struct file *);
    int     (*flush)(struct file *, fl_owner_t id);
    int     (*release)(struct inode *, struct file *);  // close() 时
    loff_t  (*llseek)(struct file *, loff_t, int);
};
```

---

## 6. open() 系统调用路径

```
sys_openat()
  → do_filp_open()
    → path_openat()
      → link_path_walk("/a/b/c", nd)    // 路径解析
      │     ├─ lookup_dcache()           // 先查 dentry 缓存
      │     └─ lookup_real()            // dentry 缓存 miss，调用 inode->i_op->lookup()
      │
      → do_dentry_open()
      │     ├─ 创建新的 struct file
      │     ├─ 打开文件：f->f_op = inode->i_fop
      │     └─ 调用 f->f_op->open(inode, f)
      │
      → fd_install()                      // 安装到当前进程的 fd table
```

---

## 7. 完整文件系统栈

```
用户空间：
  open("/a/b/c", O_RDONLY)

VFS 层：
  sys_openat()
    → do_filp_open()
      → path_openat()
        → link_path_walk()    // dentry 缓存查找
        → lookup_dcache()     // / → a → b → c
        → do_dentry_open()
          → file = alloc_file()
          → file->f_op = inode->i_fop  // ext4_file_operations

ext4 文件系统：
  ext4_file_operations
    .read  = ext4_file_read_iter()
    .write = ext4_file_write_iter()
    .open  = ext4_file_open()

页缓存层：
  address_space (inode->i_data)
    → 缓存文件页到内存
    → ext4_read_folio()
    → ext4_writepages()

块设备层：
  bio → request_queue → block_device
```

---

## 8. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| dentry 缓存 | 避免每次路径解析都调用文件系统 lookup |
| super_block → inode → dentry → file 四层 | 分离关注点：文件系统/文件/路径/打开文件 |
| inode 的 i_fop 和 inode->i_op 分离 | i_op = inode 操作（mkdir 等）/ i_fop = 文件操作（read 等）|
| dentry 三状态 | POSITIVE/NEGATIVE/in-use，优化文件不存在检测 |
| dentry LRU | 缓存驱逐策略，保持热点 dentry |
| private_data | VFS 不感知驱动私有数据，由具体文件系统的 file_operations 使用 |

---

## 9. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/fs.h` | `super_block`、`inode`、`file`、`super_operations`、`inode_operations`、`file_operations` |
| `include/linux/dcache.h` | `dentry` 结构、dentry_operations |
| `fs/dcache.c` | dentry 缓存管理、d_instantiate |
| `fs/namei.c` | 路径解析、link_path_walk、lookup_dcache |
| `fs/open.c` | do_filp_open、do_dentry_open |
