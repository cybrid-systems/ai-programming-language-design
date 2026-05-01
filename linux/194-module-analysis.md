# 194-module-analysis — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**module 加载**：load_module → 重定位 → sysfs 注册 → 初始化回调，内核模块的完整加载流程。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
