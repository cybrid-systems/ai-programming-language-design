# 141-NAPI-GRO — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**NAPI** 是中断+轮询混合接收模式，减少高负载下的中断数量。**GRO** 合并多个小包为大包以减少协议栈处理。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
