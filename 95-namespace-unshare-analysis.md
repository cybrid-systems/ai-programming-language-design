# namespace — 命名空间深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/nsproxy.c` + `kernel/namespace.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**命名空间** 隔离系统资源（PID、网络、挂载点等），是容器技术的基石。

---

## 1. 命名空间类型

```c
// include/linux/nsproxy.h — 命名空间类型
enum {
    CLONE_NEWUTS   = (1 << 12),   // UTS 命名空间（主机名/域名）
    CLONE_NEWIPC    = (1 << 7),    // IPC 命名空间（System V IPC）
    CLONE_NEWUSER   = (1 << 18),   // User 命名空间（UID/GID 映射）
    CLONE_NEWPID    = (1 << 14),   // PID 命名空间（进程 ID 隔离）
    CLONE_NEWNET    = (1 << 15),   // Network 命名空间（网络栈隔离）
    CLONE_NEWCGROUP = (1 << 24),   // Cgroup 命名空间
    CLONE_NEWTIME   = (1 << 25),   // Time 命名空间（4.18+）
};
```

---

## 2. nsproxy — 命名空间代理

```c
// include/linux/nsproxy.h — nsproxy
struct nsproxy {
    // 各命名空间指针
    struct uts_namespace          *uts_ns;      // UTS
    struct ipc_namespace          *ipc_ns;      // IPC
    struct mnt_namespace          *mnt_ns;      // Mount
    struct pid_namespace          *pid_ns;      // PID
    struct net                     *net_ns;      // Network
    struct cgroup_namespace       *cgroup_ns;   // Cgroup

    // 计数
    atomic_t                count;               // 引用计数
};
```

### 2.1 copy_namespaces — 复制命名空间

```c
// kernel/fork.c — copy_namespaces
int copy_namespaces(struct task_struct *tsk, struct nsproxy *old_nsproxy)
{
    struct nsproxy *nsproxy;

    // 1. 分配新的 nsproxy
    nsproxy = kmem_cache_zalloc(nsproxy_cachep, GFP_KERNEL);

    // 2. 如果 CLONE_NEWUTS，复制 UTS 命名空间
    if (flags & CLONE_NEWUTS)
        nsproxy->uts_ns = copy_utsname(old_nsproxy->uts_ns);
    else
        nsproxy->uts_ns = old_nsproxy->uts_ns;
        get_uts_ns(nsproxy->uts_ns);

    // 3. 对每个命名空间类似处理...

    // 4. 增加到当前进程
    tsk->nsproxy = nsproxy;

    return 0;
}
```

---

## 3. unshare — 创建新命名空间

```c
// kernel/nsproxy.c — sys_unshare
SYSCALL_DEFINE1(unshare, unsigned long, unshare_flags)
{
    struct nsproxy *new_nsproxy;
    int err;

    // 1. 分配新的 nsproxy
    new_nsproxy = kmem_cache_zalloc(nsproxy_cachep, GFP_KERNEL);

    // 2. 根据 flags 创建新的命名空间
    if (unshare_flags & CLONE_NEWUTS) {
        err = unshare_utsname(&new_nsproxy->uts_ns);
        if (err) goto out;
    }

    if (unshare_flags & CLONE_NEWUSER) {
        err = unshare_user_ns(&new_nsproxy->user_ns);
        if (err) goto out;
    }

    // 3. 替换当前进程的 nsproxy
    switch_task_namespaces(current, new_nsproxy);

    return 0;
out:
    return err;
}
```

---

## 4. setns — 加入已有命名空间

```c
// kernel/nsproxy.c — sys_setns
SYSCALL_DEFINE3(setns, int, fd, int, nstype)
{
    struct file *file;
    struct nsproxy *new_nsproxy;
    struct ns_common *ns;

    // 1. 获取指向命名空间的文件
    file = fdget(fd);
    if (!file)
        return -EBADF;

    // 2. 获取命名空间类型
    ns = get_ns(file);

    // 3. 检查类型是否匹配
    if (nstype && ns->ops->type != nstype)
        return -EINVAL;

    // 4. 获取现有的 nsproxy
    new_nsproxy = create_new_nsproxy(ns);

    // 5. 替换当前命名空间
    switch_task_namespaces(current, new_nsproxy);

    return 0;
}
```

---

## 5. /proc/PID/ns — 命名空间文件

```
/proc/1234/ns/
├── uts          ← UTS 命名空间（可打开用于 setns）
├── ipc          ← IPC 命名空间
├── mnt          ← Mount 命名空间
├── pid          ← PID 命名空间
├── net          ← Network 命名空间
├── user         ← User 命名空间
└── cgroup       ← Cgroup 命名空间

# 通过绑定挂载隐藏命名空间：
mount --bind /proc/1234/ns/net /var/run/netns/mynet
```

---

## 6. User 命名空间特别说明

```c
// user 命名空间允许普通用户创建特权操作：
//   - 普通用户可以映射自己的 UID 到 0（root）
//   - 在 user 命名空间内可以挂载文件系统
//   - 为容器提供"假 root"
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/nsproxy.h` | `struct nsproxy` |
| `kernel/nsproxy.c` | `sys_unshare`、`sys_setns` |
| `kernel/fork.c` | `copy_namespaces` |