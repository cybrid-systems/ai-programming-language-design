# 27-cgroup v2 — 控制组深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**cgroup v2** 提供对进程组的资源限制和审计（CPU/内存/IO），使用统一层次树。

---

## 1. 核心结构

```c
struct cgroup {
    struct cgroup_subsys_state *self;   // 自身 css
    int                        id;
    struct cgroup *parent;
    struct list_head children;         // 子 cgroup
    struct cgroup_file procs_file;     // cgroup.procs
};
```

---

## 2. v2 vs v1

| 特性 | v1 | v2 |
|------|-----|-----|
| 层次 | 每控制器独立树 | 统一树 |
| 线程粒度 | 仅进程 | 支持 threaded mode |
| 控制器 | 可任意组合 | 同一层次 |

---

*分析工具：doom-lsp（clangd LSP）*
