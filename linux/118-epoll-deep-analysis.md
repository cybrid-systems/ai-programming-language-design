# 118-deadline-sched — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**deadline 调度器** 是 Linux 实时调度类，基于最早截止时间优先（EDF），保证实时任务在截止时间内完成。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
