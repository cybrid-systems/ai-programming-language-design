# 101-binfmt-misc — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**binfmt_misc** 允许通过文件魔术字节（magic bytes）注册任意文件格式的解释器。例如运行 .jar 文件时自动调用 java。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
