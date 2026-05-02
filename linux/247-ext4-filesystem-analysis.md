# 247-ext4-filesystem-analysis — ext4 文件系统深度分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行符号解析与代码追踪
> 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

ext4（第四扩展文件系统）是 Linux 最主流的通用文件系统，从 ext3 演进而来，2006 年合并入主线内核。ext4 在 ext3 基础上引入了**extent 映射**（替代传统的间接块映射）、**延迟分配**（delayed allocation）、**块组descriptor校验**、**快速 fsck** 等关键改进，在性能、可扩展性和可靠性上全面提升。

本文以 `fs/ext4/inode.c`（6,826 行）、`fs/ext4/mballoc.c`（7,283 行）、`fs/ext4/super.c`（7,606 行）为核心，结合 `ext4_extents.h` 和 `fs/ext4/extents.c`，逐模块深度解析 ext4 的核心设计。

---

## 1. inode 与 extent——数据存储的组织方式

### 1.1 ext4 inode 的 i_data 结构

ext4 inode 大小默认为 256 字节（在 super block 的 `s_inode_size` 字段），包含一个 60 字节的 `i_data[60]` 数组。对于使用 extent 的普通文件，这 60 字节的结构如下：

```
┌──────────────────────────────────────────────────────────┐
│ i_data[60]                                               │
├──────────────────┬───────────────────────────────────────┤
│ ext4_extent_header (12B)  │  ext4_extent[4] (48B)          │
└──────────────────┴───────────────────────────────────────┘
```

即前 12 字节存储 `struct ext4_extent_header`，后 48 字节（4 个 extent 条目）用于直接存储小文件的 extent 信息——**无需任何间接块**，在 inode 自身内部即可定位最多 4 个 extent。

对于更大的文件，extent 信息存储在专门的 extent block 中，inode 的 `i_data` 变为 extent 树的第一层索引节点。

**doom-lsp 确认**：`ext_inode_hdr()` 将 `EXT4_I(inode)->i_data` 转换为 `struct ext4_extent_header *`。

### 1.2 核心数据结构

**ext4_extent（12 字节）**——磁盘上的 extent 条目：

```c
// ext4_extents.h
struct ext4_extent {
    __le32  ee_block;    /* 覆盖的起始逻辑块号 */
    __le16  ee_len;      /* 覆盖的块数（最大 32768） */
    __le16  ee_start_hi; /* 物理块号高 16 位 */
    __le32  ee_start_lo; /* 物理块号低 32 位 */
};
```

物理块号由 `ee_start_lo`（低 32 位）和 `ee_start_hi`（高 16 位）拼接而成，最大支持 48 位物理块号（理论上支持 1EB 文件系统）。

**MSB 标记 unwritten extent**：如果 `ee_len` 的最高位被设置（即 `ee_len > 0x8000`），则为 unwritten extent（预分配但未写入数据的extent）。`EXT_INIT_MAX_LEN = 0x8000` 是这个分界线的值。

**ext4_extent_idx（12 字节）**——extent 树中间节点索引：

```c
struct ext4_extent_idx {
    __le32  ei_block;     /* 此索引覆盖的起始逻辑块号 */
    __le32  ei_leaf_lo;   /* 下一层物理块号（低 32 位） */
    __le16  ei_leaf_hi;   /* 下一层物理块号（高 16 位） */
    __le16  ei_unused;
};
```

**ext4_extent_header（12 字节）**——每个 extent block 的头部：

```c
struct ext4_extent_header {
    __le16  eh_magic;    /* 0xf30a，magic 验证 */
    __le16  eh_entries;  /* 有效条目数 */
    __le16  eh_max;      /* 最大条目容量 */
    __le16  eh_depth;    /* 树的深度（0=叶子，1+=索引层） */
    __le32  eh_generation;
};
```

### 1.3 extent 树组织——为什么用 extent？

ext4 用 extent 替代 ext2/3 的间接块映射，核心优势是**减少元数据开销**并**加速顺序读写**。

**间接块的问题**：假设文件占用 100,000 个块，ext3 需要分配数百个间接块来记录所有块号，每个间接块 4KB 可记录 1024 个块号。元数据块数量庞大，随机访问和磁盘布局都很糟糕。

**extent 的解决方案**：一个 extent 描述一段连续物理块，一个 `ee_len` 字段就能覆盖最多 32,768 个连续块（16KB 起始块号 + 128MB 长度）。对于大多数连续文件，**一个 extent 就能覆盖整个文件**。

extent 树是一棵 B-tree-like 结构：

- **叶子节点**：存储 `struct ext4_extent`，每个 extent 描述一段连续物理块
- **索引节点**：存储 `struct ext4_extent_idx`，指向下一层节点
- **深度限制**：`EXT4_MAX_EXTENT_DEPTH = 5`，足够覆盖任何文件大小
- **叶子节点extent block校验**：`struct ext4_extent_tail` 在 extent block 末尾存储 CRC32C 校验码

extent 树根节点可以直接存在 inode 的 `i_data[60]` 中（深度 0），无需额外的间接块。

### 1.4 ext4_ext_path——extent 查找路径

```c
struct ext4_ext_path {
    ext4_fsblk_t         p_block;    /* 该节点所在的物理块号 */
    __u16                p_depth;    /* 该节点的深度 */
    __u16                p_maxdepth;
    struct ext4_extent   *p_ext;     /* 指向当前覆盖范围的 extent（叶子层） */
    struct ext4_extent_idx *p_idx;   /* 指向当前索引（索引层） */
    struct ext4_extent_header *p_hdr;/* 指向该节点的 extent_header */
    struct buffer_head   *p_bh;      /* 该节点对应的 buffer_head */
};
```

`ext4_find_extent()` 是核心查找函数：从 inode 出发，逐层沿索引节点下降到叶子，找到覆盖指定逻辑块号的 extent。返回的 `ext4_ext_path[]` 数组记录了从根到叶子的完整路径。

路径数组的使用模式：
```c
path = ext4_find_extent(inode, map->m_lblk, NULL, flags);
// ... 使用 path 中每层的 p_hdr/p_idx/p_ext 进行操作 ...
ext4_ext_release_path(path);
```

extent 树分裂（split）是最复杂的操作：当叶子节点已满需要插入新 extent 时，沿路径逐层分裂，重构路径中的索引节点，并可能增加树的深度。

### 1.5 extent 与 i_disksize

`EXT4_I(inode)->i_disksize` 记录文件的逻辑大小（已分配并确认写入的字节数）。extent 树的 `ee_block + ee_len` 反映的是实际分配的物理块范围，而 `i_disksize` 是文件截断/写入时的权威边界。

在 `ext4_ext_insert_extent()` 成功后，会更新 `i_disksize`：
```c
EXT4_I(inode)->i_disksize = inode->i_size;
```
对于延迟分配（delayed allocation）场景，`i_disksize` 的更新和 extent 的实际分配可以分开进行。

---

## 2. mballoc——多级块分配器

ext4 的块分配器（mballoc）是其性能优势的核心来源之一，采用**Buddy算法的变体**配合**预分配机制**，支持延迟分配和流式分配等多种优化策略。

### 2.1 入口：ext4_mb_new_blocks

```c
// mballoc.c:6229
ext4_fsblk_t ext4_mb_new_blocks(handle_t *handle,
                struct ext4_allocation_request *ar, int *errp)
```

分配流程分四个阶段：

**阶段一：配额检查和预留空间验证**
```c
while (ar->len && ext4_claim_free_clusters(sbi, ar->len, ar->flags))
    cond_resched(), ar->len = ar->len >> 1;  // 减半重试
```
配额通过 dquot 写入，不是 mballoc 自身的逻辑。

**阶段二：尝试使用预分配空间（PA）**
```c
ac = ext4_mb_initialize_context(ac, ar);
if (!ext4_mb_use_preallocated(ac)) {
    // 预分配未命中，走常规分配
    ext4_mb_normalize_request(ac, ar);   // 范围对齐、拆分
    ext4_mb_regular_allocator(ac);        // Buddy 算法分配
}
```

**阶段三：Buddy 分配器 `ext4_mb_regular_allocator`**

`mballoc.c:3001` 的核心分配逻辑，按优先级尝试：

1. **`CR_GOAL_LEN_FAST`**：先尝试目标组（goal group），查找接近目标地址的最佳匹配
2. **`CR_GOAL_LEN_SLOW`**：放宽限制，扫描更多组
3. **`CR_BEST_AVAIL`**：贪心策略，扫描所有组找最大可用块
4. **`CR_ALIGNED`**：已对齐模式，寻找完全对齐的块

每个组内用 **Buddy 算法**：将空闲块按 2^n 大小的块组（buddy chunk）管理，用位图标记每个块的分配状态。

**阶段四：标记磁盘空间使用**
```c
if (ac->ac_status == AC_STATUS_FOUND)
    ext4_mb_mark_diskspace_used(ac, handle);  // 修改块组位图 + 日志
```

### 2.2 预分配与回收机制

**预分配（Preallocation，PA）**

ext4 支持延迟分配的预分配：写入数据时先分配extent但不完全使用，剩余部分作为 PA 保留供后续写入使用。

关键数据结构：
- **per-inode PA rbtree**（`struct ext4_inode_info::i_prealloc_lock`）：每个文件维护自己的预分配树，以 `pa_lstart`（逻辑起始块）排序
- **per-group PA list**：每个块组的 `bb_prealloc_list`

`ext4_mb_use_preallocated()` 的查找逻辑：
1. 先在 inode 的 PA rbtree 中查找逻辑地址相邻的预分配块
2. 再在块组的 PA list 中查找
3. 检查物理地址连续性（`pa_pstart + offset` 与请求的 `ac_g_ex` 对齐）

预分配块的回收在以下时机触发：
- `ext4_mb_discard_preallocations_should_retry()`：分配失败时丢弃部分 PA 重试
- `ext4_mb_pa_put_free()`：PA 使用后剩余部分放回 buddy
- inode 销毁时：所有关联 PA 归还 buddy

### 2.3 块组结构（Block Group）

ext4 将磁盘划分为块组（block group），每个块组大小通常为 128MB（`s_blocks_per_group * block_size`）。每个块组有：

```
┌────────────────────────────────────────────┐
│  Super Block (副本)   ← 只在块组 0 或 sparse_super 激活的组  │
├────────────────────────────────────────────┤
│  Group Descriptors (备份)                   │
├────────────────────────────────────────────┤
│  Data Block Bitmap                          │
├────────────────────────────────────────────┤
│  Inode Bitmap                               │
├────────────────────────────────────────────┤
│  Inode Table                                │
├────────────────────────────────────────────┤
│  Data Blocks                               │
└────────────────────────────────────────────┘
```

块组 descriptor 存储在 `struct ext4_group_desc` 中，包含：
- `bg_block_bitmap`：数据块位图的块号
- `bg_inode_bitmap`：inode 位图的块号
- `bg_inode_table`：inode 表的起始块号
- `bg_free_blocks_count`、`bg_free_inodes_count`、`bg_used_dirs_count`

从 Linux 4.5 起，支持 **meta block group**，将元数据（位图、inode表）放在同一个块组内，进一步减少寻道。

---

## 3. JBD2 日志——原子性与一致性保证

ext4 的日志机制由独立的 JBD2 层实现，inode.c 中通过 `ext4_journal_start()` / `ext4_journal_stop()` 对 `jbd2_journal_start()` / `jbd2_journal_stop()` 的调用嵌入到每个元数据写操作中。

### 3.1 handle——事务句柄

```c
struct handle_s {
    int h_ref;
    int h_err;
    unsigned int h_sync:1;        // 需要同步等待
    unsigned int h_jdata:1;      // 日志数据（非仅元数据）
    unsigned int h_aborted:1;
    struct transaction_s *h_transaction;
    int h_buffer_credits;        // 本 handle 预分配的 buffer 修改名额
    int h_revoke_credits;
};
```

每次 ext4 元数据操作（如 `ext4_write_begin`）调用 `ext4_journal_start()` 创建一个 handle，handle 与当前事务（transaction）绑定。`h_buffer_credits` 是关键：预分配了可修改的 buffer 数量上限，保证事务不会超出日志空间。

### 3.2 ext4_writepage 与 jbd2 的协作

`ext4_writepage()` 在 `inode.c:1351`：
```c
handle = ext4_journal_start(inode, EXT4_HT_WRITE_PAGE, needed_blocks);
if (IS_ERR(handle))
    return PTR_ERR(handle);
ret = ext4_block_write_begin(page, pos, len, __ext4_journalled_writepage);
if (ret)
    unlock_page(page);
else
    ret = ext4_journal_stop(handle);
```

注意 `ext4_journal_stop()` 的语义：它**不立即提交事务**，只是释放 handle 对当前事务的引用，将 buffer 标记为已加入待提交列表。事务的真正提交（`jbd2_journal_commit_transaction()`）由独立的 `kjournald2` 内核线程定期执行，或在以下时机触发：
- handle 的 `h_sync` 标志置位（fsync 时）
- 日志区域即将写满时

### 3.3 日志三阶段提交

JBD2 使用严格的三阶段提交协议：

**阶段一：缓冲写入选中**（Handle 开始）
- `jbd2_journal_start()` → 获取 handle，加入当前 `RUNNING` 状态的事务
- 元数据 buffer 通过 `jbd2_journal_get_write_access()` 和 `jbd2_journal_dirty_metadata()` 加入事务的 `t_buffers` 链表

**阶段二：日志块写入**（事务提交）
- `jbd2_journal_commit_transaction()` 在 `kjournald2` 上下文中执行
- 扫描 `t_buffers` 链表，将每个修改过的 metadata buffer 写入日志区域（journal log）
- 所有日志块写完后，写入**提交块**（commit block，`JBD2_COMMIT_BLOCK`），内含事务 ID（tid）
- 提交块写入完成 = 事务已持久化到日志

**阶段三：回写（Checkpoint）**
- 后续 `jbd2_log_do_checkpoint()` 将日志中的元数据块写回最终磁盘位置
- checkpoint 完成后，这些日志块即可被后续事务覆盖

### 3.4 崩溃恢复流程

重启时 `jbd2_recover()` 读取日志区域：
1. 找到最后一个有效的提交块
2. 按事务 ID 顺序重放（replay）每个已提交但未 checkpoint 的事务
3. 重放操作是幂等的——如果数据已写回，重复应用不会有问题

**ext4 vs ext3 的关键差异**：ext3 日志和数据可以并发写入，而 ext4 在 `data=ordered` 模式下保证元数据日志条目对应的数据块**先于元数据本身写入磁盘**（通过 `jbd2_journal_flush()` 机制）。这个顺序保证使得崩溃后日志回放时不会读到部分写入的数据。

---

## 4. 目录与 htree 索引

ext4 的目录使用 **htree（扩展目录索引）**，是 B-tree 的变体，专门为目录场景优化，提供 `O(log n)` 的文件名查找而非线性扫描。

### 4.1 htree 的启用条件

`is_dx_dir()` 检查目录是否启用 htree（磁盘格式上通过 inode 的 `EXT4_INDEX_FL` 标志）：
- 新建目录默认启用 htree
- `mount -o noextent` 时以线性格式创建目录
- 小目录（block 数内可容纳所有条目）可能退化为线性扫描

### 4.2 htree 的两层结构

htree 目录实际使用两种节点：

**根节点（dx_root）**：存储在目录文件的第一个 block 中
```c
struct dx_root {
    __le32 dot_gen_bitfield;  // dotdot + hash algorithm info
    char bullet[12];           // ".";
    struct ext4_dir_entry_2 dot;
    char bullet2[12];          // "..";
    struct ext4_dir_entry_2 dotdot;
    struct dx_entry entries[...];  // 第一层 hash → block 映射
    char dummy[12];
    struct dx_tail info;       // 含 hash 版本信息
};
```

**内部节点（dx_node）**：存储 hash 范围到子 block 的映射
```c
struct dx_node {
    __le32 fake;
    struct ext4_dir_entry_2 fake_dot;
    struct dx_entry entries[...];  // hash → block 映射
    struct dx_tail info;
};
```

**叶子节点**：就是普通的目录 block，包含 `struct ext4_dir_entry_2` 条目，每个条目存储文件 inode 号、名称、文件类型等。

### 4.3 ext4_find_entry 查找路径

`ext4_find_entry()` 在 `dir.c` 中的查找路径：
```c
if (is_dx_dir(inode)) {
    err = ext4_dx_readdir(file, ctx);
    // → ext4_htree_fill_tree() → 遍历 htree
} else {
    // 线性扫描目录 block，找到返回 struct ext4_dir_entry_2
    ret = search.dir = ext4_find_entry(...);
}
```

`ext4_dx_readdir()` 使用 `ctx->pos` 作为 htree 遍历的状态：
- `pos = 0`：从头开始（第一个叶子 block）
- `pos = htree_eof`：遍历结束
- 中间值：hash 树中的当前 hash 位置

`ext4_htree_fill_tree()` 内部使用 `htree_hash` 计算文件名 hash，然后在 htree 的索引节点中二分查找目标 block，最后在叶子 block 中线性搜索文件名。

### 4.4 hash 算法演进

ext4 支持多种目录 hash 算法（通过 `dx_tail.info` 中的 hash 版本标识）：
- **legacy**：初始算法（hash 碰撞较多）
- **half_md4**：改进的 MD4 变体
- **tea**：柯克-麦卡勒斯特算法（已被发现存在弱点）
- **siphash**：现代算法，从 Linux 4.20 起使用，更强的抗碰撞性

---

## 5. 配额（Quota）与 inode 关联

ext4 原生支持 POSIX quota，inode 通过 `struct ext4_inode_info` 中的 `i_dquot[EXT4_MAXQUOTAS]` 数组关联配额信息。

### 5.1 核心数据结构

```c
// super.c:1633
static const struct dquot_operations ext4_quota_operations = {
    .write_dquot     = ext4_write_dquot,
    .acquire_dquot   = ext4_acquire_dquot,
    .release_dquot   = ext4_release_dquot,
    .mark_dirty      = ext4_mark_dquot_dirty,
    .alloc_dquot     = dquot_alloc,
    .destroy_dquot   = dquot_destroy,
    .get_next_id     = dquot_get_next_id,
};

// super.c:1628
static struct dquot __rcu **ext4_get_dquots(struct inode *inode)
{
    return EXT4_I(inode)->i_dquot;
}
```

`EXT4_MAXQUOTAS = 2`（user quota + group quota），`i_dquot[2]` 数组分别存储两种配额的 dquot 指针。

### 5.2 配额操作流程

**分配块时的配额检查**：
```c
// mballoc.c 分配路径
dquot_alloc_block(ar->inode, EXT4_C2B(sbi, ar->len));
```

**日志集成**：配额修改通过 `jbd2_journal_start()` 的 `EXT4_HT_QUOTA` 类型 handle 保护，确保配额变更本身被原子地记录到日志。

**配额文件**：配额信息不存储在 ext4 元数据中，而是存储在独立的 quota 文件（通过 `quota_on` 挂载选项指定）。`ext4_quota_read()` / `ext4_quota_write()` 通过 VFS 层访问这些文件。

**orphan inode 与配额恢复**：`super.c` 中的 orphan list（未完整关闭的 inode 链表）在 `ext4_orphan_cleanup()` 时也会触发相关 dquot 释放。

### 5.3 ext4_quota_enable 与配额初始化

```c
// super.c:1625
static int ext4_quota_enable(struct super_block *sb, int type,
                             int format_id, unsigned int flags)
```

配额子系统在 mount 时通过 `ext4_fill_super()` 中的 `ext4_quotas_on()` 初始化，将 quota 文件 inode 与 quota 类型关联。

---

## 6. 快速 fsck——ext4 vs ext3 的核心差异

ext4 的 fsck 速度比 ext3 快 2~10 倍，原因是多方面的设计改进，并非单一优化。

### 6.1 super.c 中的快速 fsck 相关特性

**1. Sparse Super（稀疏超级块）**

ext4 的 super block 副本只存储在少数块组（0, 1, 以及 3^k、5^k、7^k 幂次块组），而非每个块组都备份。相比 ext3 的每个块组备份，极大减少了需要读取的 super block 副本数量。

**2. 元数据校验（Metadata Checksums）**

ext4 使用 CRC32C 对元数据进行校验：
- extent block 的 `ext4_extent_tail.et_checksum`
- block group descriptor 的 `bg_block_csum` / `bg_inode_csum`
- journal super block 的 s_checksum

`e2fsck` 可以利用这些校验码**跳过已知正确的块**，而无需完整扫描验证每个块的内容。ext3 没有这个特性，所有元数据必须逐块读取和验证。

**3. 延迟 inode 表初始化（Lazy ITB Init）**

ext4 支持 `lazy_itable_init` 选项，在格式化时只初始化 inode 位图而不初始化 inode 表内容。`e2fsck` 可以**只检查已分配的 inode**（从 inode 位图可知），忽略未使用的 inode 表块——这在创建大文件系统时效果显著。

### 6.2 ext3 fsck 必须做什么

ext3 的 fsck 在崩溃恢复时必须：
1. 逐块扫描所有数据块位图，确认每个块组的状态
2. 验证每个 inode 的链接计数（directory entry → inode 遍历）
3. 对 orphan inode 链表逐项追踪
4. 检查所有 directory entry 的一致性（父目录引用等）

### 6.3 ext4 的 e2fsck 额外优化

**Pass 1 优化**：ext4 的 extent 树结构使 `e2fsck` 能更快地遍历文件的所有块——extent 链表比 ext3 的间接块链短得多。

**Pass 4 优化**：链接计数的修正，ext4 的 inode 编号更紧凑（extent 文件的 inode 空间连续性更好）。

**orphan inode 优化**：`super.c:1163` 的 orphan list 机制使 e2fsck 只需遍历 orphan 链表而非全量 inode 扫描。对于 large sparse 文件，这个差异尤为明显。

---

## 7. 逻辑串联——从写文件到磁盘的完整路径

理解 ext4 的关键是将以上模块串联成完整的 I/O 路径：

```
应用 write()
  → VFS generic_file_write_iter()
    → ext4_da_write_begin()           # 延迟分配路径
         ↘ ext4_journal_start()        # 获取 handle
    → ext4_da_map_blocks()             # extent 树查找 + 新块分配请求
         ↘ ext4_find_extent()         # 在 extent 树中定位逻辑块
         ↘ ext4_mb_new_blocks()        # 调用 mballoc
              ↘ ext4_mb_use_preallocated()  # 尝试 PA
              ↘ ext4_mb_regular_allocator() # Buddy 分配
         ↘ ext4_ext_insert_extent()    # 更新 extent 树（可能触发分裂）
    → ext4_da_write_end()              # 更新 i_disksize，标记 dirty
         ↘ ext4_journal_stop()        # 释放 handle（buffer 加入待提交）
```

**后台提交线程（kjournald2）**定期执行：
```
jbd2_journal_commit_transaction()
  → 将 dirty buffer 写入日志区
  → 写入 commit block（事务 ID）
  → jbd2_log_do_checkpoint() 回写到最终位置
```

**文件系统同步（fsync）**时：
```
ext4_sync_file()
  → jbd2_journal_wait_commpletion()   # 等待本文件相关事务提交
  → ext4_write_inode()                # 强制 inode 写入
```

---

## 8. 关键数据结构速查

| 结构 | 文件 | 用途 |
|------|------|------|
| `struct ext4_extent` | ext4_extents.h | 叶子 extent，描述连续物理块 |
| `struct ext4_extent_idx` | ext4_extents.h | 索引节点，跳转到下层 |
| `struct ext4_extent_header` | ext4_extents.h | 每个 extent block 头部 |
| `struct ext4_ext_path` | ext4_extents.h | extent 树遍历路径 |
| `struct ext4_prealloc_space` | mballoc.c | 预分配空间条目 |
| `struct ext4_allocation_context` | mballoc.c | 分配请求上下文 |
| `struct handle_s` | jbd2.h | 日志事务句柄 |
| `struct transaction_s` | jbd2.h | 日志事务 |
| `struct ext4_dir_entry_2` | ext4.h | 目录条目 |
| `struct dx_root/dx_node` | dir.c | htree 目录索引节点 |

---

## 9. 源码位置总结

| 模块 | 核心函数 | 源码位置 |
|------|---------|---------|
| extent 查找 | `ext4_find_extent()` | extents.c:886 |
| extent 插入 | `ext4_ext_insert_extent()` | extents.c:1992 |
| extent 分裂 | `ext4_split_convert_extents()` | extents.c:3816 |
| 块分配入口 | `ext4_mb_new_blocks()` | mballoc.c:6229 |
| Buddy 分配器 | `ext4_mb_regular_allocator()` | mballoc.c:3001 |
| 预分配查找 | `ext4_mb_use_preallocated()` | mballoc.c:4876 |
| 写页 | `ext4_writepage()` → `ext4_block_write_begin()` | inode.c:1170+ |
| 目录查找 | `ext4_find_entry()` / `ext4_dx_readdir()` | dir.c:557 |
| 日志 handle | `jbd2_journal_start/stop()` | jbd2/transaction.c |
| 配额获取 | `ext4_get_dquots()` | super.c:1628 |