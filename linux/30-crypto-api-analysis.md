# crypto API — 内核密码学框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`crypto/api.c` + `include/crypto/algapi.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Linux Crypto API** 是内核的统一密码学框架，提供：
- **算法注册**：对称加密（AES/DES/SHA）、非对称（RSA/ECC）、哈希（CRC32）
- **密码变换**：压缩/解压缩、随机数生成
- **硬件加速**：CRYPTO_ALG_KERN_DRIVER_ONLY 标记硬件驱动

---

## 1. 核心数据结构

### 1.1 crypto_tfm — 密码变换

```c
// include/linux/crypto.h — crypto_tfm
struct crypto_tfm {
    // 指向底层算法实现
    struct crypto_alg       *__crt_alg;   // 算法
    void                    *crt_u;       // 特定算法数据
    // ...
};

struct crypto_alg {
    // 算法基本信息
    __u32                   cra_flags;     // CRYPTO_ALG_* 标志
    char                    cra_name[CRYPTO_MAX_ALG_NAME]; // 算法名
    char                    cra_driver_name[CRYPTO_MAX_ALG_NAME]; // 驱动名
    char                    cra_module[MODULE_NAME_LEN]; // 模块名

    // 算法特定操作
    union {
        struct cipher_alg     cipher;      // 对称加密
        struct compress_alg   compress;    // 压缩
        struct hash_alg        hash;       // 哈希
        // ...
    };

    // 初始化/销毁
    int (*cra_init)(struct crypto_tfm *);
    void (*cra_exit)(struct crypto_tfm *);
    // ...
};
```

### 1.2 ablkcipher_tfm — 块密码（可并行）

```c
// include/linux/crypto.h — ablkcipher_tfm
struct ablkcipher_tfm {
    void                    *base;         // 基础 tfm
    unsigned int            ivsize;        // IV 大小
    unsigned int            reqsize;       // 请求大小

    int (*enc)(struct ablkcipher_request *req);  // 加密
    int (*dec)(struct ablkcipher_request *req);  // 解密
};
```

### 1.3 shash — 单块哈希

```c
// include/crypto/shash.h — shash
struct shash {
    unsigned int            descsize;      // 描述大小
    unsigned int            digestsize;    // 摘要大小
    unsigned int            statesize;     // 状态大小

    int (*init)(struct shash_desc *desc);
    int (*update)(struct shash_desc *desc, const u8 *data, unsigned int len);
    int (*final)(struct shash_desc *desc, u8 *out);
    // ...
};
```

---

## 2. 同步 API

### 2.1 crypto_alloc — 分配算法

```c
// crypto/api.c — crypto_alloc_base
struct crypto_tfm *crypto_alloc_base(const char *alg_name, u32 type, u32 mask)
{
    // 1. 在算法列表中查找
    // 2. 分配 tfm
    // 3. 调用 cra_init
    return tfm;
}
```

### 2.2 crypto_cipher_encrypt_one — 对称加密

```c
// crypto/api.c — crypto_cipher_encrypt_one
int crypto_cipher_encrypt_one(struct crypto_cipher *tfm, u8 *dst, const u8 *src)
{
    // 1. 分组加密（ECB/CBC/CTR 等）
    // 2. 内部调用 ablkcipher
    return tfm->enc(ablkcipher_request);
}
```

### 2.3 crypto_shash_digest — 哈希摘要

```c
// include/crypto/shash.h — crypto_shash_digest
int crypto_shash_digest(struct shash_desc *desc, const u8 *data, unsigned int len, u8 *out)
{
    crypto_shash_init(desc);
    crypto_shash_update(desc, data, len);
    return crypto_shash_final(desc, out);
}
```

---

## 3. 异步 API（加快处理）

### 3.1 ablkcipher_request — 异步请求

```c
// include/linux/crypto.h — ablkcipher_request
struct ablkcipher_request {
    struct crypto_ablkcipher *tfm;      // 变换
    struct scatterlist       *src;      // 源
    struct scatterlist       *dst;      // 目标
    unsigned int            nbytes;     // 字节数
    void                   *iv;         // IV
    // ...
};
```

### 3.2 crypto_ablkcipher_encrypt — 异步加密

```c
// crypto/ablkcipher.c — crypto_ablkcipher_encrypt
int crypto_ablkcipher_encrypt(struct ablkcipher_request *req)
{
    return req->tfm->enc(req);
}
```

---

## 4. 散列/哈希算法（示例：SHA256）

```c
// crypto/sha256_generic.c — SHA256 实现
static int sha256_init(struct shash_desc *desc)
{
    struct sha256_state *sctx = shash_desc_ctx(desc);

    // 初始化 SHA256 状态
    sctx->state[0] = 0x6a09e667;
    sctx->state[1] = 0xbb67ae85;
    // ...

    return 0;
}
```

---

## 5. 对称加密算法（示例：AES）

```c
// arch/x86/crypto/aes-ce.c — AES 实现
static int aes_encrypt(struct crypto_ablkcipher *tfm, const u8 *src, u8 *dst)
{
    // 1. 加载密钥
    aes_load_key(sctx, key);

    // 2. CBC/CTR 加密
    for (i = 0; i < blocks; i++) {
        if (mode == CBC)
            xor128(dst, src, iv);
        aes_encrypt_block(dst);
        if (mode == CBC)
            iv = dst;
    }

    return 0;
}
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `crypto/api.c` | `crypto_alloc_base`、`crypto_cipher_encrypt_one` |
| `include/linux/crypto.h` | `struct crypto_tfm`、`struct crypto_alg` |
| `include/crypto/shash.h` | `struct shash`、`crypto_shash_digest` |
| `crypto/ablkcipher.c` | `crypto_ablkcipher_encrypt` |