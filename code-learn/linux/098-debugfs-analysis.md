# 098-debugfs — Linux debugfs 文件系统深度源码分析

## 0. 概述

**debugfs** 是一个简单的内存文件系统（通常挂载在 `/sys/kernel/debug`），为内核开发者提供导出调试信息的简单接口。不保证 ABI 稳定，仅用于开发和调试。

## 1. 核心 API

```c
// 创建文件和目录：
struct dentry *debugfs_create_file(const char *name, umode_t mode,
    struct dentry *parent, void *data, const struct file_operations *fops);
struct dentry *debugfs_create_dir(const char *name, struct dentry *parent);

// 创建类型化文件（简化操作）：
void debugfs_create_u8(const char *name, umode_t mode, struct dentry *parent, u8 *value);
void debugfs_create_u32(const char *name, umode_t mode, struct dentry *parent, u32 *value);
void debugfs_create_bool(const char *name, umode_t mode, struct dentry *parent, bool *value);
void debugfs_create_x64(const char *name, umode_t mode, struct dentry *parent, u64 *value);

// 删除：
void debugfs_remove(struct dentry *dentry);
void debugfs_remove_recursive(struct dentry *dentry);
```

## 2. 源码索引

| 符号 | 文件 |
|------|------|
| `debugfs_create_file()` | fs/debugfs/inode.c |
| `debugfs_create_dir()` | fs/debugfs/inode.c |
| `debugfs_remove()` | fs/debugfs/inode.c |
