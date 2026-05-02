# btrfs 文件系统深度分析

## 1. 核心数据结构：B-tree、extent tree 与 path

### 1.1 B-tree 基本结构

btrfs 的元数据全部存储在 B-tree 结构中。与传统文件系统（如 ext4 的块位图）不同，btrfs 用统一的 B-tree 引擎管理所有元数据：文件 inode、目录项、extent 映射、chunk 分配信息、快照引用计数等，都以 key-item 对的形式存放在 B-tree 节点中。

```
struct btrfs_key {
    __u64 objectid;    // 对象 ID（inode 号、tree root ID 等）
    __u8  type;        // key 类型（BTRFS_EXTENT_ITEM_KEY = 168,
                       // BTRFS_CHUNK_ITEM_KEY = 228,
                       // BTRFS_ROOT_ITEM_KEY = 132 等）
    __u64 offset;      // 类型相关偏移（文件内字节 offset、
                       // extent 起始逻辑地址等）
}
```

每个 btrfs 有一个唯一的 **chunk tree**（objectid = `BTRFS_CHUNK_TREE_OBJECTID`），其中以 `BTRFS_CHUNK_ITEM_KEY` 存储所有 chunk 分配信息；`BTRFS_EXTENT_TREE_OBJECTID` 的 extent tree 存储已分配 extent 的引用计数；`BTRFS_FS_TREE_OBJECTID = 5` 的 fs tree 存储文件系统目录结构。

### 1.2 extent_buffer：节点的内存表示

B-tree 节点（node）和叶子（leaf）都是 `struct extent_buffer`，在内存中连续存放。在磁盘上，节点/叶子遵循 btrfs 的 node size（通常 16KB）。extent_buffer 是 btrfs 最核心的内存结构：

```c
struct extent_buffer {
    // 所有节点通用的 header
    char                    csum[32];
    char                    fsid[16];
    __le64                  bytenr;          // 磁盘起始字节
    __le64                  generation;      // 事务代
    __le64                  owner;           // root id（对于 fs tree）
    __le64                  flags;           // WRITTEN | RELOC | ...
    struct btrfs_header {
        char                csum[32];
        char                fsid[16];
        __le64              bytenr;
        __le64              flags;
        __le64              generation;
        __le64              owner;           // root id
        __le8               chunk_tree_uuid[16];
        __le8               level;          // 0 = leaf, 1~7 = node
    } header;
    // level == 0 (leaf): nritems 个 struct btrfs_item
    // level >  0 (node): nritems 个 child blockptr + key
    __le32                  nritems;         // 项数
    __le64                  flags;           // 额外 flags
    // ... data payload starts here
};
```

对于 **leaf**（`level == 0`），data 段由 `nritems` 个 `struct btrfs_item` 组成：

```c
struct btrfs_item {
    __le64 key;           // encoded key (objectid << 44 | type << 36 | offset)
    __le32 offset;        // 数据在 leaf data area 的字节偏移
    __le32 size;          // 数据长度（不含 item header 本身）
}
// 通过 offset + size 可找到下一个 item
// offset 从 leaf 末尾向前增长，size 从 leaf 开头向后增长
```

对于 **node**（`level > 0`），data 段由 `nritems` 个 child pointer 组成：

```c
struct btrfs_key_ptr {
    __le64 blockptr;      // child extent_buffer 的磁盘 bytenr
    __le64 generation;    // child 的 generation
    __le64 owner;         // child 的 root id
    // key 用于二分查找，决定应该往哪个 child 走
    // 与 child 首项的 key 相同
}
```

### 1.3 struct btrfs_path：遍历的核心

`struct btrfs_path` 记录从 root 到当前 leaf 的完整路径，是 btrfs 所有树操作的通用遍历句柄：

```c
struct btrfs_path {
    struct extent_buffer *nodes[BTRFS_MAX_LEVEL];  // 最多 8 层
    int slots[BTRFS_MAX_LEVEL];                     // 每层的 item 槽位
    u8 locks[BTRFS_MAX_LEVEL];                      // 锁级别（read/write）
    u8 reada;                                       // 预读策略
    u8 lowest_level;                               // 最低搜索层级
    bool keep_locks;
    bool skip_locking;       // 只读路径跳过锁
    bool search_commit_root; // 从 commit_root 而非 current root 搜索
    bool nowait;            // nowait 模式（不 blocking）
};
```

`btrfs_search_slot()` 是树的遍历入口，流程如下：

```
btrfs_search_slot(trans, root, key, path, ins_len, cow)
  │
  ├─ btrfs_search_slot_get_root(root, path) → root node (已加 write lock)
  │   path->nodes[level] = root node, path->slots[level] = -1
  │
  └─ while (b) {  // 自顶向下逐层遍历
        slot = btrfs_bin_search(b, 0, key);  // 二分搜索定位 child/leaf slot
        path->slots[level] = slot
        │
        ├─ [如果需要 COW]
        │   btrfs_cow_block() → 分配新 block，
        │       复制原 block 内容到新地址，
        │       更新父节点的 child pointer
        │
        ├─ [如果 slot 指向的 child 未在内存]
        │   read_block_for_search() → 从磁盘读取 child block
        │
        └─ level-- 推进到下一层
    }
  → 最终 leaf 中的 slot，即为 key 所在的 item
```

### 1.4 extent tree vs fs tree

btrfs 有多棵 B-tree，各司其职：

| Tree | objectid | 存储内容 |
|------|----------|---------|
| **extent tree** | `BTRFS_EXTENT_TREE_OBJECTID` (10) | extent 分配记录：`[bytenr, BTRFS_EXTENT_ITEM_KEY/METADATA_ITEM_KEY, refs/generation/flags]` |
| **fs tree** | `BTRFS_FS_TREE_OBJECTID` (5) | 文件/目录：`[inode#, BTRFS_INODE_ITEM_KEY, inode metadata]` / `[inode#, BTRFS_EXTENT_DATA_KEY, file data]` |
| **chunk tree** | `BTRFS_CHUNK_TREE_OBJECTID` (7) | chunk 分配映射：`[bytenr, BTRFS_CHUNK_ITEM_KEY, chunk结构含stripe信息]` |
| **root tree** | `BTRFS_ROOT_TREE_OBJECTID` (1) | 子卷/snapshot root 列表：`[root_id, BTRFS_ROOT_ITEM_KEY, root_item]` |

extent tree 和 fs tree 本质上都是 B-tree，但职责不同：extent tree 记录物理空间分配（哪个磁盘区间属于哪个 root），fs tree 记录逻辑文件结构（哪个 inode 占用了哪些逻辑偏移）。两者通过 extent 的 owner root 字段互相引用。

---

## 2. COW 机制

### 2.1 为什么需要 COW

btrfs 是一个 COW（Copy-on-Write）文件系统。当修改一个已存在的 block 时，**不会直接覆写原 block**，而是：
1. 分配一个新的磁盘 block
2. 把原始数据复制（copy）到新 block
3. 修改在新 block 上进行
4. 更新父节点的指针指向新 block
5. 旧 block 的引用计数 -1，如果变成 0 则释放

COW 使得 btrfs 可以轻松实现：
- **事务原子性**：通过generation递增，旧版本自然保留
- **快照零开销**：快照只复制 root node，新数据写入才真正复制
- **完整性保护**：写入失败时旧数据完好无损

### 2.2 btrfs_cow_block 完整路径

调用链（`fs/btrfs/ctree.c`）：

```
btrfs_search_slot(trans, root, key, path, ins_len, cow=1)
  │
  └─ at level L where path->nodes[L] needs modification:
     ret = btrfs_cow_block(trans, root, buf=path->nodes[L],
                           parent=path->nodes[L+1],
                           parent_slot=path->slots[L+1],
                           cow_ret=&child)

btrfs_cow_block() → 验证 transaction
  └→ should_cow_block() → 检查是否必须 COW（ROOT_SHAREABLE 等）
     └→ btrfs_force_cow_block()
           ├─ btrfs_alloc_tree_block()      ← 分配新 block（可能是新 chunk）
           │   └→ find_free_extent()         ← extent-tree.c 中找可用空间
           │       └→ btrfs_alloc_chunk()    ← 需要时创建新 chunk
           ├─ copy_extent_buffer_full(cow, buf)  ← 复制数据
           ├─ btrfs_set_header_generation(cow, trans->transid)
           ├─ update_ref_for_cow()           ← 旧 block 引用计数 -1
           │   └→ btrfs_inc_extent_ref() / btrfs_dec_extent_ref()
           ├─ if (root->node == buf)         ← 根节点替换
           │   rcu_assign_pointer(root->node, cow)  ← 原子替换 root 指针
           │   add_root_to_dirty_list()      ← 标记为脏，等待 writeback
           │   btrfs_free_tree_block()       ← 释放旧 block
           └─ else                            ← 非根节点
               btrfs_set_node_blockptr(parent, parent_slot, cow->start)
               btrfs_mark_buffer_dirty(parent)  ← 父节点标记脏
               btrfs_free_tree_block()       ← 旧 block 引用计数到 0 时释放
```

### 2.3 COW 完整写入路径 ASCII 图

```
应用层写入: write(fd, buf, 4096)
    │
    ▼
btrfs_writepage() [extent_io.c]
    │
    ▼
run_delalloc_cow()
    │  检查 extent 是否已分配
    │  若已分配 → COW path
    │
    ▼
btrfs_submit_data_bio()
    │
    ├─ btrfs_get_io_context() → 从 extent tree 查 extent_map
    │    映射 file_offset → [logical bytenr, num_bytes, chunk_map]
    │
    ▼
btrfs_map_block() [block-group.c]
    │  将 logical bytenr 映射到物理设备 stripe
    │  计算 stripe_nr, stripe_offset, num_stripes
    │  RAID1/RAID10: num_stripes = 2+
    │
    ▼
bioc->map_type 判断:
    │
    ├─ RAID56 ──→ raid56_parity_write() → 计算校验 stripe，同时写 data + parity
    │
    ├─ RAID1/RAID10 ──→ for each stripe:
    │       btrfs_submit_mirrored_bio(bioc, dev_nr)
    │           bio_clone_partial()
    │           bio->bi_end_io = btrfs_raid_bio_end_io
    │           submit_bio(dev_bio)
    │
    └─ SINGLE/DUP ──→ 单设备路径 btrfs_submit_dev_bio()
                          submit_bio(bio)
    │
    ▼ 各 stripe 并行写盘（镜像间无因果关系）
    │
    ▼
IO 完成回调:
    ├─ RAID1/RAID10: btrfs_raid_bio_end_io()
    │                    检查各镜像完整性，任一成功即成功
    ├─ RAID56: raid56_end_io()
    │               校验 parity
    └─ SINGLE: btrfs_simple_end_io()
                    更新 ordered_extent 状态
    │
    ▼
btrfs_writepage_end_io_hook()
    │  计算 csum，附加到 ordered_extent
    │
    ▼
btrfs_finish_ordered_io()
    │  将 csum 批量写入 csum tree
    │  更新 extent tree（如果新分配了 extent）
    │
    ▼
事务提交 (btrfs_commit_transaction):
    │  将 extent tree、fs tree 的脏节点刷盘
    │  生成新的 super block（不是覆写，而是追加）
    │
    ▼
新 generation 写入完毕
```

### 2.4 update_ref_for_cow：引用计数更新

`update_ref_for_cow()` 在 COW 过程中更新 extent tree：

```c
update_ref_for_cow(trans, root, buf, cow, last_ref)
    ├─ 旧 block buf 的 extent_item 在 extent tree 中的 refs--
    │   btrfs_lookup_extent_item() 找到 extent_item
    │   btrfs_set_extent_refs() refs - 1
    │   如果 refs == 0 && !(flags & SHARED):
    │       *last_ref = 1   ← 标记"可以释放"
    │       从 extent tree 删除 extent_item（释放磁盘空间）
    │       （或保留以备快照引用）
    └─ 新 block cow 的 extent_item:
        btrfs_insert_extent_item()
        refs = 1 (或快照继承)
        flags = TREE_BLOCK | FULL_BACKREF
        generation = trans->transid
```

---

## 3. Chunk 与 extent 映射

### 3.1 Chunk 分配架构

btrfs 把物理磁盘空间组织成 **chunk**（条带化单元），每个 chunk 有固定大小（通常 1GB），由 `struct btrfs_chunk` 描述，存储在 chunk tree 中：

```c
struct btrfs_chunk {
    __le64 length;           // chunk 大小（字节）
    __le64 owner;            // 引用此 chunk 的 root id
    __le64 stripe_len;       // stripe 长度（通常 64KB）
    __le64 type;             // BLOCK_GROUP_* flags (DATA/METADATA/SYSTEM
                             //   | RAID0 | RAID1 | RAID10 | DUP | RAID56)
    __le32 io_align;         // IO 对齐要求
    __le32 io_width;         // IO 宽度
    __le32 sector_size;      // 扇区大小
    __le16 num_stripes;      // stripe 总数
    __le16 sub_stripes;      // raid10 子条带数
    struct btrfs_stripe stripe;  // 第一个 stripe
    // struct btrfs_stripe stripe[N] 后续 stripe 紧随其后
};

struct btrfs_stripe {
    __le64 devid;             // 设备 ID
    __le64 offset;            // 该 stripe 在设备上的物理偏移
    __u8   dev_uuid[16];      // 设备 UUID
};
```

block group 是 chunk 的逻辑容器，一个 block group 对应一个 chunk，包含多个 chunk 条带。block group 用 flags 表示类型：`BTRFS_BLOCK_GROUP_DATA`、`BTRFS_BLOCK_GROUP_METADATA`、`BTRFS_BLOCK_GROUP_SYSTEM`。

### 3.2 btrfs_alloc_chunk 路径

`btrfs_alloc_tree_block()` 分配新的 tree block 时，底层调用 `find_free_extent()`：

```
btrfs_alloc_tree_block(trans, root, parent_start, root_id, disk_key,
                       level, search_start, empty_size, ...)
  │
  └─ find_free_extent(root, ...)
        │
        ├─ 遍历 space_info 中的 block_group 链表
        │   跳过 flags 不匹配的 block_group（如请求 METADATA 但遍历到 DATA）
        ├─ 尝试 clustered 分配（查找相邻空闲区域）
        │   失败则尝试 unclustered 分配
        │   分配 -> 更新 block_group 的 bitmap
        └─ 若所有现有 block_group 都无法满足
            btrfs_alloc_chunk() → 分配全新 chunk
              ├─ btrfs_reserve_chunk() → 创建新 block_group
              ├─ 在 chunk tree 中插入 BTRFS_CHUNK_ITEM_KEY
              │   (key.objectid = 新 chunk 的逻辑起始地址)
              │   (key.offset = 0)
              │   chunk 结构写入 leaf
              └─ 将新 chunk 加入 space_info 缓存
```

chunk item 的 key 很特殊：`objectid = 逻辑地址 bytenr，type = BTRFS_CHUNK_ITEM_KEY，offset = 0`。这是 extent tree 的索引方式——通过 `BTRFS_CHUNK_ITEM_KEY` 类型的 key 可以二分查找任意逻辑地址属于哪个 chunk。

### 3.3 逻辑地址到物理设备的映射

从 logical bytenr 到物理设备的路径：

```
btrfs_map_block(fs_info, op, logical_bytenr, &map, ...)
    │
    ├─ btrfs_get_block_group_cache_info()
    │   从 rb_tree 中查找覆盖该地址的 block_group
    │
    ├─ btrfs_get_chunk_map()
    │   在 block_group->chunk_map_tree 中
    │   查找 [logical, logical + len) 对应的 btrfs_chunk_map
    │
    └─ 计算 stripe 映射:
        stripe_nr  = (logical - chunk_start) / stripe_len
        stripe_idx = stripe_nr % num_stripes   (RAID0)
                     stripe_nr * (num_stripes / sub_stripes) + i  (RAID10)
                     全部 stripe (RAID1/DUP)
        for RAID1: all num_stripes 都需要写
        for RAID10: num_stripes / sub_stripes 个方向各写一份
        physical = stripe[stripe_idx].offset + stripe_offset
```

---

## 4. RAID1/RAID10 冗余

### 4.1 冗余层面：RAID vs btrfs 层

btrfs 的镜像冗余**在块设备层面之上、文件系统层面之内实现**，独立于底层 RAID 卡（或 JBOD）的工作模式。写入时 btrfs 同时向多个设备提交 IO，读取时从主设备读取并验证 checksum。

RAID1 在 btrfs 内部通过 `bioc->map_type & BTRFS_BLOCK_GROUP_RAID1` 判断；`BTRFS_BLOCK_GROUP_RAID10` 通过 `num_stripes` 和 `sub_stripes` 的配合实现。

### 4.2 write 路径的镜像写入

`btrfs_submit_bio()` 是所有写入的汇聚点（`fs/btrfs/bio.c:568`）：

```c
static void btrfs_submit_bio(struct bio *bio, struct btrfs_io_context *bioc,
                             struct btrfs_io_stripe *smap, int mirror_num)
{
    if (!bioc) {
        // 单设备路径（无冗余）
        bio->bi_private = smap->dev;
        bio->bi_end_io = btrfs_simple_end_io;
        btrfs_submit_dev_bio(smap->dev, bio);
    } else if (bioc->map_type & BTRFS_BLOCK_GROUP_RAID56_MASK) {
        // RAID5/6：计算校验，写 data + parity
        bio->bi_end_io = btrfs_raid56_end_io;
        if (bio_op(bio) == REQ_OP_READ)
            raid56_parity_recover(bio, bioc, mirror_num);
        else
            raid56_parity_write(bio, bioc);
    } else {
        // RAID1/RAID10/DUP：向所有镜像并发写
        int total_devs = bioc->num_stripes;
        bioc->orig_bio = bio;  // 保存原始 bio 引用
        for (int dev_nr = 0; dev_nr < total_devs; dev_nr++)
            btrfs_submit_mirrored_bio(bioc, dev_nr);
            // → bio_clone_partial() 克隆 bio
            // → 设置目标设备 dev
            // → 调整 bi_iter.bi_sector = physical >> SECTOR_SHIFT
            // → btrfs_submit_dev_bio()
            // 镜像之间完全独立并行，无阻塞等待
    }
}
```

### 4.3 mirror_num 与读取恢复

`mirror_num` 参数控制读取时的镜像选择：
- `mirror_num == 0`：使用默认 primary stripe
- `mirror_num > 0`：读取备用镜像（用于 scrub 或读取失败后重试）

`btrfs_num_copies()` 返回给定逻辑地址需要多少份镜像才能容忍 N-1 块盘故障。RAID1 返回 2 份，RAID10 按配置返回 2 或更多。

### 4.4 scrub 对镜像的校验

scrub 在 `fs/btrfs/scrub.c` 中以 `struct scrub_stripe` 为单位（对应一个条带化单元）进行校验：

```
scrub_setup_wr_ctx() → 为每个数据 stripe 分配 scrub_stripe
    │
    ├─ scrub_verify_one_sector()   // 逐扇区验证数据
    │   读取该扇区的 csum
    │   从一个设备读取数据，计算 csum，与存储的 csum 比对
    │   若不匹配 → 进入 bad mirrors 检测
    │
    ├─ scrub_verify_one_metadata() // 校验元数据
    │   btrfs_csum_tree_block() 计算块级 csum
    │   比对 super block 中记录的 chunk tree root csum
    │
    └─ 若检测到 bad sector:
        读取其他镜像（从不同设备读取同一 logical）
        用好的数据修复坏设备
        btrfs_scrub_recheck() 重新计算并写入正确数据
```

scrub 的核心原则：**至少一个镜像成功即认为数据完整**。修复时对每个失败的扇区，从剩余健康镜像重建并写回。

---

## 5. 快照与子卷

### 5.1 快照的本质

btrfs 的快照是一个 **新的 BTRFS_ROOT_ITEM**，挂在同一个 fs tree（或者从 reloc tree）的不同 subvolume root 下。快照本身**不复制任何数据块**——它只复制原始 fs tree 的 root node，然后 COW 机制在后续写入时按需复制。

快照的创建路径（`fs/btrfs/ioctl.c:704 create_snapshot()`）：

```
create_snapshot(root, dir, dentry, readonly, inherit)
    │
    ├─ btrfs_subvolume_reserve_metadata() → 预留事务空间
    │
    ├─ btrfs_start_transaction(root, 0) → 开启事务
    │
    ├─ pending_snapshot->root = root  ← 源子卷
    │   pending_snapshot->readonly = readonly
    │
    └─ 事务提交时 (btrfs_commit_transaction):
        btrfs_create_snapshot()
            ├─ btrfs_copy_root(trans, root, &snap_root_item)
            │   // 复制 root node extent_buffer
            │   // 生成新的 snap_root_item（有不同的 root_id）
            │   // 所有 tree block 的 owner 指向新 root_id
            │   // 但实际 block 数据并未复制（COW 延迟到写入）
            │
            ├─ 在 root tree 中插入 [snap_root_id, ROOT_ITEM_KEY, ...]
            │   指向新的 root node bytenr
            │
            ├─ 在父目录中创建 .snaps 目录项
            │
            └─ 设置 root_item.flags |= READONLY（如果是只读快照）
```

**关键**：快照创建时只复制 root node，因此极其快速（毫秒级）。原 fs tree 和快照共享所有未修改的 tree block，通过引用计数管理。

### 5.2 COW 对快照的影响

当快照创建后原 subvolume 有数据写入时：

```
原 subvolume 的 fs tree 有 leaf 被修改
    │
    ├─ btrfs_search_slot() 在该 leaf 上找到需要修改的 item
    │   path->nodes[0] = leaf, path->slots[0] = item_slot
    │
    └─ btrfs_cow_block() 被调用
          ├─ btrfs_alloc_tree_block() → 分配新 leaf (new_leaf)
          ├─ copy_extent_buffer_full(new_leaf, old_leaf)
          ├─ 修改 new_leaf 中的数据
          ├─ 更新父节点的 blockptr: old_leaf → new_leaf
          └─ old_leaf 的 refs--，但快照仍持有对 old_leaf 的引用
              → old_leaf refs > 0，不会被释放
              → old_leaf 保持在磁盘上，快照仍可访问历史数据
```

这就是 btrfs 快照"时间旅行"能力的本质：每次 COW，旧版本 block 通过引用计数得以保留，快照可见。写入越频繁，产生的新 block 越多，历史版本越多。

### 5.3 子卷 vs 快照

- **子卷（subvolume）**：一个独立的 fs tree 根，拥有自己的 `root_item`。可作为独立挂载点。
- **快照（snapshot）**：子卷的只读或读写副本。快照创建时复制 root node，创建后与原子卷共享所有未修改 block。

本质区别：**快照 = 带时间戳的子卷根引用 + READONLY 标记**。创建后如果原 subvolume 继续写入，快照保持只读，历史数据通过 COW 的旧 block 保留。

---

## 6. 压缩机制

### 6.1 压缩架构

btrfs 支持在线压缩（`zlib` 和 `zstd`），压缩发生在写入路径而非分配路径。文件 extent 的逻辑地址不变，物理磁盘上存放的是压缩后的数据。extent tree 中的 `BTRFS_EXTENT_DATA_KEY` 记录 extent 映射，压缩标志存储在 inode 的 `i_compress_algorithm` 字段中。

### 6.2 写入时的压缩路径

```
btrfs_writepage()
    │
    └─ submit_extent_page()
          │
          ├─ 尝试压缩: compress_file_range(inode, page_start, len)
          │     ├─ 读取页面未压缩数据
          │     ├─ 调用 btrfs_compress_workspace->compress_bio()
          │     │   (zlib_compress_bio 或 zstd_compress_bio)
          │     ├─ 如果压缩后大小 < 原始大小 → 使用压缩
          │     │   压缩后的数据 → compressed_bio
          │     └─ 否则放弃压缩，使用原始数据
          │
          ├─ 创建 compressed_bio:
          │     cb->compressed_pages[]  // 压缩后数据页
          │     cb->compressed_len       // 压缩后总长度
          │     cb->compress_type        // ZLIB / ZSTD
          │
          └─ btrfs_submit_compressed_bio()
                // compressed_bio 作为一个整体写入
                // 写入到 extent tree 的 extent_item 中：
                //   key = [inode#, EXTENT_DATA_KEY, file_offset]
                //   extent_item.flags |= EXTENT_FLAG_COMPRESS
                //   extent_item.compression = ZLIB | ZSTD
                //   extent_item.linear encoding = compressed_data
```

### 6.3 读取时的解压缩路径

```
btrfs_readpage()
    │
    ├─ btrfs_lookup_extent_map() → 查 extent_map
    │   extent_map->flags & EXTENT_COMPRESSED → 是压缩 extent
    │
    └─ btrfs_decompress_bio()
          ├─ 读取 compressed_bio（整个压缩 extent）
          │   读取 extent 在磁盘上的物理位置
          │   整块读入 compressed_pages[]
          │
          ├─ 调用 decompression workspace:
          │   zlib_decompress_bio() 或 zstd_decompress_bio()
          │   解压到原始大小的 buffer
          │
          └─ 返回解压缩后的原始页面给上层
```

### 6.4 zlib vs zstd 对比

| 特性 | zlib | zstd |
|------|------|------|
| 压缩比 | 中等（通常 2~4x） | 高（通常 3~6x） | 
| CPU 开销 | 中等 | 低（Facebook 开发的算法，ZSTD 能效比高） |
| 内存使用 | 低 | 可调（级别 1~19，级别越高内存越大） |
| 普及度 | 极高（标准 deflate） | 高（但稍逊于 zlib） |
| btrfs 挂载选项 | `compress=zlib` | `compress=zstd` |

### 6.5 compressed data extent 的 extent_item 结构

压缩 extent 在 extent tree 中的 item 比普通 data extent 复杂：

```
extent tree leaf 中的 extent_item:
  [bytenr, BTRFS_EXTENT_ITEM_KEY | BTRFS_METADATA_ITEM_KEY, refs/flags]
  ├─ 附加 inline extent_data_ref / shared_data_ref（inline 或通过 offset）
  │   描述该 extent 属于哪个 root、哪个 inode、哪个文件 offset
  │
  若为压缩 extent，还可能有：
  extent_inline_ref.type = BTRFS_EXTENT_INLINE_REF_DATA_COMPRESSED
  extent_inline_ref.offset = 压缩后长度
```

---

## 7. Scrub 与 Balance

### 7.1 Scrub：数据完整性校验

Scrub 的核心设计思路是**顺序读取全文件系统数据，计算 checksum 并与 extent tree 中记录的 checksum 比对**。

Scrub 单次任务的生命周期（`fs/btrfs/scrub.c`）：

```
btrfs_scrub_dev(fs_info, devid, readonly, progress)
    │
    ├─ scrub_supers() → 读取 3 份 super block 验证一致性
    │
    ├─ scrub_chunks() → 遍历该设备管理的所有 chunk
    │   └→ scrub_stripe() → scrub 一个完整的条带单元
    │       ├─ 分配 scrub_stripe 结构（最多 3 份冗余）
    │       │   scrub_stripe 包含 N 个 scrub_page（N = 设备上的 chunk 大小 / 扇区大小）
    │       │
    │       ├─ scrub_page_init() → 为每个扇区分配内存页
    │       │
    │       ├─ scrub_page_check() 逐扇区:
    │       │   ├─ read from device (一个完整条带读取)
    │       │   ├─ 从 csum tree 查找该扇区的预期 csum
    │       │   ├─ btrfs_csum_calc() 计算读到的数据的 csum
    │       │   └─ 比对 expected_csum vs computed_csum
    │       │       match → good sector
    │       │       mismatch → 数据损坏
    │       │
    │       ├─ scrub_handle_errored_sector():
    │       │   // 数据损坏时的恢复逻辑
    │       │   ├─ 从其他镜像重建（RAID1/RAID10）
    │       │   │   btrfs_map_block() → 获取该 logical 的其他 stripe
    │       │   │   从其他设备读取相同 logical
    │       │   │   写入当前设备（修复）
    │       │   │
    │       │   └─ 如果没有冗余（single）：
    │       │       记录损坏扇区，等待管理员处理
    │       │       将损坏扇区标记到 bad device map
    │
    └─ scrub_stat_update() → 更新 /sys/fs/btrfs/.../scrub/
```

Scrub 的关键约束：
- **读取优先级**：Scrub 在磁盘 IO 空闲时进行（受 `scrub_speed_max` 限制）
- **raid56 特殊处理**：RAID56 需要读取所有 data stripe + parity 才能验证单扇区，scrub 会进行完整性重建尝试
- **元数据校验**：`scrub_verify_one_metadata()` 计算 tree block 的 checksum，对比 chunk tree 中的记录

### 7.2 Balance：数据重分布

Balance 的目的是将数据从已满/过旧的 block group 移动到新分配的 block group，将 chunk 重新条带化，以恢复冗余配置或利用新设备。

Balance 的主要操作（通过 `btrfs_balance` ioctl 触发）：

```
btrfs_balance(fs_info, filter)
    │
    ├─ btrfs_balance_data() → 重平衡 data chunk
    │   遍历 DATA block_group
    │   如果 block_group 已满或碎片化程度高
    │       btrfs_reloc_chunk() → 将 chunk 中的所有 extent 迁移到新 chunk
    │           ├─ 在 reloc tree 中建立原 chunk 的镜像
    │           ├─ 遍历原 chunk 的每个 extent
    │           │   btrfs_search_extent_item() → 找到 extent_item
    │           │   btrfs_alloc_extent() → 在新 chunk 中分配空间
    │           │   btrfs_dec_extent_ref() / btrfs_inc_extent_ref() → 更新引用
    │           │   copy_extent_buffer() → 复制数据
    │           └─ 更新 extent_item 中的 bytenr
    │       原 block_group 被标记为空闲，后续可被回收
    │
    ├─ btrfs_balance_metadata() → 重平衡 metadata chunk
    │
    └─ btrfs_shrink_device() → 设备缩小时的 chunk 迁移
```

Balance 是危险操作（会大量 COW 并重新分配），生产环境中建议在低负载时执行，并密切监控 `btrfs balance status` 输出。

---

## 8. 关键代码路径速查

| 功能 | 入口函数 | 主要文件 |
|------|----------|---------|
| 树搜索/遍历 | `btrfs_search_slot()` | `ctree.c:2001` |
| COW block | `btrfs_cow_block()` → `btrfs_force_cow_block()` | `ctree.c:651, 465` |
| block 分配 | `btrfs_alloc_tree_block()` → `find_free_extent()` | `extent-tree.c` |
| chunk 分配 | `btrfs_alloc_chunk()` | `extent-tree.c` |
| 数据写入 | `btrfs_submit_data_bio()` → `btrfs_submit_bio()` | `bio.c:568` |
| RAID1/RAID10 镜像写 | `btrfs_submit_mirrored_bio()` | `bio.c` |
| RAID56 校验写 | `raid56_parity_write()` | `raid56.c` |
| RAID56 校验读 | `raid56_parity_recover()` | `raid56.c` |
| 快照创建 | `create_snapshot()` | `ioctl.c:704` |
| 压缩写入 | `compress_file_range()` | `compression.c` |
| 解压读取 | `btrfs_decompress_bio()` | `compression.c:89` |
| Scrub 校验 | `scrub_stripe()` | `scrub.c` |
| Balance 迁移 | `btrfs_reloc_chunk()` | `block-group.c` |
| extent 查找 | `btrfs_lookup_extent_item()` | `extent-tree.c` |
| 引用计数更新 | `update_ref_for_cow()` | `ctree.c:349` |

---

## 9. 总结：btrfs 设计哲学

btrfs 将所有元数据统一到 B-tree 引擎上，用 COW 作为一致性的核心保障，用 extent tree 追踪物理分配、用 fs tree 组织文件逻辑——两者通过 root_id 互相引用。Chunk tree 管理磁盘的物理条带化，block group 负责空间分类，raid 层在块设备层面之上实现冗余而不依赖硬件 RAID。

整个系统的设计可以归纳为几个关键原则：

1. **COW 优先**：任何修改都产生新版本，旧版本通过引用计数保留，天然支持快照和事务回滚
2. **校验和无处不在**：每个 data/metadata block 都有 csum，scrub 可以发现并修复静默数据损坏
3. **元数据与数据同权**：元数据和数据都存储在 B-tree 中，都支持压缩和冗余
4. **设备抽象**：btrfs 把多设备视为统一存储池，chunk 分配和 raid 映射都在文件系统内部完成

btrfs 的复杂之处在于多层 B-tree 的互相引用和 cross-reference，以及 COW 路径上事务、锁、引用计数、quota 的协调。但其核心设计原则始终清晰：**所有修改都产生新版本，所有旧版本通过引用计数保留，无覆盖，无in-place更新。**