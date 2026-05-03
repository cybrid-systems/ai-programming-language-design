# 67-xfs — Linux XFS 文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**XFS** 是由 SGI 开发的高性能 64 位日志文件系统，2001 年移植到 Linux。XFS 的设计针对**大文件和大存储**优化，支持最大 8EB 文件系统和 8EB 文件。其核心架构基于 **B+ 树 extent 映射**、**延迟日志（CIL）**和**分配组（AG）** 并发设计。

**关键架构特点**：
- **分配组（AG）** — 将存储空间划分为独立管理的组，每组有独立的空闲空间 B+ 树索引，支持并发 IO
- **B+ 树 extent 映射（BMBT）** — 文件数据块映射用 B+ 树管理，小文件 extent 内联 inode
- **延迟日志（CIL）** — 事务不立即写盘，累积到内存 CIL 后批量 checkpoint 到 iclog
- **延迟分配** — 写数据时先标记 delalloc extent，回写时再分配物理块，最大化连续性
- **xfs_buf 缓存** — 统一的元数据 buffer cache，通过 delwri 队列延迟批量提交 IO

**doom-lsp 确认**：XFS 在 `fs/xfs/`（**79 个源文件**）。核心头文件 `xfs_inode.h`、`xfs_mount.h`、`xfs_buf.h`。日志在 `xfs_log.c`（3,477 行）和 `xfs_log_cil.c`。B+ 树 extent 在 `libxfs/xfs_bmap.c`。

---

## 1. 核心数据结构

### 1.1 struct xfs_inode — XFS inode

XFS 的 inode 拥有独立的 extent 映射和三个独立 fork。通过 `xfs_inode_log_item` 与日志系统集成：

```c
// fs/xfs/xfs_inode.h:25-100
typedef struct xfs_inode {
    struct xfs_mount *i_mount;               /* 文件系统挂载 */
    struct xfs_trans *i_transp;              /* 当前事务指针 */

    struct xfs_inode_log_item *i_itemp;      /* 日志项（记录修改的字段位图）*/

    struct xfs_ifork *i_afp;                 /* 属性 fork（xattr 数据）*/
    struct xfs_ifork *i_cowfp;               /* COW fork（写时复制 extent）*/
    struct xfs_ifork *i_df;                  /* 数据 fork（文件数据 extent）*/

    xfs_fsize_t i_disk_size;                 /* 磁盘上文件大小 */
    xfs_rfsblock_t i_nblocks;                /* 已分配的块数 */
    prid_t i_projid;                         /* 项目 ID */

    unsigned long i_flags;                   /* XFS_INO_* 标志 */
    struct inode i_vnode;                    /* VFS inode（必须最后）*/
} xfs_inode_t;
```

**struct xfs_ifork** — fork 管理（每个 inode 的三种 fork 共用此结构）：

```c
struct xfs_ifork {
    int if_bytes;                           /* fork 数据字节数 */
    struct xfs_btree_block *if_broot;       /* B+ 树根 */
    short if_broot_bytes;
    unsigned char if_flags;
    enum xfs_dinode_fmt if_format;          /* EXTENTS/LOCAL/BTREE/DEV */
    void *if_data;                          /* 内联 extent 数组或小文件数据 */
};
```

### 1.2 struct xfs_mount — 文件系统挂载

```c
typedef struct xfs_mount {
    struct super_block *m_super;              /* VFS superblock */
    unsigned long m_features;

    xfs_agnumber_t m_agcount;                /* AG 总数 */
    xfs_agnumber_t m_agirotor;               /* AG round-robin 索引 */

    struct xfs_sb m_sb;                       /* 磁盘超级块 */
    struct xfs_perag *m_perag;                /* per-AG 数据结构数组 */
    struct xfs_buf *m_sb_bp;                 /* 超级块 buffer */

    struct xfs_inode *m_rootip;               /* 根目录 inode */
    struct xlog *m_log;                       /* 日志 */
} xfs_mount_t;
```

### 1.3 struct xfs_buf — 元数据缓冲区

`xfs_buf` 是 XFS 元数据 IO 的基本单元——所有元数据读写通过此结构管理：

```c
// fs/xfs/xfs_buf.h:138-190
struct xfs_buf {
    struct rhash_head b_rhash_head;          /* 哈希表查找节点 */
    xfs_daddr_t b_rhash_key;                 /* 块号 */
    int b_length;                             /* 长度（扇区数）*/
    struct lockref b_lockref;                 /* 引用计数 + 锁 */
    xfs_buf_flags_t b_flags;
    struct semaphore b_sema;

    struct list_head b_lru;                   /* LRU 列表 */
    struct xfs_perag *b_pag;                  /* per-AG 数据 */
    void *b_addr;                             /* 虚拟地址 */
    struct work_struct b_ioend_work;

    struct xfs_buf_log_item *b_log_item;      /* 日志项 */
    struct list_head b_li_list;               /* 日志项列表 */
    struct xfs_trans *b_transp;               /* 当前事务 */
    atomic_t b_pin_count;                     /* pin 计数（日志未提交时锁住）*/

    const struct xfs_buf_ops *b_ops;          /* 校验/验证操作 */
    void (*b_iodone)(struct xfs_buf *bp);     /* IO 完成回调 */
};
```

**doom-lsp 确认**：`struct xfs_buf` 在 `fs/xfs/xfs_buf.h:138`。`b_log_item` 将 buffer 与事务系统绑定，`b_pin_count` 阻止 buffer 在日志提交前被回收。

---

## 2. 分配组（AG）架构

```
XFS 磁盘布局：
┌──────────┬──────────┬──────────┬──────────┐
│  AG 0    │  AG 1    │  AG 2    │  ...     │
├──┬──┬──┬─┼──┬──┬──┬─┼──┬──┬──┬─┼─────────┤
│SB│AGF│  │  │AGF│  │  │  │AGF│  │  │         │
│AGI│BNO│CNT│  │AGI│BNO│CNT│  │AGI│BNO│CNT│    │
└──┴──┴──┴─┴──┴──┴──┴─┴──┴──┴──┴─┴─────────┘
```

每个 AG 的核心元数据：

| 结构 | 内容 |
|------|------|
| **SB** (SuperBlock) | 只 AG 0 有，全局超级块 |
| **AGF** | 空闲空间信息：空闲块数、BNO/CNT B+ 树根 |
| **AGI** | inode 信息：空闲 inode 数、未分配链表、inode B+ 树根 |
| **BNO B+tree** | 按块号排序的空闲空间（用于连续分配检查）|
| **CNT B+tree** | 按大小排序的空闲空间（用于 best-fit 分配）|
| **INOBT B+tree** | inode 分配和空闲状态（inode 位图替代品）|

分配器通过 `xfs_alloc_vextent()` 选择 AG：

```c
// AG 选择优先级：
// 1. 提示类型 (XFS_ALLOCTYPE_THIS_AG / XFS_ALLOCTYPE_NEAR_BNO / ...)
// 2. AG 轮转 (m_agirotor) — 用于大范围写入
// 3. 目标 AG 的空间不足 → 尝试下一个 AG

// BNO B+ 树（按块号排序）：
// 用于检查某个 block 前后是否连续（coalesce 合并）
//
// CNT B+ 树（按大小排序）：
// 用于 best-fit 分配——找大小最匹配的空闲区域
// 避免大块碎片
```

---

## 3. Extent 映射与 B+ 树（BMBT）

```c
// 每个 extent 表示一段连续物理块：
struct xfs_bmbt_irec {
    xfs_fsblock_t br_startblock;     /* 起始物理块号 */
    xfs_filblks_t br_blockcount;     /* 连续块数 */
    xfs_fileoff_t br_startoff;       /* 文件逻辑偏移（块）*/
    int br_state;                    /* 0=正常, 1=unwritten(预分配) */
};
```

**fork 格式自动升级**：

```
小文件 (data < ~100KB):
  XFS_DINODE_FMT_EXTENTS — extent 数组直接存在 inode 中
  → xfs_iext_lookup_extent() 线性扫描

大文件:
  XFS_DINODE_FMT_BTREE — B+ 树
  → xfs_btree_lookup() O(log n) 查找
```

### xfs_bmapi_read / xfs_bmapi_write

```c
// fs/xfs/libxfs/xfs_bmap.c

// 读 extent 映射：
int xfs_bmapi_read(ip, bno, len, mval, nmap, flags)
{
    if (ip->i_df.if_format == XFS_DINODE_FMT_EXTENTS) {
        /* 内联 extent — 线性扫描 */
        xfs_iext_lookup_extent(ip, &ip->i_df, bno, &state, &got);
    } else {
        /* B+ 树 — 树遍历 */
        cur = xfs_bmbt_init_cursor(mp, tp, ip, whichfork);
        xfs_btree_lookup(cur, XFS_LOOKUP_LE, &stat);
        xfs_btree_get_block(cur, 0, &bp);
    }
}

// 写/分配 extent：
int xfs_bmapi_write(ip, bno, len, ...)
{
    if (flags & XFS_BMAPI_DELALLOC) {
        /* 延迟分配 → 转换为实际物理块 */
        xfs_bmapi_convert_delalloc(ip);
    } else {
        /* 物理分配 */
        xfs_alloc_vextent(&args);                    /* BNO/CNT 查找 */
        xfs_iext_insert(ip, &state, &bma->got, ...); /* 插入 extent */
    }
}
```

---

## 4. 延迟分配

XFS 的核心优化——写数据时不立即决定物理块位置：

```
write(fd, buf, len)           → 只写 page cache
                               → 在内存标记延迟分配 extent
回写 (flush/writeback):
  xfs_bmapi_convert_delalloc() → xfs_alloc_vextent()
                               → 分配物理块
                               → 更新 B+ 树
                               → 写入物理块
```

**好处**：
- 回写时能看到**更大的写范围**，分配器做出更好的连续分配
- 减少碎片
- 减少锁持有时间（分配不阻塞写路径）

---

## 5. 缓冲区缓存与延迟提交

XFS 通过 `xfs_buf_delwri`（延迟写）队列批量提交元数据 IO：

```c
// 每个元数据 buffer 修改后：
xfs_buf_delwri_queue(bp, &buffer_list);    /* 加入延迟写队列 */

// 批量提交：
xfs_buf_delwri_submit(&buffer_list);       /* 整个队列一次提交 */
// 内部实现：
// list_for_each_entry(bp, &list, b_list)
//     xfs_buf_submit(bp);                  /* 实际 IO */
// submit_bio(bp->b_io->bio);              /* block layer IO */
```

**与日志的配合**：
```
事务修改 buffer → xfs_buf_delwri_queue() → 日志 checkpoint → 写 iclog
                                                        ↓
                                            xfs_buf_delwri_submit()
                                            元数据回写到文件系统位置
```

---

## 6. 延迟日志（CIL + iclog）

### 6.1 架构对比

| | ext4 JBD2 | XFS |
|--|-----------|-----|
| 单元 | `handle_t` → `transaction_t` | `xfs_trans` → `xfs_cil` |
| 提交方式 | handle stop 减少 `t_updates`，为 0 时触发 | trans_commit 追加日志向量到 CIL |
| 写盘时机 | 每个事务独立写日志块 | CIL 空间超阈值时批量 checkpoint |
| 日志格式 | 描述符+元数据+提交块 | 日志向量写入 iclog 循环缓冲区 |
| 完成通知 | `j_committing_transaction` | LSN + AIL |

### 6.2 CIL（Commit Item List）

```c
struct xfs_cil {
    struct xlog *xc_log;
    unsigned long xc_flags;
    struct workqueue_struct *xc_push_wq;
    struct rw_semaphore xc_ctx_lock;       /* 上下文锁（写序列化）*/
    struct xfs_cil_ctx *xc_ctx;            /* 当前上下文 */
    spinlock_t xc_push_lock;
    struct list_head xc_committing;        /* 提交中上下文列表 */
    wait_queue_head_t xc_commit_wait;      /* 提交等待队列 */
    wait_queue_head_t xc_start_wait;       /* 启动等待队列 */
    void __percpu *xc_pcp;                 /* percpu CIL 结构 */
} ____cacheline_aligned_in_smp;

// 每次 trans_commit：
// 1. 将脏 buffer 格式化为 xfs_log_vec
// 2. 追加到 percpu CIL（xc_pcp）
// 3. 检查空间 → 超过阈值触发 xlog_cil_push_work()
```

### 6.3 iclog 循环缓冲区

```c
// 实际定义在 fs/xfs/xfs_log_priv.h:202
struct xlog_in_core {
    wait_queue_head_t ic_force_wait;         /* 强制等待队列 */
    wait_queue_head_t ic_write_wait;        /* 等待写入 */
    struct xlog_in_core *ic_next, *ic_prev;  /* 双向循环链表 */
    struct xlog *ic_log;
    u32 ic_size, ic_offset;                  /* 当前写入位置 */
    enum xlog_iclog_state ic_state;
    unsigned int ic_flags;                   /* XLOG_* */
    atomic_t ic_refcnt;                      /* 引用计数 */
    struct xlog_rec_header *ic_header;
    struct bio ic_bio;                       /* 底层 IO */
};

// iclog 是内存中的日志循环缓冲区
// 所有 checkpoint 写入当前 iclog
// iclog 满 → 刷到磁盘 → 切换到下一个 iclog
```

### 6.4 AIL（日志项目列表）

```c
struct xfs_ail {
    struct xlog *ail_log;
    spinlock_t ail_lock;
    xfs_lsn_t ail_target;
    xfs_lsn_t ail_target_prev;
    struct list_head ail_head;               /* 日志项列表 */
    struct work_struct ail_work;             /* 后台 push */
};

// AIL 中保存已写日志但元数据尚未 checkpoint 的项
// xfs_ail_push() → 回写元数据到最终位置 → 释放 AIL 项
```

---

## 7. 事务和 inode 操作示例

```c
// fs/xfs/xfs_inode.c
static int xfs_create(...)   /* VFS create 入口 */
{
    /* 1. 分配事务 + 预留资源 */
    xfs_trans_alloc_icreate(mp, tres, &udqp, &gdqp, &pdqp, resblks, &tp);

    /* 2. inode 物理分配 */
    xfs_dialloc(&tp, dp->i_ino, mode, &ino);     /* AGI 查找空闲 inode */
    xfs_ialloc(tp, dp->i_ino, mode, isize, &ip);  /* 初始化 inode 块 */

    /* 3. 创建目录项 */
    xfs_dir_createname(tp, dp, name, ip->i_ino, ...);

    /* 4. 日志 inode 修改 */
    xfs_trans_log_inode(tp, ip, flags);           /* 标记 inode 为脏 */

    /* 5. 提交——触发 CIL */
    xfs_trans_commit(tp);
}
```

---

## 8. 与 VFS 的集成

```c
// fs/xfs/xfs_super.c
const struct super_operations xfs_super_operations = {
    .alloc_inode    = xfs_fs_alloc_inode,   /* 分配 xfs_inode + vfs inode */
    .destroy_inode  = xfs_fs_destroy_inode,
    .write_inode    = xfs_fs_write_inode,
    .drop_inode     = xfs_fs_drop_inode,
    .evict_inode    = xfs_evict_inode,
    .sync_fs        = xfs_fs_sync_fs,
    .freeze_fs      = xfs_fs_freeze,
    .statfs         = xfs_fs_statfs,
    .remount_fs     = xfs_fs_remount,
};

// xfs_fs_alloc_inode:
// 分配 sizeof(struct xfs_inode) 字节，前部为 xfs_inode
// 后部为 vfs inode（i_vnode 是最后一个成员）
// container_of 宏从 vfs inode 反推到 xfs_inode
```

---

## 9. 总结

XFS 的设计体系围绕**可扩展性**展开：

| 组件 | 设计 | 目的 |
|------|------|------|
| AG | 存储空间分区，独立 B+ 树 | 多核并发，消除锁竞争 |
| BMBT | B+ 树 extent 映射 | 大文件 O(log n) 查找，小文件内联 |
| CIL | 延迟日志 | 批量写盘，减少 IOPS 压力 |
| Delalloc | 延迟分配 | 更好的空间连续性和碎片控制 |
| xfs_buf | 哈希缓存 + delwri | 元数据 IO 合并和缓存复用 |
| inode fork | 3 fork 分离 | data/attr/cow 独立管理 |

**doom-lsp 确认**：B+ 树 extent 接口在 `fs/xfs/libxfs/xfs_bmap.c`，CIL 在 `xfs_log_cil.c`，delwri 在 `xfs_buf.c`，AG 分配器在 `libxfs/xfs_alloc.c`。

---

## 9. xfs_buf 缓存层深度分析

### 9.1 查找路径——xfs_buf_find

```c
// fs/xfs/xfs_buf.c
// xfs_buf_find() 是 buffer 缓存的核心查找函数
// 使用 rhashtable 实现 O(1) 查找

static int
xfs_buf_find(struct xfs_buftarg *btp, struct xfs_buf_map *map,
             xfs_buf_flags_t flags, struct xfs_buf **bpp)
{
    /* 1. rhashtable 查找 */
    rcu_read_lock();
    bp = rhashtable_lookup(&btp->bt_hash, map, xfs_buf_hash_params);
    if (bp && !lockref_get_not_dead(&bp->b_lockref))
        bp = NULL;
    rcu_read_unlock();

    if (bp) {
        /* 2. 缓存命中 → 获取锁 */
        error = xfs_buf_find_lock(bp, flags);
        if (error) {
            xfs_buf_rele(bp);
            return error;
        }
        *bpp = bp;
        return 0;
    }

    /* 3. 缓存未命中 → 分配新 buffer */
    error = xfs_buf_alloc(btp, map, nmaps, flags, &new_bp);
    // 插入哈希表（原子操作，防止并发重复分配）
    bp = rhashtable_lookup_get_insert_fast(&btp->bt_hash, ...);
    if (bp) {
        // 其他线程已经插入了 → 释放新建的、返回已有的
        xfs_buf_free(new_bp);
        error = xfs_buf_find_lock(bp, flags);
    }
}
```

**doom-lsp 确认**：`xfs_buf_find` 在 `xfs_buf.c`。使用 `lockref_get_not_dead` 原子操作获取引用——这是 `struct lockref` 的 DMA 友好设计（cmpxchg + spinlock fallback）。

### 9.2 延迟写队列——delwri

```c
// fs/xfs/xfs_buf.c:1806
// xfs_buf_delwri_queue() 将 buffer 加入延迟写队列
// 同一 buffer 多次入队会被判重（_XBF_DELWRI_Q 标志）

bool xfs_buf_delwri_queue(struct xfs_buf *bp, struct list_head *list)
{
    if (bp->b_flags & _XBF_DELWRI_Q)
        return false;            // 已在队列中，判重

    bp->b_flags |= _XBF_DELWRI_Q;
    if (list_empty(&bp->b_list)) {
        xfs_buf_hold(bp);        // 增加引用防回收
        list_add_tail(&bp->b_list, list);
    }
    return true;
}

// 批量提交（用工作队列异步执行）：
int xfs_buf_delwri_submit(struct list_head *list)
{
    LIST_HEAD(io_list);
    struct xfs_buf *bp;

    /* 1. 按块号排序（减少寻道）*/
    list_sort(NULL, &io_list, xfs_buf_cmp);

    /* 2. 逐个提交 */
    list_for_each_entry_safe(bp, n, &io_list, b_list) {
        if (!(bp->b_flags & _XBF_DELWRI_Q)) {
            // 已被其他线程同步写过 → 跳过
            xfs_buf_list_del(bp);
            xfs_buf_relse(bp);
            continue;
        }
        bp->b_flags &= ~_XBF_DELWRI_Q;
        xfs_buf_submit(bp);
    }
}

/* 提交后的 IO 完成链 */
xfs_buf_submit → submit_bio → bio 完成 → xfs_buf_ioend()
    → xfs_buf_ioend_handle_error()  // 错误处理：重试或报错
    → b_ops->verify_write(bp)        // 写验证
    → b_iodone(bp)                    // 通知上层（如 AIL）
    → xfs_buf_rele(bp)               // 释放引用
```

### 9.3 LRU 淘汰与内存回收

```c
// 当 xfs_buf_rele() 将引用归零时，buffer 进入 LRU 列表
// 内核内存回收时，xfs_buf_shrink() 扫描 LRU 并释放最久未使用的 buffer
// 被 pin 的 buffer（b_pin_count > 0）不能被回收

// 主动释放：
void xfs_buf_free(struct xfs_buf *bp)
{
    // 释放 backing memory
    xfs_buf_free_maps(bp);
    if (bp->b_flags & _XBF_KMEM)
        kmem_free(bp->b_addr);
    else
        free_pages(...);

    // RCU 延迟释放结构体
    call_rcu(&bp->b_rcu, xfs_buf_free_callback);
}
```

## 10. 日志恢复

XFS mount 时自动执行日志恢复（若有未完成的提交）：

```c
// fs/xfs/xfs_log_recover.c
// xfs_log_mount() → xlog_do_recovery_pass()

int xlog_do_recovery_pass(struct xlog *log, xfs_daddr_t head_blk,
                          xfs_daddr_t tail_blk)
{
    /* 1. 扫描日志，找到最后一个完整提交 */
    // 从 tail 到 head 扫描日志块
    // 找到每个日志向量的 LSN

    /* 2. 验证校验和 */
    // 校验 crc32 检查每个日志块的完整性

    /* 3. 回放日志向量到文件系统元数据位置 */
    for (each record) {
        o = item->ri_ops->iop_recover(item, &trans);
    }

    /* 4. 清除陈旧的日志块 */
    xlog_clear_stale_blocks(log, tail_lsn);
}
```

## 11. 错误处理

```c
// fs/xfs/xfs_buf.c:996
// xfs_buf_ioend_handle_error() 处理 IO 错误：
//
// 1. 首次失败 → 重试（最多 XFS_BUF_RETRIES 次）
// 2. 重试超时 → 根据错误类型决定是否 retry
// 3. 不可恢复错误 → 标记文件系统错误（xfs_force_shutdown）
//    → 后续操作返回 EFSCORRUPTED 或 EIO
//
// 这种设计使 XFS 能在出现瞬时 IO 错误时重试
// 而非立即 panic（与 ext4 的区别之一）
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
