# 159-writeback-analysis — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**backing-dev（bdi）** 管理回写设备信息，每个块设备或文件系统有一个 bdi，控制脏页回写节流。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
