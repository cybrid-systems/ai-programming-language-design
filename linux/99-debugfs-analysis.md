# 99-debugfs — 内核调试文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`lib/debugfs/` + `fs/debugfs/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**debugfs** 是 Linux 内核专门用于调试的文件系统，挂在 `/sys/kernel/debug/`，提供简单的文件/目录接口，让内核代码可以轻松暴露调试信息给用户空间。

---

## 1. debugfs vs sysfs vs procfs

| 特性 | debugfs | sysfs | procfs |
|------|---------|-------|--------|
| 用途 | 内核调试 | 设备/驱动信息 | 进程/系统信息 |
| 结构 | 任意 | 严格层级 | 任意 |
| API | 简单 | 严格规范 | 复杂 |
| 稳定性 | 不保证 | 稳定 | 部分保证 |

---

## 2. 核心 API

### 2.1 debugfs_create_file — 创建调试文件

```c
// lib/debugfs/prims.c — debugfs_create_file
struct dentry *debugfs_create_file(const char *name, umode_t mode,
                                   struct dentry *parent,
                                   void *data,
                                   const struct dentry_operations *dops)
{
    struct dentry *dentry;

    // 1. 创建 dentry
    dentry = debugfs_lookup(name, parent);
    if (dentry)
        return dentry;

    // 2. 创建 inode
    inode = debugfs_get_inode(dentry->d_sb, S_IFREG | mode);

    // 3. 设置文件操作
    inode->i_fop = debugfs_file_operations;
    inode->i_private = data;  // 关联内核数据

    // 4. d_instantiate
    d_instantiate(dentry, inode);

    return dentry;
}
```

### 2.2 debugfs_create_dir — 创建目录

```c
// lib/debugfs/prims.c — debugfs_create_dir
struct dentry *debugfs_create_dir(const char *name, struct dentry *parent)
{
    return debugfs_create_file(name, S_IFDIR | 0755, parent, NULL,
                               &debugfs_dir_operations);
}
```

### 2.3 debugfs_create_regset32 — 创建寄存器集

```c
// lib/debugfs/regset32.c — debugfs_create_regset32
struct dentry *debugfs_create_regset32(const char *name, umode_t mode,
                                       struct dentry *parent,
                                       struct debugfs_regset32 *regset)
{
    struct dentry *dentry;

    dentry = debugfs_create_file(name, mode, parent, regset,
                                 &debugfs_regset32_fops);

    return dentry;
}
```

---

## 3. 文件操作

### 3.1 debugfs_open — 打开文件

```c
// lib/debugfs/file.c — debugfs_open
static int debugfs_open(struct inode *inode, struct file *filp)
{
    filp->private_data = inode->i_private;  // 恢复 data

    // 调用用户提供的 open
    if (debugfs_real_fops(inode)->open)
        debugfs_real_fops(inode)->open(inode, filp);

    return 0;
}
```

---

## 4. 常用辅助函数

```c
// lib/debugfs/prims.c — 常用创建函数
debugfs_create_bool(name, mode, parent, value)       // 布尔值（0/1）
debugfs_create_u8(name, mode, parent, value)        // u8
debugfs_create_u16(name, mode, parent, value)       // u16
debugfs_create_u32(name, mode, parent, value)        // u32
debugfs_create_u64(name, mode, parent, value)        // u64
debugfs_create_x32(name, mode, parent, value)        // 十六进制 u32
debugfs_create_size_t(name, mode, parent, value)     // size_t
debugfs_create_str(name, mode, parent, value)        // 字符串
debugfs_create_blob(name, mode, parent, value)       // 二进制 blob
```

---

## 5. seq_file 接口

### 5.1 debugfs_create_seq_file — 顺序文件

```c
// lib/debugfs/seq_file.c — debugfs_create_seq_file
// 用于大量数据的顺序读取
struct dentry *debugfs_create_seq_file(const char *name,
                                       struct dentry *parent,
                                       const struct seq_operations *ops)
{
    // 创建 seq_file，底层调用 seq_read()
    // ops->start(), ->next(), ->stop(), ->show()
}
```

---

## 6. 使用示例

```c
// 内核模块中使用 debugfs：
static struct dentry *debugfs_parent;
static u32 dbg_value = 0;

static int __init my_init(void)
{
    // 创建目录
    debugfs_parent = debugfs_create_dir("my_driver", NULL);

    // 创建调试值
    debugfs_create_u32("value", 0644, debugfs_parent, &dbg_value);

    return 0;
}

// 用户空间：
//   cat /sys/kernel/debug/my_driver/value
//   echo 123 > /sys/kernel/debug/my_driver/value
```

---

## 7. 挂载点

```bash
# 手动挂载
mount -t debugfs none /sys/kernel/debug

# 默认挂载（如果配置了）
# /sys/kernel/debug  ← debugfs 根目录
```

---

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `lib/debugfs/prims.c` | `debugfs_create_file`、`debugfs_create_dir`、`debugfs_create_u32` |
| `lib/debugfs/file.c` | `debugfs_open`、`debugfs_read`、`debugfs_write` |
| `lib/debugfs/seq_file.c` | `debugfs_create_seq_file` |

---

## 9. 西游记类比

**debugfs** 就像"土地神的公告栏"——

> debugfs 是内核留给开发者查看和修改状态的"公告栏"。不像 sysfs 那样有严格的层级规定（设备-驱动-属性），debugfs 可以随意创建文件和目录土地神（内核模块）想公开什么信息，就在公告栏贴一张纸（创建文件），写上当前状态（read），也可以接受上级部门的指令（write）。seq_file 就像一张可以翻页的大表格（sequential file），显示大量信息。比起其他文件系统，debugfs 就是给开发者自己看的，不保证长期稳定。

---

## 10. 关联文章

- **procfs**（article 98）：另一种调试信息接口
- **sysfs**（相关）：设备/驱动信息的规范化接口