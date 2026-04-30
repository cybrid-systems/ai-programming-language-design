# namespace / unshare — Linux 命名空间深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/nsproxy.c` + `kernel/fork.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Linux namespace** 隔离全局系统资源，让进程/容器拥有独立的视图。`unshare()` 创建新的命名空间，`setns()` 加入已有命名空间。

---

## 1. 命名空间类型

```c
// include/linux/sched.h — clone_flags（CLONE_NEW*）
#define CLONE_NEWUTS     0x04000000  // UTS（主机名/域名）
#define CLONE_NEWIPC     0x08000000  // IPC（信号量/共享内存/消息队列）
#define CLONE_NEWUSER    0x10000000  // User（用户/组 ID 映射）
#define CLONE_PID        0x20000000  // PID（仅对 init 有效）
#define CLONE_NEWNET     0x40000000  // Network（网络设备/路由/防火墙）
#define CLONE_NEWCGROUP  0x02000000  // Cgroup（cgroup 命名空间）
#define CLONE_NEWPID     0x20000000  // PID（进程 ID）

// 组合：
//   unshare(CLONE_NEWNET | CLONE_NEWUTS) → 创建网络+主机名命名空间
```

---

## 2. 核心数据结构

### 2.1 nsproxy — 命名空间代理

```c
// include/linux/nsproxy.h — nsproxy
struct nsproxy {
    // 各命名空间
    struct uts_namespace   *uts_ns;       // UTS（主机名/域名）
    struct ipc_namespace   *ipc_ns;       // IPC（System V IPC）
    struct mnt_namespace   *mnt_ns;       // Mount（文件系统挂载点）
    struct pid_namespace   *pid_ns;       // PID（进程 ID）
    struct net             *net_ns;       // Network（网络设备/栈）
    struct cgroup_namespace *cgroup_ns;    // Cgroup

    // 引用计数
    atomic_t                count;         // 使用计数
};

// 全局初始 nsproxy：
extern struct nsproxy init_nsproxy;
```

### 2.2 nsproxy 与 task_struct 的关联

```c
// include/linux/sched.h — task_struct
struct task_struct {
    // ...
    struct nsproxy          *nsproxy;      // 命名空间代理
    // ...
};
```

---

## 3. unshare 系统调用

```c
// kernel/fork.c — sys_unshare
SYSCALL_DEFINE1(unshare, unsigned long, unshare_flags)
{
    struct nsproxy *old_nsproxy, *new_nsproxy;
    int err;

    // 1. 检查权限
    if (unshare_flags & CLONE_NEWUSER)
        // 需要 CAP_SYS_ADMIN
        if (!capable(CAP_SYS_ADMIN))
            return -EPERM;

    // 2. 分配新的 nsproxy
    new_nsproxy = create_new_namespaces(unshare_flags,
                                         current->nsproxy,
                                         current_user_ns(),
                                         current->fs);
    if (IS_ERR(new_nsproxy))
        return PTR_ERR(new_nsproxy);

    // 3. 切换到新的 nsproxy
    old_nsproxy = current->nsproxy;
    rcu_assign_pointer(current->nsproxy, new_nsproxy);

    // 4. 释放旧的 nsproxy
    put_nsproxy(old_nsproxy);

    return 0;
}
```

---

## 4. setns — 加入命名空间

```c
// kernel/fork.c — sys_setns
SYSCALL_DEFINE2(setns, int, fd, int, nstype)
{
    struct file *file;
    struct ns_common *ns;
    struct nsproxy *new_nsproxy;
    int err;

    // 1. 获取指向命名空间的文件描述符
    file = fget(fd);
    ns = file->private_data;  // ns_common

    // 2. 验证类型
    if (nstype && ns->ops->parent != ns->ops)
        // 检查命名空间类型匹配

    // 3. 替换当前进程的 nsproxy
    new_nsproxy = current->nsproxy;
    err = ns->ops->install(new_nsproxy, ns);

    return err;
}
```

---

## 5. /proc/PID/ns — 命名空间文件

```
/proc/PID/ns/          ← 每个命名空间一个文件
  uts                   ← UTS 命名空间
  ipc                   ← IPC 命名空间
  user                  ← User 命名空间
  pid                   ← PID 命名空间
  net                   ← Network 命名空间
  cgroup                ← Cgroup 命名空间

# 查看进程所属命名空间：
ls -la /proc/$$/ns/

# 通过文件描述符保持命名空间 alive：
touch /var/run/myns.uts
mount --bind /proc/$$/ns/uts /var/run/myns.uts
```

---

## 6. User 命名空间（CLONE_NEWUSER）

```c
// User 命名空间允许普通用户创建"假的" uid/gid 映射：
// 在容器内是 root (uid=0)，在宿主机可能是普通用户

// 映射配置：
//   uid_map:  容内uid → 容外uid
//   gid_map:  容内gid → 容外gid

// 示例（通过 newuidmap）：
// newuidmap pid 0 1000 1 1    # 容内 uid 0 → 容外 uid 1000

// /proc/PID/uid_map 格式：
//   inside_id  outside_id  count
//   0          1000000     65536     # 容器内 uid 0-65535 → 容外 1000000-1065535
```

---

## 7. Network 命名空间（CLONE_NEWNET）

```network namespace 包含：
- 网络设备（eth0、veth 对端）
- 协议栈（IP 路由表、iptables 规则）
- 端口号（每个 namespace 独立）
- /proc/sys/net

// 示例：
ip netns add myns            # 创建网络命名空间
ip link set veth0 netns myns # 把设备移到 namespace
```

---

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/nsproxy.h` | `struct nsproxy` |
| `kernel/nsproxy.c` | `create_new_namespaces`、`copy_namespaces` |
| `kernel/fork.c` | `sys_unshare`、`sys_setns` |
| `include/linux/sched.h` | `CLONE_NEW*` 标志 |