# 75-regulator — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**regulator 框架** 管理电压调节器。regulator_get→regulator_enable→regulator_set_voltage→regulator_disable。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
