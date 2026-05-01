# 42-OOM-killer — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**OOM Killer** 内存耗尽时选择进程杀掉。select_bad_process 计算 badness（RSS+swap），oom_kill_process 发 SIGKILL + 唤醒 oom_reaper 回收内存。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
