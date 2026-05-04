# 127-process-lifecycle — fork → exec → exit：读 kernel/fork.c 和 kernel/exit.c

---

## kernel_clone——fork 的闸门

（`kernel/fork.c` L2672）

所有创建新进程的系统调用——`sys_fork`（L2803）、`sys_vfork`（L2819）、`sys_clone`、`sys_clone3`（L3006）——最终汇聚到 `kernel_clone`。

**但这只是一个中介函数。** 它会做几件事：

1. 处理 CLONE_EMPTY_MNTNS → 隐式解为 CLONE_NEWNS
2. 检查 CLONE_PIDFD 与 CLONE_PARENT_SETTID 的兼容性（clone3 修复的问题）
3. 决定 ptrace 事件类型（FORK/VFORK/CLONE）
4. **调用 copy_process** 创建新线程
5. `wake_up_new_task(p)` 让新线程进入调度器
6. 如果是 vfork，等待子进程的 `completion`
7. 返回 PID

其中第 5 步 `wake_up_new_task` 被注释说"线程指针在之后可能失效，因为线程可能快速退出"——这反映了多线程程序一个根本问题：你刚创建的线程可能已经死了。

但 `kernel_clone` 的简洁性掩盖了 `copy_process` 的复杂度。

---

## copy_process——新进程的诞生

（`kernel/fork.c` L1967）

`copy_process` 约 200 行。它的工作是**从零创建一个 task_struct**，逐资源拷贝。

### task_struct 分配

```c
// L2022
p = dup_task_struct(current, node);
```

`dup_task_struct` 在 slab cache 中分配新的 `task_struct`（slab cache 在 `fork_init` 时创建），然后将当前进程的 task_struct 整体 `memcpy` 到新结构。这意味着新进程开始时拥有与父进程**完全相同**的调度参数、信号状态、安全凭证。

然后重置子进程特有字段：
- `p->state = TASK_NEW`——不是 TASK_RUNNING，任务被创建后处于 NEW 状态
- `p->on_cpu = 0`
- `p->pid = alloc_pid(...)`——分配 PID（在 `copy_process` 末尾）

### 资源拷贝的决定树

每个资源的拷贝策略由 clone_flags 决定——`copy_semundo()` 到 `copy_thread()` 的调用序列就是一张"clone flags → 资源共享 vs 深拷贝"的映射表：

```
!CLONE_SIGHAND  → copy_sighand()       // 独立信号处理表
 CLONE_SIGHAND  → atomic_inc(&sighand->count)  // 共享

!CLONE_FILES    → dup_fd()             // 深拷贝 fd 表
 CLONE_FILES    → atomic_inc(&files->count)    // 共享

!CLONE_VM       → dup_mm(mm)           // 新地址空间（COW）
 CLONE_VM       → mmget(mm)            // 共享地址空间（线程）

!CLONE_THREAD   → copy_signal()        // 新 signal_struct
 CLONE_THREAD   → atomic_inc(&signal->count)   // 共享

!CLONE_FS       → copy_fs()            // 新 fs_struct（cwd/umask/root）
 CLONE_FS       → atomic_inc(&fs->count)        // 共享
```

**关于 CLONE_VM 的说明**：`dup_mm` 并不立刻复制所有物理页面。它复制 `mm_struct` 的元数据（vma 红黑树等），但物理页通过写时拷贝（COW）延迟复制。`dup_mmap()` 将父进程的所有 vma 逐条拷贝到子进程，但新 vma 的物理页标记为只读——谁先写，谁分配新页。这就是 fork 为什么快——元数据拷贝是纳秒级的，物理页拷贝是微秒级的，但延迟到了实际写入时才发生。

### copy_thread——子进程的寄存器上下文

`copy_thread` 是架构相关的。在 x86-64 上：

```c
// 将父进程的内核栈上的 pt_regs 拷贝到子进程
memcpy(new_sp, regs, sizeof(*regs));

// 将子进程的返回地址设为 ret_from_fork
// 这是关键设计：当子进程第一次被 schedule() 选中时，
// 它从 ret_from_fork 开始执行，而不是从 fork 系统调用的中间
// -> 子进程的栈上有伪造的"系统调用返回"上下文
// -> ret_from_fork 直接跳到 syscall_exit_to_user_mode
// -> 子进程回到用户空间 fork() 调用的返回点
// -> 返回 0（这是子进程的 PID = 0 的原因）
```

子进程看起来像是从 fork() 系统调用中返回到用户空间——它得到 0。父进程得到子进程的 PID。

### 发布前的不一致窗口

`alloc_pid` 实际上在 `copy_process` 的尾部调用，但**进程在 `copy_process` 完成前对全局不可见**：

```c
// L330 — 将 PID 从占位符替换为实际指针
idr_replace(&upid->ns->idr, pid, upid->nr);

// L336 — 返回后，kernel_clone 调用 wake_up_new_task 使进程可见
```

这个两阶段设计（先分配、后发布）保证如果 `copy_process` 在中期失败，idr 中不会留下孤儿条目。

---

## do_exit——进程的终结

（`kernel/exit.c` L895）

`do_exit` 把进程拥有的资源逐一归还，然后将自己交给调度器。关键步骤：

```
do_exit(code)
  │
  ├─ 0. 设置 PF_EXITING（防止再次调用）
  │
  ├─ 1. exit_signals(tsk)     // 清理信号状态
  │    → 将线程私有 pending 信号合并到进程组
  │    → 如果是最后一个线程，发送 SIGCHLD
  │
  ├─ 2. exit_mm()             // 释放地址空间
  │    → mmput(mm) → 如果 mm 引用归零 → exit_mmap
  │
  ├─ 3. exit_sem()            // 释放 IPC 信号量撤销操作
  ├─ 4. __exit_files(tsk)     // 关闭文件描述符
  ├─ 5. __exit_fs(tsk)        // 释放 fs_struct（cwd/umask）
  ├─ 6. exit_namespace(tsk)   // 释放命名空间引用
  ├─ 7. exit_task_work(tsk)
  ├─ 8. exit_taskstack(tsk)   // 释放内核栈
  │
  ├─ 9. exit_notify(tsk)      // 通知父进程 + 子进程托管
  │    → 如果父进程正在 wait：发 SIGCHLD
  │    → 子进程托管给 init 或 subreaper
  │    → 决定是否进入僵尸状态（保留 task_struct）
  │
  └─ schedule()               // 不再返回
       BUG();                  // 如果 schedule 返回（不应该发生）
```

**僵尸进程出现的位置**：`exit_notify` 中，内核检查父进程是否已经通过 `wait4()` 获取了子进程的退出状态。如果父进程尚未 wait，子进程的 `task_struct` **保留**在系统中——这就是僵尸（TASK_DEAD 状态）。僵尸持有的资源只有 `task_struct` + 内核栈（已释放地址空间、fd 表等）。

---

## do_group_exit——线程组退出

（`kernel/exit.c` L1092）

与 `do_exit` 不同——`do_group_exit` 是`进程组`的退出：

```c
do_group_exit(int exit_code)
{
    // 设置 SIGNAL_GROUP_EXIT
    signal->flags |= SIGNAL_GROUP_EXIT;
    signal->group_exit_code = exit_code;

    // 当前线程带头退出
    do_exit(exit_code);

    // 其他线程在 get_signal() 中看到 SIGNAL_GROUP_EXIT
    // → 自动调用 do_exit()
    // → 整个进程组退出
}
```

**sys_exit（exit 系统调用）** 调用 `do_exit`，**sys_exit_group** 调用 `do_group_exit`。区别：exit 只退出当前线程，exit_group 杀死整个进程组。

---

## fork 的性能陷阱

fork 的延迟来自 `copy_process` 中的资源拷贝：

| 操作 | 延迟来源 | 优化手段 |
|------|---------|---------|
| `dup_task_struct` | memcpy 整个 task_struct | 使用 slab cache（零初始化） |
| `dup_mm` | VMA 红黑树拷贝 + 页表复制 | COW 延迟物理页拷贝 |
| `dup_fd` | fd 表深拷贝 | 使用 CLONE_FILES 共享 |
| `alloc_pid` | IDR 分配 | PID 编号 O(1) 分配 |
| `copy_sighand` | 信号处理表拷贝 | 使用 CLONE_SIGHAND 共享 |

现代 Web 服务器使用 `clone(CLONE_VM | CLONE_THREAD | ...)` 创建线程，只拷贝 task_struct，地址空间和 fd 表共享，因此线程创建比进程创建快一个数量级。
