# 123-xfs-filesystem — Linux XFS 文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行符号解析与代码追踪
> 分析文件：`fs/xfs/xfs_inode.c`（3072行）、`fs/xfs/xfs_log.c`（3477行）、`fs/xfs/xfs_super.c`（2721行）
> 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

XFS 是 SGI 于 1993 年为 IRIX 操作系统开发的高性能日志文件系统，2001 年进入 Linux 主线，以其**大文件支持**（最大 8EB）、**高并发目录**（HTree B+tree）、**延迟分配**、**配额精细控制**和**崩溃快速恢复**著称。与 ext4 相比，XFS 的日志机制基于**逻辑日志**（记录元数据操作而非物理块变化），采用 **CIL（Checkpoint Interval Log）** 批量提交策略，在高 IO 负载下表现尤为突出。

---

## 1. inode 磁盘布局——dinode 与 ifork

### 1.1 dinode 核心结构

XFS 的磁盘 inode 称为 **dinode**，固定为 256 字节（V3 inode）或 176 字节（V2 inode）。`struct xfs_dinode` 定义于 `libxfs/xfs_format.h:901`：

```c
struct xfs_dinode {
    __be16      di_magic;         /* XFS_DINODE_MAGIC = 0x494e */
    __be16      di_mode;          /* 文件类型 + 权限位 */
    __u8        di_version;       /* 版本号：1/2 (V2) 或 3 (V3) */
    __u8        di_format;        /* 数据fork格式（见下文） */
    __be16      di_metatype;      /* 元数据类型（V3 metafile inode） */
    __be32      di_uid;           /* 所有者用户 ID */
    __be32      di_gid;           /* 所有者组 ID */
    __be32      di_nlink;         /* 硬链接数 */
    __be16      di_projid_lo;     /* 项目 ID 低 16 位 */
    __be16      di_projid_hi;     /* 项目 ID 高 16 位 */
    union {
        __be64  di_big_nextents;  /* V3+NREXT64: 数据fork extent 数 */
        struct { __u8 di_v2_pad[6]; __be16 di_flushiter; }; /* V2 */
    };
    xfs_timestamp_t di_atime;     /* 访问时间 */
    xfs_timestamp_t di_mtime;     /* 修改时间 */
    xfs_timestamp_t di_ctime;     /* 状态改变时间 */
    __be64      di_size;          /* 文件字节大小 */
    __be64      di_nblocks;       /* 占用块数（含间接块） */
    __be32      di_extsize;       /* 基本 extent 大小（按块计） */
    union {
        struct { __be32 di_nextents;   /* V2/V3无NREXT64: extent数 */
                 __be16 di_anextents;  /* 属性fork extent数 */ };
        struct { __be32 di_big_anextents; /* NREXT64: 属性extent数 */
                 __be16 di_nrext64_pad; };
    };
    __u8        di_forkoff;       /* 属性fork偏移 >> 3（按8字节对齐） */
    __s8        di_aformat;        /* 属性fork的数据格式 */
    __be32      di_dmevmask;      /* DMIG 事件掩码 */
    __be16      di_dmstate;       /* DMIG 状态 */
    __be16      di_flags;         /* XFS_DIFLAG_* 标志 */
    __be32      di_gen;           /* 代号（用于 inode 回收） */
    __be32      di_next_unlinked; /* AGI 未链接链表指针 */
    /* ————— V3 扩展字段（从 di_crc 开始）————— */
    __le32      di_crc;           /* dinode CRC 校验（V3） */
    __be64      di_changecount;   /* 属性变更计数 */
    __be64      di_lsn;           /* 日志序列号 */
    __be64      di_flags2;        /* 扩展标志 */
    union { __be32 di_cowextsize; __be32 di_used_blocks; };
    __u8        di_pad2[12];
    /* 紧接其后：数据fork + 属性fork，内容取决于 di_forkoff */
};
```

关键字段：
- **`di_forkoff`**：将 inode 256 字节空间在数据fork和属性fork之间划分。`di_forkoff << 3` 为数据fork的字节边界。无属性fork时为 0，数据fork直接占用整个 `XFS_LITINO`（= inode_size - 176/256 字节核心区）。
- **`di_format`**（数据fork）和 **`di_aformat`**（属性fork）共用一套格式枚举：

```c
enum xfs_dinode_fmt {
    XFS_DINODE_FMT_DEV,      /* 设备文件：低32位存储 dev_t */
    XFS_DINODE_FMT_LOCAL,    /* 数据直接内嵌在 inode 中（小文件） */
    XFS_DINODE_FMT_EXTENTS,  /* extent 数组（最常见） */
    XFS_DINODE_FMT_BTREE,    /* Btree 索引（extent 数超限时） */
    XFS_DINODE_FMT_UUID,     /* 历史遗留，从未使用 */
    XFS_DINODE_FMT_META_BTREE, /* 用于特殊 inode（如 RT bitmap） */
};
```

### 1.2 ifork——内存中的 fork 结构

内存中的 `struct xfs_ifork`（`xfs_inode_fork.h`）对应磁盘上 dinode 的数据fork或属性fork：

```c
struct xfs_ifork {
    int64_t         if_bytes;     /* if_data 已分配字节数 */
    struct xfs_btree_block *if_broot; /* Btree 根块（fmt=BTREE时） */
    unsigned int    if_seq;       /* Fork 修改计数器（用于缓存一致性） */
    int             if_height;    /* Btree 高度；0=内嵌/extent/empty */
    void            *if_data;     /* 内嵌数据（fmt=LOCAL）或 extent 数组 */
    xfs_extnum_t    if_nextents;  /* 当前 extent 数量 */
    short           if_broot_bytes; /* Btree 根块字节数 */
    int8_t          if_format;    /* 磁盘格式（XFS_DINODE_FMT_*） */
    uint8_t         if_needextents; /* 是否需要从磁盘读取 extent */
};
```

`xfs_inode` 结构体本身（`xfs_inode.h:25`）包含两个 ifork：

```c
typedef struct xfs_inode {
    struct xfs_ifork    i_df;      /* 数据 fork（必定存在） */
    struct xfs_ifork    i_af;      /* 属性 fork（di_forkoff > 0 时存在） */
    struct xfs_ifork    *i_cowfp;  /* COW fork（仅 reflink 文件有） */
    /* ... */
    uint64_t        i_delayed_blks; /* 延迟分配块计数（尚未落盘的分配） */
    xfs_fsize_t     i_disk_size;    /* 磁盘上的文件大小 */
    xfs_rfsblock_t  i_nblocks;      /* 已落盘块数（含 Btree 块） */
    /* ... */
} xfs_inode_t;
```

**extent 三种格式的判断**（`xfs_ifork_has_extents()`）：
- `XFS_DINODE_FMT_EXTENTS` → `if_data` 为 `xfs_bmbt_rec_t[]` 数组
- `XFS_DINODE_FMT_BTREE` → `if_broot` 指向 Btree 根块，`if_height >= 1`
- `XFS_DINODE_FMT_LOCAL` → `if_data` 直接存储文件内容（适合小文件）

### 1.3 dinode 到 inode 的转换

`xfs_inode_from_disk()`（`xfs_inode_buf.c`）将磁盘 dinode 转换为内存 inode：

```c
inode->i_mode = be16_to_cpu(from->di_mode);
/VFS inode 填充...
/* extent 格式：从磁盘 dinode 读取 extent 数组或初始化 Btree */
if (xfs_ifork_format(&ip->i_df) == XFS_DINODE_FMT_EXTENTS)
    xfs_iext_read(ip, XFS_DATA_FORK); /* 惰性读取 extent */
```

反向转换 `xfs_inode_to_disk()` 将内存 inode 写回 dinode（仅在日志操作中进行）。

---

## 2. 日志机制——XFS log vs ext4 jbd2

### 2.1 设计哲学的根本差异

| 维度 | XFS CIL | ext4 jbd2 |
|------|---------|-----------|
| 日志类型 | **逻辑日志**（记录元数据操作语义） | **物理日志**（journal_writeback 模式）或**日志文件系统（ordered）** |
| 提交策略 | CIL 批量收集，批量提交（高吞吐） | 每笔事务独立提交（更保守） |
| 恢复速度 | 快（逻辑日志记录已计算好的变更） | 中等 |
| 元数据放大 | 低 | 中（journal_data 模式下较高） |
| 顺序写入优化 | CIL push 时合并多事务，连续写入 | 每事务独立，碎片化风险高 |

ext4 的 jbd2 基于**每事务提交**模型，每个 `journal_commit_transaction()` 都需要等待日志写入完成。XFS 的 CIL 则将一段时间内的多个事务合并为一个**检查点间隔**（Checkpoint Interval），一次性写入日志。

### 2.2 CIL——Checkpoint Interval Log

CIL 是 XFS 日志的核心结构。`xfs_log_cil.c` 中实现。每次事务发生时，元数据变更被**序列化**到一个 `struct xfs_log_item` 中，并追加到当前 CIL 上下文的链表：

```c
struct xfs_cil_ctx {
    struct list_head    iclog_entry;  /* 链接到 iclog 的链表节点 */
    struct xfs_log_vec  *lv_chain;    /* 该 checkpoint 的所有 log vector */
    xfs_lsn_t           checkpoint_lsn; /* 检查点 LSN（提交后写入头部）*/
    struct work_struct  push_work;    /* 延迟 push 工作项 */
    /* ... */
};
```

关键流程：
1. **事务修改** → 生成 `xfs_log_item`，加入当前 CIL 的 `lv_chain`
2. **CIL push 触发**（空间阈值或超时） → `xlog_cil_push_work()` 将整个 CIL 打包为一个日志记录
3. **写入 iclog** → 通过 `xlog_write()` 将 CIL 记录以**逻辑向量**（log vector）形式写入 iclog
4. **commit LSN** → CIL 提交后生成 `checkpoint_lsn`，用于崩溃恢复定位

### 2.3 iclog 状态机

XFS 日志缓冲区（`struct xlog_in_core`，`xfs_log_priv.h:55`）是一个**固定数量的环形缓冲区**，每个 iclog 对应一块内存中的日志页。iclog 的状态机由 `enum xlog_iclog_state` 定义：

```c
enum xlog_iclog_state {
    XLOG_STATE_ACTIVE,       /* 当前正在写入的 iclog */
    XLOG_STATE_WANT_SYNC,    /* 已写满，等待同步到磁盘 */
    XLOG_STATE_SYNCING,      /* 正在执行磁盘同步（写盘 + FUA） */
    XLOG_STATE_DONE_SYNC,    /* 同步完成，等待回调处理 */
    XLOG_STATE_CALLBACK,     /* 正在执行回调（如 AIL 推送） */
    XLOG_STATE_DIRTY,       /* 脏 iclog，需要重置为 ACTIVE */
};
```

**状态转换图**：

```
应用层写入 transaction
         │
         ▼
    ┌─────────────┐
    │XLOG_STATE   │◄───────────────┐
    │ ACTIVE      │                │
    └──────┬──────┘                │
           │ xlog_ticket_reservation 满   │
           │ 或 xlog_state_release_iclog()│
           ▼                          │
    ┌────────────────┐               │
    │XLOG_STATE       │ 延迟写入磁盘    │
    │WANT_SYNC        │               │
    └──────┬──────────┘               │
           │ xlog_sync()             │
           ▼                         │
    ┌────────────────┐               │
    │XLOG_STATE       │───────────────┤
    │SYNCING          │ 磁盘写入完成   │
    └──────┬──────────┘               │
           │ 中断回调                  │
           ▼                          │
    ┌────────────────┐               │
    │XLOG_STATE       │               │
    │DONE_SYNC/CALLBACK│─────────────┤
    └──────┬──────────┘               │
           │ 回调完成（AIE/bufflush）  │
           ▼                          │
    ┌────────────────┐               │
    │XLOG_STATE       │──────────────►│ (回到 ACTIVE)
    │DIRTY→ACTIVE    │               │
    └────────────────┘               │
```

核心函数 `xlog_state_release_iclog()`（`xfs_log.c:469`）处理引用计数递减和状态跃迁：

```c
last_ref = atomic_dec_and_test(&iclog->ic_refcnt);
if (!last_ref) return 0;  /* 还有引用者，等待 */

/* 满足 WANT_SYNC 或 NEED_FUA 时，捕获 tail_lsn */
if ((iclog->ic_state == XLOG_STATE_WANT_SYNC ||
     (iclog->ic_flags & XLOG_ICL_NEED_FUA)) &&
    !iclog->ic_header->h_tail_lsn)
    iclog->ic_header->h_tail_lsn = cpu_to_be64(atomic64_read(&log->l_tail_lsn));

iclog->ic_state = XLOG_STATE_SYNCING;
/* 解锁后调用 xlog_sync(log, iclog, ticket) 执行实际磁盘写入 */
```

**FLAGS**：`XLOG_ICL_NEED_FLUSH`（需要 cache flush）和 `XLOG_ICL_NEED_FUA`（Force Unit Access，保证数据进入持久化存储）通过磁盘的 FUA 命令实现原子性。

### 2.4 ticket 预留机制

每个写日志的操作需要先申请 `struct xlog_ticket`（`xfs_log_priv.h:185`）：

```c
struct xlog_ticket {
    xlog_tid_t      t_tid;          /* 事务 ID */
    atomic_t        t_ref;          /* 引用计数 */
    int             t_curr_res;     /* 当前剩余预留空间 */
    int             t_unit_res;     /* 单位预留（每次操作递减） */
    char            t_cnt;          /* 当前 unit 数 */
    char            t_ocnt;         /* 原始 unit 数 */
    uint8_t         t_flags;        /* XLOG_TIC_PERM_RESERV 等 */
};
```

`xlog_ticket_reservation()` 计算当前需要的空间，`xlog_write()` 负责将 log vector 写入 iclog。

---

## 3. 延迟分配——XFS delayed allocation

### 3.1 核心思想

ext4 和 XFS 都支持延迟分配（delayed allocation），但 XFS 的实现尤为精妙。其核心思路：

**写文件时，不立即分配物理块**。数据写入请求被推迟到**脏页回写**（writeback）时才真正分配块。从而实现以下优化：

1. **合并相邻写**：多个小写操作合并为一个 extent 分配请求
2. **减少碎片**：在 pagecache 中积累足够多的数据再分配，减少内部碎片
3. **延长信息窗口**：在分配前知道文件最终大小（`i_size`），可以预分配对齐的 extent

### 3.2 关键代码路径

当应用程序执行 `write()` 时，最终路径为 `xfs_file_iomap_begin()` → `xfs_iomap_write_direct()`（`xfs_iomap.c:268`）：

```c
error = xfs_bmapi_write(tp, ip, offset_fsb, count_fsb,
                         bmapi_flags, 0, imap, &nimaps);
```

若满足延迟分配条件（`!XFS_IS_REALTIME_INODE(ip)` 且空间紧张或小写入），`xfs_bmapi_write()` 会返回一个起始块号为 **`DELAYSTARTBLOCK`**（`libxfs/xfs_bmap.c:3696`）的 `xfs_bmbt_irec`：

```c
if (state == XFS_BMAPI_PREALLOC || prealloc)
    irec->br_startblock = DELAYSTARTBLOCK;  /* 延迟分配标记 */
else
    mval->br_startblock = DELAYSTARTBLOCK;  /* 延迟分配 */
```

此时**没有发生任何磁盘分配**，只是在内存中的 inode ifork 里记录了"这段逻辑块号将来会分配物理块"。实际的块计数反映在 `ip->i_delayed_blks` 中。

### 3.3 延迟分配转换为真实分配

延迟分配的 extent 在以下时机被"物化"：

1. **脏页回写时**（`xfs_aops.c` 的 `xfs_vm_writepage`）：
   ```c
   error = xfs_bmapi_convert_delalloc(ip, whichfork, offset,
                                      length, &imap, &ioend);
   ```
   调用 `__xfs_bmapi_write()` 中的延迟分配处理分支，实际分配物理块。

2. **MMAP 写时**：访问到尚未分配的页时触发。

3. **`fsync()` / `fdatasync()`**：强制将延迟分配转换为真实分配后再同步。

转换过程（`libxfs/xfs_bmap.c:1436`）调用 `xfs_bmap_delalloc_convert()`，将 `DELAYSTARTBLOCK` 替换为真实分配的块号，并从 `i_delayed_blks` 中减去对应数量。

### 3.4 为什么提升性能

| 场景 | 无延迟分配 | 延迟分配 |
|------|-----------|---------|
| 顺序写 4K page × 1000 次 | 1000 次小块分配 + 1000 次 journal 记录 | 合并为 1 次大 extent 分配 |
| 多进程并发写同一文件 | 各自独立分配，产生碎片 | CIL 收集后统一分配策略 |
| 写入覆盖（同一块多次写） | 第一次分配，第二次无意义重分配 | 延迟到最后一刻，只分配一次 |

延迟分配还使 XFS 在高并发小文件场景下能够更好地控制**组空闲（AGFL）** 的使用效率。

---

## 4. 目录——shortform / linear / HTree 转换

### 4.1 四种目录格式

XFS 目录根据规模使用不同的磁盘格式（`enum xfs_dir2_fmt`，`libxfs/xfs_dir2.h:40`）：

| 格式 | 触发条件 | 存储位置 |
|------|---------|---------|
| `XFS_DIR2_FMT_SF` | 目录项少（小目录） | 直接内嵌在 inode data fork（`di_format = LOCAL`） |
| `XFS_DIR2_FMT_BLOCK` | 单块目录（块级目录） | 占用文件系统一个完整块 |
| `XFS_DIR2_FMT_LEAF` | 小型 Btree 目录 | leaf-only Btree |
| `XFS_DIR2_FMT_NODE` | 大型 Btree 目录（HTree） | 多层 Btree 节点 |

### 4.2 shortform 目录结构

`struct xfs_dir2_sf_hdr`（`xfs_da_format.h:214`）内嵌于 inode data fork：

```c
typedef struct xfs_dir2_sf_hdr {
    uint8_t     count;     /* 条目数 */
    uint8_t     i8count;   /* inode 号需要 8 字节的条目数（> 32 位）*/
    uint8_t     parent[8]; /* 父目录 inode 号（如果是 32 位则后 4 字节为 0）*/
} __packed xfs_dir2_sf_hdr_t;
```

每个条目 `struct xfs_dir2_sf_entry` 结构：
```c
typedef struct xfs_dir2_sf_entry {
    __u8        namelen;       /* 名称长度 */
    __u8        offset[2];     /* 在目录块中的偏移（供块格式转换用）*/
    __u8        name[];        /* 名称（变长）*/
    /* 后面紧跟：inode 号（4 或 8 字节，取决于是否 i8）*/
} __packed xfs_dir2_sf_entry_t;
```

shortform 的空间限制是 inode 的 data fork 可用空间（`XFS_DFORK_DSIZE`），通常为 356 字节（256 字节 inode - 176 字节核心区）。

### 4.3 shortform → block 的转换条件

当向 shortform 目录添加新条目时（`libxfs/xfs_dir2_sf.c:405`），若以下任一条件满足则触发**到 BLOCK 格式的转换**：

```c
new_isize = dp->i_disk_size + incr_isize;
/* 条件1：新大小超过 data fork 可用空间 */
if (new_isize > xfs_inode_data_fork_size(dp))
    convert_to_block();

/* 条件2：现有条目在目录块中位置分散，插入效率低 */
pick = xfs_dir2_sf_addname_pick(args, objchange, &sfep, &offset);
if (pick == 0)  /* 没有合适的插入位置 */
    convert_to_block();
```

即：**空间不足** 或 **条目位置冲突导致需要分散插入** 时触发转换。

### 4.4 HTree（node 格式）

当目录从 BLOCK 格式增长到一定程度时，`xfs_dir2_block_addname()` 在块满时调用 `xfs_dir2_block_to_leaf()` → `xfs_dir2_leaf_to_node()`，构建 B+tree。

HTree 的叶节点和内部节点都使用 `struct xfs_da_node_hdr`（`xfs_da_format.h`），内部节点包含 `struct xfs_da_node_entry` 数组，每个 entry 存储子节点的哈希范围和块指针：

```c
struct xfs_da_node_entry {
    xfs_hash_name_t   hash;    /* 该子节点覆盖的哈希上界 */
    __be32            before;  /* 子节点的磁盘块号 */
};
```

XFS 目录 HTree 的**叶子节点**使用 `struct xfs_dir2_leaf_entry`，包含文件名哈希值和目录数据块中的实际条目指针。

---

## 5. 配额机制——XFS quota

### 5.1 三类配额与两组限制

XFS 支持三种配额类型（`enum xfs_dqtype`，`xfs_quota.h`）：

- **USRQUOTA**：用户配额
- **GRPQUOTA**：组配额
- **PRJQUOTA**：项目配额（基于 `di_projid`）

每种配额有两组限制：

- **硬限制（hard limit）**：绝对上限，达到后**拒绝**分配
- **软限制（soft limit）**：宽限期上限，达到后**警告**但仍允许分配，超期后降级为硬限制

### 5.2 磁盘配额结构

`struct xfs_disk_dquot`（`libxfs/xfs_format.h:1438`）是配额的磁盘格式：

```c
struct xfs_disk_dquot {
    __be16      d_magic;       /* XFS_DQUOT_MAGIC */
    __u8        d_version;     /* 版本 */
    __u8        d_type;       /* XFS_DQTYPE_USER/PROJ/GROUP */
    __be32      d_id;         /* 用户/组/项目 ID */
    __be64      d_blk_hardlimit; /* 磁盘块硬限制（字节）*/
    __be64      d_blk_softlimit;
    __be64      d_ino_hardlimit; /* inode 数硬限制 */
    __be64      d_ino_softlimit;
    __be64      d_bcount;      /* 当前磁盘块占用 */
    __be64      d_icount;      /* 当前 inode 计数 */
    __be32      d_itimer;      /* inode 软限制超期时间 */
    __be32      d_btimer;       /* 磁盘块软限制超期时间 */
    __be16      d_iwarns;      /* 警告计数 */
    __be16      d_bwarns;
    __be64      d_rtb_hardlimit; /* realtime 块限制 */
    __be64      d_rtb_softlimit;
    __be64      d_rtbcount;    /* 当前 rt 块占用 */
    __be32      d_rtbtimer;
    /* ... */
};
```

### 5.3 内存中的 dquot

`struct xfs_dquot`（`xfs_dquot.h:68`）是内存中的配额对象：

```c
struct xfs_dquot {
    struct list_head    q_lru;        /* LRU 链表（未使用的 dquot）*/
    xfs_dqtype_t         q_type;       /* 配额类型 */
    uint16_t             q_flags;
    xfs_dqid_t           q_id;         /* 对应 ID */
    struct xfs_dquot_res q_blk;       /* 块资源 */
    struct xfs_dquot_res q_ino;       /* inode 资源 */
    struct xfs_dquot_res q_rtb;       /* realtime 块资源 */
    struct xfs_dquot_pre q_blk_prealloc; /* 预分配宽限期跟踪 */
    struct mutex         q_qlock;      /* dquot 锁 */
    struct completion    q_flush;     /* 刷新完成同步 */
    atomic_t             q_pincount;  /* pin 计数（日志中）*/
    /* ... */
};
```

### 5.4 配额初始化与检查流程

挂载时 `xfs_qm_init()`（`xfs_qm.c:766`）完成：
1. **分配 quota inode**（特殊 metafile inode，类型为 `XFS_METAFILE_USRQUOTA` 等）
2. **初始化 quotainfo**：设置定时器、警告阈值
3. **读取磁盘 quota**：将磁盘上的 dquot 加载到内存 hash cache

写操作时的配额检查（`xfs_qm_dqattach()`）：
```c
error = xfs_qm_dqattach(ip);  /* 为 inode 绑定 dquot */
```

分配块时的检查（`xfs_bmap_alloc_account()`，`libxfs/xfs_bmap.c:3267`）：
```c
ap->ip->i_delayed_blks += ap->length;  /* 延迟块也计入配额 */
```

配额超额时，`xfs_qm_dqput()` 触发写回和警告。

### 5.5 日志中的配额记录

dquot 的变更通过 `struct xfs_dq_logitem`（嵌入 `xfs_dquot`）记录到日志。`xfs_dquot_item_recover.c` 在恢复时重新应用 dquot 变更。

---

## 6. 崩溃恢复——xlog_recover_commit_trans

### 6.1 恢复的整体流程

XFS 崩溃恢复分为两个 pass（`xfs_log_recover.c`）：

**Pass 1（`XLOG_RECOVER_PASS1`）**：扫描日志，验证所有 log item，执行只读操作（如检查 EFI/EFD 完整性）。

**Pass 2（`XLOG_RECOVER_PASS2`）**：重放所有已提交事务，将元数据变更应用到文件系统。

恢复入口 `xlog_recover()`（mount 时调用）：
```c
if (xlog_recovery_needed(log))
    error = xlog_recover(log);  /* → xlog_recover_finish() */
```

### 6.2 xlog_recover_commit_trans——事务提交的核心

`xlog_recover_commit_trans()`（`xfs_log_recover.c:2025`）是恢复时重放每个已提交事务的关键函数：

```c
STATIC int xlog_recover_commit_trans(
    struct xlog     *log,
    struct xlog_recover *trans,
    int              pass,
    struct list_head *buffer_list)
{
    /* 从全局恢复链表移除该事务 */
    hlist_del_init(&trans->r_list);

    /* 重新排序 log item（按依赖关系）*/
    error = xlog_recover_reorder_trans(log, trans, pass);
    if (error) return error;

    list_for_each_entry_safe(item, next, &trans->r_itemq, ri_list) {
        switch (pass) {
        case XLOG_RECOVER_PASS1:
            if (item->ri_ops->commit_pass1)
                error = item->ri_ops->commit_pass1(log, item);
            break;
        case XLOG_RECOVER_PASS2:
            /* 准备 pass2：计算需要的块和空间 */
            if (item->ri_ops->ra_pass2)
                item->ri_ops->ra_pass2(log, item);
            list_move_tail(&item->ri_list, &ra_list);
            items_queued++;
            /* 批量处理，最多 100 个 item */
            if (items_queued >= XLOG_RECOVER_COMMIT_QUEUE_MAX) {
                error = xlog_recover_items_pass2(log, trans,
                        buffer_list, &ra_list);
                items_queued = 0;
            }
            break;
        }
    }
    /* ... 剩余 item 处理 ... */
}
```

### 6.3 log item 的重放操作

每种元数据类型（inode、buf、dquot）都有对应的 `xlog_recover_item_ops`：

| 元数据类型 | `commit_pass1` | `ra_pass2` / `commit_pass2` |
|-----------|---------------|---------------------------|
| **inode item** | 无 | `xlog_recover_inode_commit_pass2()` — 恢复 inode 内容 |
| **buf item** | 无 | `xfs_buf_item_recover()` — 恢复磁盘缓冲区内容 |
| **dquot item** | 无 | `xfs_dquot_item_recover()` — 恢复配额信息 |
| **efi/efd item** | `xfs_efi_item_recover()` | 无（Pass 2 直接跳过） |

**inode 恢复**（`xfs_inode_item_recover.c:308`）：
1. 从日志记录中提取 inode 的完整内容（`di_mode`、`di_size`、各 fork 数据）
2. 在磁盘上定位该 inode（通过 `xfs_imap_to_bp()`）
3. 调用 `xfs_inode_from_disk()` 将日志中的 dinode 写入磁盘

**buf item 恢复**（`xfs_buf_item_recover.c`）：
- 直接将日志中记录的块内容覆盖磁盘上对应缓冲区
- 处理块号到物理块的映射

### 6.4 未链接链表的恢复

XFS 使用 `di_next_unlinked` 字段维护一个 AG 级别的未链接 inode 链表（每个 AG 有自己的 bucket）。恢复时 `xlog_recover_process_iunlinks()` 遍历这些链表，将因系统崩溃而处于"已删除但未完成 unlink"状态的 inode 正确清理。

### 6.5 恢复完成

`xlog_recover_finish()` 执行最后步骤：
1. **`xlog_recover_process_intents()`**：处理所有 intent item（EFI/EFD），撤销未完成的空间分配
2. **`xlog_recover_process_iunlinks()`**：清理未链接 inode
3. **`xfs_reflink_recover_cow()`**：恢复 COW 块（reflink 文件特有）

---

## 7. 核心数据结构索引

| 结构 | 定义位置 | 用途 |
|------|---------|------|
| `struct xfs_dinode` | `libxfs/xfs_format.h:901` | 磁盘 inode 格式 |
| `struct xfs_ifork` | `libxfs/xfs_inode_fork.h` | 内存中 data/attr fork |
| `struct xfs_inode` | `xfs_inode.h:25`（内核态） | 内存 inode |
| `struct xlog` | `xfs_log_priv.h` | 日志系统全局结构 |
| `struct xlog_in_core` | `xfs_log_priv.h` | iclog（环形日志缓冲区） |
| `enum xlog_iclog_state` | `xfs_log_priv.h:55` | iclog 状态机 |
| `struct xfs_cil_ctx` | `xfs_log_cil.c` | CIL checkpoint 上下文 |
| `struct xlog_ticket` | `xfs_log_priv.h:185` | 日志空间预留 ticket |
| `struct xfs_disk_dquot` | `libxfs/xfs_format.h:1438` | 磁盘配额格式 |
| `struct xfs_dquot` | `xfs_dquot.h:68` | 内存配额对象 |
| `struct xfs_dir2_sf_hdr` | `xfs_da_format.h:214` | shortform 目录头 |

---

## 8. 总结：XFS 的设计哲学

1. **日志为逻辑而非物理**：XFS 日志记录的是元数据操作的语义（如"创建一个 extent"）而非物理块变更，使日志量更小，恢复更快
2. **CIL 批量提交**：通过延迟批量提交策略，在高并发写入时显著提升吞吐量
3. **inode 大空间预分配**：inode 本身可预分配大 extent，减少动态扩展开销
4. **AG 级别的并发控制**：每个 AG 有独立的 inode 分配位图和块组，高并发下减少锁竞争
5. **配额与日志深度集成**：dquot 变更同样记录日志，保证配额信息的崩溃一致性
