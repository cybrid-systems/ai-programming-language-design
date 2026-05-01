# 66-ext4-journal — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**jbd2** 是 ext4 的日志块设备层。事务先写入日志（journal），commit 后写入磁盘，保证元数据一致性。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
