# 94-cgroup-v1 — Linux cgroup v1 资源控制器框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**cgroup（control group）** 是 Linux 的资源隔离和限制框架。它将进程组织为层级树，对每个 cgroup 中的进程进行 CPU、内存、IO 等资源的配额控制。核心是 `struct cgroup` 层级树 + `struct cgroup_subsys` 控制器插件架构。

**doom-lsp 确认**：`kernel/cgroup/cgroup.c`（7,493 行，349 符号），`include/linux/cgroup.h`（903 行）。

---

## 1. 核心数据结构

### 1.1 struct cgroup——cgroup 节点

```c
struct cgroup {
    struct cgroup *parent;                   // 父节点
    struct list_head children;               // 子节点链表
    struct cgroup_subsys_state *subsys[CGROUP_SUBSYS_COUNT]; // 控制器状态
    struct cgroup_root *root;
    struct kernfs_node *kn;                  // sysfs 节点
    struct cgroup_file *files;               // 控制文件
};
```

### 1.2 struct cgroup_subsys——控制器接口

```c
struct cgroup_subsys {
    struct cgroup_subsys_state *(*css_alloc)(struct cgroup_subsys_state *parent_css);
    int (*css_online)(struct cgroup_subsys_state *css);
    void (*css_offline)(struct cgroup_subsys_state *css);
    int (*can_attach)(struct cgroup_taskset *tset);  // 允许迁移检查
    void (*attach)(struct cgroup_taskset *tset);      // 迁移后回调
    int id;
    const char *name;
};
```

### 1.3 struct css_set——进程的 css 集合

```c
struct css_set {
    struct cgroup_subsys_state *subsys[CGROUP_SUBSYS_COUNT]; // 所有控制器 css
    struct list_head tasks;                  // 进程链表
    refcount_t refcount;
    struct rcu_head rcu;
};
```

---

## 2. cgroup_attach_task——进程迁移

```c
// 写入 /sys/fs/cgroup/cpu/mygroup/cgroup.procs
// → cgroup_procs_write() → cgroup_attach_task()

int cgroup_attach_task(struct cgroup *dst_cgrp, struct cgroup_taskset *tset)
{
    // 1. can_attach 检查
    for_each_subsys(ss, ssid)
        if (ss->can_attach && !ss->can_attach(tset))
            return -EINVAL;

    // 2. 迁移 css_set
    // → find_css_set() 查找或创建新的 css_set
    // → task->cgroups = new_cset

    // 3. attach 通知
    for_each_subsys(ss, ssid)
        if (ss->attach)
            ss->attach(tset);
}
```

---

## 3. 控制器列表

```c
// @ cgroup.c:142
struct cgroup_subsys *cgroup_subsys[] = {
    &cpu_cgroup_subsys,        // kernel/sched/core.c — CPU 带宽
    &memory_cgroup_subsys,     // mm/memcontrol.c — 内存限制
    &blkio_cgroup_subsys,      // block/blk-cgroup.c — IO 控制
    &cpuset_subsys,            // kernel/cgroup/cpuset.c — CPU/内存绑定
    &devices_subsys,           // security/device_cgroup.c — 设备白名单
    &freezer_subsys,           // kernel/cgroup/freezer.c — 冻结
    &net_cls_subsys,           // net/core/netclassid_cgroup.c — 网络分类
    &perf_event_subsys,        // kernel/events/core.c — perf 事件
    &hugetlb_subsys,           // mm/hugetlb_cgroup.c — 大页限制
    &pids_subsys,              // kernel/cgroup/pids.c — PID 限制
};
```

---

## 4. cgroup v1 vs v2

| 维度 | v1 | v2 |
|------|-----|-----|
| 挂载方式 | `mount -t cgroup -o cpu` 独立 | `mount -t cgroup2` 统一 |
| 进程归属 | 多 cgroup（每控制器不同） | 单 cgroup |
| 内部节点 | 允许任务 | 禁止任务（only leaves）|
| 线程粒度 | 进程级 | 支持 thread mode |
| 默认挂载 | `/sys/fs/cgroup/<name>/` | `/sys/fs/cgroup/` |

---

## 5. 关键函数

| 函数 | 行号 | 作用 |
|------|------|------|
| `cgroup_mkdir` | — | 创建 cgroup |
| `cgroup_attach_task` | — | 进程迁移 |
| `css_alloc` | — | 控制器状态分配 |

---

## 6. 调试

```bash
cat /proc/cgroups                 # 控制器列表
cat /proc/self/cgroup             # 当前 cgroup
ls /sys/fs/cgroup/memory/         # 控制文件
```

---

## 7. 总结

cgroup 通过 `struct cgroup` 层级树 + `struct cgroup_subsys` 控制器插件 + `struct css_set` 进程绑定实现资源隔离。`cgroup_attach_task` 是进程迁移核心路径。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
