# 094-namespace-unshare — Linux 命名空间系统深度源码分析

## 0. 概述

**命名空间（namespace）** 是 Linux 容器化的基础，每个进程运行在自己独立的命名空间视图中。存在 8 种命名空间类型：

---

## 1. 命名空间类型

| 类型 | 常量 | 隔离的资源 | 引入版本 |
|------|------|-----------|---------|
| Mount | CLONE_NEWNS | 文件系统挂载点 | 2.4.19 |
| PID | CLONE_NEWPID | 进程 ID | 3.8 |
| Network | CLONE_NEWNET | 网络设备、IP 地址 | 2.6.24 |
| IPC | CLONE_NEWIPC | System V IPC、POSIX 消息队列 | 2.6.19 |
| UTS | CLONE_NEWUTS | 主机名、域名 | 2.6.19 |
| User | CLONE_NEWUSER | UID/GID 映射 | 3.8 |
| Cgroup | CLONE_NEWCGROUP | cgroup 根目录 | 4.6 |
| Time | CLONE_NEWTIME | 系统时间偏移 | 5.6 |

## 2. 核心数据结构

```c
struct nsproxy {
    atomic_t count;
    struct uts_namespace *uts_ns;
    struct ipc_namespace *ipc_ns;
    struct mnt_namespace *mnt_ns;
    struct pid_namespace *pid_ns_for_children;
    struct net           *net_ns;
    struct time_namespace *time_ns;
    struct cgroup_namespace *cgroup_ns;
};
```

每个进程通过 `task_struct->nsproxy` 指向其命名空间视图。

## 3. unshare 系统调用

```
unshare(CLONE_NEWNS | CLONE_NEWNET | CLONE_NEWPID)
  └─ unshare_nsproxy_namespaces()
       └─ 对每个请求的命名空间类型：
            create_new_namespaces(flags, ...)
              → 分配新的 nsproxy
              → 对每种命名空间调用对应的 copy_*_ns() 函数
              → 返回新的 nsproxy
         └─ switch_task_namespaces(current, new_ns)
```

## 4. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct nsproxy` | include/linux/nsproxy.h | 核心 |
| `unshare_nsproxy_namespaces()` | kernel/nsproxy.c | 相关 |
| `create_new_namespaces()` | kernel/nsproxy.c | 相关 |
| `copy_pid_ns()` | kernel/pid_namespace.c | PID 命名空间 |
| `copy_net_ns()` | net/core/net_namespace.c | 网络命名空间 |
| `copy_mnt_ns()` | fs/namespace.c | 挂载命名空间 |
