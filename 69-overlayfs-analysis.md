# overlayfs — 联合文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/overlayfs/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**overlayfs** 将两个目录"叠加"为一个视图：
- **upper**：上层目录（可写，快照）
- **lower**：下层目录（只读，底层）
- **merged**：合并后的视图（看到的）

常用于 Docker 镜像层、容器文件系统。

---

## 1. 核心数据结构

### 1.1 ovl_entry — overlay 入口

```c
// fs/overlayfs/super.c — ovl_entry
struct ovl_entry {
    // 层信息
    struct path             lower;         // 下层目录
    struct path             upper;         // 上层目录
    struct path             work;          // 工作目录（whiteout/copy_up 用）

    // inode 缓存
    struct inode            *upperinode;  // 上层 inode
    struct inode            *lowerino;     // 下层 inode
    struct inode            *ovl_inode;    // 合并的 inode

    // 标志
    unsigned long           flags;         // OVL_* 标志
    //   OVL_WHITEOUT        (whiteout 标记)
    //   OVL_UPPERDATA       (数据在上层)
};

#define OVL_COPY_UP_CHILD    (1 << 0)
```

### 1.2 ovl_inode — 合并 inode

```c
// fs/overlayfs/inode.c — ovl_inode
struct ovl_inode {
    struct inode            inode;         // VFS inode 基类

    // 来源
    enum {
        OVL_UPPER_INO,     // inode 来自上层
        OVL_LOWER_INO,     // inode 来自下层
        OVL_MERGE_INO,     // inode 来自上下层合并
    } source;

    // inode 号
    unsigned long           ino;           // inode 号（统一视图）
    unsigned long           real_ino;       // 真实 inode 号

    // 层
    struct path             lowerpath;     // 下层路径
    struct inode            *lowerinode;  // 下层 inode
    struct inode            *upperinode;  // 上层 inode

    // copy_up
    struct mutex            lock;          // 保护 copy_up
    struct dentry           *workentry;    // 工作目录条目
};
```

---

## 2. lookup — 查找流程

### 2.1 ovl_lookup — 查找合并视图中的文件

```c
// fs/overlayfs/dirf.c — ovl_lookup
static struct dentry *ovl_lookup(struct inode *inode, struct dentry *dentry, ...)
{
    struct dentry *upperdentry = NULL;
    struct dentry *lowerdentry = NULL;
    struct ovl_entry *oe = ovl_inode(inode)->oe;

    // 1. 如果有上层，先在上层查找
    if (oe->upper.mnt) {
        upperdentry = lookup_one(oe->upper.dentry, &dentry->d_name);

        // 2. 检查是否为 whiteout（.wh.文件名）
        if (d_is_whiteout(upperdentry)) {
            dput(upperdentry);
            return NULL;  // 下层同名文件被覆盖
        }
    }

    // 3. 如果有下层，在下层查找
    if (oe->lower.mnt && !upperdentry) {
        lowerdentry = lookup_one(oe->lower.dentry, &dentry->d_name);

        // 4. 如果上层存在，跳过下层
        if (upperdentry)
            dput(lowerdentry);
        else
            // 5. 没有上层，使用下层
            return lowerdentry;
    }

    // 6. 合并上下层（如果都有）
    return ovl_d_select(upperdentry, lowerdentry);
}
```

---

## 3. readdir — 合并目录

```c
// fs/overlayfs/dirf.c — ovl_iterate
static int ovl_iterate(struct file *file, struct dir_context *ctx)
{
    struct ovl_readdir_data *rd = ctx->private;

    // 1. 读取上层目录
    if (ovl_has_upper(rd->obj)) {
        ctx->pos = 0;
        iterate_upper(file, ctx);
    }

    // 2. 读取下层目录
    if (ovl_has_lower(rd->obj)) {
        ctx->pos = 0;
        iterate_lower(file, ctx);
    }

    // 3. 过滤 whiteout
    // 4. 过滤已在上层出现的下层文件名
}
```

---

## 4. copy_up — 延迟复制

```c
// fs/overlayfs/copy_up.c — ovl_copy_up
static int ovl_copy_up(struct dentry *dentry)
{
    struct path lower, upper;
    struct ovl_entry *oe = ovl_dentry(dentry)->oe;

    // 1. 获取路径
    lower = oe->lower;
    upper = oe->upper;

    // 2. 创建工作目录条目（原子操作）
    ovl_create_workdir(dentry);

    // 3. 复制文件内容
    if (S_ISDIR(d_inode(dentry)->i_mode))
        copy_dir(lower.dentry, upper.dentry);
    else
        copy_file(lower.dentry, upper.dentry);

    // 4. 设置权限
    ovl_set_attr(upper.dentry, dentry);

    // 5. 更新 dentry
    d_drop(dentry);
    d_add(dentry, upper.dentry);

    return 0;
}
```

---

## 5. Whiteout（白障）

```c
// whiteout 机制：当需要删除一个在下层存在的文件时
// 在上层创建 .wh.<文件名> 文件
// lookup 时发现 whiteout，返回"不存在"

// 例如：
// lower/  : file.txt
// upper/  : .wh.file.txt
// merged/ : file.txt 不存在（被删除）
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/overlayfs/super.c` | `struct ovl_entry` |
| `fs/overlayfs/inode.c` | `struct ovl_inode` |
| `fs/overlayfs/dirf.c` | `ovl_lookup`、`ovl_iterate` |
| `fs/overlayfs/copy_up.c` | `ovl_copy_up` |