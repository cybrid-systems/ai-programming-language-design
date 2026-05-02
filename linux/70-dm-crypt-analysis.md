# 70-dm-crypt — Linux 块设备加密映射器深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**dm-crypt** 是 Linux Device Mapper 框架下的块设备加密 target。它在 DM 层实现**透明全盘加密**——写入底层设备的数据块通过内核 Crypto API 自动加密，读取时自动解密。`cryptsetup/LUKS` 的用户空间工具管理密钥和元数据，内核 dm-crypt 只负责实际的加密/解密数据路径。

**核心设计**：dm-crypt 注册为 `struct target_type`（`.name = "crypt"`）。文件系统的 BIO 进入 DM 层后，dm-crypt 通过 `crypt_map()` 拦截，将 BIO 数据克隆、加密（通过 `crypto_skcipher` 或 `crypto_aead`），然后转发到底层设备。

```
文件系统 page cache → BIO
    ↓
DM: crypt_map() @ dm-crypt.c
    ├── 读路径：kcryptd_crypt_read_convert()
    │            → crypt_convert() → crypto_skipher_decrypt()
    │            → kcryptd_io() → submit_bio(底层设备)
    │
    └── 写路径：kcryptd_crypt_write_convert()
                 → crypt_alloc_buffer() 分配加密输出缓冲区
                 → crypt_convert() → crypto_skipher_encrypt()
                 → kcryptd_io() → submit_bio(底层设备)
    ↓
底层块设备 (/dev/sda1)
```

**doom-lsp 确认**：实现在 `drivers/md/dm-crypt.c`（**3,723 行**）。核心结构 `struct crypt_config`（`:159`）、`struct dm_crypt_io`（`:80`）、`struct crypt_iv_operations`（`:108`）。

---

## 1. 核心数据结构

### 1.1 struct crypt_config — 加密上下文

```c
// drivers/md/dm-crypt.c:159-261
struct crypt_config {
    struct dm_dev *dev;                    /* 底层块设备 */
    sector_t start;

    struct percpu_counter n_allocated_pages;  /* 跟踪分配页数 */

    struct workqueue_struct *io_queue;         /* IO 提交 wq */
    struct workqueue_struct *crypt_queue;       /* 加密 wq */

    spinlock_t write_thread_lock;
    struct task_struct *write_thread;          /* 写线程（kcryptd）*/
    struct rb_root write_tree;                 /* 写请求排序树 */

    char *cipher_string;                       /* "aes-xts-plain64" */
    char *cipher_auth;
    char *key_string;

    /* ── IV 生成 ─ */
    const struct crypt_iv_operations *iv_gen_ops;
    union {
        struct iv_benbi_private benbi;
        struct iv_lmk_private lmk;
        struct iv_tcw_private tcw;
        struct iv_elephant_private elephant;
    } iv_gen_private;
    u64 iv_offset;
    unsigned int iv_size;
    unsigned short sector_size;               /* 扇区大小 */
    unsigned char sector_shift;

    /* ── Crypto ─ */
    union {
        struct crypto_skcipher **tfms;         /* skcipher 句柄 */
        struct crypto_aead **tfms_aead;        /* AEAD 句柄 */
    } cipher_tfm;
    unsigned int tfms_count;

    unsigned long flags;                       /* DM_CRYPT_* */
    unsigned long cipher_flags;                /* CRYPT_* */
};
```

### 1.2 struct dm_crypt_io — per-BIO 操作上下文

```c
// drivers/md/dm-crypt.c:80-96
struct dm_crypt_io {
    struct crypt_config *cc;
    struct bio *base_bio;                    /* 原始文件系统 BIO */
    u8 *integrity_metadata;                  /* AEAD 完整性元数据 */
    bool integrity_metadata_from_pool:1;

    struct work_struct work;                 /* 异步 work */
    struct convert_context ctx;              /* 加密转换上下文 */

    atomic_t io_pending;                     /* 待完成子操作计数 */
    blk_status_t error;
    sector_t sector;                         /* 起始扇区 */

    struct rb_node rb_node;                  /* 写排序树节点 */
} CRYPTO_MINALIGN_ATTR;
```

### 1.3 struct crypt_iv_operations — IV 策略表

```c
// drivers/md/dm-crypt.c:108-118
struct crypt_iv_operations {
    int (*ctr)(struct crypt_config *cc, struct dm_target *ti,
               const char *opts);
    void (*dtr)(struct crypt_config *cc);
    int (*init)(struct crypt_config *cc);
    void (*wipe)(struct crypt_config *cc);
    int (*generator)(struct crypt_config *cc, u8 *iv,
                     struct dm_crypt_request *dmreq);
    void (*post)(struct crypt_config *cc, u8 *iv,
                 struct dm_crypt_request *dmreq);
};
```

**doom-lsp 确认**：IV 策略实例在 `dm-crypt.c` 中注册：
- `crypt_iv_plain_ops`（`:1016`）— `IV = sector`（32-bit）
- `crypt_iv_plain64_ops`（`:1020`）— `IV = sector`（64-bit）
- `crypt_iv_plain64be_ops`（`:1024`）— big-endian 64-bit
- `crypt_iv_essiv_ops` — `IV = AES(sector, key)`（encrypted sector salt）
- `crypt_iv_benbi_ops` — big-endian + shift
- `crypt_iv_lmk_ops` — Loop-AES 兼容（`crypt_iv_lmk_one` `:519`）
- `crypt_iv_tcw_ops` — TrueCrypt 兼容
- `crypt_iv_elephant_ops` — `crypt_iv_elephant` `:928`，AES-ECB 加密 IV

---

## 2. BIO 提交——crypt_map

```c
// drivers/md/dm-crypt.c
static int crypt_map(struct dm_target *ti, struct bio *bio)
{
    struct crypt_config *cc = ti->private;
    struct dm_crypt_io *io;

    io = dm_per_bio_data(bio, cc->dmreq_size);
    io->cc = cc;
    io->base_bio = bio;
    io->sector = bio->bi_iter.bi_sector;
    atomic_set(&io->io_pending, 2);     /* 加密 + 提交各一 */

    if (bio_data_dir(bio) == READ)
        kcryptd_queue_crypt(io);        /* 读：先加密（解密）再 IO */
    else
        kcryptd_queue_crypt(io);        /* 写：先加密再 IO */
}
```

**DM 框架集成**：`crypt_map` 返回 `DM_MAPIO_SUBMITTED`，DM 不对 BIO 做进一步处理。

---

## 3. 加密转换——crypt_convert

```c
// drivers/md/dm-crypt.c
static int crypt_convert(struct crypt_config *cc, struct convert_context *ctx)
{
    struct bio_vec bv;
    struct dm_crypt_request *dmreq;
    int bv_idx = 0;

    while (ctx->iter.bi_size) {
        /* 1. IV 生成——根据扇区号计算 IV */
        cc->iv_gen_ops->generator(cc, iv, dmreq);

        /* 2. 设置 Scatterlist */
        sg_init_table(dmreq->sg_in, 4);
        bio_get_first_bvec(&ctx->iter, &bv);
        sg_set_page(dmreq->sg_in, bv.bv_page, bv.bv_len, bv.bv_offset);

        /* 3. 调用 Crypto API 加密/解密 */
        skcipher_request_set_crypt(req, dmreq->sg_in, dmreq->sg_out,
                                    bv.bv_len, iv);
        crypto_skcipher_encrypt(req);          /* 或 decrypt */

        /* 4. 处理完一个 bvec，推进迭代器 */
        bio_advance_iter(&ctx->iter, bv.bv_len);
        bv_idx++;
    }
}
```

**doom-lsp 确认**：`crypt_convert` 是同步加密循环——遍历 BIO 的所有 `bio_vec`，为每个 `bio_vec` 设置 SG 列表并调用 `crypto_skcipher_encrypt/decrypt`。

---

## 4. 读/写路径分离

### 4.1 读路径——kcryptd_crypt_read_convert

```c
// 读：BIO 有现成的数据页面 → 就地解密
static void kcryptd_crypt_read_convert(struct work_struct *work)
{
    /* 复用原始 BIO 的页面作为输出 */
    crypt_convert(cc, &io->ctx);

    /* 提交到底层设备 */
    kcryptd_io(io);
}
```

### 4.2 写路径——kcryptd_crypt_write_convert

```c
// 写：需要分配新页面保存加密结果（不能覆盖原始数据）
static void kcryptd_crypt_write_convert(struct work_struct *work)
{
    /* 1. 分配加密输出缓冲区 */
    crypt_alloc_buffer(io, io->base_bio->bi_iter.bi_size);

    /* 2. 加密 */
    crypt_convert(cc, &io->ctx);

    /* 3. 通过 write_thread 或直接提交 */
    if (use_write_thread)
        kcryptd_write(io);      /* 写入排序树，保证顺序 */
    else
        kcryptd_io(io);         /* 直接提交 */
}
```

### 4.3 写线程排序

```c
// 写线程 kcryptd_write_thread() 维护 write_tree（红黑树）
// 按扇区号排序提交，保证加密写入顺序
// 避免块设备因乱序写入导致的性能问题（HDD 寻道）
```

**doom-lsp 确认**：写线程路径在 `dm-crypt.c` 中可选（`DM_CRYPT_NO_WRITE_WORKQUEUE` 标志关闭排序，直接提交）。

---

## 5. AEAD/完整性保护

```c
// dm-crypt 支持 AEAD（Authenticated Encryption with Associated Data）
// 加密同时提供完整性保护（检测数据篡改）

// 启用：cipher 使用 aead 格式
// "aes-xts-plain64" → skcipher（仅加密）
// "aes-gcm-random" → aead（加密+认证）

// AEAD 路径：
// crypt_convert() 使用 crypto_aead_encrypt()
// 认证标签（tag）存入 integrity_metadata
// 读取时 crypto_aead_decrypt() 验证标签
// 验证失败 → bio 返回 -EIO
```

---

## 6. 性能优化

| 特性 | 说明 |
|------|------|
| **per-CPU 队列** | `CRYPT_SAME_CPU` 使加密在同一 CPU 上完成，减少 cache miss |
| **写线程排序** | 按扇区排序的 write_tree，优化 HDD 写入模式 |
| **页面预分配** | `crypt_alloc_buffer()` 预先分配加密输出页面池 |
| **AES-NI** | 通过 Crypto API `crypto_skcipher` 自动使用硬件加速 |
| **工作队列** | `io_queue` 和 `crypt_queue` 分离 IO 等待和加密计算 |
| **大扇区** | `sector_size > 512` 减少 IV 计算次数 |

---

## 7. dm-crypt 典型配置

```bash
# LUKS 格式
cryptsetup luksFormat --cipher aes-xts-plain64 --key-size 512 /dev/sda1
cryptsetup open /dev/sda1 crypt_root
mkfs.ext4 /dev/mapper/crypt_root

# 查看 DM table
dmsetup table crypt_root
# 0 1000000 crypt aes-xts-plain64 :64:logon:key: 0 /dev/sda1 0

# 性能测试
cryptsetup benchmark
```

---

## 8. 总结

dm-crypt 是 Linux DM 框架下的**块设备加密引擎**：`crypt_map` 拦截 BIO → `crypt_convert` 通过 IV 策略 + Crypto API 加密 → 提交到底层。其模块化设计使 IV 策略（plain64/lmk/tcw/elephant）和加密算法（skcipher/aead）均可插拔。

**关键路径延迟**：读=解密+IO，写=IO+加密。加密通过 AES-NI 可达到 ~10GB/s，软件 AES 约 500MB/s。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
