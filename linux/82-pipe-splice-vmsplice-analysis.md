# 82-pipe-splice — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**pipe** 提供半双工进程间通信。**splice** 实现零拷贝数据传递（在管道和文件之间直接移动页，无需用户空间拷贝）。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
