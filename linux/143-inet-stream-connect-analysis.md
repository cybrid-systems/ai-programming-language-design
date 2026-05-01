# 143-sock-create — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**socket 创建**：sys_socket → sock_create → inet_create → 初始化协议特定的 sock 结构。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
