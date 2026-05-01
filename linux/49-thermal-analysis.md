# 49-thermal — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**thermal 框架** 管理设备温度。thermal_zone_device_update 读取温度→governor 决策→cooling device 调节。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
