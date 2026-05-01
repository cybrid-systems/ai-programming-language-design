# 69-**overlayfs** 是联合挂载文件系统，将多个目录层叠为一个视图，是 Docker 容器镜像的底层技术。 — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

## 0. 概述

**overlayfs** 是联合挂载文件系统，将多个目录层叠为一个视图，是 Docker 容器镜像的底层技术。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
