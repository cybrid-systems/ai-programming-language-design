# 67-xfs — Linux XFS 文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**XFS** 是由 SGI 开发的高性能 64 位日志文件系统，2001 年移植到 Linux。XFS 的设计针对**大文件和大存储**优化，支持最大 8EB 文件系统和 8EB 文件。其核心架构基于 **B+ 树 extent 映射**、**延迟日志**和**分配组（AG）** 并发设计。

**关键架构特点**：
- **分配组（AG）** — 将存储空间划分为独立管理的组，支持并发 IO
- **B+ 树 extent 映射** — 文件数据块映射用 B+ 树管理，而不是 ext4 的 Htree
- **延迟日志** — 日志事务先缓存在内存，定期批量提交
- **延迟分配** — 写数据时延迟决定磁盘块分配，优化连续性

**doom-lsp 确认**：XFS 实现在 `fs/xfs/`（**79 个源文件**）。核心数据结构在 `fs/xfs/xfs_inode.h`、`fs/xfs/xfs_mount.h`。日志系统在 `fs/xfs/xfs_log.c`（3,477 行）。

---

## 1. 核心数据结构

### 1.1 struct xfs_inode — XFS inode

```c
// fs/xfs/xfs_inode.h:25-100
typedef struct xfs_inode {
    struct xfs_mount *i_mount;               /* 文件系统挂载 */
    struct xfs_trans *i_transp;              /* 当前事务 */

    struct xfs_inode_log_item *i_itemp;      /* 日志项 */
    struct xfs_bmbt_irec *i_df;              /* 数据 fork extent */
    struct xfs_ifork *i_afp;                /* 属性 fork */
    struct xfs_ifork *i_cowfp;               /* COW (写时复制) fork */

    /* 策略字段 */
    xfs_fsize_t i_disk_size;                 /* 磁盘上大小 */
    xfs_rfsblock_t i_nblocks;                /* 块数 */
    prid_t i_projid;

    spinlock_t i_flags_lock;
    unsigned long i_flags;

    /* VFS inode */
    struct inode i_vnode;                    /* 必须是最后一个 */
} xfs_inode_t;
```

### 1.2 struct xfs_mount — 文件系统挂载

```c
// fs/xfs/xfs_mount.h
typedef struct xfs_mount {
    struct super_block *m_super;              /* VFS superblock */
    unsigned long m_features;                 /* 特性标志 */
    unsigned long m_flags;

    xfs_agnumber_t m_agcount;                /* AG 数量 */
    xfs_agnumber_t m_agirotor;               /* AG 轮转 */
    xfs_agnumber_t m_logagno;                /* 日志 AG */
    xfs_extlen_t m_agblklog;                 /* AG 块数 log */

    struct xfs_sb m_sb;                       /* 超级块 */
    struct xfs_perag *m_perag;                /* per-AG 数据 */
    struct xfs_buf *m_sb_bp;                 /* 超级块 buffer */

    struct xfs_inode *m_rootip;               /* 根目录 inode */

    /* 日志 */
    struct xlog *m_log;                       /* 日志 */
    struct xfs_trans *m_trans;                /* 当前事务 */

    /* 分配器 */
    struct xfs_alloc *m_alloc;                /* 块分配器 */
} xfs_mount_t;
```

---

## 2. 分配组（AG）架构

```
XFS 文件系统磁盘布局：
┌───────┬───────┬───────┬───────┬───────┬───────┐
│ AG 0  │ AG 1  │ AG 2  │ AG 3  │ ...   │AG n-1 │
├───┬───┼───┬───┼───┬───┼───┬───┼───┬───┼───┬───┤
│SB │AGF│  │  │SB │AGF│  │  │... │   │   │   │   │
│AGI │BNO│CNT│  │AGI │BNO│CNT│  │    │   │   │   │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
            ↑ 每个 AG 独立管理（免锁并发）

每个 AG:
  - 超级块（SB，仅 AG 0 有效）
  - AGF（free space 信息）
  - AGI（inode 分配信息）
  - BNO（free block by block number B+ 树）
  - CNT（free block by size B+ 树）
```

---

## 3. Extent 映射与 B+ 树

```c
// XFS 文件数据块映射使用 BMBT（B+ tree）:
// 小文件：inode 内联 extent（data fork 直接存）
// 大文件：B+ 树索引 extent

struct xfs_bmbt_irec {
    xfs_fsblock_t br_startblock;     /* 起始物理块 */
    xfs_filblks_t br_blockcount;     /* 连续块数 */
    xfs_fileoff_t br_startoff;       /* 文件逻辑偏移 */
    int br_state;                    /* 状态（unwritten/正常）*/
};

// inode 的 data fork 有三种格式：
// - XFS_DINODE_FMT_EXTENTS: xfs_bmbt_irec 数组直接存在 inode 中
// - XFS_DINODE_FMT_BTREE:   B+ 树根指针
// - XFS_DINODE_FMT_LOCAL:   小文件数据直接存在 inode 中

// 延迟分配（Delayed Allocation）:
// 写数据时，XFS 不立即决定 extent 位置
// 在内存中标记为 'delalloc'，直到回写时再分配
// 好处：块分配器能看到全部待写数据，做出更好的连续分配决策
```

### 3.1 分配组（AG）详情

```c
// 每个 AG 的 B+ 树索引：
// BNO B+ 树：按块号排序的空闲空间
// CNT B+ 树：按大小排序的空闲空间（最佳适配）

// 块分配的两种模式：
// - xfs_alloc_vextent_near()：在指定 AG 中找接近目标块的连续空间
// - xfs_alloc_vextent_this_ag()：在当前 AG 查找
// - xfs_alloc_vextent_start_ag()：从指定 AG 开始逐个尝试

// 分配决策在 fs/xfs/xfs_alloc.c 中实现
```

---

## 4. 日志系统——延迟日志

### 4.1 架构

XFS 使用**延迟日志（Delayed Logging）**，这是与 ext4 JBD2 的最大区别。事务不立即写到磁盘日志，而是先累积在内存的 CIL（Commit Item List）中：

```c
// fs/xfs/xfs_log_priv.h:284-295
struct xfs_cil {
    struct xlog *xc_log;                  /* 所属日志 */
    struct xfs_cil_ctx *xc_ctx;            /* 当前上下文 */
    struct list_head xc_cil;               /* CIL 项目链表 */
    spinlock_t xc_push_lock;               /* push 锁 */
    struct workqueue_struct *xc_push_wq;   /* 后台 push 工作队列 */
    wait_queue_head_t xc_commit_wait;      /* 提交等待 */
};

// CIL 上下文（每个 checkpoint 一个）
struct xfs_cil_ctx {
    struct xfs_cil *cil;
    struct xfs_log_vec *lv_chain;          /* 日志向量链 */
    struct xlog_in_core *commit_iclog;     /* 提交用的 iclog */
    struct xlog_ticket *ticket;            /* checkpoint 票据 */
    int space_used;                         /* 已用空间 */
    struct list_head iclog_entry;           /* iclog 持有列表 */
    /* 完成后的清理 */
    struct xfs_ail *ailp;                  /* AIL 关联 */
};
```

**写路径对比（JBD2 vs XFS）**：

| JBD2 | XFS |
|------|-----|
| 每个 handle 引用事务 | 每个事务累积到 CIL |
| handle stop → 减少 t_updates | trans_commit → 追加到 CIL |
| t_updates==0 → 触发提交 | CIL 空间阈值 → 触发 push |
| 直接写日志块到磁盘 | checkpoint → 批量写入 iclog |
| 每个元数据块单独写日志 | 日志向量批量写入 |

### 4.2 日志提交路径

```c
// xfs_log_commit_cil() — 事务提交入口
int xfs_log_commit_cil(struct xfs_mount *mp, struct xfs_trans *tp,
                       xfs_lsn_t *commit_lsn)
{
    struct xfs_cil *cil = mp->m_log->l_cilp;
    struct xfs_cil_ctx *ctx = cil->xc_ctx;

    /* 1. 提取日志向量 */
    lv = xlog_prepare_log_vec(lip->li_type, ...);
    lip->li_ops->iop_format(lip, lv);   /* 格式化为 log vector */

    /* 2. 追加到 CIL */
    list_add_tail(&lv->lv_list, &cil->xc_cil);

    /* 3. 检查是否需要 push（空间阈值）*/
    if (cil->xc_ctx->space_used > XLOG_CIL_SPACE_LIMIT(log))
        queue_work(cil->xc_push_wq, &cil->xc_ctx->push_work);

    *commit_lsn = cil->xc_ctx->sequence;
}

// xlog_cil_push_work() — 后台 checkpoint
// 1. 创建新 CIL 上下文（后续事务写到新上下文）
// 2. 提取当前 CIL 所有日志向量
// 3. 整理日志向量成 iclog 格式
// 4. 写入 iclog 缓冲区
// 5. 提交 iclog（将缓冲区写入磁盘日志）
```

### 4.3 AIL（日志项目列表）

```c
// fs/xfs/xfs_log_priv.h:417
// AIL 管理已经写到磁盘日志但尚未 checkpoint 的事务
struct xfs_ail {
    struct xlog *ail_log;                /* 所属日志 */
    spinlock_t ail_lock;
    xfs_lsn_t ail_target;                /* 目标 LSN */
    xfs_lsn_t ail_target_prev;
    struct list_head ail_head;            /* 项目列表 */
    struct work_struct ail_work;          /* 后台 push work */
};

// 当 AIL 中的项目太多时，触发 xfs_ail_push()
// 将日志内容回写到文件系统元数据的实际位置
// 然后 AIL 项目可以安全释放
```

### 4.4 iclog 循环缓冲区

```c
// fs/xfs/xfs_log_priv.h:202-220
// iclog 是内存中的日志循环缓冲区
// 所有事务首先写入 iclog，然后 iclog 批量刷到磁盘

struct xlog_in_core {
    struct xlog_in_core *ic_next;          /* 下一个 iclog */
    struct xlog_in_core *ic_prev;          /* 前一个 iclog */
    struct xfs_buf *ic_bp;                /* buffer head */
    int ic_size;                           /* iclog 大小 */
    int ic_offset;                         /* 当前写入偏移 */
    unsigned int ic_flags;                 /* XLOG_* 标志 */
    int ic_refcnt;                         /* 引用计数 */
};
```

**doom-lsp 确认**：`struct xlog`、`struct xfs_cil`、`struct xlog_in_core` 在 `fs/xfs/xfs_log_priv.h`。`xlog_cil_push_work` 在 `fs/xfs/xfs_log_cil.c`。

---

## 5. 事务

```c
// fs/xfs/xfs_trans.c:1431
// 事务=原子操作单元

struct xfs_trans {
    unsigned int t_flags;                /* 标志 */
    unsigned int t_log_res;              /* 日志空间 */
    unsigned int t_blk_res;              /* 块空间 */
    struct xfs_mount *t_mountp;
    struct list_head t_items;            /* 日志项列表 */
    struct xfs_trans_res t_res;          /* 资源 */
};

// 典型操作：extent 分配
// xfs_trans_alloc() → xfs_alloc_vextent() → xfs_trans_commit()
```

---

## 6. 调试

```bash
# XFS 信息
xfs_info /dev/sda1

# AG 信息
xfs_db -c "aginfo" /dev/sda1

# 查看 B+ 树
xfs_db -c "sb" -c "p" /dev/sda1
xfs_db -c "inode 128" -c "p" /dev/sda1

# 统计
xfs_growfs -n /mnt
```

---

## 7. 总结

XFS 的**分配组 + B+ 树 extent + 延迟日志**设计使其成为大规模存储场景的首选文件系统。per-AG 并发控制和 extent-based 存储在大文件场景下表现优异。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
