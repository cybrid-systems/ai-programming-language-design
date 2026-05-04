# 129-pid-namespace — 读 kernel/pid.c

---

## alloc_pid 的两阶段分配

（`kernel/pid.c` L159）

PID 分配分两阶段：结构体分配 + ID 分配。

### 阶段一：pid 结构体

```c
pid = kmem_cache_alloc(ns->pid_cachep, GFP_KERNEL);  // L177
pid->level = ns->level;
refcount_set(&pid->count, 1);
for (type = 0; type < PIDTYPE_MAX; ++type)
    INIT_HLIST_HEAD(&pid->tasks[type]);
```

`struct pid` 本身是一个引用计数对象。它的核心是 `tasks[PIDTYPE_MAX]`——每个 PID 类型（PID/PGID/SID/TGID）对应一个 hlist 链表，链着使用这个 PID 的所有 task_struct。

### 阶段二：ID 分配

```c
// L220 — 从最内层到最外层，在每层命名空间中分配 ID
for (tmp = ns, i = ns->level; i >= 0;) {
    int tid = set_tid[ns->level - i];

    if (tid) {
        // clone3 CLONE_SET_TID：调用者指定 PID
        nr = idr_alloc(&tmp->idr, NULL, tid, tid + 1, GFP_ATOMIC);
    } else {
        // 正常分配：从 idr 中拿一个空闲编号
        nr = idr_alloc_cyclic(&tmp->idr, NULL, pid_min, pid_max, GFP_ATOMIC);
    }

    pid->numbers[i].nr = nr;
    pid->numbers[i].ns = tmp;
    tmp->pid_allocated++;
    i--;
}
```

`pid->numbers[]` 数组是这个设计的核心。每个元素对应一个命名空间层级，记录该进程在那个命名空间中的 PID 编号和所属命名空间。

```
例如，level 2 命名空间中创建的进程：
struct pid {
    .level = 3,
    .numbers[0]: { .nr=1280, .ns=&init_pid_ns }    // 在根 ns 中是 1280
    .numbers[1]: { .nr=52,   .ns=&ns_level1 }       // 在 level 1 中是 52
    .numbers[2]: { .nr=5,    .ns=&ns_level2 }        // 在 level 2 中是 5
    .numbers[3]: { .nr=1,    .ns=&ns_level3 }        // 在 level 3 中是 1（PID 1）
};
```

容器中看到的 PID 1，在宿主机上可能是 1280。`getpid()` 返回的是当前命名空间中的 PID，通过 `pid->numbers[ns->level].nr` 查得。

### 发布

```c
// L330 — copy_process 中调用
idr_replace(&upid->ns->idr, pid, upid->nr);
```

`idr_replace` 将 `alloc_pid` 阶段分配的 NULL 占位符替换为真正的 pid 指针。此后，`find_pid_ns(nr, ns)` 才能找到这个 PID。

---

## find_pid_ns——PID 查找

（`kernel/pid.c` L368）

```c
struct pid *find_pid_ns(int nr, struct pid_namespace *ns)
{
    return idr_find(&ns->idr, nr);
}
```

`idr_find` 是基数树（radix tree）的 O(1) 查找。`find_task_by_vpid(nr)` 包装了这个调用——它在当前进程的命名空间中查找 PID，然后通过 `pid_task(pid, PIDTYPE_PID)` 返回 task_struct。

---

## 命名空间边界的可见性

```c
// kernel/pid.c L560
pid_t __task_pid_nr_ns(struct task_struct *task, enum pid_type type,
                       struct pid_namespace *ns)
{
    if (!ns)
        ns = task_active_pid_ns(current);
    // 只在 ns->level <= task->pid->level 时查找
    // 即父命名空间能看到子命名空间中的进程
    // 但子命名空间看不到父命名空间中的进程
    nr = pid_nr_ns(rcu_dereference(*task_pid_ptr(task, type)), ns);
}
```

如果目标进程在请求的命名空间中不可见（`ns->level > pid->level`），返回 0。这使得容器的 init 进程看不到宿主机上的其他进程——`kill(1, SIGTERM)` 在容器内发送给容器自身的 PID 1，而不是宿主机的 init。

---

## pidfd——无竞争的进程引用

`pidfd_open(pid, flags)` 在 `kernel/pid.c` L695 实现。它打开一个指向进程的文件描述符，持有 `struct pid` 的引用计数：

```c
// pidfd_open → 找到 pid → 创建匿名文件
// file->private_data = get_pid(pid)  // 引用+1
// 返回 fd

// 通过 pidfd 发送信号：
// pidfd_send_signal(fd, sig, info, flags)
// → file->private_data → struct pid
// → pid_task(pid, PIDTYPE_TGID) → task_struct
// → send_signal_locked
```

pidfd 解决了传统 PID 的重用问题：如果你持有 pidfd，即使目标进程退出、PID 被回收再分配，`pidfd_send_signal` 仍然只发给原来的进程（因为持有的是 `struct pid *`，不是数字 PID）。
