# 37-CFS-scheduler — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**CFS** 使用红黑树按 vruntime 组织进程。pick_next_entity 取最左节点，update_curr 更新 vruntime。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
