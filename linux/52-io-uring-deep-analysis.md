# 52-io_uring-deep — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

io_uring 高级特性：fixed buffers（预注册缓冲区避免 GUP）、registered files（预注册 fd）、IORING_OP_PROVIDE_BUFFERS。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
