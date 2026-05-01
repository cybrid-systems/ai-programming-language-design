# 48-kworker — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**kworker** 是 workqueue 的工作线程。kworker/<cpu>:<id><flags> 命名，执行 pool->worklist 中的 work_struct。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
