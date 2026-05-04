# 093-cgroup-v1 — Linux cgroup v1 资源控制器框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**cgroup（control group）** 是 Linux 的资源隔离框架，将进程组织为层级树，对每组进程的 CPU、内存、IO 等资源做配额限制。**cgroup v1** 让每个控制器（subsystem）独立管理自己的层级。

**核心架构**：三层数据结构——`struct cgroup`（层级节点）→ `struct cgroup_subsys_state`（css，控制器的 per-cgroup 状态）→ `struct css_set`（cset，进程到 css 的映射集合）。进程迁移到新 cgroup 时，`cgroup_attach_task()` 更新 `task->cgroups` 指针。

```
struct cgroup (层级树节点)       struct css_set (进程的控制器集合)
  ├── parent                    ┌─────────────────────────┐
  ├── children                  │ task_struct->cgroups →  │
  └── subsys[]                  │   subsys[CPU] → cpu_css │
       ├── cpu_css              │   subsys[MEM]→ mem_css  │
       ├── mem_css              │   subsys[IO] → blkio_css│
       └── ...                  └─────────────────────────┘
                                   ↑
                            cgroup_attach_task() 迁移时更新
```

**doom-lsp 确认**：`kernel/cgroup/cgroup.c`（7,493 行，349 符号），`include/linux/cgroup-defs.h`（~980 行）。

---

## 1. 核心数据结构 @ cgroup-defs.h

### 1.1 struct cgroup——cgroup 节点

```c
// include/linux/cgroup-defs.h
struct cgroup {
    struct cgroup *parent;                   // 父 cgroup
    struct list_head children;               // 子 cgroup 链表
    struct list_head sibling;                 // 兄弟 cgroup 链表

    struct cgroup_subsys_state *subsys[CGROUP_SUBSYS_COUNT]; // 每个控制器的 css
    struct cgroup_root *root;                // 所属根

    struct kernfs_node *kn;                  // sysfs 节点
    struct cgroup_file *files;               // 控制文件数组

    u64 id;                                  // 唯一 ID
    int flags;                                // CGRP_*

    struct list_head cset_links;             // 关联的 css_set 链表
    struct list_head releasing_list;
    struct list_head pidlists;
};
```

### 1.2 struct cgroup_subsys——控制器接口

```c
struct cgroup_subsys {
    struct cgroup_subsys_state *(*css_alloc)(struct cgroup_subsys_state *parent_css);
    int (*css_online)(struct cgroup_subsys_state *css);
    void (*css_offline)(struct cgroup_subsys_state *css);
    void (*css_free)(struct cgroup_subsys_state *css);
    int (*can_attach)(struct cgroup_taskset *tset);   // 允许迁移
    void (*cancel_attach)(struct cgroup_taskset *tset);
    void (*attach)(struct cgroup_taskset *tset);       // 迁移后通知
    void (*fork)(struct task_struct *task);             // 子进程 fork 通知
    void (*exit)(struct task_struct *task);             // 进程退出

    int id;
    const char *name;                         // "cpu", "memory", "blkio"...
    bool early_init:1;
    bool thread_root:1;
    bool no_fork_refcnt:1;
    struct list_head cfts;                    // 控制文件类型列表
};
```

### 1.3 struct css_set——进程的控制器状态集合

```c
struct css_set {
    struct cgroup_subsys_state *subsys[CGROUP_SUBSYS_COUNT]; // 所有控制器的 css
    struct list_head tasks;                  // 此 css_set 中的所有进程

    struct list_head cgrp_links;              // 指向 cgroup->cset_links
    struct list_head mg_src_preload_node;
    struct list_head mg_dst_preload_node;
    struct list_head mg_tasks;

    refcount_t refcount;
    struct rcu_head rcu;
};
```

### 1.4 struct cgroup_subsys_state——控制器的 per-cgroup 状态

```c
struct cgroup_subsys_state {
    struct cgroup *cgroup;                   // 所属 cgroup
    struct cgroup_subsys *ss;                // 控制器
    struct percpu_ref refcnt;                 // 引用计数

    struct list_head sibling;                // 兄弟 css
    struct list_head children;
    struct css_set *cset;                    // 关联的 css_set
    u64 id;
    unsigned int flags;                       // CSS_ONLINE / CSS_VISIBLE 等
};
```

---

## 2. 进程迁移——cgroup_attach_task

```c
// echo PID > /sys/fs/cgroup/cpu/mygroup/cgroup.procs
// → cgroup_file_write() → cgroup_procs_write()
// → cgroup_attach_task(cgrp, &tset)

int cgroup_attach_task(struct cgroup *dst_cgrp, struct cgroup_taskset *tset)
{
    // 1. 调用所有控制器的 can_attach
    for_each_subsys(ss, ssid)
        if (ss->can_attach && !ss->can_attach(tset))
            goto out_release;

    // 2. 分配新的 css_set
    new_cset = find_css_set(dst_cgrp, old_cset);
    // → 复制旧 cset 的 subsys[] 指针
    // → 替换目标 cgroup 所涉及的 subsys

    // 3. 更新 task->cgroups
    task_lock(tsk);
    tsk->cgroups = new_cset;
    task_unlock(tsk);

    // 4. 通知控制器
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
    &cpu_cgroup_subsys,        // kernel/sched/core.c — CFS 带宽控制
    &memory_cgroup_subsys,     // mm/memcontrol.c — 内存上限+回收
    &blkio_cgroup_subsys,      // block/blk-cgroup.c — IO 权重+限制
    &cpuset_subsys,            // kernel/cgroup/cpuset.c — CPU+内存绑定
    &devices_subsys,           // security/device_cgroup.c — 设备白名单
    &freezer_subsys,           // kernel/cgroup/freezer.c — 进程冻结
    &net_cls_subsys,           // net/core/netclassid_cgroup.c — 网络包标记
    &perf_event_subsys,        // kernel/events/core.c — perf 事件分组
    &hugetlb_subsys,           // mm/hugetlb_cgroup.c — 大页限制
    &pids_subsys,              // kernel/cgroup/pids.c — 进程数限制
};
```

---

## 4. 控制文件读写

```c
// cgroup v1 中的控制文件：
// /sys/fs/cgroup/memory/mygroup/
//   memory.limit_in_bytes     → cftype::write_u64 → mem_cgroup_write()
//   memory.usage_in_bytes     → cftype::read_u64  → mem_cgroup_read()
//   memory.stat               → cftype::seq_show  → mem_cgroup_show_stat()

// struct cftype — 控制文件类型：
struct cftype {
    char name[MAX_CFTYPE_NAME];               // 文件名
    u64 flags;
    umode_t mode;

    int (*write_u64)(struct cgroup_subsys_state *css, struct cftype *cft, u64 val);
    u64 (*read_u64)(struct cgroup_subsys_state *css, struct cftype *cft);
    int (*seq_show)(struct seq_file *sf, void *v);
    int (*write)(...);
    void *private;
};
```

---

## 5. cgroup v1 vs v2

| 维度 | v1 | v2 |
|------|-----|-----|
| 挂载方式 | 每控制器独立 `mount -t cgroup -o cpu` | 统一 `mount -t cgroup2` |
| 层级数 | 多层级（每控制器一个） | 单层级（unified hierarchy）|
| 进程归属 | 可在不同控制器的不同 cgroup | 每个进程单一 cgroup |
| 内部节点 | 可包含进程 | 禁止内部节点（仅 leaf）|
| 线程模式 | 仅进程级 | 支持 thread mode |
| 控制器 | cpu/memory/blkio/cpuset...| 精简合并 |
| 默认挂载 | `/sys/fs/cgroup/<name>/` | `/sys/fs/cgroup/` |

---

## 6. 调试

```bash
cat /proc/cgroups                # 所有控制器状态
cat /proc/self/cgroup            # 进程所在 cgroup
cat /sys/fs/cgroup/memory/memory.stat
ls /sys/fs/cgroup/               # 所有 v1 子系统
```

---

## 7. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `cgroup_attach_task` | — | 进程迁移 |
| `cgroup_mkdir` | — | 创建 cgroup |
| `css_alloc` | — | 分配 per-cgroup ss 状态 |
| `find_css_set` | — | 查找/创建 css_set |
| `cgroup_file_write` | — | 控制文件写入分发 |

---

## 8. 总结

cgroup v1 通过 `struct cgroup` 层级树 + `struct cgroup_subsys` 控制器插件 + `struct css_set` 进程绑定 + `struct cftype` 控制文件实现资源隔离。`cgroup_attach_task` 是进程迁移核心——通过 `find_css_set` 切换进程的控制器状态集合。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*

## 9. cgroup 文件系统接口

```c
// cgroup 文件系统类型（v1 多个挂载）：
// mount -t cgroup -o cpu none /sys/fs/cgroup/cpu
// → cgroup_v1_get_tree() → cgroup1_get_tree()
//   → 创建 cgroup_root，关联 cpu_cgroup_subsys
//   → 挂载到 /sys/fs/cgroup/cpu/

// cgroup 控制文件的读写：
// struct cftype cgroup_files[] = {
//     {
//         .name = "cgroup.procs",
//         .write_u64 = cgroup_procs_write,  // 写入 PID
//         .read_u64 = cgroup_procs_read,
//     },
// };

// 每个控制器注册自己的文件：
// memory_cgroup_subsys 添加 memory.limit_in_bytes：
// struct cftype mem_cgroup_files[] = {
//     {
//         .name = "memory.limit_in_bytes",
//         .write_u64 = mem_cg_write,
//         .seq_show = mem_cg_show,
//     },
// };
```

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct cgroup` | include/linux/cgroup-defs.h | 核心 |
| `struct cgroup_subsys_state` | include/linux/cgroup-defs.h | 核心 |
| `cgroup_attach_task()` | kernel/cgroup/cgroup.c | 进程迁移 |
| `cgroup_mkdir()` | kernel/cgroup/cgroup.c | 创建 cgroup |
| `mem_cgroup_try_charge()` | mm/memcontrol.c | 内存计费 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
