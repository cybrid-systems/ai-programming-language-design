# 64-vsock — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**VM Sockets（vsock）** 宿主机↔虚拟机通信通道，通过 VMCI/PCI 设备直接通信，绕过网络协议栈。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
