# Linux Kernel btrfs 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/btrfs/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. btrfs 核心特性

**btrfs（B-tree FS）** 是现代 COW 文件系统：
- **COW（Copy-on-Write）**：写入新块，不修改原块
- **校验和**：数据/元数据都有 CRC32C 校验
- **多设备**：RAID0/1/5/6/10 / 混合存储
- **snapshot / clone**：即时快照，零拷贝克隆
- **压缩**：zlib / zstd 在线压缩

---

## 1. 核心结构

```c
// fs/btrfs/ctree.h — btrfs_root
struct btrfs_root {
    struct btrfs_fs_info   *fs_info;     // 文件系统信息
    struct btrfs_key       root_key;      // root key（objectid）
    struct btrfs_root     *log_root;     // 日志根
    struct btrfs_root     *reloc_root;   // 迁移根

    /* B+tree 根 */
    struct extent_buffer   *node;          // 根节点
    struct extent_buffer   *commit_root;  // 当前提交根

    /* 写回 */
    u64                   last_trans;     // 最后事务 ID
};

// btrfs_inode — inode + COW 信息
struct btrfs_inode {
    struct inode           vfs_inode;
    u64                   root;           // 所属 subvolume
    u64                   generation;     // inode 代际
    struct btrfs_delayed_node *delayed_node;  // 延迟节点
};
```

---

## 2. COW 写入

```
写操作：
1. 分配新 extent（新磁盘位置）
2. 写入新 extent
3. 更新 B+tree 节点（新节点指向新 extent）
4. 原 extent 保留（用于快照）

优势：写入失败不破坏原数据，快照零拷贝
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `fs/btrfs/ctree.h` | B+tree 定义 |
| `fs/btrfs/inode.c` | COW 写入 |
| `fs/btrfs/send.c` | snapshot 发送（增量）|
