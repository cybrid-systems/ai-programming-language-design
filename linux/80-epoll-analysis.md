# 80-binfmt-elf — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**binfmt_elf** 加载 ELF 可执行文件。load_elf_binary 解析 ELF header，加载段到内存，设置解释器（ld.so）。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
