# VFS 抽象层与系统调用桥梁深度分析

<!--
VFS 抽象层与系统调用桥梁深度分析
编号: 241
标签: Linux kernel, VFS, file system, system call
-->

## 1. 概述

VFS（Virtual File System）是 Linux 内核中连接用户态系统调用与具体文件系统的核心抽象层。无论用户执行 `open("/etc/passwd", O_RDONLY)` 还是 `read(fd, buf, 4096)`，都必须经过 VFS 的路径解析、对象绑定与操作分派逻辑。本文以 Linux 7.0-rc1 内核源码为依据，追踪从 `open()` 系统调用到具体文件系统操作的完整调用链，深入解析 dentry 缓存、struct file 与 dentry 的关联、do_dentry_open 的绑定机制，以及 writeback 脏页回写流程。

## 2. 完整调用链 — open("/etc/passwd", O_RDONLY) 的旅程

```
用户态                                       内核态
┌─────────────────┐
│ open(...)       │  →  SYSCALL_DEFINE3(open, ...)   [fs/open.c]
│  O_RDONLY       │     build_open_flags()             构建 open_flags
└─────────────────┘     do_file_open(dfd, filename, &op)
                            │
                       set_nameidata()                设置 nameidata 起点
                            │
                       path_openat(&nd, op, flags | LOOKUP_RCU)
                       ─────────────────────────────────────────────
                       ┌──────────────────────────────────────────┐
                       │  path_openat() [fs/namei.c:4838]          │
                       │                                          │
                       │  1. alloc_empty_file()                   │
                       │     → 分配 struct file，f_flags = O_RDONLY│
                       │                                          │
                       │  2. path_init(nd, flags)                 │
                       │     → 若是绝对路径：从 ND_ROOT 切入       │
                       │     → 若是相对路径：从 current->fs->pwd  │
                       │        读取 vfsmount + dentry            │
                       │     → 开启 RCU 锁（LOOKUP_RCU 模式）      │
                       │     → 返回路径字符串指针（跳过起始'/'）  │
                       │                                          │
                       │  3. link_path_walk(s, nd)      [namei.c] │
                       │     对 /etc/passwd 逐层解析：              │
                       │     "etc"  → lookup_hash(parent dentry)   │
                       │            → dcache hit? 返回缓存 dentry  │
                       │            → dcache miss? inode->i_op->lookup()
                       │     "passwd" → 同上，最终得到目标 dentry │
                       │                                          │
                       │  4. open_last_lookups(nd, file, op)      │
                       │     → lookup_fast_for_open()             │
                       │        尝试 dcache 快速路径命中           │
                       │     → 若 miss：lookup_open()              │
                       │        走 inode->i_op->lookup()           │
                       │                                          │
                       │  5. do_open(nd, file, op)                 │
                       │     → vfs_open(&nd->path, file)           │
                       │                                          │
                       │  6. vfs_open() [fs/open.c]               │
                       │     → file->__f_path = *path              │
                       │     → do_dentry_open(file, NULL)         │
                       │                                          │
                       │  7. do_dentry_open(file, NULL)           │
                       │     → f->f_inode = dentry->d_inode       │
                       │     → f->f_mapping = inode->i_mapping    │
                       │     → f->f_op = fops_get(inode->i_fop)   │
                       │     → open = f->f_op->open               │
                       │        （若存在，调用具体文件系统 hook）  │
                       │     → 设置 FMODE_OPENED                  │
                       └──────────────────────────────────────────┘
                            │
                       回到用户态：fd 返回给进程
```

### 关键数据结构速查

| 结构体 | 所在文件 | 核心作用 |
|--------|----------|----------|
| `struct nameidata` | `fs/namei.c` | 路径解析的上下文容器，含 `path`、`inode`、`flags` |
| `struct path` | `include/linux/path.h` | `(vfsmount *mnt, dentry *dentry)` 的二元组 |
| `struct dentry` | `include/linux/dcache.h` | 目录项缓存条目，对应路径上的一个分量 |
| `struct file` | `include/linux/fs.h:1260` | 已打开文件的内核表示，持有 `f_op`、`f_mapping` |
| `struct inode` | `include/linux/fs.h` | 文件/目录在文件系统内的唯一标识 |
| `struct vfsmount` | `include/linux/mount.h` | 挂载点的视图，一个挂载树 |

## 3. path_lookupat 串联 — 路径解析的每一步

### 3.1 入口：filename_lookup

```c
// fs/namei.c:2830
int filename_lookup(int dfd, struct filename *name, unsigned flags,
                    struct path *path, const struct path *root)
{
    struct nameidata nd;
    set_nameidata(&nd, dfd, name, root);   // 初始化 nd，绑定起始位置
    retval = path_lookupat(&nd, flags | LOOKUP_RCU, path);
    // fallback: -ECHILD → 禁用 RCU 重试   -ESTALE → 加 LOOKUP_REVAL 重试
    audit_inode(name, path->dentry, ...);
    restore_nameidata();
    return retval;
}
```

`filename_lookup` 是路径查找的"安全包装器"：它负责 nameidata 的初始化、RCU 降级 fallback、审计以及清理。**真正的工作在 `path_lookupat`**。

### 3.2 path_lookupat — 两层循环

```c
// fs/namei.c:2797
static int path_lookupat(struct nameidata *nd, unsigned flags, struct path *path)
{
    const char *s = path_init(nd, flags);       // 第一步：初始化
    while (!(err = link_path_walk(s, nd)) &&     // 第二步：逐路径分量遍历
           (s = lookup_last(nd)) != NULL)        // 最后分量单独处理
        ;
    if (!err && unlikely(nd->flags & LOOKUP_MOUNTPOINT))
        err = handle_lookup_down(nd);
    if (!err)
        err = complete_walk(nd);                // 权限检查、symlink 最终解析
    if (!err && (nd->flags & LOOKUP_DIRECTORY))
        if (!d_can_lookup(nd->path.dentry))
            err = -ENOTDIR;
    if (!err) {
        *path = nd->path;                        // 产出：mnt + dentry 二元组
        nd->path.mnt = NULL;
        nd->path.dentry = NULL;
    }
    terminate_walk(nd);                          // 释放 RCU 锁等资源
    return err;
}
```

**三层循环语义**：

1. `path_init`：根据路径类型（绝对/相对）找到搜索起点——要么是进程的当前目录 (`fs->pwd`)，要么是全局 root，要么是 caller 指定的 dfd 对应目录。绝对路径以 `nd_jump_root()` 从 current->fs->root 开始。
2. `link_path_walk`：对**中间分量**（非最后组件）循环解析，处理 symlink 展开、权限检查、hash lookup。每一个分量都是一个 `dentry`，串联在 `nd->path` 上。
3. `lookup_last`（内联于 `open_last_lookups` 的调用方）：处理最后分量，可能需要 O_CREAT 等语义。

### 3.3 link_path_walk — 逐分量解析

```c
// fs/namei.c:2574
static int link_path_walk(const char *name, struct nameidata *nd)
{
    for (;;) {
        // 1. 权限检查 may_lookup()
        err = may_lookup(idmap, nd);
        // 2. hash_name() 提取路径分量（跳过 "/"）
        name = hash_name(nd, name, &lastword);
        // 3. 根据分量类型处理：
        //    - LAST_DOTDOT  → nd_jump_root / parent 切换
        //    - LAST_DOT     → 跳过
        //    - LAST_NORM    → d_hash() + lookup_hash()
        if (!*name)                      // 路径以 "/" 结尾，已到达目标
            goto OK;
        link = walk_component(nd, WALK_MORE); // 尝试解析 symlink
        if (link) {
            // 发现 symlink：压栈，回避递归
            nd->stack[depth++].name = name;
            name = link;                  // 切换到 symlink target 继续
            continue;
        }
        // 4. 确认当前是目录（非最后分量必须是目录）
        if (!d_can_lookup(nd->path.dentry))
            return -ENOTDIR;
    }
}
```

**dentry 与 vfsmount 的串联**：`nd->path` 跟踪当前遍历位置。每一层查找成功后，`nd->path.dentry` 更新为新找到的子 dentry，`nd->path.mnt` 保持不变（同一文件系统内遍历）。当跨越 mount point 时，`handle_lookup_down()` 更新 `nd->path.mnt` 到新的 vfsmount。

### 3.4 路径解析中的 mount 跨越

`handle_lookup_down`（`link_path_walk` 之后调用，或在 `LOOKUP_MOUNTPOINT` flag 下显式调用）负责检测当前 dentry 是否是某个 mount point 的根。若是，则将 `nd->path.mnt` 更新为该 mount 的 vfsmount，同时 `nd->path.dentry` 变为该 mount 的根 dentry。此后，后续的 `lookup_hash` 都会在新文件系统的根下进行。

## 4. dentry 缓存逻辑串联 — 为什么第二次 open 更快

### 4.1 dentry_hashtable 与 LRU 链表

Linux 的 dentry 缓存在 `fs/dcache.c` 中维护两个核心结构：

```c
// fs/dcache.c
static struct hlist_bl_head *dentry_hashtable __ro_after_init;  // hash 桶数组

static DEFINE_PER_CPU(long, nr_dentry_unused);                   // per-CPU 计数
static LIST_HEAD(dentry_unused);                                 // 全局 LRU 链表
```

- **`dentry_hashtable`**：是一个 `hlist_bl_head`（双向链表头）数组，每个桶存储 hash 值相同的 dentry 链表。`d_hash(parent, &qstr)` 驱动 hash 查找，实现 O(1) 理想情况的快速匹配。
- **`dentry_unused`**：双向链表，串联所有处于 "unused" 状态的 positive dentry（对应真实文件的 dentry）。最近访问的 dentry 在链表头部，最老的在尾部。被 shrinker 用于内存压力下的回收。

```c
// 查找：fs/dcache.c
struct dentry *__d_lookup_rcu(const struct dentry *parent,
                              const struct qstr *name, unsigned *seq)
{
    // 1. 计算 qstr hash
    // 2. 在 dentry_hashtable[hash] 链表中 RCU 遍历
    // 3. 比较 parent、name、seq 验证
}
```

### 4.2 同一文件多次 open 为什么快

第一次 `open("/etc/passwd", O_RDONLY)` 时：

1. `link_path_walk` 对 `etc` 调用 `lookup_hash()` → cache miss → 通过 `inode->i_op->lookup()` 从 ext4/xfs 等磁盘读取目录文件，在内存中构造 dentry
2. 对 `passwd` 重复上述过程
3. 两个 dentry 加入 `dentry_hashtable` 对应 hash 桶，加入 `dentry_unused` LRU 链表头部

第二次 `open("/etc/passwd", O_RDONLY)` 时：

1. `lookup_fast_for_open()` 直接调用 `__d_lookup_rcu()`，在 hash 桶中找到已有的 dentry
2. **零次磁盘 I/O**，直接返回
3. dentry 从 `dentry_unused` 链表移到头部（引用计数 +1）

> dentry 缓存加速的本质：**路径遍历中每一层的 hash 查找命中都不需要访问磁盘**。对于深层目录（如 `/usr/local/share/doc/foo.txt`），路径越深，缓存收益越大。

### 4.3 negative dentry

即使文件不存在，内核也会创建 "negative dentry"（`d_inode == NULL`）来缓存 "此路径不存在" 这一信息，避免重复向磁盘发送 lookup 请求。这由 `d_instantiate(dentry, NULL)` 完成。

## 5. struct file 与 struct dentry 的关系

### 5.1 path_openat 是怎么创建 struct file 的

```c
// fs/namei.c:4838
static struct file *path_openat(struct nameidata *nd,
                                const struct open_flags *op, unsigned flags)
{
    struct file *file = alloc_empty_file(op->open_flag, current_cred());
    // ...
    const char *s = path_init(nd, flags);
    while (!(error = link_path_walk(s, nd)) &&
           (s = open_last_lookups(nd, file, op)) != NULL)
        ;
    if (!error)
        error = do_open(nd, file, op);
    terminate_walk(nd);
    // ...
    return file;
}
```

关键：`struct file` 在 `path_openat` 入口处**独立分配**，此时还没有绑定到任何具体的 dentry。`alloc_empty_file` 仅设置 `f_flags`（从 open flags 继承）和引用计数。

### 5.2 file->f_path.dentry 和 file->f_inode 的区别

```c
// include/linux/fs.h:1260
struct file {
    // ...
    union {
        const struct path   f_path;    // VFS 层：mnt + dentry 二元组
        struct path         __f_path;   // 仅在构造阶段可写的视图
    };
    struct inode          *f_inode;    // 指向磁盘 inode 的直接指针
    // ...
    const struct file_operations *f_op; // 来自 inode->i_fop
    struct address_space  *f_mapping;  // 来自 inode->i_mapping
    // ...
};
```

| 字段 | 来源 | 生命周期 |
|------|------|----------|
| `file->f_path.dentry` | `vfs_open()` 时从 path 参数复制 | 持有对 dentry 的引用直到 `fput()` |
| `file->f_inode` | `do_dentry_open()` 中直接从 `f->f_path.dentry->d_inode` 读取 | 与 file 生命周期无关（inode 独立管理） |
| `file->f_op` | `do_dentry_open()` 中从 `inode->i_fop` 获取 | 通过 `fops_get()` 引用 inode 的 fop |

**为什么两个字段都要？**

- `f_path` 保留完整的 mount namespace 上下文——`mnt` 指针使得即使文件系统被 unmount，已打开的 fd 仍然有效（因为 `file` 持有 `vfsmount` 的引用）。
- `f_inode` 是性能优化：不需要每次通过 `f_path.dentry->d_inode` 两步解引用。两者**永远指向同一个 inode**，`f_inode = f_path.dentry->d_inode` 在 `do_dentry_open` 开头完成。

### 5.3 f_mode 和 f_flags 的传递

```
用户态 open_flags
    ↓ build_open_flags()
struct open_flags { open_flag, mode, acc_mode, intent, lookup_flags }
    ↓ do_file_open()
struct file (alloc_empty_file): f_flags = op->open_flag
    ↓ do_dentry_open()
分析 f_flags 推导 f_mode:
    - O_RDONLY        → FMODE_READ
    - O_WRONLY        → FMODE_WRITE
    - O_RDWR          → FMODE_READ | FMODE_WRITE
    - O_PATH          → FMODE_PATH
    - O_CREAT         → 触发 inode_permission + may_create
    ↓
最终 f_mode 包含:
    FMODE_READ / FMODE_WRITE
    FMODE_LSEEK / FMODE_PREAD / FMODE_PWRITE  （根据 inode 类型推断）
    FMODE_OPENED  （do_dentry_open 成功返回后设置）
    FMODE_CAN_READ / FMODE_CAN_WRITE （根据 f_op->read/write 是否存在推断）
```

## 6. do_dentry_open 串联 — 文件系统操作的绑定点

### 6.1 完整流程

```c
// fs/open.c:885
static int do_dentry_open(struct file *f,
                          int (*open)(struct inode *, struct file *))
{
    struct inode *inode = f->f_path.dentry->d_inode;   // 从 dentry 取 inode

    path_get(&f->f_path);
    f->f_inode = inode;
    f->f_mapping = inode->i_mapping;

    // O_PATH 特殊路径：几乎不做任何绑定
    if (unlikely(f->f_flags & O_PATH)) {
        f->f_mode = FMODE_PATH | FMODE_OPENED;
        f->f_op = &empty_fops;
        return 0;
    }

    // 读/写计数
    if ((f->f_mode & (FMODE_READ | FMODE_WRITE)) == FMODE_READ)
        i_readcount_inc(inode);
    else if (f->f_mode & FMODE_WRITE && !special_file(inode->i_mode))
        file_get_write_access(f);

    // 核心：从 inode 拿到文件系统的 operations
    f->f_op = fops_get(inode->i_fop);
    if (WARN_ON(!f->f_op))
        return -ENODEV;

    // 安全检查
    error = security_file_open(f);
    error = fsnotify_open_perm_and_set_mode(f);

    // break_lease（处理文件的 lease/flock）
    error = break_lease(file_inode(f), f->f_flags);

    // 设置默认的 seek/pread/pwrite 能力标志
    f->f_mode |= FMODE_LSEEK | FMODE_PREAD | FMODE_PWRITE;

    // 调用文件系统的 ->open() hook（如果有的话）
    if (!open)
        open = f->f_op->open;
    if (open) {
        error = open(inode, f);
        if (error) goto cleanup_all;
    }

    // 设置已打开标志和各能力位
    f->f_mode |= FMODE_OPENED;
    if (f->f_mode & FMODE_READ && likely(f->f_op->read || f->f_op->read_iter))
        f->f_mode |= FMODE_CAN_READ;
    if (f->f_mode & FMODE_WRITE && likely(f->f_op->write || f->f_op->write_iter))
        f->f_mode |= FMODE_CAN_WRITE;
    if ((f->f_mode & FMODE_LSEEK) && !f->f_op->llseek)
        f->f_mode &= ~FMODE_LSEEK;
    if (f->f_mapping->a_ops && f->f_mapping->a_ops->direct_IO)
        f->f_mode |= FMODE_CAN_ODIRECT;

    return 0;
// cleanup:
    fops_put(f->f_op);
    put_file_access(f);
    path_put(&f->f_path);
}
```

### 6.2 如何根据 dentry 找到 file_operations

```
dentry
  └─ d_inode  ──────────────────────→  struct inode
                                          ├─ i_sb        → super_block
                                          ├─ i_fop       → struct file_operations *
                                          │               (由具体文件系统在 iget() 时填充)
                                          └─ i_mapping  → struct address_space
                                                           ├─ a_ops    → address_space_operations *
                                                           └─ i_pages  → page cache xarray
```

具体文件系统在创建 inode 时填充 `inode->i_fop`：

- ext4: `inode->i_fop = &ext4_file_operations`（定义于 `fs/ext4/file.c`）
- xfs: `inode->i_fop = &xfs_file_operations`（定义于 `fs/xfs/xfs_file.c`）
- procfs: `inode->i_fop = &proc_file_operations`

所以 `do_dentry_open` 的绑定本质是：**从磁盘 inode 取出该文件系统注册的操作函数集**，赋值给 `struct file->f_op`，此后对文件的所有读写操作都通过 `f->f_op->read()` / `f->f_op->write()` 分派到具体文件系统的实现。

### 6.3 nop_mnt_idmap 的使用场景

```c
// include/linux/mnt_idmapping.h
extern struct mnt_idmap nop_mnt_idmap;
```

ID mapping 是用来在容器环境中将容器内的 uid/gid 映射到宿主机的 uid/gid 的机制。`nop_mnt_idmap` 是一个"不做任何映射"的 idmap，所有 `make_vfsuid()` / `mapped_fsuid()` 等函数在此 idmap 下直接返回原值。

**使用场景**：

1. **内核内部文件系统**（如 `shmem`、`devpts`、`proc`）在不需要用户命名空间映射时直接使用 `nop_mnt_idmap`
2. **O_PATH 打开的文件**：`do_dentry_open` 中 `mnt_idmap(path->mnt)` 返回实际 mount 的 idmap，但某些内部操作使用 `nop_mnt_idmap` 避免不必要的安全上下文字符串构造
3. **只读 mount 或没有 user namespace 支持的文件系统**：在内核代码中看到 `nop_mnt_idmap` 常作为"这个操作不涉及用户 ID 映射"的显式标记

## 7. VFS 和具体文件系统的边界

### 7.1 抽象层提供的核心结构

```
VFS 抽象层
  │
  ├── struct super_block    → 文件系统实例的元信息（块设备、挂载选项、根 dentry）
  ├── struct inode         → 磁盘 inode 的内核表示（唯一标识 + 操作集）
  ├── struct dentry         → 路径分量的缓存（name → inode 的映射）
  ├── struct file           → 进程打开的文件的内核表示（文件描述符的背面）
  ├── struct file_operations → inode 级操作集（open/read/write/ioctl...）
  ├── struct address_space  → inode 的页缓存（dirty pages 的管理）
  └── struct address_space_operations → 块 I/O 操作集（read_folio/writepages...）
```

### 7.2 ext4_file_operations vs xfs_file_operations — VFS 视角下的区别

从 VFS 往下看，这两个结构体分别是什么：

```c
// VFS 视角看到的 ext4
const struct file_operations ext4_file_operations = {
    .llseek     = ext4_llseek,        // 重写了 llseek 行为（支持 extent）
    .read_iter  = ext4_read_iter,    // 使用 iomap 读路径
    .write_iter = ext4_write_iter,
    .iopoll     = iopoll,            // io_uring 支持
    .unlocked_ioctl = ext4_ioctl,
    .mmap       = ext4_file_mmap,    // 文件映射
    .open       = ext4_file_open,    // 设置 ext4 特有的文件信息
    .fsync      = ext4_sync_file,
};
```

```c
// VFS 视角看到的 xfs
const struct file_operations xfs_file_operations = {
    .llseek     = xfs_file_dio_llseek,   // 支持 Direct I/O 的特殊 llseek
    .read_iter  = xfs_file_read_iter,    // XFS 特有的读路径（支持 reflink）
    .write_iter = xfs_file_write_iter,   // 延迟分配、实时 extents
    .iopoll     = iopoll,
    .unlocked_ioctl = xfs_file_ioctl,
    .mmap       = xfs_file_mmap,
    .open       = xfs_file_open,         // XFS 特有
    .fsync      = xfs_file_fsync,
    .flock      = xfs_file_flock,        // XFS 有自己的 flock 实现
};
```

**VFS 视角下的本质区别**：

- **相同的 VFS 接口，不同的实现策略**：两者都实现了 `read_iter` / `write_iter`，但 ext4 使用 iomap 框架，XFS 有自己的 dio（延迟分配、实时 extent）逻辑
- **llseek 行为不同**：ext4 可以 seek 到任意位置，XFS Direct I/O 的 llseek 需要特殊处理
- **fsync 语义不同**：ext4 的 journal commit vs XFS 的 log I/O
- **mmap 行为不同**：ext4 的 page cache vs XFS 的 cluster/extent 预读策略

**关键**：VFS 通过 `struct file` 的 `f_op` 接口对上层（系统调用层）完全屏蔽了这些差异。对用户态来说，`read(fd, buf, n)` 的行为是统一的，即使底层是 ext4 的 iomap 还是 XFS 的自定义 dio。

### 7.3 inode_operations — 目录级操作

与 `file_operations`（文件内容操作）并列，`inode_operations` 处理目录级语义：

```c
struct inode_operations {
    int (*create)(struct mnt_idmap *, struct dentry *,
                  umode_t, bool);          // mknod / creat
    struct dentry *(*lookup)(struct inode *, struct dentry *); // 目录查找
    int (*link)(struct dentry *, struct dentry *, struct dentry *); // link()
    int (*unlink)(struct inode *, struct dentry *);
    int (*mkdir)(struct inode *, struct dentry *, umode_t);
    int (*rmdir)(struct inode *, struct dentry *);
    int (*rename)(struct inode *, struct dentry *,
                   struct inode *, struct dentry *, unsigned int);
    // ...
};
```

`link_path_walk` 中每层目录的查找（`lookup_hash` → `inode->i_op->lookup()`）就是通过这个接口分派的。

## 8. writeback 机制 — 脏页如何流回磁盘

### 8.1 address_space 与脏页管理

每个 inode 持有一个 `struct address_space`，管理该文件的所有缓存页：

```c
// include/linux/fs.h:473
struct address_space {
    struct inode     *host;               // 所属 inode
    struct xarray     i_pages;            // 所有缓存页（page cache）
    struct rw_semaphore invalidate_lock;
    struct rb_root_cached i_mmap;         // 所有映射区域（mmap 用）
    const struct address_space_operations *a_ops;
    // ...
};
```

`address_space_operations` 提供了文件系统无关的接口：

```c
struct address_space_operations {
    int (*read_folio)(struct file *, struct folio *);
    int (*writepages)(struct address_space *, struct writeback_control *);
    bool (*dirty_folio)(struct address_space *, struct folio *);
    int (*write_begin)(const struct kiocb *, struct address_space *, ...);
    int (*write_end)(const struct kiocb *, struct address_space *, ...);
    int (*direct_IO)(struct kiocb *, struct iov_iter *);
    // ...
};
```

### 8.2 writeback_control

```c
struct writeback_control {
    long                  nr_to_write;    // 本轮要写多少页
    long                  pages_skipped;  // 跳过（被等其他 writeback）页数
    enum writeback_sync_modes sync_mode:2; // 同步模式
    // ...
    struct wb_writeback_work *reason;     // 触发来源
};
```

`writeback_control` 在 `writeback_inodes_sb()` / `wb_writeback()` / `write_inode()` 等函数间传递，协调批量写回的行为。

### 8.3 pdflush/page-writeback 的演进

历史上 Linux 使用 `pdflush` 线程池（2-8 个动态创建的线程）来执行写回。后来演变为以 **per-bdi writeback**（`struct bdi_writeback`，每个 backing_dev_info 一个）为核心的架构：

```
触发源                      writeback_work enqueue
──────────────────────────────────────────────────────────
1. 定时 flusher 线程  ──→  wb_writeback_work() ──→  writeback_inodes_sb()
2. sync(2) / fsync(2)  ─→  writeback_inodes_sb() ──→  __writeback_single_inode()
3. 内存压力（shrink） ──→  prune_dcache_sb() ──→  direct commit
4. 用户手动 sync(2)  ──→  wakeup_flusher_threads() ──→ wb_writeback_work()
```

现在的 `wb_writeback_work` 由 `bdi_split_work_to_wbs()` 分发到每个 `bdi_writeback`（每个磁盘一个），在各自的 flusher 线程中执行。pdflush 已完全废除。

### 8.4 脏页回写的完整路径

```
用户 write(fd, buf, n)
    ↓
generic_perform_write() [fs/libfs.c]
    ↓ (write_begin / write_end)
文件系统 address_space_operations::write_begin()
    ↓ (mark folio dirty via set_page_dirty / folio_mark_dirty)
    ↓
folio 加入 address_space::i_pages (xa_marked DIRTY)
    ↓ (通过 /proc/sys/vm/dirty_writeback_centisecs 定时器)
wakeup_flusher_threads()
    ↓
wb_writeback_work enqueue
    ↓
bdi_writeback 线程获取 work
    ↓
writeback_inodes_sb() 遍历 sb 所有 inode
    ↓
__writeback_single_inode(inode, wbc)
    ↓
do_writepages()  →  inode->i_mapping->a_ops->writepages()
    ↓ (ext4: ext4_writepages() 使用 iomap_writepages())
    ↓ (xfs:  xfs_vm_writepages())
    ↓
writepages() 调用 iomap_writepage() 或 buffer_heads
    ↓
submit_bh() / bio_submit() → 块设备层
    ↓
磁盘控制器驱动 → 写入磁盘
```

### 8.5 脏页与 inode 的关系

```
struct inode {
    struct address_space  *i_mapping;   // → inode 的主页缓存（匿名映射页）
    struct address_space   i_data;       // 某些文件系统的块设备 mapping
    // ...
}
struct address_space {
    struct xarray   i_pages;             // 所有缓存的 folio
    // ...
    XA_MARK_0 = DIRTY                    // 标记为脏
    XA_MARK_1 = WRITEBACK                // 正在写回
    XA_MARK_2 = TOWRITE                  // 即将写回
}
```

一个 folio 被 `folio_mark_dirty()` 后，xa 标记 `PAGECACHE_TAG_DIRTY`（即 `XA_MARK_0`）。`writeback_single_inode()` 在遍历时查询此标记决定是否需要写回。

## 9. 数据结构关系总图

```
                         用户进程
                        struct files_struct *files
                              │
                              ▼
                     ┌─────────────────┐
                     │  fd 指向 file*  │
                     └────────┬────────┘
                              │
                              ▼
          ┌───────────────────────────────────────┐
          │           struct file                 │
          │  f_path = { mnt, dentry }             │
          │  f_inode = dentry->d_inode            │
          │  f_op    = inode->i_fop               │
          │  f_mapping = inode->i_mapping         │
          │  f_mode / f_flags / f_pos             │
          └───────────────────┬───────────────────┘
                              │
          ┌───────────────────┴───────────────────┐
          │  struct path                          │
          │  .mnt ──→ struct vfsmount (mount点)    │
          │  .dentry ──→ struct dentry            │
          └───────────────────┬───────────────────┘
                              │
          ┌───────────────────┴───────────────────┐
          │  struct dentry                       │
          │  d_inode ──→ struct inode            │
          │  d_parent ──→ 父 dentry               │
          │  d_hash ──→ dentry_hashtable[hash]   │
          │  d_lru ──→ dentry_unused LRU链表     │
          │  d_sb ──→ struct super_block         │
          └───────────────────┬───────────────────┘
                              │
          ┌───────────────────┴───────────────────┐
          │  struct inode                        │
          │  i_fop ──→ struct file_operations    │
          │  i_op  ──→ struct inode_operations   │
          │  i_mapping ──→ struct address_space  │
          │  i_sb  ──→ struct super_block        │
          └───────────────────┬───────────────────┘
                              │
          ┌───────────────────┴───────────────────┐
          │  struct super_block                  │
          │  s_op   ──→ struct super_operations   │
          │  s_fs_info ──→ 文件系统私有数据       │
          │  s_root ──→ 根 dentry                │
          └───────────────────────────────────────┘

          具体文件系统（ext4 / xfs / btrfs ...）
          实现 file_operations、inode_operations、address_space_operations
          在 VFS 的框架内填充各自的函数指针
```

## 10. 小结

VFS 层是 Linux 文件系统架构的"适配器模式"教科书实现：

1. **`filename_lookup` → `path_lookupat` → `link_path_walk`** 构成了完整的路径解析流水线，通过 `nameidata` 维护上下文，每层查找优先命中 dentry 缓存
2. **dentry 缓存**是路径解析性能的关键——`dentry_hashtable` 提供 O(1) hash 查找，`dentry_unused` LRU 链配合 shrinker 实现有管理的缓存淘汰
3. **`struct file` 在 `path_openat` 中分配**，在 `do_dentry_open` 中通过 `inode->i_fop` 绑定到具体文件系统的操作集；`f_path` 保留 mount 命名空间上下文，`f_inode` 提供直接访问
4. **writeback 由 per-bdi flusher 线程驱动**，通过 `writeback_control` 协调，脏页通过 `address_space_operations` 接口回写到块设备

理解这套机制，就能看清 Linux 中"一切皆文件"背后的真正工程价值：**统一的系统调用接口 + 灵活的文件系统插入机制 + 高效的缓存层**，三者缺一不可。