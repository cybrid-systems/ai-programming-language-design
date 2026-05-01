# 64-**VM Sockets (vsock)** 提供宿主机和虚拟机之间的通信通道，绕过网络协议栈，通过 VMCI / PCI 设备直接通信。 — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**VM Sockets (vsock)** 提供宿主机和虚拟机之间的通信通道，绕过网络协议栈，通过 VMCI / PCI 设备直接通信。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
