# 46-scheduler-domains — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**调度域** 层次化组织 CPU（SMT→core→NUMA）。每域独立负载均衡，load_balance 迁移任务均衡负载。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
