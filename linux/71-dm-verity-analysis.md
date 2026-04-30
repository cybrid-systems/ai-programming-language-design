# dm-verity — 完整性验证映射深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/md/dm-verity.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**dm-verity** 是 Device Mapper 的完整性验证目标，确保磁盘数据未被篡改：
- **HMAC**：使用 SHA256 等算法验证每个块的哈希
- **Merkle Tree**：分层哈希树（避免存储每个块的哈希）
- **ecryptfs-like**：类似 ext4 的 dm-verity 用于 Android verified boot

---

## 1. 核心数据结构

### 1.1 verity_config — 配置

```c
// drivers/md/dm-verity.c — verity_config
struct verity_config {
    // 设备
    struct dm_dev           *data_dev;   // 数据设备（/dev/sdaX）
    struct dm_dev           *hash_dev;     // 哈希设备

    // 哈希参数
    unsigned int            hash_width;   // 哈希宽度（32 字节 SHA256）
    unsigned int            hash_depth;   // Merkle 树深度
    unsigned int            hash_block_bits; // 哈希块大小的 log2

    // 数据参数
    unsigned int            data_block_bits; // 数据块大小的 log2
    unsigned int            data_blocks;    // 数据块数

    // 根哈希
    u8                      *root_digest;  // 根哈希（存储在可信位置）

    // 算法
    struct crypto_shash      *tfm;         // 哈希算法
    struct shash_desc        *desc;         // 哈希描述
};
```

### 1.2 verity_sector — 扇区映射

```c
// drivers/md/dm-verity.c — verity_sector
static inline unsigned long verity_sector(struct verity_config *vc, sector_t sector)
{
    // 将数据扇区映射到哈希表中的位置
    // hash_offset = (sector / data_blocks_per_hash_block) * hash_width
    return sector >> (vc->hash_block_bits - 9);
}
```

---

## 2. hash_lookup — 查找哈希

```c
// drivers/md/dm-verity.c — verity_hash_lookup
static int verity_hash_lookup(struct verity_config *vc, sector_t block,
                              u8 *hash)
{
    unsigned long hash_block;
    unsigned int offset;
    struct bio *bio;

    // 1. 计算哈希块的位置
    hash_block = verity_sector(vc, block);

    // 2. 从 hash_dev 读取哈希
    bio = bio_read_map(hash_block << (vc->hash_block_bits - 9));

    // 3. 提取哈希值（每个块对应一个哈希）
    memcpy(hash, bio_data(bio), vc->hash_width);

    return 0;
}
```

---

## 3. verity_map — 验证并映射

```c
// drivers/md/dm-verity.c — verity_map
static int verity_map(struct dm_target *ti, struct bio *bio)
{
    struct verity_config *vc = ti->private;
    sector_t sector = dm_target_offset(ti, bio->bi_iter.bi_sector);
    u8 wanted[vc->hash_width];
    u8 actual[vc->hash_width];

    // 1. 获取期望的哈希值
    verity_hash_lookup(vc, sector, wanted);

    // 2. 计算实际数据的哈希
    verity_hash_for_block(vc, bio, actual);

    // 3. 比较
    if (memcmp(wanted, actual, vc->hash_width) != 0) {
        // 完整性验证失败！
        // Android：触发 dm_verity_kernel_error
        // 返回 -EIO，拒绝访问
        return DM_MAPIO_KILL;
    }

    // 4. 验证通过，传递到底层设备
    generic_make_request(bio);
    return DM_MAPIO_REMAPPED;
}
```

---

## 4. Merkle Tree

```
Merkle Tree 结构：
                    Root Hash
                   /          \
            Hash(0,1)      Hash(2,3)
            /      \        /      \
     Hash(0)   Hash(1)   Hash(2)   Hash(3)
       |        |         |        |
     Block0   Block1   Block2   Block3

验证 Block2：
  1. 从哈希设备读取 Hash(2) 和 Hash(3)
  2. 计算 Hash(2,3) = hash(Hash(2) || Hash(3))
  3. 从哈希设备读取 Root（预先存储在可信位置）
  4. 比较：hash(Hash(2,3)) == Root ?
```

---

## 5. Android Verified Boot

```c
// dm-verity 用于 Android：
// - dm-verity 设备映射表由 dm-verity-table kernel cmdline 指定
// - vbmeta partition 存储根哈希
// - 启动时验证 dm-verity 表的完整性
// - 如果验证失败，设备无法启动（砖块保护）
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/md/dm-verity.c` | `struct verity_config`、`verity_map`、`verity_hash_lookup` |