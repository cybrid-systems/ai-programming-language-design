# btrfs 文件系统深度分析

**内核版本**: Linux 7.0-rc1  
**源码路径**: `/home/dev/code/linux/fs/btrfs/`  
**核心文件**: `ctree.c`, `extent_io.c`, `extent-tree.c`, `block-group.c`, `volumes.c`, `raid56.c`, `scrub.c`, `compression.c`

---

## 一、Extent Tree 与 B-tree：btrfs 核心结构

### 1.1 多棵树共存

btrfs 不是一棵单一的树，而是由多棵 B-tree 组成，每棵树职责分明：

| 树名 | objectid (root_key.objectid) | 职责 |
|------|------------------------------|------|
| **Tree Root** (`BTRFS_ROOT_TREE_OBJECTID = 1`) | 1 | 管理所有根节点，记录所有 subvolume/snapshot root |
| **Extent Root** (`BTRFS_EXTENT_TREE_OBJECTID = 2`) | 2 | 管理所有 extent 分配，记录 block → extent 映射 |
| **Fs Tree** (`BTRFS_FS_TREE_OBJECTID = 5`) | 5 | 真实文件系统树，存文件/目录 inode |
| **Chunk Root** (`BTRFS_CHUNK_TREE_OBJECTID = 7`) | 7 | 管理 chunk 和设备信息 |
| **Dev Root** (`BTRFS_DEV_TREE_OBJECTID = 8`) | 8 | 管理设备 extent |
| **Csum Root** | 9 | 校验和树 |
| **Reloc Root** | -10 (TREE_RELOC_OBJECTID) | 快照/平衡时用的迁移树 |

```
Super Block
    ├── tree_root  (rootid=1)   → 管理所有根
    │       └── [subvolume root entries]
    ├── extent_root (rootid=2) → 管理 extent 分配
    │       └── extent items: (bytenr, size) → {refs, flags, extent_inline_ref*}
    ├── fs_root   (rootid=5)   → 真实文件树
    │       └── INODE_ITEM / INODE_REF / DIR_ITEM / EXTENT_DATA ...
    └── chunk_root (rootid=7)  → 管理 chunk 条目
            └── chunk items: stripe 分布信息
```

### 1.2 Extent Tree vs Fs Tree

**Extent Tree**（`BTRFS_EXTENT_TREE_OBJECTID = 2`）的核心职责是追踪"哪些磁盘空间已被分配"。

在 extent tree 中，每个 key 的格式为：

```
key.objectid = extent 的起始 bytenr
key.type     = BTRFS_EXTENT_ITEM_KEY (= 168)
key.offset   = extent 的长度
```

对应的 `struct btrfs_extent_item`（定义在 `btrfs_tree.h:792`）包含：

```c
struct btrfs_extent_item {
    __u64 refs;        // 引用计数（多少个 owner 引用此 extent）
    __u64 generation;   // 创建时的事务 generation
    __u64 flags;       // BTRFS_EXTENT_FLAG_TREE_BLOCK | DATA | FULL_BACKREF 等
    // 后面跟着 extent_inline_ref（如果 inline 不下）
};
```

extent tree 中的 inline ref 类型（`btrfs_tree.h:845`）记录了这个 extent 被谁引用：

- `BTRFS_TREE_BLOCK_REF_KEY (176)`: 引用者是另一个 tree block（子树的根节点）
- `BTRFS_EXTENT_DATA_REF_KEY (178)`: 引用者是一个文件中的数据 extent
- `BTRFS_SHARED_BLOCK_REF_KEY (179)`: 被多个 tree block 共享（通过 `FULL_BACKREF` flag）

**Fs Tree**（`BTRFS_FS_TREE_OBJECTID = 5`）存储文件的实际内容布局：

```
key.objectid = inode 号
key.type     = BTRFS_EXTENT_DATA_KEY (= 108)
key.offset   = 文件内的逻辑偏移
```

对应 `struct btrfs_file_extent_item`，记录了数据在磁盘上的物理位置或压缩信息。

**本质区别**：

- **Extent Tree** 是"空间分配账本"，回答"磁盘上这块空间归谁用"
- **Fs Tree** 是"文件系统视图"，回答"这个文件的数据存在哪"

### 1.3 struct btrfs_path 工作方式

`btrfs_search_slot()` 是所有树操作的入口（`ctree.c:2001`）：

```c
int btrfs_search_slot(struct btrfs_trans_handle *trans,
                      struct btrfs_root *root,
                      const struct btrfs_key *key,
                      struct btrfs_path *p,
                      int ins_len, int cow)
```

`struct btrfs_path`（`ctree.h:57`）维护搜索路径：

```c
struct btrfs_path {
    struct extent_buffer *nodes[BTRFS_MAX_LEVEL]; // 每层节点
    int slots[BTRFS_MAX_LEVEL];                    // 每层的槽位
    u8 locks[BTRFS_MAX_LEVEL];                     // 锁级别
    u8 lowest_level;                               // 最低起始层
    // ... 搜索控制 flags
};
```

搜索过程：
1. `btrfs_search_slot_get_root()` 获取根节点（`ctree.c:1703`）
2. 自顶向下遍历各层，对每个节点执行 `btrfs_bin_search()` 二分查找
3. `btrfs_header_level() == 0` 时到达 leaf 层
4. 记录每层的 `nodes[]` 和 `slots[]`，供后续插入/删除使用

### 1.4 Leaf / Node 结构

extent buffer 是 btrfs 在内存中的树节点抽象（`extent_io.h:86`）：

```c
struct extent_buffer {
    u64 start;          // 块起始地址
    u32 len;            // 块长度（通常 = nodesize，4K~64K）
    void *addr;         // 映射到内存的地址
    refcount_t refs;    // 引用计数
    struct rw_semaphore lock; // 读写锁
    struct folio *folios[];   // 数据页面
};
```

**Leaf（level = 0）** 结构（`btrfs_tree.h` 中 `btrfs_leaf`）：
```
struct btrfs_leaf {
    struct btrfs_header {        // 固定头
        u64 bytenr;
        u64 generation;
        u64 owner;              // root id
        u32 nritems;            // item 数量
        u64 flags;
        u8 level;               // = 0
    } header;
    struct btrfs_item[] items;  // 可变长数组
    // 数据区：item[0]的数据, item[1]的数据, ...
};
```

**Node（level > 0）** 结构：
```
struct btrfs_node {
    struct btrfs_header { ... } header;
    struct btrfs_key_ptr[] ptrs; // 子节点指针数组
};
```

`btrfs_item` 包含 `offset`（数据在 leaf 中的偏移）和 `size`（数据长度）。这种 **items 和数据分离** 的设计使得 leaf 可以动态增长/收缩。

关键访问函数在 `accessors.h` 中定义：
- `btrfs_item_nr()`: 获取第 N 个 item
- `btrfs_item_key()`: 获取 item 的 key
- `btrfs_item_data_end()`: item 数据结束位置
- `btrfs_node_blockptr()`: 获取 node 中第 N 个子块指针

---

## 二、COW 机制：Copy-on-Write 深度解析

### 2.1 COW 的触发路径

btrfs 的 COW 路径入口是 `btrfs_cow_block()`（`ctree.c:651`）：

```c
int btrfs_cow_block(struct btrfs_trans_handle *trans,
                    struct btrfs_root *root,
                    struct extent_buffer *buf,
                    struct extent_buffer *parent, int parent_slot,
                    struct extent_buffer **cow_ret,
                    enum btrfs_lock_nesting nest)
```

触发条件（`should_cow_block()` at `ctree.c:606`）：
1. `BTRFS_ROOT_FORCE_COW` flag 被设置
2. 对 leaf 中的 item 做写入操作（`ins_len != 0`）
3. 对 tree block 做修改且不在当前 transaction 的 commit root 中

### 2.2 COW 实际执行：btrfs_force_cow_block

`btrfs_force_cow_block()`（`ctree.c:465`）是真正的 COW 执行者：

```c
cow = btrfs_alloc_tree_block(trans, root, parent_start,
                              btrfs_root_id(root), &disk_key, level,
                              search_start, empty_size, reloc_src_root, nest);
// ↑ 分配一个新块

copy_extent_buffer_full(cow, buf);  // 复制原块内容到新块
btrfs_set_header_generation(cow, trans->transid); // 写入新 generation

// 更新父节点指针，指向新块
if (parent)
    btrfs_set_node_blockptr(parent, parent_slot, cow->start);
```

关键点：**父节点的更新也在同一个 transaction 内**，这是保证原子性的基础。

### 2.3 分配新块：btrfs_alloc_tree_block

`btrfs_alloc_tree_block()`（在 `extent-tree.c` 中）负责分配新块：
1. 调用 `btrfs_find_free_extent()` 在 extent tree 中找可用空间
2. 在 block group 中寻找合适的物理位置
3. 更新 extent tree（`BTRFS_EXTENT_ITEM_KEY`）记录新分配

### 2.4 旧块的释放：引用计数递减

旧块不会立即释放，而是通过 **延迟引用**（delayed ref）机制处理：

```c
// delayed-ref.c 中的队列机制
struct btrfs_delayed_ref_node {
    u64 bytenr;
    u64 num_bytes;
    refcount_t refs;
    // ...
};
```

当 `btrfs_inc_ref()` / `btrfs_dec_ref()` 被调用时，修改不会立即反映到 extent tree，而是先进入 delayed ref 队列。在 transaction commit 时，`__btrfs_run_delayed_refs()` 批量处理这些引用计数变更。

**旧 block 的实际释放时机**：当 `refs` 计数归零时，在 transaction commit 过程中通过 `__btrfs_free_extent()` 归还到 free space cache。

---

## 三、Chunk 与 Extent：存储分配机制

### 3.1 Chunk 的概念

Chunk 是 btrfs 存储分配的**逻辑单位**，一个 chunk 有以下属性：

```
起始地址（chunk_root 中的 key.objectid）
长度（通常 256MB~1GB）
类型（DATA | METADATA | SYSTEM）
profile（ SINGLE | DUP | RAID1 | RAID10 | RAID56 等）
stripe 信息（设备号 + 物理偏移）
```

Chunk 条目存储在 **Chunk Root** 中，格式为 `struct btrfs_chunk`（`volumes.c`）：

```c
struct btrfs_chunk {
    __u64 length;          // chunk 长度
    __u64 owner;           // = BTRFS Chunk tree objectid
    __u64 stripe_len;      // stripe 长度（通常 64K）
    __u64 type;            // DATA/METADATA/SYSTEM flags
    __u16 num_stripes;     // stripe 数量
    __u16 sub_stripes;     // RAID10 子条带数
    __u32 io_align;         // IO 对齐
    __u32 io_width;        // IO 宽度
    __u32 sector_size;     // 扇区大小
    struct btrfs_stripe[] stripes; // 各 stripe 设备/偏移
};
```

### 3.2 btrfs_alloc_chunk 分配流程

`btrfs_create_chunk()`（`volumes.c:6044`）的完整分配流程：

```
1. init_alloc_chunk_ctl()
   - 根据 raid profile 初始化 ctl 参数
   - 确定 devs_max, devs_min, ncopies, nparity 等

2. gather_device_info()
   - 遍历所有读写设备，收集可用空间信息
   - 对每个设备调用 find_free_dev_extent() 找孔洞

3. decide_stripe_size()
   - 计算 chunk 大小（受 max_chunk_size 限制）
   - 确定 num_stripes 和 stripe_len

4. create_chunk() → 分配设备 extent
   - 对每个 stripe 设备调用 find_free_dev_extent()
   - 更新 dev_tree（记录设备 extent）
   - 创建 block_group 结构体

5. btrfs_chunk_alloc_add_chunk_item()
   - 在 chunk_root 中插入 chunk item（BTRFS_CHUNK_ITEM_KEY）
   - 更新 super block 中的 sys_chunk_array
```

Block Group 是 chunk 的内存抽象，通过 `btrfs_get_chunk_map()` 可以从 chunk 起始地址获取其 stripe 映射。

### 3.3 Extent Tree 记录已分配 Extent

当分配一个新的 data extent 时（`extent-tree.c`）：

```c
// btrfs_inode.c 中的 extent 分配
ins.objectid = start;    // 逻辑地址
ins.type = BTRFS_EXTENT_ITEM_KEY;
ins.offset = num_bytes;  // 长度

// 在 extent_root 中插入 item
btrfs_insert_empty_item(trans, extent_root, path, &ins, ...);

// 插入 inline ref 说明谁拥有这个 extent
// type = BTRFS_EXTENT_DATA_REF_KEY 或 TREE_BLOCK_REF_KEY
add_extent_mapping(extent_root, &ins, &extent_ref);
```

读取文件数据时，通过 `btrfs_lookup_data_extent()` 在 extent tree 中查找对应的 extent item。

---

## 四、RAID1 / RAID10：镜像层面

### 4.1 btrfs RAID 的实现层级

**重要**：btrfs 的 RAID 镜像**发生在块设备分配层面**，不是文件系统逻辑层面。

```
应用写入文件数据
    ↓
btrfs 根据 extent 位置，确定 block_group 的 profile
    ↓
block_group 为 RAID1/RAID10 时
    ↓
在 btrfs_get_chunk_map() 获取 stripe 映射
    ↓
bio 会被拆分，镜像写入所有 stripe 设备
```

### 4.2 RAID1 实现

`struct btrfs_raid_array`（`volumes.h:38`）定义了 RAID1 参数：

```c
[BTRFS_RAID_RAID1] = {
    .bg_flag    = BTRFS_BLOCK_GROUP_RAID1,
    .devs_max   = 2,
    .devs_min   = 2,
    .devs_increment = 1,
    .ncopies    = 2,         // 2 份拷贝
    .nparity    = 0,
    .mindev_error = BTRFS_ERROR_DEV_RAID10_MIN_NOT_MET,
}
```

当分配一个 RAID1 extent 时：
1. `decide_stripe_size()` 从多个设备各分配一个 stripe
2. `create_chunk()` 为每个 stripe 调用 `find_free_dev_extent()` 分别在不同设备上分配
3. 写入时，同一 bio 会被 **btrfs_rmw（Read-Modify-Write）** 处理（`raid56.c` 中 `rmw_rbio()`）

### 4.3 RAID10 实现

```c
[BTRFS_RAID_RAID10] = {
    .bg_flag    = BTRFS_BLOCK_GROUP_RAID10,
    .devs_max   = 0,       // 无限制
    .devs_min   = 4,
    .sub_stripes = 2,      // 每个"子条带"镜像对
    .ncopies    = 2,
}
```

RAID10 = 条带化（Stripe）+ 镜像。数据被分成 `num_stripes / sub_stripes` 个条带，每个条带内部做镜像。

### 4.4 RAID56（RMW 问题）

RAID5/6 的写入因为部分条带更新需要 Read-Modify-Write（`raid56.c:1439` 的 `rmw_assemble_write_bios`）：

```
读取整个 stripe（所有数据盘 + P/Q 盘）
计算新的 P/Q
写回数据盘 + P/Q
```

这就是 RAID56 的"写放大"问题根源。btrfs 在 `raid56.c` 中实现了 `raid56_parity_write()` 和 `raid56_parity_recover()` 来处理这些逻辑。

---

## 五、快照与子卷：COW 的应用

### 5.1 快照的本质

btrfs 的快照本质上是**对一个 subvolume root 的引用**。

`struct btrfs_root_item`（`ctree.h`）中的关键字段：
```c
struct btrfs_root_item {
    u64 bytenr;           // 根节点的物理地址
    u8 level;             // 根节点层级
    u64 generation;       // 创建时的 generation
    u64 root_dirid;       // 根目录的 inode id
    u32 refs;             // 引用计数（快照数量）
    u64 flags;
    // ...
};
```

快照创建（`ioctl.c:704` 的 `create_snapshot`）：
1. 分配一个新的 root item（`pending_snapshot->root_item`）
2. 复制原始 subvolume 的 root item，但 **bytenr 指向原始的 root node**
3. 写入 `BTRFS_ROOT_ITEM_KEY` 到 tree_root 中
4. 设置 `BTRFS_ROOT_SUBVOL_RDONLY` 为只读快照

### 5.2 COW 对快照的影响

当原始 subvolume 修改数据时：
1. 假设要修改 leaf L，COW 后得到新的 leaf L'
2. 原始 subvolume 的路径变为：`root → ... → L'`
3. 快照的路径仍然是：`root_snapshot → ... → L`（指向未修改的旧 leaf）

**快照和原始 subvolume 共享未修改的 tree block**，这就是 btrfs 快照"秒建"的秘密——不需要复制任何数据，只需要复制路径上的 tree node。

### 5.3 子卷（Subvolume）与 Shareable Root

`BTRFS_ROOT_SHAREABLE` flag（`ctree.h:92`）标识的 root 可以被快照：

```c
// ctree.c:531 在 btrfs_copy_root 中
if (test_bit(BTRFS_ROOT_SHAREABLE, &root->state)) {
    ret = btrfs_inc_ref(trans, root, cow, true);
} else {
    ret = btrfs_inc_ref(trans, root, cow, false);
}
```

只有设置了 `BTRFS_ROOT_SHAREABLE` 的 root 才会被 `btrfs_copy_root()` 增加引用计数。Fs Tree 和 Reloc Tree 是 shareable 的，而其他系统树不是。

### 5.4 Reloc Root（快照/平衡时的特殊处理）

`btrfs_copy_root()` 当 `new_root_objectid == BTRFS_TREE_RELOC_OBJECTID` 时会设置 `BTRFS_HEADER_FLAG_RELOC`，表示这是一个 reloc root。在快照创建和平衡过程中，btrfs 会创建 reloc root 来处理被移动的 tree block。

---

## 六、压缩：zlib vs zstd

### 6.1 压缩的启用方式

btrfs 支持三种压缩算法（`compression.c:39`）：
```c
static const char* const btrfs_compress_types[] = {
    "", "zlib", "lzo", "zstd"
};
```

### 6.2 Compressed Data Extent 的读取

文件 extent 的类型（`BTRFS_FILE_EXTENT_INLINE = 0` 或 `BTRFS_FILE_EXTENT_REG = 1`）决定了数据是否压缩。

`struct btrfs_file_extent_item`（`btrfs_tree.h`）中的压缩信息：

```c
__u8 type;                    // REG 或 INLINE
__u64 disk_bytenr;            // 压缩数据在磁盘上的起始位置
__u64 disk_num_bytes;         // 压缩后的大小
__u64 offset;                 // 在 extent 内的逻辑偏移
__u64 num_bytes;              // 解压后的大小
__u8 compression;             // 0=无压缩, zlib=1, lzo=2, zstd=3
```

**读取压缩 extent 的流程**（`compression.c`）：

```c
int compression_decompress_bio(struct list_head *ws,
                               struct compressed_bio *cb)
{
    switch (cb->compress_type) {
    case BTRFS_COMPRESS_ZLIB: return zlib_decompress_bio(ws, cb);
    case BTRFS_COMPRESS_LZO:  return lzo_decompress_bio(ws, cb);
    case BTRFS_COMPRESS_ZSTD: return zstd_decompress_bio(ws, cb);
    }
}
```

### 6.3 zlib vs zstd 对比

| 特性 | zlib | zstd |
|------|------|------|
| 压缩速度 | 较慢 | 快 3~5x |
| 解压速度 | 中等 | 快 |
| 压缩比 | 高 | 略低于 zlib |
| CPU 占用 | 高 | 低 |
| 内核实现 | 标准 zlib | libzstd |

zlib 是传统的 DEFLATE 算法（huffman + LZ77），zstd（Zstandard）是 Facebook 开源的新算法，提供了更好的速度/压缩比 trade-off。

### 6.4 压缩extent 的写入

当文件写入时（`delalloc` 机制），`btrfs_submit_compressed_write()` 会：
1. 收集未压缩的数据
2. 调用对应算法的压缩函数
3. 创建 compressed extent item
4. bio 写入压缩后的数据

读取时 `btrfs_submit_compressed_read()` 会解压后返回给上层。

---

## 七、Scrub 与 Balance

### 7.1 Scrub：错误检测机制

`btrfs_scrub_dev()`（`scrub.c:3072`）是 scrub 的入口：

```c
int btrfs_scrub_dev(struct btrfs_fs_info *fs_info, u64 devid, u64 start,
                    u64 end, struct btrfs_scrub_progress *progress,
                    bool readonly, bool is_dev_replace)
```

Scrub 的核心是 `scrub_recheck_block_csum()` 和 `scrub_repair_block()`：

```
1. 读取每个 extent 的数据
2. 计算 csum（从 csum_root 读取期望值）
3. 与实际读取数据的 csum 对比
4. 如果不匹配：
   - 如果有镜像（RAID1/RAID10），从其他副本读取修复
   - 否则记录错误（ECC / 媒体错误）
5. 写回修复后的数据（如果可修复）
```

Scrub 工作在 metadata extent 和 data extent 两个层面：
- Metadata extent：`scrub_stripe()` 处理
- Data extent：`scrub_page` 级别的逐页验证

### 7.2 Balance：重新分配 Chunk

Balance 的目标是**将数据从一个 chunk 迁移到另一个 chunk**，以优化空间使用或改变 RAID profile。

Balance 入口在 `volumes.c` 中的 `btrfs_balance()` 函数族：

```c
// volumes.c:3750 - 将磁盘格式的参数转换为 CPU 格式
static void btrfs_disk_balance_args_to_cpu(...)
```

Balance 的完整流程（`btrfs_balance` at `volumes.c`）：

```
1. 解析 balance 参数（data/meta/sys profile filter）
2. 扫描所有 chunk，找出符合 filter 的 chunk
3. 对每个需要重新分配的 chunk：
   a. 创建 reloc_root
   b. 标记 chunk 为 RO（block_group::ro）
   c. 扫描 chunk 中的所有 extent
   d. 将 extent 移动到新 chunk
   e. 更新 extent tree 中的引用
   f. 释放旧 chunk
4. 提交 transaction
```

Balance 中的块移动由 **relocation.c** 处理（6122 行），核心函数：

```c
// relocation.c: relocate_file_extent_cluster()
// 移动一个文件 cluster 的所有 extent
// 1. 读原始数据
// 2. 分配新位置
// 3. 写新位置
// 4. 更新 extent tree
// 5. 释放旧位置
```

### 7.3 Scrub 与 Balance 的协同

Scrub 期间如果发现不可修复的错误，会标记 chunk 为只读（`BTRFS_DISCARD_ITEM_SCRUB_ERROR`），阻止进一步写入。Balance 可以选择只平衡有效数据，跳过损坏的 extent。

---

## 八、总结：btrfs 架构要点

```
btrfs 核心设计哲学：

1. 一切皆 B-tree
   - 所有元数据和数据索引都存储在 B-tree 中
   - extent tree 管理空间分配，fs tree 管理文件逻辑布局

2. COW 保证一致性
   - 写入永远不覆盖已存在的数据
   - transaction commit 时一次性持久化
   - 快照的"零复制"建立在 COW 之上

3. Chunk 是物理分配的桥梁
   - RAID profile 在 chunk 分配层面实现
   - block group 是 chunk 的内存抽象
   - stripe 映射由 chunk_root 管理

4. 延迟引用减少锁竞争
   - 引用计数变更进入 delayed ref 队列
   - transaction commit 时批量处理
   - 避免了大量随机写 extent tree

5. 多棵树协同
   - tree_root: 根节点管理
   - extent_root: 空间账本
   - chunk_root: 物理布局
   - fs_root: 文件系统视图
   - 各司其职，互相引用
```
