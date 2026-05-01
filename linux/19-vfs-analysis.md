# 19-VFS — 虚拟文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**VFS（Virtual File System）** 是文件系统抽象层。它定义所有文件系统必须实现的接口，使 open/read/write/close 统一适用于 ext4、XFS、btrfs、NFS 等。

四个核心对象：**super_block**（文件系统实例）、**inode**（文件元数据）、**dentry**（路径组件缓存）、**file**（已打开文件）。

doom-lsp 确认 `include/linux/fs.h` 包含 1650+ 符号（最大头文件之一）。

---

## 1. 对象关系

```
文件系统实例（super_block）
  ├── 根 dentry (s_root)
  │     └── root inode（根目录元数据）
  │           └── dentry child（子文件/目录）
  │                 └── inode（文件元数据）
  │                       └── address_space（page cache）
  │
  fd → struct file（打开上下文）
       ├── f_path.dentry → dentry（路径）
       └── f_mapping → address_space（数据缓存）
```

---

## 2. 核心操作路径

### 2.1 open

```
do_sys_open(filename, flags, mode)
  │
  ├─ get_unused_fd_flags()          ← 分配 fd
  ├─ do_filp_open(dfd, filename, op)
  │    └─ path_openat(nd, op, flags)
  │         ├─ path_walk() 路径解析
  │         │    ├─ __d_lookup(path) → dentry cache
  │         │    └─ 未命中 → inode->i_op->lookup()
  │         ├─ dentry_open(path, flags, cred) → alloc file
  │         └─ file->f_op = inode->i_fop
  └─ fd_install(fd, file)
```

### 2.2 read

```
vfs_read(file, buf, count, pos)
  │
  └─ file->f_op->read_iter(file, &iter)
       └─ generic_file_read_iter()
            └─ filemap_read() → page cache 查找
                 ├─ 命中：copy_page_to_iter()
                 └─ 未命中：filemap_fault() → 磁盘 IO
```

---

## 3. dcache（dentry cache）

dentry cache 缓存已解析的路径名→inode 映射：

```
open("/home/user/file.txt")
  │
  ├─ __d_lookup("file.txt", parent_dentry)
  │    ├─ 哈希表查找 → 命中 → 直接返回 inode
  │    └─ 未命中 → ext4_lookup() → 磁盘 IO → 创建 dentry
  │
  └─ dentry 加入 LRU 链表
       └─ 内存压力时回收
```

---

## 4. 设计决策

| 决策 | 原因 |
|------|------|
| 四对象分离 | 解耦路径解析、元数据、打开状态 |
| dentry cache | 加速路径查找，减少磁盘 IO |
| file_operations 回调 | 每种文件系统定制操作 |

---

*分析工具：doom-lsp（clangd LSP）*
