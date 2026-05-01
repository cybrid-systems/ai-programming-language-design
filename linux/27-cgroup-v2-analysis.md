# 27-cgroup v2 — 控制组第二版深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**cgroup v2（Control Group Version 2）** 是 Linux 资源管理的统一框架，自 Linux 4.5 开始稳定。与 v1 不同，v2 统一了进程层次结构和资源控制器（subsystem）的组织，强制使用单一层次树（unified hierarchy）。

核心功能：限制、审计、隔离进程组的 CPU/内存/IO 等资源使用。

doom-lsp 确认 `kernel/cgroup/cgroup.c` 包含约 349+ 个符号。

---

## 1. 核心数据结构

### 1.1 struct cgroup

```c
struct cgroup {
    struct cgroup_subsys_state __rcu *self; // 自身的 css
    unsigned long              flags;       // 状态标志
    int                        id;          // 唯一 ID

    struct cgroup_file         procs_file;  // cgroup.procs
    struct cgroup_file         events_file; // cgroup.events

    struct cgroup *parent;         // 父 cgroup
    struct list_head children;     // 子 cgroup 链表
    struct list_head cset_links;   // 关联的 cset

    struct cgroup_base_stat      stat;      // 基础统计
    struct cgroup *nr_descendants; // 后代数量
    ...
};
```

---

## 2. 层次结构

```
/sys/fs/cgroup/              ← 根 cgroup
  ├── system.slice/           ← 系统服务
  │   ├── sshd.service/
  │   └── systemd-journald/
  ├── user.slice/             ← 用户会话
  │   └── user-1000.slice/
  └── docker/                 ← 容器
      └── <container_id>/
```

---

## 3. 核心操作

```
cgroup_mkdir(parent_cgroup, "mygroup")    ← 创建 cgroup
  │
  ├─ 创建目录对应的 kernfs 节点
  ├─ 分配 struct cgroup
  ├─ 创建子控制器界面文件
  └─ 加入父 cgroup 的 children 链表

写 cgroup.procs：
  │
  ├─ cgroup_procs_write()
  │    └─ cgroup_attach_task(cgrp, task)
  │         ├─ 从旧 cgroup 移除
  │         ├─ 加入新 cgroup
  │         └─ 更新所有相关控制器的状态
```

---

## 4. v2 的关键改进

| 特性 | v1 | v2 |
|------|-----|-----|
| 层次结构 | 每控制器独立树 | 统一树（single hierarchy）|
| 线程粒度 | 仅进程 | 支持 threaded mode |
| 控制器内嵌 | 可任意组合 | 所有控制器绑定同一层次 |
| 资源上限 | per-controller | unified limit |

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
