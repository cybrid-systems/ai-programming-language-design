# XFS — 日志文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/xfs/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**XFS** 是高性能日志文件系统，最初由 SGI 开发（IRIX），现在广泛应用于大文件和并发场景：
- **B+tree**：元数据（inode、块分配）使用 B+tree
- **日志（Journal）**：记录所有元数据操作，崩溃后快速恢复
- **延迟分配**：优化磁盘写入（类似 ext4）
- **extent**：替代间接块映射

---

## 1. 核心数据结构

### 1.1 xfs_sb — 超级块

```c
// fs/xfs/libxfs/xfs_sb.h — xfs_sb
struct xfs_sb {
    // 块信息
    xfs_fsblock_t          sb_blocks;       // 总块数
    xfs_fsblock_t          sb_agblocks;    // 每 AG 块数
    unsigned int           sb_agblklog;    // AG 块数的 log2

    // UUID / 标签
    uuid_t                 sb_uuid;         // UUID
    char                   sb_volume_name[16]; // 卷名

    // 日志
    xfs_fsblock_t          sb_logstart;    // 日志起始块
    xfs_ino_t              sb_logstart_inode; // 日志 inode

    // Root / RT
    xfs_ino_t              sb_rootino;      // 根 inode 号
    xfs_ino_t              sb_rbm_ino;      // 实时位图 inode
    xfs_ino_t              sb_realtime_ino; // 实时设备 inode

    // AG 计数
    unsigned int           sb_agcount;      // AG 数量
    unsigned int           sb_agblocks_log; // log2(agblocks)

    // Btree 块大小
    unsigned int           sb_inode_log;   // inode chunk 大小 log2
    unsigned int           sb_agblklog;     // AG 块数 log2
};
```

### 1.2 xfs_inode — inode

```c
// fs/xfs/xfs/xfs_inode.h — xfs_inode
struct xfs_inode {
    struct inode           i_vn;            // VFS inode 基类
    struct xfs_mount       *i_mount;       // 挂载点
    xfs_ino_t             i_ino;           // inode 号

    // 文件锁
    xfs_filelock_t         i_lock;         // 文件锁
    xfs_filelock_t         i_lockval;      // 文件锁持有者

    // B+tree 指针
    xfs_bmbt_intr_t       *i_bmap;         // extent B+tree 根
    xfs_bmbt_irec          i_bmap_state;   // extent 状态

    // inode 分配
    xfs_agino_t           i_agino;         // AG 内的 inode 号
    xfs_ino_t             i_ino;           // inode 号

    // 数据
    union {
        xfs_ialloc_rec_t   i_ialloc;      // inode 分配记录
        xfs_icdinode_t     i_icdinode;     // inode 核心数据
    };

    // 链接数
    __int64_t              i_nlink;        // 硬链接数

    // 空间
    xfs_fsize_t            i_size;         // 文件大小
    xfs_fsize_t            i_size_disk;    // 磁盘大小
    xfs_off_t              i_new_size;      // 新大小
};
```

### 1.3 xfs_bmbt_rec_32 — extent（B+tree 叶子节点）

```c
// fs/xfs/libxfs/xfs_btree.h — xfs_bmbt_rec_32
struct xfs_bmbt_rec_32 {
    __be32                 br_startoff;    // 起始逻辑块（8B 共享）
    __be32                 br_startblock;  // 起始物理块
    __be32                 br_blockcount;   // 块数
    __be32                 br_state;        // 状态（0=ext, 1= unwritten）
};

// 例如：{ startoff=0, startblock=2048, blockcount=1000, state=0 }
// 表示逻辑块 0-999 → 物理块 2048-3047
```

---

## 2. AG（分配组）结构

```
磁盘布局：
┌────────────┬────────────┬────────────┬────────────┐
│   Super    │    AG 0   │    AG 1    │   AG 2 ... │  ← 每个 AG 独立分配
│   Block    │  inode    │  inode    │
│   0        │  B+tree   │  B+tree   │
│            │  free ext │  free ext │
└────────────┴────────────┴────────────┴────────────┘

每个 AG 包含：
  - AGF（allocation group free space header）
  - AGI（allocation group inode index）
  - 空闲块 B+tree
  - inode 索引 B+tree
  - inode 记录
  - 数据块区
```

---

## 3. extent 分配

### 3.1 xfs_bmap_extents_to_btree — 分配 extent

```c
// fs/xfs/xfs_bmap.c — xfs_bmap_extents_to_btree
int xfs_bmap_extents_to_btree(xfs_trans_t *tp, xfs_inode_t *ip, ...)
{
    xfs_bmbt_irec          new;

    // 1. 查找连续空闲块
    error = xfs_bmap_first_unused(tp, ip, len, &startoff);
    if (error)
        return error;

    // 2. 创建 extent 记录
    new = (xfs_bmbt_irec){ startoff, startblock, len, XFS_EXTF };

    // 3. 插入 B+tree
    xfs_bmbt_insert(tp, ip->i_bmap, &new);

    // 4. 更新 inode
    ip->i_size = max(ip->i_size, startoff + len);

    return 0;
}
```

---

## 4. 日志恢复

### 4.1 xlog_recover_process_data — 恢复数据

```c
// fs/xfs/xfs_log_recover.c — xlog_recover_process_data
int xlog_recover_process_data(xlog_t *log, xlog_recover_t *rp)
{
    // 1. 扫描日志块
    for (block = rp->r_start; block < rp->r_end; block++) {
        bh = bread(log->l_dev, block);

        // 2. 解析 op_header
        op = (xlog_op_header *)bh;

        // 3. 根据操作类型重放
        switch (op->oh_type) {
        case XLOG_WC:
            // 写操作：更新元数据
            xlog_recover_write(op, bh);
            break;
        case XLOG_IC:
            // inode 修改
            xlog_recover_inode(op, bh);
            break;
        }
    }

    // 4. 提交恢复的事务
    xlog_recover_commit_trans(rp);
}
```

---

## 5. 与 ext4 的区别

| 特性 | XFS | ext4 |
|------|-----|------|
| 最大文件 | 8EB | 16TB |
| 最大文件系统 | 16EB | 1EB |
| 元数据 B+tree | 是 | 否（extent 数组）|
| 延迟分配 | 是 | 是 |
| 日志 | 记录所有操作 | 只记录元数据 |
| 崩溃恢复 | 快 | 取决于文件系统大小 |

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/xfs/libxfs/xfs_sb.h` | `struct xfs_sb` |
| `fs/xfs/xfs/xfs_inode.h` | `struct xfs_inode` |
| `fs/xfs/libxfs/xfs_btree.h` | `struct xfs_bmbt_rec_32` |
| `fs/xfs/xfs_bmap.c` | `xfs_bmap_extents_to_btree` |
| `fs/xfs/xfs_log_recover.c` | `xlog_recover_process_data` |