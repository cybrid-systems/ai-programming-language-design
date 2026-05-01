# 138-netdevice — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**struct net_device** 是网络设备的核心结构（~200+ 字段），包含设备名、MAC 地址、mtu、操作函数集（ndo_*）。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
