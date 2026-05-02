# vfs_deep — VFS 抽象层与系统调用桥梁深度分析

## 1. 从 open() 系统调用到具体文件系统的完整调用链

```
用户空间: open("/etc/passwd", O_RDONLY)
          │
          ▼
SYSCALL_DEFINE3(open)          [fs/open.c:1374]
  → do_sys_open()              [fs/open.c:1367]
    → do_sys_openat2()          [fs/open.c:1355]
      → build_open_flags()      构建 open_flags
      → do_file_open()          [fs/namei.c:4867]
          │
          ▼
    filename_lookup()            [fs/namei.c:2830]
      → set_nameidata()
      → path_lookupat()          [fs/namei.c:2797]
          │                      (RCU 模式优先)
          ▼
      link_path_walk()           [fs/namei.c:2574]
        path_init()              初始化 nd->path
        循环: 解析每一层路径分量
        lookup_hash()            查 dentry hash 表
        follow_symlink()         处理符号链接
          │
          ▼
      complete_walk()            完成路径解析，验证最终 dentry
      返回: struct path { dentry, vfsmount }
          │
          ▼
    path_openat()                [fs/namei.c:4838]
      alloc_empty_file()         分配 struct file
      path_init()                重新初始化（重走路径解析）
      link_path_walk()           解析到最后一层
      open_last_lookups()        处理 open 特有的 lookup
      do_open()                  [fs/namei.c:4655]
          │
          ▼
      vfs_open()                 [fs/open.c:1074]
        → do_dentry_open()       [fs/open.c:885]
          │                      ★ 关键: 绑定 file 到具体 fs
          ▼
      [具体文件系统: ext4_file_operations.open /
                    xfs_file_operations.open]
```

## 2. path_lookupat 串联：open("/etc/passwd", O_RDONLY) 完整路径解析

### 2.1 调用链总览

```
filename_lookup(AT_FDCWD, "/etc/passwd", flags, &path, NULL)
  ├─ set_nameidata(&nd, AT_FDCWD, filename, NULL)
  ├─ path_lookupat(&nd, flags | LOOKUP_RCU, path)  ← 首次尝试 RCU
  │     ├─ path_init(nd, flags)        → 设置 nd->path = { current->fs->pwd, root }
  │     │                               处理绝对/相对路径，区分 ROOT/PARENT/DOTDOT
  │     ├─ link_path_walk("/etc/passwd", nd)      ← 核心解析循环
  │     │     ├─ 遇到 "/" → 跳过，连续 "/" 只算一个
  │     │     ├─ 解析第一分量 "etc" → hash_name() 计算 qstr
  │     │     ├─ lookup_hash(parent, &name)       查 dentry_hashtable
  │     │     │     └─ d_lookup(parent, &name)    先查 DCACHE_OP_HASH
  │     │     │         └─ 命中 → 验证 seq
  │     │     │         └─ 未命中 → ->lookup() 回调具体 fs
  │     │     ├─ follow_one_link()   处理符号链接（嵌套跟踪）
  │     │     ├─ 解析第二分量 "passwd"
  │     │     ├─ lookup_hash(dir, &name)
  │     │     └─ 若 "." 或 ".." → 特殊处理
  │     ├─ lookup_last(nd)           最后分量特殊处理（可不查找）
  │     ├─ complete_walk(nd)        RCU unlock + 权限验证 + 重解析
  │     └─ *path = nd->path          返回 { dentry, mnt }
  │
  ├─ if (-ECHILD) retry without RCU
  ├─ if (-ESTALE) retry with LOOKUP_REVAL
  └─ audit_inode(name, path->dentry, 0)
```

### 2.2 link_path_walk 内部循环

```c
// fs/namei.c:2574
static int link_path_walk(const char *name, struct nameidata *nd)
{
    for(;;) {
        // 1. 权限检查
        err = may_lookup(idmap, nd);

        // 2. 计算分量 hash
        nd->last.name = name;
        name = hash_name(nd, name, &lastword);

        // 3. 处理 DOTDOT / DOT / 普通分量
        switch(lastword) {
        case LAST_WORD_IS_DOTDOT: nd->last_type = LAST_DOTDOT; break;
        case LAST_WORD_IS_DOT:    nd->last_type = LAST_DOT;    break;
        default:
            nd->last_type = LAST_NORM;
            // 调用 DCACHE_OP_HASH（若有）做特殊 hash
            if (parent->d_flags & DCACHE_OP_HASH)
                parent->d_op->d_hash(parent, &nd->last);
        }

        // 4. 若已无更多分量，跳出
        if (!*name) goto OK;

        // 5. 查 dentry（先 d_lookup 缓存，未命中调 ->lookup）
        dentry = lookup_hash(parent, &nd->last);

        // 6. 符号链接跟踪
        if (d_is_symlink(dentry))
            err = follow_link(&dentry, nd);

        // 7. 更新 parent = 当前 dentry，继续循环
        parent = dentry;
    }
OK:
    // 处理最终分量
}
```

### 2.3 dentry 和 vfsmount 的串联关系

```
struct path {
    struct vfsmount *mnt;    ← 挂载点命名空间
    struct dentry  *dentry;  ← 目录项（指向 inode）
}
```

- **dentry** 是路径中每一个分量的"目录项缓存对象"，包含：
  - `d_inode`：指向该分量对应的 inode
  - `d_parent`：指向父目录 dentry（构成树结构）
  - `d_flags`：缓存操作标志（DCACHE_OP_HASH、DCACHE_OP_COMPARE 等）
  - `d_hash`：缓存的 hash 链（用于加速同目录查找）

- **vfsmount** 代表一个挂载点，所有从同一挂载点出发的路径共享同一个 mnt
- 跨文件系统访问（如 `/mnt/tmp/file`）时，`path->mnt` 发生变化但 `dentry` 仍指向该mnt根下的子树

### 2.4 RCU 路径解析的退化机制

```c
int filename_lookup(int dfd, struct filename *name, unsigned flags,
                    struct path *path, const struct path *root)
{
    set_nameidata(&nd, dfd, name, root);
    retval = path_lookupat(&nd, flags | LOOKUP_RCU, path);  // 快速路径
    if (unlikely(retval == -ECHILD))                      // RCU 冲突
        retval = path_lookupat(&nd, flags, path);         // 退到 Blocking
    if (unlikely(retval == -ESTALE))                       // dentry 失效
        retval = path_lookupat(&nd, flags | LOOKUP_REVAL, path);
    ...
}
```

RCU 模式不使用锁，通过 seqcount 验证 dentry 有效性；冲突时整体退化为 Blocking 模式。

## 3. dentry 缓存逻辑：为何 open 第二次很快

### 3.1 dentry_hashtable 与 dentry_unused 的关系

```
dentry_hashtable [哈希表]
  ├─ slot[hash("/etc")] → [ dentry("/etc"), dentry("/etc") ... ]
  │                           ↓
  │                       串成 hlist（冲突链）
  └─ slot[hash("/var")] → [ dentry("/var") ]

dentry_unused [双向链表，LRU 队列]
  所有 "未在使用"（d_flags = DCACHE_LRU_LIST）的 dentry 按最近访问排序
  │recently used│←←←LRU←←←←│older│
```

**关键数据结构**（dcache.c）：

```c
// 全局哈希表，size = dentry_hashtable_size
static struct hlist_bl_head *dentry_hashtable;

// 每个 CPU 的未使用 dentry 计数（用于快速判断 shrink 时机）
static DEFINE_PER_CPU(long, nr_dentry_unused);

// 实际 LRU 链表头
static struct list_head dentry_unused[NR_LRU_LISTS];
```

### 3.2 加速原理：缓存命中减少文件系统 lookup

```
第一次 open("/etc/passwd"):
  link_path_walk("etc")
    lookup_hash("/")             → 查 dentry_hashtable → 未命中
      → ext4_lookup()            → 磁盘 I/O，读 inode
      → d_add(dentry, inode)    → 加入 hashtable + dentry_unused LRU
  link_path_walk("passwd")
    lookup_hash("/etc")          → 查 hashtable → 未命中
      → ext4_lookup()            → 磁盘 I/O
      → d_add(dentry, inode)

第二次 open("/etc/passwd"):
  link_path_walk("etc")
    lookup_hash("/")             → hashtable 命中！
      → d_lookup()               → 验证 seq（RCU 模式）
      → 命中！返回已有 dentry     ★ 完全跳过 ext4_lookup()
  link_path_walk("passwd")
    lookup_hash("/etc")          → hashtable 命中！
      → 命中！                   ★ 第二次也跳过了磁盘 I/O

结论：dentry_hashtable 按 {parent, name} 做哈希，同一路径第二次命中率极高
```

### 3.3 hashtable 查找 vs 磁盘 I/O 的性能差距

| 操作 | 耗时 |
|------|------|
| 内存 hashtable 查找 | ~10-50 ns |
| ext4_lookup()（磁盘读 inode） | ~0.5-5 ms（SSD） / ~10-30 ms（HDD） |
| ext4_lookup() + 目录缓冲未命中 | ~10-50 ms（HDD 寻道） |

**差距：4~6 个数量级**。这就是为何 `open("/etc/passwd")` 第一次几毫秒、第二次几纳秒。

### 3.4 LRU 回收机制

```c
// dcache shrink 时，从 dentry_unused 尾部驱逐
static void prune_dcache_sb(struct super_block *sb, struct shrink_control *sc)
{
    while (sc->nr_to_scan--) {
        dentry = list_entry(dentry_unused.prev, struct dentry, d_lru);
        list_del_init(&dentry->d_lru);
        // 调用 d_iput() 释放（若计数为 0）
        shrink_dentry_list(&dispose);
    }
}
```

## 4. struct file 和 struct dentry 的关系

### 4.1 struct file 的核心字段

```c
struct file {
    fmode_t                 f_mode;       // FREAD | FWRITE 等
    const struct file_operations *f_op;   // ★ 操作函数表（来自 inode）
    struct address_space    *f_mapping;   // 页缓存 address_space
    struct inode            *f_inode;     // 指向 inode（不是从 dentry 派生）
    unsigned int            f_flags;       // O_RDONLY | O_WRONLY 等

    union {
        const struct path   f_path;        // ★ 来自 path（mnt + dentry）
        struct path         __f_path;
    };
    loff_t                  f_pos;         // 当前文件偏移
    void                   *private_data; // 文件句柄私有数据
    ...
}
```

### 4.2 path_openat 如何创建 struct file

```c
// fs/namei.c:4838
static struct file *path_openat(struct nameidata *nd,
                                const struct open_flags *op, unsigned flags)
{
    // 1. 分配一个空的 struct file
    file = alloc_empty_file(op->open_flag, current_cred());
    if (IS_ERR(file))
        return file;

    // 2. O_PATH 和 O_TMPFILE 特殊处理
    if (unlikely(file->f_flags & __O_TMPFILE)) ...
    else if (unlikely(file->f_flags & O_PATH)) ...

    // 3. 重走路径解析（path_openat 会再次调用 path_init + link_path_walk）
    const char *s = path_init(nd, flags);
    while (!(error = link_path_walk(s, nd)) &&
           (s = open_last_lookups(nd, file, op)) != NULL)
        ;

    // 4. 执行最终打开
    if (!error)
        error = do_open(nd, file, op);

    terminate_walk(nd);
    return file;
}
```

### 4.3 f_path.dentry 和 f_inode 的区别

```
struct file {
    union {
        const struct path f_path;   // 路径信息：{ mnt, dentry }
        struct path       __f_path;
    };
    struct inode *f_inode;          // 直接指向 inode
}
```

| 字段 | 来源 | 用途 |
|------|------|------|
| `f_path.dentry` | path_lookupat 返回 | 用于 VFS 层操作（权限检查、路径展示、dnotify） |
| `f_inode` | `f_path.dentry->d_inode` | 用于获取 `f_op`，直接 I/O 操作 |

**两者在 `do_dentry_open` 中被同时赋值**：

```c
// fs/open.c:895
static int do_dentry_open(struct file *f, ...)
{
    struct inode *inode = f->f_path.dentry->d_inode;

    f->f_inode = inode;             // 派生自 dentry
    f->f_mapping = inode->i_mapping; // 也来自 inode

    f->f_op = fops_get(inode->i_fop); // ★ 从 inode 获取文件系统操作函数表
    ...
}
```

### 4.4 f_mode 和 f_flags 的传递路径

```
用户: open("/etc/passwd", O_RDONLY)
       ↓
SYSCALL_DEFINE3(open)
  → do_sys_open() → do_sys_openat2()
      → build_open_flags()          将 flags 转换为 open_flag + acc_mode
      → do_file_open()
          → path_openat()
              → do_open(nd, file, op)
                  → vfs_open(&nd->path, file)
                      → do_dentry_open(file, NULL)
                          ↓
                          // f->f_flags = file->f_flags（来自 alloc_empty_file）
                          // f->f_mode 从 alloc_empty_file(op->open_flag, ...) 设置
```

```c
// fs/open.c:4855
static struct file *path_openat(...)
{
    file = alloc_empty_file(op->open_flag, current_cred());  // ← f_flags 在此设置
    ...
    error = do_open(nd, file, op);
}

// do_dentry_open 中根据 f_flags 决定读/写权限
if ((f->f_mode & (FMODE_READ | FMODE_WRITE)) == FMODE_READ)
    i_readcount_inc(inode);        // 记录 inode 读取计数
else if (f->f_mode & FMODE_WRITE && !special_file(inode->i_mode))
    file_get_write_access(f);
```

## 5. do_dentry_open：file 与具体文件系统绑定

### 5.1 完整流程

```c
// fs/open.c:885
static int do_dentry_open(struct file *f,
                          int (*open)(struct inode *, struct file *))
{
    struct inode *inode = f->f_path.dentry->d_inode;

    // 1. 增加路径引用
    path_get(&f->f_path);

    // 2. 建立 file ↔ inode 的双向关联
    f->f_inode = inode;
    f->f_mapping = inode->i_mapping;

    // 3. O_PATH 快速路径（不需要真正的文件系统操作）
    if (unlikely(f->f_flags & O_PATH)) {
        f->f_mode = FMODE_PATH | FMODE_OPENED;
        f->f_op = &empty_fops;
        return 0;
    }

    // 4. 读计数管理
    if ((f->f_mode & (FMODE_READ | FMODE_WRITE)) == FMODE_READ) {
        i_readcount_inc(inode);
    } else if (f->f_mode & FMODE_WRITE && !special_file(inode->i_mode)) {
        error = file_get_write_access(f);
        if (unlikely(error)) goto cleanup_file;
        f->f_mode |= FMODE_WRITER;
    }

    // 5. ★ 关键步骤：从 inode 获取文件操作函数表
    f->f_op = fops_get(inode->i_fop);
    if (WARN_ON(!f->f_op)) { error = -ENODEV; goto cleanup_all; }

    // 6. 安全检查
    error = security_file_open(f);         // SELinux / AppArmor
    if (unlikely(error)) goto cleanup_all;

    error = fsnotify_open_perm_and_set_mode(f);
    if (unlikely(error)) goto cleanup_all;

    error = break_lease(file_inode(f), f->f_flags);
    if (unlikely(error)) goto cleanup_all;

    // 7. 设置默认操作标志
    f->f_mode |= FMODE_LSEEK | FMODE_PREAD | FMODE_PWRITE;

    // 8. 调用文件系统的 ->open()（若无自定义则用 f_op->open）
    if (!open)
        open = f->f_op->open;
    if (open) {
        error = open(inode, f);
        if (error) goto cleanup_all;
    }

    // 9. 设置读写能力标志
    f->f_mode |= FMODE_OPENED;
    if ((f->f_mode & FMODE_READ) &&
        likely(f->f_op->read || f->f_op->read_iter))
        f->f_mode |= FMODE_CAN_READ;
    if ((f->f_mode & FMODE_WRITE) &&
        likely(f->f_op->write || f->f_op->write_iter))
        f->f_mode |= FMODE_CAN_WRITE;
    ...
}
```

### 5.2 inode → file_operations 的查找链

```
struct inode {
    const struct inode_operations *i_op;   // inode 级别操作（create/unlink/mkdir等）
    const struct file_operations  *i_fop;  // ★ 文件操作函数表
    struct super_block            *i_sb;    // 指向超级块
}

struct super_block {
    struct file_system_type   *s_type;      // 文件系统类型 (ext4/xfs/btrfs)
    const struct super_operations *s_op;    // 超级块操作
}
```

**inode->i_fop 的来源**：
1. 目录项被解析时，`ext4_lookup()` / `xfs_lookup()` 找到 inode 后，设置 `inode->i_fop`
2. 不同文件类型可能有不同的 fop（例如：ext4_file_operations 用于常规文件，ext4_dir_file_operations 用于目录）

```c
// ext4 中设置 i_fop 示例
ext4_new_inode_start_handle()
  → inode->i_fop = &ext4_file_operations;  // 常规文件

// 目录则用
inode->i_fop = &ext4_dir_file_operations;
```

## 6. VFS 和具体文件系统的分层边界

### 6.1 核心抽象结构

```
┌────────────────────────────────────────────────────────────────────┐
│                         用户空间进程                                 │
│                    open() / read() / write()                       │
└────────────────────────────┬─────────────────────────────────────┘
                             ▼
┌────────────────────────────────────────────────────────────────────┐
│  SYSCALL 层 (fs/open.c, fs/read_write.c)                           │
│  __arm64_sys_open → do_sys_open → do_file_open                    │
│  __arm64_sys_read  → ksys_read → do_sys_read_...                  │
└────────────────────────────┬─────────────────────────────────────┘
                             ▼
┌────────────────────────────────────────────────────────────────────┐
│  VFS 核心层 (fs/namei.c, fs/open.c, fs/internal.h)                  │
│                                                                    │
│  path_lookupat() / link_path_walk()    ← 路径解析，dentry 管理      │
│  do_dentry_open()                      ← file 与 fs 绑定            │
│  vfs_open() / vfs_read() / vfs_write() ← 文件操作 dispatch         │
│                                                                    │
│  关键数据结构：                                                      │
│    struct file    { f_op, f_path, f_mode, f_flags }                │
│    struct path    { mnt, dentry }                                  │
│    struct dentry  { d_inode, d_parent, d_hash, d_op }             │
│    struct inode   { i_fop, i_op, i_mapping, i_sb }                 │
│    struct super_block { s_type, s_op, s_root }                     │
└────────────────────────────┬─────────────────────────────────────┘
                             ▼
┌────────────────────────────────────────────────────────────────────┐
│  具体文件系统实现                                                   │
│                                                                    │
│  ext4:                                                            │
│    ext4_file_operations { .open=ext4_file_open,                    │
│                            .read=ext4_file_read_iter,             │
│                            .write=ext4_file_write_iter,            │
│                            .mmap=ext4_file_mmap }                 │
│                                                                    │
│  xfs:                                                             │
│    xfs_file_operations  { .open=xfs_file_open,                      │
│                            .read=xfs_file_read_iter,               │
│                            .write=xfs_file_write_iter,            │
│                            .mmap=xfs_file_mmap }                  │
│                                                                    │
│  btrfs:                                                           │
│    btrfs_file_operations { ... }                                   │
└────────────────────────────────────────────────────────────────────┘
```

### 6.2 ext4_read_iter vs xfs_file_read_iter（VFS 视角）

**相同点（VFS 看到的一致性）**：

两者都实现 `ssize_t (*read_iter)(struct kiocb *, struct iov_iter *)`，接受 kiocb 和 iov_iter。VFS 通过统一的 `file->f_op->read_iter` 调用，无论底层是 ext4 还是 xfs。

```c
// VFS 统一调用路径（fs/read_write.c）
ssize_t __kernel_read_iter(struct file *file, struct iov_iter *iter)
{
    if (file->f_op->read_iter)
        ret = file->f_op->read_iter(iocb, iter);
    else if (file->f_op->read)
        ret = file->f_op->read(file, buf, len, &file->f_pos);
}
```

**不同点（VFS 看不到的实现差异）**：

| 方面 | ext4_file_read_iter | xfs_file_read_iter |
|------|---------------------|-------------------|
| I/O 路径 | ext4 直接 I/O 或 ext4_dax_read_iter（Dax） | xfs_dax_read_iter |
| 块分配 | ext4_map_blocks()（延迟分配 + extent） | xfs_bmapi()（延迟分配） |
| 页缓存 | filemap_read() → do_generic_file_read() | 同上（共享通用路径） |
| 锁粒度 | inode->i_rwmutex | xfs inode ilock（读写分离） |
| 日志 | 读操作不记录日志 | 同上（读不记日志） |

**VFS 视角的抽象**：对 VFS 而言，`read_iter` 函数指针可以指向任何实现，只要签名为 `ssize_t (*read_iter)(struct kiocb *, struct iov_iter *)`。ext4 和 xfs 的内部逻辑完全封装在各自的实现中。

### 6.3 分层原则

1. **VFS 负责"是什么"（What）**：路径解析、权限检查、file/dentry/inode 管理、操作分发
2. **文件系统负责"怎么做"（How）**：块寻址、extent 管理、日志、缓存策略

```
open() 用户语义
    ↓
VFS: "找到这个路径对应的 inode，创建一个 file 对象"      ← 通用协议
    ↓
具体 fs: "根据我的磁盘布局，找到这个文件的物理块"          ← 各不相同
```

## 7. Writeback 机制：脏页如何写回磁盘

### 7.1 数据结构串联

```
struct inode {
    struct address_space    i_mapping;    ← 所有页缓存页归于 inode
    struct address_space_operations *i_aops;
}

struct address_space {
    const struct address_space_operations *a_ops;  ← writepage/writepages
    struct radix_tree_root  page_tree;    ← 缓存页的 radix tree
    struct backing_dev_info *backing_dev_info;
    pgoff_t                 writeback_index; // writeback 继续位置
    ...
}

struct writeback_control {
    long     nr_to_write;         ← 本次需写多少页
    loff_t   range_start/end;     ← 限定字节范围
    enum writeback_sync_modes sync_mode;  ← WB_SYNC_ALL（同步）/ WB_SYNC_NONE
    unsigned for_background:1;    ← 后台刷脏
    unsigned for_sync:1;          ← sync(2) 触发
    ...
}
```

### 7.2 完整调用链

```
用户 write()
  → file->f_op->write_iter()      (ext4_file_write_iter / xfs_file_write_iter)
    → ext4_dio_write_iter() / xfs_file_write_iter()
      → iomap_write_iter()
        → generic_perform_write()        [fs/iov_iter.c]
          → address_space_operations.write_begin()  分配页
          → copy_from_user()             拷贝数据
          → address_space_operations.write_end()     标记脏页

[页变为脏，加入 address_space 的 radix tree，置 PG_dirty]
```

**触发 writeback 的路径**：

```
路径 A: 用户主动调用 fsync() / sync()
  → do_sys_sync()
    → iterates super_blocks
      → sync_filesystem()
        → writeback_sb_inodes()         ← 遍历该 sb 所有 inode
            → __writeback_single_inode(inode, wbc)
                → address_space_operations.writepages()
                    → ext4_writepages() / xfs_writepages()

路径 B: 内存压力触发的后台回写
  → wb_writeback()                      [fs/fs-writeback.c]
    → writeback_sb_inodes()
        → __writeback_single_inode()
            → ext4_writepages() / xfs_writepages()

路径 C: 页回收前检查（try_to_free_pages）
  → shrink_inode()
    → address_space_operations.writepage()
```

### 7.3 writeback_control 的作用

```c
// fs/fs-writeback.c:1934 注释
 *          writeback_sb_inodes()       <== called only once
 *              write_cache_pages()     <== called once for each inode
 *                  ext4_writepages() / xfs_writepages()  ← 具体 fs 实现
```

`writeback_control` 携带同步模式、范围限制、剩余页数等信息，使文件系统能够：
- `WB_SYNC_ALL`：等待所有页 I/O 完成（`sync(2)`）
- `WB_SYNC_NONE`：只发起 I/O，不等待（后台回写）
- `nr_to_write`：控制本次回写的页数上限
- `range_start/end`：只回写特定字节范围

### 7.4 关键操作函数对应关系

```
writepages()  ← inode 上的回调，由具体文件系统实现
  ext4_writepages()    [fs/ext4/inode.c]
  xfs_writepages()     [fs/xfs/xfs_aops.c]

writepage()   ← 单页回写（用于内存回收）
  ext4_writepage()
  xfs_vm_writepage()

write_begin/write_end  ← 读时分配+延迟分配的写
  ext4_write_begin()
  xfs_write_write()

direct_IO     ← 绕过页缓存的直接 I/O
  ext4_direct_IO
  xfs_direct_IO
```

## 8. ASCII 流程图：从 open() 到具体文件系统

```
                                open("/etc/passwd", O_RDONLY)
                                        │
                         ┌──────────────┴──────────────┐
                         │  SYSCALL_DEFINE3(open)      │
                         │  fs/open.c:1374             │
                         └──────────────┬──────────────┘
                                        ▼
                         ┌────────────────────────────┐
                         │ do_sys_open()              │
                         │   → do_sys_openat2()       │
                         │   → build_open_flags()     │
                         └──────────────┬──────────────┘
                                        ▼
                         ┌────────────────────────────┐
                         │ do_file_open()             │
                         │   filename_lookup()         │
                         └──────────────┬──────────────┘
                                        ▼
                         ┌────────────────────────────┐
                         │ filename_lookup()           │
                         │   set_nameidata()          │
                         │   path_lookupat(RCU)        │
                         └──────────────┬──────────────┘
                                        ▼
                         ┌────────────────────────────┐
                         │ path_lookupat()            │
                         │   path_init()               │
                         │     → 初始化 nd->path       │
                         │   link_path_walk()         │
                         │     → 循环解析 "etc"        │
                         │       lookup_hash()        │
                         │       (hashtable hit ✓)    │
                         │     → 循环解析 "passwd"    │
                         │       lookup_hash()        │
                         │       (hashtable hit ✓)    │
                         │   complete_walk()           │
                         └──────────────┬──────────────┘
                                        ▼
                         ┌────────────────────────────┐
                         │ path_openat()              │
                         │   alloc_empty_file()       │
                         │   path_init() + link_walk()│
                         │   open_last_lookups()      │
                         │   do_open()                 │
                         └──────────────┬──────────────┘
                                        ▼
                         ┌────────────────────────────┐
                         │ do_open()                   │
                         │   complete_walk()           │
                         │   may_open()                │
                         │   vfs_open(&nd->path, file) │
                         └──────────────┬──────────────┘
                                        ▼
                         ┌────────────────────────────┐
                         │ vfs_open()                 │
                         │   file->__f_path = *path   │
                         │   do_dentry_open(file)     │
                         └──────────────┬──────────────┘
                                        ▼
                         ┌────────────────────────────┐
                         │ do_dentry_open()            │
                         │   inode = dentry->d_inode  │
                         │   f->f_inode = inode       │
                         │   f->f_op = inode->i_fop  │
                         │   → inode->i_op->open()    │
                         │   (若无自定义用 f_op->open)│
                         └──────────────┬──────────────┘
                                        ▼
                         ┌──────────────────────────────────────────┐
                         │  具体文件系统操作                         │
                         │  ext4_file_operations.open()            │
                         │    ext4_file_open()                     │
                         │    (设置 ext4 特有的 file 状态)         │
                         └──────────────────────────────────────────┘
```

---

**关键函数索引**（基于 Linux 7.0-rc1 源码）：

| 函数 | 文件:行 | 作用 |
|------|---------|------|
| `link_path_walk` | fs/namei.c:2574 | 逐分量路径解析循环 |
| `path_lookupat` | fs/namei.c:2797 | 路径查找主入口（带 RCU 支持） |
| `filename_lookup` | fs/namei.c:2830 | 路径查找封装（处理 ECHILD/ESTALE） |
| `path_openat` | fs/namei.c:4838 | 打开文件时的路径查找 |
| `do_open` | fs/namei.c:4655 | 最终执行 vfs_open |
| `vfs_open` | fs/open.c:1074 | VFS 打开文件 |
| `do_dentry_open` | fs/open.c:885 | 将 file 绑定到具体文件系统 |
| `build_open_flags` | fs/open.c:1179 | 将 flags 转换为 open_flags |
| `do_sys_openat2` | fs/open.c:1355 | openat2 系统调用入口 |