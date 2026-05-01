# 55-ftrace — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**ftrace** 内核跟踪器。编译时函数入口插入 nop，启用时替换为 call ftrace_caller，回调写入 ring buffer。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
