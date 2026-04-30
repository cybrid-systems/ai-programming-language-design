# ext4 / journal — 日志文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/ext4/` + `fs/jbd2/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**ext4** 是 ext3 的演进，提供：
- **日志（Journal）**：通过 JBD2 确保崩溃一致性
- **extent**：替代块映射（存储连续块范围）
- **延迟分配**：优化磁盘布局

---

## 1. ext4 超级块

### 1.1 ext4_super_block

```c
// include/trace/events/ext4.h — ext4_super_block
struct ext4_super_block {
    __le32          s_blocks_count;      // 块数
    __le32          s_blocks_count_hi;   // 高位
    __le32          s_r_blocks_count;     // 保留块数
    __le32          s_free_blocks_count; // 空闲块数

    char            s_volume_name[16];    // 卷名
    __le64          s_journal_inode;     // 日志 inode 号
    __le64          s_journal_dev;       // 日志设备

    // 日志
    __le32          s_journal_start;     // 日志起始块
    __le32          s_journal_length;    // 日志长度

    // 特性
    __le32          s_feature_incompat;   // 不兼容特性
    //   EXT4_FEATURE_INCOMPAT_RECOVER   (需要恢复)
    //   EXT4_FEATURE_INCOMPAT_EXTENTS   (使用 extent)
    //   EXT4_FEATURE_INCOMPAT_64BIT     (64 位块号)
};
```

### 1.2 ext4_inode — inode

```c
// fs/ext4/ext4.h — ext4_inode
struct ext4_inode {
    __le16          i_mode;              // 文件模式
    __le16          i_uid;               // UID
    __le32          i_size_lo;           // 大小（低 32 位）
    __le32          i_atime;             // 访问时间
    __le32          i_ctime;             // 修改时间
    __le32          i_mtime;             // 元数据修改时间
    __le32          i_dtime;             // 删除时间
    __le16          i_gid;               // GID
    __le16          i_links_count;       // 硬链接数
    __le32          i_blocks_lo;          // 块数（低）
    __le32          i_flags;             // EXT4_* 标志
    __le64          i_blocks_hi;         // 块数（高）

    // extent（代替间接块）
    struct ext4_extent_header {
        __le16      eh_magic;           // 0xF30A
        __le16      eh_entries;         // extent 数量
        __le16      eh_max;             // 最大条目数
        __le16      eh_depth;          // depth（0=叶子，>0=内部节点）
        __le32      eh_generation;      // 生成号
    } i_extents;

    // 如果 depth > 0，使用 i_data[0] 作为 ext4_extent_idx（内部节点）
    // 如果 depth = 0，使用 i_data[0] 作为 ext4_extent（叶子）
};
```

---

## 2. JBD2 日志

### 2.1 journal_superblock — 日志超级块

```c
// fs/jbd2/journal.h — journal_superblock
struct journal_superblock_t {
    // 标识
    __be32          s_header_type;       // JBD2_MAGIC_NUMBER
    __be32          s_block_type;        // JBD2_SUPERBLOCK_V{2,3}
    __be32          s_sequence_number;    // 日志序列号

    // 块信息
    __be32          s_first;             // 日志第一个块
    __be32          s_max_len;           // 日志最大长度
    __be32          s_nr_users;          // 使用此日志的文件系统数

    // 检查点
    __be32          s_start;             // 日志数据开始（commit block 后）
    __be32          s_errno;             // 错误码

    // 恢复
    __be32          s_features;          // 特性
    unsigned char   s_uuid[16];          // UUID
};
```

### 2.2 transaction — 事务

```c
// fs/jbd2/transaction.c — transaction
struct transaction {
    tid_t               t_tid;            // 事务 ID
    unsigned int        t_state;         // T_*

    // 缓冲区
    struct journal_head *t_buffers;      // 头缓冲区链表
    struct journal_head *t_sync_datalist; // 同步的数据
    struct journal_head *t_forget;       // 不需要恢复的缓冲区
    struct journal_head *t_shadow_list;   // 正在提交的缓冲区

    // 锁
    spinlock_t          t_lock;
    atomic_t            t_updates;
    atomic_t            t_handle_count;
};
```

### 2.3 日志流程

```c
// fs/jbd2/transaction.c — journal_start
handle_t *journal_start(struct super_block *sb)
{
    // 1. 分配 handle（事务中的操作）
    handle_t *handle = journal_alloc_handle(JBD2_UNSAFE_GIVECREDITS);

    // 2. 开始新事务（或加入现有事务）
    tid_t tid = transaction->t_tid;

    // 3. 返回 handle，用于后续 journal_dirty_metadata()
    return handle;
}

// journal_dirty_metadata(handle, buffer_head)
// → 将缓冲区加入当前事务的日志
```

---

## 3. 日志恢复

```c
// fs/jbd2/recovery.c — journal_recover
int journal_recover(journal_t *journal)
{
    // 1. 读取日志超级块
    jsb = journal->j_superblock;

    // 2. 从 s_start 开始扫描日志
    for (block = journal->j_first; block < journal->j_last; block++) {
        // 3. 读取块
        bh = bread(journal->j_dev, block);

        // 4. 如果是 commit block（type = JBD2_COMMIT_BLOCK）
        if ( Descriptor->h_blocktype == JBD2_COMMIT_BLOCK) {
            // 5. 重放该事务中的所有操作
            replay_transaction(journal, descriptor);
        }

        if (bh->b_state == 0)
            break;  // 日志结束
    }

    // 6. 更新日志超级块的序列号
    jsb->s_sequence_number++;

    return 0;
}
```

---

## 4. extent 树

### 4.1 ext4_extent — extent 条目

```c
// fs/ext4/ext4.h — ext4_extent
struct ext4_extent {
    __le32          ee_block;            // 起始逻辑块号
    __le16          ee_len;              // 长度（blocks）
    __le16          ee_start_hi;         // 起始块号（高 16 位）
    __le32          ee_start_lo;         // 起始块号（低 32 位）
};

// 例如：extent { ee_block=0, ee_len=1000, ee_start=2048 }
// 表示逻辑块 0-999 → 物理块 2048-3047（连续）
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/ext4/ext4.h` | `struct ext4_inode`、`struct ext4_extent` |
| `fs/jbd2/journal.h` | `struct journal_superblock_t` |
| `fs/jbd2/transaction.c` | `journal_start`、`journal_dirty_metadata` |
| `fs/jbd2/recovery.c` | `journal_recover` |