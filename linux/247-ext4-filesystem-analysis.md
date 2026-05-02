# ext4 文件系统深度分析

ext4（fourth extended filesystem）是 Linux 最主流的文件系统，从 ext3 演化而来，引入了 extent 存储、多块分配器、延迟分配、校验和等关键优化。本文以 Linux 7.0-rc1 内核源码为依据，深入分析 ext4 的五大核心机制：extent 树组织、mballoc 分配器、JBD2 日志、目录 htree 索引，以及快速 fsck 的设计原理。

---

## 一、inode 与 extent 树

### 1.1 从间接块到 extent

ext3 时代，文件数据块通过间接块链（indirect block chain）组织：一个块指针数组存在 inode 或间接块中，每个指针指向一个数据块。缺点是访问任意位置都需要遍历指针链，且大文件的 pointer block 本身占用了大量空间。

ext4 引入 **extent** 作为基本存储单元。一个 extent 描述一段连续的物理块：`[logical_start, length, physical_start]`，用一段描述符代替多个指针。

### 1.2 核心数据结构（ext4_extents.h）

```c
// 叶节点：实际存储数据的 extent
struct ext4_extent {
    __le32  ee_block;      // 覆盖的起始逻辑块号
    __le16  ee_len;         // 覆盖的块数（<= 32768）
    __le16  ee_start_hi;    // 物理块号高 16 位
    __le32  ee_start_lo;    // 物理块号低 32 位
};

// 索引节点：指向下一层 extent block 或索引块
struct ext4_extent_idx {
    __le32  ei_block;       // 此索引覆盖的逻辑块下界
    __le32  ei_leaf_lo;     // 指向下一层块的物理块号（低 32 位）
    __le16  ei_leaf_hi;     // 高 16 位
    __u16   ei_unused;
};

// 每个 extent block（含叶节点和索引节点）的统一头部
struct ext4_extent_header {
    __le16  eh_magic;       // 0xf30a
    __le16  eh_entries;     // 当前条目数
    __le16  eh_max;         // 可容纳的最大条目数
    __le16  eh_depth;       // 树的深度（0 = 叶节点层）
    __le32  eh_generation;  // 树的生成号
};
```

extent tree 的深度最多 5 层（`EXT4_MAX_EXTENT_DEPTH`）。每个 extent block 末尾还有一个 `ext4_extent_tail`，包含 crc32c 校验和。

### 1.3 ext4_ext_path — 遍历路径的载体

ext4 在做 extent 查询或修改时，需要一个数组来记录从根到叶的路径上每一层的信息。这个数组的类型就是 `struct ext4_ext_path`：

```c
struct ext4_ext_path {
    ext4_fsblk_t         p_block;   // 当前层所在块的物理块号
    __u16                p_depth;   // 当前层在树中的深度
    __u16                p_maxdepth; // 路径数组的分配深度
    struct ext4_extent  *p_ext;     // 指向叶子层的 extent 条目（仅在叶子层有效）
    struct ext4_extent_idx *p_idx; // 指向索引条目（索引层有效）
    struct ext4_extent_header *p_hdr; // 指向当前块的 extent_header
    struct buffer_head   *p_bh;    // 当前块对应的 buffer_head
};
```

`ext4_find_extent()` 返回一个动态分配的 `ext4_ext_path[]` 数组，数组长度 = 树的深度 + 1。索引层依次填入索引信息，最后一个元素是叶子层的 `p_ext` 指向实际 extent。

### 1.4 查找过程：ext4_find_extent

```c
// fs/ext4/extents.c:886
ext4_find_extent(inode, block, path, flags)
{
    eh = ext_inode_hdr(inode);          // 从 inode i_data 取 extent header
    depth = ext_depth(inode);           // eh_depth，即树深度

    path = kzalloc_objs(struct ext4_ext_path, depth + 2, gfp);
    path[0].p_hdr = eh;                  // 根节点 = inode 内嵌 extent header
    path[0].p_bh = NULL;

    i = depth;
    while (i) {                          // 从根向叶逐层
        ext4_ext_binsearch_idx(inode, path + ppos, block); // 二分搜索当前索引层
        path[ppos].p_block = ext4_idx_pblock(path[ppos].p_idx);
        bh = read_extent_tree_block(inode, ..., flags);      // 读取下一层块
        eh = ext_block_hdr(bh);
        i--;
    }
    // 叶子层：用 binsearch（非 binsearch_idx）找覆盖 block 的 extent
    ext4_ext_binsearch(inode, path + ppos, block);
    path[ppos].p_ext = ...;             // 找到的 extent 条目
    return path;
}
```

两层二分搜索：索引层用 `ext4_ext_binsearch_idx`（比较 `ei_block`），叶子层用 `ext4_ext_binsearch`（比较 `ee_block`）。

### 1.5 写入时 extent 插入与分裂

当文件写入需要新块，`ext4_ext_map_blocks()` 先 `find_extent` 查找已存在的 extent。若逻辑块不在任何现有 extent 范围内，则分配新物理块，然后调用 `ext4_ext_insert_extent()` 将新 extent 插入树中。

若当前 block 已满，插入操作会触发 **split**：将一个满节点按中位数分裂为两个节点，若父节点也因此满，则递归向上分裂，直到根节点——根节点分裂时深度 +1（这是 extent 树深度增加的唯一途径）。

---

## 二、mballoc — 多块分配器

ext4 的多块分配器（mballoc）负责在块组中寻找连续空闲块，是 ext4 性能的核心。相比 ext3 的位图扫描，mballoc 引入 buddy 系统 + 多种分配策略。

### 2.1 Buddy 分配算法

ext4 为每个块组维护一套 buddy 空闲块管理结构 `struct ext4_buddy`。空闲块按 2^n 个连续块为单位组织成链表（order 0 ~ MB_NUM_ORDERS）。分配时，找到最小的满足大小的 order，从对应链表取出一块；若太大则进一步二分（split）。释放时（`ext4_mb_unload_buddy`），将块与同 order 的 buddy 块合并（merge），直到不能再合。

```c
// 分配核心入口 fs/ext4/mballoc.c:6229
ext4_fsblk_t ext4_mb_new_blocks(handle_t *handle,
                                struct ext4_allocation_request *ar, int *errp)
{
    ac = ext4_mb_initialize_context(ac, ar);     // 初始化 allocation context

    if (!ext4_mb_use_preallocated(ac)) {          // 先尝试用 inode 预分配空间
        ext4_mb_normalize_request(ac, ar);       // 规整化请求（扩展到 2^n 对齐）
        *errp = ext4_mb_pa_alloc(ac);            // 分配预分配结构
repeat:
        *errp = ext4_mb_regular_allocator(ac);   // 调用 buddy 分配器
    }
    if (ac->ac_status == AC_STATUS_FOUND) {
        *errp = ext4_mb_mark_diskspace_used(ac, handle); // 更新块位图、inode
    }
}
```

### 2.2 分配策略 — ext4_mb_regular_allocator

`ext4_mb_regular_allocator` 按**评估准则**（criteria）分多轮尝试，每轮使用不同策略：

| 准则 | 含义 |
|------|------|
| CR_GOAL_LEN_FAST | 优先在目标组附近寻找，尽量靠近 goal 块 |
| CR_GOAL_LEN_SLOW | 放宽 proximity 要求，扫描更多组 |
| CR_BEST_AVAIL | 找最大的可用块 |
| CR_BEST_FOUND | 使用之前扫描找到的最佳块 |

流程：
1. **先尝试 goal** — `ext4_mb_find_by_goal`：如果块组描述符中记录了上一个分配位置，优先从那里开始（有利于空间局部性）
2. **扫描块组** — `ext4_mb_scan_groups`：遍历块组，用 buddy 信息找合适大小的空闲块
3. **找不到则 fallback** 到更宽松的策略

### 2.3 预分配（Preallocation）与回收

ext4 引入了**延迟预分配**：文件写入时提前分配比请求更多的块，形成 `struct ext4_prealloc_space`（pa），挂在 inode 的红黑树 `i_prealloc_node` 上。下次写入若逻辑块落在预分配范围内，直接消费预分配块而无需再向磁盘请求分配。

预分配空间在以下情况被回收：

- **显式释放** — `ext4_free_blocks()` → 释放物理块 → 同步更新 buddy
- **延迟回收（discard）** — `ext4_discard_preallocations()`：在 `writeback` 或 `truncate` 时，扫描 inode 的 i_prealloc_node 树，将未用完的预分配块归还 buddy 系统
- **OOM/紧张时回收** — 当 buddy 扫描发现空间紧张，会调用 `ext4_discard_preallocations()`

```c
// fs/ext4/mballoc.c:5607
void ext4_discard_preallocations(struct inode *inode)
{
    // 遍历 inode 的 i_prealloc_node 红黑树
    for (iter = rb_first(&ei->i_prealloc_node); iter; iter = rb_next(iter)) {
        pa = rb_entry(iter, struct ext4_prealloc_space, ...);
        if (atomic_read(&pa->pa_count) == 0 && !pa->pa_deleted) {
            ext4_mb_mark_pa_deleted(sb, pa);
            rb_erase(&pa->pa_node.inode_node, &ei->i_prealloc_node);
            // 更新 buddy 位图，释放物理块
            ext4_mb_load_buddy_gfp(sb, group, &e4b, ...);
            ext4_mb_free_blocks(..., pa->pa_pstart, pa->pa_len);
            ext4_mb_unload_buddy(&e4b);
        }
    }
}
```

---

## 三、JBD2 日志 — 保证一致性

ext4 的日志（journal）功能由 JBD2（Journaling Block Device 2）子系统实现，位于 `fs/jbd2/`。所有元数据修改（inode 更新、块分配、目录项修改等）都经过日志层。

### 3.1 日志的基本思想

修改元数据前，先将修改内容作为一个**事务（transaction）**记录到日志块（journal blocks）中；日志落盘后，才真正修改磁盘上的元数据。这个过程叫 **write-ahead logging**。

崩溃后恢复时，只要找到日志中已提交的事务（commit block 存在），重放（replay）这些修改即可保证一致性。

### 3.2 事务生命周期

```
开始事务
  ↓
jbd2_journal_start() → handle_t 创建，关联到当前 task
  ↓
元数据修改（每块修改记录到 t_reserved_list 或 t_iobuf_list）
  ↓
jbd2_journal_stop() → 关闭 handle
  ↓
jbd2_journal_commit_transaction() → 将事务写入 journal
      ① 将所有已标记 dirty 的 buffer 写入 journal（数据块）
      ② 计算 CRC32C 校验和
      ③ 写入 COMMIT 块（包含时间戳、checksum）
  ↓
清理并释放 handle
```

### 3.3 Commit 块写入 — journal_submit_commit_record

```c
// fs/jbd2/commit.c:114
static int journal_submit_commit_record(journal_t *journal,
                                        transaction_t *commit_transaction,
                                        struct buffer_head **cbh, __u32 crc32_sum)
{
    bh = jbd2_journal_get_descriptor_buffer(..., JBD2_COMMIT_BLOCK);
    tmp = (struct commit_header *)bh->b_data;
    ktime_get_coarse_real_ts64(&now);
    tmp->h_commit_sec  = cpu_to_be64(now.tv_sec);
    tmp->h_commit_nsec = cpu_to_be32(now.tv_nsec);

    if (jbd2_has_feature_checksum(journal))
        tmp->h_chksum[0] = cpu_to_be32(crc32_sum);

    // 写屏障：确保所有数据已落到存储
    if (journal->j_flags & JBD2_BARRIER)
        write_flags |= REQ_PREFLUSH | REQ_FUA;

    submit_bh(write_flags, bh);   // 提交到块设备
    *cbh = bh;
}
```

**写屏障（barrier）** 是保证日志完整性的关键：`REQ_PREFLUSH` 强制刷新存储写缓存，`REQ_FUA`（Force Unit Access）确保数据直接写入非易失性介质。COMMIT 块落盘后，事务才被认为已提交。

### 3.4 恢复（Recovery）

挂载时若发现 `s_state` 含 `EXT3_ERROR_FS` 或 `EXT4_FEATURE_RO_COMPAT_HAS_JOURNAL`，ext4 调用 `jbd2_journal_recover()` 扫描 journal：

```c
// fs/jbd2/recovery.c
jbd2_journal_recover(journal_t *journal)
{
    // 扫描 journal 找到所有 COMMIT 块
    // 对每个已提交事务，重放其描述的修改到磁盘
    // 跳过不完整事务（无 COMMIT 块者）
}
```

对于完整事务，直接将日志中的修改数据写回对应位置；对于不完整事务，直接丢弃（因为修改尚未真正应用到磁盘）。

---

## 四、目录 htree — 加速文件查找

ext3 的目录是线性结构：目录块中直接存放 `struct ext4_dir_entry_2`，按文件名线性排列，查找是 O(n) 的。目录包含数万文件时，lookup 成为瓶颈。

ext4 对大目录使用 **htree（哈希树）索引**，将查找复杂度降到 O(log n)。

### 4.1 htree 结构

htree 本质是一棵以文件名哈希值为键的**内部节点目录**。每个 htree 节点是一个标准目录块，格式有两种：

- **根节点（dx_root）**：固定在目录的第一个块（block 0），包含 `dx_root_info`（hash 版本、间接层级、info 长度）和 `dx_entry[]` 数组，每个 entry 记录 `[hash, block_ptr]`
- **内部节点（dx_node）**：与 dx_root 结构相同，但通过 `dx_entry` 指向子级 htree 块
- **叶子节点**：仍然存放 `ext4_dir_entry_2` 线性列表，但按 hash 值排序

```c
// fs/ext4/namei.c:235
struct dx_entry {
    __le32 hash;    // 此 entry 对应的 hash 上界
    __le32 block;   // 指向的子块号
};

struct dx_root {
    struct fake_dirent   dot;
    char                 dot_name[4];
    struct fake_dirent   dotdot;
    char                 dotdot_name[4];
    struct dx_root_info {
        __le32  reserved_zero;
        u8      hash_version;   // TEA / Half-MD4 / Legacy / SipHash
        u8      info_length;    // = 8
        u8      indirect_levels;
        u8      unused_flags;
    } info;
    struct dx_entry entries[]; // 可变长数组
};

struct dx_node {
    struct fake_dirent  fake;
    struct dx_entry     entries[];
};
```

### 4.2 查找过程：dx_probe 与 ext4_dx_find_entry

```c
// fs/ext4/namei.c:778
static struct dx_frame *dx_probe(struct ext4_filename *fname, struct inode *dir,
                                  struct dx_hash_info *hinfo, struct dx_frame *frame_in)
{
    // 读取 block 0（htree 根节点）
    frame->bh = ext4_read_dirblock(dir, 0, INDEX);
    root = (struct dx_root *) frame->bh->b_data;

    // 计算 name 的 hash（SipHash 等）
    ext4fs_dirhash(dir, fname_name(fname), fname_len(fname), hinfo);
    hash = hinfo->hash;

    level = 0;
    while (1) {
        entries = (struct dx_entry *)((char *)&root->info + root->info.info_length);
        count = dx_get_count(entries);

        // 二分搜索：找 hash 落在 [at-1, at] 之间的 entry
        p = entries + 1;
        q = entries + count - 1;
        while (p <= q) {
            m = p + (q - p) / 2;
            if (dx_get_hash(m) > hash)
                q = m - 1;
            else
                p = m + 1;
        }
        at = p - 1;
        block = dx_get_block(at);

        if (++level > indirect)
            return frame;  // 到达叶子层

        // 读取下一层节点，继续二分
        frame++;
        frame->bh = ext4_read_dirblock(dir, block, INDEX);
        entries = ((struct dx_node *) frame->bh->b_data)->entries;
    }
}
```

`dx_probe` 每层做一次二分搜索（O(1)），最多遍历 `indirect_levels` 层（通常 1~2 层），最终到达叶子目录块。叶子块中的 `ext4_dir_entry_2` 列表再用 `search_dirblock()` 线性查找具体文件名。

### 4.3 从 ext4_find_entry 入口看路由

```c
// fs/ext4/namei.c:1517
static struct buffer_head *__ext4_find_entry(struct inode *dir, ...)
{
    // 是否为 htree 目录？
    if (is_dx(dir)) {
        ret = ext4_dx_find_entry(dir, fname, res_dir); // htree 路径
        if (!IS_ERR(ret) || PTR_ERR(ret) != ERR_BAD_DX_DIR)
            goto cleanup_and_exit;
        // htree 损坏时退化到线性搜索
    }
    // 非 htree：大目录或不支持 htree → 线性扫描块
    nblocks = dir->i_size >> EXT4_BLOCK_SIZE_BITS(sb);
    for (i = 0; i < nblocks; i++) {
        bh = ext4_bread(dir, i);
        if (search_dirblock(bh, ...) == FOUND)
            goto cleanup_and_exit;
    }
}
```

---

## 五、快速 fsck — ext4 vs ext3

ext3 时代，每次启动 `fsck.ext4` 都需要全量扫描所有 inode 和块位图，时间随文件系统大小线性增长。对于数 TB 的磁盘，这可能需要数十分钟甚至数小时。

ext4（启用 `meta_bg` 和 `flex_bg` 特性后）实现了**显著更快的 fsck**，核心原因如下：

### 5.1 块组描述符校验和（block group descriptor checksum）

ext3 的块组描述符（block group descriptor）不含校验和，且存放在固定位置。若文件系统元数据损坏，修复工具可能读取到错误的描述符信息，导致误判。

ext4 在 `s_block_group_info` 中为每个块组维护一个 `struct ext4_group_desc_info`，包含 CRC32C 校验和：`gdc->gdx.crc32c(uuid+group_desc_group_num+group_desc)`。fsck 首先验证所有块组描述符的校验和，损坏的描述符可以直接识别并跳过，避免二次损坏。

### 5.2 稀疏 Superblock（sparse superblock）

ext4 默认不将 superblock 和块组描述符表写入每个块组——只有备份的 superblock 存在于少数保留块组（1, 3, 5, 7, 9 的幂次等）。这意味着：

- fsck 不需要扫描所有块组去找 superblock
- 只需验证主 superblock 和少数备份的 checksum，即可确认文件系统整体状态
- 一个块组损坏不会连带损坏其他块组的描述符

### 5.3 元数据块链接（meta_bg）

`meta_bg`（flex_bg 前身）将块组分组管理，每组内的块组描述符集中存放，fsck 可以批量处理。

更关键的是 **flex_bg**：多个相邻块组组成一个 flex group，块组描述符、inode 表、保留块全部集中在 flex group 首部。fsck 处理时，**只需要扫描有数据的 flex group**，空闲的 flex group 直接跳过。

```c
// fs/ext4/super.c:5492
needs_recovery = (es->s_last_orphan != 0 ||
                  ext4_has_feature_journal_needs_recovery(sb));

// fsck 前，先运行 journal_recover
if (needs_recovery) {
    journal = jbd2_journal_init_inode(journal_inode);
    jbd2_journal_recover(journal);
    jbd2_journal_destroy(journal);
}
```

### 5.4 ext4 vs ext3 fsck 速度差异总结

| 因素 | ext3 | ext4（含 flex_bg） |
|------|------|---------------------|
| 块组描述符校验和 | 无 | CRC32C，每块组可独立验证 |
| Superblock 分布 | 每块组都写 | 仅主块组 + 稀疏备份 |
| 元数据扫描范围 | 全量扫描所有块组 | 只扫描有数据的 flex_group |
| Journal replay | 可选 | 必然执行，journal 提交本身验证了大量元数据一致性 |
| 块组分组 | 无（线性扫描） | flex_bg 分组，可跳过空闲组 |

实际测试中，同等大小文件系统，ext4 fsck 通常比 ext3 快 **5~20 倍**，原因是上述多种优化叠加：稀疏 superblock 减少读取量，flex_bg 跳过空闲区域，校验和快速识别损坏块组。

---

## 六、数据流串联

以下是一段文件写入操作在 ext4 中的完整数据流，串联五大机制：

```
open("/dir/file")
  → ext4_lookup()        # 目录 htree：dx_probe 定位文件 inode
  → ext4_file_write()
      → ext4_write_begin()
          → ext4_discard_preallocations()    # 检查并回收预分配空间
          → ext4_map_blocks()
              → ext4_find_extent()           # 查 extent 树（O(log n)）
              → 若需新块：ext4_mb_new_blocks()
                  → ext4_mb_regular_allocator()  # buddy 算法 + 预分配策略
                      → ext4_mb_mark_diskspace_used() # 更新块位图（journaled）
              → ext4_ext_insert_extent()     # extent 树插入/split
      → jbd2_journal_start() + handle  → 元数据修改记录到日志
      → ext4_write_end()
  → jbd2_journal_stop()
      → jbd2_journal_commit_transaction()
          → journal_submit_commit_record()  # 写 COMMIT 块（带 barrier）
```

崩溃恢复时：
```
jbd2_journal_recover()
  → 扫描 journal 中的所有事务
  → 对每个有 COMMIT 块的事务重放修改
  → ext4 组装 extent 树（extent tree rebuild）
  → 完成一致性恢复
```

---

## 参考文献

- `fs/ext4/ext4_extents.h` — extent 数据结构定义
- `fs/ext4/extents.c` — extent 树操作（查找、插入、分裂）
- `fs/ext4/mballoc.c` — 多块分配器（buddy + 预分配）
- `fs/ext4/namei.c` — htree 索引（dx_probe, ext4_find_entry）
- `fs/jbd2/commit.c` — 日志提交（commit record 写入）
- `fs/jbd2/recovery.c` — 日志恢复
- `fs/ext4/super.c` — 文件系统初始化与快速 fsck 逻辑