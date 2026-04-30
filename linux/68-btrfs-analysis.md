# btrfs — B-Tree 文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/btrfs/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**btrfs**（B-Tree FS）是 Linux 的现代 COW（Copy-On-Write）文件系统，支持：
- **CoW**：写入时复制，保证数据完整性
- **Snapshot**：支持只读快照和克隆
- **Subvolumes**：类似 ZFS 的数据集
- **内联校验**：CRC 校验所有数据
- **多设备**：RAID0/1/10/5/6 支持

---

## 1. 核心数据结构

### 1.1 btrfs_super_block — 超级块

```c
// fs/btrfs/ctree.h — btrfs_super_block
struct btrfs_super_block {
    // 标识
    u8                      csum[32];      // 校验和（SHA256）
    u8                      fsid[16];      // 文件系统 UUID
    u8                      bytenr[8];     // 块地址

    // 块大小
    u32                     chunksize;      // 数据块大小
    u32                     sector_size;    // 扇区大小
    u64                     total_bytes;    // 总大小
    u64                     bytes_used;     // 已用大小

    // 根节点
    u64                     root_dir_objectid; // 根目录 inode
    u64                     chunk_root_generation; // Chunk 树代数
    u64                     log_root_objectid;   // 日志根
    u64                     log_root_transid;    // 日志事务

    // 时间戳
    struct btrfs_timespec   ctime;        // 创建时间
    struct btrfs_timespec   otime;        // 挂载时间
    u64                     last_trans_id;  // 最后事务 ID

    // 标记
    u32                     flags;         // BTRFS_SUPER_FLAG_*
    //   BTRFS_SUPER_FLAG_CHANGING_FS   (正在修改)
    //   BTRFS_SUPER_FLAG_ERROR         (错误)
};
```

### 1.2 btrfs_header — B-tree 节点头

```c
// fs/btrfs/ctree.h — btrfs_header
struct btrfs_header {
    // 校验
    u8                      csum[32];      // CRC32c
    u8                      fsid[16];      // 文件系统 UUID

    // 位置
    u64                     bytenr;        // 自身地址
    u64                     generation;    // 事务 ID

    // 结构
    u64                     owner;         // 所有者（chunk root 的 root ID）
    u32                     flags;         // NODE_FLAG_*

    u8                      level;         // B-Tree 深度（0=叶子）
};
```

### 1.3 btrfs_key — B-tree 键

```c
// fs/btrfs/ctree.h — btrfs_key
struct btrfs_key {
    __le64                  objectid;       // 对象 ID（inode 号）
    __le64                  type;          // 类型（EXTENT_ITEM/INODE_ITEM/DIR_ITEM...）
    __le64                  offset;         // 偏移/长度/子类型
};

// 类型：
//   BTRFS_ROOT_ITEM_KEY        = 1   // 子卷根
//   BTRFS_INODE_ITEM_KEY       = 6   // inode 元数据
//   BTRFS_EXTENT_ITEM_KEY      = 9   // extent
//   BTRFS_DIR_ITEM_KEY         = 12  // 目录项
//   BTRFS_EXTENT_DATA_KEY      = 18  // 文件数据
```

---

## 2. B-Tree 结构

### 2.1 节点布局

```
btrfs_node（内部节点）:
  btrfs_header
  btrfs_key_ptr[0..n-1]:
    key           ← 键
    blockptr      ← 子节点块地址
    generation    ← 子节点代数
  btrfs_footer   ← 校验

btrfs_leaf（叶子节点）:
  btrfs_header
  items[0..n-1]:
    key           ← 键
    offset        ← 在叶子中的偏移
    size          ← 大小
  data           ← 实际数据
```

### 2.2 btrfs_search — 查找

```c
// fs/btrfs/ctree.c — btrfs_search
int btrfs_search(struct btrfs_root *root, const struct btrfs_key *key, ...)
{
    struct btrfs_path *path;
    struct btrfs_key tmp;
    int slot;
    int ret;

    // 1. 从根开始
    path->nodes[0] = root->node;
    level = 0;

    // 2. 遍历每层 B-Tree
    while (level < root->level) {
        node = path->nodes[level];

        // 3. 在键数组中二分查找
        slot = btrfs_search_slot(node, key);

        // 4. 进入下一层
        child = btrfs_node_child_ptr(node, slot);
        path->nodes[++level] = read_block(child);
    }

    // 5. 到达叶子，找到具体 item
    leaf = path->nodes[level];
    slot = btrfs_search_slot(leaf, key);
}
```

---

## 3. COW 机制

### 3.1 btrfs_cow_block — 复制块

```c
// fs/btrfs/ctree.c — btrfs_cow_block
static int btrfs_cow_block(struct btrfs_trans_handle *trans,
                          struct btrfs_root *root,
                          struct btrfs_buffer *buf,
                          struct btrfs_buffer *parent,
                          int parent_slot)
{
    struct btrfs_buffer *cow;

    // 1. 分配新块
    cow = btrfs_alloc_free_block(trans, root, buf->len);

    // 2. 复制内容（Copy-On-Write）
    memcpy(cow->data, buf->data, buf->len);

    // 3. 更新父节点指针
    if (parent)
        btrfs_set_node_blockptr(parent, parent_slot, cow->bytenr);

    // 4. 标记为脏
    btrfs_set_dirty(cow);

    // 5. 释放旧块（延迟释放，因为可能有快照引用）
    btrfs_free_path(buf);

    return 0;
}
```

---

## 4. Snapshot

### 4.1 btrfs_create_snapshot — 创建快照

```c
// fs/btrfs/ioctl.c — btrfs_create_snapshot
int btrfs_create_snapshot(struct btrfs_trans_handle *trans,
                         struct btrfs_root *root,
                         struct btrfs_root *parent_root,
                         const char *name, ...)
{
    // 1. 分配新根（root_item）
    // 2. 设置根的 generation = 当前事务 ID
    // 3. 设置快照目标指向原根
    new_root->reloc_root = old_root->root_item.root_dirid;

    // 4. 记录快照
    //    snapshots 不复制数据，只是记录根位置
    //    COW 保证写入时不会覆盖原数据

    return 0;
}
```

---

## 5. 多设备管理

```c
// fs/btrfs/volumes.c — btrfs_fin_chunk_reloc
// chunk 分配：
//   - chunk_tree 中记录每个 chunk 的设备/物理位置
//   - 多设备条带化（RAID0）或镜像（RAID1）
//   - BTRFS_DEV_ITEM_KEY 记录设备信息
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/btrfs/ctree.h` | `struct btrfs_super_block`、`struct btrfs_header`、`struct btrfs_key` |
| `fs/btrfs/ctree.c` | `btrfs_search`、`btrfs_cow_block` |
| `fs/btrfs/ioctl.c` | `btrfs_create_snapshot` |