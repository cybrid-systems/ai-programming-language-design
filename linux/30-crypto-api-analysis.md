# 30-crypto API — 加密子系统深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

Linux **Crypto API** 提供统一的加密操作接口。采用算法模板+实现的两层设计（如 "cbc(aes)"=模板cbc+算法aes）。

---

## 1. 核心操作

```c
// 分配算法实例
struct crypto_skcipher *tfm = crypto_alloc_skcipher("cbc(aes)", 0, 0);

// 设置密钥
crypto_skcipher_setkey(tfm, key, keylen);

// 加解密
crypto_skcipher_encrypt(req);
crypto_skcipher_decrypt(req);

// 释放
crypto_free_skcipher(tfm);
```

---

## 2. 算法查找

```
crypto_alloc_base("cbc(aes)", type, mask)
  ├─ crypto_larval_lookup(name)     ← 模板+算法组合
  ├─ crypto_larval_wait(alg)        ← 等待就绪
  ├─ crypto_create_tfm(alg, type)   ← 分配 tfm
  └─ return tfm
```

---

*分析工具：doom-lsp（clangd LSP）*
