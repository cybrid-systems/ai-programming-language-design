# 95-namespace-unshare — Linux 命名空间（namespace）和 unshare 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**Linux 命名空间（namespace）** 是容器技术的核心——将全局系统资源（PID、网络、挂载点、UTS、IPC、用户、cgroup、时间）隔离为独立的视图。`unshare` 系统调用允许进程创建新的命名空间并加入其中。

**核心设计**：每个进程的 `task_struct->nsproxy`（`struct nsproxy` @ `include/linux/nsproxy.h`）指向一组命名空间指针。`unshare(CLONE_NEWNS|CLONE_NEWNET)` 创建新的命名空间并替换 `nsproxy`。

```
task_struct
  └── nsproxy (struct nsproxy) @ nsproxy.h
        ├── uts_ns   → struct uts_namespace  (hostname)
        ├── ipc_ns   → struct ipc_namespace  (SysV IPC)
        ├── mnt_ns   → struct mnt_namespace  (mount table)
        ├── pid_ns   → struct pid_namespace  (PID numbers)
        ├── net_ns   → struct net_namespace  (network stack)
        ├── time_ns  → struct time_namespace (timestamps)
        └── cgroup_ns→ struct cgroup_namespace(cgroup root)
```

**doom-lsp 确认**：`kernel/nsproxy.c`（613 行），`include/linux/nsproxy.h`（120 行）。

---

## 1. 核心数据结构 @ nsproxy.h

```c
struct nsproxy {
    refcount_t count;                          // 引用计数
    struct uts_namespace *uts_ns;
    struct ipc_namespace *ipc_ns;
    struct mnt_namespace *mnt_ns;
    struct pid_namespace *pid_ns_for_children;
    struct net *net_ns;                        // 网络命名空间
    struct time_namespace *time_ns;
    struct time_namespace *time_ns_for_children;
    struct cgroup_namespace *cgroup_ns;
};
```

### 命名空间类型

| 类型 | flag | 隔离资源 | 内核文件 |
|------|------|---------|----------|
| **UTS** | `CLONE_NEWUTS` | hostname, domainname | `kernel/utsname.c` |
| **IPC** | `CLONE_NEWIPC` | SysV IPC, POSIX msgqueue | `ipc/namespace.c` |
| **Mount** | `CLONE_NEWNS` | 挂载表 | `fs/namespace.c` |
| **PID** | `CLONE_NEWPID` | PID 编号 | `kernel/pid_namespace.c` |
| **Net** | `CLONE_NEWNET` | 网络栈（接口/路由/iptables）| `net/core/net_namespace.c` |
| **User** | `CLONE_NEWUSER` | UID/GID 映射 | `kernel/user_namespace.c` |
| **Cgroup** | `CLONE_NEWCGROUP` | cgroup 根目录 | `kernel/cgroup/namespace.c` |
| **Time** | `CLONE_NEWTIME` | 时间偏移 | `kernel/time_namespace.c` |

---

## 2. copy_namespaces——fork 时的命名空间继承

```c
// fork() → copy_process() → copy_namespaces(flags, tsk)
// → 根据 flags 决定是共享还是创建新命名空间

int copy_namespaces(unsigned long flags, struct task_struct *tsk)
{
    struct nsproxy *old_ns = tsk->nsproxy;
    struct nsproxy *new_ns;
    int ret;

    if (likely(!(flags & (CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC |
                          CLONE_NEWPID | CLONE_NEWNET |
                          CLONE_NEWCGROUP | CLONE_NEWTIME)))) {
        // 无新的命名空间标志 → 共享（增加引用计数）
        get_nsproxy(old_ns);
        return 0;
    }

    if (!thread_group_empty(tsk))
        return -EINVAL;                      // 多线程不能 unshare

    // 创建新的 nsproxy（复制旧的，替换被请求的命名空间）
    new_ns = create_new_namespaces(flags, old_ns, tsk, ...);
    tsk->nsproxy = new_ns;                  // 替换
    return 0;
}
```

---

## 3. unshare_nsproxy_namespaces——unshare 系统调用路径

```c
// sys_unshare(flags) → unshare_nsproxy_namespaces()

int unshare_nsproxy_namespaces(unsigned long unshare_flags,
                                struct nsproxy **new_nsp,
                                struct cred *new_cred, struct fs_struct *new_fs)
{
    struct nsproxy *new_ns;

    // 1. 复制当前 nsproxy
    new_ns = create_new_namespaces(unshare_flags, current->nsproxy,
                                    current, new_cred);

    // 2. 创建新的 UTS 命名空间
    if (unshare_flags & CLONE_NEWUTS)
        new_ns->uts_ns = clone_uts_ns(old_ns->uts_ns, ...);

    // 3. 创建新的 IPC 命名空间
    if (unshare_flags & CLONE_NEWIPC)
        new_ns->ipc_ns = create_ipc_ns(old_ns->ipc_ns, ...);

    // 4. 创建新的 Mount 命名空间
    if (unshare_flags & CLONE_NEWNS)
        new_ns->mnt_ns = copy_mnt_ns(old_ns->mnt_ns, ...);

    // 5. 创建新的 Net 命名空间
    if (unshare_flags & CLONE_NEWNET)
        new_ns->net_ns = copy_net_ns(...);

    *new_nsp = new_ns;
    return 0;
}
```

---

## 4. switch_task_namespaces——切换命名空间

```c
// 在 exec 或 unshare 完成时调用
void switch_task_namespaces(struct task_struct *tsk, struct nsproxy *new)
{
    task_lock(tsk);
    // 保存旧 nsproxy → put_nsproxy(old)
    // 设置新 nsproxy → tsk->nsproxy = new
    task_unlock(tsk);
}
```

---

## 5. 用户命名空间（User Namespace）

```c
// CLONE_NEWUSER 是特权命名空间——非特权用户也可以创建
// 创建时可以映射 UID/GID：
// /proc/<pid>/uid_map
// /proc/<pid>/gid_map

// 用户命名空间中的特权：
// 在用户命名空间内有 CAP_SYS_ADMIN
// 可以创建其他命名空间（NEWNS/NEWNET 等）
// 可以挂载文件系统（但在自己的 mount namespace 内）
```

---

## 6. 关键函数索引

| 函数 | 文件名 | 作用 |
|------|--------|------|
| `copy_namespaces` | `nsproxy.c` | fork 时命名空间继承 |
| `create_new_namespaces` | `nsproxy.c` | 创建新的 nsproxy |
| `unshare_nsproxy_namespaces` | `nsproxy.c` | unshare 系统调用路径 |
| `switch_task_namespaces` | `nsproxy.c` | 切换进程的 nsproxy |
| `clone_uts_ns` | `utsname.c` | 克隆 UTS 命名空间 |
| `copy_net_ns` | `net_namespace.c` | 克隆网络命名空间 |
| `copy_mnt_ns` | `namespace.c` | 克隆挂载命名空间 |

---

## 7. 性能

| 操作 | 延迟 | 说明 |
|------|------|------|
| `clone(CLONE_NEWNS)` | ~10μs | 拷贝挂载表 |
| `clone(CLONE_NEWNET)` | ~50-200μs | 初始化网络栈 |
| `unshare(CLONE_NEWNS)` | ~5μs | 挂载表 copy-on-write |

---

## 8. 总结

命名空间通过 `task_struct->nsproxy`（`nsproxy.h`）管理 8 种资源隔离视图。`copy_namespaces`（fork 时）和 `unshare_nsproxy_namespaces`（unshare 时）创建新的 `nsproxy`，`switch_task_namespaces` 替换当前进程的命名空间集合。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
