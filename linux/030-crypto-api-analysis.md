# 30-crypto — Linux 内核加密 API 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**Linux Crypto API** 是内核的加密框架，为 IPsec、dm-crypt、fs-verity、磁盘加密等子系统提供统一的加密操作接口。它支持对称加密（AES、SM4）、哈希（SHA、MD5）、AEAD（GCM、CCM）、HMAC、公钥操作等多种算法。

架构层次：
```
用户（IPsec / dm-crypt / fs-verity）
    │
    ▼
Crypto API 通用层（算法查找、请求分配）
    │
    ▼
算法实现（aes-generic, aes-x86_64, sha256, gcm 等）
    │
    ▼
硬件加速（AES-NI、AVX、QAT、CCP）
```

**doom-lsp 确认**：核心 API 在 `include/linux/crypto.h`。实现在 `crypto/` 目录（约 50+ 源文件，涵盖各种算法和模板）。

---

## 1. 核心数据结构

### 1.1 `struct crypto_alg`——算法描述

```c
struct crypto_alg {
    char cra_name[CRYPTO_MAX_ALG_NAME];    // "aes", "sha256", "gcm"
    char cra_driver_name[CRYPTO_MAX_ALG_NAME]; // "aes-aesni", "aes-generic"
    unsigned int cra_blocksize;             // 块大小（AES=16, SHA256=64）
    unsigned int cra_flags;                 // CRYPTO_ALG_*
    unsigned int cra_priority;              // 优先级（硬件加速 > 软件实现）
    struct module *cra_module;

    union {
        struct skcipher_alg skcipher;       // 对称加密
        struct aead_alg aead;               // AEAD
        struct hash_alg hash;               // 哈希
        struct rng_alg rng;                 // 随机数
        struct akcipher_alg akcipher;       // 非对称加密
    };
};
```

### 1.2 加密请求

```c
// 对称加密请求
struct skcipher_request {
    struct crypto_skcipher *tfm;            // 变换对象
    struct scatterlist *src;                // 源数据散列表
    struct scatterlist *dst;                // 目标数据散列表
    unsigned int cryptlen;                  // 加密长度
    u8 *iv;                                 // 初始化向量
    struct crypto_async_request base;       // 异步请求基
};

// AEAD 请求（认证加密）
struct aead_request {
    struct crypto_aead *tfm;
    u8 *iv;
    struct scatterlist *src, *dst;
    unsigned int cryptlen;                  // 密文长度
    unsigned int assoclen;                  // 关联数据长度
    struct crypto_async_request base;
};
```

---

## 2. 对称加密操作

```c
// 1. 分配加密变换
struct crypto_skcipher *tfm;
tfm = crypto_alloc_skcipher("cbc(aes)", 0, 0);
if (IS_ERR(tfm))
    return PTR_ERR(tfm);

// 2. 设置密钥
int ret = crypto_skcipher_setkey(tfm, key, key_len);
// AES-128: key_len = 16
// AES-256: key_len = 32

// 3. 分配请求
struct skcipher_request *req;
req = skcipher_request_alloc(tfm, GFP_KERNEL);
skcipher_request_set_callback(req, CRYPTO_TFM_REQ_MAY_BACKLOG,
                               my_callback, data);

// 4. 设置加解密参数
skcipher_request_set_crypt(req, sg_src, sg_dst, len, iv);

// 5. 执行加密（异步！）
crypto_skcipher_encrypt(req);
// 完成后调用 my_callback(data)
```

---

## 3. 哈希操作

```c
struct crypto_shash *tfm = crypto_alloc_shash("sha256", 0, 0);
SHASH_DESC_ON_STACK(desc, tfm);
desc->tfm = tfm;

crypto_shash_init(desc);
crypto_shash_update(desc, data, len);  // 流式更新数据
crypto_shash_final(desc, hash);       // 获取哈希值
```

---

## 4. 硬件加速

x86-64 上 AES 的硬件加速路径：

```c
// 注册硬件加速算法
static struct skcipher_alg aesni_skciphers[] = {
    {
        .base = {
            .cra_name        = "__aes",
            .cra_driver_name = "__aes-aesni",
            .cra_priority    = 400,    // 软件通用实现 priority=100
            .cra_module      = THIS_MODULE,
            .cra_ctxsize     = sizeof(struct aesni_ctx),
        },
        .setkey         = aesni_setkey,
        .encrypt        = aesni_encrypt,
        .decrypt        = aesni_decrypt,
        .min_keysize    = AES_MIN_KEY_SIZE,
        .max_keysize    = AES_MAX_KEY_SIZE,
    },
};

// crypto API 根据 priority 选择最高优先级的实现
// crypto_alloc_skcipher("cbc(aes)", 0, 0) 自动选择 aes-aesni
```

---

## 5. 模板——算法组合

模板将基础算法组合为更高级的加密模式：

| 模板 | 基础算法 | 含义 |
|------|---------|------|
| cbc | aes | AES+CBC 模式 |
| ctr | aes | AES+CTR 模式 |
| gcm | aes | AES+GCM 认证加密 |
| hmac | sha256 | HMAC-SHA256 |
| cbcmac | aes | AES-CBC-MAC |
| ecb | aes | AES+ECB 模式 |

```c
// "cbc(aes)" 的注册：
struct skcipher_alg cbc_aes_alg = {
    .base.cra_name = "cbc(aes)",
    .base.cra_driver_name = "cbc-aes-aesni",
    .encrypt = cbc_encrypt,
    .decrypt = cbc_decrypt,
};

// cbcmac(aes) 的注册：
struct shash_alg cbcmac_aes_alg = {
    .base.cra_name = "cbcmac(aes)",
    .digest = cbcmac_digest,
};
```

---

## 6. 源码文件索引

| 文件 | 内容 |
|------|------|
| `include/linux/crypto.h` | 通用 API |
| `crypto/cipher.c` | 对称密码核心 |
| `crypto/aead.c` | AEAD |
| `crypto/hash.c` | 哈希 |
| `crypto/shash.c` | 同步哈希 |
| `crypto/ahash.c` | 异步哈希 |
| `crypto/skcipher.c` | 对称加密 |
| `arch/x86/crypto/aes-aesni_asm.S` | AES-NI 实现 |
| `arch/x86/crypto/crc32-pclmul_asm.S` | CRC32 硬件加速 |

---

## 7. 关联文章

- **70-dm-crypt**：磁盘加密使用 crypto API
- **71-dm-verity**：哈希验证使用 crypto
- **30-crypto**：crypto API 总览

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 7. AEAD——认证加密

AEAD 同时提供加密和认证（常见于 IPsec 和 TLS）：

```c
struct crypto_aead *tfm = crypto_alloc_aead("gcm(aes)", 0, 0);
// GCM: Galois/Counter Mode

// 设置密钥
crypto_aead_setkey(tfm, key, key_len);

// 设置认证标签长度
crypto_aead_setauthsize(tfm, 16);  // 128-bit 认证标签

// 准备请求
struct aead_request *req = aead_request_alloc(tfm, GFP_KERNEL);
aead_request_set_callback(req, CRYPTO_TFM_REQ_MAY_BACKLOG, callback, data);
aead_request_set_ad(req, assoc_sg, assoc_len);  // 关联数据（认证但不加密）
aead_request_set_crypt(req, src_sg, dst_sg, crypt_len, iv);

// 执行
crypto_aead_encrypt(req);  // 异步
```

---

## 8. 异步操作

Crypto API 的异步操作模式：

```c
// 加密请求完成后调用此回调
void my_callback(struct crypto_async_request *req, int err)
{
    struct skcipher_request *skreq = container_of(req, ...);
    if (err)
        printk("encryption failed: %d\n", err);
    else
        printk("encryption complete!\n");
    // 释放请求
    skcipher_request_free(skreq);
}

// 流式处理——不用等上一个完成就能提交下一个
for (i = 0; i < num_buffers; i++) {
    struct skcipher_request *req = skcipher_request_alloc(tfm, GFP_KERNEL);
    skcipher_request_set_callback(req, 0, completion_cb, req);
    skcipher_request_set_crypt(req, sg_in, sg_out, len, iv);
    crypto_skcipher_encrypt(req);
}
```

---

## 9. 同步操作（shash、ciper）

对于短数据，同步操作更高效：

```c
// 同步哈希
struct crypto_shash *tfm = crypto_alloc_shash("sha256", 0, 0);
SHASH_DESC_ON_STACK(desc, tfm);
desc->tfm = tfm;

crypto_shash_init(desc);
crypto_shash_update(desc, data, len);
crypto_shash_final(desc, hash);

// 一次性计算（init + update + final）
crypto_shash_digest(desc, data, len, hash);
```

---

## 10. 算法优先级

```c
// 内核根据优先级选择实现
struct crypto_alg aes_alg_generic = {
    .cra_priority = 100,     // 软件通用实现
};

struct crypto_alg aes_alg_aesni = {
    .cra_priority = 400,     // AES-NI 硬件加速（高于软件）
};

// crypto_alloc_skcipher("cbc(aes)", 0, 0)
// → 返回 "cbc(aes)" 模板组合
// → 基础算法选择优先级最高的 aes-aesni
// → 最终操作路径：cbc_template + aes_aesni

// 强制禁用硬件加速：
// crypto_alloc_skcipher("cbc(aes)", 0, CRYPTO_ALG_ASYNC)
```

---

## 11. 支持的算法列表

| 算法 | 类型 | 用途 |
|------|------|------|
| aes | skcipher | AES 加密 |
| sm4 | skcipher | 国密 SM4 |
| cbc(aes) | skcipher | AES-CBC |
| ctr(aes) | skcipher | AES-CTR |
| gcm(aes) | aead | AES-GCM 认证加密 |
| ccm(aes) | aead | AES-CCM |
| sha256 | shash | SHA-256 哈希 |
| sha512 | shash | SHA-512 哈希 |
| sm3 | shash | 国密 SM3 哈希 |
| hmac(sha256) | shash | HMAC-SHA256 |
| crc32c | shash | CRC32C 校验 |
| chacha20 | skcipher | ChaCha20 流密码 |
| poly1305 | shash | Poly1305 MAC |
| ecb(des3_ede) | skcipher | 3DES（兼容）|

---

## 12. 源码文件索引

| 文件 | 内容 |
|------|------|
| `include/linux/crypto.h` | 通用 API 声明 |
| `crypto/cipher.c` | 对称密码 |
| `crypto/aead.c` | AEAD |
| `crypto/hash.c` | 哈希 |
| `crypto/skcipher.c` | 对称加密 |
| `arch/x86/crypto/` | x86 硬件加速 |
| `crypto/testmgr.c` | 加密测试框架 |

---

## 13. 关联文章

- **70-dm-crypt**：磁盘加密使用 crypto API
- **71-dm-verity**：哈希验证使用 crypto
- **30-crypto**：加密 API 总览

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 14. 随机数生成器

```c
struct crypto_rng *rng = crypto_alloc_rng("drbg_nopr_hmac_sha256", 0, 0);

// 种子
u8 *seed = kmalloc(32, GFP_KERNEL);
get_random_bytes(seed, 32);
crypto_rng_reset(rng, seed, 32);

// 生成随机数
u8 *output = kmalloc(64, GFP_KERNEL);
crypto_rng_get_bytes(rng, output, 64);
```

---

## 15. KPP——密钥协商（DH、ECDH）

```c
struct crypto_kpp *tfm = crypto_alloc_kpp("ecdh", 0, 0);

// 设置私钥
struct ecdh params = {
    .curve_id = ECC_CURVE_NIST_P256,
    .key = private_key,
    .key_size = private_key_len,
};
crypto_kpp_set_secret(tfm, ¶ms);

// 生成公钥
struct kpp_request *req = kpp_request_alloc(tfm, GFP_KERNEL);
kpp_request_set_input(req, NULL);
kpp_request_set_output(req, public_key_sg, public_key_len);
crypto_kpp_generate_public_key(req);

// 计算共享密钥
kpp_request_set_input(req, peer_public_sg);
kpp_request_set_output(req, shared_secret_sg, shared_secret_len);
crypto_kpp_compute_shared_secret(req);
```

---

## 16. 公钥加密

```c
struct crypto_akcipher *tfm = crypto_alloc_akcipher("rsa", 0, 0);

// 设置公钥
struct rsa_key rsa_key = {
    .n = modulus, .n_sz = modulus_len,
    .e = exponent, .e_sz = exponent_len,
};
crypto_akcipher_set_pub_key(tfm, &rsa_key);

// RSA 加密（OAEP 填充）
struct akcipher_request *req = akcipher_request_alloc(tfm, GFP_KERNEL);
sg_init_one(src_sg, plaintext, plaintext_len);
sg_init_one(dst_sg, ciphertext, ciphertext_len);
akcipher_request_set_crypt(req, src_sg, dst_sg, plaintext_len, ciphertext_len);
crypto_akcipher_encrypt(req);
```

---

## 17. Crypto API 测试

```bash
# 查看注册的所有算法
cat /proc/crypto

# 运行加密测试
modprobe tcrypt mode=200  # AES-CBC 测试
modprobe tcrypt mode=500  # SHA256 测试
```

---

## 18. 调试

```c
// 打印算法信息
pr_info("Using %s (%s)\n",
        crypto_tfm_alg_name(tfm),
        crypto_tfm_alg_driver_name(tfm));
```


## 19. Crypto API 内核中的使用场景

| 子系统 | 使用方式 | 目的 |
|--------|---------|------|
| IPsec (xfrm) | aead(gcm(aes)) | 数据包加密和认证 |
| dm-crypt | skcipher(cbc(aes)) | 磁盘加密 |
| fscrypt | skcipher(xts(aes)) | 文件系统加密 |
| fs-verity | shash(sha256) | 文件完整性验证 |
| dm-verity | shash(sha256) | 块设备完整性验证 |
| 密钥环 (keyctl) | akcipher(rsa) | 公钥验证 |
| 内核模块签名 | akcipher(rsa) | 模块签名验证 |
| WireGuard | aead(chacha20poly1305) | VPN 隧道加密 |

---

## 20. 性能对比

| 算法 | 实现 | 吞吐量 (GiB/s) | 延迟 (ns/block) |
|------|------|----------------|-----------------|
| AES-256-CBC | AES-NI | ~5 | ~20 |
| AES-256-CBC | 软件 | ~0.5 | ~150 |
| AES-256-XTS | AES-NI | ~4 | ~25 |
| SHA256 | AVX2 | ~3 | ~15 |
| SHA256 | 软件 | ~0.3 | ~100 |
| ChaCha20 | AVX2 | ~6 | ~10 |
| SM4 | 软件 | ~0.8 | ~80 |
| GCM(AES) | AES-NI+PCLMUL | ~3 | ~30 |

---

## 21. 源码文件索引

| 文件 | 内容 |
|------|------|
| `include/linux/crypto.h` | 通用 API |
| `crypto/cipher.c` | 对称密码 |
| `crypto/aead.c` | AEAD |
| `crypto/hash.c` | 哈希 |
| `crypto/shash.c` | 同步哈希 |
| `crypto/ahash.c` | 异步哈希 |
| `crypto/skcipher.c` | 对称加密 |
| `arch/x86/crypto/` | x86 硬件加速代码 |
| `crypto/algapi.c` | 算法管理 |
| `crypto/testmgr.c` | 加密测试框架 |

---

## 22. 关联文章

- **70-dm-crypt**：磁盘加密
- **71-dm-verity**：哈希验证
- **105-wireguard**：WireGuard 使用 crypto API

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 23. 注册和查找算法

```c
// 查找算法
struct crypto_alg *alg = crypto_alg_mod_lookup("aes", 0, 0);
if (IS_ERR(alg))
    return PTR_ERR(alg);

// 遍历所有已注册算法
struct crypto_alg *pos;
list_for_each_entry(pos, &crypto_alg_list, cra_list) {
    pr_info("Algorithm: %s (%s), priority=%d, blocksize=%u\n",
            pos->cra_name, pos->cra_driver_name,
            pos->cra_priority, pos->cra_blocksize);
}

// 按类型查找
unsigned int type = crypto_skcipher_type(0);
unsigned int mask = crypto_skcipher_mask(0);
alg = crypto_find_alg("cbc(aes)", &type, &mask);
```

---

## 24. dm-crypt 中的 crypto API 使用

dm-crypt 是 crypto API 在内核中最典型的使用者：

```c
// drivers/md/dm-crypt.c
struct crypt_config {
    struct crypto_skcipher *tfm;   // 加密变换
    struct crypto_aead *tfm_aead;  // AEAD 变换（用于 authenticated 模式）
    struct crypto_shash *integrity_hashes; // 完整性哈希
    char cipher_string[CRYPTO_MAX_ALG_NAME]; // "aes-cbc-essiv:sha256"
};

// 初始化加密
static int crypt_ctr(struct dm_target *ti, unsigned int argc, char **argv)
{
    cc->tfm = crypto_alloc_skcipher(cc->cipher_string, 0, 0);
    if (IS_ERR(cc->tfm))
        return PTR_ERR(cc->tfm);
    
    // 设置密钥（从内核密钥环获取）
    crypto_skcipher_setkey(cc->tfm, key, key_len);
}

// 每个 BIO 的加密/解密
static int crypt_convert(struct crypt_config *cc, ...)
{
    struct skcipher_request *req = skcipher_request_alloc(cc->tfm, GFP_NOIO);
    skcipher_request_set_callback(req, CRYPTO_TFM_REQ_MAY_BACKLOG, crypt_endio, io);
    skcipher_request_set_crypt(req, sg_in, sg_out, DATA_SIZE, iv);
    
    if (write)
        crypto_skcipher_encrypt(req);
    else
        crypto_skcipher_decrypt(req);
}
```


## 25. CRYPTO_ALG_* 标志

| 标志 | 含义 |
|------|------|
| CRYPTO_ALG_ASYNC | 异步算法（可能需要等待硬件）|
| CRYPTO_ALG_ALLOCATES_MEMORY | 可能分配内存 |
| CRYPTO_ALG_KERN_DRIVER_ONLY | 仅内核使用 |
| CRYPTO_ALG_NEED_KEY | 需要设置密钥 |
| CRYPTO_ALG_LARVAL | 算法正在注册中 |
| CRYPTO_ALG_DEAD | 算法已移除 |
| CRYPTO_ALG_TESTED | 已通过自检 |
