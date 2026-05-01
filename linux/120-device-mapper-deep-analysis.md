# 120-lockdep — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**lockdep** 是 Linux 死锁检测器，在运行时跟踪锁的获取顺序，通过校验锁依赖图发现潜在的死锁。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
