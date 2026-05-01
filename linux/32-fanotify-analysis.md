# 32-fanotify — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**fanotify** 是文件系统事件通知机制。支持 PRE_OPEN 事件（用户空间决定允许/拒绝），通过 fanotify fd 读取事件，write 回复（PERM 事件）。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
