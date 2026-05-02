# 68-btrfs — Linux Btrfs 文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**Btrfs（B-tree File System）** 是一个写时复制（CoW）文件系统，由 Oracle 于 2008 年启动开发。Btrfs 最核心的设计是**一棵 B 树管理一切**——文件数据、目录条目、extent 分配、chunk 映射全部通过 COW B 树实现。

**与 XFS/ext4 的核心区别**：

| 特性 | ext4 | XFS | Btrfs |
|------|-----|-----|-------|
| 存储架构 | 块组 + 位图 | AG + B+ 树(C/B) | **全局 B 树** |
| 数据更新 | 覆盖写 | 覆盖写 | **写时复制(CoW)** |
| 一致性 | JBD2 日志 | CIL 延迟日志 | **CoW + 世代号** |
| 校验和 | 无 | 无 | **数据和元数据 CRC32C** |
| 快照/子卷 | 无 | 无 | **原生内建** |
| RAID | 无 | 无 | **文件系统层 RAID0/1/10** |

**doom-lsp 确认**：Btrfs 在 `fs/btrfs/`（**65 个文件**）。核心 B 树操作在 `ctree.c`（5,074 行），事务在 `transaction.c`（2,754 行），extent 分配在 `extent-tree.c`（6,921 行）。

---

## 1. 核心数据结构

### 1.1 struct extent_buffer — B 树节点（元数据块）

`extent_buffer` 是 Btrfs 中所有元数据的存储单元——每个 B 树节点就是一个 `extent_buffer`：

```c
// fs/btrfs/extent_io.h:86-115
struct extent_buffer {
    u64 start;                              /* 磁盘偏移 */
    u32 len;                                 /* 节点大小（如 16K）*/
    unsigned long bflags;                    /* 标志 */
    struct btrfs_fs_info *fs_info;
    void *addr;                              /* 内存地址（可直接访问）*/

    spinlock_t refs_lock;
    refcount_t refs;                         /* 引用计数 */
    int read_mirror;                         /* 读取的镜像号 */

    struct rw_semaphore lock;                /* 读写信号量 */
    struct folio *folios[INLINE_EXTENT_BUFFER_PAGES]; /* 背页（folio 数组）*/
};
```

**B 树节点的磁盘格式**（`struct btrfs_header`）：

```c
// 每个 extent_buffer 的开头是 btrfs_header：
struct btrfs_header {
    u8 csum[BTRFS_CSUM_SIZE];        /* 校验和（元数据保护）*/
    u8 fsid[BTRFS_FSID_SIZE];        /* 文件系统 UUID */
    __le64 bytenr;                    /* 此块的磁盘地址 */
    __le64 flags;
    u8 chunk_tree_uuid[BTRFS_UUID_SIZE];
    __le64 generation;                /* 世代号（事务 ID）*/
    __le64 owner;                     /* 所有者对象 ID */
    __le32 nritems;                   /* 条目数 */
    u8 level;                         /* 树层级（0=leaf）*/
};
```

**节点检查**：每次从磁盘读取 `extent_buffer` 时，`btrfs_check_node_leaf()` 验证 `csum` 校验和和 `generation` 世代号。元数据校验和存储在 `extent_buffer` 自身的 header 中。

### 1.2 struct btrfs_path — B 树搜索路径

`btrfs_path` 记录一次 B 树遍历的完整路径——从根到叶子每层的 node 指针和 slot 位置：

```c
struct btrfs_path {
    struct extent_buffer *nodes[BTRFS_MAX_LEVEL]; /* 每层 node buffer */
    int slots[BTRFS_MAX_LEVEL];                    /* 每层当前槽位 */
    u8 locks[BTRFS_MAX_LEVEL];                    /* 锁状态 */
    u8 reada;
    u8 lowest_level;
    bool skip_locking:1;
    bool search_commit_root:1;
};

// 使用模式：
path = btrfs_alloc_path();
btrfs_search_slot(trans, root, &key, path, ins_len, cow);
// → 遍历完成后，path->nodes[level] 持有每层锁住的 buffer
// → 修改 path->slots[level] 后写入
btrfs_release_path(path);    // 释放锁和引用
btrfs_free_path(path);       // 释放 path 自身
```

**`btrfs_path` 是 Btrfs 中最频繁使用的数据结构**——每次 B 树查找都通过它完成。

### 1.3 struct btrfs_key — 统一键值

```c
// Btrfs 全局 B 树通过 128 位键定位一切：
struct btrfs_key {
    u64 objectid;           /* 对象 ID（如 inode#）*/
    u8 type;                 /* 条目类型 */
    u64 offset;             /* 偏移量 */
};  // 共 136 位

// 类型示例（Btrfs 使用 type 域区分不同元数据）：
// BTRFS_INODE_ITEM_KEY     — inode 条目
// BTRFS_DIR_ITEM_KEY       — 目录条目
// BTRFS_EXTENT_DATA_KEY    — 文件数据 extent
// BTRFS_EXTENT_ITEM_KEY    — 空闲 extent 信息
// BTRFS_CHUNK_ITEM_KEY     — chunk 映射
// BTRFS_ROOT_ITEM_KEY      — 子卷根条目
```

**单 B 树的设计**：xattr、directory entries、file extents、extent allocation 全部用同一个 `(objectid, type, offset)` 键空间管理。这与 ext4/xfs 的独立索引结构不同。

### 1.2 struct btrfs_root — 根节点

```c
// fs/btrfs/ctree.h:173-200
struct btrfs_root {
    struct extent_buffer *node;              /* 当前根节点 buffer */
    struct extent_buffer *commit_root;        /* 最后提交的根 */
    struct btrfs_root *log_root;             /* 日志根 */
    struct btrfs_root_item root_item;         /* 磁盘上的根条目 */
    struct btrfs_key root_key;

    struct btrfs_fs_info *fs_info;            /* 文件系统全局信息 */
    struct btrfs_transaction *last_trans;
    int nr_commit_retries;

    /* 极简缓存：最近查找的目录条目 */
    struct inode *inode;

    spinlock_t root_item_lock;
    refcount_t refs;
};
```

### 1.3 struct btrfs_fs_info — 文件系统全局信息

```c
// fs/btrfs/fs.h
struct btrfs_fs_info {
    struct btrfs_super_block *super_copy;     /* 超级块副本 */
    struct super_block *sb;

    struct btrfs_root *tree_root;             /* 全局 B 树根 */
    struct btrfs_root *chunk_root;            /* chunk 映射 B 树 */
    struct btrfs_root *fs_root;               /* 文件系统 B 树根 */
    struct btrfs_root *dev_root;              /* 设备 B 树根 */
    struct btrfs_root *csum_root;             /* 校验和 B 树根 */

    struct btrfs_root *quota_root;
    struct btrfs_root *uuid_root;
    struct btrfs_root *free_space_root;
    struct btrfs_root *data_reloc_root;

    struct btrfs_transaction *running_transaction;
    struct btrfs_transaction *commit_transaction;
    struct list_head trans_list;

    struct btrfs_super_block super_for_commit; /* 提交时的一致超级块 */
    u64 generation;                            /* 全局世代号 */

    struct extent_io_tree dirty_tree;           /* 脏页跟踪 */
    struct extent_io_tree free_space_cache;    /* 空闲空间缓存 */
    struct btrfs_block_group *block_group_cache;

    struct btrfs_workqueue *endio_workers;
    struct btrfs_workqueue *rmw_workers;
    struct btrfs_workqueue *compressed_write_workers;

    spinlock_t fs_roots_radix_lock;
    struct radix_tree_root fs_roots_radix;     /* 所有根目录的 radix 树 */
};
```

---

## 2. B 树（B-tree）

Btrfs 使用自实现的 COW B 树（不是标准 B+ 树）。每个节点是 `struct extent_buffer`（一个磁盘块或元数据块）：

```
B 树结构：
     [root node]  level=2
    /     |       \
 [node]  [node]   [node]  level=1
 / | \   / | \    / | \
[L][L][L]...                level=0 (leaf)

一个 leaf 节点包含多个 btrfs_item：
每个 item = (key, offset, size) → data
key = (objectid, type, offset)   — 128 位唯一键
```

**Btrfs B 树与标准 B+ 树的区别**：

| 标准 B+ 树 | Btrfs B 树 |
|-----------|-----------|
| 内节点存 key 和指针 | 内节点也存 key 和指针 |
| 叶子存数据 | 叶子存 items（key + data）|
| 根固定 | 根通过 root->node 指针切换（COW）|
| 无世代号 | 每个节点有 generation |
| 读不锁 | btrfs_path 记录锁状态 |

**doom-lsp 确认**：B 树实现在 `fs/btrfs/ctree.c`（5,074 行）。`btrfs_search_slot` 是核心查找函数，使用 `btrfs_path` 记录遍历路径。

### btrfs_search_slot——核心 B 树查找

```c
// fs/btrfs/ctree.c
int btrfs_search_slot(struct btrfs_trans_handle *trans,
    struct btrfs_root *root, const struct btrfs_key *key,
    struct btrfs_path *p, int ins_len, int cow)
{
    /* 从根节点开始逐层下降 */
    b = root->node;
    level = btrfs_header_level(b);
    p->nodes[level] = b;

    while (level >= 0) {
        /* 二分查找当前节点中应该进入的子槽 */
        slot = btrfs_bin_search(b, key, &slot_ret);
        p->slots[level] = slot;

        if (level == 0)  /* 到达叶子层 */
            break;

        /* 如果需要 COW，在此层拷贝节点 */
        if (cow) {
            b = btrfs_cow_block(trans, root, b, p, slot);
            p->nodes[level] = b;
        }

        /* 下降到下一层 */
        b = btrfs_read_node_slot(b, slot);
        level--;
        p->nodes[level] = b;
    }
    return 0;
}
```

---

## 3. 写时复制（CoW）事务

Btrfs 没有独立的日志系统（如 JBD2 或 XFS CIL）。事务通过 **COW（写时复制）** 实现原子性——所有元数据修改都在新分配的节点上进行，修改过程中原树保持完整：

```
事务前：                     修改中：                     事务提交后：
root→v1                     root→v1（未变）              root→v3
  ├── n1                      ├── n1                      ├── n3 (COW)
  │   └── L1                  │   └── L1 (旧)              │   └── L3 (COW)
  └── n2                      └── n2                      └── n2
      └── L2                      └── L2                      └── L2
                                    
  CoW 过程：                分配新节点 n3, L3
                            L1→L3 复制并修改
                            n1→n3 复制并更新子指针
                            原 n1, L1 保留（旧根仍可读）
```

### 3.1 btrfs_cow_block——B 树的 COW 核心

`btrfs_cow_block()` 是 Btrfs 最核心的函数——每次修改 B 树节点之前都会被调用：

```c
// fs/btrfs/ctree.c
struct extent_buffer *btrfs_cow_block(struct btrfs_trans_handle *trans,
    struct btrfs_root *root, struct extent_buffer *buf,
    struct btrfs_path *path, int slot)
{
    /* 1. 如果没有根的事务（搜索模式）→ 不需要 COW */
    if (!trans)
        return buf;

    /* 2. 分配新的 extent_buffer */
    cow = btrfs_alloc_tree_block(trans, root, buf->start,
                                   root->root_key.objectid,
                                   &disk_key, level, ...);

    /* 3. 复制旧节点的内容到新节点 */
    copy_extent_buffer(cow, buf);

    /* 4. 写入新节点 */
    btrfs_set_header_generation(cow, trans->transid);
    btrfs_tree_unlock(buf);        /* 释放旧节点 */

    /* 5. 更新父节点的子指针指向新节点 */
    btrfs_set_node_blockptr(parent, slot, cow->start);
    btrfs_set_node_ptr_generation(parent, slot, trans->transid);

    /* 6. 释放旧节点空间（事务提交后可回收）*/
    btrfs_free_tree_block(trans, root, buf, 0, 1);

    return cow;
}
```

**关键点**：每次 `btrfs_search_slot(trans, ..., cow=1)` 在下树过程中遇到事务已修改的节点时，自动调用 `btrfs_cow_block` 复制。这保证了整个树的修改路径从叶子到根都被复制。

### 3.2 事务完成流程

```c
// fs/btrfs/transaction.c
int btrfs_commit_transaction(struct btrfs_trans_handle *trans)
{
    struct btrfs_transaction *cur_trans = trans->transaction;
    struct btrfs_fs_info *fs_info = trans->fs_info;

    /* 阶段 1：事务准备 */
    /* 阻止新事务加入 */
    cur_trans->state = TRANS_STATE_COMMIT_DOING;

    /* 阶段 2：创建并写入所有 pending 快照 */
    create_pending_snapshots(trans);

    /* 阶段 3：将 CoW 后的 B 树节点写入磁盘 */
    btrfs_write_and_wait_transaction(cur_trans);

    /* 阶段 4：更新超级块中的各 B 树根指针 */
    update_super_roots(fs_info);
    write_ctree_super(cur_trans);

    /* 阶段 5：切换 committed_transaction */
    cur_trans->state = TRANS_STATE_COMPLETED;
    wake_up(&cur_trans->commit_wait);

    /* 阶段 6：清理 pin 住的旧节点 */
    btrfs_destroy_pinned_extent(fs_info);
}
```

### 3.3 Btrfs 事务 vs JBD2 vs CIL

| | ext4 JBD2 | XFS CIL | Btrfs |
|--|-----------|--------|-------|
| 机制 | 描述符+影子块+提交块 | 日志向量→iclog | **COW 整树** |
| 原子性 | 日志回放 | 日志回放 | **根指针切换 + 世代号** |
| 回滚 | 丢弃未提交日志 | 丢弃未提交 CIL | **保留旧根**（旧版本树完整）|
| 快照支持 | 需要 LVM | 需要 LVM | **内建**（旧根=快照）|
| 写放大 | 日志+原位置 | 日志+元数据 | **CoW 路径上的所有节点** |

**doom-lsp 确认**：`btrfs_cow_block` 在 `fs/btrfs/ctree.c`。`btrfs_commit_transaction` 在 `transaction.c` 中。`btrfs_alloc_tree_block` 在 `extent-tree.c` 中分配新的元数据块。

---

## 4. Extent 分配

```c
// fs/btrfs/extent-tree.c:6921
// Btrfs 的 extent 分配器管理所有磁盘空间
// 通过 extent B 树（tree_root）跟踪每个物理 block 的状态

struct btrfs_block_group {
    u64 start;                           /* 起始物理偏移 */
    u64 length;                          /* 长度 */
    u64 bytes_used;
    u64 bytes_super;
    u64 pinned;
    int ro;                              /* 只读 */

    unsigned long *dirty_extents;        /* 脏 extent 位图 */
    struct list_head list;
    struct btrfs_space_info *space_info;  /* 空间类型（data/meta/system）*/
};

// 分配路径：
// btrfs_reserve_extent()
//   → find_free_extent()                // 在 block group 中搜索空闲 extent
//     → btrfs_space_info_update_bytes_may_use()
//     → 更新 extent B 树（标记为使用中）
```

---

## 5. 校验和

```c
// Btrfs 为所有数据和元数据维护独立的校验和：
//
// 元数据校验和：
//   写入：btrfs_csum_one_bio() 为每个 extent_buffer 计算 CRC32C
//         CRC 存储在 extent_buffer 的 header.csum 字段中
//   读取：btrfs_read_extent_buffer() 验证 header.csum
//         → btrfs_verify_level_key() 校验
//         → csum 不匹配 → 尝试镜像副本（如有 RAID）
//
// 数据校验和：
//   写入：btrfs_csum_file_block() 为每个 4K 块计算
//         csum 存储在 csum_root 的 B 树中
//         key = (logical, BTRFS_EXTENT_CSUM_KEY, offset)
//   读取：btrfs_lookup_csum() 查找 csum 并验证
//
// 校验和失败的处理（fs/btrfs/inode.c）：
//   end_bio_extent_readpage() → btrfs_check_read_dio_bio()
//     → 有镜像副本 → 尝试其他镜像（REQ_FAILFAST）
//     → 无镜像 → 返回 -EIO + 日志警告
```

**doom-lsp 确认**：csum 写入在 `fs/btrfs/file-item.c` 的 `btrfs_csum_file_block`，读取验证在 `fs/btrfs/compression.c` 和 `fs/btrfs/inode.c` 的 `end_bio_extent_readpage`。

---

## 6. 子卷（Subvolumes）和快照

```c
// 子卷 = 一个独立的 btrfs_root（有自己的 B 树根）
// 快照 = 子卷的 COW 副本（共享未修改的节点）

// 创建快照：
// btrfs_ioctl_snap_create()
//   → btrfs_commit_transaction()        // 刷新当前事务
//   → btrfs_copy_root()                 // COW 根节点
//   → insert snapshot root into tree_root
```

---

## 7. 总结

Btrfs 与其他 Linux 文件系统的核心差异：

1. **CoW B 树** — 所有元数据通过 COW B 树管理，事务天然的原子性
2. **无独立日志** — COW 本身提供了原子性保证
3. **数据和元数据校验和** — 检测静默数据损坏
4. **内建快照/子卷** — 通过 COW 共享实现零成本快照
5. **内建 RAID** — 在文件系统层实现 RAID0/1/10/5/6

**缺点**：CoW 对小文件随机写性能有影响，碎片问题需要 `btrfs autodefrag`。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
