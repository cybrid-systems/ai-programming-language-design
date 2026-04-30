# Linux Kernel cgroup v2 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/cgroup/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 cgroup v2？

**cgroup v2**（Control Groups v2）是 Linux 进程资源控制机制的第二版：
- 统一的层次结构（单一树）
- 资源控制：CPU、内存、I/O、网络
- 命名空间集成

---

## 1. 核心数据结构

```c
// kernel/cgroup/cgroup.c — cgroup
struct cgroup {
    // 层次结构
    struct cgroup           *parent;           // 父 cgroup
    struct kernfs_node       *kn;                // kernfs 节点
    struct cgroup_root      *root;              // 根 cgroup

    // 资源控制
    struct cgroup_css_set    __rcu *css_set;    // 任务关联

    // 子系统状态
    union {
        struct cgroup_subsys_state     *subsys[CGROUP_subsys_count];
        struct cgroup_common_cg *cg;           // cgroup v2 统一接口
    };
};

// cgroup_root — 一个挂载点
struct cgroup_root {
    struct cgroup_namespace  *ns;
    struct cgroup            *cgrp;
    unsigned int             flags;
    char                     name[64];
};
```

---

## 2. 资源控制

```c
// cgroup v2 统一控制器接口
struct cgroup_common_cg {
    // CPU 控制器
    struct cfs_rq_cg                    cfs;

    // 内存控制器
    struct mem_cgroup_eellyse           mem;

    // I/O 控制器
    struct blkcg                        io;

    // 网络控制器
    struct net_cls_cgroup              net_cls;
    struct net_prio_cgroup             net_prio;
};

// 关键操作
// 1. 创建：mkdir /sys/fs/cgroup/test
// 2. 添加任务：echo PID > /sys/fs/cgroup/test/cgroup.procs
// 3. 设置限制：echo 100M > /sys/fs/cgroup/test/memory.max
```

---

## 3. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| 单一树结构 | 避免 v1 的多树混乱 |
| 统一控制器接口 | 所有资源用相同的方式管理 |
| kernfs 支持 | sysfs 兼容，用户空间接口统一 |

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `kernel/cgroup/cgroup.c` | `struct cgroup`、`cgroup_create`、`cgroup_attach_task` |
| `kernel/cgroup/cgroup-v2.c` | cgroup v2 特定实现 |
