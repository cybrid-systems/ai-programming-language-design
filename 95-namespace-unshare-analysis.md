# Linux Kernel namespace / unshare 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/nsproxy.c`）

---

## 0. namespace 类型

```
CLONE_NEWUTS     — UTS 命名空间（hostname/domainname）
CLONE_NEWIPC     — IPC 命名空间（System V IPC、POSIX msg）
CLONE_NEWPID     — PID 命名空间（进程 ID 隔离）
CLONE_NEWNET     — 网络命名空间（网络设备/路由/端口）
CLONE_NEWUSER    — 用户命名空间（UID/GID 映射）
CLONE_NEWCGROUP  — cgroup 命名空间（cgroup 目录视图）
CLONE_NEWNS      — mount 命名空间（挂载点隔离）
```

---

## 1. 核心结构

```c
// kernel/nsproxy.c — nsproxy
struct nsproxy {
    atomic_t        count;
    struct uts_namespace *uts_ns;       // UTS
    struct ipc_namespace *ipc_ns;       // IPC
    struct mnt_namespace *mnt_ns;       // Mount
    struct pid_namespace *pid_ns;       // PID
    struct net      *net_ns;           // Network
    struct cgroup_namespace *cgroup_ns;  // cgroup
};
```

---

## 2. unshare

```c
// kernel/fork.c — _do_sys_unshare
// 创建新的 namespace（不启动新进程）

unshare(CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWNS);
// 相当于 clone(CLONE_NEW*)，但修改当前进程的 namespace
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `kernel/nsproxy.c` | `struct nsproxy` |
| `kernel/fork.c` | `_do_sys_unshare` |
