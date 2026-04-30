# Linux Kernel Crypto API 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`crypto/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 Crypto API？

**Crypto API** 是 Linux 内核的**密码学抽象层**，统一了 AES、SHA、RSA、HMAC 等算法的接口，支持软实现和硬件加速（CAAM、ARM-CE、Intel AES-NI）。

---

## 1. 核心结构

```c
// crypto/api.c — crypto_tfm
struct crypto_tfm {
    union {
        struct ablkcipher_tfm   ablkcipher;
        struct aead_tfm        aead;
        struct ahash_tfm      ahash;
        struct shash_tfm       shash;
        struct skcipher_tfm    skcipher;
    };

    void                    *ctx;          // 算法实例上下文
    const struct crypto_type  *type;
    const struct crypto_alg  *alg;          // 底层算法
    __u32                    crt_flags;      // 能力标志
};

// crypto_alg — 算法描述符
struct crypto_alg {
    __u32       cra_priority;
    const char *cra_name;
    const char *cra_driver_name;
    const void *cra_blocksize;
    __u32       cra_ctxsize;                // 上下文大小
    union {
        struct ablkcipher_alg  *ablkcipher;
        struct aead_alg         *aead;
        struct ahash_alg        *ahash;
        struct shash_alg        *shash;
    };
};
```

---

## 2. 同步 API

```c
// 简单加密（同步）
#include <crypto/hash.h>

// 1. 创建 shash 变换
struct crypto_shash *tfm = crypto_alloc_shash("sha256", 0, 0);

// 2. 初始化
struct shash_desc *desc = kmalloc(sizeof(*desc) + crypto_shash_descsize(tfm), GFP_KERNEL);
desc->tfm = tfm;

// 3. 计算摘要
crypto_shash_digest(desc, data, len, digest);

// 4. 释放
crypto_free_shash(tfm);
```

---

## 3. 异步 API（crypto_engine）

```c
// 异步加密（后台线程处理）
struct crypto_async_request *req;
struct crypto_engine_ctx {
    struct crypto_engine     *engine;
};

int crypto_aead_encrypt(struct aead_request *req)
{
    return aead_encrypt(req);
}
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `crypto/api.c` | `crypto_alloc_*`、`crypto_register_alg` |
| `crypto/shash.c` | `crypto_shash_digest`、`shash_alg` |
| `include/linux/crypto.h` | `struct crypto_alg`、`struct crypto_tfm` |
