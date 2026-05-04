# Linux PID 分配与 PID 命名空间深度分析

## 概述

进程 ID（PID）是 Linux 内核中每个进程和线程的唯一标识符。与直觉相反，PID 在内核中并不是字符串或路径，而是一个**引用计数的对象**（`struct pid`），通过 IDR（基数树）在一个或多个 PID 命名空间中进行分配和查找。

PID 命名空间（`struct pid_namespace`）是 Linux 容器化的基石：每个容器在自己的 PID 命名空间中看到 PID 从 1 开始的进程树，而同一个进程在不同命名空间中有不同的虚拟 PID（vpid）。

## 核心数据结构

### struct pid — PID 对象

（`include/linux/pid.h` L58~70）

```c
struct pid {
    refcount_t          count;              // L59 — 引用计数
    unsigned int        level;              // L60 — 该 PID 可见的命名空间层级数
    spinlock_t          lock;               // L61 — 保护 tasks 链表
    struct {
        u64             ino;                // L63 — pidfs inode 号
        struct rhash_head pidfs_hash;       // L64 — pidfs rhashtable 节点
        struct dentry   *stashed;           // L65 — pidfs dentry 缓存
        struct pidfs_attr *attr;            // L66 — pidfs 属性缓存
    };
    /* lists of tasks that use this pid */
    struct hlist_head   tasks[PIDTYPE_MAX]; // L69 — 每个 PID 类型一个链表
    struct hlist_head   inodes;             // L70 — 关联的 inode 列表
};
```

关键设计：`tasks[PIDTYPE_MAX]` 数组。`enum pid_type`（`include/linux/pid.h` 附近）定义了：

```c
enum pid_type {
    PIDTYPE_PID,      // 线程 ID（task 唯一）
    PIDTYPE_TGID,     // 线程组 ID（进程 ID）
    PIDTYPE_PGID,     // 进程组 ID
    PIDTYPE_SID,      // 会话 ID
    PIDTYPE_MAX,
};
```

每个 PID 对象维护了**当前命名空间下所有使用该 PID 的进程**的链表。例如，一个 PID 值可能被多个线程共享 `PIDTYPE_TGID`，同时每个线程有自己的 `PIDTYPE_PID` 条目。

### struct upid — 层级 PID

（`include/linux/pid.h` L53~56）

```c
struct upid {
    int                 nr;     // L54 — 在该命名空间中的 PID 值
    struct pid_namespace *ns;   // L55 — 所属命名空间
};
```

`struct pid` 实际上是多个 `upid` 的合集，每个层级一个。`pid->level` 表示该 PID 对象跨越的命名空间层级数。当创建一个 PID 时，内核会在所有祖先命名空间中分配一个 `upid` 条目。

```
例如，在 level 2 的命名空间中创建的进程：
struct pid {
    .level = 3,   // init_pid_ns (level 0) + 3 个嵌套命名空间
    .numbers[0]: { .nr=1280, .ns=&init_pid_ns }
    .numbers[1]: { .nr=52,   .ns=&ns_level1   }
    .numbers[2]: { .nr=5,    .ns=&ns_level2   }
    .numbers[3]: { .nr=1,    .ns=&ns_level3   }  // 容器内看到 PID 1
};
```

### struct pid_namespace — PID 命名空间

（`include/linux/pid_namespace.h` L26~41）

```c
struct pid_namespace {
    struct idr              idr;            // L27 — PID 分配器（IDR 基数树）
    struct rcu_head         rcu;            // L28 — RCU 回调
    unsigned int            pid_allocated;  // L29 — 已分配的 PID 数量
#ifdef CONFIG_SYSCTL
    struct ctl_table_set    set;            // L34 — sysctl 表
    struct ctl_table_header *sysctls;       // L35 — sysctl 头部
#endif
    struct task_struct      *child_reaper;  // L37 — 该命名空间的 init 进程（收尸者）
    struct kmem_cache       *pid_cachep;    // L38 — PID 对象 slab cache
    unsigned int            level;          // L39 — 命名空间层级（0 = init_pid_ns）
    int                     pid_max;        // L40 — 最大 PID 值
    struct pid_namespace    *parent;        // L41 — 父命名空间
};
```

- `child_reaper`：在命名空间内承担 init 进程角色（PID 1）。如果容器内 init 退出，整个命名空间被终结。
- `idr`：IDR 基数树（`struct idr`）是 PID 分配的核心数据结构，O(1) 查找和分配。
- `pid_max`：命名空间的最大 PID 值（默认 4194304，受 `kernel/pid_max` 控制）。

## PID 分配：alloc_pid()

（`kernel/pid.c` L159~340）

```c
struct pid *alloc_pid(struct pid_namespace *ns, pid_t *arg_set_tid,
                      struct pid_namespace **arg_set_tid_ns)
```

这是 PID 分配的核心函数，在 `copy_process()` 中被调用。

### 分配流程

```
alloc_pid(ns, set_tid, set_tid_ns)
  │
  ├─ 1. 计算层级
  │     level = ns->level      // 命名空间的嵌套深度
  │     sizeof(numbers) = (level + 1) × sizeof(struct upid)
  │
  ├─ 2. 分配 PID 对象
  │     pid = kmem_cache_alloc(ns->pid_cachep, GFP_KERNEL)
  │     pid->level = level
  │
  ├─ 3. 从最内层到最外层，在每个命名空间中分配 PID 编号
  │     for (i = level; i >= 0; i--) {
  │         tmp = ns;               // 从当前 ns 开始向上层遍历
  │         for (j = i; j < level; j++)
  │             tmp = tmp->parent;  // 向 root 方向走 level-i 级
  │
  │         nr = alloc_pididr(tmp, ...)
  │         // 在 tmp->idr 中分配一个空闲 ID
  │
  │         pid->numbers[i].nr = nr;
  │         pid->numbers[i].ns = tmp;
  │
  │         // 如果 arg_set_tid 指定了特定 PID，用 idr_replace 替换（L330~332）
  │     }
  │
  ├─ 4. 初始化 tasks 链表
  │     for (i = 0; i < PIDTYPE_MAX; i++)
  │         INIT_HLIST_HEAD(&pid->tasks[i])
  │     INIT_HLIST_HEAD(&pid->inodes)
  │
  └─ 5. 返回 pid（注意：尚未在 idr 中可见！
        需等 copy_process 完成后再调用 publish_pid() 使可见）
```

### IDR 分配细节

`alloc_pididr()` 内部使用 `idr_alloc()` 在命名空间的 IDR 树中分配编号：

```c
static int alloc_pididr(struct pid_namespace *ns, ...)
{
    return idr_alloc_cyclic(&ns->idr, NULL,
                           PIDNS_ADDING,           // 起始值（通常=1）
                           ns->pid_max,            // 最大值
                           GFP_KERNEL);
}
```

- `idr_alloc_cyclic()`：循环分配，从 1 到 `pid_max-1`
- 使用 `IDR_ALLOC_CYCLIC` 标志使分配位置滚动，避免 PID 重用时间窗口过短
- 初始分配 NULL 作为占位，等 copy_process 全部完成后通过 `publish_pid()` 替换为真正的 pid 指针

### PID 发布与可见性

`alloc_pid()` 分配的 PID 在 `copy_process()` 返回前不在 `idr` 中可见。可见性通过独立的发布步骤控制：

```c
// kernel/fork.c copy_process() 末尾
// L330: 在 idr 中替换占位的 NULL 为真正的 pid 指针
idr_replace(&upid->ns->idr, pid, upid->nr);

// 然后由 caller (kernel_clone) 调用 wake_up_new_task()
```

这个两阶段设计（先分配，后发布）确保了：
- 在 `copy_process()` 失败回滚时，不会在 idr 中留下无效条目
- 在进程完全初始化前，`find_pid_ns()` 不会找到它

## PID 查找体系

### 查找路径

```c
// 从 PID 编号找到 PID 对象
struct pid *find_pid_ns(int nr, struct pid_namespace *ns)   // kernel/pid.c L368
{
    return idr_find(&ns->idr, nr);
}

// 从 PID 对象找到 task_struct（特定 PID 类型）
struct task_struct *pid_task(struct pid *pid, enum pid_type type)  // L464
{
    struct task_struct *result = NULL;
    if (pid) {
        struct hlist_node *first;
        first = rcu_dereference_check(hlist_first_rcu(&pid->tasks[type]), ...);
        if (first)
            result = hlist_entry(first, struct task_struct, pid_links[type]);
    }
    return result;
}

// 常见封装
struct task_struct *find_task_by_vpid(pid_t vnr)   // L488 — 当前命名空间
    → pid_task(find_pid_ns(vnr, task_active_pid_ns(current)), PIDTYPE_PID)

struct task_struct *find_get_task_by_vpid(pid_t nr) // L493
    → get_pid_task(find_pid_ns(nr, task_active_pid_ns(current)), PIDTYPE_PID)
```

### attach_pid / detach_pid

当进程的 PID 类型状态变化时（如进程组组长变化），需要更新 `pid->tasks[]` 链表：

```c
void change_pid(struct task_struct *task, enum pid_type type, struct pid *pid)
{
    struct pid **pids = task->pids;     // task->pids[PIDTYPE_MAX] 数组
    struct pid *old_pid = *pids;
    ...
    hlist_del_rcu(&task->pid_links[type]);
    *pids = pid;
    hlist_add_head_rcu(&task->pid_links[type], &pid->tasks[type]);
    ...
}
```

## PID 命名空间层级

### init_pid_ns — 根命名空间

（`kernel/pid.c` 全局变量）

```c
struct pid_namespace init_pid_ns = {
    .level      = 0,
    .child_reaper = &init_task,   // PID 1 的 task_struct
    // ...
};
```

### 创建新的 PID 命名空间

（`kernel/nsproxy.c` — `create_new_namespaces()` / `kernel/pid_namespace.c` — `copy_pid_ns()`）

```c
struct pid_namespace *copy_pid_ns(unsigned long flags,
    struct user_namespace *user_ns, struct pid_namespace *old_ns)
```

1. **检查权限**：`CLONE_NEWPID` 需要 `CAP_SYS_ADMIN`
2. **创建新 ns**：`ns = kmem_cache_alloc(pid_ns_cachep, ...)`
3. **初始化 IDR**：`idr_init(&ns->idr)`
4. **设置层级**：`ns->level = old_ns->level + 1`
5. **设置 parent**：`get_pid_ns(old_ns)`
6. **设置 child_reaper**：`ns->child_reaper = current`
7. **初始化信号量**：`set_bit(0, ns->idr.idr_rt)` — 保留 PID 0

**关键行为**：
- 新命名空间中第一个进程（`child_reaper`）获得 PID 1
- 如果该进程退出，所有子进程被 SIGKILL，命名空间被销毁
- 父命名空间中的 PID 1 在子命名空间中不可见

### PID 可见性

```
init_pid_ns (level 0)        PID 1     PID 42     PID 100
      │                        │         │          │
ns_level_1 (level 1)         PID 1     PID 5      —不可见—
      │
ns_level_2 (level 2)         PID 1     —不可见—   —不可见—
```

- 进程在**当前命名空间和所有祖先命名空间**中有一个 PID
- 当前命名空间外的进程不可见（`find_task_by_vpid()` 只在当前 ns 中查找）
- 父命名空间可以看子命名空间（通过 `__task_pid_nr_ns()` 指定目标 ns）

## PID 回收：free_pid()

（`kernel/pid.c` L110~147）

```c
void free_pid(struct pid *pid)
```

1. **从所有层级命名空间的 idr 中移除**（L139~146）：
   ```c
   for (i = 0; i <= pid->level; i++) {
       struct upid *upid = pid->numbers + i;
       idr_remove(&upid->ns->idr, upid->nr);
       upid->ns->pid_allocated--;
   }
   ```

2. **RCU 回调释放 PID 对象**（L147）：
   ```c
   call_rcu(&pid->rcu, pid_free_rcu);
   ```

3. **PID 编号在 IDR 中变为可用**：新的 `alloc_pid()` 可能重用该编号。`idr_alloc_cyclic` 的循环分配模式最小化立即重用。

## 系统调用中的 PID 获取

（`kernel/sys.c` 中的 `sys_getpid`, `sys_gettid`, `sys_getppid` 等）

```c
// kernel/sys.c
SYSCALL_DEFINE0(getpid)
{
    return task_tgid_vnr(current);  // 当前命名空间的 TGID
}

SYSCALL_DEFINE0(gettid)
{
    return task_pid_vnr(current);   // 当前命名空间的 PID
}
```

`task_tgid_vnr()` 和 `task_pid_vnr()` 使用当前进程的 PID 命名空间（`task_active_pid_ns(current)`）查找 PID 值：

```c
// kernel/pid.c
pid_t __task_pid_nr_ns(struct task_struct *task, enum pid_type type,
                       struct pid_namespace *ns)
{
    pid_t nr = 0;
    rcu_read_lock();
    if (ns != task_active_pid_ns(task))     // 安全边界检查
        ns = task_active_pid_ns(task);
    if (likely(pid_alive(task))) {
        struct pid *pid = task->pids[type];  // 或 task_tgid/task_pid
        if (pid && ns->level <= pid->level)
            nr = pid->numbers[ns->level].nr;  // 取对应层级的编号
    }
    rcu_read_unlock();
    return nr;
}
```

关键：如果请求的 ns 层级大于 PID 对象的 level（跨命名空间看不可见的 PID），返回 0（即该进程在目标命名空间中不可见）。

## pidfd — PID 文件描述符

Linux 5.x 引入的 pidfd 机制提供了一种不使用数字 PID 来引用进程的方式，消除了其他操作系统常见的 PID 重用竞争问题。

### pidfd_open()

```c
// kernel/pid.c
SYSCALL_DEFINE2(pidfd_open, pid_t, pid, unsigned int, flags)
```

1. 通过 `find_get_pid(pid)` 在当前命名空间查找 PID 对象
2. 创建匿名文件（`anon_inode_getfd()`）：
   - file_operations = `pidfd_fops`
   - private_data = pid 对象（引用计数 +1）
3. 返回文件描述符

### pidfd 操作

```c
static const struct file_operations pidfd_fops = {
    .release    = pidfd_release,     // pid_put(pid)
    .poll       = pidfd_poll,        // 监听进程退出（POLLIN）
    .show_fdinfo= pidfd_show_fdinfo,
};
```

- `pidfd_poll()`：如果 `pid_task(pid, PIDTYPE_TGID)` 返回 NULL（进程已退出），返回 `POLLIN | POLLRDNORM`
- 与 `poll`/`epoll`/`select` 配合，实现进程退出的事件驱动等待
- `PIDFD_SIGNAL`：支持通过 `pidfd_send_signal()` 发送信号

### pidfd vs 传统 PID

| 特性 | 传统 PID | pidfd |
|------|---------|-------|
| 重用问题 | PID 可能被重用（违例） | pidfd 持有引用，有效直到 close |
| 安全检查 | 每次使用时需要检查 ns | 打开时一次 |
| 等待方式 | wait4() 阻塞 | poll/epoll 事件驱动 |
| 信号发送 | kill(pid, sig) | pidfd_send_signal(fd, sig, info, flags) |

### pidfs

从 Linux 6.x 开始，pidfs 提供了基于 inode 的 PID 引用，struct pid 中的 `ino`, `pidfs_hash`, `stashed`, `attr` 字段用于 pidfs 实现。这使得 `/proc/<pid>` 可以通过基于 dentry 的路径访问，而不需要每次转换数字 PID。

## 关键设计决策分析

### 1. 为什么 PID 用 IDR 而不是普通数组

早期 Linux（< 2.6）使用固定大小的 `pid_hash` 数组（位图 + 哈希冲突链接）。IDR（基数树）替代方案的优势：
- **稀疏性好**：不需要 `pid_max` 大小的连续数组
- **O(1) 查找**：基数树查找在常见深度下是常数时间
- **动态 UUID**：不需要预分配 PID 号范围
- **无上限扩展**：`pid_max` 仅受内存限制（约 400 万）

### 2. PID vs TGID 的分离

每个线程在 `task_struct` 中有两组 PID 指针：

```c
// include/linux/sched.h — task_struct 内
struct pid             *thread_pid;       // task->pids[PIDTYPE_PID]
struct pid             *pids[PIDTYPE_MAX];// 包含 PIDTYPE_PID, TGID, PGID, SID
```

- `task_struct->thread_pid`：线程自身的 PID（gettid 返回）
- `task_struct->signal->leader_pid`：进程组的 PID（getpid 返回）
- 多线程进程中，所有线程共享同一个 `PIDTYPE_TGID` 的 PID

### 3. child_reaper 与 PID 1 的特殊角色

PID 1（init 进程）在传统 Unix 和 Linux 中承担独特的职责：
- **孤儿收养**：任何父进程先退出的子进程，被 init 收养
- **僵尸回收**：init 负责 `wait4()` 回收所有僵尸
- **命名空间的终结**：在 PID 命名空间中，`child_reaper`（PID 1）退出时，内核杀死所有进程并销毁命名空间

```c
// kernel/pid_namespace.c — zap_pid_ns_processes()
void zap_pid_ns_processes(struct pid_namespace *pid_ns)
{
    // 向所有活着的进程发送 SIGKILL
    // 等待它们全部退出
    // 清空命名空间
}
```

### 4. 命名空间边界的 PID 转换

跨命名空间的进程操作需要 PID 转换。例如，`sys_kill()` 接收的是调用者命名空间中的 PID：

```c
// kernel/signal.c L3950
SYSCALL_DEFINE2(kill, pid_t, pid, int, sig)
{
    struct pid *p = find_vpid(pid);   // 当前命名空间查找
    return kill_pid_info(sig, info, p);
}
```

如果目标进程在当前命名空间中不可见，`find_vpid()` 返回 NULL，kill 返回 ESRCH。这使得容器无法影响在容器外的进程。

### 5. PID 的 RCU 保护

PID 查找路径是 RCU 保护的：

```c
// idr_find 本身是 RCU 安全
// pid_task 使用 rcu_dereference 访问 hlist
// 进程创建/退出时的 pid_link 操作使用 hlist_add_head_rcu / hlist_del_rcu
```

这使得 `find_task_by_vpid()` 路径不需要任何锁（除了 RCU read-side critical section），是高度优化的快速路径。

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct pid` | include/linux/pid.h | 58 |
| `struct upid` | include/linux/pid.h | 53 |
| `struct pid_namespace` | include/linux/pid_namespace.h | 26 |
| `enum pid_type` | include/linux/pid.h | (PIDTYPE_PID/TGID/PGID/SID) |
| `alloc_pid()` | kernel/pid.c | 159 |
| `free_pid()` | kernel/pid.c | 110 |
| `find_pid_ns()` | kernel/pid.c | 368 |
| `pid_task()` | kernel/pid.c | 464 |
| `find_task_by_vpid()` | kernel/pid.c | 488 |
| `find_get_task_by_vpid()` | kernel/pid.c | 493 |
| `get_pid_task()` | kernel/pid.c | 516 |
| `attach_pid()` | kernel/pid.c | 390 |
| `change_pid()` | kernel/pid.c | 427 |
| `__task_pid_nr_ns()` | kernel/pid.c | 232 |
| `sys_getpid()` | kernel/sys.c | (通过 task_tgid_vnr) |
| `init_pid_ns` | kernel/pid.c | 全局变量 |
| `copy_pid_ns()` | kernel/pid_namespace.c | 附近 |
| `zap_pid_ns_processes()` | kernel/pid_namespace.c | 附近 |
| `sys_pidfd_open()` | kernel/pid.c | (pidfd_open) |
| `pidfd_fops` | kernel/pid.c | (poll/release) |
