# 103-netlink-deep — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**netlink** 是内核到用户空间的通信套接字协议。用于路由、防火墙、audit、uevent 等。netlink 建立在标准 socket API 之上。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
