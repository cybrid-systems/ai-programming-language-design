# 30-crypto API — 加密子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

Linux **Crypto API** 提供了统一的加密操作接口，支持对称/非对称加密、哈希、AEAD、压缩等。内核中的文件系统加密（fscrypt）、IPsec、dm-crypt 等都基于此框架。

Crypto API 采用**算法模板 + 具体实现**的两层设计：用户指定算法名（如 "cbc(aes)"），框架自动组合模板和底层驱动。

---

## 1. 核心结构

### 1.1 struct crypto_tfm——算法实例

```c
struct crypto_tfm {
    u32 crt_flags;                    // 标志
    struct crypto_alg *__crt_alg;     // 指向算法类型
    void *__crt_ctx[];                // 算法上下文（柔性数组）
};
```

### 1.2 struct crypto_alg——算法描述

```c
struct crypto_alg {
    char                    cra_name[CRYPTO_MAX_ALG_NAME];  // 算法名
    char                    cra_driver_name[CRYPTO_MAX_ALG_NAME]; // 驱动名
    unsigned int            cra_priority;                    // 优先级
    unsigned int            cra_flags;                       // CRYPTO_ALG_*
    unsigned int            cra_blocksize;                   // 块大小
    unsigned int            cra_ctxsize;                     // 上下文大小
    union {
        struct ablkcipher_alg ablkcipher;  // 异步块加密
        struct aead_alg       aead;         // AEAD
        struct hash_alg       hash;         // 哈希
        ...
    };
    struct module           *cra_module;
    ...
};
```

---

## 2. 操作流程

```
使用 Crypto API 的典型模式：

1. 分配算法实例
   crypto_alloc_skcipher("cbc(aes)", 0, 0)
     └─ crypto_alloc_base(name, type, mask)
          ├─ crypto_larval_lookup(name)     ← 查找/创建幼虫
          ├─ crypto_larval_wait(alg)        ← 等待算法就绪
          ├─ crypto_create_tfm(alg, type)   ← 分配 tfm
          └─ return tfm

2. 设置密钥
   crypto_skcipher_setkey(tfm, key, keylen)
     └─ alg->cra_skcipher.setkey(tfm, key, keylen)
          └─ 检查密钥长度
          └─ 展开密钥（如 AES key expansion）

3. 加密/解密
   crypto_skcipher_encrypt(req)
     └─ alg->cra_skcipher.encrypt(req)
          ├─ 同步路径：直接调用驱动
          └─ 异步路径：提交到 cryptd 线程

4. 释放
   crypto_free_skcipher(tfm)
```

---

## 3. 源码文件索引

| 文件 | 关键符号 |
|------|---------|
| `crypto/api.c` | `crypto_alloc_base` / `crypto_create_tfm` |
| `crypto/algapi.c` | 算法管理 |
| `include/linux/crypto.h` | 公共 API |

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
