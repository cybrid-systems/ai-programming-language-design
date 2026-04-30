# Linux Kernel overlayfs 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/overlayfs/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. overlayfs

**overlayfs** 将多个目录**层叠**展示为单一目录，容器镜像（Docker）的存储驱动正是它。

---

## 1. 层结构

```
overlayfs mount：

/lower/          （底层，只读，通常是 base image）
/upper/           （顶层，可写，通常是 container diff）
/work/            （白屏区，rename2 用）

合并后视图：
/merged/
 ├── lowerdir/lower1        ← 来自底层
 ├── lowerdir/lower2        ← 来自底层
 ├── upperdir/               ← 来自顶层（可写）
 └── work/                   ← 内部工作区
```

---

## 2. 核心操作

```c
// fs/overlayfs/super.c — ovl_lookup
static struct dentry *ovl_lookup(struct inode *dir, ...)
{
    // 1. 先查 upper（顶层优先）
    upper = ovl_lookup_real(upperdir, name);

    // 2. 再查 lower（底层）
    lower = ovl_lookup_real(lowerdir, name);

    // 3. 合并：upper 存在则覆盖 lower
    if (upper)
        return upper;
    return lower;
}
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `fs/overlayfs/super.c` | super block 初始化 |
| `fs/overlayfs/namei.c` | `ovl_lookup`、`ovl_create` |
