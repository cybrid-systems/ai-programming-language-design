# XFS 文件系统深度分析

> 基于 Linux 7.0-rc1 内核源码（/home/dev/code/linux），分析 XFS 文件系统的核心设计与实现。

---

## 一、inode 与 extent 布局：dinode、ifork 与 B+tree

### 1.1 磁盘上的 dinode 结构

XFS 在磁盘上的 inode 称为 **dinode**，定义在 `libxfs/xfs_format.h:901`：

```c
struct xfs_dinode {
    __be16      di_magic;      // XFS_DINODE_MAGIC = 0x494e ('IN')
    __be16      di_mode;       // 文件模式 + 类型
    __u8        di_version;    // 版本号：1、2 或 3
    __u8        di_format;     // 数据分叉的格式
    __be16      di_metatype;
    __be32      di_uid, di_gid;
    __be32      di_nlink;
    __be16      di_projid_lo, di_projid_hi;
    union { ... };             // V2/V3 扩展字段
    xfs_timestamp_t di_atime, di_mtime, di_ctime;
    __be64      di_size;
    __be64      di_nblocks;    // 直接块 + btree 块数量
    __be32      di_extsize;
    union { __be32 di_nextents; __be16 di_anextents; ... };
    __u8        di_forkoff;    // attr fork 在 inode 内的偏移（<<3 对齐）
    __s8        di_aformat;    // attr fork 的格式
    __be32      di_dmevmask;
    __be16      di_dmstate;
    __be16      di_flags;
    __be32      di_gen;
    __be32      di_next_unlinked; // AGI unlinked 链表指针
    // V3 扩展字段（di_crc 开始的写保护区）
    __le32      di_crc;
    __be64      di_changecount;
    __be64      di_lsn;
    __be64      di_flags2;
    __be32      di_cowextsize;
    __u8        di_pad2[12];
    xfs_timestamp_t di_crtime;
    __be64      di_ino;
    uuid_t      di_uuid;
};
```

关键点：
- **di_version**：V1/V2 inode 大小固定，V3（需要 `xfs_has_v3inodes()`）扩展了大量字段并开启了 CRC 校验。
- **di_format**（数据分叉）和 **di_aformat**（属性分叉）有四种格式：`LOCAL`、`EXTENTS`、`BTREE`、`META_BTREE`。
- **di_forkoff**：V3 inode 中，attr fork 嵌入在 inode 末尾，di_forkoff 指定其在 inode 内的字节偏移（右移 3 位，即按 8 字节对齐）。
- **di_next_unlinked**：用于实现 unlinked inode 链表，是回收已删除但仍有硬链接 inode 的机制。

### 1.2 ifork：内存中的 extent 树

内存中的 inode fork 结构体 `struct xfs_ifork`（`libxfs/xfs_inode_fork.h:15`）：

```c
struct xfs_ifork {
    int64_t         if_bytes;          // if_data 中的字节数
    struct xfs_btree_block *if_broot; // B+tree 根节点（内嵌于 if_data）
    unsigned int    if_seq;            // fork 修改计数器
    int              if_height;        // B+tree 高度（0 = 内联数据）
    void            *if_data;          // 内联数据或 btree 根
    xfs_extnum_t     if_nextents;      // extent 数量
    short            if_broot_bytes;
    int8_t           if_format;        // LOCAL / EXTENTS / BTREE
    uint8_t          if_needextents;   // extent 尚未读取标记
};
```

**为什么 XFS 用 B+tree 而不是 extent 数组？**

当 extent 数量较少时，XFS 使用 `XFS_DINODE_FMT_EXTENTS` 格式，将 `struct xfs_bmbt_rec`（每个 extent 12 字节）直接存储在 inode 的数据区。但 extent 数量增长超过阈值时，`di_format` 切换为 `XFS_DINODE_FMT_BTREE`，在 inode 数据区存储一个 `struct xfs_btree_block`（B+tree 根节点），extent 记录转移到 B+tree 叶子节点中。

B+tree 的优势在于：
- **查找效率**：O(log n) vs O(n) 遍历数组
- **扩展性**：支持稀疏 inode chunk（通过 `ir_holemask` 标记哪些 inode 块不存在）
- **支持大规模文件系统**：XFS 支持 16EB 文件，每个文件 extent 数量可以非常庞大

### 1.3 inode chunk 分配路径

```
inode 号 (ino)
  → XFS_INO_TO_AGNO(mp, ino)     定位到 Allocation Group (AG)
  → XFS_INO_TO_AGINO(mp, ino)    AG 内 inode 号（AG 内偏移）
  → xfs_imap_to_bp()             将 (AG, inode offset) 映射到磁盘块
  → xfs_iget()                   VFS inode 缓存查找 → cache miss → xfs_iget_cache_miss()
```

inode chunk 分配通过 **inode allocation B+tree（inobt）** 管理。每个 AG 有一个 inobt，记录该 AG 内所有 inode chunk 的使用情况。

```c
// 每个 inode chunk 的位图
typedef uint64_t xfs_inofree_t;
#define XFS_INODES_PER_CHUNK  (NBBY * sizeof(xfs_inofree_t))  // 64 个 inode
```

稀疏 inode chunk（sparse inodes）通过 `ir_holemask` 支持不连续的物理块分配。

---

## 二、实时区域（Realtime Bitmap）

### 2.1 实时子卷的工作方式

XFS 支持独立的实时子卷（realtime volume），专门用于存储实时性要求高的数据。超级块中相关字段：

```c
sb->sb_rblocks    // realtime 区总块数
sb->sb_rextents   // realtime extent 总数
sb->sb_rextsize   // realtime extent 大小（以块计）
```

实时区通过 `xfs_rtalloc.c` 管理，核心结构是 **实时位图（rtbitmap）** 和 **实时摘要（rtsummary）**。

### 2.2 rbmino 与实时 extent 映射

`rbmino` 是实时位图 inode（类似于一个特殊的文件），其 extent 映射直接指向实时位图块。每个位图块中的每个 bit 对应一个 realtime extent 的使用状态（0 = 空闲，1 = 已分配）。

关键函数：
- `xfs_rtallocate_extent_near()` — 在指定位置附近寻找空闲 extent
- `xfs_rtallocate_extent_block()` — 在一个 rtbitmap 块范围内分配
- `xfs_rtfind_back() / xfs_rtfind_forw()` — 向前/向后查找空闲 extent

### 2.3 实时 extent 的分配

```
用户请求 rt-extent
  → xfs_bmap_rtalloc()       在实时区分配
  → xfs_rtallocate_range()    查 bitmap，找连续块
  → xfs_rtmodify_summary()    更新 rtsummary 块
  → br_startblock = 物理块号   （非 DELAYSTARTBLOCK）
```

---

## 三、日志机制：record-based vs block-based

### 3.1 XFS 日志与 ext4 jbd2 的本质区别

| 特性 | XFS 日志 | ext4 jbd2 |
|------|---------|-----------|
| **组织方式** | **record-based（日志记录）** | **block-based（块）** |
| **元数据组织** | 每个物理操作为一个 log item | 每个修改的块作为一个 buffer_head |
| **空间预分配** | 预先分配 log 空间（log reservation） | 动态分配 |
| **崩溃恢复粒度** | transaction 级别 | transaction 级别 |
| **日志写入** | 直接序列化 log item 到 iclog | 通过 buffer_head 间接写入 |

XFS 日志的核心是 **xlog**，由一系列 **iclog（in-core log buffer）** 组成。

### 3.2 iclog 状态机

定义在 `xfs_log_priv.h:54`：

```
XLOG_STATE_ACTIVE       ← 当前正在写入的 iclog
XLOG_STATE_WANT_SYNC    ← 已写满，等待同步
XLOG_STATE_SYNCING      ← 正在同步到磁盘
XLOG_STATE_DONE_SYNC    ← 同步完成，执行回调
XLOG_STATE_CALLBACK     ← 执行回调
XLOG_STATE_DIRTY        ← 脏 iclog，需要被重新激活
```

状态转换图：

```
用户提交 transaction
  → xlog_write() 写入 iclog
  → iclog 写满或 xlog_sync() 被调用
  → iclog->ic_state = XLOG_STATE_WANT_SYNC
  → xlog_state_release_iclog() 检测到 WANT_SYNC
  → iclog->ic_state = XLOG_STATE_SYNCING
  → xlog_sync() = xlog_write_iclog() 提交到块设备
    → REQ_PREFLUSH (如果 XLOG_ICL_NEED_FLUSH)
    → REQ_FUA     (如果 XLOG_ICL_NEED_FUA)
  → I/O 完成回调 xlog_bio_end_io()
  → iclog->ic_state = XLOG_STATE_DONE_SYNC
  → xlog_state_switch_iclogs() 切换到下一个 ACTIVE iclog
  → 回调链表执行 → ic_state = XLOG_STATE_DIRTY → XLOG_STATE_ACTIVE
```

### 3.3 xlog_write_iclog（`xfs_log.c:1542`）

这是将 iclog 写入磁盘的核心函数：

```c
xlog_write_iclog(log, iclog, bno, count)
{
    // 1. 设置同步屏障
    if (iclog->ic_flags & XLOG_ICL_NEED_FLUSH)
        bio.opf |= REQ_PREFLUSH;   // 写前刷新磁盘缓存
    if (iclog->ic_flags & XLOG_ICL_NEED_FUA)
        bio.opf |= REQ_FUA;         // 强制写入持久化媒体

    // 2. 提交 bio 异步 I/O
    bio_submit(&iclog->ic_bio);

    // 3. I/O 完成后通过 xlog_bio_end_io 回调
    //    触发 ic_state 状态推进
}
```

XFS 日志使用 **physical logging**（物理日志）——记录的是完整的磁盘块内容变化，而不是 redo/undo 操作日志。这使得崩溃恢复简单可靠。

---

## 四、延迟分配（Delayed Allocation）

### 4.1 核心机制

延迟分配是 XFS 最重要的性能优化之一。当应用程序写入文件时：

1. **数据首先写入页缓存**，文件系统**不立即分配磁盘块**
2. extent 记录中 `br_startblock == DELAYSTARTBLOCK`（值为 -1LL）标记为"延迟分配"
3. 真正的物理块分配**推迟到**：
   - 页缓存被刷回磁盘时（`xfs_bmap_flush()`）
   - 或调用 `fsync()` / `fdatasync()` 时
   - 或内存压力需要回收页帧时

### 4.2 延迟分配的性能收益

```
传统方式（直接分配）：
  write() → 磁盘 I/O 同步等待块分配 → 返回用户

延迟分配方式：
  write() → 只更新页缓存 → 立即返回
  → 多次小写入合并为一次大顺序 I/O
  → 可以更好地对齐 stripe 边界
  → 减少磁盘碎片
```

延迟分配使 XFS 能够：
- **合并小写入**：同一个文件相邻区域的多次写入，在真正落盘时合并为少数几个大 extent
- **优化磁盘布局**：知道文件最终大小时，可以分配连续的大extent，减少碎片
- **减少 I/O 次数**：通过合并减少磁盘寻道

### 4.3 代码路径

```
write()
  → xfs_file_write_iter()
  → xfs_ilock()
  → xfs_file_iomap_begin()    // 分配 imap，标记 DELAYSTARTBLOCK
  → xfs_bmapi_write()         // 只分配 extent 记录，不分配物理块
  → iomap_write()             // 写页缓存

(延迟到刷盘)
  → xfs_bmap_flush()
  → xfs_bmap_add_extent()     // 真正分配物理块
  → DELAYSTARTBLOCK → 实际块号
```

---

## 五、目录组织：shortform / data block / B+tree（HTree）

### 5.1 XFS 目录的三种格式

XFS 目录使用 `di_format` 字段（`XFS_DINODE_FMT_LOCAL / EXTENTS / BTREE`），但目录有自己的格式枚举：

| 格式 | 触发条件 | 存储位置 |
|------|---------|---------|
| **shortform（inline）** | 条目数少（< ~200），总大小 < inode 剩余空间 | 直接存储在 inode 的数据区（`di_u.di_local`） |
| **data block（block）** | 条目数增多或单个条目变大 | 独立的目录数据块（`di_u.di_extents`） |
| **B+tree（HTree）** | block 格式条目数过多 | inode 存储 B+tree 根，目录块作为叶子 |

### 5.2 shortform 目录

`struct xfs_dir2_sf_hdr` 直接嵌入在 inode 数据 fork 中：

```c
struct xfs_dir2_sf_hdr {
    __uint8_t   count;         // 条目数
    xfs_ino_t   parent;        // 父目录 inode 号
    // 后面跟着变长条目 xfs_dir2_sf_entry[]
};

struct xfs_dir2_sf_entry {
    __uint8_t   namelen;       // 文件名长度
    __be64      ino;           // inode 号（根据长度压缩）
    __uint8_t   ftype;        // 文件类型
    char        name[];        // 文件名
};
```

shortform 的好处是**零磁盘 I/O** —— 读取目录时直接读 inode，不需要额外的磁盘块访问。

### 5.3 格式转换触发条件

转换通过 `xfs_dir2_sf_to_block()` 等函数完成，触发条件（`xfs_dir2.h` 注释）：
- shortform 目录总大小超过 inode 剩余空间
- block 目录的 data free list 不足以容纳新条目
- 条目数超过 `XFS_DIR2_DATA_FREECOUNT` 阈值

data block 格式使用一个块存储所有目录条目（`struct xfs_dir2_data_hdr`），每个条目通过 `xfs_dir2_data_free` 空闲列表管理空间分配。

当 data block 数量过多时，切换到 B+tree（HTree）格式，目录块组织成 B+tree 索引结构，查找复杂度从 O(n) 降到 O(log n)。

---

## 六、配额（Quotas）机制

### 6.1 XFS 配额设计

XFS 的配额机制与 ext4 有本质区别：

| 特性 | XFS | ext4 |
|------|-----|------|
| **配额类型** | USRQUOTA、GRPQUOTA、PRJQUOTA | 同 |
| **实现位置** | inode 级联（每个 inode 可有项目 ID）| 块级（通过 dquot） |
| **磁盘格式** | 每个 AG 的 quota inode | 全局 quota 文件 |
| **配额计数** | dquot 附加到 inode 的 transaction | 独立的 dquot 结构体 |
| **实时检测** | 是（xfs_qm_dqattach） | 是（vfs_dq_mount） |

### 6.2 核心数据结构

```c
// xfs_dquot — quota 记录，附加到 inode
struct xfs_dquot {
    xfs_dqtype_t    q_type;       // USER / GROUP / PROJ
    xfs_dqid_t      q_id;
    struct xfs_dquot_res  q_blk;  // 块使用量
    struct xfs_dquot_res  q_ino;  // inode 使用量
    struct xfs_dquot_res  q_rtb;  // realtime 块使用量
    struct xfs_dq_logitem q_logitem;
    struct mutex     q_qlock;     // quota 锁
    struct completion q_flush;    // 刷盘完成
};
```

### 6.3 配额检查流程

```
write() → xfs_trans_reserve()
  → xfs_qm_dqattach_locked(ip)   // 确保 inode 关联了 dquot
  → xfs_qm_quotacheck()          // 扫描 inode，初始化配额计数
  → xfs_trans_mod_dquot()         // 修改 dquot 的使用量计数
  → 检查 hardlimit / softlimit
  → 超过硬限制 → -EDQUOT
  → 超过软限制 → -EDQUOT（宽限期内）
```

关键函数：
- `xfs_qm_dqattach()` — 将 dquot 关联到 inode（lazy attach）
- `xfs_qm_quotacheck()` — 全量扫描，修正配额计数
- `xfs_trans_mod_dquot()` — 在 transaction 中更新配额计数

### 6.4 XFS 配额与 ext4 的核心区别

1. **存储位置**：ext4 将配额信息存储在磁盘上的全局 quota 文件（`aquota.user` / `aquota.group`），XFS 将配额信息嵌入在 **per-AG quota inode** 中。
2. **项目配额（PRJQUOTA）**：XFS 原生支持项目配额，每个 inode 有一个 32 位 `di_projid`；ext4 的项目配额支持较晚才加入且实现不同。
3. **延迟配额计数**：XFS 使用 lazy dquot attach，只有在实际修改时才关联 dquot，减少配额系统的开销。

---

## 七、崩溃恢复（CRASH）串联

### 7.1 日志恢复流程

```
系统启动 → xfs_mount()
  → xfs_mountfs()
  → xfs_log_mount()
  → xfs_trans_alloc()  (空 transaction)
  → xlog_recover()     ← 核心崩溃恢复入口
```

### 7.2 xlog_recover() 详解

`xfs_log_recover.c` 中的恢复分两遍（two-pass）：

**Pass 1**：扫描日志，验证每条 record 的头部，收集 transaction 信息。不修改磁盘。

**Pass 2**：按顺序重放（replay）所有 transaction：
1. 从日志中读取 transaction header
2. `xlog_recover_commit_trans()` — 重建 transaction
3. `xlog_recover_reorder_trans()` — 按 LSN 排序
4. 对每个 log item 调用 `item->ri_ops->commit_pass2()`
   - `xfs_buf_item_recover()` — 重放 buffer 修改
   - `xfs_inode_item_recover()` — 重放 inode 修改
   - `xfs_bmap_item_recover()` — 重放 extent map 修改
   - `xfs_attr_item_recover()` — 重放 extended attribute 修改

### 7.3 xlog_recover_commit_trans 的关系

```
xlog_recover_commit_trans(log, trans, pass, buffer_list)
  │
  ├─→ xlog_recover_reorder_trans()
  │     按 LSN 重排 trans 中的 log item
  │
  ├─→ list_for_each_item(item, &trans->r_itemq)
  │     │
  │     └─→ switch(pass)
  │           PASS1: item->commit_pass1() — 验证
  │           PASS2: item->ra_pass2() — 预读
  │                  xlog_recover_items_pass2() — 重放
  │
  └─→ xlog_recover_items_pass2()
        对每个 item 调用 item->commit_pass2()
        实际修改磁盘上的元数据
```

### 7.4 恢复的关键保证

XFS 使用 **physical logging**，这意味着：
- 日志中记录的是修改后的完整数据块
- 恢复时直接覆盖磁盘上的块，不需要 redo 日志
- 如果日志条目标记为 `COMMIT`，该 transaction 一定已经完整写入日志
- 如果崩溃发生在写日志期间，recovery 通过 CRC 校验丢弃不完整的记录

---

## 八、inode 分配路径图

```
                        ┌─────────────────────────────┐
                        │   VFS 请求 inode (xfs_iget)  │
                        └──────────────┬──────────────┘
                                       │
                        ┌──────────────▼──────────────┐
                        │  radix_tree_lookup(pag_ici)  │
                        │  inode 缓存查找               │
                        └──────────────┬──────────────┘
                              cache hit │        cache miss
                                       │              │
                        ┌──────────────▼──────────────▼──────┐
                        │     xfs_iget_cache_miss()          │
                        │  1. xfs_imap_to_bp()               │
                        │     AG = XFS_INO_TO_AGNO(ino)       │
                        │     offset = XFS_INO_TO_AGINO(ino)  │
                        │     blkno = (AG * agblocks + ... )  │
                        │  2. xfs_buf_get() 读取磁盘块        │
                        │  3. xfs_inode_from_disk()          │
                        │     解析 dinode → xfs_inode        │
                        │  4. xfs_iformat_data_fork()         │
                        │     根据 di_format:                │
                        │       LOCAL → xfs_iformat_local()  │
                        │       EXTENTS → xfs_iformat_extents()│
                        │       BTREE → xfs_iformat_btree()   │
                        │  5. xfs_iformat_attr_fork()          │
                        │  6. insert into radix_tree          │
                        └────────────────────────────────────┘
```

---

## 九、总结

XFS 是 Linux 生态中最复杂的文件系统之一，其设计处处体现了对**大规模高性能存储**的追求：

1. **inode B+tree** vs extent 数组：可扩展到 16EB 文件系统
2. **实时子卷**：独立管理的实时数据区
3. **物理日志** vs 逻辑日志：恢复简单可靠，但日志体积较大
4. **延迟分配**：以"延迟换性能"，合并小写入为顺序大 I/O
5. **目录 B+tree**：避免目录条目爆炸导致的性能退化
6. **per-AG 配额 inode**：分布式配额管理
7. **双遍崩溃恢复**：CRC 保护 + 两遍重放，保证一致性

XFS 的代码组织清晰（libxfs 包含磁盘格式和 B+tree 通用代码，上层 xfs/ 包含 VFS 集成），但代码量庞大（Linux 7.0 中 fs/xfs/ 目录有超过 300 个 .c 文件），理解其整体架构需要花费大量时间。本文覆盖了 XFS 最核心的七个设计维度，希望能为深入研究 XFS 提供有价值的参考。
