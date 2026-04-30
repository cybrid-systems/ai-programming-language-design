# Linux Kernel XFS 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/xfs/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. XFS 特点

**XFS** 是高性能日志文件系统，专为大文件和高并发设计：
- **extent-based inode**：大文件不连续分配块
- **B+tree inode index**：支持百万级文件
- **实时日志**：日志在独立日志设备，性能更好
- **延迟分配**：性能优化，先分配再写

---

## 1. 核心结构

```c
// fs/xfs/xfs_inode.h — xfs_inode
struct xfs_inode {
    struct inode       i_vnode;          // VFS inode
    xfs_ino_t         i_ino;            // inode 号
    struct xfs_imap    i_imap;           // inode 在磁盘位置

    /* extent 信息 */
    struct xfs_ifork  *i_afp;          // extent 分配fork
    struct xfs_bmbt_irec *i_cfp;        // 在线碎片

    /* extent B+tree 根 */
    struct xfs_bmbt_root *i_bmbt;     // extent B+tree 根

    /* 日志序列号（恢复用）*/
    xfs_lsn_t         i_lsn;
};
```

---

## 2. 参考

| 文件 | 内容 |
|------|------|
| `fs/xfs/xfs_inode.c` | XFS inode 操作 |
| `fs/xfs/xfs_bmap.c` | extent 管理（分配/拆分/合并）|
| `fs/xfs/xfs_log.c` | XFS 日志系统 |
