# Linux Kernel namespace / unshare 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/nsproxy.c` + `kernel/fork.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：CLONE_NEWUTS/USER/PID/NET/IPC/CGROUP

---

## 1. namespace 类型

| CLONE_ | namespace | 隔离内容 |
|--------|-----------|---------|
| CLONE_NEWUTS | UTS | hostname、domainname |
| CLONE_NEWIPC | IPC | System V msg/sem/shm、POSIX msg |
| CLONE_NEWPID | PID | 进程 ID |
| CLONE_NEWNET | NET | 网络设备、路由、端口 |
| CLONE_NEWUSER | USER | UID/GID 映射 |
| CLONE_NEWCGROUP | CGROUP | cgroup 目录视图 |
| CLONE_NEWNS | MOUNT | 挂载点 |

---

## 2. 核心数据结构

### 2.1 nsproxy — 命名空间代理

```c
// kernel/nsproxy.c — nsproxy
struct nsproxy {
    atomic_t              count;              // 引用计数

    // UTS 命名空间（hostname/domainname）
    struct uts_namespace *uts_ns;           // 行 40

    // IPC 命名空间
    struct ipc_namespace *ipc_ns;          // 行 43

    // 挂载命名空间
    struct mnt_namespace *mnt_ns;           // 行 46

    // PID 命名空间
    struct pid_namespace *pid_ns;           // 行 49

    // 网络命名空间
    struct net           *net_ns;            // 行 52

    // cgroup 命名空间
    struct cgroup_namespace *cgroup_ns;    // 行 55
};
```

### 2.2 unshare — 创建新 namespace

```c
// kernel/fork.c — _do_sys_unshare
long do_unshare(unsigned long unshare_flags)
{
    struct nsproxy *new_nsproxy;
    struct cred *new_cred;

    // 1. 分配新的 nsproxy
    new_nsproxy = create_new_namespaces(unshare_flags, current->nsproxy);

    // 2. 切换到新的 nsproxy
    switch_namespaces(current, new_nsproxy);

    return 0;
}
```

---

## 3. 参考

| 文件 | 函数 |
|------|------|
| `kernel/nsproxy.c` | `struct nsproxy` |
| `kernel/fork.c` | `_do_sys_unshare` |
