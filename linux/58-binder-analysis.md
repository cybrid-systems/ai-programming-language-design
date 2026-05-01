# 58-binder — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**Binder** 是 Android IPC 机制。binder_transaction 在进程间传递事务，通过 ioctl(BINDER_WRITE_READ) 通信。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
