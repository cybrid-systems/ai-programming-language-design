# debugfs — 调试文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/debugfs/inode.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**debugfs** 是内核开发者专用的调试文件系统，挂载在 `/sys/kernel/debug`（或 `/d`），用于导出内部状态。

---

## 1. 核心数据结构

```c
// fs/debugfs/inode.c — debugfs_fs_info
struct debugfs_fs_info {
    // 文件系统信息
    struct super_block      *sb;           // 超级块

    // inode
    struct inode            *root_inode;   // 根 inode

    // 选项
    umode_t                 mode;          // 默认权限
};
```

---

## 2. 创建文件和目录

### 2.1 debugfs_create_file

```c
// fs/debugfs/inode.c — debugfs_create_file
struct dentry *debugfs_create_file(const char *name, umode_t mode,
                                    struct dentry *parent, void *data,
                                    const struct file_operations *fops)
{
    // 1. 创建 dentry
    struct dentry *dentry = d_make_root(parent);

    // 2. 设置 inode
    // 3. 关联 file_operations
    // 4. 关联私有数据

    return dentry;
}

// 示例：驱动注册 debug 文件
debugfs_create_file("my_debug", 0644, NULL, driver_data, &my_fops);
```

### 2.2 debugfs_create_dir

```c
// fs/debugfs/inode.c — debugfs_create_dir
struct dentry *debugfs_create_dir(const char *name, struct dentry *parent)
{
    return debugfs_create_file(name, S_IFDIR | 0755, parent, NULL, NULL);
}
```

---

## 3. 常用 API

```c
// 创建各种 debugfs 条目
debugfs_create_file(name, mode, parent, data, &fops);    // 普通文件
debugfs_create_dir(name, parent);                        // 目录
debugfs_create_u8(name, mode, parent, u8 *ptr);           // u8 值
debugfs_create_u32(name, mode, parent, u32 *ptr);        // u32 值
debugfs_create_bool(name, mode, parent, u32 *ptr);       // 布尔值
debugfs_create_blob(name, mode, parent, struct debugfs_blob *blob); // 二进制数据
```

---

## 4. 挂载点

```
/sys/kernel/debug/        ← 主目录
/sys/kernel/debug/tracing/ ← ftrace
/sys/kernel/debug/clk/    ← 时钟
/sys/kernel/debug/gpio/    ← GPIO
/sys/kernel/debug/dma/      ← DMA
```

---

## 5. 完整文件索引

| 文件 | 函数 |
|------|------|
| `fs/debugfs/inode.c` | `debugfs_create_file`、`debugfs_create_dir` |