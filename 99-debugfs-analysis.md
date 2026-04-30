# Linux Kernel debugfs 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/debugfs/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. debugfs 概述

**debugfs** 是内核提供给开发者的**调试文件系统**（挂载于 `/sys/kernel/debug/`），比 `pr_debug()` 更结构化，允许读写内核内部状态。

---

## 1. 核心 API

```c
// fs/debugfs/inode.c — debugfs_create_file
struct dentry *debugfs_create_file(const char *name, umode_t mode,
                    struct dentry *parent, void *data,
                    const struct file_operations *fops)
{
    // 1. 创建 dentry
    dentry = d_alloc_name(parent, name);

    // 2. 注册到 debugfs
    d_instantiate(dentry, inode);
    inode->i_fop = &debugfs_file_operations;
    inode->i_private = data;  // 私有数据传给 fops

    return dentry;
}

// 使用示例：
// 创建文件：
debugfs_create_file("my_debug", 0644, parent, &my_data, &my_fops);

// 创建 u32 值：
debugfs_create_u32("my_u32", 0644, parent, &my_value);

// 创建布尔值：
debugfs_create_bool("my_bool", 0644, parent, &my_bool);
```

---

## 2. 常用 debugfs 文件类型

```c
// 原子变量
struct dentry *debugfs_create_atomic_t(const char *name, umode_t mode,
                    struct dentry *parent, atomic_t *value);

// 创建位域
struct dentry *debugfs_create_x8(const char *name, umode_t mode,
                    struct dentry *parent, u8 *value);

// 创建 blob（二进制数据）
struct dentry *debugfs_create_blob(const char *name, umode_t mode,
                    struct dentry *parent, struct debugfs_blob_wrapper *blob);
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `fs/debugfs/inode.c` | `debugfs_create_file` |
| `include/linux/debugfs.h` | 所有 debugfs_create_* 函数声明 |
