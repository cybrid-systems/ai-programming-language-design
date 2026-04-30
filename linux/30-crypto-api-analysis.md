# 30-crypto_api — 内核加密框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`crypto/api.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**crypto API** 是 Linux 内核的统一加密接口，抽象了各种加密算法（AES、SHA、CRC 等），支持同步和异步加密。

---

## 1. 核心数据结构

### 1.1 struct crypto_tfm — 加密算法实例

```c
// include/crypto/algapi.h — crypto_tfm
struct crypto_tfm {
    // 算法
    struct crypto_alg         *__crt_alg;  // 底层算法
    u32                       crt_flags;    // 标志

    // 密钥
    unsigned long             crt_flags;
    union {
        struct ablkcipher_tfm   crt_ablkcipher;
        struct aead_tfm        crt_aead;
        struct blkcipher_tfm    crt_blkcipher;
        struct hash_tfm        crt_hash;
    };
};
```

### 1.2 struct crypto_alg — 算法定义

```c
// include/linux/crypto.h — crypto_alg
struct crypto_alg {
    __u32                   cra_priority;     // 优先级
    __u32                   cra_blocksize;   // 块大小（AES=16）
    __u32                  cra_ctxsize;      // 上下文大小
    const char              *cra_name;        // 算法名（"cbc(aes)"）
    const char              *cra_driver_name; // 驱动名

    struct crypto_alg       *cra_list;       // 算法链表

    // 算法方法
    union {
        struct ablkcipher_alg   *cra_ablkcipher;
        struct aead_alg       *cra_aead;
        struct blkcipher_alg  *cra_blkcipher;
        struct shash_alg      *cra_shash;
    };
};
```

---

## 2. 同步 API

### 2.1 crypto_alloc_cipher — 分配算法

```c
// crypto/api.c — crypto_alloc_cipher
struct crypto_cipher *crypto_alloc_cipher(const char *name, u32 type, u32 mask)
{
    // 1. 查找算法
    struct crypto_alg *alg;
    alg = crypto_alg_lookup(name);

    // 2. 创建 tfm
    struct crypto_tfm *tfm;
    tfm = crypto_create_tfm(alg, &cipher_tfm);

    return __crypto_cipher_tfm(tfm);
}
```

### 2.2 crypto_cipher_encrypt_one — 加密

```c
// crypto/cipher.c — crypto_cipher_encrypt_one
void crypto_cipher_encrypt_one(struct crypto_cipher *tfm,
                              u8 *dst, const u8 *src)
{
    // 调用底层算法的 encrypt 方法
    tfm->__crt_alg->cra_cipher->cia_encrypt(tfm, dst, src);
}
```

### 2.3 使用示例

```c
// 使用 AES-CBC 加密：
struct crypto_cipher *tfm = crypto_alloc_cipher("aes", 0, 0);
crypto_cipher_setkey(tfm, key, 16);
u8 iv[16] = {0};
crypto_cipher_encrypt_one(tfm, dst, src);
crypto_free_cipher(tfm);
```

---

## 3. 异步 API

### 3.1 async cipher — ablkcipher

```c
// crypto/ablkcipher.c — crypto_ablkcipher_encrypt
int crypto_ablkcipher_encrypt(struct ablkcipher_request *req)
{
    struct crypto_ablkcipher    *tfm = crypto_ablkcipher_reqtfm(req);

    return tfm->alg.base.encrypt(req);
}
```

### 3.2 struct ablkcipher_request

```c
// include/crypto/ablkcipher.h — ablkcipher_request
struct ablkcipher_request {
    struct crypto_ablkcipher    *tfm;
    struct scatterlist         *src;     // 源数据（SG 列表）
    struct scatterlist         *dst;     // 目标数据
    unsigned int              nbytes;    // 长度
    void                     *info;     // IV（初始化向量）
};
```

---

## 4. SHA256 示例

```c
// 使用 SHA256：
struct shash_desc *desc;
struct crypto_shash *tfm = crypto_alloc_shash("sha256", 0, 0);
desc = kzalloc(sizeof(*desc) + crypto_shash_descsize(tfm), GFP_KERNEL);
desc->tfm = tfm;
crypto_shash_digest(desc, data, len, digest);
crypto_free_shash(tfm);
kfree(desc);
```

---

## 5. 算法类型

```
常见算法类型：
  blkcipher    — 块密码（AES, DES, ...)
  ablkcipher  — 异步块密码
  aead        — 带认证的加密（gcm, ccm）
  ahash       — 异步哈希（sha256, md5）
  shash       — 同步哈希
  crc32       — CRC 校验
  rng         — 随机数生成器
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `crypto/api.c` | `crypto_alloc_cipher`、`crypto_create_tfm` |
| `crypto/cipher.c` | `crypto_cipher_encrypt_one` |
| `crypto/ablkcipher.c` | `crypto_ablkcipher_encrypt` |

---

## 7. 西游记类比

**crypto API** 就像"天庭的保密局"——

> 保密局提供各种加密工具（AES、SHA 等），但具体由谁来加密是透明的（crypto_alloc_cipher）。你需要写信加密，只需去保密局登记（AES 注册），然后把你的信交给保密局处理（encrypt）。他们会找到相应的专家（AES 实现）来处理。这就是 crypto API 的意义——统一的接口，多种实现，按需加载。

---

## 8. 关联文章

- **AES/NIST 算法**（算法部分）：具体加密算法