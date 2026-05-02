# 95-namespace-unshare — Linux 命名空间（namespace）系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**Linux 命名空间（namespace）** 是容器技术的核心隔离机制——将全局系统资源（PID、网络、挂载点、主机名、IPC、时间、cgroup、用户）划分为独立视图。`unshare` 系统调用创建新命名空间，`setns` 加入已有命名空间，`clone` 在创建进程时指定新命名空间。

**核心设计**：每个进程的 `task_struct->nsproxy` 指针（`struct nsproxy` @ `include/linux/nsproxy.h`）指向 8 种命名空间指针。`copy_namespaces`（fork 时@ `nsproxy.c:169`）和 `unshare_nsproxy_namespaces`（unshare 时 @ `:211`）通过 `create_new_namespaces`（`:88`）创建新的 `nsproxy`，逐个子命名空间调用 `copy_*_ns()` 克隆。

```
fork() → copy_process()            unshare(CLONE_NEWNS)
  → copy_namespaces(flags, tsk)      → unshare_nsproxy_namespaces()
    → create_new_namespaces()          → create_new_namespaces()
      → copy_mnt_ns(flags, ...)           → copy_mnt_ns(CLONE_NEWNS, ...)
      → copy_utsname(flags, ...)          → copy_utsname(0, ...)
      → copy_ipcs(flags, ...)             → copy_ipcs(0, ...)
      → copy_pid_ns(flags, ...)          → copy_pid_ns(0, ...)
      → copy_net_ns(flags, ...)           → copy_net_ns(0, ...)
    → tsk->nsproxy = new_ns            → *new_nsp = new_ns
```

**doom-lsp 确认**：`kernel/nsproxy.c`（613 行，28 符号）。`create_new_namespaces` @ `:88`，`copy_namespaces` @ `:169`，`unshare_nsproxy_namespaces` @ `:211`，`switch_task_namespaces` @ `:245`。

---

## 1. 核心数据结构 @ nsproxy.h

```c
// include/linux/nsproxy.h
struct nsproxy {
    refcount_t count;                          // 引用计数（共享 nsproxy 的进程数）
    struct uts_namespace *uts_ns;              // hostname/domainname
    struct ipc_namespace *ipc_ns;              // SysV IPC / POSIX 消息队列
    struct mnt_namespace *mnt_ns;              // 挂载表
    struct pid_namespace *pid_ns_for_children;  // 子进程 PID 编号
    struct net *net_ns;                        // 网络栈（接口、路由、iptables）
    struct time_namespace *time_ns;            // 当前时间命名空间
    struct time_namespace *time_ns_for_children; // 子进程时间命名空间
    struct cgroup_namespace *cgroup_ns;        // cgroup 根目录
};

// 全局初始命名空间（init 进程使用）：
extern struct nsproxy init_nsproxy;
```

### 命名空间类型与标志

| 类型 | flag | 隔离资源 | copy 函数 | 内核文件 |
|------|------|---------|-----------|----------|
| **Mount** | `CLONE_NEWNS` | 挂载表 | `copy_mnt_ns` | `fs/namespace.c` |
| **UTS** | `CLONE_NEWUTS` | hostname, domainname | `copy_utsname` | `kernel/utsname.c` |
| **IPC** | `CLONE_NEWIPC` | SysV IPC | `copy_ipcs` | `ipc/namespace.c` |
| **PID** | `CLONE_NEWPID` | PID 编号 | `copy_pid_ns` | `kernel/pid_namespace.c` |
| **Net** | `CLONE_NEWNET` | 网络栈 | `copy_net_ns` | `net/core/net_namespace.c` |
| **User** | `CLONE_NEWUSER` | UID/GID 映射 | `copy_user_ns` | `kernel/user_namespace.c` |
| **Cgroup** | `CLONE_NEWCGROUP` | cgroup 根 | `copy_cgroup_ns` | `kernel/cgroup/namespace.c` |
| **Time** | `CLONE_NEWTIME` | 时间偏移 | `copy_time_ns` | `kernel/time_namespace.c` |

---

## 2. create_new_namespaces @ :88——核心创建函数

```c
static struct nsproxy *create_new_namespaces(u64 flags,
    struct task_struct *tsk, struct user_namespace *user_ns,
    struct fs_struct *new_fs)
{
    struct nsproxy *new_nsp;

    // 1. 分配新的 nsproxy
    new_nsp = create_nsproxy();                  // kmem_cache_alloc(nsproxy_cachep)
    refcount_set(&new_nsp->count, 1);

    // 2. 逐个子命名空间：如果 flags 中有对应 CLONE_NEW* 位
    //    则创建新命名空间，否则共享（增加引用计数）
    //
    // 每个 copy_*_ns 的模式：
    //   if (flags & CLONE_NEWXXX)
    //       return clone_new_xxx(...)    // 创建新的独立实例
    //   else
    //       return get_xxx(old_ns)       // 增加引用（共享）

    new_nsp->mnt_ns = copy_mnt_ns(flags, tsk->nsproxy->mnt_ns, user_ns, new_fs);
    new_nsp->uts_ns = copy_utsname(flags, user_ns, tsk->nsproxy->uts_ns);
    new_nsp->ipc_ns = copy_ipcs(flags, user_ns, tsk->nsproxy->ipc_ns);
    new_nsp->pid_ns_for_children = copy_pid_ns(flags, user_ns, ...);
    new_nsp->cgroup_ns = copy_cgroup_ns(flags, user_ns, ...);
    new_nsp->net_ns = copy_net_ns(flags, user_ns, tsk->nsproxy->net_ns);
    new_nsp->time_ns_for_children = copy_time_ns(flags, user_ns, ...);
    new_nsp->time_ns = get_time_ns(tsk->nsproxy->time_ns);  // 共享

    // 3. 错误回滚（goto out_* 逐层释放已分配的资源）
    return new_nsp;
}
```

---

## 3. copy_namespaces @ :169——fork 时的命名空间继承

```c
// fork() → copy_process() → copy_namespaces(flags, tsk)

int copy_namespaces(u64 flags, struct task_struct *tsk)
{
    struct nsproxy *old_ns = tsk->nsproxy;
    struct nsproxy *new_ns;

    // 快速路径：没有新命名空间标志 → 直接共享
    if (likely(!(flags & (CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC |
                          CLONE_NEWPID | CLONE_NEWNET |
                          CLONE_NEWCGROUP | CLONE_NEWTIME)))) {
        get_nsproxy(old_ns);              // 引用计数 +1
        return 0;
    }

    // 多线程不能 unshare 命名空间
    if (!thread_group_empty(tsk))
        return -EINVAL;

    // 创建新的命名空间
    new_ns = create_new_namespaces(flags, tsk, user_ns, tsk->fs);
    if (IS_ERR(new_ns))
        return PTR_ERR(new_ns);

    // 替换进程的 nsproxy
    tsk->nsproxy = new_ns;
    return 0;
}
```

---

## 4. unshare_nsproxy_namespaces @ :211——unshare 系统调用

```c
// sys_unshare(flags) → unshare_nsproxy_namespaces()

int unshare_nsproxy_namespaces(unsigned long unshare_flags,
    struct nsproxy **new_nsp, struct cred *new_cred, struct fs_struct *new_fs)
{
    u64 flags = unshare_flags;

    // 1. 检查是否需要操作命名空间
    if (!(flags & (CLONE_NS_ALL & ~CLONE_NEWUSER)))
        return 0;                            // 没有命名空间操作

    // 2. 权限检查
    user_ns = new_cred ? new_cred->user_ns : current_user_ns();
    if (!ns_capable(user_ns, CAP_SYS_ADMIN))
        return -EPERM;

    // 3. 创建新的命名空间
    *new_nsp = create_new_namespaces(flags, current, user_ns,
                                     new_fs ? new_fs : current->fs);
    return 0;
}
```

---

## 5. switch_task_namespaces @ :245——切换进程的 nsproxy

```c
// unshare/setns 完成后调用——替换进程的命名空间指针
void switch_task_namespaces(struct task_struct *p, struct nsproxy *new)
{
    struct nsproxy *ns;

    task_lock(p);                             // 保护 task_struct 修改
    ns = p->nsproxy;
    p->nsproxy = new;                         // 替换指针
    task_unlock(p);

    if (ns)
        put_nsproxy(ns);                      // 释放旧 nsproxy
}
```

---

## 6. setns——加入已有命名空间

```c
// sys_setns(fd, nstype) — 通过 fd 加入已有命名空间
SYSCALL_DEFINE2(setns, int, fd, int, nstype)
{
    // 1. proc_ns_file = fget(fd) 获取 fd 指向的 proc_ns 文件
    //    → /proc/<pid>/ns/net, /proc/<pid>/ns/mnt 等

    // 2. struct ns_common *ns = proc_ns_file->private_data;

    // 3. validate_nsset() 验证新命名空间的合法性

    // 4. commit_nsset() → switch_task_namespaces(current, new_nsproxy)
    //    → task_lock(current)
    //    → current->nsproxy = new_ns
    //    → task_unlock(current)
}
```

---

## 7. 容器创建示例

```c
// clone(CLONE_NEWNS|CLONE_NEWUTS|CLONE_NEWIPC|CLONE_NEWPID|
//       CLONE_NEWNET|CLONE_NEWUSER, ...)
// → copy_process() → copy_namespaces()
//   → create_new_namespaces()
//     → copy_mnt_ns(CLONE_NEWNS, ...)  — 新的挂载表
//     → copy_utsname(CLONE_NEWUTS, ...) — 新的主机名
//     → copy_net_ns(CLONE_NEWNET, ...)  — 新的网络栈
//     → copy_pid_ns(CLONE_NEWPID, ...)  — 新的 PID 空间
//     → copy_user_ns(CLONE_NEWUSER, ...) — 新的 UID 映射
```

---

## 8. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `create_nsproxy` | `:54` | 分配 nsproxy 对象 |
| `create_new_namespaces` | `:88` | 逐子命名空间创建/共享 |
| `copy_namespaces` | `:169` | fork 时调用 |
| `unshare_nsproxy_namespaces` | `:211` | unshare 时调用 |
| `switch_task_namespaces` | `:245` | 切换进程 nsproxy |
| `exit_nsproxy_namespaces` | `:263` | 进程退出清理 |
| `validate_nsset` | `:398` | setns 命名空间验证 |
| `commit_nsset` | `:535` | setns 最终提交 |

---

## 9. 调试

```bash
# 查看进程的命名空间
ls -la /proc/self/ns/
# total 0
# lrwxrwxrwx ... cgroup -> 'cgroup:[4026531835]'
# lrwxrwxrwx ... ipc    -> 'ipc:[4026531839]'
# lrwxrwxrwx ... mnt    -> 'mnt:[4026531840]'
# lrwxrwxrwx ... net    -> 'net:[4026532009]'
# lrwxrwxrwx ... pid    -> 'pid:[4026531836]'
# lrwxrwxrwx ... user   -> 'user:[4026531837]'
# lrwxrwxrwx ... uts    -> 'uts:[4026531838]'

# 命名空间个数
cat /proc/self/status | grep NS

# 加入命名空间
nsenter -t <pid> -n -m /bin/bash
```

---

## 10. 总结

命名空间通过 `task_struct->nsproxy` 管理 8 种资源隔离视图。`create_new_namespaces`（`:88`）逐个子命名空间调用 `copy_*_ns`（按 `CLONE_NEW*` 标志判定创建或共享）。`copy_namespaces`（`:169`）在 fork 时调用，`unshare_nsproxy_namespaces`（`:211`）在 unshare 时调用，`switch_task_namespaces`（`:245`）最终替换进程的 `nsproxy` 指针。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
