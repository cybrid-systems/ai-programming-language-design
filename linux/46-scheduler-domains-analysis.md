# 46-scheduler-domains — 调度域深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**调度域（scheduler domains）** 是 Linux 调度器在 NUMA/SMP 系统中对 CPU 的层次化分组。每个域有自己的负载均衡策略，避免不必要的跨域迁移。

---

## 1. 层次结构

```
NUMA 系统示例：
  domain 1 (NUMA 节点)     ─── 跨节点负载均衡
    domain 0 (物理核心)     ─── 同节点内均衡
      CPU 0  CPU 1  CPU 2  CPU 3

SMT 系统示例：
  domain 2 (NUMA 节点)
    domain 1 (物理核心)
      domain 0 (SMT 线程)
        CPU 0  CPU 1  (同一核心的 2 个线程)
```

---

*分析工具：doom-lsp（clangd LSP）*
