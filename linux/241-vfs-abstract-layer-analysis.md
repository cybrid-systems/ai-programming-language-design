# vfs_deep — VFS 抽象层与系统调用桥梁深度分析

> 基于 Linux 7.0-rc1 源码，结合 doom-lsp 静态分析 `fs/namei.c`、`fs/open.c`、`include/linux/fs.h`

---

## 1. open() 到文件系统的完整 ASCII 调用链

```
open("/etc/passwd", O_RDONLY)
  │
  ├─ SYSCALL_DEFINE3(open)                          [fs/open.c:1374]
  │     └─ do_sys_open()                            [fs/open.c:1367]
  │           ├─ do_sys_openat2()                   [fs/open.c:1355]
  │           │     ├─ build_open_flags()            将 flags 转换为 open_flags
  │           │     └─ do_file_open()               [fs/namei.c:4867]
  │           │
  │           └─ do_file_open()                      [fs/namei.c:4867]
  │                 ├─ set_nameidata()              初始化 nameidata
  │                 └─ path_openat(nd, op, flags)  [fs/namei.c:4838]
  │                       │
  │                       ├─ alloc_empty_file()    分配 struct file
  │                       ├─ path_init(nd, flags)  初始化路径起点
  │                       ├─ link_path_walk(s, nd) 循环解析每个路径分量
  │                       │     ├─ 解析 "etc"  → lookup_hash() → d_lookup()
  │                       │     │                      ├─ 命中 → hashtable hit
  │                       │     │                      └─ 未命中 → ext4_lookup()
  │                       │     └─ 解析 "passwd" → 同上
  │                       ├─ open_last_lookups()   open 特有的 lookup
  │                       ├─ do_open(nd, file, op) [fs/namei.c:4655]
  │                       │     └─ vfs_open(&nd->path, file)  [fs/open.c:1074]
  │                       └─ terminate_walk(nd)
  │                             │
  │                             └─ vfs_open() → do_dentry_open()  [fs/open.c:885]
  │                                   │
  │                                   ├─ f->f_inode = dentry->d_inode
  │                                   ├─ f->f_op   = inode->i_fop        ★ 从 inode 获取
  │                                   ├─ security_file_open(f)
  │                                   └─ inode->i_op->open(inode, f)    ★ 调用 fs 实现的 open
  │                                         │
  │                                         └─ ext4_file_operations.open
  │                                               ext4_file_open()
```

---

## 2. path_lookupat：open("/etc/passwd") 路径解析每步做什么

### 2.1 核心数据结构 `struct nameidata`

```c
// fs/namei.c:723
struct nameidata {
    struct path     path;         // 当前解析到的 {mnt, dentry}
    struct qstr     last;         // 最后一个分量（名字 + hashlen）
    struct path     root;         // 进程根目录（/）
    struct inode    *inode;       // 当前 path 的 inode
    unsigned int   flags;        // LOOKUP_xxx 标志
    unsigned        seq;          // RCU seqcount（验证 dentry 有效性）
    unsigned        m_seq;        // mount_lock seqcount
    unsigned        r_seq;         // rename_lock seqcount
    enum { LAST_ROOT, LAST_DOTDOT, LAST_DOT, LAST_NORM } last_type;
    int             depth;        // 符号链接嵌套深度
    const char      *pathname;    // 原始路径字符串
    ...
};
```

### 2.2 path_init：确定搜索起点

```c
// fs/namei.c:2673
static const char *path_init(struct nameidata *nd, unsigned flags)
{
    const char *s = nd->pathname;  // e.g. "/etc/passwd"

    // 处理 LOOKUP_ROOT：若路径以 "/" 开头，nd->path = current->fs->root
    if (*s == '/') {
        nd->path = nd->root;       // 从进程的根目录开始（跨 mount 传播）
        nd->state |= ND_ROOT_PRESET;
    } else if (IS_ERR(s)) {
        return s;
    } else {
        // 相对路径：从当前工作目录开始
        nd->path = current->fs->pwd;
    }

    nd->inode = nd->path.dentry->d_inode;

    // 若开启 RCU 模式，加锁
    if (flags & LOOKUP_RCU)
        rcu_read_lock();

    return s;
}
```

**关键**：绝对路径从 `nd->root`（`/`）开始解析；相对路径从 `current->fs->pwd` 开始。`nd->root` 在进程创建时从 init_task 继承，指向系统根文件系统。

### 2.3 link_path_walk：逐分量解析循环

```c
// fs/namei.c:2574
static int link_path_walk(const char *name, struct nameidata *nd)
{
    nd->last_type = LAST_ROOT;
    nd->flags |= LOOKUP_PARENT;  // 解析父目录模式

    // 跳过前导 "/"
    if (*name == '/') {
        do { name++; } while (*name == '/');
    }

    for (;;) {
        struct mnt_idmap *idmap = mnt_idmap(nd->path.mnt);

        // ★ 权限检查：may_lookup 检查进程是否有权限遍历该目录
        err = may_lookup(idmap, nd);
        if (unlikely(err)) return err;

        // hash_name：将 "etc" 转为 qstr { name, len, hashlen }
        nd->last.name = name;
        name = hash_name(nd, name, &lastword);

        switch (lastword) {
        case LAST_WORD_IS_DOTDOT:
            nd->last_type = LAST_DOTDOT;
            nd->state |= ND_JUMPED;   // 发生了目录跨越
            break;
        case LAST_WORD_IS_DOT:
            nd->last_type = LAST_DOT;
            break;
        default: {
            nd->last_type = LAST_NORM;
            nd->state &= ~ND_JUMPED;

            // 若 d_op->d_hash 存在，调用它做自定义 hash
            struct dentry *parent = nd->path.dentry;
            if (unlikely(parent->d_flags & DCACHE_OP_HASH)) {
                err = parent->d_op->d_hash(parent, &nd->last);
                if (err < 0) return err;
            }
        }

        // 如果 name 已为空（末尾），说明这个分量就是最后一个
        if (!*name) goto OK;

        // 跳过后续的 "/" 继续解析
        do { name++; } while (*name == '/');
        if (!*name) {
OK:
            // 路径结束或末尾只有 "/"
            if (likely(!depth)) {
                nd->dir_vfsuid = i_uid_into_vfsuid(idmap, nd->inode);
                nd->dir_mode   = nd->inode->i_mode;
                nd->flags &= ~LOOKUP_PARENT;  // 不再解析父目录
                return 0;
            }
            // 最后分量是嵌套符号链接的末端
            name = nd->stack[--depth].name;
            link = walk_component(nd, 0);
        } else {
            // 非最后分量
            link = walk_component(nd, WALK_MORE);
        }

        if (unlikely(link)) {
            // 符号链接：压栈后继续循环跟踪
            nd->stack[depth++].name = name;
            name = link;
            continue;
        }

        // 检查当前是否为目录（非目录无法继续解析子路径）
        if (unlikely(!d_can_lookup(nd->path.dentry))) {
            if (nd->flags & LOOKUP_RCU) {
                if (!try_to_unlazy(nd)) return -ECHILD;
            }
            return -ENOTDIR;
        }
    }
}
```

### 2.4 walk_component：单个分量的查找和符号链接处理

```c
// fs/namei.c:2261
static const char *walk_component(struct nameidata *nd, int flags)
{
    struct inode *inode;

lookup:
    // 1. 查 dentry 缓存（lookup_fast）
    dentry = lookup_fast(nd);
    if (IS_ERR(dentry))
        return ERR_CAST(dentry);

    if (likely(dentry))
        goto found;

    // 2. 缓存未命中，调用具体文件系统的 ->lookup()
    dentry = lookup_slow(&nd->last, nd->path.dentry, nd->flags);
    if (IS_ERR(dentry))
        return ERR_CAST(dentry);

found:
    inode = d_inode(dentry);

    // 3. 符号链接跟踪
    if (d_is_symlink(dentry) && !(flags & WALK_NOFOLLOW)) {
        if (nd->flags & LOOKUP_RCU) {
            if (!try_to_unlazy(nd)) return ERR_PTR(-ECHILD);
        }
        return d_op->d_follow_link(dentry, nd);  // 返回链接目标
    }

    // 4. 更新当前 path
    nd->path.dentry = dentry;
    nd->inode = inode;
    return NULL;  // 无链接继续
}
```

### 2.5 dentry 和 vfsmount 的关系

```
path { mnt, dentry } ——
  │
  │ mnt: struct vfsmount*，代表一个挂载点。
  │      所有在该挂载点下的文件共享同一个 mnt。
  │      访问 /mnt/tmp/file 时，mnt 指向 /mnt 的挂载信息。
  │
  │ dentry: struct dentry*，代表路径中的一个分量。
  │         - d_inode：指向该分量对应的 inode
  │         - d_parent：指向父目录的 dentry（构成树）
  │         - d_flags：缓存操作标志
  │         - d_hash：hashtable 冲突链节点
  │         - d_lru：LRU 链表节点
  │         - d_children：该目录的所有子项
  │
  │ 示例 "/etc/passwd":
  │   nd->path.dentry = dentry("passwd")
  │   dentry("passwd")->d_parent = dentry("etc")
  │   dentry("etc")->d_parent = dentry("/")  (根目录)
  │   dentry("/")->d_inode = inode(/)        (根 inode)
  │   dentry("passwd")->d_inode = inode(/etc/passwd)
  │
  │ 跨文件系统示例 "/mnt/disk/file":
  │   解析 /     → mnt = root_mnt, dentry = root_dentry
  │   解析 mnt  → mnt = /mnt 的 vfsmount, dentry = mnt 的根 dentry
  │   解析 disk → mnt 不变, dentry = disk 的 dentry
```

**关键点**：同一个 `path` 中，`mnt` 和 `dentry` 必须属于同一个挂载空间。跨 `mnt` 的路径解析由 `handle_lookup_down` 处理。

---

## 3. dentry 缓存：dentry_hashtable 加速原理

### 3.1 核心数据结构

```c
// fs/dcache.c
static unsigned int d_hash_shift __ro_after_init;
static struct hlist_bl_head *dentry_hashtable;   // 全局哈希表

// 按 {parent_dentry, name} 哈希，查找同目录下的文件
static inline struct hlist_bl_head *d_hash(unsigned long hashlen)
{
    return dentry_hashtable + runtime_const_shift_right_32(hashlen, d_hash_shift);
}

// CPU 本地计数器，用于快速判断 shrink 压力
static DEFINE_PER_CPU(long, nr_dentry_unused);

// LRU 链表：所有"未在使用"的 dentry 按最近访问排序
static struct list_head dentry_unused[NR_LRU_LISTS];
```

**dentry_hashtable** 是一个大小为 `2^d_hash_shift` 的哈希表，每个槽是一个 `hlist_bl_head`（双向链表头）。冲突时同一槽内多个 dentry 通过 `d_hash` 串成冲突链。

### 3.2 d_lookup：缓存命中查找

```c
// fs/dcache.c
static struct dentry *d_lookup(const struct dentry *parent,
                                const struct qstr *name)
{
    unsigned int hash = name->hashlen_hashlen(name->hash);
    struct hlist_bl_head *b = d_hash(hash);
    struct hlist_bl_node *n;

    // RCU 遍历（lockless）
    hlist_bl_for_each_entry_rcu(dentry, n, b, d_hash) {
        if (dentry->d_parent != parent)
            continue;
        if (dentry->d_name.hash_len != name->hash_len)
            continue;
        // 比较名字（可stadt 比较）
        if (dentry_cmp(dentry, name))
            continue;
        // 验证 seqcount（RCU 模式）
        if (!lockref_get_not_dead(&dentry->d_lockref))
            continue;
        return dentry;  // ★ 命中
    }
    return NULL;  // 未命中
}
```

### 3.3 缓存加速效果

```
第一次 open("/etc/passwd"):

  link_path_walk("etc")
    hash_name("etc") → hash = 0x5a3c...
    d_hash(hash) → slot = dentry_hashtable[xxx]
    hlist_bl_for_each_entry_rcu: 槽为空 ← 未命中
    → ext4_lookup(parent=/, name="etc")
      → 磁盘 I/O: 读 / 的 inode 和 data block
      → 遍历 / 下所有目录项
      → 找到 "etc" 对应的 inode
      → d_add(dentry, inode)    ★ 加入 hashtable 和 LRU

  link_path_walk("passwd")
    同上，第二次磁盘 I/O

第二次 open("/etc/passwd"):

  link_path_walk("etc")
    d_lookup("/", "etc")  → hashtable 命中！ ✓
    → 验证 seq，refcount++  → 零磁盘 I/O！  ★

  link_path_walk("passwd")
    d_lookup("/etc", "passwd") → 命中！ ✓
    → 零磁盘 I/O！  ★

性能差距: 内存查找 ~50ns vs 磁盘 I/O ~0.5~30ms → 5~6 个数量级
```

### 3.4 LRU 回收

```c
// dentry_unused 是全局 LRU 链表
// DCACHE_LRU_LIST 标记表示 dentry 在 LRU 上
// 页面回收时从 LRU 尾驱逐最少使用的 dentry

// 加入 LRU（dentry 被释放时）
dentry->d_flags |= DCACHE_LRU_LIST;
list_add(&dentry->d_lru, &dentry_unused[sb->s_nr_dentry_unused]);
this_cpu_inc(nr_dentry_unused);

// 从 LRU 移除（dentry 被使用时）
list_del_init(&dentry->d_lru);
dentry->d_flags &= ~DCACHE_LRU_LIST;
this_cpu_dec(nr_dentry_unused);
```

---

## 4. struct file 和 dentry：从 path_openat 创建到 do_dentry_open

### 4.1 path_openat：分配 struct file 并重走路径解析

```c
// fs/namei.c:4838
static struct file *path_openat(struct nameidata *nd,
                                 const struct open_flags *op, unsigned flags)
{
    // 1. 分配空 struct file（引用计数 = 1）
    file = alloc_empty_file(op->open_flag, current_cred());
    if (IS_ERR(file))
        return file;

    // 2. O_TMPFILE 处理
    if (unlikely(file->f_flags & __O_TMPFILE))
        return do_tmpfile(nd, flags, op, file);

    // 3. O_PATH 处理（只解析路径，不真正打开）
    if (unlikely(file->f_flags & O_PATH))
        return do_o_path(nd, flags, file);

    // 4. 重走路径解析（注意：path_openat 内部再次调用 path_init + link_path_walk）
    const char *s = path_init(nd, flags);
    while (!(error = link_path_walk(s, nd)) &&
           (s = open_last_lookups(nd, file, op)) != NULL)
        ;

    // 5. 执行最终打开
    if (!error)
        error = do_open(nd, file, op);

    terminate_walk(nd);

    if (likely(!error)) {
        if (likely(file->f_mode & FMODE_OPENED))
            return file;
    }

    fput_close(file);
    return ERR_PTR(error);
}
```

**关键**：`path_openat` 内部再次调用 `path_init + link_path_walk`，这看起来是重复的——因为 `filename_lookup` 已经做过一次路径解析。实际原因是 `path_openat` 需要用 `nameidata` 来跟踪解析状态，并在打开文件时可能需要重新解析（如 O_CREAT 场景）。

### 4.2 struct file 的关键字段

```c
// include/linux/fs.h:1260
struct file {
    fmode_t                     f_mode;          // FMODE_READ | FMODE_WRITE 等
    const struct file_operations *f_op;          // ★ 文件操作函数表（来自 inode->i_fop）
    struct address_space        *f_mapping;      // inode->i_mapping（页缓存）
    struct inode                *f_inode;        // 指向 inode（派生自 f_path.dentry->d_inode）
    unsigned int                f_flags;        // O_RDONLY | O_WRONLY | O_DIRECT 等
    loff_t                      f_pos;           // 当前文件偏移
    void                        *private_data;   // 文件句柄私有数据

    union {
        const struct path       f_path;          // { mnt, dentry }
        struct path             __f_path;
    };
    ...
}
```

### 4.3 file->f_path.dentry vs file->f_inode

```
同一个 file 对象中：

  f_path.dentry → d_inode  ← 这是同一个 inode！
                  (同一个物理 inode，dentry 是缓存的目录项视图)

  f_inode       ← 直接指向 inode（绕过了 dentry 查找）

何时用 f_path.dentry：
  - 路径解析（path_put、path_get）
  - 审计（audit_inode）
  - 权限检查（may_open）
  - fsnotify 事件

何时用 f_inode：
  - 获取 f_op（file_operations）
  - 获取 i_mapping（address_space）
  - 直接 inode I/O
```

**两者在 `do_dentry_open` 中同时赋值，指向同一个 inode**：

```c
// fs/open.c:895
static int do_dentry_open(struct file *f, int (*open)(struct inode *, struct file *))
{
    struct inode *inode = f->f_path.dentry->d_inode;

    f->f_inode   = inode;
    f->f_mapping = inode->i_mapping;
    f->f_op      = fops_get(inode->i_fop);   // ★ 从 inode 获取 f_op
}
```

---

## 5. do_dentry_open：如何根据 dentry 找到 file_operations

### 5.1 完整调用序列

```
用户 open()
  → do_file_open()
    → path_openat()
      → do_open()
        → vfs_open()              [fs/open.c:1074]
          → do_dentry_open()     [fs/open.c:885]
```

### 5.2 do_dentry_open 逐行分析

```c
// fs/open.c:885
static int do_dentry_open(struct file *f,
                          int (*open)(struct inode *, struct file *))
{
    struct inode *inode = f->f_path.dentry->d_inode;
    int error;

    // 1. 增加路径引用
    path_get(&f->f_path);

    // 2. 建立 file ↔ inode 的双向关联
    f->f_inode   = inode;
    f->f_mapping = inode->i_mapping;

    // 3. O_PATH 快速路径（不调用文件系统）
    if (unlikely(f->f_flags & O_PATH)) {
        f->f_mode = FMODE_PATH | FMODE_OPENED;
        f->f_op = &empty_fops;
        return 0;
    }

    // 4. 读写计数（用于强制锁等场景）
    if ((f->f_mode & (FMODE_READ | FMODE_WRITE)) == FMODE_READ)
        i_readcount_inc(inode);
    else if (f->f_mode & FMODE_WRITE && !special_file(inode->i_mode)) {
        error = file_get_write_access(f);
        if (unlikely(error)) goto cleanup_file;
        f->f_mode |= FMODE_WRITER;
    }

    // 5. ★ 从 inode 获取文件操作函数表
    f->f_op = fops_get(inode->i_fop);
    if (WARN_ON(!f->f_op)) {
        error = -ENODEV;
        goto cleanup_all;
    }

    // 6. 安全检查
    error = security_file_open(f);
    if (unlikely(error)) goto cleanup_all;

    error = fsnotify_open_perm_and_set_mode(f);
    if (unlikely(error)) goto cleanup_all;

    error = break_lease(file_inode(f), f->f_flags);
    if (unlikely(error)) goto cleanup_all;

    // 7. 设置默认操作标志
    f->f_mode |= FMODE_LSEEK | FMODE_PREAD | FMODE_PWRITE;

    // 8. ★ 调用具体文件系统的 open() 回调
    if (!open)
        open = f->f_op->open;           // 优先用 inode->i_fop->open
    if (open) {
        error = open(inode, f);         // ext4_file_open() 在这里被调用
        if (error) goto cleanup_all;
    }

    // 9. 设置能力标志（运行时检测）
    f->f_mode |= FMODE_OPENED;
    if ((f->f_mode & FMODE_READ) &&
        likely(f->f_op->read || f->f_op->read_iter))
        f->f_mode |= FMODE_CAN_READ;
    if ((f->f_mode & FMODE_WRITE) &&
        likely(f->f_op->write || f->f_op->write_iter))
        f->f_mode |= FMODE_CAN_WRITE;

    // 10. O_DIRECT 校验
    if ((f->f_flags & O_DIRECT) && !(f->f_mode & FMODE_CAN_ODIRECT))
        return -EINVAL;

    return 0;

cleanup_all:
    fops_put(f->f_op);
    put_file_access(f);
cleanup_file:
    path_put(&f->f_path);
    f->__f_path.mnt = NULL;
    f->__f_path.dentry = NULL;
    f->f_inode = NULL;
    return error;
}
```

### 5.3 inode → file_operations 的传递链

```
struct inode {
    const struct inode_operations *i_op;   // inode 级操作（create/unlink/mkdir）
    const struct file_operations  *i_fop;  // ★ 文件操作函数表
    struct super_block            *i_sb;   // 所属超级块
    struct address_space          *i_mapping;
}

struct super_block {
    struct file_system_type      *s_type;  // 文件系统类型 (ext4/xfs/btrfs)
    const struct super_operations *s_op;
}

inode->i_fop 的来源：
  ext4_lookup() 找到 inode 后：
    inode->i_fop = &ext4_file_operations;     // 常规文件
    inode->i_fop = &ext4_dir_file_operations;   // 目录
    inode->i_fop = &ext4_symlink_file_operations;  // 符号链接
```

---

## 6. VFS 和具体文件系统：分层边界

### 6.1 四大核心抽象结构

```
┌─────────────────────────────────────────────────┐
│              struct super_block                  │
│  s_type (ext4/xfs/btrfs)                         │
│  s_op (alloc_inode/read_inode/write_inode...)    │
│  s_root (文件系统根目录的 dentry)                │
│  s_bdev (底层块设备)                             │
└────────────────────┬────────────────────────────┘
                     ▼
┌─────────────────────────────────────────────────┐
│                 struct inode                    │
│  i_fop (file_operations: read/write/mmap...)    │
│  i_op  (inode_operations: create/unlink...)      │
│  i_mapping (address_space: 页缓存)              │
│  i_sb → super_block                              │
└────────────────────┬────────────────────────────┘
                     ▼
┌─────────────────────────────────────────────────┐
│                 struct dentry                    │
│  d_inode → inode（同一个 inode）                 │
│  d_parent → 父目录 dentry（构成目录树）          │
│  d_op → dentry_operations (d_hash/d_compare...) │
│  d_hash → hashtable 冲突链节点                   │
│  d_lru  → LRU 链表节点                           │
└────────────────────┬────────────────────────────┘
                     ▼
┌─────────────────────────────────────────────────┐
│                 struct file                     │
│  f_op  (file_operations: read/write/mmap...)    │
│  f_path { mnt, dentry }                         │
│  f_inode → inode                                │
│  f_mapping → address_space (页缓存)             │
└─────────────────────────────────────────────────┘
```

### 6.2 VFS 和 ext4/xfs 的职责划分

```
职责            │ VFS 做了什么              │ 具体 fs 做了什么
────────────────┼───────────────────────────┼────────────────────────────
路径解析        │ link_path_walk + dcache   │ 提供 ->lookup() 补充未命中
权限检查        │ may_open / inode_permission │ 通常不干预
文件名操作     │ vfs_create/unlink/mkdir   │ 实现 inode 级 create/unlink
文件内容读写   │ 统一调用 f_op->read/write │ ext4/xfs 各自的 I/O 路径
内存管理(页缓存)│ address_space + radix_tree│ ext4/xfs 提供 aops
元数据持久化   │ 不涉及                    │ ext4 inode/extents，xfs btree
日志/事务      │ 不涉及                    │ ext4 journal，xfs log
```

### 6.3 文件操作函数表实例对比

```c
// ext4
const struct file_operations ext4_file_operations = {
    .open    = ext4_file_open,           // ext4 特有初始化
    .read    = new_sync_read,             // 复用 VFS 通用实现
    .read_iter = ext4_file_read_iter,     // ext4 自己的 iter 版本
    .write   = new_sync_write,
    .write_iter = ext4_file_write_iter,
    .mmap    = ext4_file_mmap,
    .fsync   = ext4_sync_file,
    .lock    = ext4_lock_file,
    ...
};

// xfs
const struct file_operations xfs_file_operations = {
    .open    = xfs_file_open,
    .read    = new_sync_read,
    .read_iter = xfs_file_read_iter,
    .write   = new_sync_write,
    .write_iter = xfs_file_write_iter,
    .mmap    = xfs_file_mmap,
    .fsync   = xfs_file_fsync,
    .lock    = xfs_file_lock,
    ...
};
```

**VFS 视角**：无论 `f_op` 指向 `ext4_file_operations` 还是 `xfs_file_operations`，VFS 都通过同一个接口调用——`file->f_op->read_iter(iocb, iter)`。这就是"无需知道底层实现"的分层意义。

---

## 7. Writeback：address_space 和 writeback_control 如何把脏页写回磁盘

### 7.1 address_space：页缓存的核心

```c
// include/linux/fs.h:473
struct address_space {
    struct inode           *host;          // 所属 inode
    struct xarray          i_pages;       // ★ 缓存页的 xarray（原 radix_tree）
    struct rb_root_cached  i_mmap;         // 映射的 vma 集合
    unsigned long          nrpages;       // 缓存页数量
    pgoff_t                writeback_index; // writeback 恢复位置
    const struct address_space_operations *a_ops;  // ★ 关键操作表
    ...
}
```

### 7.2 address_space_operations

```c
// include/linux/fs.h:401
struct address_space_operations {
    int    (*read_folio)(struct file *, struct folio *);
    int    (*writepages)(struct address_space *, struct writeback_control *);
    bool   (*dirty_folio)(struct address_space *, struct folio *);
    int    (*write_begin)(const struct kiocb *, struct address_space *,
                           loff_t pos, unsigned len,
                           struct folio **, void **);
    int    (*write_end)(const struct kiocb *, struct address_space *,
                         loff_t pos, unsigned len, unsigned copied,
                         struct folio *, void *);
    ssize_t(*direct_IO)(struct kiocb *, struct iov_iter *);
    // ...
}
```

### 7.3 writeback_control

```c
// include/linux/writeback.h:43
struct writeback_control {
    long        nr_to_write;      // 本次写回的页数（递减）
    long        pages_skipped;    // 跳过（写失败）的页数

    loff_t      range_start;     // 字节范围起始
    loff_t      range_end;        // 字节范围结束

    enum writeback_sync_modes sync_mode;  // WB_SYNC_ALL(同步) / WB_SYNC_NONE(后台)

    unsigned    for_kupdate:1;   // kupdate 后台回写
    unsigned    for_background:1; // 内存压力后台回写
    unsigned    tagged_writepages:1; // 打标签防 livelock
    unsigned    range_cyclic:1;   // 循环回写（从 writeback_index 继续）
    unsigned    for_sync:1;       // sync(2) 触发

    struct bdi_writeback *wb;     // 所属 writeback 线程
    struct inode         *inode;  // 被回写的 inode

    pgoff_t   index;              // 当前回写位置
#ifdef CONFIG_CGROUP_WRITEBACK
    int       wb_id;              // bdi_writeback ID
    size_t    wb_bytes;           // 本次已写字节数
#endif
};
```

### 7.4 脏页写回完整路径

```
进程 write() 写入 /etc/passwd:
  → ext4_file_write_iter()
    → ext4_dio_write_iter() / generic_perform_write()
      → address_space_operations.write_begin()
        ext4_write_begin()       // 分配页/映射块
      → copy_from_user()         // 拷贝数据
      → address_space_operations.write_end()
        ext4_write_end()         // 标记页为脏（PG_dirty）

此时：page 被加入 address_space->i_pages (xarray)
      page->flags |= PG_dirty


触发回写的三种路径：

路径 A: sync(2) 系统调用
  → do_sys_sync()
    → iterate_supers_sync()
      → sync_filesystem(sb)
        → writeback_sb_inodes(sb, &wbc)
          → __writeback_single_inode(inode, &wbc)
            → write_cache_pages(inode->i_mapping, &wbc, writepages)
              → ext4_writepages() / xfs_writepages()
                ★ 这是具体文件系统实现的 writepages

路径 B: 后台回写（wb_writeback / flush 线程）
  → wb_writeback(wb, &work)
    → writeback_sb_inodes()
      → __writeback_single_inode()
        → ext4_writepages() / xfs_writepages()

路径 C: 内存回收（try_to_free_pages）
  → shrink_inode(inode)
    → address_space_operations.writepage()
      → ext4_writepage() / xfs_vm_writepage()
```

### 7.5 writeback_control 参数对文件系统的影响

```
WB_SYNC_ALL  mode:
  wbc.sync_mode = WB_SYNC_ALL
  → 等待所有页的 I/O 完成（fsync 语义）
  → ext4_writepages 会等待 journal commit

WB_SYNC_NONE mode:
  wbc.sync_mode = WB_SYNC_NONE
  → 只发起 I/O，不等待完成（后台回写）
  → 更低的延迟，但数据可能未持久化

nr_to_write:
  控制本次最多写回多少页
  后台回写通常设一个较大值，sync(2) 设 LONG_MAX

range_start / range_end:
  限制回写字节范围
  用于 fsync(fd) 只回写该文件相关脏页
```

### 7.6 ext4_writepages vs xfs_writepages 核心差异

```
ext4_writepages:
  1. 检查是否使用 journal 或 wbc->for_sync
  2. 调用 ext4_da_writepages()（延迟分配 + mpage_da_submit_io）
  3. ext4_da_write_begin() 分配 ext4 块（延迟分配）
  4. 通过 mpage_submit_page() 提交 bio

xfs_writepages:
  1. 调用 xfs_bmap_flush_pages() 处理 extent 映射
  2. xfs_alarm_ranges() 处理不连续块
  3. 调用 xfs_writepages_map() 遍历所有 dirty extents
  4. xfs_buf_submit() 提交 I/O
```

**VFS 层完全不知道这些差异**：它只调用 `a_ops->writepages(inode->i_mapping, wbc)`，剩下的由文件系统自行决定。

---

## 8. 完整 open() 流程图（整合版）

```
open("/etc/passwd", O_RDONLY)
═══════════════════════════════════════════════════════════════

  [用户空间]
  libc: open("/etc/passwd", O_RDONLY)
    → arm64_sys_open  (syscall entry)

  [SYSCALL 层 — fs/open.c]
  ┌────────────────────────────────────────┐
  │  __arm64_sys_open()                     │
  │    → do_sys_open()                      │
  │      → do_sys_openat2()                 │
  │            build_open_flags()           │  flags → open_flags + acc_mode
  │            do_file_open()               │
  └────────────────────┬───────────────────┘
                        ▼
  [路径解析 — fs/namei.c]
  ┌────────────────────────────────────────────────────────┐
  │  do_file_open()                                        │
  │    → set_nameidata(&nd, dfd, pathname, NULL)          │
  │    → path_openat(&nd, op, flags)  [namei.c:4838]       │
  │                                                        │
  │  path_openat:                                          │
  │    1. alloc_empty_file(open_flag, cred) → struct file │
  │    2. path_init(nd, flags)                            │
  │       ├─ 绝对路径 → nd->path = current->fs->root      │
  │       └─ RCU 模式 rcu_read_lock()                     │
  │    3. link_path_walk(s, nd)                           │
  │       ├─ hash_name("etc") → qstr{name:"etc", len:3}   │
  │       ├─ lookup_hash(nd->path.dentry="/", &qstr)       │
  │       │     ├─ d_lookup() → hashtable hit?            │
  │       │     │   └─ 命中 → 返回现有 dentry（零 I/O）     │
  │       │     └─ 未命中 → ext4_lookup() 读磁盘 inode    │
  │       ├─ walk_component() 验证 dentry                 │
  │       ├─ 更新 nd->path.dentry = dentry("etc")         │
  │       │                          nd->inode = inode("etc") │
  │       ├─ hash_name("passwd") → qstr{name:"passwd"}    │
  │       ├─ lookup_hash(dentry("etc"), &qstr)             │
  │       │     └─ hashtable hit / ext4_lookup()          │
  │       └─ 更新 nd->path.dentry = dentry("passwd")       │
  │    4. open_last_lookups(nd, file, op)                 │
  │       └─ finish_open() / lookup_open() 处理 O_CREAT    │
  │    5. do_open(nd, file, op)                           │
  │       ├─ complete_walk(nd)   验证路径                  │
  │       ├─ may_open()          权限检查                   │
  │       └─ vfs_open(&nd->path, file)                    │
  └────────────────────┬───────────────────────────────────┘
                        ▼
  [VFS 打开 — fs/open.c]
  ┌────────────────────────────────────────────────────────┐
  │  vfs_open(path, file)                                 │
  │    → do_dentry_open(file, NULL)  [open.c:885]         │
  │                                                        │
  │  do_dentry_open:                                       │
  │    1. inode = file->f_path.dentry->d_inode            │
  │    2. file->f_inode = inode                           │
  │    3. file->f_mapping = inode->i_mapping              │
  │    4. file->f_op = inode->i_fop  ★ 从 inode 获取     │
  │    5. security_file_open(file)   安全框架             │
  │    6. break_lease(inode, flags)  锁文件                │
  │    7. inode->i_op->open(inode, file)  ★ ext4 的 open  │
  │       └─ ext4_file_open()  ext4 特有初始化            │
  │    8. file->f_mode |= FMODE_OPENED | FMODE_CAN_READ   │
  └────────────────────┬───────────────────────────────────┘
                        ▼
  [具体文件系统 — fs/ext4/file.c]
  ┌────────────────────────────────────────────────────────┐
  │  ext4_file_open(inode, file)                          │
  │    ├─ 设置 file 私有数据                               │
  │    ├─ 配置 DAX 或 pagecache 模式                       │
  │    └─ 返回 0（成功）                                  │
  └────────────────────────────────────────────────────────┘

  返回 struct file* 给用户进程
═══════════════════════════════════════════════════════════════

后续 read(file, buf, len) 调用链：
  → __arm64_sys_read()
    → ksys_read()
      → do_sys_read()
        → vfs_read(file, buf, len, &file->f_pos)
          → file->f_op->read_iter(iocb, iter)
               ↓
            ext4_file_read_iter()  /  xfs_file_read_iter()
               ↓
            (共享 VFS 的通用路径：generic_file_read_iter → filemap_read)
```

---

## 附录：关键源码索引（Linux 7.0-rc1）

| 函数 | 文件:行 | 作用 |
|------|---------|------|
| `link_path_walk` | `fs/namei.c:2574` | 逐分量路径解析循环 |
| `path_init` | `fs/namei.c:2673` | 初始化路径起点（根目录/当前目录） |
| `path_lookupat` | `fs/namei.c:2797` | 路径查找主入口（RCU + blocking fallback） |
| `filename_lookup` | `fs/namei.c:2830` | path_lookupat 封装，处理 ECHILD/ESTALE |
| `lookup_fast` | `fs/namei.c:1838` | dentry_hashtable 命中查找 |
| `lookup_slow` | `fs/namei.c:1888` | 未命中时调用具体 fs 的 ->lookup() |
| `walk_component` | `fs/namei.c:2261` | 单个分量的查找+符号链接跟踪 |
| `path_openat` | `fs/namei.c:4838` | 文件打开时的路径查找入口 |
| `open_last_lookups` | `fs/namei.c:4563` | open 特有的最后分量处理（O_CREAT 等） |
| `do_open` | `fs/namei.c:4655` | 最终执行 vfs_open + 权限检查 |
| `vfs_open` | `fs/open.c:1074` | VFS 打开文件入口 |
| `do_dentry_open` | `fs/open.c:885` | 将 struct file 绑定到具体文件系统 |
| `build_open_flags` | `fs/open.c:1179` | 将用户 flags 转换为内部 open_flags |
| `do_sys_openat2` | `fs/open.c:1355` | openat2 系统调用入口 |
| `d_lookup` | `fs/dcache.c` | dentry_hashtable 查找 |
| `d_add` | `fs/dcache.c` | 添加 dentry 到缓存 |
| `ext4_lookup` | `fs/ext4/namei.c` | ext4 的目录项查找 |
| `ext4_file_open` | `fs/ext4/file.c` | ext4 文件打开实现 |