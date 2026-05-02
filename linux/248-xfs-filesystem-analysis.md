# XFS 文件系统深度分析

> 基于 Linux 7.0-rc1 内核源码分析
> 源码路径：`/home/dev/code/linux/fs/xfs/`

---

## 1. inode 和 extent 布局

### 1.1 磁盘上的 inode：struct xfs_dinode

XFS 的 inode 存在于磁盘上，结构体为 `xfs_dinode`（定义于 `libxfs/xfs_format.h:901`）：

```c
struct xfs_dinode {
    __be16      di_magic;        /* XFS_DINODE_MAGIC = 0x494e */
    __be16      di_mode;         /* 文件类型 + 权限位 */
    __u8        di_version;      /* V1/V2/V3 */
    __u8        di_format;      /* 数据存放方式，enum xfs_dinode_fmt */
    __be32      di_uid, di_gid;
    __be32      di_nlink;
    xfs_timestamp_t di_atime/di_mtime/di_ctime;
    __be64      di_size;         /* 文件字节数 */
    __be64      di_nblocks;      /* 实际占用块数（含 btree block） */
    __be32      di_extsize;      /* extent 最小尺寸提示 */
    union { __be32 di_nextents; __be64 di_big_nextents; };
    __u8        di_forkoff;      /* attr fork 在 inode 内偏移，<<3 */
    __s8        di_aformat;      /* attr fork 格式 */
    /* ... */
    __be32      di_next_unlinked; /* AGI unlinked 链表指针 */
    /* V3 新增字段 */
    __le32      di_crc;          /* inode CRC */
    __be64      di_changecount;
    __be64      di_lsn;          /* flush sequence */
    __be64      di_flags2;
    xfs_timestamp_t di_crtime;
    __be64      di_ino;
    uuid_t      di_uuid;
};
```

**关键点**：di_format 指定数据 fork 的存放方式，di_aformat 指定 attr fork 的格式。两者互相独立。

### 1.2 dinode 与 ifork 的关系

`xfs_ifork` 是内核内存中的结构（`libxfs/xfs_inode_fork.h:15`），对应磁盘上 data fork 和 attr fork 的描述信息：

```c
struct xfs_ifork {
    int                 if_format;    /* XFS_DINODE_FMT_* */
    xfs_extnum_t        if_bytes;     /* fork 数据总字节数 */
    xfs_extnum_t        if_nextents;  /* extent 数量 */
    union {
        char            *if_data;     /* XFS_DINODE_FMT_LOCAL：inline 数据 */
        struct xfs_bmbt_rec *if_bmx;  /* XFS_DINODE_FMT_EXTENTS：extent 数组 */
        struct xfs_bmdr_block *if_broot; /* XFS_DINODE_FMT_BTREE：bmdr block */
    };
};
```

`di_format`（disk format）和 `if_format`（内存 format）的关系：

| di_format | 含义 | if_data/if_bmx/if_broot |
|---|---|---|
| `XFS_DINODE_FMT_LOCAL` | 数据直接内嵌在 inode 尾部（`di_forkoff` 之后的 LITINO 空间） | `if_data` 指向内嵌数据 |
| `XFS_DINODE_FMT_EXTENTS` | 数据 fork 是 `xfs_bmbt_rec[]` 数组 | `if_bmx` 指向 extent 数组 |
| `XFS_DINODE_FMT_BTREE` | 数据 fork 是 B+tree（`struct xfs_bmdr_block`） | `if_broot` 指向 btree 根 |
| `XFS_DINODE_FMT_DEV` | 设备文件 | `di_rdev` 存储设备号 |
| `XFS_DINODE_FMT_META_BTREE` | 元数据专用 Btree | — |

`di_forkoff << 3` 给出 attr fork 在 inode 内的字节偏移。如果 `di_forkoff = 0`，说明没有 attr fork。

### 1.3 inode chunk 分配

XFS inode 并不逐个分配，而是以 **inode chunk** 为单位批量分配（`libxfs/xfs_ialloc.c`）。

- 每个 allocation group（AG）维护一个 **inode B+tree**（inobt），管理该 AG 内所有已分配和空闲的 inode。
- inode chunk 大小由 `inode_size` 和 `inode_per_cluster` 决定，通常是 **64 字节/inode**，若干个 inode 打包在同一块（或相邻块）中。
- inode 的磁盘地址由 `AGI`（Allocation Group Header）的 `agi_root` 指向的 inobt B+tree 管理。

```c
// xfs_dialloc() — 在某个 AG 内分配一个 inode
xfs_dialloc_ag_inobt()   // 在 inobt 中查找空闲 slot
xfs_dialloc_ag_finobt()  // 用 free inode B+tree 加速查找（如果文件系统支持）
```

分配时更新 `AGI` 的 `freecount` 和 inobt。`xfs_dinode` 的 `di_next_unlinked` 字段用于实现 **unlinked inode list**（用于删除时保留 inode 直到所有引用关闭）。

---

## 2. 实时区域（Realtime Subvolume）

### 2.1 架构概览

XFS 可以配置一个独立的 realtime 子卷（通常在 SSD 或专用盘上），由以下三个特殊 inode 描述：

```c
sb_rbmino   // realtime bitmap inode — 记录 rt extents 的占用位图
sb_rsumino  // realtime summary inode — 记录 rtbitmap 每块的已用块数（用于分配优化）
sb_rextsize // realtime extent 的大小（默认 1 block，或按 rtdev 指定）
```

### 2.2 rbmino 和实时 extent 映射

`xfs_rtalloc.c` 是 realtime 分配的核心模块。

**rtbitmap inode** 是一个特殊的 inode，其数据 fork 以 **extent 格式**存储位图。每位对应一个 realtime extent（rtextent），1 = 已分配，0 = 空闲。

关键函数 `xfs_rtallocate_extent()` 的流程：

```c
// xfs_rtalloc.c
xfs_rtallocate_range()    // 在 rtbitmap 中找连续空闲 rtextent
  → xfs_rtfind_back()    // 向前找连续空闲
  → xfs_rtfind_forw()    // 向后找连续空闲
  → xfs_rtmodify_range() // 修改 rtbitmap（原子写 log）
  → xfs_rtmodify_summary() // 更新 rt summary inode
```

**rt summary inode** 是 `XFS_DINODE_FMT_BTREE` 格式的元数据 inode，用于维护 rtbitmap 的稀疏位图摘要。它的存在使得 realtime 分配可以快速找到合适的空闲区域，而不必扫描整个 rtbitmap。

### 2.3 rtgroup（Linux 7.0-rc1 新增）

Linux 7.0-rc1 引入 **rtgroup**（`xfs_rtgroup.h`），将 realtime volume 划分为多个 rtgroup，每个 rtgroup 有自己的 `rtbitmap` 和 `rtrmap`（realtime reference map）B+tree，支持更大规模的 realtime volume。

---

## 3. 日志机制

### 3.1 XFS log vs ext4 jbd2：本质区别

| | XFS log | ext4 jbd2 |
|---|---|---|
| 粒度 | **record-based**（逻辑日志） | **block-based**（物理日志） |
| 组织方式 | CIL（Checkpoint Interval Log），逻辑操作打包 | transaction，物理块列表 |
| 恢复速度 | 快（只重放逻辑操作） | 慢（需重放所有块修改） |
| 日志内容 | inode extent 变化、buffer 引用计数变化 | 块内容的完整 before/after image |
| 元数据开销 | 低（只记 intent） | 高（需要 copy 整个块） |
| 空间回收 | CIL 批量提交，自动清理 | 需要显式 checkpoint |

### 3.2 XFS log 是 record-based

XFS 日志记录的不是磁盘块的原始内容，而是 **log record**——描述元数据变更的 intent。

log record 的基本结构（`xfs_log_format.h`）：

```c
struct xlog_op_header {
    __u8   oh_flags;    // FLAG_META / FLAG_NER / ...
    __u8   oh_len;      // 数据区长度
    __be32 oh_tail;     // 本条 record 的 tail lsn
    __be32 oh_lsn;      // 本 record 的 lsn
    __be16 oh_crc;      // record CRC
    __be16 oh_clientid; // XFS_TRANSACTION / XFS_LOGSPACE / ...
};
```

### 3.3 xlog_write_iclog 状态机

iclog（in-core log buffer）的状态机定义于 `xfs_log_priv.h:54`：

```
XLOG_STATE_ACTIVE      ← 当前正在写入的 iclog
XLOG_STATE_WANT_SYNC   ← 写入完成，等待 sync
XLOG_STATE_SYNCING     ← 正在同步到磁盘
XLOG_STATE_DONE_SYNC   ← sync 完成，等待 callback
XLOG_STATE_CALLBACK    ← 正在执行回调（解锁 log item）
XLOG_STATE_DIRTY       ← 脏数据，可被重新使用
```

`xlog_state_release_iclog()` 推动状态转移：

```c
// xfs_log.c
xlog_state_release_iclog()
    if (ic_state == XLOG_STATE_WANT_SYNC)
        xlog_state_shutdown_callbacks()
    ic_state = XLOG_STATE_SYNCING   // → 唤醒 sync 线程
    ...
```

`xlog_write_iclog()`（`xfs_log.c:1542`）负责将 iclog 内容写入磁盘块设备。

### 3.4 CIL（Checkpoint Interval Log）

CIL 是 XFS 日志的核心机制（`xfs_log_cil.c`）：

1. **事务提交**：`xfs_trans_commit()` 将修改的 log item 插入 CIL（`xlog_cil_insert_items()`）
2. **空间预留**：每个 item 的空间使用在 `xc_ctx->ticket` 上预留
3. **CIL 推进**：当 CIL 空间达到阈值（`XLOG_CIL_BLOCKING_SPACE_LIMIT`）或进程主动 `xfs_log_force()` 时，触发 CIL push
4. **Push 流程**：
   - 分配新的 CIL context（`xlog_cil_ctx_switch()`）
   - 将旧 context 的 log record 格式化为 iclog
   - 写 iclog 到磁盘（`xlog_write_iclog`）
   - 更新 log tail（`xlog_assign_tail_lsn`）

CIL 的优势：**批量提交**——大量小事务被合并成一个大日志 record，一次 I/O 刷盘，显著减少磁盘 I/O 次数。

---

## 4. 延迟分配（Delayed Allocation）

### 4.1 机制

当进程写入文件时，XFS **不立即分配磁盘块**，而是在 extent map 中记录为 `DELAYSTARTBLOCK`（`-1LL`），定义为 `xfs_bmap.h:128`：

```c
#define DELAYSTARTBLOCK ((xfs_fsblock_t)-1LL)
```

此时 extent 的 `wasdel = true`，表示这是一个"待分配"的延迟 extent。

内存中的 `i_delayed_blks`（`struct xfs_inode`）累计延迟分配的块数。

### 4.2 延迟 extent 的生命周期

```
write(2)
  → xfs_file_write_iter()
    → xfs_iomap_write_direct()       // 分配路径
      → 如果需要分配:
        if (!need_alloc) {
            // 有连续空闲 → 直接分配 extent
        } else {
            // 触发延迟分配
            imap->br_startblock = DELAYSTARTBLOCK;
            // 不刷盘，不写日志
        }
  → 页面 dirty → writeback
    → xfs_bmapi_write()
      → xfs_bmap_del_extent_delay()  // 真正分配
        → xfs_alloc_fix_minleft()    // 查空闲空间
        → 分配真实 extent
        → 写日志（CIL）
```

### 4.3 为什么能提升性能？

1. **合并写入**：多个相邻的延迟分配请求，在最终刷盘时可能合并为少量大 extent，减少碎片
2. **减少 journal I/O**：延迟分配的 extent 变化不需要立即记录日志，只有在真实分配时才写 log
3. **I/O 合并**：页面 writeback 时，文件系统可以看到更大范围的 dirty 区域，做最佳合并顺序写

### 4.4 delayed allocation 与 unwritten extent

延迟分配的 extent 在真正分配时，可能处于两种状态：

- **真实分配，未初始化**：`br_state = XFS_EXT_UNWRITTEN`，表示分配了块但内容未定义（类似 ext4 的 unwritten extent）
- **真实分配，已初始化**：直接标记为 `XFS_EXT_NORM`

转换通过 `xfs_bmap_extent_to_bonus()` 或 `xfs_iomap_write_direct()` 中的逻辑处理。

---

## 5. 目录组织

### 5.1 三种格式及其转换条件

XFS 目录有四种格式，定义在 `libxfs/xfs_dir2_priv.h`：

| 格式 | 触发条件 | 存储位置 |
|---|---|---|
| **shortform** | 条目数少（< `XFS_DIR2_SPACE_SIZE`） | inode data fork 内嵌 |
| **block** | shortform 容纳不下，但不需 hash tree | 单个 directory data block |
| **leaf** | block 容纳不下 | 多个 leaf block + hash table |
| **node** | leaf 也容纳不下 | leaf + 中间 node B+tree（hash tree）|

### 5.2 shortform → block → leaf → node 的转换

目录操作入口在 `libxfs/xfs_dir2.c:xfs_dir_lookup()`：

```c
switch (dp->i_d.di_format) {
case XFS_DINODE_FMT_LOCAL:    → xfs_dir2_sf_lookup()
case XFS_DINODE_FMT_EXTENTS:  → 判断 data fork 第一个 extent 是否为 block
    → block 在 data fork 中作为 extent 存储
    → 如果是 directory block magic: xfs_dir2_block_lookup()
    → 否则可能是 leaf: xfs_dir2_leaf_lookup()
}
```

**shortform → block**：`xfs_dir2_block_to_sf()`（`libxfs/xfs_dir2_sf.c`）

**block → leaf**：`xfs_dir2_block_addname()` 检测到 block 空间不足，调用 `xfs_dir2_leaf_addname()`，同时创建 `xfs_dir2_leaf` 结构

**leaf → node**：`xfs_dir2_leaf_to_node()` 当 leaf 的 hash table 溢出时，转换为 `xfs_da_node_hdr`（B+tree node），通过 `xfs_da_btree.c` 的通用 B+tree 接口管理

### 5.3 HTree（B+tree Hash Tree）

XFS 目录的 hash tree 使用 `xfs_da_btree.c` 的通用目录/属性 B+tree 实现：

```c
struct xfs_da_node_hdr {
    __be16  magic;      // XFS_DA_NODE_MAGIC
    __be16  count;      // 有效 entry 数
    __be16  level;     // B+tree 层高
    struct xfs_da_node_entry {
        __be32  hashval;  // hash 上界
        __be64  before;   // 子 block 的磁盘地址
    } entries[];
};
```

leaf node 中每个 entry 是 `(hash, inode#)` 对，按 hash 排序。查找时先在 B+tree 中定位 hash 范围，再在对应 leaf block 中线性搜索。

### 5.4 目录名的存储格式

XFS v3 inode 支持 `filetype`（`XFS_DIFLAG2_SIGNANT`），目录 entry 结构（`xfs_dir2_sf_entry`）包含 `name` + `inumber` + `ftype`，无需从 inode 获取文件类型，节省查找 I/O。

---

## 6. 配额（Quota）

### 6.1 XFS 配额的本质：独立 dquot 结构

XFS 配额**不依赖 inode 字段**（与 ext4 不同），使用独立的 `struct xfs_dquot`（`xfs_dquot.c`）：

```c
struct xfs_dquot {
    struct xfs_qoff_entry *q_flags;  // quotachecked 标记
    xfs_dqtype_t    q_type;           // USER / GROUP / PROJECT
    xfs_ino_t       q_id;             // uid/gid/projid
    struct xfs_dquot_res q_blk;      // 块资源
    struct xfs_dquot_res q_ino;      // inode 资源
    struct xfs_dquot_res q_rtb;       // realtime 块资源
    struct list_head q_li_list;       // log item 链表
};
```

配额 inode 由 superblock 字段指定：
- `sb_uquotino`：user quota inode
- `sb_gquotino`：group quota inode
- `sb_pquotino`：project quota inode

dquot 存储在 **reserved data region**（非 AG0 空间），通过 `xfs_dquot_buf.c` 的专用 buffer ops 读写，保证 quota 信息永不和普通文件数据混用。

### 6.2 quotacheck

`xfs_qm_quotacheck()`（`xfs_qm.c:1457`）在配额启用时扫描所有 inode，建立准确的配额使用统计：

```c
xfs_qm_quotacheck()
    → xfs_qm_dquot_walk(mp, XFS_DQTYPE_USER, ...)
    → xfs_qm_quotacheck_dqadjust(ip, type, nblks, ninos, ...)
        → 遍历 data fork 的所有 extent，累加块数
        → 比较 hardlimit/softlimit，更新计时器
    → 将修正后的 dquot 写回磁盘
```

### 6.3 与 ext4 配额的根本区别

| | XFS quota | ext4 quota |
|---|---|---|
| 存储位置 | 独立 dquot inode（可跨 AG） | inode 内 `i_itime/i_dquot[]` 或 journaled dquot |
| 精度 | 每个 dquot 独立计数器，原子更新 | 依赖 journal transaction |
| recovery | dquot buffer 有 log item，crash 后精确恢复 | 需要 quotacheck 或 journal replay |
| realtime quota | 支持（`q_rtb`） | 不支持 |
| project quota | 原生支持（`sb_pquotino`） | 需要 project quota patch |

### 6.4 dquot 的 journal 日志

`xfs_dquot_item.c` 为 dquot 提供 log item：

```c
struct xfs_dqtrx {   // dquot 在一个 transaction 中的增量
    int64_t     qt_d_blk_id;    // 块 ID 在 dquot log item 中的位置
    int64_t     qt_d_blk_res;   // 本事务预留块数
};
```

dquot 的 `di_lsn` 跟踪其 dirty 状态，确保 recovery 时按正确顺序重放。

---

## 7. 崩溃恢复（Crash Recovery）

### 7.1 recovery 入口

`xfs_log_recover()`（`xfs_log_recover.c`）是 recovery 入口，分 **两个 pass**：

```c
xlog_do_recovery_pass()   // Pass 1: 扫描 log，识别 record 边界
xlog_do_recovery_pass()   // Pass 2: 重放 log intent item
```

### 7.2 Pass 1：扫描和 intent item 收集

Pass 1 遍历整个日志（从 tail 到 head），识别每条 log record：

```c
xlog_do_recovery_pass(log, head_blk, tail_blk, ...)
    → xlog_do_io()  // 读取物理 log 块
    → xlog_recover_parse_buf() // 验证 record CRC
    → 如果是 intent item（CREATE/ATTRIBMAP/BMAP/...）
        → xlog_recover_intent_item()  // 收集到 trans->r_itemhead
    → 如果是 commit record
        → xlog_recover_reorder_trans() // 调整 item 顺序
```

intent item 记录了"将要做什么"的元数据操作（如分配 extent、创建 inode），而不是具体的块内容。XFS 使用 **deferred operation**（`xfs_defer.c`）机制，将复杂操作拆解为 intent + done pair。

### 7.3 Pass 2：重做（Redo）

Pass 2 按顺序重放 intent item：

```c
xlog_recover_items_pass2()
    → xlog_recover_commit_trans()
        → xlog_recover_intent_item()
            → xfs_defer_start_recovery()
                // 调用具体 handler：
                // xfs_agi_recover()       — 恢复 unlinked inode list
                // xfs_bmap_recover()      — 恢复 extent 分配
                // xfs_icreate_recover()   — 恢复 inode 分配
                // xfs_attr_recover()      — 恢复 extended attribute
```

### 7.4 两阶段 recovery 的优势

1. **Intent item 不需要完整块 image**：只记录"要在哪里分配 extent"，recovery 时重新执行分配逻辑，log size 更小
2. **自然处理重排序**：如果同一个 extent 的分配和释放都记录在 log 中，reorder 阶段可以将它们排成正确顺序
3. **并行 recovery**：intent item 之间无依赖时可以并行执行 done item

### 7.5 unmount record 和 clean unmount 检测

`xlog_check_unmount_rec()`（`xfs_log_recover.c:1133`）在 recovery 开始前检查日志头部是否有 unmount record：

- **有 unmount record**：上次 unmount 是 clean 的，跳过 recovery（除非 mount 指定 `norecovery`）
- **无 unmount record**：上次 unmount dirty，必须 full recovery

这避免了 ext4 中需要 `e2fsck` 判断是否需要 full replay 的开销。

---

## 8. 总结：XFS 与 ext4 的核心架构差异

| 维度 | XFS | ext4 |
|---|---|---|
| 日志方式 | record-based logical（CIL） | block-based physical（jbd2） |
| inode 组织 | 每 AG 独立 inobt B+tree，inode 可跨 AG | 全局 inode table，inode 位置固定 |
| extent 描述 | B+tree BMDR（large file）或 extent array | extent header + extent entry[] |
| 延迟分配 | 真实存在，`DELAYSTARTBLOCK` + `i_delayed_blks` | 支持（extent hole punching + `delalloc`） |
| 目录 hash | B+tree hash tree（`xfs_da_btree`） | HTree（固定 2 层 ext4_dir_entry 结构） |
| 配额 | 独立 dquot 结构，精确计数器 | inode 内嵌或 journaled |
| realtime | 原生支持 rt subvolume + rtbitmap | 不支持 |
| 崩溃恢复 | 两阶段 intent item replay，速度快 | 块级重放，速度较慢 |

XFS 的设计哲学是**面向大规模、高性能场景**——通过 B+tree 管理所有元数据（inode/extent/directory/realtime bitmap），通过 CIL 批量提交减少 I/O，通过独立 dquot 实现精确配额计数。理解这些核心数据结构之间的关系，是掌握 XFS 内部原理的关键。
