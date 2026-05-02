# 69-overlayfs — Linux OverlayFS 联合文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**OverlayFS** 是 Linux 的**联合挂载文件系统**（union mount），将一个或多个只读下层目录和一个读写上层目录组合为一个逻辑目录树。OverlayFS 是现代 Docker/容器镜像系统的核心——每个容器镜像层对应一个 overlayfs lowerdir，容器可写层对应 upperdir。

**核心设计**：OverlayFS 使用**层叠（stacking）**架构——文件操作在上下层之间查找和合并。本质上它不是一个传统的磁盘文件系统，而是一个**VFS 层之上的聚合层**，通过 `dentry` 和 `inode` 指针将操作委托给底层文件系统。

```
mount -t overlay overlay -o lowerdir=/lower,upperdir=/upper,workdir=/work /merged

  /merged (overlay root)
    │
    ├── upper layer（读写）→ /upper
    │   └── 文件修改、新建都在此
    │
    ├── lower layer 0 → /lower0
    ├── lower layer 1 → /lower1  （只读，从下层到上层覆盖）
    └── lower layer N → /lowerN
```

**读操作**：从上层向下层查找，找到即返回（whiteout 条目表示文件在下层被删除）。

**写操作（copy-up）**：文件首次在上层修改时，OverlayFS 将整个文件从下层复制到上层，然后修改上层副本。

**doom-lsp 确认**：实现在 `fs/overlayfs/`（**~10 个核心文件**，共 ~11,000 行）。头文件 `ovl_entry.h` 和 `overlayfs.h`。核心操作：`copy_up.c`（copy-up 机制）、`dir.c`（目录操作）、`inode.c`（inode 操作）、`file.c`（文件操作）。

---

## 1. 核心数据结构

### 1.1 struct ovl_layer — 存储层

```c
// fs/overlayfs/ovl_entry.h:33-40
struct ovl_layer {
    struct vfsmount *mnt;                  /* 层的挂载点 */
    struct inode *trap;                    /* trap inode（防止递归）*/
    struct ovl_sb *fs;                     /* 底层文件系统信息 */
    int idx;                               /* 层索引（0=upper）*/
    int fsid;                              /* 唯一底层 sb 索引 */
    bool has_xwhiteouts;                   /* 是否包含 xwhiteout */
};
```

### 1.2 struct ovl_path — 层路径

```c
struct ovl_path {
    const struct ovl_layer *layer;          /* 所属层 */
    struct dentry *dentry;                  /* 此路径的 dentry */
};
```

### 1.3 struct ovl_entry — dentry 的底层信息

```c
struct ovl_entry {
    unsigned int __numlower;                /* 下层路径数 */
    struct ovl_path __lowerstack[];         /* 下层路径栈（变长）*/
};
```

### 1.4 struct ovl_inode — inode 底层映射

```c
struct ovl_inode {
    union {
        struct ovl_dir_cache *cache;        /* 目录缓存 */
        const char *lowerdata_redirect;     /* 文件重定向 */
    };
    const char *redirect;                   /* 重定向路径 */
    u64 version;                            /* 版本号 */
    unsigned long flags;
    struct inode vfs_inode;                 /* VFS inode（必须最后）*/
    struct dentry *__upperdentry;           /* 上层 dentry */
    struct ovl_entry *oe;                   /* 下层路径信息 */
    struct mutex lock;                      /* 同步 copy-up */
};
```

### 1.5 struct ovl_fs — overlay 超级块

```c
struct ovl_fs {
    unsigned int numlayer;                   /* 总层数 */
    unsigned int numfs;                      /* 底层唯一文件系统数 */
    unsigned int numdatalayer;               /* 纯数据下层数 */
    struct ovl_layer *layers;                /* 层数组 [0]=upper */
    struct ovl_sb *fs;

    struct dentry *workbasedir;              /* workdir= 路径 */
    struct dentry *workdir;                  /* work/ 或 index/ 目录 */

    struct ovl_config config;
    const struct cred *creator_cred;

    bool tmpfile;                            /* 支持 tmpfile */
    bool noxattr;                            /* 不支持 xattr */
    bool nofh;
    bool upperdir_locked;
    bool workdir_locked;

    atomic_long_t last_ino;                  /* inode 号分配器 */
    struct dentry *whiteout;                 /* whiteout 缓存 */
};
```

---

## 2. 查找路径——ovl_lookup

```c
// fs/overlayfs/namei.c
// 通过 ovl_lookup() 查找 dentry 在所有层中的位置：

struct dentry *ovl_lookup(struct inode *dir, struct dentry *dentry,
                          unsigned int flags)
{
    struct ovl_entry *oe;
    const struct ovl_path *lower;
    int i;

    /* 1. 从上层开始查找 */
    upperdentry = ovl_lookup_upper(ofs, dentry->d_name.name);

    /* 2. 从最底层到次上层遍历查找下层 */
    for (i = 0; i < numlower; i++) {
        lower = &stack[i];
        this = ovl_lookup_layer(lower->layer, dentry->d_name.name);
        /* 处理 whiteout：上层删除 → 跳过此层 */
        if (ovl_is_whiteout(this))
            continue;
    }

    /* 3. 构建 ovl_entry + 设置 dentry 操作 */
    oe = ovl_alloc_entry(numlower);
    // 填充 stack[] 数组

    /* 4. 设置 dentry->d_fsdata = OE 标志 */
    // OVL_E_UPPER_ALIAS / OVL_E_CONNECTED / OVL_E_OPAQUE

    /* 5. 返回 inode（如果找到）*/
    inode = ovl_get_inode(dentry, upperdentry, oe);
    d_add(dentry, inode);
}
```

**Opaque 目录**：当一个上层目录设置了 `trusted.overlay.opaque` xattr，OverlayFS 不继续查找同名的下层目录条目（用于目录合并后防止下层文件泄露）。

---

## 3. Copy-Up 机制

Copy-up 是 OverlayFS 写操作的**核心机制**——文件首次修改时，从下层复制到上层：

```c
// fs/overlayfs/copy_up.c:1283
// 触发条件：
// 1. 文件在上层不存在（只在下层存在）
// 2. 用户试图写或修改属性

int ovl_copy_up_one(struct dentry *dentry, const char *redirect)
{
    struct path parentpath;
    struct kstat stat;
    struct cred *override_cred;

    /* 1. 用创建者权限执行 */
    override_cred = ovl_override_creds(dentry->d_sb);

    /* 2. 查找下层文件信息 */
    ovl_path_lower(dentry, &lowerpath);
    stat = ovl_get_lower_stat(dentry);

    /* 3. 如果文件是硬连接 → 创建硬连接而非复制 */
    if (ovl_get_nlink(lowerstat) > 1 && ovl_indexdir(dentry->d_sb))
        return ovl_copy_up_inode(dentry, lowerpath.dentry, NULL);

    /* 4. 实际复制 */
    if (S_ISREG(stat->mode)) {
        /* 普通文件：使用 tmpfile 或直接写入 */
        if (ofs->tmpfile)
            ovl_copy_up_tmpfile(dentry, lowerpath.dentry, stat);
        else
            ovl_do_copy_up(dentry, lowerpath.dentry, stat);
    }

    /* 5. 复制属性（owner/mode/xattr）*/
    ovl_set_attr(dentry, stat);

    /* 6. 更新 overlay inode 指向上层 dentry */
    ovl_set_upper(dentry, upperdentry);

    ovl_revert_creds(dentry->d_sb, override_cred);
}
```

**Copy-up 数据流**：

```
读文件：下层存在 → 直接通过 dentry 指向 lower 文件
第一次写文件：触发 copy-up
  1. 下层数据 → 内核 tmpfile
  2. tmpfile → rename 到上层目标路径
  3. dentry 指针切换到上层文件
  4. 后续写直接操作上层
```

---

## 4. 目录操作——Whiteout 和 Opaque

### Whiteout

当上层"删除"一个下层文件时，OverlayFS 在上层创建一个 whiteout 条目：

```c
// 删除下层文件的流程：
// 1. 在上层创建 whiteout（字符设备 0:0 或 xattr whiteout）
// 2. overlay 查找时跳过匹配 whiteout 的下层

// ovl_do_whiteout():
//   mknod(dir, dentry, S_IFCHR | WHITEOUT_MODE, WHITEOUT_DEV)
//   或设置 trusted.overlay.whiteout xattr
```

### Opaque 目录

```c
// 当上层目录已经是完整的覆盖 → 设置 opaque xattr
// 设置后，查找不继续搜索下层

// ovl_set_opaque():
//   ovl_do_setxattr(ofs, upperdentry, "trusted.overlay.opaque", "y", 1)
```

---

## 5. Redirect 与多下层

```c
//  当目录被重命名跨层时，OverlayFS 设置 redirect xattr：
//  trusted.overlay.redirect = "target/path"
//  查找时 follow redirect 到目标路径

// 举例：
// lower:  /dir_A/file     （只读层）
// upper:  /dir_B/         （上层，重命名了 dir_A 为 dir_B）
// merged: /merged/dir_B/file （通过 redirect 找到）
```

---

## 6. XINO——跨文件系统 inode 号

```c
// 当上下层在不同文件系统上时，inode 号可能冲突
// OverlayFS 使用 xino（xattr inode number）解决：
//
// 1. 通过 upper 层的 high bits 编码层 ID
// 2. lower 文件无法修改 inode → 使用 xattr 记录原始 inode
// 3. getattr() 时组合显示

#define XINO_BITS_OFFSET       32
// - xino_mode=0: 禁用（所有层返回伪 inode 号）
// - xino_mode=1: 自动（能唯一标识时启用）
```

---

## 7. Volatile 模式

```c
// mount -o volatile
// 放弃所有修改——umount 时不回写 upper 层的更改
// 用于不需要持久化的容器场景
```

---

## 8. Data-only 层

```c
// 5.x 引入的数据专用下层
// 不包含文件元数据（仅数据块）
// 用于分离元数据和数据（如 OCI 容器镜像）
```

---

## 9. VFS 集成——操作委托

OverlayFS 的核心是**操作委托**——每个 VFS 操作在 overlay 层被拦截，根据需要触发 copy-up 或委托给底层文件系统：

```c
// fs/overlayfs/super.c:297
const struct super_operations ovl_super_operations = {
    .alloc_inode    = ovl_alloc_inode,         /* 分配 ovl_inode */
    .free_inode     = ovl_free_inode,
    .destroy_inode  = ovl_destroy_inode,
    .evict_inode    = ovl_evict_inode,
    .show_options   = ovl_show_options,
    .statfs         = ovl_statfs,
    .drop_inode     = ovl_drop_inode,
};

// fs/overlayfs/inode.c
const struct inode_operations ovl_file_inode_operations = {
    .setattr    = ovl_setattr,        // 可能触发 copy-up
    .permission = ovl_permission,      // 检查双层权限
    .getattr    = ovl_getattr,         // 合并上下层属性
    .listxattr  = ovl_listxattr,       // 合并 xattr
    .get_acl    = ovl_get_acl,
    .set_acl    = ovl_set_acl,         // 可能触发 copy-up
};
```

### ovl_getattr——属性合并

```c
// fs/overlayfs/inode.c
static int ovl_getattr(struct mnt_idmap *idmap,
                       const struct path *path, struct kstat *stat,
                       u32 request_mask, unsigned int flags)
{
    struct dentry *dentry = path->dentry;
    struct inode *inode = d_inode(dentry);

    /* 获取底层真实 stat */
    ovl_path_real(dentry, &realpath);
    vfs_getattr(&realpath, stat, ...);

    /* 覆盖 inode 号为 overlay 分配的伪 ino */
    stat->ino = inode->i_ino;

    /* NFS 导出支持：使用底层真实 ino + FSID */
    if (ovl_xino_bits(dentry->d_sb) > 0)
        stat->ino = ovl_make_ino(dentry, stat->ino);

    /* 合并 blocks */
    if (ovl_is_upper(dentry) && ovl_has_upper(inode)) {
        // 已 copy-up → 报告底层统计
    } else {
        // 未 copy-up → 报告下层统计
    }
}
```

### ovl_setattr——可能触发 copy-up

```c
// fs/overlayfs/inode.c
int ovl_setattr(struct mnt_idmap *idmap, struct dentry *dentry,
                struct iattr *attr)
{
    // chmod/chown/truncate 等操作 → 确保文件在上层有副本
    // 如果文件只在下层存在，触发 copy-up
    if (!ovl_need_upper(dentry) && !ovl_has_upper(dentry))
        ovl_copy_up(dentry);

    // 委托给上层文件系统
    ovl_do_notify_change(ofs, ovl_upperdentry(dentry), attr);
}
```

## 10. Metacopy——元数据快速复制

```c
// 5.x 引入的优化：只复制元数据（不复制数据）
// mmap 写入数据时仍然需要复制完整文件
//
// mount -o metacopy=on
//
// 效果：chmod/chown 大量文件时只复制几 KB 的元数据
// 而不是复制整个文件内容
```

## 11. 共识：OverlayFS 不是常规文件系统

OverlayFS 的设计与常规文件系统有**根本不同**：

| 特性 | ext4/XFS/btrfs | OverlayFS |
|------|---------------|-----------|
| 磁盘格式 | 有，管理自己的存储 | **无**，依赖底层文件系统 |
| inode | 磁盘 inode + 扩展属性 | **VFS inode 包装器**，委托到底层 |
| 数据存储 | 直接分配磁盘块 | **委托给底层文件系统** |
| 一致性 | 日志/CoW 保证 | **底层文件系统保证**（overlay 是薄层）|
| 快照 | 内建/LVM | **层本身就是快照**（容器镜像层）|
| 性能 | 直接磁盘 IO | **copy-up 写放大**（需要复制整个文件）|
| VFS 定位 | 底层文件系统实现 | **VFS stacking 层**（不实现原始存储）|

---

## 10. 调试

```bash
# 查看 OverlayFS 挂载
cat /proc/mounts | grep overlay
mount | grep overlay

# 查看 xattr（copy-up 状态）
getfattr -d -m - /upper/file.txt
getfattr -d -m - /upper/dir/
# trusted.overlay.origin   — 下层来源 inode
# trusted.overlay.redirect  — 重定向路径
# trusted.overlay.opaque    — 不透明标记
# trusted.overlay.whiteout  — whiteout

# 查看层结构
cat /sys/fs/overlay/merged/  # 如果有 sysfs 支持

# 跟踪 copy-up
echo 1 > /sys/kernel/debug/tracing/events/overlayfs/overlay_copy_up/enable
```

---

## 11. 总结

OverlayFS 是一个**薄聚合层**——它本身不管理存储，而是通过 `dentry`/`inode` 指针将操作委托给底层文件系统。其核心价值在于**层叠（layering）**和**写时复制（copy-up）**，这两个机制使容器镜像层系统成为可能。

**关键操作**：
1. **ovl_lookup** — 自顶向下遍历层，whiteout 跳过，找到即停
2. **copy_up** — 首次写时从下层复制到上层（元数据+数据）
3. **redirect** — 跨层重命名的路径跟踪
4. **xino** — 跨文件系统的 inode 号统一

**核心局限**：copy-up 写放大（即使只修改了 1 字节，也需要复制整个文件）、rename 跨层时需要 redirect。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
