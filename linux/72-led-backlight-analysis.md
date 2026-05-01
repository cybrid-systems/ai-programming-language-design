# 72-LED — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**LED 子系统** 统一管理 LED 和闪灯。sysfs 控制亮度/触发方式，triggers（disk/mmc/wifi）自动控制。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
