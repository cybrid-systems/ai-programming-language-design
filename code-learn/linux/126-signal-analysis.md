# 126-signal — Linux 信号机制深度源码分析

## 读信号源码从何入手

信号处理横跨三个执行域，外加一组内核信号原语调用链。

- 用户空间通过 `kill/tkill/tgkill` 系统调用发送信号
- 内核内部通过 `send_signal()/force_sig()` 发送（如 SIGSEGV/SIGCHLD）
- 目标线程在返回用户空间前的一刹那（`exit_to_user_mode_loop`）处理信号
- 架构相关层在用户栈上构造 `rt_sigframe`，让信号处理函数在用户栈帧之上执行

最终，所有"发送信号"路径收敛到 `__send_signal_locked()`（L1040）。

本文从 `sys_kill` 入口开始，逐层下沉到 `complete_signal`，再逆向从目标线程的角度跟踪 get_signal→handle_signal→setup_rt_frame 的递送路径。

---

## 从 sys_kill 到 __send_signal_locked

```
用户: kill(pid, sig)
  ↓
SYSCALL_DEFINE2(kill, pid_t, pid, int, sig)      // L3950
  ↓
kill_something_info(sig, info, pid)               // L1570
  → 根据 pid 的正负/特殊值分发：
    pid > 0  → kill_pid_info(sig, info, pid)       // PID 转 task_struct
    pid = 0  → 发给当前进程组
    pid = -1 → 发给所有能发到的进程
    pid < -1 → 发给指定进程组 (-pid)
  ↓
kill_pid_info(sig, info, pid)
  → find_vpid(pid) → pid_task(pid, PIDTYPE_TGID)  // PID 到 task_struct
  → group_send_sig_info(sig, info, p, PIDTYPE_TGID)
  ↓
group_send_sig_info(sig, info, p, type)           // L1407
  → check_kill_permission(sig, info, p)            // 安全检查（LSM+capability）
  → do_send_sig_info(sig, info, p, type)
  ↓
do_send_sig_info(sig, info, p, type)               // L1260
  → send_signal_locked(sig, info, p, type)
  ↓
send_signal_locked(sig, info, p, type)             // L1181
  → __send_signal_locked(sig, info, p, type, force)
```

`sys_kill` 这个传参路径本身很直，看不出什么精妙之处。真正有趣的事情发生在 `__send_signal_locked` 内部——它在这个点上决定"这个信号真的要发出去吗？"

---

## __send_signal_locked 的决策树

（`kernel/signal.c` L1040 — 核心实现）

```
__send_signal_locked(sig, info, t, type, force)
  │
  ├─ 0. 持有 t->sighand->siglock（由 caller 保证）
  │     lockdep_assert_held(&t->sighand->siglock);
  │
  ├─ 1. prepare_signal(sig, t, force)
  │     这是信号发送的"闸门"——决定是否真的发送
  │     ├─ 如果进程已在退出（SIGNAL_GROUP_EXIT）：
  │     │   除非是 SIGKILL（coredump 时也要杀），否则丢弃
  │     │   
  │     ├─ 如果是 STOP 类信号（SIGTSTP/SIGTTIN/SIGTTOU）：
  │     │   从所有 pending 队列中清除 SIGCONT
  │     │   不能同时挂起一个 STOP 和一个 CONT 信号
  │     │   
  │     ├─ 如果是 SIGCONT：
  │     │   从所有 pending 队列中清除所有 STOP 信号
  │     │   唤醒被 STOP 的线程
  │     │   设置 SIGNAL_STOP_CONTINUED 标志
  │     │   这样父进程 wait4() 时看到 CLD_CONTINUED
  │     │   
  │     └─ 如果是会被忽略的信号（sig_task_ignored）：
  │          直接返回 false → 整个发送流程跳过
  │          这是信号发送的第一层优化——被忽略的信号不发
  │
  └─ 1b. 如果 prepare_signal 返回 false → 返回（不发送）
  │
  ├─ 2. 确定 pending 队列
  │     pending = (type != PIDTYPE_PID) ? &t->signal->shared_pending : &t->pending;
  │     sys_kill 的 type 是 PIDTYPE_TGID → 使用 shared_pending
  │     sys_tkill 的 type 是 PIDTYPE_PID → 使用线程私有 pending
  │
  ├─ 3. legacy_queue(pending, sig) — 标准信号同号合并
  │     static inline bool legacy_queue(struct sigpending *signals, int sig) {
  │         return (sig < SIGRTMIN) && sigismember(&signals->signal, sig);
  │     }
  │     标准信号已经在 pending 中了 → 跳过入队
  │     这就是"标准信号不可靠"的根源——同号合并
  │
  ├─ 4. SIGKILL 和内核线程不分配 sigqueue
  │     if ((sig == SIGKILL) || (t->flags & PF_KTHREAD))
  │         goto out_set;  // 只设位图，不入队
  │
  ├─ 5. 实时信号 vs 标准信号分流
  │     if (sig < SIGRTMIN) {
  │         // 标准信号：只更新 pending->signal 位图
  │         // 不入队，因为从来不会真正用到 siginfo
  │     } else {
  │         // 实时信号：必须分配 sigqueue 入队
  │         // 因为 siginfo 携带额外数据
  │         q = kmem_cache_alloc(sigqueue_cachep, ...);
  │         list_add_tail(&q->list, &pending->list);
  │     }
  │
  ├─ out_set: 更新 pending 位图（L1085）
  │     sigaddset(&pending->signal, sig);
  │     无论标准还是实时，位图都要更新
  │     位图用于 O(1) 的"有信号吗？"检查
  │
  └─ complete_signal(sig, t, type)  // L1089 — 投递决策
```

`legacy_queue` 只有一行代码：

```c
return (sig < SIGRTMIN) && sigismember(&signals->signal, sig);
```

这就是全部。没有复杂的算法，没有哈希表。标准信号（sig < SIGRTMIN）如果已经在 pending 位图中，跳过入队。这是 POSIX 规范允许的——标准信号不需要排队，丢失是"实现定义行为"。

实时信号（sig >= SIGRTMIN）不受 `legacy_queue` 检查——每次都入队，每次都分配一个 `sigqueue` 节点。

---

## 信号分类宏

（`include/linux/signal.h` — 决定信号行为的静态分类）

Linux 在编译时定义了三组信号分类，用于快速判断信号的行为：

```c
#define SIG_KERNEL_ONLY_MASK   sigmask(SIGKILL) | sigmask(SIGSTOP)
#define SIG_KERNEL_STOP_MASK   sigmask(SIGSTOP) | sigmask(SIGTSTP) | \
                               sigmask(SIGTTIN) | sigmask(SIGTTOU)
#define SIG_KERNEL_IGNORE_MASK sigmask(SIGCONT) | sigmask(SIGCHLD) | \
                               sigmask(SIGWINCH) | sigmask(SIGURG)

#define sig_kernel_only(sig)    siginmask(sig, SIG_KERNEL_ONLY_MASK)     // SIGKILL + SIGSTOP
#define sig_kernel_stop(sig)    siginmask(sig, SIG_KERNEL_STOP_MASK)     // STOP 类信号
#define sig_kernel_ignore(sig)  siginmask(sig, SIG_KERNEL_IGNORE_MASK)   // 默认忽略
```

这些分类用在：
- `prepare_signal`：判断 SIGNAL_GROUP_EXIT 时 SIGKILL 是唯一能穿透的信号（`sig_kernel_only`）
- `sig_task_ignored`：检查默认忽略的信号
- `flush_sigqueue_mask`：SIGCONT/SIGSTOP 互斥清除

---

## complete_signal——线程选择和唤醒

（`kernel/signal.c` L963）

```
complete_signal(sig, t, type)
  │
  ├─ SIGKILL 快速路径：
  │    如果发的是 SIGKILL，不用考虑线程选择——整个进程都要死
  │    设置 SIGNAL_GROUP_EXIT，遍历所有线程，逐个 force-wake
  │    __for_each_thread(signal, t)
  │        signal_wake_up(t, 1);  // 第二个参数 = resume（TASK_KILLABLE 也能唤醒）
  │
  └─ 非 SIGKILL：
       │
       ├─ 线程选择策略（L978-1020）：
       │    if (type == PIDTYPE_PID)
       │        has = t;  // tkill：指定线程
       │    else {
       │        // kill：选一个未被屏蔽的线程
       │        has = signal->curr_target;
       │        while (sigismember(&has->blocked, sig)) {
       │            has = next_thread(has, signal);
       │            if (has == signal->curr_target)
       │                break;  // 全都屏蔽了，发给 curr_target 也无用
       │        }
       │        signal->curr_target = has;  // 轮转
       │    }
       │
       │    关键理解：如果进程的所有线程都屏蔽了该信号
       │    信号仍然被标记为 pending——等线程解除屏蔽后才递送
       │    并不是"丢弃"
       │
       └─ signal_wake_up(has, 0)
              → set_tsk_thread_flag(t, TIF_SIGPENDING)
              → wake_up_state(t, TASK_INTERRUPTIBLE)
              → 如果进程已经在运行：kick_process(t)（发 IPI 确保检查）
```

**curr_target 轮转的设计意图**：
- 避免频繁信号（SIGIO/SIGURG/SIGWINCH）反复击中同一线程
- 不保证公平（不红黑树、不 O(log n)），只保证"下一把换个人"
- 这是"足够好直到糟糕"的工程取舍——信号发生的频率远低于调度 tick

---

## 信号递送——线程如何收到信号

信号没有立即执行。信号发送端的工作到此为止。等待信号被处理的是**接收端**——目标线程在以下时机检查 `TIF_SIGPENDING`：

1. 系统调用返回用户空间（`exit_to_user_mode_loop`）
2. 中断/异常返回用户空间
3. 从 `TASK_INTERRUPTIBLE` 睡眠中被唤醒后

```
exit_to_user_mode_loop(regs)
  └─ while (thread_info_flags & _TIF_SIGPENDING) {
         arch_do_signal_or_restart(regs);
     }
```

`arch_do_signal_or_restart` 分两步：

```
arch_do_signal_or_restart(regs)                        // arch/x86 L333
  │
  ├─ get_signal(&ksig)                                  // kernel/signal.c L2801
  │    从 pending 队列中取一个信号。
  │    处理优先级：
  │      SIGKILL → do_group_exit(0) [立即]
  │      SIGSTOP → do_signal_stop() [TASK_STOPPED]
  │      ptrace 截获 → 信号给调试器
  │      SIG_IGN → 丢弃，取下
  │      blocked → 跳过（等解除屏蔽）
  │      SIG_DFL → 按默认动作
  │      自定义 handler → 填充 ksignal 返回
  │
  └─ handle_signal(&ksig, regs)                         // arch/x86 L255
        → setup_rt_frame(ksig, regs)                   // arch/x86 L236
          → 在用户栈上分配 sigframe
          → 设置用户态栈：regs->sp = sigframe
          → 设置入口：regs->ip = handler
          → 设置参数：regs->di = sig, regs->si = siginfo, regs->dx = ucontext
        → set_current_blocked(blocked | sa_mask | sig)  // handler 执行期间屏蔽
```

---

## 信号与进程生命周期的交互

### SIGNAL_GROUP_EXIT

当进程收到 SIGKILL 或 `exit_group()` 被调用时：

```c
// 设置 SIGANL_GROUP_EXIT 标志
signal->flags |= SIGNAL_GROUP_EXIT;
signal->group_exit_code = code;

// 所有线程在 get_signal() 中看到此标志：
if (signal->flags & SIGNAL_GROUP_EXIT) {
    // 直接退出，不需要处理其他信号
    do_exit(signal->group_exit_code);
}
```

此后 `prepare_signal` 会丢弃所有非 SIGKILL 信号——正在死的进程不需要更多的中断。

### exit_signals——退出时的信号清理

（`kernel/signal.c` L3119）

```c
void exit_signals(struct task_struct *tsk)
{
    // 1. 将线程私有的 pending 信号合并到进程组 shared_pending
    // 2. 如果此线程是最后一个活着的线程，发 SIGCHLD 给父进程
    // 3. 清除 TIF_SIGPENDING
}
```

线程退出时清理信号状态的特殊性：如果父进程 `wait4()` 了这个子进程，SIGCHLD 不会再发。

---

## 总结

信号机制的核心复杂度不在 sys_kill 的传参路径，而在信号发送时的**决策树**——逐级检查权限（LSM）、忽略判断（sig_task_ignored）、信号分类（SIG_KERNEL_ONLY/STOP/IGNORE）、pending 状态（legacy_queue）、SIGCONT/SIGSTOP 互斥清除。以及信号接收时的**调度优先级**——在 get_signal 的 7 级跳转表中决定信号的最终命运。

**本文与 kernel/signal.c 的对照**：
- L3950: sys_kill 入口
- L1570: kill_something_info 分发  
- L1260: do_send_sig_info
- L1040: __send_signal_locked（核心发送路径）
- L963: complete_signal（线程选择 + 唤醒）
- L721: signal_wake_up_state（TIF_SIGPENDING + wake）
- L2801: get_signal（信号接收调度）
- L3119: exit_signals（退出清理）
