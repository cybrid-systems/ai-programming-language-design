# cgroup v1 — 控制组版本1深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/cgroup/cgroup.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**cgroup v1** 是 Linux 2.6.24+ 引入的资源控制机制，允许限制/记录/隔离进程组的资源使用（CPU、内存、I/O）。

---

## 1. 核心数据结构

### 1.1 cgroup — 控制组

```c
// kernel/cgroup/cgroup.h — cgroup
struct cgroup {
    // ID
    struct cgroup_id            id;             // 全局唯一 ID

    // 层级
    struct cgroup               *parent;        // 父 cgroup
    struct list_head            children;       // 子 cgroup 链表

    // 子系统状态
    struct cgroup_subsys_state  *subsys[CGROUP_SUBSYS_COUNT]; // 每子系统一个状态

    // 命名空间
    struct cgroup_namespace     *ns;            // cgroup 命名空间

    // 统计
    struct cgroup_stat          cgroup_stat;    // 统计信息

    // 任务
    struct css_set             *cgroups;        // cgroups 关联

    // 文件系统
    struct cftype              *cftypes;       // cgroupfs 文件
};
```

### 1.2 cgroup_subsys_state — 子系统状态

```c
// kernel/cgroup/cgroup.h — cgroup_subsys_state
struct cgroup_subsys_state {
    struct cgroup           *cgroup;           // 所属 cgroup
    struct cgroup_subsys     *ss;              // 子系统
    unsigned long           flags;             // CSS_* 标志

    // 计数器
    atomic_t                refcnt;            // 引用计数

    // 链表
    struct list_head        sibling;            // 兄弟链表
    struct list_head        children;           // 子链表
};
```

---

## 2. 控制器

```c
// kernel/cgroup/cgroup.h — cgroup_subsys
struct cgroup_subsys {
    const char              *name;             // "cpu" "memory" "io"
    int                     (*css_alloc)(struct cgroup *cgrp);
    void                    (*css_offline)(struct cgroup *cgrp);
    void                    (*css_free)(struct cgroup *cgrp);

    // 层级
    int                     (*can_attach)(struct cgroup *cgrp, struct cgroup_taskset *tset);
    void                    (*attach)(struct cgroup *cgrp, struct cgroup_taskset *tset);

    // 传播
    void                    (*post_attach)(void);
    int                     (*can_fork)(struct task_struct *task);
    void                    (*cancel_fork)(struct task_struct *task);

    // 统计
    void                    (*bind)(struct cgroup *root);
};
```

---

## 3. cgroupfs 接口

```
/sys/fs/cgroup/
├── cpu/                    ← CPU 控制器
│   ├── cpu.cfs_quota_us    ← 带宽限制
│   ├── cpu.shares          ← 权重
│   └── tasks               ← 任务列表
├── memory/                 ← 内存控制器
│   ├── memory.limit_in_bytes
│   ├── memory.usage_in_bytes
│   └── tasks
├── blkio/                  ← I/O 控制器
│   ├── blkio.throttle.read_bps_device
│   └── tasks
└── devices/               ← 设备控制器
    └── tasks
```

---

## 4. 与 cgroup v2 的区别

| 特性 | cgroup v1 | cgroup v2 |
|------|-----------|-----------|
| 树结构 | 多树（每控制器独立）| 单一树 |
| 线程模式 | 进程级别 | 支持线程级别 |
| 控制器 | 可混合 | 统一层级 |

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/cgroup/cgroup.h` | `struct cgroup`、`struct cgroup_subsys_state` |
| `kernel/cgroup/cgroup.c` | cgroupfs 实现 |