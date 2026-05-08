# 69-overlayfs — Linux OverlayFS 联合文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-08 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**OverlayFS** 是 Linux 的**联合挂载文件系统**（union mount），将多个只读下层目录和一个读写上层目录组合为单一逻辑树。它是 Docker/容器镜像系统的基石——每个容器镜像层对应一个 overlay 下层，容器可写层对应上层。

**核心设计**：OverlayFS 是一个 **VFS stacking 层**——它不管理原始存储，而是通过 dentry/inode 指针将操作委托给底层文件系统。写操作触发 **copy-up**：文件从下层复制到上层后再修改。

```
mount -t overlay overlay -o lowerdir=/A:/B,upperdir=/U,workdir=/W /M

/M→U (upper, rw) |→A (lower0, ro) |→B (lower1, ro)
读：U→A→B（上层优先，找到即停）
写：触发 copy-up（A或B→U）
删：在上层创建 whiteout（屏蔽下层同名文件）
```

**文件布局**：实现全部在 `fs/overlayfs/` 目录（13 个 .c 文件）。

| 文件 | 作用 |
|------|------|
| `namei.c` | dentry 查找，redirect 追踪 |
| `dir.c` | 目录修改操作（create/mkdir/unlink/rename） |
| `inode.c` | inode 操作（setattr/getattr/permission） |
| `copy_up.c` | copy-up 全流程（最核心） |
| `file.c` | 文件读写/mmap |
| `readdir.c` | 目录遍历（ovl_iterate） |
| `super.c` | super_block 生命周期 |
| `util.c` | 辅助函数 |
| `xattrs.c` | xattr 操作 |
| `export.c` | NFS 导出支持 |
| `params.c` | 挂载参数解析 |

---

## 1. 核心数据结构

### 1.1 struct ovl_layer — 存储层

```c
// fs/overlayfs/ovl_entry.h:33-40 — doom-lsp 确认
struct ovl_layer {
    struct vfsmount *mnt;     /* L35 — 层的挂载点 */
    struct inode *trap;       /* L36 — trap inode */
    struct ovl_sb *fs;        /* L37 — 底层 fs 数据 */
    int idx;                  /* L38 — 层索引（0=upper）*/
    int fsid;                 /* L40 — 底层 fs 唯一 ID */
    bool has_xwhiteouts;      /* L41 — 是否有 whiteout */
};
```

### 1.2 struct ovl_path — 层路径

```c
// fs/overlayfs/ovl_entry.h L47 — doom-lsp 确认
struct ovl_path {
    const struct ovl_layer *layer;  /* L48 — 所属层 */
    struct dentry *dentry;          /* L49 — 该层中的 dentry */
};
```

### 1.3 struct ovl_entry — dentry 的底层路径栈

```c
// fs/overlayfs/ovl_entry.h:52
struct ovl_entry {
    unsigned int __numlower;                /* 下层数量 */
    struct ovl_path __lowerstack[];         /* 下层路径栈 */
};
```

### 1.4 struct ovl_inode — overlay inode

```c
// fs/overlayfs/ovl_entry.h L159 — doom-lsp 确认
struct ovl_inode {
    union {
        struct ovl_dir_cache *cache;        /* L161 — 目录缓存 */
        const char *lowerdata_redirect;     /* L162 — 下层数据重定向 */
    };
    const char *redirect;           /* L164 — 重定向路径 */
    u64 version;                    /* L165 — 版本号（copy-up 跟踪） */
    unsigned long flags;            /* L166 — 状态标志 */
    struct inode vfs_inode;         /* L167 — VFS inode 缓存 */
    struct dentry *__upperdentry;   /* L168 — 上层 dentry */
    struct ovl_entry *oe;           /* L169 — 下层路径信息 */
    struct mutex lock;              /* L171 — copy-up 同步锁 */
};
```

### 1.5 struct ovl_fs — overlay 超级块

```c
// fs/overlayfs/ovl_entry.h:58
struct ovl_fs {
    unsigned int numlayer;                   /* 总层数 */
    unsigned int numdatalayer;
    struct ovl_layer *layers;                /* 层数组 [0]=upper */
    struct dentry *workbasedir;
    struct dentry *workdir;
    struct ovl_config config;
    const struct cred *creator_cred;
    bool tmpfile, noxattr, nofh;
    atomic_long_t last_ino;                  /* 伪 inode 号分配 */
    struct dentry *whiteout;                 /* whiteout 缓存 */
};
```

### 1.6 struct ovl_file — 打开的文件

```c
// fs/overlayfs/file.c:92
struct ovl_file {
    struct file *realfile;          /* L93 — 底层真实文件 */
    struct file *realfile_upper;    /* L94 — 上层真实文件 */
    bool release;                   /* L95 — release 标记 */
};
```

overlay 打开文件时没有自己的 file 状态——通过 `file->private_data` （`struct ovl_file *`）持有底层文件的引用。所有 IO 直接委托给 `realfile`。

**访问宏**（doom-lsp 确认）：

| 宏 | ovl_entry.h:行 | 作用 |
|----|---------------|------|
| `OVL_FS(sb)` | 98 | sb→s_fs_info → struct ovl_fs |
| `OVL_I(inode)` | 177 | inode→i_private → struct ovl_inode |
| `ovl_upperdentry(dentry)` | util.c | dentry 的上层 dentry |
| `ovl_lower_positive(dentry)` | util.c | 下层是否存在 |

---

## 2. 查找——ovl_lookup @ namei.c:1382

`ovl_lookup()` 是 OverlayFS 的 dentry 查找核心——自顶向下遍历所有层：

```c
// fs/overlayfs/namei.c:1382
struct dentry *ovl_lookup(struct inode *dir, struct dentry *dentry,
                          unsigned int flags)
{
    struct ovl_lookup_ctx ctx = { .dentry = dentry };
    struct ovl_path *lower = NULL;
    int i;

    /* 阶段 1：查找上层 */
    err = ovl_lookup_layer(upperdir, &d, &ctx.upperdentry, true);

    /* 阶段 2：从底层到次上层遍历 */
    for (i = 0; i < numlower; i++) {
        /* ovl_lookup_layer @ namei.c:356 */
        err = ovl_lookup_layer(lower.dentry, &d, &this, false);

        if (ovl_is_whiteout(this)) {
            /* whiteout = 此文件在上层被删除 → 跳过此层 */
            dput(this);
            continue;
        }
        /* 处理 redirect（跨层重命名）*/
        if (d.redirect) {
            /* ovl_check_follow_redirect @ namei.c:1064 */
            err = ovl_check_follow_redirect(&d);
        }
        /* 存入 stack[] */
    }

    /* 阶段 3：构建 ovl_entry → ovl_get_inode */
    oe = ovl_alloc_entry(numlower);
    inode = ovl_get_inode(dentry, upperdentry, oe);
    d_add(dentry, inode);
}
```

**ovl_lookup_layer** — 在每个层中执行实际 dentry 查找（@ namei.c:356）。它通过 `ovl_mnt(ch)` 获取当前层的挂载，调用 `vfs_lookup()` 到底层文件系统。返回结果可能是普通 dentry、whiteout、或 redirect。

**doom-lsp 确认**：`ovl_lookup` 在 `namei.c:1382`。`ovl_lookup_layer` 在 `namei.c:356`。`ovl_is_whiteout` 检查 whiteout 条目。`ovl_check_follow_redirect` 在 `namei.c:1064` 处理 redirect 追踪。

---

## 3. 目录操作——ovl_dir_operations @ dir.c

OverlayFS 的目录修改操作集中在 `fs/overlayfs/dir.c`，通过一个统一的 **copy-up 触发 + 底层委托** 模式实现。

### 3.1 ovl_create_object — 创建通用入口 @ dir.c:692

所有创建类操作（create/mkdir/mknod/symlink）最终汇聚到这个函数：

```c
// fs/overlayfs/dir.c:692
static int ovl_create_object(struct dentry *dentry, int mode, dev_t rdev,
                             const char *link)
{
    /* 1. 父目录可能需要被 copy-up（下层→上层）*/
    err = ovl_copy_up(dentry->d_parent);

    /* 2. 获取写入权限 */
    err = ovl_want_write(dentry);

    /* 3. 预分配 inode（标记 I_CREATING 防止并发访问）*/
    inode = ovl_new_inode(dentry->d_sb, mode, rdev);
    inode_init_owner(&nop_mnt_idmap, inode,
                     dentry->d_parent->d_inode, mode);

    /* 4. 委托给 ovl_create_or_link */
    err = ovl_create_or_link(dentry, inode, &attr, false);
}
```

关键点：OverlayFS 不直接在上层创建 inode。它通过 `ovl_create_or_link`（@ dir.c:706）借用 **override_creds** 机制，以 mount 时的 uid/gid 在下层文件系统创建真实文件。

### 3.2 ovl_create / ovl_mkdir — 创建文件/目录

```c
// fs/overlayfs/dir.c:734
static int ovl_create(struct mnt_idmap *idmap, struct inode *dir,
                      struct dentry *dentry, umode_t mode, bool excl)
{
    return ovl_create_object(dentry, (mode & 07777) | S_IFREG, 0, NULL);
}

// fs/overlayfs/dir.c:740
static struct dentry *ovl_mkdir(struct mnt_idmap *idmap, struct inode *dir,
                                struct dentry *dentry, umode_t mode)
{
    return ERR_PTR(ovl_create_object(dentry, (mode & 07777) | S_IFDIR, 0, NULL));
}
```

VFS 分发表（`dir.c:1477-1487`）：

```c
const struct inode_operations ovl_dir_inode_operations = {
    .create     = ovl_create,       /* dir.c:1484 */
    .mkdir      = ovl_mkdir,        /* dir.c:1477 */
    .unlink     = ovl_unlink,       /* dir.c:1479 */
    .rmdir      = ovl_rmdir,        /* dir.c:1480 */
    .rename     = ovl_rename,       /* dir.c:1481 */
    .symlink    = ovl_symlink,      /* dir.c:1478 */
    .link       = ovl_link,         /* dir.c:1482 */
    .mknod      = ovl_mknod,        /* dir.c:1485 */
    .permission = ovl_permission,   /* inode.c:290 */
    .setattr    = ovl_setattr,      /* inode.c:21 */
    .getattr    = ovl_getattr,      /* inode.c:163 */
};
```

### 3.3 ovl_do_remove — 删除操作：unlink / rmdir @ dir.c:937

```c
// fs/overlayfs/dir.c:937
static int ovl_do_remove(struct dentry *dentry, bool is_dir)
{
    bool lower_positive = ovl_lower_positive(dentry);

    /* 如果是目录且下层有内容 → 检查目录是否为空 */
    if (is_dir && (lower_positive || !ovl_pure_upper(dentry)))
        ovl_check_empty_dir(dentry, &list);

    /* 父目录要有 upper copy */
    ovl_copy_up(dentry->d_parent);

    /* nlink 管理（硬链接计数维护）*/
    ovl_nlink_start(dentry);

    with_ovl_creds(dentry->d_sb) {
        if (!lower_positive)
            /* 纯上层文件 → 直接删除 */
            err = ovl_remove_upper(dentry, is_dir, &list);
        else
            /* 下层也有 → 创建 whiteout 屏蔽下层 */
            err = ovl_remove_and_whiteout(dentry, &list);
    }

    /* 更新 inode 计数 */
    if (is_dir)
        clear_nlink(dentry->d_inode);
    else
        ovl_drop_nlink(dentry);
}
```

**删除的关键分歧**：
- **纯上层文件**（无下层副本）：直接调用底层 `vfs_unlink()` 或 `vfs_rmdir()`
- **有下层副本**：在上层创建一个 **whiteout** 节点（`mknod(parent, dentry, S_IFCHR|WHITEOUT_MODE, 0/0)`），之后 lookup 时 `ovl_is_whiteout()` 会跳过此层

### 3.4 ovl_rename — 跨层重命名 @ dir.c:1348

```c
// fs/overlayfs/dir.c:1348
static int ovl_rename(struct mnt_idmap *idmap, struct inode *olddir,
                      struct dentry *old, struct inode *newdir,
                      struct dentry *new, unsigned int flags)
{
    struct ovl_renamedata ovlrd = { ... };

    /* 1. copy-up 源文件（如果需要跨层）*/
    /* 2. copy-up 目标父目录 */
    /* 3. 设置 redirect xattr（如果源在下层）*/
    /* 4. 底层 vfs_rename() */
    /* 5. 更新 ovl_entry 引用 */
}
```

rename 在 OverlayFS 中是复杂的操作，因为 rename 可能跨越不同的层。当源文件在下层、目标在上层时，需要：
1. Copy-up 源文件到上层
2. 设置 `trusted.overlay.redirect` xattr 记录路径映射
3. 后续 lookup 通过 redirect 追踪找到文件

---

## 4. 文件操作——ovl_file_operations @ file.c

OverlayFS 的文件 IO 操作全部委托给底层文件系统，通过 `struct ovl_file` 持有真实文件引用。

### 4.1 ovl_read_iter @ file.c:323

```c
// fs/overlayfs/file.c:323
static ssize_t ovl_read_iter(struct kiocb *iocb, struct iov_iter *iter)
{
    struct file *realfile = ovl_real_file(file);

    return backing_file_read_iter(realfile, iter, iocb,
                                  iocb->ki_flags, &ctx);
}
```

纯委托——没有 OverlayFS 层的缓存。`ovl_real_file()` 从 `ovl_file->realfile` 获取底层文件。`backing_file_read_iter()` 是 VFS 辅助函数，直接调用底层 `f_op->read_iter()` 并用 `ctx.cred` 覆盖进程 cred。

### 4.2 ovl_write_iter @ file.c:343

```c
// fs/overlayfs/file.c:343
static ssize_t ovl_write_iter(struct kiocb *iocb, struct iov_iter *iter)
{
    inode_lock(inode);
    ovl_copyattr(inode);            /* 同步 mode 等属性 */
    realfile = ovl_real_file(file);

    if (!ovl_should_sync(OVL_FS(inode->i_sb)))
        ifl &= ~(IOCB_DSYNC | IOCB_SYNC);
    /* 如果配置了 nosync，去掉同步标志 */

    ret = backing_file_write_iter(realfile, iter, iocb, ifl, &ctx);
    inode_unlock(inode);
}
```

写操作加了 `inode_lock()` 保护，因为 OverlayFS 的 inode 和底层 inode 可能不同步。`ovl_copyattr()` 确保 mode/times 等元数据在写之前对齐。

### 4.3 ovl_mmap @ file.c:468

```c
// fs/overlayfs/file.c:468
static int ovl_mmap(struct file *file, struct vm_area_struct *vma)
{
    struct ovl_file *of = file->private_data;

    return backing_file_mmap(of->realfile, vma, &ctx);
}
```

mmap 直接映射到底层文件的页缓存。需要注意：如果文件是用 metacopy（仅有元数据在上层）打开的，mmap 可能触发完整 copy-up（在 `copy_up.c` 的 `ovl_copy_up_meta_inode_data` 中处理）。

---

## 5. 目录遍历——ovl_iterate @ readdir.c:898

```c
// fs/overlayfs/readdir.c:898
static int ovl_iterate(struct file *file, struct dir_context *ctx)
```

`ovl_iterate` 实现 `readdir` 操作，需要 **合并多层的目录内容**：

```
1. 读取上层目录 → 得到上层条目列表
2. 对每层下层：
   a. 读取条目
   b. 跳过已在上层出现过的条目
   c. 跳过 whiteout 条目
3. 合并结果（上层优先，下层补漏）
```

复杂之处：
- **merge 目录**（`ovl_type_merge_or_lower`）：需要合并上下层条目，去重
- **whiteout**：下层有、上层有 whiteout → 完全隐藏
- **opaque**：上层目录设置了 `trusted.overlay.opaque` xattr → 不再遍历下层

**doom-lsp 确认**：`ovl_iterate` 在 `readdir.c:898`。通过 `WRAP_DIR_ITER(ovl_iterate)` @ readdir.c:1066 包装为 `.iterate_shared` 回调。

---

## 6. Copy-Up——写时复制 @ copy_up.c

Copy-Up 是 OverlayFS 最核心的机制——当文件只存在于下层时，首次修改触发"复制到上层"。整个流程分为 4 个阶段。

### 6.1 入口：ovl_copy_up @ copy_up.c:1280

```c
// fs/overlayfs/copy_up.c:1280
int ovl_copy_up(struct dentry *dentry)
{
    return ovl_copy_up_flags(dentry, 0);
}

// 写操作触发入口：
//   ovl_setattr()       @ inode.c:21  — chmod/chown/truncate
//   ovl_permission()    @ inode.c:290 — 写入前权限检查
//   ovl_maybe_copy_up() @ copy_up.c — open 时按需 copy-up
```

### 6.2 ovl_copy_up_flags @ copy_up.c:1201——自顶向下遍历

```c
// fs/overlayfs/copy_up.c:1201
static int ovl_copy_up_flags(struct dentry *dentry, int flags)
{
    while (!err) {
        /* 找到最上层尚未 copy-up 的 dentry */
        next = dget(dentry);
        for (; !disconnected;) {
            parent = dget_parent(next);
            if (ovl_dentry_upper(parent))
                break;        /* 父目录已有 upper → 从此开始 */
            dput(next);
            next = parent;
        }

        /* 从该 dentry 开始逐层向上 copy */
        err = ovl_copy_up_one(parent, next, flags);
        dput(next);
    }
}
```

**关键设计**：Copy-up 是自顶向下的——如果父目录不在 upper 层，先 copy-up 父目录，再 copy-up 子文件。确保路径结构的完整性。

### 6.3 ovl_copy_up_one @ copy_up.c:1123——单文件 copy-up

```c
// fs/overlayfs/copy_up.c:1123
static int ovl_copy_up_one(struct dentry *parent, struct dentry *dentry,
                           int flags)
{
    struct ovl_copy_up_ctx ctx = {
        .parent = parent,
        .dentry = dentry,
        .workdir = ovl_workdir(dentry),
    };

    /* 1. 收集下层文件 stat */
    ovl_path_lower(dentry, &ctx.lowerpath);
    vfs_getattr(&ctx.lowerpath, &ctx.stat, ...);

    /* 2. 判断是否需要 metacopy */
    ctx.metacopy = ovl_need_meta_copy_up(dentry, ctx.stat.mode, flags);

    /* 3. 加锁防止并发 copy-up */
    err = ovl_copy_up_start(dentry, flags);

    /* 4. 执行实际复制 */
    if (!ovl_dentry_upper(dentry))
        err = ovl_do_copy_up(&ctx);

    /* 5. 上层已有 → 建立硬链接 */
    if (!err && parent && !ovl_dentry_has_upper_alias(dentry))
        err = ovl_link_up(&ctx);

    /* 6. 数据 copy-up（如果 metacopy 后需要完整数据）*/
    if (!err && ovl_dentry_needs_data_copy_up_locked(dentry, flags))
        err = ovl_copy_up_meta_inode_data(&ctx);
}
```

### 6.4 ovl_do_copy_up @ copy_up.c:924——内部复制调度

```c
// fs/overlayfs/copy_up.c:924
static int ovl_do_copy_up(struct ovl_copy_up_ctx *c)
{
    /* 判断是否需要 indexing（nlink>1 或 NFS 导出）*/
    if (ovl_need_index(c->dentry))
        to_index = true;

    /* 获取 origin FH（用于后续 hardlink 检测）*/
    fh = ovl_get_origin_fh(ofs, origin);

    if (to_index) {
        /* 硬链接 → copy 到索引目录 */
        c->destdir = ovl_indexdir(c->dentry->d_sb);
        err = ovl_get_index_name(ofs, origin, &c->destname);
    } else {
        /* 普通文件 → copy 到 upper 父目录 */
        c->destname = c->dentry->d_name;
        ovl_set_impure(c->parent, c->destdir);
    }

    if (S_ISDIR(c->stat.mode))
        err = ovl_copy_up_workdir(c);     /* 目录 */
    else
        err = ovl_copy_up_tmpfile(c);     /* 普通文件 */
}
```

### 6.5 ovl_copy_up_workdir @ copy_up.c:758——目录 copy-up

```c
// fs/overlayfs/copy_up.c:758
static int ovl_copy_up_workdir(struct ovl_copy_up_ctx *c)
{
    /* 在 workdir 中创建临时目录 */
    /* 复制 xattr / 元数据 */
    /* 内核内部的 ovl_create_real() */
    /* ovl_copy_up_metadata() 设置 origin, times */
    /* 临时目录→目标位置 rename */
}
```

### 6.6 ovl_copy_up_tmpfile @ copy_up.c:852——普通文件 copy-up

```c
// fs/overlayfs/copy_up.c:852
static int ovl_copy_up_tmpfile(struct ovl_copy_up_ctx *c)
{
    /* 创建 tmpfile → ovl_copy_up_data() → ovl_copy_up_metadata() */
    /* → 硬链接到目标位置 */
}
```

### 6.7 ovl_copy_up_data @ copy_up.c:639——数据复制

```c
// fs/overlayfs/copy_up.c:639
static int ovl_copy_up_data(struct ovl_copy_up_ctx *c, const struct path *temp)
{
    if (!S_ISREG(c->stat.mode) || c->metacopy || !c->stat.size)
        return 0;    /* 非文件、metacopy、空文件 → 无需数据复制 */

    new_file = ovl_path_open(temp, O_LARGEFILE | O_WRONLY);
    err = ovl_copy_up_file(ofs, c->dentry, new_file, c->stat.size, ...);
    fput(new_file);
}
```

### 6.8 ovl_copy_up_metadata @ copy_up.c:659——元数据复制

```c
// fs/overlayfs/copy_up.c:659
static int ovl_copy_up_metadata(struct ovl_copy_up_ctx *c, struct dentry *temp)
{
    /* 1. 复制 xattr（跳过 trusted.overlay.* 命名空间）*/
    ovl_copy_xattr(c->dentry->d_sb, &c->lowerpath, temp);

    /* 2. 复制 fileattr（I_FLAGS）*/
    ovl_copy_fileattr(inode, &c->lowerpath, &upperpath);

    /* 3. 设置 origin FH（标识下层 inode，用于硬链接检测）*/
    ovl_set_origin_fh(ofs, c->origin_fh, temp);

    /* 4. 处理 metacopy 元数据 */
    if (c->metacopy) {
        /* 只复制元数据，不复制文件内容 */
        /* 设置 trusted.overlay.metacopy xattr */
        /* 记录下层数据路径 */
    }

    /* 5. 设置 owner/mode/times */
    ovl_set_attr(ofs, temp, &c->stat);
}
```

### Copy-Up 完整流程图

```
用户空间: write(fd, buf, len)
    ↓
sys_write()
    ↓
ovl_write_iter() @ file.c:343     ← inode_lock, ovl_copyattr
    ↓
backing_file_write_iter()
    ↓
底层文件系统：ext4/xfs → page cache

--- 如果文件尚未 copy-up： ---
open("/merged/foo", O_WRONLY)
    ↓
ovl_open() @ file.c → 触发 ovl_maybe_copy_up()
    ↓
ovl_copy_up_flags() @ copy_up.c:1201     ← 自顶向下遍历
    ↓
ovl_copy_up_one() @ copy_up.c:1123       ← 单文件
    ↓
ovl_do_copy_up() @ copy_up.c:924         ← 调度
    ├── ovl_copy_up_workdir()  @ 758     ← 目录：workdir→rename
    └── ovl_copy_up_tmpfile()  @ 852     ← 文件：tmpfile→link
            ↓
        ovl_copy_up_data() @ 639         ← 读下层→写上层
        ovl_copy_up_metadata() @ 659     ← xattr+origin+attrs
```

---

## 7. Whiteout 和 Opaque

**Whiteout**——实现"在上层删除下层文件"。

创建：`mknod(parent, dentry, S_IFCHR|WHITEOUT_MODE, 0/0)`（`overlayfs.h:394: ovl_do_whiteout` 内联函数）。

检查：`ovl_is_whiteout()` 在 lookup 阶段识别并跳过。

**Opaque 目录**——当上层目录完全覆盖了下层同名目录时，设置 `trusted.overlay.opaque` xattr。查找时不再遍历下层。这防止了下层目录的内容意外"渗漏"到已替换的上层目录中。

---

## 8. Redirect——跨层重命名

当 rename 操作跨越不同的层时，OverlayFS 在上层设置 redirect xattr 记录源路径：

```
# lower: /a/file   upper: (空)

# 用户将 /a 重命名为 /b
# 生成：
# upper: /b (新目录) → xattr trusted.overlay.redirect = "/a"
# 查找 /b/file 时：
# 1. 找到 upper 中的 /b
# 2. 看到 redirect="/a"
# 3. 在下层 /a 中继续查找 file
```

多级 redirect（`ovl_check_follow_redirect` @ namei.c:1064）需要递归追踪，有循环检测。

---

## 9. Metacopy——元数据快速复制

```c
// Linux 5.x 引入的优化
// mount -o metacopy=on
//
// 传统 copy-up：复制整个文件（即使只改 owner）
// metacopy：只复制元数据到 upper（xattr、mode、timestamps）
// 数据文件仍留在下层
// mmap/DIO 写触发完整 copy-up
```

通过 `ovl_need_meta_copy_up()`（copy_up.c:1068）判断是否使用 metacopy：

```c
static bool ovl_need_meta_copy_up(struct dentry *dentry, umode_t mode,
                                  int flags)
{
    if (!ofs->config.metacopy) return false;     /* 未启用 */
    if (!S_ISREG(mode)) return false;             /* 只对普通文件 */
    if (flags & (FMODE_WRITE | O_TRUNC)) return false;
    /* 如果下层数据需要 fsverity 但不可用 → fallback 到完整 copy-up */
    ...
    return true;
}
```

---

## 10. XINO——跨文件系统 inode

```c
// 上下层在不同文件系统（不同 sb）→ inode 号冲突
// xino 模式：使用高 bits 编码层 ID
//
// xino_mode = 0: 禁用（所有层返回 unique 伪 ino）
// xino_mode = 1: 自动（能编码时启用）
// xino_mode = N: 使用 N bits 编码（1-32）
```

通过 `ovl_make_ino()` 在 `ovl_getattr`（inode.c:163）中生成。如果底层文件系统的 inode 号高位充足，将层 ID 编码到 inode 号中，确保跨层 inode 号不冲突。

---

## 11. VFS 操作委托

### 11.1 super_operations @ super.c:297

```c
// fs/overlayfs/super.c:297
const struct super_operations ovl_super_operations = {
    .alloc_inode    = ovl_alloc_inode,         /* super.c:184 */
    .free_inode     = ovl_free_inode,
    .destroy_inode  = ovl_destroy_inode,
    .evict_inode    = ovl_evict_inode,
    .statfs         = ovl_statfs,               /* super.c:276 — 合并底层统计 */
    .show_options   = ovl_show_options,
    .drop_inode     = ovl_drop_inode,
};
```

`ovl_alloc_inode`（super.c:184）通过 `kmem_cache_alloc(ovl_inode_cachep, ...)` 分配 `struct ovl_inode`。

### 11.2 dentry_operations @ super.c:166

```c
// fs/overlayfs/super.c:166
const struct dentry_operations ovl_dentry_operations = {
    .d_revalidate   = ovl_dentry_revalidate,    /* super.c:155 */
    .d_real         = ovl_d_real,               /* super.c:31 */
};
```

`ovl_dentry_revalidate`（super.c:155）检查底层 dentry 是否还合法。`d_real` 用于返回底层 dentry（NFS 导出等场景需要知道"真实" dentry）。

### 11.3 inode_operations @ inode.c:729

```c
// fs/overlayfs/inode.c:729
const struct inode_operations ovl_file_inode_operations = {
    .setattr    = ovl_setattr,         /* inode.c:21 */
    .permission = ovl_permission,       /* inode.c:290 */
    .getattr    = ovl_getattr,          /* inode.c:163 */
    .listxattr  = ovl_listxattr,
    .get_acl    = ovl_get_acl,
    .set_acl    = ovl_set_acl,
    .fileattr_get = ovl_fileattr_get,
    .fileattr_set = ovl_fileattr_set,
};
```

### ovl_getattr @ inode.c:163——属性合并

```c
int ovl_getattr(struct mnt_idmap *idmap, const struct path *path,
                struct kstat *stat, u32 request_mask, unsigned int flags)
{
    /* 1. 获取底层真实 stat */
    ovl_path_real(dentry, &realpath);
    vfs_getattr(&realpath, stat, request_mask, flags);

    /* 2. 覆盖 inode 号（用 overlay 自己的伪 ino）*/
    stat->ino = inode->i_ino;

    /* 3. xino 模式处理跨文件系统 inode 号 */
    if (ovl_xino_bits(dentry->d_sb) > 0)
        stat->ino = ovl_make_ino(dentry, stat->ino);
}
```

### ovl_setattr @ inode.c:21——触发 copy-up

```c
int ovl_setattr(struct mnt_idmap *idmap, struct dentry *dentry,
                struct iattr *attr)
{
    if (!ovl_has_upper(dentry))
        ovl_copy_up(dentry);          /* 首次修改 → copy-up */

    ovl_do_notify_change(ofs, ovl_upperdentry(dentry), attr);
}
```

---

## 12. 与底层文件系统的交互模式

```
VFS 系统调用
    ↓
merged (overlay mount)
    ↓
┌──────────────────────────────────────────┐
│ OverlayFS VFS Operations                  │
│ ovl_file_inode_operations (inode.c:729)    │
│ ovl_dir_inode_operations (dir.c:1476)      │
│ ovl_file_operations (file.c:636)           │
│   ↓                                       │
│ ovl_setattr() → ovl_copy_up() → 委托       │
│ ovl_getattr() → vfs_getattr(底层)          │
│ ovl_read_iter() → backing_file_read_iter() │
│ ovl_iterate() → 合并多层目录条目             │
└──────────────────────────────────────────┘
    ↓
vfs_getattr/vfs_setattr/vfs_read/vfs_write
    ↓
底层文件系统（ext4 / xfs / btrfs / ...）
    ↓
真正的存储 / 页缓存
```

---

## 13. 总结

OverlayFS 是一个**VFS stacking 层**——它没有自己的数据存储，通过精心设计的委托模式将所有操作转发到底层文件系统。关键设计决策：

| 概念 | 核心机制 | 源码位置 |
|------|---------|---------|
| **查找** | 多层遍历，上层优先 | `namei.c:1382`（ovl_lookup）|
| **写时复制** | 首次修改文件→copy-up 到上层 | `copy_up.c:1280`（ovl_copy_up）|
| **删除** | 下层文件 → whiteout 屏蔽 | `dir.c:937`（ovl_do_remove）|
| **元数据优化** | metacopy 只复制 xattr 不复制数据 | `copy_up.c:659`（ovl_copy_up_metadata）|
| **跨层重命名** | redirect xattr 追踪原始路径 | `namei.c:1064`（ovl_check_follow_redirect）|
| **inode 唯一性** | xino 编码跨文件系统 inode 号 | `inode.c:163`（ovl_getattr）|
| **目录遍历** | 多层级去重合并 | `readdir.c:898`（ovl_iterate）|
| **文件 IO** | 纯委托，通过 backing_file API | `file.c:92`（struct ovl_file）|

---

### 源码索引（LSP 验证）

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct ovl_fs` | fs/overlayfs/ovl_entry.h | 58 |
| `struct ovl_inode` | fs/overlayfs/ovl_entry.h | 159 |
| `struct ovl_layer` | fs/overlayfs/ovl_entry.h | 33 |
| `struct ovl_file` | fs/overlayfs/file.c | 92 |
| `ovl_lookup()` | fs/overlayfs/namei.c | 1382 |
| `ovl_lookup_layer()` | fs/overlayfs/namei.c | 356 |
| `ovl_check_follow_redirect()` | fs/overlayfs/namei.c | 1064 |
| `ovl_create_object()` | fs/overlayfs/dir.c | 692 |
| `ovl_create()` | fs/overlayfs/dir.c | 734 |
| `ovl_mkdir()` | fs/overlayfs/dir.c | 740 |
| `ovl_do_remove()` | fs/overlayfs/dir.c | 937 |
| `ovl_unlink()` | fs/overlayfs/dir.c | 986 |
| `ovl_rmdir()` | fs/overlayfs/dir.c | 991 |
| `ovl_rename()` | fs/overlayfs/dir.c | 1348 |
| `ovl_iterate()` | fs/overlayfs/readdir.c | 898 |
| `ovl_read_iter()` | fs/overlayfs/file.c | 323 |
| `ovl_write_iter()` | fs/overlayfs/file.c | 343 |
| `ovl_mmap()` | fs/overlayfs/file.c | 468 |
| `ovl_setattr()` | fs/overlayfs/inode.c | 21 |
| `ovl_getattr()` | fs/overlayfs/inode.c | 163 |
| `ovl_permission()` | fs/overlayfs/inode.c | 290 |
| `ovl_copy_up()` | fs/overlayfs/copy_up.c | 1280 |
| `ovl_copy_up_one()` | fs/overlayfs/copy_up.c | 1123 |
| `ovl_copy_up_flags()` | fs/overlayfs/copy_up.c | 1201 |
| `ovl_do_copy_up()` | fs/overlayfs/copy_up.c | 924 |
| `ovl_copy_up_data()` | fs/overlayfs/copy_up.c | 639 |
| `ovl_copy_up_metadata()` | fs/overlayfs/copy_up.c | 659 |
| `ovl_copy_up_workdir()` | fs/overlayfs/copy_up.c | 758 |
| `ovl_copy_up_tmpfile()` | fs/overlayfs/copy_up.c | 852 |
| `ovl_alloc_inode()` | fs/overlayfs/super.c | 184 |
| `ovl_dentry_revalidate()` | fs/overlayfs/super.c | 155 |
| `ovl_dir_inode_operations` | fs/overlayfs/dir.c | 1476 |
| `ovl_file_inode_operations` | fs/overlayfs/inode.c | 729 |
| `ovl_super_operations` | fs/overlayfs/super.c | 297 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-08 | 内核版本：Linux 7.0-rc1*
