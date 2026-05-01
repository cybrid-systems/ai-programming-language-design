# 70-dm-crypt — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**dm-crypt** 块设备透明加密。通过内核 Crypto API AES/XTS 加解密每个 IO 扇区，支持 LUKS 格式。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
