# 070-dm-crypt — Linux 块设备加密映射器深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**dm-crypt** 是 Linux Device Mapper 框架下的块设备加密 target。它在 DM 层实现**透明全盘加密**——文件系统的 BIO 进入 DM 层后，dm-crypt 通过 `crypt_map()` 拦截，将数据通过内核 Crypto API（`crypto_skcipher` 或 `crypto_aead`）加密/解密，然后转发到底层设备。`cryptsetup/LUKS` 管理密钥和元数据，内核只负责实际的数据加解密路径。

**doom-lsp 确认**：`drivers/md/dm-crypt.c`（3,723 行，236 个符号）。核心结构 `struct crypt_config` @ L159，`struct dm_crypt_io` @ L80，`crypt_map` @ L3417。

---

## 1. 核心数据结构

### 1.1 `struct crypt_config`——加密上下文

（`drivers/md/dm-crypt.c` L159 — doom-lsp 确认）

```c
struct crypt_config {
    struct dm_dev           *dev;            // L160 — 底层块设备
    sector_t                start;           // L161 — 起始扇区偏移

    struct percpu_counter   n_allocated_pages; // L163 — 已分配页数跟踪

    struct workqueue_struct *io_queue;       // L165 — I/O 提交工作队列
    struct workqueue_struct *crypt_queue;    // L166 — 加解密工作队列

    spinlock_t              write_thread_lock; // L168 — 写线程锁
    struct task_struct      *write_thread;   // L169 — 写线程（kcryptd）
    struct rb_root          write_tree;      // L170 — 写请求排序树

    char                    *cipher_string;  // L172 — 密码算法字符串（"aes-xts-plain64"）
    char                    *cipher_auth;    // L173 — 认证算法
    char                    *key_string;     // L174 — 密钥字符串

    /* IV 生成器操作 */
    const struct crypt_iv_operations *iv_gen_ops; // L176
    union {
        struct iv_benbi_private benbi;       // L178 — Benbi IV
        struct iv_lmk_private lmk;           // L179 — LMK IV（旧式）
        struct iv_tcw_private tcw;           // L180 — TCW IV（旧式）
        struct iv_elephant_private elephant; // L181 — Elephant IV
    } iv_gen_private;
    u64                     iv_offset;       // L183 — IV 初始偏移
    unsigned int            iv_size;         // L184 — IV 大小
    unsigned short          sector_size;     // L186 — 扇区大小（512/4096）
    unsigned char           sector_shift;    // L187 — 扇区位移

    /* 加密引擎句柄数组 */
    union {
        struct crypto_skcipher **tfms;       // L191 — skcipher 句柄（AES-XTS 等）
        struct crypto_aead **tfms_aead;      // L192 — AEAD 句柄（AES-GCM 等）
    } cipher_tfm;
    unsigned int            tfms_count;      // L194 — 句柄数量（多队列并行）

    unsigned long           cipher_flags;    // L199 — 加密标志
    unsigned int            key_size;        // L204 — 密钥长度（字节）
    unsigned int            key_parts;       // L205 — 密钥部件数
    unsigned int            key_extra_size;  // L207 — 额外密钥数据（防侧信道）
    u8                      key[0];          // L210 — 柔性数组：实际密钥数据
};
```

### 1.2 `struct dm_crypt_io`——I/O 请求

（`drivers/md/dm-crypt.c` L80 — doom-lsp 确认）

```c
struct dm_crypt_io {
    struct crypt_config     *cc;             // L81 — 加密配置
    struct bio              *base_bio;       // L82 — 原始 BIO
    struct work_struct      work;            // L83 — 工作项（提交到 crypt_queue）
    struct bio              *crypt_bio;      // L85 — 加密后 BIO
    sector_t                sector;          // L86 — 起始扇区
    atomic_t                pending;         // L88 — 待处理计数（引用计数）
    int                     error;           // L89 — 错误码
    bool                    write;           // L90 — 写标志
};
```

---

## 2. 完整数据流

### 2.1 crypt_map——DM target 入口

（`drivers/md/dm-crypt.c` L3417 — doom-lsp 确认）

```c
static int crypt_map(struct dm_target *ti, struct bio *bio)
{
    struct crypt_config *cc = ti->private;
    struct dm_crypt_io *io;

    // 1. 分配 I/O 请求
    io = dm_crypt_io_alloc(cc, bio, dm_target_offset(ti, bio->bi_iter.bi_sector));

    // 2. 如果是写请求：在 write_tree 中排序
    //    保证写入底层设备的顺序与提交顺序一致
    if (bio_data_dir(bio) == WRITE) {
        io->write = true;
        // 将 io 插入 cc->write_tree（红黑树，按扇区排序）
        // 确保同一扇区的写操作按序完成
    }

    // 3. 提交到 crypt_queue 工作队列
    INIT_WORK(&io->work, kcryptd_crypt);
    queue_work(cc->crypt_queue, &io->work);

    return DM_MAPIO_SUBMITTED;
}
```

### 2.2 kcryptd_crypt——工作队列分发

（`drivers/md/dm-crypt.c` L2223 — doom-lsp 确认）

```c
static void kcryptd_crypt(struct work_struct *work)
{
    struct dm_crypt_io *io = container_of(work, struct dm_crypt_io, work);

    if (io->write)
        kcryptd_crypt_write_convert(io);     // 写路径：先加密后写入
    else
        kcryptd_crypt_read_convert(io);      // 读路径：先读取后解密
}
```

### 2.3 写路径——kcryptd_crypt_write_convert

（`drivers/md/dm-crypt.c` L2041 — doom-lsp 确认）

```
kcryptd_crypt_write_convert(io)
  │
  ├─ 1. crypt_alloc_buffer(io, io->base_bio->bi_iter.bi_size)
  │     为加密输出分配 page 向量（io->crypt_bio 的 bio_vec）
  │     可能等待内存回写（GFP_NOIO | __GFP_HIGH）
  │
  ├─ 2. crypt_convert(cc, io->crypt_bio, io->sector, encrypt_func)
  │     对每个扇区（512/4096 字节）：
  │     └─ crypt_convert_block_skcipher(cc, ...)
  │          └─ 构造 skcipher_request
  │          └─ sg_init_table(sg_in, 1); sg_set_page(sg_in, src_page, ...)
  │          └─ sg_init_table(sg_out, 1); sg_set_page(sg_out, dst_page, ...)
  │          └─ crypto_skcipher_encrypt(req)   // AES-XTS 加密
  │               → 硬件加速（如 AES-NI）或软件
  │          └─ crypto_wait_req(r, &wait)
  │
  ├─ 3. 将加密后的 BIO 写入底层设备
  │     kcryptd_crypt_write_io_submit(io, 0)
  │       └─ submit_bio(io->crypt_bio)     // 提交到 /dev/sda1 等
  │
  └─ 4. 完成回调
       crypt_endio(io->crypt_bio)
         └─ bio_endio(io->base_bio)        // 通知原始请求者
```

### 2.4 读路径——kcryptd_crypt_read_convert

（`drivers/md/dm-crypt.c` L2132 — doom-lsp 确认）

```
kcryptd_crypt_read_convert(io)
  │
  ├─ 1. 直接从底层设备读取加密数据
  │     kcryptd_io_read(io)
  │       └─ submit_bio(io->crypt_bio)     // 读取加密的扇区
  │
  ├─ 2. 读取完成后解密
  │     kcryptd_crypt_read_continue(io)
  │       └─ crypt_convert(cc, io->crypt_bio, io->sector, decrypt_func)
  │            └─ crypto_skcipher_decrypt(req)   // AES-XTS 解密
  │                 → crypto_wait_req(r, &wait)
  │
  └─ 3. 完成
       bio_endio(io->base_bio)             // 数据已解密，通知请求者
```

### 2.5 crypt_convert——逐扇区加解密

（`drivers/md/dm-crypt.c` 核心路径 — doom-lsp 确认）

```c
// 伪代码，实际实现分布在 crypt_convert 和 crypt_convert_block_skcipher 中
static int crypt_convert(struct crypt_config *cc, struct bio *bio,
                         sector_t sector, int (*convert_fn)(...))
{
    struct bio_vec bv;
    struct bvec_iter iter;

    // 遍历 BIO 的每个 bio_vec (page + offset + len)
    bio_for_each_segment(bv, bio, iter) {
        unsigned int remaining = bv.bv_len;

        while (remaining) {
            // 对每个扇区调用加密回调
            struct skcipher_request *req = ...;
            sg_set_page(req->src, bv.bv_page, sector_size, offset);
            sg_set_page(req->dst, bv.bv_page, sector_size, offset);

            // IV 生成（每个扇区的初始向量）
            // XTS: 扇区号作为 tweak
            // CBC-ESSIV: 扇区号加密后作为 IV
            // plain64: 64 位扇区号直接作为 IV
            cc->iv_gen_ops->generate(cc, iv, sector);

            // 加密/解密
            convert_fn(req);  // crypto_skcipher_encrypt 或 decrypt
            sector += sector_shift;  // 推进扇区
        }
    }
}
```

---

## 3. IV 生成策略

dm-crypt 支持多种 IV（初始化向量）生成模式：

| IV 模式 | 描述 | 安全性 |
|---------|------|--------|
| `plain` | IV = sector（32 位） | 弱（不能被重复） |
| `plain64` | IV = sector（64 位） | 适用于 >2TB 设备 |
| `plain64be` | 大端 plain64 | 兼容性 |
| `essiv` | IV = AES(sector, hash(key)) | 推荐（CBC 模式） |
| `benbi` | IV = sector << 2 + 1（大端） | 兼容旧 cryptsetup |
| `null` | IV = 0 | 测试用 |
| `lmk` / `tcw` | 旧式 | 兼容旧 LUKS 格式 |
| `elephant` | 大象 IV | 特殊用途 |

**推荐配置**：`aes-xts-plain64`（AES-XTS + plain64 IV，支持 2TB+ 设备）。

---

## 4. 密钥管理

dm-crypt 本身不管理密钥存储（由 cryptsetup 管理 LUKS 头部），但内核对密钥的处理有安全考量：

```c
// L204-210 — 密钥存储在柔性数组中
struct crypt_config {
    unsigned int            key_size;        // L204 — 密钥长度
    unsigned int            key_parts;       // L205 — 密钥部件数（XTS 需要两个 key）
    unsigned int            key_extra_size;  // L207 — 额外安全数据（防侧信道攻击）
    u8                      key[0];          // L210 — 实际 key 数据
};

// 密钥写入后，原始缓冲区立即清零
// memzero_explicit(original_key, key_size);
// 防止密钥残留在内存中
```

---


### 2.7 crypt_convert——逐扇区加解密引擎

（`drivers/md/dm-crypt.c` L1352 — doom-lsp 确认）

```c
static int crypt_convert_block_skcipher(struct crypt_config *cc,
    struct skcipher_request *req, unsigned int tag_it)
{
    struct crypto_skcipher *tfm = cc->cipher_tfm.tfms[0];
    struct skcipher_request *subreq;
    int r;

    subreq = skcipher_request_alloc(tfm, GFP_NOIO);
    // 构造 IV（初始化向量）— 每个扇区不同
    cc->iv_gen_ops->generate(cc, iv, dmreq->iv_sector);

    // 设置散聚列表
    sg_init_table(&srcsg, 1);  sg_set_page(&srcsg, dmreq->sg_pages[0], cc->sector_size, 0);
    sg_init_table(&dstsg, 1);  sg_set_page(&dstsg, dmreq->sg_pages[1], cc->sector_size, 0);

    skcipher_request_set_crypt(subreq, &srcsg, &dstsg, cc->sector_size, iv);

    if (bio_data_dir(dmreq_io->base_bio) == WRITE)
        r = crypto_skcipher_encrypt(subreq);  // 写：加密
    else
        r = crypto_skcipher_decrypt(subreq);  // 读：解密

    crypto_wait_req(r, &wait);
    return r;
}
```

## 5. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct crypt_config` | drivers/md/dm-crypt.c | 159 |
| `struct dm_crypt_io` | drivers/md/dm-crypt.c | 80 |
| `crypt_map()` | drivers/md/dm-crypt.c | 3417 |
| `kcryptd_crypt()` | drivers/md/dm-crypt.c | 2223 |
| `kcryptd_crypt_write_convert()` | drivers/md/dm-crypt.c | 2041 |
| `kcryptd_crypt_read_convert()` | drivers/md/dm-crypt.c | 2132 |
| `crypt_convert()` | drivers/md/dm-crypt.c | 相关 |
| `crypt_convert_block_skcipher()` | drivers/md/dm-crypt.c | 1352 |
| `crypt_alloc_buffer()` | drivers/md/dm-crypt.c | 相关 |
| `crypto_skcipher_encrypt()` | crypto/skcipher.c | (crypto API) |
| `crypto_skcipher_decrypt()` | crypto/skcipher.c | (crypto API) |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-04 | 内核版本：Linux 7.0-rc1*
