# 184-sched_domain — 调度域深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/sched/topology.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**sched_domain** 是 CFS 负载均衡的基础，通过分层的调度域（Core → LLC → Die → NUMA）实现跨 CPU 核心的负载均衡。

---

## 1. 调度域层级

```
典型 x86_64 NUMA 拓扑：
  NUMA Node 0                     NUMA Node 1
  ┌─────────────┐                  ┌─────────────┐
  │  Die 0     │                  │  Die 1     │
  │  ┌───────┐ │                  │  ┌───────┐ │
  │  │Core 0 │Core 1│            │  │Core 4 │Core 5│
  │  │ L1 L2 │ L1 L2│            │  │ L1 L2 │ L1 L2│
  │  └───────┘ │ │            │  └───────┘ │ │
  │    L3 Cache│ │            │    L3 Cache│ │
  │  ───────── │ │            │  ───────── │ │
  └─────────────┘ │            └─────────────┘ │
        ↑ SD_BOUNDS│                    ↑ SD_BOUNDS│
        │SD_SHARE_PKG_RESOURCES│        │
        └────────────────────┘

每个层级都是一个 sched_domain：
  - SD_LV_SIBLING  — 同一核心的兄弟调度域
  - SD_LV_DIE     — 同一 CPU Die
  - SD_LV_NUMA    — 同一 NUMA 节点
```

---

## 2. struct sched_domain

```c
// kernel/sched/topology.c — sched_domain
struct sched_domain {
    struct sched_domain *parent;  // 父域
    struct sched_domain *child;    // 子域

    // 包含的 CPU
    unsigned long span[NR_CPUS];

    // 标志
    unsigned int flags;
    #define SD_LOAD_BALANCE       0x0001  // 负载均衡
    #define SD_BALANCE_NEWIDLE    0x0002  // 空闲时均衡
    #define SD_SHARE_PKG_RESOURCES 0x1000  // 共享资源（缓存）

    // 层级
    int level;                     // 域层级

    // 负载均衡
    struct balance_callback *balance_callback;
};
```

---

## 3. load_balance

```c
// kernel/sched/fair.c — load_balance
// 当 CPU 空闲或超时，调用 load_balance
// 1. 找到最繁忙的调度域
// 2. 从该域的繁忙组迁移任务到当前 CPU
```

---

## 4. 西游记类喻

**sched_domain** 就像"天庭的分区调度"——

> sched_domain 像天庭分成了多个区：每个小营房（L1/L2 缓存）、每个宿舍楼（L3 缓存）、每栋楼（Die）、每个院子（NUMA 节点）。负载均衡就是在每个层级内，让工作量均匀分布——不能让某个营房特别忙，而其他营房闲置。调度域的层级关系决定了负载均衡的范围——同一 Die 的妖怪可以互相帮忙（共享 L3），但跨院子（NUMA）就需要更大的协调代价。

---

## 5. 关联文章

- **CFS**（article 37）：sched_domain 是 CFS 负载均衡的基础
- **cpuset**（article 183）：cpuset 限制调度域范围