# 111-packet-mmap-CAN-SocketCAN-RDMA — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**packet_mmap（PACKET_MMAP）** 允许用户空间通过共享环形缓冲区直接读写网络数据包，实现零拷贝的高速包处理。tcpdump 和 AF_PACKET 使用此接口。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
