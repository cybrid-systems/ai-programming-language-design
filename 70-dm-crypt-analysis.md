# Linux Kernel dm-crypt / LUKS 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/md/dm-crypt.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. dm-crypt 原理

**dm-crypt** 是 Device Mapper 的**透明加密**目标，所有经过它的数据都会被**实时加解密**。

---

## 1. 核心流程

```
写路径：
bio → dm_crypt_crypt()
  → crypt_convert_scatterlist()
    → crypto_skcipher_encrypt() → 加密
  → bio_set_dev(underlying_device) → 提交到下层设备

读路径：
bio → dm_crypt_crypt()
  → crypto_skcipher_decrypt() → 解密
  → bio_set_dev() → 完成
```

---

## 2. LUKS 头部

```
/dev/sda1:LUKS 头部格式：

offset 0-591983:  LUKS 头部 + keyslot
offset 592000:    加密数据开始
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/md/dm-crypt.c` | 核心加解密实现 |
| `drivers/md/dm.c` | DM 基础 |
