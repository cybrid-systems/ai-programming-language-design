# 128-ptrace — 读 kernel/ptrace.c

---

## ptrace 系统调用的分发

（`kernel/ptrace.c` L1388）

`sys_ptrace(request, pid, addr, data)` 是一个向目标进程注入调试操作的系统调用。它的工作方式是分发器——根据 request 参数跳到对应的处理函数。

最常见的 request 类型：

- `PTRACE_ATTACH` / `PTRACE_SEIZE` → `ptrace_attach(task, request, addr, flags)`（L409）
- `PTRACE_DETACH` → `ptrace_detach(child, data)`（L564）
- `PTRACE_PEEKTEXT` / `PTRACE_PEEKDATA` → `ptrace_access_vm`（L44）
- `PTRACE_CONT` / `PTRACE_SYSCALL` / `PTRACE_SINGLESTEP` → 修改 tracee 的寄存器状态后恢复执行
- `PTRACE_INTERRUPT` → 中断 tracee（SEIZE 模式专用）

但理解 ptrace 的入口不算难。真正的复杂度在它的跟踪模式。

---

## ptrace_attach——跟踪关系的建立

（`kernel/ptrace.c` L409）

`ptrace_attach` 做了四件事：

### 安全检查

```c
if (task->flags & PF_KTHREAD)    return -EPERM;     // 不能 attach 内核线程
if (same_thread_group(task, current)) return -EPERM; // 不能 attach 自己
scoped_cond_guard(mutex_intr, ...) {
    scoped_guard(task_lock, task) {
        retval = __ptrace_may_access(task, PTRACE_MODE_ATTACH_REALCREDS);
        // 这个调用执行所有 LSM 检查——SELinux、Apparmor、Yama
    }
}
```

`__ptrace_may_access` 的检查链：`ptracer_capable`（CAP_SYS_PTRACE）→ 同 uid 检查 → `security_ptrace_access_check`（LSM 钩子）。Yama LSM 额外检查 `/proc/sys/kernel/yama/ptrace_scope`：

- 0: 任意进程可 attach
- 1: 只能 attach 子进程
- 2: CAP_SYS_PTRACE 才可 attach
- 3: 完全禁止

### 设置 PT_PTRACED 标志

```c
if (request == PTRACE_SEIZE) {
    flags = PT_PTRACED | PT_SEIZED | (flags << PT_OPT_FLAG_SHIFT);
} else {
    flags = PT_PTRACED;  // PTRACE_ATTACH
}
task->ptrace = flags;
```

`PT_SEIZED` 标志区分两种 attach 模式：
- ATTACH：发送 SIGSTOP，强制 tracee 进入 TASK_TRACED
- SEIZE：不发送任何信号，不改变 tracee 的执行状态

### 建立跟踪关系

```c
ptrace_link(task, current);
```

`ptrace_link` 将 tracee 的 `ptrace_entry` 加入 tracer 的 `ptraced` 链表，并将 `task->parent` 重定向为 tracer：

```c
list_add(&child->ptrace_entry, &new_parent->ptraced);
child->parent = new_parent;
```

此后 tracee 的 parent 不再是原来的父进程，而是 tracer。当 tracee 退出时，SIGCHLD 发往 tracer。

### 等待 JOBCTL_TRAPPING 完成

```c
wait_on_bit(&task->jobctl, JOBCTL_TRAPPING_BIT, TASK_KILLABLE);
```

如果 tracee 正在执行 ptrace_stop 的过渡中，这个 wait 确保 tracer 等到 transition 完成才能继续操作。

---

## ptrace_stop——信号的截获

（`kernel/signal.c` L2351）

ptrace 的核心设计是信号截获。当 tracee 收到一个信号时——在 `get_signal()` 的处理流程中——`ptrace_stop()` 被调用：

```c
// 在 get_signal() 的循环中，如果 ptrace 跟踪状态被设置：
// tracee 进入 TASK_TRACED 状态
// tracee 调用 schedule() 让出 CPU
// tracer 在 wait4() 中观察到 tracee 进入 STOP 状态
// tracer 检查/修改 tracee 的寄存器状态
// tracer 调用 PTRACE_CONT / PTRACE_SYSCALL / PTRACE_SINGLESTEP 恢复 tracee
// tracee 从 schedule() 返回，继续执行
```

TASK_TRACED 是一个特殊的调度状态——它不在运行队列中，也不被信号唤醒。只有 tracer 显式调用 PTRACE_CONT 才能让 tracee 恢复执行。

---

## ptrace 的安全模型

ptrace 的权限在历史上多次被加固（CVE-2019-13272 是典型的时间战漏洞）：

```c
// ptrace_attach 的完整安全链：
// 1. PF_KTHREAD → 禁止 attach 内核线程
// 2. same_thread_group → 禁止 attach 自己
// 3. __ptrace_may_access → LSM + capability 检查
// 4. cred_guard_mutex → 与 exec 互斥
// 5. task->ptrace 非零检查 → 禁止重复 attach
// 6. task->exit_state → 禁止 attach 正在退出的进程
```

其中第 4 点 `cred_guard_mutex` 的互斥是最关键也是最容易被忽略的：在 ptrace attach 的过程中，tracee 不能同时进行 exec，因为 exec 会改变安全凭证——如果 tracer 在安全检查通过后、tracee 的 exec 完成后才真正建立跟踪关系，tracee 可能已经变成一个更高权限的进程（suid 程序）。`cred_guard_mutex` 防止了这个竞争。
