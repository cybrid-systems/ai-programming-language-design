# 59-device-mapper — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**Device Mapper** 映射虚拟块设备到物理设备。dm_target 处理 IO 映射，LVM/dm-crypt/dm-verity 基于此。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
