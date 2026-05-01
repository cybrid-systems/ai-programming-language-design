# 111 — 深度源码分析

> Linux 7.0-rc1 | 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

**packet_mmap**（PACKET_MMAP）通过共享环形缓冲区零拷贝读写网络包。tcpdump 使用此接口。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
