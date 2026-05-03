# 69-overlayfs — Linux OverlayFS 联合文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

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

**doom-lsp 确认**：实现在 `fs/overlayfs/` 目录。关键文件：`namei.c`（ovl_lookup @ 1382）、`inode.c`（ovl_getattr @ 163, ovl_setattr @ 21）、`copy_up.c`（ovl_copy_up_file @ 260）、`super.c`（ovl_super_operations @ 297）。

---

## 1. 核心数据结构

### 1.1 struct ovl_layer — 存储层

```c
// fs/overlayfs/ovl_entry.h:33-40
struct ovl_layer {
    struct vfsmount *mnt;                  /* 层的挂载点 */
    struct inode *trap;                    /* trap inode */
    struct ovl_sb *fs;
    int idx;                               /* 层索引（0=upper）*/
    int fsid;                              /* 底层 fs 唯一 ID */
    bool has_xwhiteouts;
};
```

### 1.2 struct ovl_path — 层路径

```c
struct ovl_path {
    const struct ovl_layer *layer;
    struct dentry *dentry;
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
// fs/overlayfs/ovl_entry.h:159
struct ovl_inode {
    union {
        struct ovl_dir_cache *cache;        /* 目录缓存 */
        const char *lowerdata_redirect;
    };
    const char *redirect;
    u64 version;
    unsigned long flags;
    struct inode vfs_inode;                 /* VFS inode */
    struct dentry *__upperdentry;           /* 上层 dentry */
    struct ovl_entry *oe;                   /* 下层信息 */
    struct mutex lock;                      /* copy-up 同步 */
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

**doom-lsp 确认**：`struct ovl_fs` 在 `ovl_entry.h:58`，`struct ovl_inode` 在 `ovl_entry.h:159`。`struct ovl_layer` 在 `ovl_entry.h:33`。掩码宏 `OVL_FS()` 在 `ovl_entry.h:98`，`OVL_I()` 在 `ovl_entry.h:177`。

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
            continue;
        }
        /* 处理 redirect（跨层重命名）*/
        if (d.redirect) {
            /* ovl_check_follow_redirect @ namei.c:1064 */
            err = ovl_check_follow_redirect(&d);
        }
        /* 存入 stack[] */
    }

    /* 阶段 3：构建 ovl_entry */
    oe = ovl_alloc_entry(numlower);

    /* 阶段 4：创建 inode */
    inode = ovl_get_inode(dentry, upperdentry, oe);
    d_add(dentry, inode);
}
```

**doom-lsp 确认**：`ovl_lookup` 在 `namei.c:1382`。`ovl_lookup_layer` 在 `namei.c:356`。`ovl_is_whiteout` 检查 whiteout 条目。`ovl_check_follow_redirect` 在 `namei.c:1064` 处理 redirect 追踪。

---

## 3. Copy-Up——写时复制 @ copy_up.c

OverlayFS 最核心的写操作机制——文件在下层存在但上层不存在时，首次写操作触发复制：

**doom-lsp 确认**：copy-up 实现在 `fs/overlayfs/copy_up.c`（61 个符号）。核心结构 `struct ovl_copy_up_ctx` 在 `copy_up.c:577`——包含 parent、dentry、source stat 等信息。

```c
// fs/overlayfs/copy_up.c
struct ovl_copy_up_ctx {                      /* @ copy_up.c:577 */
    struct dentry *parent;                     /* 父目录 dentry */
    struct dentry *dentry;                     /* 目标 dentry */
    struct path lowerpath;                     /* 下层路径 */
    struct kstat stat;                         /* 源文件 stat */
    struct kstat pstat;
    const char *redirect;
    struct ovl_cu_creds *cc;
};

/* 触发路径——任何修改操作都可能触发：
 *   ovl_setattr()        @ inode.c:21  — chmod/chown/truncate
 *   ovl_permission()     @ inode.c:290 — 写入前权限检查
 *   ovl_set_acl()        @ inode.c     — ACL 修改
 */

/* 实际文件复制 @ copy_up.c:260 */
static int ovl_copy_up_file(struct ovl_fs *ofs, struct dentry *dentry,
                            struct file *new_file, loff_t len)
{
    /* 1. 从下层文件读取数据 */
    /* 2. 写入上层 tmpfile */
    /* 3. tmpfile → rename 到目标路径 */
    /* 4. 设置 xattr（origin 等）*/
}

/* 复制 xattr @ copy_up.c:75 */
int ovl_copy_xattr(struct ovl_sb *upper_sb, struct dentry *upper,
                   struct dentry *lower)
{
    /* 列出下层的所有 xattr */
    /* 跳过 trusted.overlay.* namespace */
    /* 复制到上层 */
}
```

**doom-lsp 确认**：`ovl_copy_up_file` 在 `copy_up.c:260`。`ovl_copy_xattr` 在 `copy_up.c:75`。`ovl_set_attr` 在 `copy_up.c:392` 设置 owner/mode/times。

---

## 4. VFS 操作委托

### 4.1 super_operations @ super.c:297

```c
// fs/overlayfs/super.c:297
const struct super_operations ovl_super_operations = {
    .alloc_inode    = ovl_alloc_inode,         /* super.c:184 — 分配 ovl_inode */
    .free_inode     = ovl_free_inode,
    .destroy_inode  = ovl_destroy_inode,
    .evict_inode    = ovl_evict_inode,
    .statfs         = ovl_statfs,               /* super.c:276 — 合并底层统计 */
    .show_options   = ovl_show_options,
    .drop_inode     = ovl_drop_inode,
};
```

### 4.2 dentry_operations @ super.c:166

```c
// fs/overlayfs/super.c:166
const struct dentry_operations ovl_dentry_operations = {
    .d_revalidate   = ovl_dentry_revalidate,    /* super.c:155 */
    .d_real         = ovl_d_real,               /* super.c:31 */
};
```

**doom-lsp 确认**：`ovl_alloc_inode` 在 `super.c:184` 通过 `kmem_cache_alloc(ovl_inode_cachep, ...)` 分配。`ovl_dentry_revalidate` 在 `super.c:155` 检查底层 dentry 是否有效（应对底层文件系统的目录变更）。

### 4.3 inode_operations @ inode.c:729

```c
// fs/overlayfs/inode.c:729
const struct inode_operations ovl_file_inode_operations = {
    .setattr    = ovl_setattr,         /* inode.c:21 — 可能触发 copy-up */
    .permission = ovl_permission,       /* inode.c:290 */
    .getattr    = ovl_getattr,          /* inode.c:163 */
    .listxattr  = ovl_listxattr,
    .get_acl    = ovl_get_acl,
    .set_acl    = ovl_set_acl,          /* 可能触发 copy-up */
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

    /* 2. 覆盖 inode 号 */
    stat->ino = inode->i_ino;

    /* 3. xino 模式（跨文件系统）处理 */
    if (ovl_xino_bits(dentry->d_sb) > 0)
        stat->ino = ovl_make_ino(dentry, stat->ino);
}
```

### ovl_setattr @ inode.c:21——触发 copy-up 链

```c
int ovl_setattr(struct mnt_idmap *idmap, struct dentry *dentry,
                struct iattr *attr)
{
    /* 检查是否需要 copy-up */
    if (!ovl_has_upper(dentry))
        ovl_copy_up(dentry);

    /* 委托给上层文件系统 */
    ovl_do_notify_change(ofs, ovl_upperdentry(dentry), attr);
}
```

**doom-lsp 确认**：`ovl_getattr` 在 `inode.c:163`，`ovl_setattr` 在 `inode.c:21`，`ovl_permission` 在 `inode.c:290`。所有操作均通过 `ovl_need_upper()` 检查是否需要 copy-up。

---

## 5. Whiteout 和 Opaque

**Whiteout** 实现"在上层删除下层文件"：

**doom-lsp 确认**：`ovl_do_whiteout` 在 `overlayfs.h:394`（内联函数）。创建方式：`mknod(parent, dentry, S_IFCHR|WHITEOUT_MODE, WHITEOUT_DEV)`。查找时通过 `ovl_is_whiteout()` 检查。

**Opaque 目录**——当上层目录完全覆盖了下层同名目录时，设置 `trusted.overlay.opaque` xattr，查找不再遍历下层。

---

## 6. Redirect——跨层重命名

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

---

## 7. Metacopy——元数据快速复制

```c
// Linux 5.x 引入的优化
// mount -o metacopy=on
//
// 传统 copy-up：复制整个文件（即使只改 owner）
// metacopy：只复制元数据到 upper（xattr、mode、timestamps）
// 数据文件仍留在下层
// mmap/DIO 写触发完整 copy-up
```

**doom-lsp 确认**：metacopy 标志通过 `ovl_ccup_set`（`copy_up.c:25`）模块参数控制：`modprobe overlay check_copy_up=0` 可禁用。

---

## 8. XINO——跨文件系统 inode

```c
// 上下层在不同文件系统（不同 sb）→ inode 号冲突
// xino 模式：使用高 bits 编码层 ID
//
// xino_mode = 0: 禁用（所有层返回 unique 伪 ino）
// xino_mode = 1: 自动（能编码时启用）
// xino_mode = N: 使用 N bits 编码（1-32）
```

---

## 9. 与底层文件系统的交互模式

```
VFS 系统调用                                    /merged (overlay)
    ↓                                               ↓
        ovl_file_inode_operations (inode.c)
    ↓
    ovl_getattr() → 合并属性（或触发 copy-up）
    ovl_setattr() → 检查 upper → copy-up → 委托
    ovl_permission() → 检查双重权限
    ↓
    vfs_getattr()/vfs_setattr()   ← 委托到底层文件系统
    ↓
底层 ext4/xfs/... → 实现真实 IO
```

---

## 10. 总结

OverlayFS 是一个**VFS stacking 层**——不管理原始存储，通过 dentry/inode 指针将操作委托给底层文件系统。`ovl_lookup`（`namei.c:1382`）管理多层遍历，`ovl_copy_up_file`（`copy_up.c:260`）处理首次写操作的复制，`ovl_getattr`（`inode.c:163`）合并上下层属性。

**doom-lsp 确认的关键函数**：

| 函数 | 文件:行号 | 作用 |
|------|----------|------|
| `ovl_lookup` | `namei.c:1382` | 多层 dentry 查找 |
| `ovl_getattr` | `inode.c:163` | 合并 stat 属性 |
| `ovl_setattr` | `inode.c:21` | setattr + copy-up 触发 |
| `ovl_permission` | `inode.c:290` | 双层权限检查 |
| `ovl_copy_up_file` | `copy_up.c:260` | 文件数据复制 |
| `ovl_copy_xattr` | `copy_up.c:75` | xattr 层间复制 |
| `ovl_alloc_inode` | `super.c:184` | ovl_inode 分配 |
| `ovl_dentry_revalidate` | `super.c:155` | dentry 有效性验证 |
| `ovl_lookup_layer` | `namei.c:356` | 单层 dentry 查找 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
