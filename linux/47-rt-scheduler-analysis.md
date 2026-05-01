# 47-RT-scheduler — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**RT 调度器** 管理 SCHED_FIFO/RR 实时进程。pick_next_task_rt 从 rt_rq.active 位图取最高优先级进程。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
