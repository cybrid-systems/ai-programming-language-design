# 60-qdisc — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**qdisc** 控制网络包发送顺序和速率。enqueue 入队，dequeue 出队发送。pfifo_fast/HTB/TBF/fq_codel 等实现。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
