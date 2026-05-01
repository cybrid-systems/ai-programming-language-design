# 51-userfaultfd — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**userfaultfd** 用户空间处理缺页。ioctl(UFFDIO_REGISTER) 注册 VMA，缺页时 read uffd 收到事件，UFFDIO_COPY 填入页。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
