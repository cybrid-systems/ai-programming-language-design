# 183-cpuset — CPU集合调度深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/cgroup/cpuset.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**cpuset** 是 Linux 的 CPU/内存节点分配机制，通过 cgroup 接口将 CPU 核心和内存节点分配给特定进程组。

---

## 1. 核心概念

```
cpuset 将 CPU 分成多个集合：
  /sys/fs/cgroup/cpuset/
    /sys/fs/cgroup/cpuset/user/
      alice/   ← alice 的进程只能在这两个 CPU 上运行
        cpuset.cpus = "0-3"
        cpuset.mems = "0-1"
      bob/
        cpuset.cpus = "4-7"
        cpuset.mems = "2-3"
```

---

## 2. cpuset cgroup 控制器

```bash
# 查看当前 cpuset：
cat /proc/self/cpuset

# cpuset.cpus        — 可用 CPU（bitmask）
# cpuset.mems        — 可用内存节点（bitmask）
# cpuset.cpu_exclusive — 独占 CPU
# cpuset.mem_exclusive — 独占内存节点
# cpuset.sched_load_balance — 是否负载均衡
```

---

## 3. 西游记类喻

**cpuset** 就像"天庭的部门划分"——

> 天庭把天兵分成几个营（cpuset.cpus），每个营只能在自己的营地里活动（CPU 核心）。有的营是独占的（cpu_exclusive），有的营是共享的。同样，营地附近的粮仓（内存节点）也有划分（cpuset.mems），每个营只能从自己的粮仓取粮。这就是容器的 CPU 隔离机制——Docker 容器里的进程只能使用分配给它的 CPU 核心。

---

## 4. 关联文章

- **cgroup**（article 135）：cpuset 是 cgroup 的一个控制器
- **sched_domain**（article 184）：cpuset 影响负载均衡