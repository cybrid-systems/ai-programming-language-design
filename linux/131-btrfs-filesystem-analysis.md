# 249 — Btrfs 文件系统深度分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）对 `fs/btrfs/ctree.c`、`fs/btrfs/extent_io.c` 进行符号级追踪
> 内核版本：Linux 7.0-rc1

---

## 0. 概述

**Btrfs（B-tree File System）** 是 Linux 内核中唯一一个将 COW B 树作为统一存储引擎的文件系统。与 ext4/XFS 的块组+日志架构不同，Btrfs 用一棵全局 B 树管理所有元数据——文件数据、目录项、extent 分配、chunk 映射、校验和全部纳入同一键空间。

**架构特点**：

```
用户可见文件系统
    └── fs_root（文件 B 树，每个子卷独立）
        └── tree_root（全局元数据 B 树，所有根的根）
            ├── extent-tree（空闲 extent 分配记录）
            ├── chunk_root（chunk → 物理设备映射）
            ├── dev_root（设备列表）
            └── csum_root（数据校验和）

块设备层
    └── raid1/mirror / raid10 / dup（在 chunk_map 层实现）
```

---

## 1. 核心数据结构

### 1.1 extent_buffer — B 树节点

每个 B 树节点在内存中是 `struct extent_buffer`，在磁盘上直接对应一个块设备扇区组：

```c
// fs/btrfs/extent_io.h:86
struct extent_buffer {
    u64 start;                          /* 磁盘起始字节偏移 */
    u32 len;                            /* 节点长度（通常 16KB）*/
    unsigned long bflags;               /* 标志位（WRITTEN, LOCKED 等）*/
    struct btrfs_fs_info *fs_info;
    void *addr;                         /* 内存映射地址 */

    spinlock_t refs_lock;
    refcount_t refs;                    /* 引用计数，用于缓存回收 */
    int read_mirror;                    /* 读取使用的镜像号 */

    struct rw_semaphore lock;           /* 读写信号量，锁住整个节点 */
    struct folio *folios[INLINE_EXTENT_BUFFER_PAGES];
};
```

**磁盘格式**（`struct btrfs_header`，每个 extent_buffer 头部都有）：

```c
struct btrfs_header {
    u8 csum[BTRFS_CSUM_SIZE];           /* CRC32C 元数据校验和 */
    u8 fsid[BTRFS_FSID_SIZE];           /* 文件系统 UUID */
    __le64 bytenr;                      /* 自身磁盘地址 */
    __le64 flags;
    u8 chunk_tree_uuid[BTRFS_UUID_SIZE];
    __le64 generation;                  /* 事务世代号（核心）*/
    __le64 owner;                       /* 所属根的 objectid */
    __le32 nritems;                     /* 条目数量 */
    u8 level;                           /* 树层级（0=leaf）*/
};
```

**关键**：`generation` 字段使得 Btrfs 可以不通过日志就实现原子性——每次事务提交后 generation 递增，旧节点保留但 generation 不匹配，因此不可见。

### 1.2 btrfs_path — B 树搜索路径

Btrfs 的 B 树搜索路径记录从根到叶子的完整遍历状态：

```c
// fs/btrfs/ctree.h
struct btrfs_path {
    struct extent_buffer *nodes[BTRFS_MAX_LEVEL]; /* 每层节点（锁住）*/
    int slots[BTRFS_MAX_LEVEL];                    /* 每层槽位 */
    u8 locks[BTRFS_MAX_LEVEL];                      /* 锁状态 */
    u8 lowest_level;                               /* 最低允许层级 */
    bool skip_locking;                             /* 跳过加锁（只读搜索）*/
    bool search_commit_root;                       /* 在已提交根中搜索 */
    bool nowait;                                   /* 非阻塞模式 */
};
```

使用模式：
```c
path = btrfs_alloc_path();
btrfs_search_slot(trans, root, &key, path, ins_len, cow);
// → 完成后 path->nodes[level] 持有每层锁住的 buffer
//   path->slots[level] 记录每层位置
btrfs_release_path(path);    // 释放锁和引用
btrfs_free_path(path);
```

### 1.3 btrfs_key — 全局统一键

```c
struct btrfs_key {
    u64 objectid;      /* 对象 ID（inode 号、root ID 等）*/
    u8 type;            /* 条目类型，区分元数据类型 */
    u64 offset;         /* 偏移或子类型 */
};
```

通过 `(objectid, type, offset)` 三元组定位所有对象：

| type 值 | 含义 |
|---------|------|
| `BTRFS_INODE_ITEM_KEY` | inode 元数据 |
| `BTRFS_DIR_ITEM_KEY` | 目录项 |
| `BTRFS_EXTENT_DATA_KEY` | 文件数据 extent 引用 |
| `BTRFS_EXTENT_ITEM_KEY` | extent 分配记录（extent-tree）|
| `BTRFS_CHUNK_ITEM_KEY` | chunk 物理映射（chunk_root）|
| `BTRFS_ROOT_ITEM_KEY` | 子卷根节点指针 |

---

## 2. Extent Tree 与 B-tree 的关系

### 2.1 两套 B 树

Btrfs 在 `fs_info` 中维护多个独立的 B 树根（`btrfs_root`）：

```c
// fs/btrfs/fs.h
struct btrfs_fs_info {
    struct btrfs_root *tree_root;       /* 全局元数据 B 树（extent-tree 的载体）*/
    struct btrfs_root *chunk_root;      /* chunk→物理设备映射树 */
    struct btrfs_root *fs_root;         /* 当前文件系统的文件树根 */
    struct btrfs_root *dev_root;        /* 设备列表树 */
    struct btrfs_root *csum_root;       /* 数据校验和树 */
    struct btrfs_root *free_space_root; /* 空闲空间管理树（V2）*/
};
```

**核心区分**：

- **tree_root**：管理所有其他 B 树根的元数据 B 树。其叶子中包含 `BTRFS_ROOT_ITEM_KEY`，指向各个子卷的根节点。快照的核心机制就在这里——两个 root_item 可以指向同一个根节点（COW 前共享）。
- **fs_root（文件树）**：每个子卷/快照有一个独立的文件树。文件树中存储 `BTRFS_INODE_ITEM_KEY`、`BTRFS_DIR_ITEM_KEY`、`BTRFS_EXTENT_DATA_KEY` 等。
- **extent-tree（extent_root）**：在 tree_root 中存储为 `BTRFS_EXTENT_ITEM_KEY` 条目，记录每个物理 extent 的分配状态（已用/空闲）。

```
tree_root B 树：
  key = (objectid=某个根的ID, type=BTRFS_ROOT_ITEM_KEY, offset=0)
    → value = btrfs_root_item（包含该根的根节点块号）

  key = (objectid=X, type=BTRFS_EXTENT_ITEM_KEY, offset=Y)
    → value = extent 分配记录（哪个物理范围、属于哪个根、引用计数）

  key = (objectid=0, type=BTRFS_CHUNK_ITEM_KEY, offset=Z)
    → value = chunk 条目（条带数、物理设备列表）
```

### 2.2 extent tree 是怎么工作的

当 btrfs 需要分配一个新的元数据块时：

```c
// fs/btrfs/extent-tree.c:4871
int btrfs_reserve_extent(..., struct btrfs_key *ins, ...)
{
    // 找空闲空间 → 更新 extent tree（写入 tree_root B 树）
    ret = find_free_extent(root, ins, &ffe_ctl);

    // 为已分配 extent 创建 delayed ref
    // 这会插入 tree_root 中的 BTRFS_EXTENT_ITEM_KEY 条目
}
```

extent tree 的条目描述了每个物理 extent 的归属和引用计数。当一个 block 被多个 root 共享时（如快照），extent 条目中记录 `ref_count > 1`，只有 `ref_count==0` 时才真正释放。

### 2.3 btrfs_search_slot 的工作方式

`btrfs_search_slot` 是所有 B 树操作的入口：

```c
// fs/btrfs/ctree.c:2001
int btrfs_search_slot(struct btrfs_trans_handle *trans,
    struct btrfs_root *root, const struct btrfs_key *key,
    struct btrfs_path *p, int ins_len, int cow)
{
    // 1. 获取根节点（根据 search_commit_root / skip_locking 决定加锁模式）
    b = btrfs_search_slot_get_root(root, p, write_lock_level);

    // 2. 逐层下降
    while (b) {
        slot = btrfs_bin_search(b, key, &slot_ret); // 二分查找

        if (level == 0) break; // 到了叶子层

        // 3. 如果需要 COW（cow=1 且 ins_len≠0）
        if (cow && should_cow_block(trans, root, b)) {
            ret2 = btrfs_cow_block(trans, root, b, ...);
            p->nodes[level] = cow;
        }

        // 4. 下降到子节点
        b = btrfs_read_node_slot(b, slot);
        level--;
    }
    return ret;
}
```

`btrfs_search_slot_get_root` 根据路径模式有不同的根获取方式：

```c
// fs/btrfs/ctree.c:1703
static struct extent_buffer *btrfs_search_slot_get_root(...)
{
    if (p->search_commit_root) {
        // 只读搜索：从 root->commit_root 开始，不加锁
        b = root->commit_root;
        refcount_inc(&b->refs);
        goto out;
    }
    if (p->skip_locking) {
        // 跳过加锁（内部操作）
        b = btrfs_root_node(root);
        goto out;
    }
    // 正常读写：从 root->node 开始，需要 rw 锁
    b = btrfs_read_lock_root_node(root);
}
```

---

## 3. COW 机制详解

### 3.1 should_cow_block — 判断是否需要 COW

```c
// fs/btrfs/ctree.c:606
static inline bool should_cow_block(struct btrfs_trans_handle *trans,
    const struct btrfs_root *root, struct extent_buffer *buf)
{
    // 条件1：块不是本事务创建的
    if (btrfs_header_generation(buf) != trans->transid)
        return true;

    // 条件2：块已经被写过（不是新建的）
    if (btrfs_header_flag(buf, BTRFS_HEADER_FLAG_WRITTEN))
        return true;

    // 条件3：根被强制 COW（快照创建期间）
    if (test_bit(BTRFS_ROOT_FORCE_COW, &root->state))
        return true;

    // 条件4：RELOC 根不需要 COW
    if (btrfs_root_id(root) == BTRFS_TREE_RELOC_OBJECTID)
        return false;

    // 条件5：RELOC 标记的块需要 COW
    if (btrfs_header_flag(buf, BTRFS_HEADER_FLAG_RELOC))
        return true;

    return false;
}
```

这意味着：**每个事务中，对同一个 block 的第一次修改就需要 COW**。这保证了快照创建时，所有被快照共享的节点都自动获得独立的副本。

### 3.2 btrfs_cow_block — COW 执行路径

```c
// fs/btrfs/ctree.c:651
int btrfs_cow_block(struct btrfs_trans_handle *trans,
    struct btrfs_root *root, struct extent_buffer *buf,
    struct extent_buffer *parent, int parent_slot,
    struct extent_buffer **cow_ret, enum btrfs_lock_nesting nest)
{
    // 0. 必须在活跃事务中
    if (trans->transaction != fs_info->running_transaction ||
        trans->transid != fs_info->generation)
        return -EUCLEAN;

    // 1. 判断是否真的需要 COW（内联检查）
    if (!should_cow_block(trans, root, buf)) {
        *cow_ret = buf;
        return 0;
    }

    // 2. 委托给 btrfs_force_cow_block 执行实际 COW
    return btrfs_force_cow_block(trans, root, buf, parent, parent_slot,
                                 cow_ret, search_start, 0, nest);
}
```

### 3.3 btrfs_force_cow_block — 真正的 COW 操作

```c
// fs/btrfs/ctree.c:465
int btrfs_force_cow_block(struct btrfs_trans_handle *trans,
    struct btrfs_root *root, struct extent_buffer *buf, ...)
{
    level = btrfs_header_level(buf);

    // 1. 从 extent 分配器申请新块
    cow = btrfs_alloc_tree_block(trans, root, parent_start,
        btrfs_root_id(root), &disk_key, level, search_start, 0, ...);

    // 2. 将旧节点内容完整复制到新节点
    copy_extent_buffer_full(cow, buf);

    // 3. 设置新节点的元数据
    btrfs_set_header_generation(cow, trans->transid); // 新 generation
    btrfs_clear_header_flag(cow, BTRFS_HEADER_FLAG_WRITTEN |
                                  BTRFS_HEADER_FLAG_RELOC);
    btrfs_set_header_owner(cow, btrfs_root_id(root));

    // 4. 更新旧节点的引用计数（update_ref_for_cow）
    ret = update_ref_for_cow(trans, root, buf, cow, &last_ref);
    // → tree_root 中的 extent 条目引用计数变化
    // → 如果 last_ref=1（旧节点不再被任何东西引用），可被释放

    // 5. RELOC 根特殊处理
    if (test_bit(BTRFS_ROOT_SHAREABLE, &root->state))
        btrfs_reloc_cow_block(trans, root, buf, cow);

    // 6. 更新父节点指针
    if (buf == root->node) {
        // 根节点 COW：原子切换根指针
        rcu_assign_pointer(root->node, cow);
        add_root_to_dirty_list(root);
    } else {
        // 非根：更新父节点的子指针
        btrfs_set_node_blockptr(parent, parent_slot, cow->start);
        btrfs_set_node_ptr_generation(parent, parent_slot, trans->transid);
        btrfs_mark_buffer_dirty(trans, parent);
    }

    // 7. 释放旧块
    btrfs_free_tree_block(trans, btrfs_root_id(root), buf, ...);
}
```

**核心**：COW 后旧块通过 `update_ref_for_cow` 更新 extent 树中的引用计数。当引用计数归零，旧块才成为空闲空间。这正是快照可以"零成本共享"的原因——快照不复制数据，只增加引用计数。

### 3.4 btrfs_copy_root — 快照中的整树复制

快照不只是 COW 单个块，而是复制从当前根到被修改路径上所有块的完整链：

```c
// fs/btrfs/ctree.c:243
int btrfs_copy_root(struct btrfs_trans_handle *trans,
    struct btrfs_root *root, struct extent_buffer *buf,
    struct extent_buffer **cow_ret, u64 new_root_objectid)
{
    level = btrfs_header_level(buf);

    // 分配新块
    cow = btrfs_alloc_tree_block(trans, root, 0, new_root_objectid,
        &disk_key, level, buf->start, 0, reloc_src_root, ...);

    // 完整复制
    copy_extent_buffer_full(cow, buf);
    btrfs_set_header_generation(cow, trans->transid);
    btrfs_set_header_owner(cow, new_root_objectid); // 新根的 ID

    // 更新 extent 树中的引用计数
    ret = btrfs_inc_ref(trans, new_root, cow, 1, &qgroup_transac);
}
```

快照过程：
1. 读取原子的根节点 → COW 复制为 `snap_root`
2. 递归复制所有子节点（如果需要）
3. 在 `tree_root` 中插入新的 `ROOT_ITEM` 条目，指向 `snap_root`

---

## 4. Chunk 分配与 Extent 管理

### 4.1 btrfs_alloc_tree_block — 分配元数据块

```c
// fs/btrfs/extent-tree.c:5335
struct extent_buffer *btrfs_alloc_tree_block(
    struct btrfs_trans_handle *trans, struct btrfs_root *root,
    u64 parent, u64 root_objectid,
    const struct btrfs_disk_key *key, int level,
    u64 hint, u64 empty_size, u64 reloc_src_root, ...)
{
    // 1. 预留块组空间
    block_rsv = btrfs_use_block_rsv(trans, root, blocksize);

    // 2. 从空闲空间寻找可用 extent
    ret = btrfs_reserve_extent(root, blocksize, blocksize, blocksize,
        empty_size, hint, &ins, false, false);

    // 3. 初始化新的 extent_buffer
    buf = btrfs_init_new_buffer(trans, root, ins.objectid, level, ...);

    // 4. 记录分配操作到 delayed ref
    // → 创建 delayed extent op → 稍后写入 tree_root 的 extent B 树
}
```

### 4.2 btrfs_reserve_extent — 空闲空间查找

```c
// fs/btrfs/extent-tree.c:4871
int btrfs_reserve_extent(..., struct btrfs_key *ins, ...)
{
    // 根据根的类型（data/meta）选择分配 profile（raid1/single/dup 等）
    flags = get_alloc_profile_by_root(root, is_data);

    // 在 block_group 链表中寻找足够的空闲空间
    ret = find_free_extent(root, ins, &ffe_ctl);

    // 如果空间不足，尝试折半分配
    if (ret == -ENOSPC && !final_tried) {
        num_bytes >>= 1;
        goto again;
    }
}
```

### 4.3 chunk_root 与 chunk_map

chunk 信息存储在 `chunk_root` 的 B 树中，key 是 `(objectid=0, type=BTRFS_CHUNK_ITEM_KEY, offset=chunk_start)`：

```c
// fs/btrfs/volumes.c
struct btrfs_chunk_map {
    u64 start;              /* chunk 逻辑起始 */
    u64 len;                 /* chunk 长度 */
    u64 type;                /* BTRFS_BLOCK_GROUP_* 类型（RAID 级别）*/
    int num_stripes;         /* 条带数 */
    int sub_stripes;         /* 子条带数（RAID10 用）*/
    struct btrfs_chunk_stripe stripes[];
};
```

每个条带记录物理设备偏移。当 `map_blocks_raid1` 被调用时：

```c
// fs/btrfs/volumes.c:6904
static void map_blocks_raid1(struct btrfs_fs_info *fs_info,
    struct btrfs_chunk_map *map, struct btrfs_io_geometry *io_geom, ...)
{
    if (io_geom->op != BTRFS_MAP_READ) {
        // 写操作：所有条带都写
        io_geom->num_stripes = map->num_stripes;
        return;
    }
    // 读操作：选择第一个活镜像
    io_geom->stripe_index = find_live_mirror(fs_info, map, ...);
}
```

---

## 5. RAID1 冗余的层面

Btrfs 的 RAID1 在 **chunk map 层**实现，而非在块设备层。这带来一个重要特性：**写操作同时发往所有镜像设备**。

### 5.1 write 时 RAID1 行为

写数据到 RAID1 chunk 时：

```c
// fs/btrfs/volumes.c:6904 map_blocks_raid1
// 写操作 → io_geom->num_stripes = map->num_stripes
// 所有 num_stripes 个条带都会被写入
```

Btrfs 为每个条带构造独立的 bio，提交到块设备层。由于块设备层（如 md raid1）也可能做自己的镜像，Btrfs 的 RAID1 和底层块设备 RAID 可以形成嵌套（不推荐）。

### 5.2 read 时 RAID1 行为

```c
// fs/btrfs/volumes.c:6904 map_blocks_raid1
// 读操作：find_live_mirror() 选择一个健康设备
io_geom->stripe_index = find_live_mirror(fs_info, map, 0, dev_replace_is_ongoing);
io_geom->mirror_num = io_geom->stripe_index + 1;
```

读取失败时，bio 层会通过 `REQ_FAILFAST` 标志尝试其他镜像。

### 5.3 raid1 与 raid10 的差异

```c
// raid1: 所有条带都写，读选择其中一个
// num_stripes = map->num_stripes（= 2 for raid1）

// raid10: 条带化写入，子条带数决定写并发数
// num_stripes = map->sub_stripes
// factor = map->num_stripes / map->sub_stripes
```

---

## 6. 快照与子卷的关系

### 6.1 create_snapshot 流程

```c
// fs/btrfs/ioctl.c:704
static int create_snapshot(struct btrfs_root *root, struct inode *dir, ...)
{
    // 1. 分配 pending_snapshot 和临时 block_rsv
    pending_snapshot = kzalloc(...);
    block_rsv = &pending_snapshot->block_rsv;
    btrfs_init_block_rsv(block_rsv, BTRFS_BLOCK_RSV_TEMP);

    // 2. 预留子卷元数据空间
    trans_num_items = create_subvol_num_items(inherit) + 3;
    btrfs_subvolume_reserve_metadata(..., block_rsv, trans_num_items, ...);

    // 3. 启动事务
    trans = btrfs_start_transaction(root, 0);

    // 4. 设置 pending_snapshot，在事务提交时执行实际复制
    trans->pending_snapshot = pending_snapshot;

    // 5. 提交事务
    ret = btrfs_commit_transaction(trans);
    // → commit 时调用 create_pending_snapshots()
}
```

### 6.2 COW 对快照的影响

快照的核心是 **COW 路径上的所有节点**：

```
快照前：fs_root 的根节点 A 被两个 root_item 引用
  tree_root: root_item_A → node_A

快照后：创建新的 root_item_B，指向 COW 后的 node_A'
  tree_root: root_item_A → node_A（不再被新快照引用）
             root_item_B → node_A'（COW 自 node_A）

node_A 与 node_A' 的内容相同（完整复制）
node_A 保留在磁盘上，node_A' 成为新快照的根
```

因此：
- **快照本身不复制数据**，只复制路径上的节点
- 被多个快照共享的节点（未修改）保持单副本，extent 条目 `ref_count > 1`
- 一旦某个快照修改了共享节点，该节点被 COW，新副本只属于该快照

### 6.3 子卷 vs 快照

```c
// 子卷 = 独立的 btrfs_root（有自己的文件树）
// 快照 = 子卷的只读副本（COW 后共享未修改的节点）
// 两者在 tree_root 中都是 ROOT_ITEM 条目，区别在于：
//   - 子卷：可读写，创建时无 COW
//   - 快照：只读（root_item 置 BTRFS_ROOT_SUBVOL_RDONLY），创建时 COW 根节点
```

---

## 7. 压缩机制

### 7.1 支持的压缩算法

```c
// fs/btrfs/compression.c:39
static const char* const btrfs_compress_types[] = { "", "zlib", "lzo", "zstd" };

// 调用分发：
switch (cb->compress_type) {
case BTRFS_COMPRESS_ZLIB: return zlib_decompress_bio(ws, cb);
case BTRFS_COMPRESS_LZO:  return lzo_decompress_bio(ws, cb);
case BTRFS_COMPRESS_ZSTD: return zstd_decompress_bio(ws, cb);
}
```

### 7.2 zlib vs zstd

| 特性 | zlib | zstd |
|------|------|------|
| 算法 | DEFLATE（LZ77 + Huffman）| Zstandard（ANS + 匹配finder）|
| 压缩速度 | 慢 | 快（类似 lzo）|
| 解压速度 | 中等 | 非常快 |
| 压缩比 | 较高 | 与 zlib 相当或更好 |
| 内存需求 | 低 | 略高 |
| 使用场景 | 通用 | 虚拟机镜像、日志、数据库 |

zstd 在 Btrfs 中作为默认推荐算法，因为它在解压速度和压缩比之间取得了良好平衡。zlib 则在极端低内存环境下更可靠。

### 7.3 压缩流程

```
写入：btrfs_bio_endio_write() → btrfs_compress_bio()
  → 尝试压缩数据
  → 压缩有效：存储 compressed extent（inline 或分离 extent）
  → 压缩无效：存储原始数据（compress_type=BTRFS_COMPRESS_NONE）

读取：btrfs_readpage() → check_extent_item()
  → 如果 extent 标记为压缩 → decompress_bio()
  → 否则直接返回 page
```

---

## 8. tree_mod_log — 写入前日志

Btrfs 在 COW 机制之外还实现了 `tree_mod_log`，用于在原子操作前回滚关键修改：

```c
// fs/btrfs/ctree.c
// 在修改节点前记录操作日志（用于 CRS（Concurrent Raid Scanner）场景）

btrfs_tree_mod_log_insert_root(root->node, cow, true);    // 根替换
btrfs_tree_mod_log_insert_key(parent, slot, BTRFS_MOD_LOG_KEY_REPLACE); // 键替换
btrfs_tree_mod_log_free_eb(buf);                           // 块释放
btrfs_tree_mod_log_eb_copy(dst, src, ...);                // 块复制
```

这些日志在事务提交时被清除（如果事务成功）。如果系统崩溃，可以从 tree_mod_log 恢复未完成的操作。

---

## 9. extent_io — 块设备 I/O 抽象

`extent_io.c` 实现了 Btrfs 的块设备 I/O 抽象层：

```c
// fs/btrfs/extent_io.c
struct btrfs_bio_ctrl {
    u64 start;              /* 逻辑地址 */
    u64 len;                /* 长度 */
    blk_opf_t opf;          /* REQ_OP_READ / WRITE */
    struct bio *bio;        /* 底层 bio */
    struct btrfs_device *devices[BTRFS_MAX_MIRRORS];
    int mirror_num;
    compress_type;
    // ...
};
```

extent_io 负责：
1. **合并相邻的 I/O 请求**（减少 bio 数量）
2. **校验和计算和验证**（`btrfs_csum_one_bio`）
3. **镜像选择和重试**（`find_live_mirror`）
4. **压缩 I/O 集成**

---

## 10. 总结：Btrfs 的设计哲学

```
CoW B 树 = 原子性 + 快照内建
extent tree = 统一的空间管理
chunk map = RAID 在文件系统层
校验和 = 静默损坏检测
tree_mod_log = 崩溃恢复保证
```

**与其他文件系统的关键区别**：

| | ext4 | XFS | Btrfs |
|--|------|-----|-------|
| 元数据架构 | 块组+位图 | AG+B+树 | 全局 COW B 树 |
| 数据一致性 | JBD2 日志 | CIL 延迟日志 | COW + generation |
| 快照 | 需要 LVM | 需要 LVM | 内建（零成本共享）|
| RAID | 需要 mdadm | 需要 mdadm | 文件系统内建（chunk map）|
| 校验和 | 无 | 无 | 全数据+元数据 CRC32C |
| 压缩 | 无 | 无 | zlib/zstd/lzo |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*