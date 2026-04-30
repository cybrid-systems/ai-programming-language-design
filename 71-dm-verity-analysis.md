# Linux Kernel dm-verity / dm-integrity 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/md/dm-verity.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. dm-verity

**dm-verity** 是只读块设备的**完整性验证**，每个块都有哈希值存储在哈希树中。

---

## 1. 哈希树结构

```
层 0: 数据块 0..N 的哈希 → hash(block[0..N])
层 1: 哈希块的哈希          → hash(hash[0..N])
层 2: 根哈希               → verity_root_hash

验证：沿路径从叶子到根，每个块计算 SHA256 / HMAC-SHA256
```

---

## 2. 参考

| 文件 | 内容 |
|------|------|
| `drivers/md/dm-verity.c` | 核心实现 |
| `drivers/md/dm-integrity.c` | dm-integrity（可写完整性）|
