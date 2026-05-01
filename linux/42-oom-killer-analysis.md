# 42-OOM Killer — 内存耗尽杀进程深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

当系统内存耗尽且无法通过回收机制释放时，**OOM Killer** 选择杀死一个进程来释放内存。选择基于一个"坏分"（badness score）算法。

---

## 1. 触发条件

```
__alloc_pages_slowpath() → 无法分配到内存
  │
  └─ out_of_memory(gfp_mask, order)
       │
       ├─ 检查是否有 OOM 被 kill 的进程正在退出
       │    └─ 如果有 → 等待退出
       │
       ├─ select_bad_process()          ← 选择要杀死的进程
       │    │
       │    ├─ 遍历所有进程
       │    ├─ 计算 oom_score_badness(p)：
       │    │    └─ badness = rss + swap + pte
       │    │    └─ badness *= (root ? 0 : 1)  ← root 进程权重低
       │    │    └─ badness /= cpu_time  ← 长时间运行的进程权重低
       │    │
       │    └─ 选择 badness 最高的进程
       │
       ├─ oom_kill_process(victim)
       │    ├─ 发送 SIGKILL
       │    ├─ __oom_kill_process(victim)
       │    │    ├─ 标记所有线程为 OOM victim
       │    │    └─ wake_oom_reaper()   ← OOM reaper 线程回收内存
       │    │
       │    └─ 等待 victim 退出释放内存
```

---

*分析工具：doom-lsp（clangd LSP）*
