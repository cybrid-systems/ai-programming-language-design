# 093-cgroup-v1 — Linux cgroup v1 资源控制框架深度源码分析

## 0. 概述

**cgroup v1** 是第一代 Linux 资源控制框架（2006 年引入），将进程分组并按组限制资源。每个子系统管理一种资源：cpu、memory、blkio、net_prio 等。

---

## 1. 核心数据结构

```c
struct cgroup {                             // 每个 cgroup 实例
    unsigned long flags;                    // CGRP_* 标志
    struct list_head sibling;               // 兄弟链表
    struct list_head children;              // 子 cgroup 链表
    struct cgroup_subsys_state *subsys[CGROUP_SUBSYS_COUNT]; // 各子系统的状态
    struct kernfs_node *kn;                 // kernfs 节点（/sys/fs/cgroup/xxx）
};

struct cgroup_subsys_state {                // 每个子系统的 per-cgroup 状态
    struct cgroup *cgroup;                  // 所属 cgroup
    struct cgroup_subsys *ss;               // 所属子系统
    unsigned long flags;                    // CSS_* 标志
};
```

## 2. 子系统类型

| 子系统 | 控制 | 控制器文件 |
|--------|------|-----------|
| cpu | CPU 时间 | cpu.shares, cpu.cfs_quota_us |
| cpuacct | CPU 使用统计 | cpuacct.stat, cpuacct.usage |
| memory | 内存使用与限制 | memory.limit_in_bytes, memory.usage_in_bytes |
| blkio | 块设备 I/O | blkio.throttle.read_bps_device |
| devices | 设备访问 | devices.list, devices.allow |
| net_prio | 网络优先级 | net_prio.ifpriomap |
| freezer | 冻结/恢复 | freezer.state |

## 3. 内存 cgroup 示例

```
/sys/fs/cgroup/memory/mycontainer/
  memory.limit_in_bytes = 1G      # 最多使用 1G
  memory.usage_in_bytes           # 当前使用量
  memory.failcnt                  # 超限次数
  memory.kmem.limit_in_bytes      # 内核内存限制
```

## 4. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct cgroup` | include/linux/cgroup-defs.h | 核心 |
| `struct cgroup_subsys_state` | include/linux/cgroup-defs.h | 核心 |
| `cgroup_attach_task()` | kernel/cgroup/cgroup.c | 进程迁移 |
| `cgroup_mkdir()` | kernel/cgroup/cgroup.c | 创建 cgroup |
| `mem_cgroup_try_charge()` | mm/memcontrol.c | 内存计费 |
