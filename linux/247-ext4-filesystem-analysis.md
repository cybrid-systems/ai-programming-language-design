# ext4 文件系统深度分析

## 概述

ext4（Fourth Extended Filesystem）是 Linux 最主流的文件系统，从 ext2/ext3 演化而来，提供了 extent 映射、大分配组（flex_bg）、延迟分配（delayed allocation）、日志校验和（journal checksums）、在线调整大小等关键特性。代码位于 `fs/ext4/`。

本文从 **inode/extent 树**、**块分配器（mballoc）**、**日志机制（jbd2）**、**目录组织**、**配额**、**快速 fsck**、**在线调整大小** 七条逻辑线深度串联剖析，并画出 inode 读取的完整路径图。

---

## 一、inode 和 extent 树串联

### 1.1 ext4 inode 结构

```c
// fs/ext4/ext4.h:794
struct ext4_inode {
    __le16  i_mode;          // 文件类型 + 权限位
    __le16  i_uid;           // 低16位 UID
    __le32  i_size_lo;       // 文件大小（低32位）
    __le32  i_atime, i_ctime, i_mtime; // 时间戳
    __le32  i_dtime;         // 删除时间
    __le16  i_gid;           // 低16位 GID
    __le16  i_links_count;   // 硬链接计数
    __le32  i_blocks_lo;     // 块数（以 512 字节为单位）
    __le32  i_flags;         // 文件标志（EXT4_EXTENTS_FL 等）
    __le32  i_block[EXT4_N_BLOCKS]; // 块指针数组
    // ...
    __le32  i_size_high;     // 大文件高32位
    // osd2: i_uid_high, i_gid_high, i_checksum_lo
    __le16  i_extra_isize;   // 扩展字段大小
    __le32  i_projid;       // Project ID（配额）
};
```

**关键点**：`i_block[EXT4_N_BLOCKS]` — 在 ext4 中它不再是直接/间接块号数组，而存储 extent 树的根（当 `i_flags & EXT4_EXTENTS_FL` 时）。这是 extent 替换间接块映射的标志。

### 1.2 extent 树的三层数据结构

extent 树由三种结构组成：

```c
// fs/ext4/ext4_extents.h:75
struct ext4_extent_header {
    __le16  eh_magic;    // 0xf30a (EXT4_EXT_MAGIC)
    __le16  eh_entries;  // 有效条目数
    __le16  eh_max;      // 容量
    __le16  eh_depth;    // 树的深度（0=叶子）
    __le32  eh_generation;
};
```

**叶子节点** — `struct ext4_extent`（存储在extent树叶子层）：

```c
// fs/ext4/ext4_extents.h:56
struct ext4_extent {
    __le32  ee_block;      // 逻辑块号（覆盖的起始块）
    __le16  ee_len;        // 覆盖的块数（MSB=1表示unwritten extent）
    __le16  ee_start_hi;   // 物理块号高16位
    __le32  ee_start_lo;   // 物理块号低32位
};
// 物理块号 = (ee_start_hi << 32) | ee_start_lo
```

**索引节点** — `struct ext4_extent_idx`（存储在 extent 树的中间层/根层）：

```c
// fs/ext4/ext4_extents.h:67
struct ext4_extent_idx {
    __le32  ei_block;      // 此索引覆盖的逻辑块号
    __le32  ei_leaf_lo;     // 指向下一层物理块号（低32位）
    __le16  ei_leaf_hi;     // 物理块号高16位
    __u16   ei_unused;
};
```

**遍历路径** — `struct ext4_ext_path`（extent 树遍历的内存结构）：

```c
// fs/ext4/ext4_extents.h:105
struct ext4_ext_path {
    ext4_fsblk_t         p_block;    // 物理块号（解析后）
    __u16                 p_depth;     // 此路径层深度
    __u16                 p_maxdepth;  // 分配的最大深度
    struct ext4_extent   *p_ext;      // 指向找到的 extent（叶子）
    struct ext4_extent_idx *p_idx;    // 指向找到的索引（中间层）
    struct ext4_extent_header *p_hdr; // 指向层的 ext4_extent_header
    struct buffer_head   *p_bh;       // 层的 buffer_head
};
```

**为什么用 extent 而不是间接块：**

| 特性 | ext2/3（间接块） | ext4（extent） |
|------|-----------------|--------------|
| 大文件映射 | 块号指针链→多次磁盘IO | 一个 extent 描述连续的大范围→1次IO |
| 存储开销 | 1GB文件需 1MB 指针空间 | 1GB文件可由1个 extent 描述 |
| 碎片化 | 任意块→复杂映射 | 连续块→简单映射 |
| 深度 | 3级间接→最多 4KB*4K*4K | 4级 extent 树（eh_depth=0~4） |

### 1.3 extent 树的查找过程

```c
// fs/ext4/extents.c:886 — ext4_find_extent
ext4_find_extent(inode, block, path, flags)
  eh = ext_inode_hdr(inode)          // 从 inode->i_data 取 extent_header
  depth = ext_depth(inode)           // eh->eh_depth

  // path[0] 是 inode 自身（eh 已在 i_data 中，无 bh）
  path[0].p_hdr = eh
  path[0].p_bh  = NULL

  // 从根向下遍历：每层读一个块
  i = depth
  while (i--) {                      // i 从 depth 降到 1
    ext4_ext_binsearch_idx(path+ppos, block)  // 在当前索引层二分查找
    path[ppos].p_block = ext4_idx_pblock(p_idx)  // 下一层物理块号
    bh = read_extent_tree_block(inode, p_idx, --i, flags)  // 读下一层块
    eh = ext_block_hdr(bh)            // 解码子节点的 header
    ppos++
    path[ppos].p_bh = bh
    path[ppos].p_hdr = eh
  }

  // 叶子层：在叶子块中二分查找 extent
  ext4_ext_binsearch(path+ppos, block)
  path[ppos].p_ext = found_extent
  path[ppos].p_block = ext4_ext_pblock(found_extent)  // 物理块号
  return path
```

### 1.4 extent 插入与树分裂

当插入新 extent 超出叶子节点容量时，发生**树分裂**：

```c
// fs/ext4/extents.c:1986 — ext4_ext_insert_extent
ext4_ext_insert_extent(handle, inode, path, newext, gb_flags)
  depth = ext_depth(inode)

  if (path[depth].p_hdr->eh_entries < path[depth].p_hdr->eh_max)
    // 叶子有空间：直接插入 extent
    // 可能需要合并相邻 extent
  else
    // 叶子满：需要分裂
    // ext4_ext_split() — 从叶子到根一路分裂
    // 需要 journal handle（因为修改索引层）
    // 需要更新所有父节点的索引条目
```

**extent 插入的 journal credits**：由于可能触发从叶子到根的路径上所有索引块的修改，credits 需求通过 `ext4_ext_calc_credits_for_single_extent` 计算：

```c
// fs/ext4/extents.c:2373
// 最坏情况：depth 层都需要分裂
// depth=4 时，需要 (depth*2)+2 个 metadata 块 + bitmap 块 + group descriptor
// 即 ext4_chunk_trans_blocks() 返回较大值
```

---

## 二、块分配器（mballoc）串联

### 2.1 核心数据结构

ext4 的 mballoc 使用 **buddy bitmap** 算法，以**分配组（block group）** 为单位管理。每个 block group 的结构：

```
┌─────────────────────────────────────────────┐
│  group descriptor (ext4_group_desc)         │
│    bg_block_bitmap_lo/hi  → 块位图块号       │
│    bg_inode_bitmap_lo/hi  → inode位图块号    │
│    bg_inode_table_lo/hi   → inode表起始块    │
│    bg_free_blocks_count   → 可用块数         │
│    bg_checksum            → 校验和            │
├─────────────────────────────────────────────┤
│  block bitmap  (块位图，每位=1个块)           │
├─────────────────────────────────────────────┤
│  inode bitmap  (inode位图)                   │
├─────────────────────────────────────────────┤
│  inode table   (inode 数组)                 │
├─────────────────────────────────────────────┤
│  data blocks   (数据块)                     │
└─────────────────────────────────────────────┘
```

### 2.2 ext4_mb_new_blocks 完整路径

```c
// fs/ext4/mballoc.c:6229
ext4_fsblk_t ext4_mb_new_blocks(handle_t *handle,
                                 struct ext4_allocation_request *ar, int *errp)
  // 1. 检查 quota，分配 reserved blocks
  while (ar->len && ext4_claim_free_clusters(sbi, ar->len, ar->flags))
    ar->len >>= 1   // 减半直到有足够空间

  // 2. 尝试重用预分配空间
  ac = ext4_mb_initialize_context(ac, ar)
  if (!ext4_mb_use_preallocated(ac))
    // 3. 归一化请求（extents 边界对齐等）
    ext4_mb_normalize_request(ac, ar)
    // 4. 分配预分配结构
    ext4_mb_pa_alloc(ac)
    // 5. 调用 Buddy 分配器
    ext4_mb_regular_allocator(ac)
      // a. ext4_mb_find_by_goal — 优先在目标位置附近查找
      // b. CR_GOAL_LEN_FAST → CR_GOAL_LEN_SLOW → CR_BEST_AVAIL
      //    ext4_mb_scan_groups() 遍历 group
      //    对每个 group 调用 mb_find_extent()（buddy 算法）
      //    ext4_mb_try_best_found() — 找不到最优时用次优
  // 6. 标记磁盘空间已用
  ext4_mb_mark_diskspace_used(ac, handle)
    gdp = ext4_get_group_desc(sb, group, &gdp_bh)
    bitmap_bh = ext4_read_block_bitmap(sb, group)
    ext4_lock_group(sb, group)
    mb_set_bits(bitmap_bh->b_data, blkoff, len)        // 置位位图
    ext4_free_group_clusters_set(sb, gdp,
        ext4_free_group_clusters(sb, gdp) - changed) // 更新 gd 空块数
    ext4_group_desc_csum_set(sb, group, gdp)          // 重新计算校验和
    ext4_unlock_group(sb, group)
    percpu_counter_sub(&sbi->s_freeclusters_counter, len) // 更新全局计数器
    ext4_handle_dirty_metadata(handle, NULL, bitmap_bh)  // 日志化位图修改
    ext4_handle_dirty_metadata(handle, NULL, gdp_bh)     // 日志化 group descriptor
```

### 2.3 bg_free_blocks_count 更新链条

```
用户请求块
    ↓
ext4_mb_mark_diskspace_used()
    ↓
mb_set_bits(bitmap_bh->b_data, ...)    // 内存中置位
    ↓
ext4_free_group_clusters_set(sb, gdp,
    old - changed)                      // gdp->bg_free_blocks_count_lo/hi 写回
    ↓
ext4_group_desc_csum_set()              // 为 gdp 计算 checksum 写回
    ↓
ext4_handle_dirty_metadata(handle, NULL, gdp_bh)  // 通过 jbd2 journal 持久化
    ↓
percpu_counter_sub(&sbi->s_freeclusters_counter, ...) // 非持久化，快速路径计数
```

**group descriptor 的写入**：每个 block group 的 `ext4_group_desc` 先被 `ext4_journal_get_write_access` 保护，再被 `ext4_handle_dirty_metadata` 标记为待写入 journal 的缓冲区。在 `jbd2_journal_commit_transaction` 的 metadata 提交阶段（第 620 行附近），所有 dirty 的 group descriptors 才真正写入磁盘。

### 2.4 预分配和延迟回收

ext4 支持**组级预分配（group preallocation）** 和**大块预分配（large preallocation）**：

```c
// fs/ext4/mballoc.c:5935
ext4_mb_discard_lg_preallocations(sb, lg, order, total_entries)
  // 从 lg_prealloc_list[order] 遍历
  // pa（prealloc_space）如果引用计数为0，标记为 deleted
  // ext4_mb_release_group_pa(&e4b, pa) → mb_free_blocks()
  // 更新 group descriptor 的 bg_free_blocks_count
```

预分配机制：`ext4_mb_use_preallocated()` 在 `ext4_mb_new_blocks` 开头检查是否有可复用的预分配块。如果有，直接用它而跳过 buddy 搜索。

---

## 三、日志机制（jbd2）串联

### 3.1 ext4 的 journal 配置

ext4 默认开启 journal（通过 `EXT4_MOUNT_JOURNAL_DATA` 或 `mount -o journal`），日志 inode 编号记录在 superblock 的 `s_journal_inum` 中。

### 3.2 ext4_writepage → journal 数据流

```
用户写文件（write(2) 或 mmap → page cache dirty）
    ↓
ext4_writepages()  [fs/ext4/inode.c:3025]
    ↓
ext4_bmap() 或 ext4_map_blocks()
    ↓
延迟分配：ext4_da_map_blocks()
    ↓
__ext4_journal_start_sb() → jbd2_journal_start()
    ↓
ext4_journal_get_write_access(handle, bh)    // 对元数据块
ext4_handle_dirty_metadata(handle, NULL, bh) // 标记到当前 transaction
```

对于 **data=ordered 模式**（默认）：

```
ext4_writepages()
    ↓
handle = ext4_journal_start(inode, HT_WRITE_PAGE, needed_blocks)
    ↓
遍历 dirty pages：
  ext4_block_write_begin()  →  分配块 ext4_map_blocks()
    ↓
  ext4_journal_ensure_extent_credits()  // 确保 journal credit 足够
    ↓
  ext4_dirty_journalled_data()  →  jbd2_inode_add_write()
    ↓
ext4_journal_stop(handle)  →  等待 jbd2 commit
```

### 3.3 jbd2 日志提交流程（commit 阶段）

`jbd2_journal_commit_transaction`（`fs/jbd2/commit.c:377`）是核心：

```
commit phase 1：锁定当前 transaction（t_running_transaction → NULL）
    ↓
commit phase 2a：journal_submit_data_buffers()
    遍历 t_inode_list 中的每个 jbd2_inode
    对 JI_WRITE_DATA 标志的 inode 调用：
      journal->j_submit_inode_data_buffers(jinode)
    → ext4_normal_submit_inode_data_buffers()
    → 将 inode 的 dirty pages 提交到磁盘（不是 journal）
    ↓
commit phase 2b：jbd2_journal_write_revoke_records()
    ↓
commit phase 3：遍历 t_buffers（metadata buffer 链表）
    对每个 buffer：
      journal_descriptor = get_write_access()
      copy_buffer_to_journal()
      journal_csum_set()
    ↓
commit phase 4：写 descriptor block（描述刚才写的所有 metadata 块）
    ↓
commit phase 5：更新 superblock 的 journal tail
    jbd2_journal_update_sb_log_tail()
    ↓
jbd2_journal_stop() — 通知 transaction 完成
```

**metadata 和 data 的顺序保证**：在 data=ordered 模式下，ext4 **先提交 data buffers 到磁盘**（通过 `journal_submit_data_buffers` → `jbd2_submit_inode_data`），然后在同一个 commit 过程中写 metadata 到 journal。这保证了元数据的journal记录永远指向已刷到磁盘的数据块。

### 3.4 ext4_journal_start / ext4_journal_stop

```c
// fs/ext4/ext4_jbd2.c:92
handle_t *__ext4_journal_start_sb(struct inode *inode, int type, int blocks)
  return jbd2_journal_start(sb, blocks)

handle_t *ext4_journal_start(struct inode *inode, int type, int blocks)
  // 从 sb 或 inode 推断 super_block
  __ext4_journal_start_sb(inode, type, blocks)
```

`ext4_journal_stop(handle)` 最终调用 `jbd2_journal_stop()`：

```c
jbd2_journal_stop(handle)
  if (handle->h_err)
    jbd2_journal_abort()    // 出错时触发快速 abort
  else
    jbd2_journal_end()      // 将 buffer 添加到 t_updates，等待 commit
```

---

## 四、目录组织串联

### 4.1 目录项结构

ext4 的目录项（directory entry）是变长结构：

```c
// fs/ext4/namei.c:216
struct fake_dirent {        // 兼容旧 VFS 层，name_len 在这里
    __le32  inode;
    __le16  rec_len;
    u8      name_len;
    u8      file_type;
};
// ext4_dir_entry_2 包含实际文件名（可变长）
struct ext4_dir_entry_2 {
    __le32  inode;          // 0 表示未使用
    __le16  rec_len;        // 此项总长度（含文件名）
    __u8    name_len;       // 文件名字节数
    __u8    file_type;      // EXT4_FT_REG_FILE 等
    char    name[0];        // 可变长文件名
};
```

目录块（dirblock）组织：一个 block（如 4KB）内填充多个 `ext4_dir_entry_2`，通过 `rec_len` 串联。最后一个条目用 `EXT4_DIRENT_TAIL` 填充以支持校验。

### 4.2 线性目录 vs HTree 目录

小目录（`< 2^15 entries`）使用**线性数组**组织。`ext4_test_inode_flag(dir, EXT4_INDEX_FL)` 判断目录是否启用了 hash-indexed（htree）方式。

当目录变得更大时，ext4 使用 **HTree（扩散树）** — 基于 dirhash 的 B+树变种：

```c
// fs/ext4/namei.c:235
struct dx_entry {            // HTree 索引条目
    __le32  hash;             // 此节点覆盖的哈希范围上限
    __le32  block;            // 指向子节点块号
};
struct dx_countlimit {        // dx_root/dx_node 的头部
    __le16  limit;            // 最多 dx_entry 数
    __le16  count;            // 实际 dx_entry 数
};
struct dx_root {              // HTree 根节点（存储在目录的第一个块）
    struct fake_dirent        dot;
    struct dx_root_info {     // dx_root 专用
        __le32  reserved_zero;
        u8      hash_version;  // DX_HASH_LEGACY / DX_HASH_HALF_MD4 / DX_HASH_TEA
        u8      info_length;   // 固定 8
        u8      indirect_levels;
        u8      unused_flags;
    } info;
    struct dx_entry  entries[];
};
struct dx_node {              // HTree 中间/叶子节点
    struct fake_dirent  fake;
    struct dx_entry     entries[];
};
struct dx_frame {             // 遍历栈
    struct buffer_head *bh;
    struct dx_entry    *entries;
    struct dx_entry    *at;    // 当前 entry 指针
};
```

### 4.3 ext4_find_entry 查找路径

```c
// fs/ext4/namei.c:1668
ext4_find_entry(inode, name, res_dir)
  __ext4_find_entry(dir, &fname, res_dir, NULL)

__ext4_find_entry(dir, fname, res_dir, inlined)
  // 检查是否是 inline data 目录
  if (ext4_test_inode_flag(dir, EXT4_INLINE_DATA_FL))
    return ext4_search_inline_data()

  // 计算 name 的 hash
  ext4_fname_setup_ci(fname, name)
  ext4_fname_hash(fname, &hinfo)

  // 判断使用 htree 还是线性查找
  if (ext4_test_inode_flag(dir, EXT4_INDEX_FL))
    return ext4_dx_find_entry(dir, fname, res_dir)
  else
    // 线性扫描目录块
    for each block in dir:
      scan directory entries linearly
      compare name hash (for case-insensitive)
```

### 4.4 ext4_dx_find_entry（HTree 查找）

```c
// fs/ext4/namei.c:294
ext4_dx_find_entry(dir, fname, res_dir)
  // 读根块（第一个块）
  bh = ext4_bread(NULL, dir, 0, 0)
  root = (struct dx_root *)bh->b_data

  // 在 root->entries 中二分查找 hash
  frames[0].entries = root->entries
  frames[0].at = dx_trace()  // dx_match：找 hash 最近匹配项

  // 如果还有中间层（indirect_levels > 0）
  while (frames[depth].bh is not leaf):
    // 从 frame 取 block 号
    block = dx_get_block(frames[depth].at)
    bh = ext4_bread(dir, block)
    node = (struct dx_node *)bh->b_data
    dx_binsearch()  // 在 node->entries 中找
    frames[depth+1].entries = node->entries
    frames[depth+1].at = dx_match()

  // 到达叶子：是一个普通目录块
  // 在目录块中线性查找 entry
  return search_dir_block(dx_frame_leaf)
```

---

## 五、配额（Quota）机制

### 5.1 ext4 与配额系统的关联

ext4 通过 Linux VFS 的通用配额层（`linux/quota.h`）支持 user quota、group quota 和 project quota。配额信息通过以下 inode 关联：

```c
// fs/ext4/ext4.h
struct ext4_sb_info {
    // ...
    struct ext4_super_block *s_es;
    // quota 文件名（可变）
    const char __rcu *s_qf_names[EXT4_MAXQUOTAS];
    // quota 格式 (QFMT_VFS_V0 / QFMT_VFS_V1)
    int s_jquota_fmt;
    // quota inode（通过 s_es 中 s_usr_quota_inum / s_grp_quota_inum）
};

// fs/ext4/ext4.h:1030 — ext4_inode_info
struct ext4_inode_info {
    // ...
    struct jbd2_inode *jinode;         // 日志关联
    struct rw_semaphore i_data_sem;     // 数据修改序列化
    qsize_t i_reserved_quota;           // 预分配的配额预留
    u64     i_es_seq;                  // extent status 序列号
};
```

**配额写入流程**（以块分配为例）：

```
ext4_mb_new_blocks()
    ↓
dquot_alloc_block(inode, len)      // 检查 inode 所属 user/group 的配额
    ↓
如果配额超限：返回 -EDQUOT，ar->len 被减半重试
    ↓
配额允许：写入磁盘后
ext4_mb_mark_diskspace_used()
    ↓
dquot_claim_block()                // 从预留转为实际使用
```

**配额释放**（文件删除或 truncate）：

```c
ext4_evict_inode(inode)
    ↓
ext4_truncate()  →  ext4_ext_remove_space()
    ↓
ext4_mb_free_blocks()
    ↓
dquot_free_block(inode, released_blocks)
```

### 5.2 mbcache 和 dqopt 的关系

- **mbcache**（metadata block cache）：是 ext4 的页缓存层，用于缓存目录项查找结果、xattr 等元数据块。它通过 `struct mbcache_entry` 用 (block_device, blocknr) 作为 key 进行缓存查找，加速频繁访问的元数据块。
- **dqopt**（disk quota operations）：是 VFS quota 代码的磁盘布局操作结构，定义了如何读、写 quota 文件块。`s_qf_names` 指向 quota 文件路径（如果是文件型配额）。

两者独立：mbcache 缓存**任意元数据块**（包括 quota 文件块），dqopt 定义**如何解释 quota 文件内容**。

---

## 六、快速 fsck（e2fsck）串联

### 6.1 ext4 的 fsck 为什么快

ext3 的 fsck 需要逐块扫描所有 inode 和块位图，确认一致性。ext4 的关键优化：

**1. block group descriptor checksums**

```c
// fs/ext4/ext4.h:402 — ext4_group_desc
struct ext4_group_desc {
    __le32  bg_block_bitmap_lo;
    __le32  bg_inode_bitmap_lo;
    __le32  bg_inode_table_lo;
    __le16  bg_free_blocks_count_lo;
    __le16  bg_free_inodes_count_lo;
    __le16  bg_used_dirs_count_lo;
    __le16  bg_flags;
    // ...
    __le16  bg_checksum;  // crc16(sb_uuid+group+desc)
};
```

`bg_checksum` 在 `ext4_group_desc_csum_set()` 计算。e2fsck 通过校验和快速识别哪些 group descriptor 损坏，从而只检查那些块而不是全部。

**2. extent-status tree（es cache）**

`ext4_es_cachep`（`fs/ext4/extents_status.c:194`）是 extent_status 的 radix-tree 缓存，记录了哪些逻辑块已被分配、哪些是 unwritten、哪些是延迟分配。它帮助 e2fsck 快速重建 bitmaps 而不需要全量扫描。

**3. flex_bg 增大 group 粒度**

flex_bg 将多个连续 block group 合并为一个更大的分配组，块位图合成一个大位图，e2fsck 处理更少的大块。

**4. s_free_blocks_count vs group descriptor**

superblock 中的 `s_free_blocks_count_lo/hi` 是**全局汇总**：

```c
// fs/ext4/ext4.h:1399
ext4_free_blocks_count_set(sb, es, blk)
  es->s_free_blocks_count_lo = cpu_to_le32((u32)blk)
  es->s_free_blocks_count_hi = cpu_to_le32(blk >> 32)
```

而每个 group descriptor 的 `bg_free_blocks_count_lo/hi` 是**分组的精确计数**。

两者关系：
```
s_free_blocks_count = Σ(每 group 的 bg_free_blocks_count) + overhead_clusters
```

e2fsck **不信任** s_free_blocks_count，而是遍历所有 group descriptor 重新求和来验证。如果不匹配说明有元数据损坏。

### 6.2 bg_block_bitmap_csum 和 bg_inode_bitmap_csum

ext4 还在 group descriptor 中对每个 bitmap 块计算独立的 CRC32C 校验和（`bg_block_bitmap_csum_lo/hi`、`bg_inode_bitmap_csum_lo/hi`），通过 `ext4_block_bitmap_csum_set()` 写入。这些校验和让 e2fsck 在读取位图前就能发现位图块本身的腐化。

---

## 七、resize2fs 和在线调整大小

### 7.1 ext4_resize_fs 过程

```c
// fs/ext4/resize.c:1996
int ext4_resize_fs(struct super_block *sb, ext4_fsblk_t n_blocks_count)
  // 1. 验证新大小不超过设备边界
  bh = ext4_sb_bread(sb, n_blocks_count - 1, 0)  // 尝试读最后一块
  // 2. 计算新的 group 数量
  n_group = ext4_get_group_number(sb, n_blocks_count - 1)
  // 3. 计算需要的 group descriptor blocks 数量
  n_desc_blocks = num_desc_blocks(sb, n_group + 1)
  // 4. 如果需要更多 descriptor blocks（resize inode 或 meta_bg）
  if (n_desc_blocks > o_desc_blocks + le16_to_cpu(es->s_reserved_gdt_blocks))
    // 需要分配新 descriptor blocks → 分配它们
  // 5. 初始化新 group's descriptor（BG_BLOCK_UNINIT 标志）
  // 6. 更新 superblock
  ext4_free_blocks_count_set(sbi->s_es, n_blocks_count)
  // 7. 更新 sbi->s_groups_count
  // 8. 写回 superblock 和 所有 group descriptors
```

**struct ext4_super_block 的更新**：`s_blocks_count_lo/hi` → `s_free_blocks_count_lo/hi` 都需要更新。superblock 通过 `ext4_handle_dirty_metadata()` 写入日志。

### 7.2 GPT 与 2TB+ 文件系统

MBR（DOS）分区表最大支持 2TB（2^32 × 512B）。超过 2TB 的文件系统必须使用 GPT 分区表，GPT 支持到 8ZB。

ext4 本身支持 48-bit block count（`s_blocks_count_hi`），通过 `ext4_has_feature_64bit(sb)` 表示。在 Linux 6.19 下，ext4 最大文件系统大小约 1EB（取决于页面大小和块大小）。

---

## 八、ext4 inode 读取完整路径图

从用户进程 `open(2)` 到磁盘块读取的完整路径：

```
用户空间
======
open("/mnt/file", O_RDONLY)
    ↓
VFS 层
======
sys_open()
    → do_filp_open()
    → dentry_open()
    → ext4_file_open()
    → ext4_file_read_iter()
        → generic_file_read_iter()
            → ext4_read_folio()
                → ext4_bread()
                    → ext4_getblk()
                        → _ext4_get_block()
                            → ext4_map_blocks()
                                [核心：extent 查找或分配]
    ↓
extent 查找路径（ext4_map_blocks 内部）
==========================================
ext4_map_blocks(inode, map, flags)
    ↓
    ┌─ 如果是 extent inode（EXT4_EXTENTS_FL 置位）
    │    ext4_ext_map_blocks()
    │        → ext4_find_extent(inode, lblk, NULL, flags)
    │            ┌─ 读取 inode 的 i_data（extent_header）
    │            │    eh = ext_inode_hdr(inode)
    │            │    depth = ext_depth(inode)
    │            ├─ while (i = depth; i-- > 0):
    │            │    ext4_ext_binsearch_idx(path+ppos, block)
    │            │    block = ext4_idx_pblock(p_idx)
    │            │    bh = read_extent_tree_block(inode, ...)
    │            │    eh = ext_block_hdr(bh)
    │            ├─ ext4_ext_binsearch(path+ppos, block)   // 叶子层
    │            └─ return path  // p_ext 指向找到的 extent
    │        → ext4_ext_pblock(p_ext)   // 解析物理块号
    │        → return map->m_pblk, map->m_len
    │
    └─ 如果是非 extent inode（间接块映射）
         ext4_ind_map_blocks()
              // 跟随 i_block[] 中的间接指针
    ↓
块分配（如果块不存在且需要分配）
===================================
ext4_mb_new_blocks(handle, ar, errp)
    → ext4_mb_use_preallocated()      // 尝试预分配
    → ext4_mb_normalize_request(ar)
    → ext4_mb_regular_allocator(ac)
        → ext4_mb_find_by_goal()      // Buddy: 在目标附近找
        → ext4_mb_scan_groups()       // Buddy: 遍历所有 group
        → mb_find_extent()            // 核心 buddy 搜索
    → ext4_mb_mark_diskspace_used(ac, handle)
        → ext4_get_group_desc()       // 加载 group descriptor
        → ext4_read_block_bitmap()    // 读块位图
        → ext4_lock_group()
        → mb_set_bits()               // 置位位图
        → ext4_free_group_clusters_set() // 更新 gdp->bg_free_blocks_count
        → ext4_group_desc_csum_set()  // 校验和
        → ext4_unlock_group()
        → percpu_counter_sub()        // 更新 sbi->s_freeclusters_counter
        → ext4_handle_dirty_metadata() // → journal 化修改
    ↓
buffer I/O 层
==============
ext4_bread() → ext4_getblk() → sb_bread()
    → __bread() → bio_read_page()
        → Submit bio to block layer
            → scsi/nvme/ata 驱动
                → DMA 到磁盘
                    → IRQ 中断
                        → buffer_head 标记 Uptodate
    ↓
folio Uptodate
==============
ext4_read_folio() 回调完成
    → unlock_folio()
        → wake_up_bit(&folio->flags, PG_locked)
    ↓
VFS 返回文件描述符
===================
do_filp_open() 返回 struct file *
→ fd_install() → 进程打开文件表
```

**ASCII 简化视图**：

```
User open(2)
    │
    ▼
┌─────────────────────────────────────────┐
│  VFS: do_filp_open()                    │
│  → dentry lookup (dentry cache)        │
└────────────┬────────────────────────────┘
             ▼
┌─────────────────────────────────────────┐
│  ext4_file_open()                      │
│  → ext4_read_folio()                  │
└────────────┬────────────────────────────┘
             ▼
┌─────────────────────────────────────────┐
│  ext4_bread()                          │
│  → ext4_getblk() → sb_bread()          │
└────────────┬────────────────────────────┘
             ▼
┌─────────────────────────────────────────┐
│  _ext4_get_block()                     │
│  → ext4_map_blocks()                   │
│      ├─ ext4_ext_map_blocks()         │
│      │   └─ ext4_find_extent()        │
│      │       ├─ ext_inode_hdr()         │
│      │       ├─ ext4_ext_binsearch_idx()│
│      │       └─ read_extent_tree_block() │
│      └─ ext4_mb_new_blocks() (if new)  │
│          ├─ ext4_mb_regular_allocator() │
│          ├─ mb_find_extent()            │
│          └─ ext4_mb_mark_diskspace_used()│
│              ├─ ext4_lock_group()        │
│              ├─ mb_set_bits()            │
│              ├─ gdp->bg_free_blocks     │
│              └─ ext4_handle_dirty_meta() │
└────────────┬────────────────────────────┘
             ▼
┌─────────────────────────────────────────┐
│  sb_bread() → submit_bio()             │
│  → block device / NVMe / SCSI         │
│  → buffer_head up-to-date             │
└────────────┬────────────────────────────┘
             ▼
       folio unlocked
       file descriptor returned
```

---

## 总结：七条逻辑线的交织

| 逻辑线 | 核心结构 | 核心操作 | 交织点 |
|--------|---------|---------|--------|
| inode/extent | ext4_extent, ext4_ext_path | ext4_find_extent, ext4_ext_insert_extent | 所有文件读写必经之路 |
| mballoc | ext4_group_desc, buddy bitmap | ext4_mb_new_blocks, ext4_mb_mark_diskspace_used | ext4_map_blocks 触发分配时 |
| jbd2 日志 | jbd2_inode, transaction | journal_submit_data_buffers, jbd2_journal_commit_transaction | 元数据修改必须日志化 |
| 目录组织 | ext4_dir_entry_2, dx_root | ext4_find_entry, ext4_dx_find_entry | namei 操作入口 |
| Quota | ext4_sb_info.s_qf_names, i_reserved_quota | dquot_alloc_block, dquot_claim_block | mballoc 分配前检查 |
| 快速 fsck | bg_checksum, s_free_blocks_count | e2fsck 校验vs 扫描 | superblock/group descriptor |
| resize | ext4_super_block, flex_bg | ext4_resize_fs, num_desc_blocks | superblock 更新 + 新 group 初始化 |

ext4 的设计哲学是**层次清晰、交代价低**：每个子系统（extent、mballoc、jbd2）都是独立的算法模块，通过 VFS 和 buffer_head 的薄胶水层组合在一起。最精妙的设计是 extent 树——它把原来 ext2/3 的三级间接块指针链压缩成了一个最多 5 层的 B+树变种，使得大文件的块映射从 O(n) 降到了 O(log n)。