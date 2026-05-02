# btrfs 文件系统深度分析

btrfs 是一个为 Linux 设计的写时复制（Copy-on-Write）文件系统，设计目标包括：数据完整性保护、可扩展性、子卷/快照支持、软件 RAID、内联压缩等高级存储功能。本文以 Linux 7.0-rc1 内核源码为依据，深度剖析 btrfs 的核心数据结构、COW 机制、extent 管理、RAID 冗余、快照和压缩等关键技术。

> **源码基准**：Linux 7.0-rc1，主要分析 `/home/dev/code/linux/fs/btrfs/` 下的实现，核心文件为 `ctree.c`（5074 行）、`extent_io.c`（4695 行）、`disk-io.c`（4955 行）、`volumes.c`、`extent-tree.c`、`compression.c`、`scrub.c`。

---

## 一、核心数据结构：B-tree、extent tree 与 struct btrfs_path

### 1.1 B-tree 结构：leaf 与 node

btrfs 的所有元数据（目录项、文件索引、extent 映射）和存储空间管理都建立在 B-tree 之上。在 `ctree.c` 的实现中，leaf 和 node 共享同一个 `struct extent_buffer` 结构，只是 `level` 字段不同：

```c
// ctree.c: btrfs_header_level() 区分节点类型
static inline int btrfs_header_level(const struct extent_buffer *eb)
{
    return eb->level;
}
```

- **Leaf**（`level == 0`）：存储 `struct btrfs_item`，每个 item 包含一个 key 和对应的数据（内联数据或指向其他树的引用）。item 的布局从 `struct btrfs_leaf::items` 开始，每个 `struct btrfs_item` 包含 `{ key, offset, size }`。
- **Node**（`level > 0`）：存储 `struct btrfs_key_ptr`，每个 ptr 包含 `{ child_physical_addr, key, generation }`。指针按 key 排序，支持二分查找定位下一层节点。

关键搜索函数 `btrfs_bin_search()`（`ctree.c:738`）同时适用于 leaf 和 node，通过 `offsetof()` 根据 `level` 选择从 `btrfs_leaf::items` 还是 `btrfs_node::ptrs` 开始解析：

```c
// ctree.c:738 — 二分查找核心
if (btrfs_header_level(eb) == 0) {
    p = offsetof(struct btrfs_leaf, items);
    item_size = sizeof(struct btrfs_item);
} else {
    p = offsetof(struct btrfs_node, ptrs);
    item_size = sizeof(struct btrfs_key_ptr);
}
while (low < high) {
    mid = (low + high) / 2;
    ret = btrfs_comp_keys(tmp, key);
    // ret < 0 → key 在 mid 右侧；ret > 0 → key 在 mid 左侧；ret == 0 → 命中
}
```

### 1.2 struct btrfs_path — 树遍历的"梯子"

`struct btrfs_path`（定义于 `ctree.h:56`）是 btrfs 树遍历的核心数据结构，相当于从根到当前 leaf 的"路径栈"：

```c
struct btrfs_path {
    struct extent_buffer *nodes[BTRFS_MAX_LEVEL];  // 每层一个节点/leaf
    int slots[BTRFS_MAX_LEVEL];                     // 每层命中的 item 槽位
    u8 locks[BTRFS_MAX_LEVEL];                     // 每层锁的级别（读锁/写锁）
    // ...
};
```

`BTRFS_MAX_LEVEL` 通常为 8（足以支持深度很大的树）。路径的工作方式：

1. `btrfs_search_slot()` 从根向下逐层查找，每一层记录 `nodes[level]` 和命中的 `slots[level]`
2. 搜索完成后，`path->nodes[0]` 指向当前 leaf，`path->slots[0]` 指向 leaf 中的目标 item
3. 父节点在 `path->nodes[1]`、`path->nodes[2]` 等，`slots[i]` 对应子节点在其父节点中的槽位

`btrfs_alloc_path()`（`ctree.c:139`）从 slab cache 分配 path，`btrfs_release_path()`（`ctree.c:161`）逐层解锁并释放对 extent_buffer 的引用。这是一个被高频使用的路径，所有树操作（插入、删除、搜索）都依赖它。

### 1.3 extent tree 与 fs tree 的区别

btrfs 有多棵 B-tree，各司其职：

| 树 | 用途 | 根节点位置 |
|---|---|---|
| **fs tree**（文件系统树） | 文件目录结构、extent 映射（文件数据物理位置） | 每 subvolume/snapshot 各自独立 |
| **extent tree**（extent 树） | 记录所有已分配 extent 的元数据（属于哪个 chunk、引用计数） | 所有 block group 共享的全局树 |
| **chunk tree**（chunk 树） | 管理 block group 和设备 stripe 映射 | 超级块指向 |
| **root tree**（根树） | 管理所有 subvolume/snapshot 的根 | 超级块指向 |
| **tree log** | 记录尚未提交到 fs tree 的事务操作 | 临时，挂起时存在 |

**extent tree** 的 key 格式为 `(objectid=0, type=BTRFS_EXTENT_ITEM_KEY, offset=extent_physical_start)`，value 为 `struct btrfs_extent_item`，包含 `num_bytes`、`refs`（引用计数）等信息。每当分配一个新的 extent，就在 extent tree 中插入一个条目；释放 extent 时更新引用计数。

**fs tree** 的 key 格式为 `(objectid=inode_number, type=item_type, offset)`：
- `BTRFS_INODE_ITEM_KEY`：inode 元数据（mode、size、uid/gid 等）
- `BTRFS_INODE_REF_KEY`：文件名（跨目录共享硬链接）
- `BTRFS_EXTENT_DATA_KEY`：文件数据 extent 映射（指向 extent tree 中的 extent 或内联数据）

### 1.4 COW 路径上的结构体链

从用户写入到磁盘分配，完整的 COW 路径涉及以下结构体：

```
用户缓冲区
  ↓
btrfs_submit_write() → struct btrfs_inode
  ↓
btrfs_search_slot(fs_tree) → struct btrfs_path（找到目标 leaf）
  ↓
btrfs_cow_block() → 检查 should_cow_block()
  ↓
btrfs_force_cow_block() → 分配新的 extent_buffer（cow）
  ↓
btrfs_alloc_tree_block() → struct btrfs_key { bytenr, num_bytes }
  ↓
btrfs_reserve_extent() → 从 block_group 分配物理空间，写入 extent tree
  ↓
copy_extent_buffer_full(cow, buf) → 数据复制到新 block
  ↓
update_ref_for_cow() → 更新引用计数
  ↓
write_extent_buffer() → 脏页标记，最终通过 transaction commit 刷盘
```

---

## 二、COW（Copy-on-Write）机制

### 2.1 COW 的工作原理

btrfs 是一个"永不就地覆写"（never-overwrite）的文件系统。所有对已有数据块（包括元数据块）的修改都遵循以下模式：

1. **分配新块**：从空闲空间中分配一个全新的物理块
2. **写入新块**：将修改后的数据写入新块
3. **更新指针**：将父节点中指向旧块的指针替换为指向新块
4. **旧块延迟释放**：旧块引用计数减 1，若归零则变为空闲空间（不立即覆写）

这一机制天然提供了**原子性**保障：事务提交前，旧数据仍然保持完好；事务提交后，新数据才对外部可见。

### 2.2 btrfs_cow_block 完整路径

`btrfs_cow_block()`（`ctree.c:651`）是 COW 的入口函数，调用流程：

```
btrfs_cow_block(trans, root, buf, parent, parent_slot, &cow_ret)
  ├─ should_cow_block() 检查是否需要 COW
  │    返回 false → 复用原块（同一个 transaction 内的同一 root）
  │    返回 true  → 继续
  ├─ btrfs_force_cow_block()  ← 真正执行 COW
  │    ├─ btrfs_alloc_tree_block()  ← 分配新物理块
  │    │    ├─ btrfs_use_block_rsv()  从 block reservation 分配
  │    │    ├─ btrfs_reserve_extent()  从 block_group 找空闲空间
  │    │    └─ btrfs_init_new_buffer()  初始化 extent_buffer
  │    ├─ copy_extent_buffer_full(cow, buf)  复制数据
  │    ├─ btrfs_set_header_generation(cow, trans->transid)
  │    ├─ update_ref_for_cow()  更新 extent tree 引用计数
  │    ├─ btrfs_reloc_cow_block()  如 reloc_root 需要处理反向映射
  │    ├─ 若 buf == root->node:
  │    │    ├─ btrfs_tree_mod_log_insert_root()  记录根替换历史
  │    │    ├─ rcu_assign_pointer(root->node, cow)  更新根指针
  │    │    ├─ btrfs_free_tree_block(old)  释放旧块
  │    │    └─ add_root_to_dirty_list()  将 root 标记为脏，等待刷盘
  │    └─ 否则（非根节点）：
  │         ├─ btrfs_tree_mod_log_insert_key()  记录指针替换历史
  │         ├─ btrfs_set_node_blockptr(parent, parent_slot, cow->start)
  │         ├─ btrfs_mark_buffer_dirty(parent)  标记父节点为脏
  │         └─ btrfs_free_tree_block(old)  释放旧块
  └─ trace_btrfs_cow_block()  追踪事件
```

关键函数 `btrfs_force_cow_block()`（`ctree.c:465`）中，所有对树结构的修改（更新根节点、修改父节点指针）都是通过 COW 后的新块完成的。旧块在 `update_ref_for_cow()` 中引用计数递减，如果变成 0（没有其他 reference），则可被释放为可用空间。

### 2.3 should_cow_block 的判定逻辑

`should_cow_block()`（`ctree.c:606`）是一个内联函数，判定是否需要 COW。基本原则：
- **共享根**（`BTRFS_ROOT_SHAREABLE` set）：该 root 可能被快照共享，必须 COW 以保证快照的完整性
- **非共享根**：同一事务内对同一 root 的修改，若无快照引用，可以不 COW 直接修改（用写锁保护并发）
- **非 SHAREABLE 根**：通常不需要 COW 元数据块

### 2.4 extent 写入完整 COW 路径 ASCII 图

```
用户 write(2)
  │
  ▼
┌──────────────────────────────────────────────────────────────┐
│ btrfs_writepages / btrfs_submit_write                       │
│  → 为文件 extent 构建 btrfs_ordered_extent（等待磁盘空间）   │
└──────────────────────────────────────────────────────────────┘
  │
  ▼
┌──────────────────────────────────────────────────────────────┐
│ btrfs_search_slot(fs_tree)                                   │
│  → 从 fs_tree 根开始，二分查找路径，建立 struct btrfs_path   │
│  → 逐层：btrfs_bin_search() → nodes[level], slots[level]     │
│  → 最终 nodes[0] = 目标 leaf，slots[0] = 目标 item           │
└──────────────────────────────────────────────────────────────┘
  │
  ▼
┌──────────────────────────────────────────────────────────────┐
│ should_cow_block() → true（共享根 / 跨事务 / 快照引用）       │
│ btrfs_cow_block() entry                                     │
└──────────────────────────────────────────────────────────────┘
  │
  ▼
┌──────────────────────────────────────────────────────────────┐
│ btrfs_force_cow_block()                                      │
│                                                              │
│ ① btrfs_alloc_tree_block(trans, root, ...)                   │
│    ├─ btrfs_use_block_rsv()  从 transaction 预留空间          │
│    └─ btrfs_reserve_extent()                                 │
│         ├─ btrfs_find_free_extent()  搜索可用 block_group    │
│         │    → 遍历 space_info → block_group 链表            │
│         │    → 从 free_space cache 中找连续空间              │
│         │    → 返回 (objectid = physical_addr, offset = size) │
│         │                                                      │
│         │    [Block Group 结构]                                │
│         │    ┌────────────┬────────────┬────────────┐         │
│         │    │ used       │  free      │ reserved  │         │
│         │    └────────────┴────────────┴────────────┘         │
│         │                              ↑                      │
│         │                         找到这个区间              │
│         │                                                      │
│         └─ btrfs_init_new_buffer()  创建 struct extent_buffer │
│              → 设置 start = ins.objectid（物理地址）          │
│              → 设置 level = 0（leaf）或更高                   │
│                                                              │
│ ② copy_extent_buffer_full(cow, buf)  将旧块数据拷贝到新块    │
│                                                              │
│ ③ update_ref_for_cow()                                       │
│    → 从 extent tree 查到旧块的 ref count                     │
│    → 旧块 ref_count--，新块 ref_count = 1                     │
│    → 若旧块 ref_count == 0，加入 delayed refs 等待释放        │
└──────────────────────────────────────────────────────────────┘
  │
  ▼
┌──────────────────────────────────────────────────────────────┐
│ 父节点指针更新（COW 链式向上传播）                            │
│                                                              │
│ 若 buf == root->node（是根节点）:                            │
│    rcu_assign_pointer(root->node, cow)  原子替换根指针       │
│    btrfs_free_tree_block(old_root)  释放旧根                 │
│    add_root_to_dirty_list(root)  标记该 root 需要刷盘         │
│                                                              │
│ 若 buf != root->node（普通节点）:                            │
│    btrfs_set_node_blockptr(parent, parent_slot, cow->start)  │
│    btrfs_mark_buffer_dirty(parent)  标记父节点为脏            │
│    → 父节点同样触发 COW 链，递归向上直到根                   │
└──────────────────────────────────────────────────────────────┘
  │
  ▼
┌──────────────────────────────────────────────────────────────┐
│ btrfs_mark_buffer_dirty(cow)                                 │
│  → 将 cow 加入 transaction 的 dirty 列表                      │
│  → extent buffer 被标记为 "需要写入磁盘"                      │
│  → 等待 transaction commit 时统一刷盘                         │
└──────────────────────────────────────────────────────────────┘
  │
  ▼
┌──────────────────────────────────────────────────────────────┐
│ Transaction Commit 阶段                                       │
│                                                              │
│ btrfs_commit_transaction()                                   │
│  ① barrier 写入所有 dirty extent_buffer（metadata）          │
│  ② 写入 superblock（更新 root 指针、generation）            │
│  ③ fsync / fdatasync 完成                                  │
│                                                              │
│ 旧块释放（delayed ref 机制）:                                │
│  → btrfs_qgroup_destroy() → 清理旧块的 qgroup 引用           │
│  → btrfs_free_tree_block() → 旧块 ref_count == 0 时加入      │
│    free_space cache（不再覆写，等待 GC 或 balance 整理）     │
└──────────────────────────────────────────────────────────────┘
```

**COW 的关键效果**：
- 快照可以在任意时刻创建：只需复制根节点引用，旧数据不会因新写入而被破坏
- 事务原子性：通过两次完整写入（superblock 更新前后的两次 commit）实现
- 数据损坏可恢复：旧块不会立即被覆写，可以通过只读挂载或快照回滚恢复

---

## 三、chunk 与 extent 映射

### 3.1 chunk 分配机制

btrfs 的存储空间按 `block group` 组织，每个 block group 包含多个 `chunk`。chunk 是存储分配的物理单位，具有特定的 RAID 属性（raid1、raid10、dup 等）。

`btrfs_find_free_extent()`（`extent-tree.c`）是分配入口，流程：

```
btrfs_find_free_extent()
  ├─ 遍历 fs_info->space_info 链
  │    每个 space_info 包含多个 block_group
  ├─ should_alloc_chunk() 判断当前 space_info 空间是否足够
  │    → 若不足，调用 btrfs_alloc_chunk() 创建新 chunk
  │         ├─ init_alloc_chunk_ctl() 根据 RAID profile 初始化 ctl
  │         │    → raid1: devs_min=2, ncopies=2, devs_stripes=1
  │         │    → raid10: sub_stripes=2, devs_min=2, ncopies=2
  │         ├─ decide_stripe_size_regular()
  │         │    → raid1: 每个 stripe 一个 device，两份数据
  │         │    → raid10: stripe = 2 devices，nstripes = num_devices/2
  │         ├─ btrfs_alloc_chunk_map() 创建 struct btrfs_chunk_map
  │         │    → 记录 num_stripes、stripe_offset、type（RAID 属性）
  │         └─ 将 chunk 插入 chunk_map RB-tree
  └─ 从匹配的 block_group 中找一段连续空闲空间
       → 返回 btrfs_key { objectid=physical_addr, offset=num_bytes }
```

在 `volumes.c:5582` 的 `struct alloc_chunk_ctl` 中定义各 RAID 类型的参数：

```c
// volumes.c — RAID 配置表（btrfs_raid_array）
[BTRFS_RAID_RAID10] = {
    .sub_stripes = 2,   // 每组 2 个 stripe 作为一个镜像对
    .dev_stripes = 1,
    .devs_min = 2,
    .ncopies = 2,        // 每块数据两份
    .bg_flag = BTRFS_BLOCK_GROUP_RAID10,
}
[BTRFS_RAID_RAID1] = {
    .sub_stripes = 1,
    .dev_stripes = 1,
    .devs_min = 2,
    .ncopies = 2,        // 所有 device 同时写入相同数据
    .bg_flag = BTRFS_BLOCK_GROUP_RAID1,
}
```

### 3.2 extent tree 与 chunk map 的关系

**chunk tree**（chunk RB-tree）负责 logical 到 physical 的映射，key 是 chunk 的起始 logical 地址：

```c
// volumes.c: rb-tree of chunk maps
struct btrfs_chunk_map {
    u64 logical;          // logical address (chunk 起始)
    u64 length;           // chunk 大小
    int num_stripes;      // stripe 数量
    struct btrfs_stripe stripes[];
    // key: by (logical, type) → value: chunk_map
};
```

当文件系统需要知道某个 logical 地址对应的物理设备和 stripe 偏移时，调用 `btrfs_get_chunk_map(fs_info, logical, len)` 在 RB-tree 中查找匹配的 chunk map。

**extent tree** 负责记录已分配的 extent 元数据，key 是 extent 的 physical bytenr。每分配一个 extent，就在 extent tree 中插入一条 `BTRFS_EXTENT_ITEM_KEY`，其中包含 `num_bytes` 和 `ref_count`。当 `ref_count == 0` 时，该 extent 被标记为空闲，释放回 block group 的 free_space cache。

### 3.3 btrfs_reserve_extent 的完整流程

```c
// extent-tree.c:4871
btrfs_reserve_extent(root, ram_bytes, min_size, alloc_hint, empty_size, &ins)
  ├─ btrfs_find_free_extent(root, ...)
  │    ├─ 遍历 space_info → block_group
  │    ├─ 从 block_group->free_space.cache 找连续区间
  │    └─ 若找不到 sufficient 空间 → 触发 chunk 分配
  │         └─ btrfs_alloc_chunk() → 创建新 block group
  ├─ 分配成功 → ins.objectid = physical_addr, ins.offset = num_bytes
  ├─ btrfs_add_delayed_extent(ins)
  │    → 写 extent tree（插入 BTRFS_EXTENT_ITEM_KEY）
  │    → 增加 block_group->used 计数
  │    → 更新 space_info->bytes_used
  └─ 返回 ins
```

---

## 四、RAID1/RAID10 数据冗余

### 4.1 btrfs RAID 的层次

btrfs 的数据冗余在 **chunk 分配层** 实现，而不是在底层块设备层。这意味着：
- RAID1 在 btrfs 文件系统层面维护两份完整数据副本，底层可以是任意块设备（HDD、SSD）
- 每个 RAID 属性（raid1/raid10/dup）定义一个 `block group type`
- 写入时，btrfs 根据 chunk 的 RAID 属性决定写几个副本

### 4.2 RAID1 镜像写入路径

RAID1 在 `volumes.c` 中的实现分为几个层次：

**1. chunk 分配阶段**（`init_alloc_chunk_ctl_policy_regular()`）：
```c
// volumes.c:5613
init_alloc_chunk_ctl_policy_regular(fs_devices, ctl)
  → raid1: devs_max=2, devs_min=2, devs_increment=2
  → 每个 device 分配一个 stripe，内容完全相同
```

**2. 写路径 — btrfs_submit_bio**（`bio.c:568`）：

```
btrfs_submit_bio(bio, bioc, smap, mirror_num)
  ├─ btrfs_map_bio(fs_info, bioc, op, smap)
  │    ├─ btrfs_get_chunk_map(logical)
  │    └─ map_blocks_raid1(io_geom)  ← 核心 RAID 映射逻辑
  │         → io_geom->num_stripes = map->num_stripes (每个 stripe 都要写)
  │         → 所有 mirror 都写入
  ├─ 对 num_stripes 依次调用 submit_bio
  │    → 每个 stripe 的物理设备都收到相同的完整数据
  │    → stripe[i].physical = chunk起始 + i * stripe_len
  └─ 写入完成，通过 btrfs_write_end() 更新 fs_tree
```

`map_blocks_raid1()`（`volumes.c:6904`）对写入操作的处理：
```c
if (io_geom->op != BTRFS_MAP_READ) {
    // 写入操作：所有镜像都要写
    io_geom->num_stripes = map->num_stripes;
    return;
}
```

**3. btrfs_num_copies()** — 询问某个 logical 区间有多少副本可用：
```c
// volumes.c:6340
btrfs_num_copies(fs_info, logical, len)
  → btrfs_get_chunk_map(logical)
  → btrfs_chunk_map_num_copies(map)  // raid1 → 2, raid10 → 2, dup → 2
  → free chunk_map
```

### 4.3 RAID10 的条带化与镜像

RAID10 是条带化（RAID0）与镜像（RAID1）的组合：
- **条带化**：`stripe_nr % num_stripes` 确定属于哪个物理 device
- **镜像**：同一个 RAID10 组内的两个 stripe 包含相同数据

```c
// volumes.c:6940 — RAID10 映射
map_blocks_raid10(fs_info, map, io_geom)
  ├─ 计算 stripe_index = (stripe_nr % (num_stripes / sub_stripes)) * sub_stripes
  │    → RAID10 将 devices 分为若干组，每组 2 个（sub_stripes=2）
  │    → 数据同时写入同一组的两个设备
  ├─ RAID10 读取：选择其中一个副本（round-robin）
  └─ RAID10 写入：所有 mirror 都写
```

### 4.4 device add 与 chunk 分配的关系

当使用 `btrfs device add` 添加新设备时：
1. 新设备注册到 `fs_devices` 链表
2. 已有的 block group 不会自动重新分布
3. 新的 chunk 分配可以落在新设备上（取决于 chunk tree 的分配策略）
4. 已有的数据仍在旧设备上，直到执行 `btrfs balance` 进行数据迁移

```
device add /dev/sdb
  → fs_devices 链表增加设备
  → 新 block group 分配时选择 devid 匹配的 chunk
  → 旧的 raid1 chunk 仍在原设备上
  → btrfs balance 会将数据重新分布到所有设备
```

---

## 五、快照（snapshot）与子卷（subvolume）

### 5.1 快照与子卷的关系

在 btrfs 中，快照和子卷本质上都是 **独立的 fs tree 根**。区别在于：
- **子卷**：一个独立的文件系统树，有自己的 root tree entry
- **快照**：某一时刻子卷的只读副本，其根节点是原子卷根节点的 COW 复制

两者共享同一个数据结构 `struct btrfs_root`，通过 `BTRFS_ROOT_SUBVOL_RDONLY` 标志位区分是否只读。

### 5.2 btrfs_copy_root — 快照的核心

`btrfs_copy_root()`（`ctree.c:243`）是建立快照的核心函数：

```c
btrfs_copy_root(trans, root, buf, cow_ret, new_root_objectid)
  ├─ btrfs_alloc_tree_block(trans, root, ...)
  │    → 分配一个全新的物理块（COW 新块）
  │    → level = btrfs_header_level(buf)（与原节点相同）
  │    → owner = new_root_objectid（新子卷/快照的 ID）
  ├─ copy_extent_buffer_full(cow, buf)
  │    → 将整个原节点的数据（包括所有 child pointers）复制到新块
  ├─ btrfs_set_header_generation(cow, trans->transid)
  │    → 更新 generation（快照创建的事务 ID）
  ├─ 若 is_reloc_root → 设置 BTRFS_HEADER_FLAG_RELOC
  ├─ btrfs_tree_mod_log_link_node()  记录父子关系（支持 COW 历史追踪）
  └─ 返回 cow = 新根节点
```

注意：**子树的 child pointers 仍然指向原节点的 child**，而非重新分配。这就是快照"立即创建"的原因——只需复制根节点，其余节点按需 COW。

### 5.3 快照创建的完整流程

```
btrfs ioctl(BTRFS_IOC_SNAP_CREATE, ...)
  → btrfs_get_fs_root(objectid)  找到原 subvolume
  → btrfs_start_transaction(root, ...)
  → btrfs_copy_root(trans, root->node, &cow, SNAPSHOT_OBJECTID)
      → 递归复制整棵树（不是一次性全部复制，而是路径上的节点逐级 COW）
      → 只需复制根到 leaf 路径上的节点（深度通常 3-4 层）
      → 其余共享节点暂不复制
  → 将新 root 插入 root tree（BTRFS_ROOT_ITEM_KEY）
  → btrfs_end_transaction()
```

创建快照的代价与树的深度成正比，而不是与文件系统大小成正比，因为只有路径上的节点需要复制。

### 5.4 COW 对快照的影响

COW 是快照存在的技术基础：

- **写时共享**：快照创建后，原子卷和快照共享所有未被修改的节点
- **修改隔离**：对原子卷的任何后续修改，只 COW 涉及的路径节点，快照端不受影响
- **递归 COW**：如果修改了快照中引用的节点（例如快照间共享的中间节点），则该节点被 COW，快照的根指针仍然指向旧节点

引用计数（ref count）在 extent tree 中管理：每个 extent item 有一个 `ref_count`，表示有多少个树节点引用了这个物理块。创建快照会增加 ref_count，释放（删除快照或文件）会减少 ref_count，ref_count 归零 时该物理块被回收。

### 5.5 子卷与 root tree

所有子卷和快照通过 `root tree` 管理：
- root tree 是以 `BTRFS_ROOT_ITEM_KEY` 为 key 的 B-tree
- 每个 entry 包含 `struct btrfs_root_item`（根节点 bytenr、generation、ref count 等）
- 子卷/快照的 ID（`btrfs_root_id()`）是其在 root tree 中的 objectid

---

## 六、压缩机制

### 6.1 btrfs 压缩的实现层次

btrfs 支持三种压缩算法：`zlib`、`lzo`、`zstd`。压缩是透明的，在写入路径和读取路径中自动处理，不需要用户显式解压。

**关键文件**：
- `compression.c`：压缩/解压缩框架和调度
- `zlib.c`：`zlib` 压缩实现（基于 zlib 库）
- `lzo.c`：`lzo` 压缩实现
- `zstd.c`：`zstd` 压缩实现

### 6.2 压缩写入路径

```
btrfs_submit_write()
  → btrfs_compress_heuristic()  判断是否值得压缩
      → 检查数据熵（随机数据不值得压缩）
      → 检查已有压缩历史
  → btrfs_compress_bio(inode, start, len, compress_type, level)
      ├─ 为每个连续压缩区域（compression context）分配 workspace
      ├─ 调用具体算法（zlib_compress / lzo_compress / zstd_compress）
      │    → 输出压缩后的 buffer
      │    → 设置 compress_type 和压缩级别
      ├─ 构建 struct compressed_bio
      │    → csum（校验和）
      │    → compress_type（BTRFS_COMPRESS_ZLIB/LZO/ZSTD）
      │    → compressed_len vs uncompressed_len
      └─ btrfs_submit_compressed_write()
           ├─ 映射 logical → physical（可能涉及 RAID）
           ├─ 分配 compressed extent（通常 16KB 或 64KB 块）
           ├─ 将压缩后的数据写入磁盘
           └─ 在 fs_tree 中记录 extent item（类型为 COMPRESSED）
```

**Compressed extent 的结构**（`compression.c:1033`）：
```c
struct compressed_bio {
    u64 logical;          // 文件 logical 地址
    u64 compressed_len;  // 压缩后大小
    u64 uncompressed_len; // 原始大小
    enum btrfs_compression_type compress_type;
    // ...
};
```

compressed extent 写入 extent tree 时，key 类型仍然是 `BTRFS_EXTENT_ITEM_KEY`，但 extent item 中额外记录了 `flags = BTRFS_EXTENT_FLAG_COMPRESSED`，`compression_offset` 指向压缩数据位置。

### 6.3 压缩读取路径

```
readpage → btrfs_readpage → btrfs_submit_bio
  → btrfs_map_bio()
  → 发现 extent 标记为 COMPRESSED
  → btrfs_submit_compressed_read(bbio)  ← 特殊处理
      ├─ 读取压缩后的 extent（一次磁盘 I/O）
      ├─ btrfs_decompress_bio(cb)  解压缩到原缓冲区
      │    ├─ zlib: inflate()
      │    ├─ lzo: lzo1x_decompress()
      │    └─ zstd: ZSTD_decompress()
      └─ 返回解压缩后的原始数据给调用者
```

compressed extent 的读取只需要一次 I/O（读压缩后的数据），然后在内存中解压缩。因此对于高压缩率数据（如文本、日志），可以显著减少磁盘 I/O。

### 6.4 zlib vs zstd

| 特性 | zlib | zstd |
|---|---|---|
| 压缩率 | 中等（通常 2-4x） | 高（通常 3-6x） |
| 压缩速度 | 慢（CPU 密集） | 快（尤其是 zstd-fast） |
| 解压缩速度 | 中等 | 快（接近 lzo） |
| CPU 使用 | 高 | 中等 |
| 适用场景 | 均衡场景，兼容性最好 | 需要高压缩率或快速解压的场景 |

压缩级别通过 `btrfs_compress_set_level()` 设置，`compression.c:970`：
- zlib：level 1-9（1=最快，9=最高压缩）
- zstd：level 1-15（1=最快，15=最高压缩）

### 6.5 压缩的 extent 映射

compressed extent 也是一个 extent，通过 extent tree 管理：
- `BTRFS_EXTENT_ITEM_KEY` 中 `flags` 包含 `BTRFS_EXTENT_FLAG_COMPRESSED`
- extent 的大小是**压缩后**的大小，而非原文件大小
- 解压缩时读取整个 compressed extent，然后解压到原始长度

---

## 七、scrub 和 balance

### 7.1 scrub — 数据完整性检测

scrub 是 btrfs 的在线数据完整性检查机制，能检测并修复 Silent Data Corruption（静默数据损坏）。

**入口**：`btrfs_scrub_dev()`（`scrub.c:3072`）

核心流程：
```
btrfs_scrub_dev(fs_info, devid, start, end, progress, readonly)
  ├─ scrub_setup_ctx()  创建 scrub 上下文
  │    → 分配 scrub_ctx（worker threads、bio 聚合）
  │    → 初始化校验和树（csum tree）查找
  ├─ scrub_workers_get()  获取 scrub 线程池
  │    → scrub_stripe()  以 stripe 为单位遍历设备
  ├─ 遍历设备的每个 block group:
  │    ├─ 读取 block group 的所有 extent
  │    ├─ 读取对应 extent 的校验和（csum tree）
  │    │    → csum_tree key: (objectid=0, type=EXTENT_CSUM_KEY, offset=logical)
  │    │    → value = checksum（通常是 32 字节 SHA256 或 xxhash）
  │    ├─ 比较读取的 data checksum 与 stored checksum
  │    │    → 不匹配 → 数据损坏
  │    │    → 计算 parity（对于 RAID56）验证冗余
  │    └─ 若发现损坏且 RAID1/RAID10 可用冗余副本：
  │         → 从另一个 mirror 读取正确数据
  │         → 写入修复损坏的副本
  ├─ scrub_recheck_block_checksum()  逐 block 验证
  │    → 对每个扇区计算 checksum，与存储的 csum 比对
  └─ 上报损坏：通过 /sys/fs/btrfs/<uuid>/scrub 暴露错误统计
```

**读取路径的校验**：不仅仅是 scrub 时检查，每次正常读取数据时 btrfs 也会验证 csum：
- 读取 extent data 时，`btrfs_lookup_csum()` 从 csum tree 查找该 logical 范围的 checksum
- 计算读取数据的 checksum，与 stored checksum 比对
- 不匹配 → 返回 `-EIO`，触发从其他镜像重新读取

### 7.2 balance — 存储空间重分布

balance 重新分配 chunk，将数据从一个 block group 迁移到另一个，以实现：
- **空间均衡**：将数据从接近满的 block group 迁移到空闲的
- **profile 转换**：将 `single` 转换为 `raid1`（重建冗余）
- **设备均衡**：将数据分布到所有设备

**核心流程**：

```
btrfs_balance(fs_info, bctl, bargs)
  ├─ btrfs_read_block_groups()  遍历所有 block group
  ├─ 对每个符合过滤条件（type/dusage/devid）的 block group：
  │    ├─ btrfs_relocate_chunk(start, false)
  │    │    ├─ 分配新 chunk（新 profile）
  │    │    ├─ 扫描原 block group 的所有 extent
  │    │    ├─ 对每个 extent：
  │    │    │    ├─ 从原 extent 读取数据
  │    │    │    ├─ 写入新 chunk（新 physical 地址）
  │    │    │    ├─ 更新 extent tree 的引用
  │    │    │    └─ 更新 chunk tree 的映射
  │    │    ├─ 释放原 chunk
  │    │    └─ 更新 space_info 和 block_group 状态
  │    └─ 标记原 block group 为 RO（禁止新分配）
  └─ btrfs_wait_ordered_range()  等待所有 in-flight I/O 完成
```

**balance vs. device add**：
- `device add` 后数据不会自动迁移到新设备
- `balance` 强制重分布，可以将单设备数据迁移到多设备 raid 配置
- `balance` 也是修复部分块组 profile 降级的唯一方法

### 7.3 scrub 和 balance 的并发

- balance 会暂停 scrub（`scrub_pause` mechanism）
- scrub 运行时，`btrfs_relocate_chunk()` 会等待 scrub 完成
- `btrfs_balance_delayed_items()` 在 transaction commit 前运行，将延迟的 balance 操作合并到提交过程

---

## 八、extent tree 与块组管理的关系

```
Block Group (Block Group Tree 中的一个 entry)
  ├── length: chunk 大小（如 1GB）
  ├── used: 已分配空间
  ├── chunk_objectid: 指向 chunk_map（RAID 信息）
  │
  ├── space_info (共享空间池)
  │    ├── block_groups (所有相同 profile 的 block groups)
  │    ├── total_bytes (总空间)
  │    └── bytes_used / bytes_readonly / bytes_may_use
  │
  ├── free_space cache (extent-tree.c 中管理)
  │    ├── 记录空闲区间（bitmap 或 extent-based）
  │    └── btrfs_find_free_extent() 查找可用空间
  │
  └── Chunk Map (RB-tree，按 logical 地址索引)
       ├── logical → physical 的 stripe 映射
       ├── num_stripes
       └── RAID type (RAID1/RAID10/DUP/SINGLE)
```

extent tree 中每个 `BTRFS_EXTENT_ITEM_KEY` 的 key.objectid 对应一个已分配 extent 的物理地址。block_group 的 used 计数与 extent tree 中的条目总和理论上一致（通过 `btrfs_block_group_used()` 验证）。

---

## 九、关键函数索引

| 函数 | 文件:行 | 作用 |
|---|---|---|
| `btrfs_search_slot` | ctree.c:2001 | 核心树搜索，在 fs_tree 中定位 key 的 leaf |
| `btrfs_bin_search` | ctree.c:738 | B-tree 二分查找，leaf/node 通用 |
| `btrfs_cow_block` | ctree.c:651 | COW 入口，判定 + 调度 |
| `btrfs_force_cow_block` | ctree.c:465 | 执行 COW 实际工作（分配、复制、更新） |
| `btrfs_copy_root` | ctree.c:243 | 复制根节点快照 |
| `btrfs_alloc_tree_block` | extent-tree.c:5335 | 从 block_group 分配物理树块 |
| `btrfs_reserve_extent` | extent-tree.c:4871 | 预留 extent（分配物理空间入口） |
| `btrfs_find_free_extent` | extent-tree.c:4594 | 在 block_group 中找空闲区间 |
| `btrfs_free_tree_block` | extent-tree.c:3617 | 释放物理块（更新 ref_count） |
| `btrfs_get_chunk_map` | volumes.c:3308 | 查找 logical → chunk 映射 |
| `btrfs_num_copies` | volumes.c:6340 | 查询 RAID 副本数 |
| `map_blocks_raid1` | volumes.c:6904 | RAID1 映射逻辑 |
| `map_blocks_raid10` | volumes.c:6940 | RAID10 映射逻辑 |
| `btrfs_submit_bio` | bio.c:568 | bio 提交入口，调用 map_bio |
| `btrfs_submit_compressed_write` | compression.c:315 | 压缩数据写入 |
| `btrfs_submit_compressed_read` | compression.c:541 | 压缩数据读取 |
| `btrfs_scrub_dev` | scrub.c:3072 | scrub 入口 |
| `btrfs_balance` | ioctl.c:3453 | balance 入口 |
| `btrfs_create_snapshot` | ioctl.c:2767 | 快照创建（通过 btrfs_copy_root） |

---

## 十、总结

btrfs 的设计哲学是**以 COW 为基础，通过树结构管理一切**。几个核心机制相互缠绕：

1. **extent tree** 是存储分配的全局账本，所有 extent 的物理地址和引用计数都记录在这里
2. **COW** 是快照和事务原子性的基础，每个写操作都产生新块，旧块被引用计数保护
3. **chunk tree + block group** 是空间分配的物理层，RAID 属性在分配时确定，而非事后添加
4. **校验和树（csum tree）** 贯穿读取和 scrub 路径，确保每个 extent 的数据完整性
5. **scrub** 利用 RAID 冗余进行修复，balance 则负责空间和 profile 的重新组织

btrfs 的优势在于所有这些机制协同工作：COW 使快照零成本，RAID 属性在 chunk 层面一致管理，内联压缩无需额外存储层，checksum 覆盖所有数据路径。代价是 COW 写放大（write amplification）和复杂的事务管理，对 SSD 友好但对机械硬盘需要合理配置。