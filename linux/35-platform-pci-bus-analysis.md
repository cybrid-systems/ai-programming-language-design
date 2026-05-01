# 35-platform-pci-bus — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**platform device**（不可枚举设备）和 **PCI**（可枚举外设总线）是 Linux 设备模型的核心总线。platform_device_register → device_add → bus 匹配驱动 probe。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
