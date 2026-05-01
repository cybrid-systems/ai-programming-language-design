# 194 — 深度源码分析

> Linux 7.0-rc1 | 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

**module** 加载。load_module→拉入内核→重定位→sysfs 注册→init 回调。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
