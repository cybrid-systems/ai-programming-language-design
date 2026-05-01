# 54-perf — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**perf** 性能事件子系统。perf_event_open 创建事件，PMU 溢出时 perf_event_overflow 写入 ring buffer，用户 mmap 零拷贝读取。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
