# 097-procfs-sysctl — Linux procfs 和 sysctl 机制深度源码分析

## 0. 概述

**procfs**（/proc）和 **sysctl**（/proc/sys）是 Linux 内核的运行时配置接口。procfs 通过注册 `proc_dir_entry` 暴露文件，sysctl 通过 `ctl_table` 注册内核参数。

---

## 1. procfs 核心

```c
struct proc_dir_entry {
    unsigned int            low_ino;        // inode 号
    umode_t                 mode;           // 文件权限
    struct proc_dir_entry   *parent;        // 父目录
    const char              *name;          // 文件名
    struct proc_dir_entry   *next, *subdir; // 链表
    const struct proc_ops   *proc_ops;      // 文件操作（proc_read/proc_write/proc_open/release/ioctl）
    union {
        const void          *data;          // 私有数据
        atomic_t            size;           // 大小
    };
};
```

## 2. sysctl 核心

```c
struct ctl_table {
    const char              *procname;      // 参数名（如 "vm/swappiness"）
    void                    *data;          // 内核变量地址
    int                     maxlen;         // 最大长度
    umode_t                 mode;           // 权限
    proc_handler            *proc_handler;  // 读写处理器
    struct ctl_table_poll   *poll;          // poll 支持
};
```

## 3. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct proc_dir_entry` | include/linux/proc_fs.h | 核心 |
| `proc_create()` | fs/proc/generic.c | 创建 proc 文件 |
| `struct ctl_table` | include/linux/sysctl.h | 核心 |
| `register_sysctl()` | fs/proc/proc_sysctl.c | 注册 sysctl |
