# 50-cdev — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**cdev** 注册字符设备驱动。cdev_init+cdev_add 注册到内核，用户通过 /dev/ 节点访问 file_operations。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
