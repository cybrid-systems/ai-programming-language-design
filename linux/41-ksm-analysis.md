# 41-KSM — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**KSM（Kernel Same-page Merging）** 合并内容相同的匿名页。ksmd 扫描注册的 VMA（MADV_MERGEABLE），计算校验和，合并匹配页为 COW 共享。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
