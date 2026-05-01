# 69-overlayfs — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**overlayfs** 联合挂载文件系统。lowerdir+upperdir+workdir 层叠为 merged 视图，Docker 容器镜像的底层实现。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
