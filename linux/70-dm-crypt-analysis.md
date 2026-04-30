# dm-crypt — 磁盘加密映射深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/md/dm-crypt.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**dm-crypt** 是 Device Mapper 的加密目标，提供透明磁盘加密：
- **LUKS（Linux Unified Key Setup）**：标准密钥管理
- **XTS / CBC / ESSIV**：加密模式
- **dm-crypt** 堆叠在普通块设备上（如 /dev/sda5）

---

## 1. 核心数据结构

### 1.1 crypt_config — 加密配置

```c
// drivers/md/dm-crypt.c — crypt_config
struct crypt_config {
    // 设备
    struct block_device     *dev;          // 底层块设备
    struct dm_dev           *ti_device;    // DM 目标设备

    // 密钥
    u8                      *key;          // 对称密钥
    unsigned int            key_size;      // 密钥大小（字节）

    // 加密参数
    unsigned int            sector_size;  // 扇区大小（512 或 4096）
    unsigned int            iv_size;      // IV 大小（16 字节）
    unsigned int           integrated_iv; // 集成 IV 模式

    // 加密算法
    struct crypto_skcipher  *tfm;          // 密码学 tfm
    struct crypto_ablkcipher *ablkcipher;  // 异步块加密

    // 模式
    enum {
        CRYPTO_MODE_CBC,
        CRYPTO_MODE_XTS,
        CRYPTO_MODE_ESSIV,
    } crypt_mode;

    // DM
    struct dm_target        *ti;           // DM 目标
    struct work_struct      crypt_work;   // 加密工作队列

    // 缓冲池
    mempool_t               *page_pool;    // 页内存池
    mempool_t               *bio_pool;     // bio 内存池
};
```

### 1.2 iv_mode — IV（初始化向量）模式

```c
// drivers/md/dm-crypt.c — crypt_iv_essiv_gen
// ESSIV（Encrypted Salt-Sector IV）：
//   IV = SHA256(key) ⊕ sector
// CBC：
//   IV = previous_ciphertext_block（链式）
//   IV = ECB(plaintext[0])  (第一个块)
// XTS（推荐）：
//   应用于每个扇区，IV = sector number
```

---

## 2. 映射流程

### 2.1 crypt_map — BIO 映射

```c
// drivers/md/dm-crypt.c — crypt_map
static int crypt_map(struct dm_target *ti, struct bio *bio)
{
    struct crypt_config *cc = ti->private;
    struct crypt_io *io;

    // 1. 检查 BIO 类型
    if (bio_data_dir(bio) == READ)
        io = crypt_io_from_node(crypt_bio_get_node(bio));
    else
        io = crypt_io_from_node(crypt_bio_put_node(bio));

    // 2. 设置完成回调
    bio->bi_end_io = crypt_endio;
    bio->bi_private = io;

    // 3. 解密/加密数据
    if (bio_data_dir(bio) == READ)
        crypt_decrypt(cc, bio);
    else
        crypt_encrypt(cc, bio);

    // 4. 转发到底层设备
    generic_make_request(bio);

    return DM_MAPIO_REMAPPED;
}
```

### 2.2 crypt_decrypt — 解密

```c
// drivers/md/dm-crypt.c — crypt_decrypt
static int crypt_decrypt(struct crypt_config *cc, struct bio *bio)
{
    struct bio_vec bv;
    sector_t sector = dm_target_offset(cc->ti, bio->bi_iter.bi_sector);

    // 遍历每个页
    bio_for_each_segment(bv, bio, iter) {
        // 1. 计算 IV（根据扇区号）
        u8 *iv = crypt_iv(cc, sector);

        // 2. 解密（crypto_ablkcipher_decrypt）
        crypto_ablkcipher_decrypt(cc->ablkcipher, &req, iv, bv_page, bv_offset, bv_len);

        sector += (bv_len >> 9);
    }

    return 0;
}
```

---

## 3. dmsetup 创建加密设备

```bash
# 创建 LUKS 容器
cryptsetup luksFormat /dev/sda5

# 打开加密容器（创建 /dev/mapper/encrypted）
cryptsetup luksOpen /dev/sda5 encrypted

# 格式化
mkfs.ext4 /dev/mapper/encrypted

# 挂载
mount /dev/mapper/encrypted /mnt

# 内核实际路径：
#   /dev/mapper/encrypted
#       → dm-crypt（加密/解密）
#           → /dev/sda5（物理设备）
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/md/dm-crypt.c` | `struct crypt_config`、`crypt_map`、`crypt_decrypt` |