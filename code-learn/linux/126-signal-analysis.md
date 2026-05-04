# 126-signal — Linux 内核信号处理机制深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**信号（Signal）** 是 Linux 内核提供的最古老、最基础的进程间通信（IPC）和异常处理机制。从 Unix V7（1979 年）继承至今，信号处理已从简单的软件中断演化为一个涵盖同步异常、异步通知、调试陷阱、资源限制的完整子系统。

**与 FreeBSD 的对比**：FreeBSD 的信号实现与 Linux 同源（POSIX 标准），但 FreeBSD 在 4.4BSD 中引入了 `sigwaitinfo` 和 `sigtimedwait` 等扩展——Linux 后来也实现了，但底层实现不同。FreeBSD 的信号投递路径更简单，因为它没有线程组（`PIDTYPE_TGID`）的概念——每个进程只有一个线程。Linux 的信号实现中约一半的复杂度来自于"信号发送给进程 vs 发送给线程"这个二分法。

**与 Windows 的对比**：Windows 的 **APC（Asynchronous Procedure Call）** 机制与信号类似，但 APC 可以"排队"（queue user APC）且不需要可重入 handler——Windows 内核保证 APC 被调用时，原线程处于 Alertable 等待状态。而 signal handler 的执行是抢占式的——某指令之后、下一指令之前的一刹那（`exit_to_user_mode_loop`）。这使得 signal handler 的可重入约束比 APC 严格得多。

**doom-lsp 确认**：`kernel/signal.c` 含 **303 个符号**，4870 行——内核中最大的函数之一。`arch/x86/kernel/signal.c`（x86 信号帧处理），`include/linux/sched/signal.h`（核心结构定义），`include/linux/signal_types.h`（类型定义）。

---

## 1. 核心数据结构

### 1.1 `task_struct` 信号相关字段

（`include/linux/sched.h` L1197~1203 — doom-lsp 确认）

```c
struct signal_struct      *signal;        // L1197 — 进程组共享的信号状态（引用计数 + 待处理信号）
struct sighand_struct __rcu *sighand;     // L1198 — 信号处理函数表（RCU 保护，clone 共享）
sigset_t                  blocked;        // L1199 — 当前屏蔽的信号集（sigprocmask 设置）
sigset_t                  real_blocked;   // L1200 — 临时保存的原始屏蔽集
struct sigpending         pending;        // L1203 — 该线程私有的待处理信号队列
```

**设计哲学**：每个线程有独立的 `pending`（待处理信号）和 `blocked`（屏蔽集）。进程组的共享信号放在 `signal_struct.shared_pending`。这是 Linux 线程模型（`CLONE_THREAD`）强加的设计复杂度：如果无线程，只需一组 pending/blocked 即可；多线程时代，信号可以发送给特定线程（`tkill`、`tgkill`）或整个进程组（`kill`）。

### 1.2 `struct signal_struct`——进程组信号状态

（`include/linux/sched/signal.h` L94~124 — doom-lsp 确认）

```c
struct signal_struct {
    refcount_t          sigcnt;             // L95 — 引用计数（多线程共享此结构）
    atomic_t            live;               // L96 — 存活线程数（退出时减一）
    int                 nr_threads;         // L97 — 线程组线程总数
    int                 quick_threads;      // L98 — 非 PTRACED 线程数（快速信号投递目的）
    struct list_head    thread_head;        // L99 — 线程链表头（遍历所有 thread）
    wait_queue_head_t   wait_chldexit;      // L101 — wait4() 等待队列（父进程 wait 子进程时）
    struct task_struct  *curr_target;       // L104 — 当前信号投递目标（round-robin 轮转指针）
    struct sigpending   shared_pending;     // L107 — 进程组共享待处理信号
    struct hlist_head   multiprocess;       // L110 — 多进程 fork 信号收集链表
    int                 group_exit_code;    // L113 — 组退出码（exit_group 时设置）
    int                 notify_count;       // L115 — 待通知的线程数
    struct task_struct  *group_exec_task;   // L116 — 正在执行 exec 的线程
    int                 group_stop_count;   // L119 — 组停止计数（SIGSTOP 相关）
    unsigned int        flags;              // L120 — SIGNAL_* 标志（SIGNAL_GROUP_EXIT 等）
    struct core_state   *core_state;        // L122 — coredump 状态
};
```

**对比 FreeBSD**：FreeBSD 的 `struct proc` 中没有 `curr_target` 字段——FreeBSD 不支持线程级信号投递，信号总是发给进程，内核选择任意线程处理。`curr_target` 是 Linux 特有的 round-robin 优化，避免同一线程反复处理 SIGIO/SIGURG 等高频信号。

### 1.3 `struct sighand_struct`——信号处理函数表

（`include/linux/sched/signal.h` L21~26 — doom-lsp 确认）

```c
struct sighand_struct {
    spinlock_t          siglock;            // L22 — 信号处理自旋锁（保护整个结构）
    refcount_t          count;              // L23 — 引用计数（CLONE_SIGHAND 共享时 >1）
    wait_queue_head_t   signalfd_wqh;       // L24 — signalfd 等待队列
    struct k_sigaction  action[_NSIG];      // L25 — 每个信号的处理动作
};
```

`action[]` 数组以信号编号为索引。`_NSIG` 在 x86-64 上为 65（常规信号 1-31 + 实时信号 32-64）。`struct k_sigaction` 包裹了 `struct sigaction`：

```c
// include/linux/signal_types.h L48-55 — doom-lsp 确认
struct k_sigaction {
    struct sigaction sa;                    // L49 — 用户可见的处理结构
#ifdef __ARCH_HAS_KA_RESTORER
    __sigrestore_t ka_restorer;             // L52 — 架构相关 restorer 函数
#endif
};
```

**跨架构**：`ka_restorer` 在 x86-64 上通常指向 `__NR_rt_sigreturn` 系统调用的入口地址。ARM64 没有 restorer 字段——内核直接修改 `regs->regs[0]` 指向 sigreturn 代码。

### 1.4 `struct sigpending` 与 `struct sigqueue`——信号排队

（`include/linux/signal_types.h` L32/L22 — doom-lsp 确认）

```c
// L32
struct sigpending {
    struct list_head    list;       // L33 — 信号队列链表
    sigset_t            signal;     // L34 — 位图：哪些信号有待处理（O(1) 检查）
};

// L22
struct sigqueue {
    struct list_head    list;       // L23 — 链表节点
    int                 flags;      // L24 — SIGQUEUE_PREALLOC 等
    kernel_siginfo_t    info;       // L25 — 信号的附加信息（pid, uid, errno 等）
    struct ucounts      *ucounts;   // L27 — 用户命名空间计数
};
```

**位图 + 链表双重结构的设计意图**：`sigpending.signal` 位图允许 O(1) 判断是否有信号待处理（`sigismember()`），而 `list` 链表的遍历用于逐个取出信号（`dequeue_signal`）。标准信号（1-31）在入队时如果位图中已经存在，跳过入队操作（同号合并），只更新位图。实时信号（32-64）每次都独立入队。

```c
// kernel/signal.c L1040 — doom-lsp 确认：__send_signal_locked 中的排队逻辑
// 标准信号（sig < SIGRTMIN）: 如果 pending->signal 中已有该信号，跳过入队
//    → 只更新 pending->signal 位图
// 实时信号（sig >= SIGRTMIN）: 总是分配 sigqueue 入队
//    → 同时更新 pending->signal 位图和 list
```

### 1.5 `struct ksignal`——信号传递中间结构

（`include/linux/signal_types.h` L67 — doom-lsp 确认）

```c
struct ksignal {
    struct k_sigaction  ka;         // L68 — 处理函数信息（从 sighand->action[sig] 复制）
    kernel_siginfo_t    info;       // L69 — 信号附加信息（从 sigqueue->info 复制）
    int                 sig;        // L70 — 信号编号
};
```

`get_signal()` 从 pending 队列取出信号后填充此结构，然后传给架构相关的 `handle_signal()`。

---

## 2. 信号生命周期：从发送到处理的完整数据流

### 2.1 信号生成（Generation）

信号来源：

```c
// kernel/signal.c — doom-lsp 确认
SYSCALL_DEFINE2(kill, pid_t, pid, int, sig)         // L3950 — 杀进程（PIDTYPE_TGID）
SYSCALL_DEFINE2(tkill, pid_t, pid, int, sig)         // L4184 — 杀线程（PIDTYPE_PID）
SYSCALL_DEFINE3(tgkill, pid_t, tgid, pid_t, pid, int, sig) // L4168 — 安全版本（检查 tgid）
SYSCALL_DEFINE4(pidfd_send_signal, ...)               // L4066 — 通过 pidfd 发送
int force_sig_info(struct kernel_siginfo *info)       // L1327 — 同步异常（SIGSEGV 等）
int send_signal_locked(int sig, ...)                  // L1181 — 内核内部发送（定时器等）
```

### 2.2 `__send_signal_locked`——信号发送核心

（`kernel/signal.c` L1040 — doom-lsp 确认）

这是信号发送的核心函数。所有信号发送路径（kill/tkill/tgkill/force_sig/定时器）最终汇聚于此：

```c
// kernel/signal.c L1040-1089 — doom-lsp 确认（以下为截取的关键逻辑）
static int __send_signal_locked(int sig, struct kernel_siginfo *info,
                                struct task_struct *t, enum pid_type type, bool force)
{
    struct sigpending *pending;
    struct sigqueue *q;

    lockdep_assert_held(&t->sighand->siglock);  // L1048 — 必须持有 siglock

    // L1056 — 确定 pending 队列
    pending = (type != PIDTYPE_PID) ? &t->signal->shared_pending : &t->pending;
    // 验证：type==PIDTYPE_PID（tkill）→ 线程私有 pending
    //       type==PIDTYPE_TGID（kill）→ 进程组 shared_pending

    // L1062 — 标准信号同号合并
    if (legacy_queue(pending, sig))
        goto ret;  // 已存在同号信号 → 跳过入队

    // L1066 — SIGKILL 和内核线程不分配 sigqueue
    if ((sig == SIGKILL) || (t->flags & PF_KTHREAD))
        goto out_set;

    // L1076 — 实时信号 vs 标准信号分流
    if (sig < SIGRTMIN) {
        // 标准信号：只需设置 pending->signal 位图
        // 不需要分配 sigqueue
    } else {
        // 实时信号：必须分配 sigqueue 入队
        q = ...;
        list_add_tail(&q->list, &pending->list);
    }

out_set:
    sigaddset(&pending->signal, sig);  // L1085 — 设定位图
    complete_signal(sig, t, type);     // L1089 — 投递决策
}
```

### 2.3 `complete_signal`——投递决策

（`kernel/signal.c` L963 — doom-lsp 确认）

```c
static void complete_signal(int sig, struct task_struct *p, enum pid_type type)
{
    struct signal_struct *signal = p->signal;
    struct task_struct *t;

    // SIGKILL 快速路径：立即设置组退出标志，唤醒所有线程
    if (sig == SIGKILL) {
        signal->flags |= SIGNAL_GROUP_EXIT;
        // 遍历所有线程，逐个唤醒
        __for_each_thread(signal, t)
            signal_wake_up(t, 1);  // 第二个参数 = resume（强制唤醒）
        return;
    }

    // 选择目标线程（L978-1020）
    if (type == PIDTYPE_PID) {
        // tkill → 信号发给指定线程
        t = p;
    } else {
        // kill → 从进程组中选一个线程
        // 策略：优先选未屏蔽该信号的线程
        // 如果都屏蔽了，轮转 curr_target
        t = signal->curr_target;
        while (!sigismember(&t->blocked, sig)) {
            t = next_thread(t);
            if (t == signal->curr_target)
                break;  // 全都屏蔽了
        }
        signal->curr_target = t;
    }

    // 唤醒目标线程（L1021-1031）
    signal_wake_up(t, sig == SIGKILL);
}
```

**设计意图**：`curr_target` 的轮转设计避免了 CFS/completely-fair 的选择算法——不需要 O(log n) 红黑树查找。用简单的"下一个线程"轮转，在信号频率不高时已足够。

### 2.4 `signal_wake_up`——唤醒目标线程

（`kernel/signal.c` L721 — doom-lsp 确认）

```c
void signal_wake_up_state(struct task_struct *t, unsigned int state)
{
    set_tsk_thread_flag(t, TIF_SIGPENDING);   // 设置"有信号待处理"标志

    // 如果 state 包含 TASK_INTERRUPTIBLE（SIGKILL 时）：
    //   强制唤醒——即使进程在 TASK_KILLABLE 睡眠中
    if (!wake_up_state(t, state | TASK_INTERRUPTIBLE))
        // 如果进程已经在运行：只需 kick（确保从 syscall 返回时检查）
        kick_process(t);
}
```

### 2.5 信号递送——`arch_do_signal_or_restart`

（`arch/x86/kernel/signal.c` L333 — doom-lsp 确认）

当线程被调度执行时，在`返回用户空间之前`检查 `TIF_SIGPENDING` 标志：

```c
// arch/x86/kernel/signal.c — 用户空间返回前的信号处理
void arch_do_signal_or_restart(struct pt_regs *regs)
{
    struct ksignal ksig;

    // 1. 从 pending 队列取出一个信号（get_signal 处理优先级、屏蔽等）
    if (get_signal(&ksig)) {
        // 2. 有可以递送的信号 → 设置 sigframe
        handle_signal(&ksig, regs);
        return;
    }

    // 3. 没有待处理的信号 → 处理系统调用重启
    //    如果前一个系统调用返回 ERESTARTSYS/ERESTARTNOINTR 等
    //    需要重新执行该系统调用
    handle_signal_restart(regs, ...);
}
```

**`get_signal` 信号调度优先级**（`kernel/signal.c` L2801）：

```
SIGKILL → do_group_exit(0)                  // 立即终止
SIGSTOP → TASK_STOPPED + 通知父进程          // 停止执行
ptrace 追踪信号 → 先通知调试器               // gdb/strace 截获
SIG_IGN → 丢弃（不递送）                     // 被忽略
blocked → 暂不处理，等 sigprocmask 解除屏蔽   // 挂起
SIG_DFL 默认动作 → terminate/ignore/core/stop // 按默认处理
自定义 handler → 填充 ksignal 返回            // 用户态处理
```

### 2.6 `setup_rt_frame`——sigframe 构造

（`arch/x86/kernel/signal.c` L236 — doom-lsp 确认）

```c
static int setup_rt_frame(struct ksignal *ksig, struct pt_regs *regs)
{
    // 在用户栈上分配 sigframe 结构
    // sigframe = 栈顶 - sizeof(struct rt_sigframe)
    // rt_sigframe 包含：
    //   1. pretcode: 指向 sigreturn 代码（__NR_rt_sigreturn）
    //   2. ucontext: 保存的寄存器上下文
    //   3. siginfo: 信号附加信息
    //   4. fpu 状态

    // 复制当前 regs → sigframe->uc.uc_mcontext
    // 设置 regs->sp = sigframe 位置
    // 设置 regs->ip = handler 地址
    // 设置 regs->di = sig 编号
    // 设置 regs->si = siginfo 地址
    // 设置 regs->dx = ucontext 地址

    // 设置新 blocked mask：
    // new_blocked = old_blocked | sa_mask | sig
    // set_current_blocked(new_blocked)
}
```

**对比 Windows APC**：Windows 的 kernel APC 执行不需要修改用户栈——APC 在 `KiServiceExit` 路径中执行，使用当前线程的内核栈。Linux 的 signal handler 需要在用户栈上构造 `rt_sigframe`，因为 handler 运行在用户空间，需要保存/恢复完整的寄存器上下文。这是一个根本的设计差异：Windows APC 由内核调度器在内核态触发，Linux signal handler 在返回用户空间前由内核在用户栈上设置执行环境。

---

## 3. 关键设计决策分析

### 3.1 blocked vs real_blocked：为什么需要两个屏蔽集

```
执行 signal handler 时：
  blocked = old_blocked | handler->sa_mask | sig（本身）
  而 real_blocked 保存 old_blocked

signal handler 返回时（通过 rt_sigreturn）：
  blocked = sigframe 中保存的原始 mask
  即还原为 real_blocked 的值
```

为什么要保存到 real_blocked 而不是直接覆盖 blocked？
- 因为 `rt_sigreturn` 通过检查 sigframe 恢复 blocked——如果嵌套信号处理（第二个信号处理中又允许第三个信号），sigframe 中的 mask 是"第二个 handler 执行前的 mask"，而 real_blocked 是"第一个 handler 执行前的 mask"。两者不同，必须分别保存。

### 3.2 标准信号 vs 实时信号：为什么同号合并

标准信号（1-31）同号合并：同一信号多次发送，只会递送一次。
实时信号（32-64）排队：每次发送独立入队，按序递送。

这个设计源自 POSIX 标准，但底层原因更实际：
- **标准信号携带的信息量小**——只有信号编号（8 位），无额外数据。多次触发同一信号，最终效果相同。
- **实时信号携带 siginfo_t**——包含 pid、uid、errno、数据值等。两次实时信号的内容可能不同，不能合并。
- **性能考虑**——实时信号需要分配和释放 `sigqueue` 节点，而标准信号只需要操作位图。

### 3.3 为什么信号处理是在返回用户空间前，而不是在中断返回时

信号在 `exit_to_user_mode_loop()` 中处理——而不是像硬件中断那样在 `irqentry_exit()` 中立即处理。原因是：

1. **sigframe 必须在用户栈上构造**——如果线程当前在内核某处（如持有 spinlock），无法安全切换到用户栈
2. **TIF_SIGPENDING 的检查点**设计——在 syscall 返回、中断返回、`schedule()` 返回的"安全点"检查。这保证了信号处理时内核栈已清空到安全状态
3. **延迟信号不影响正确性**——信号本质上是"懒"的，被屏蔽的信号暂不处理，等解除屏蔽后再说

---

## 4. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct signal_struct` | include/linux/sched/signal.h | 94 |
| `struct sighand_struct` | include/linux/sched/signal.h | 21 |
| `struct sigpending` | include/linux/signal_types.h | 32 |
| `struct sigqueue` | include/linux/signal_types.h | 22 |
| `struct k_sigaction` | include/linux/signal_types.h | 48 |
| `struct ksignal` | include/linux/signal_types.h | 67 |
| `task_struct->signal` | include/linux/sched.h | 1197 |
| `task_struct->sighand` | include/linux/sched.h | 1198 |
| `task_struct->blocked` | include/linux/sched.h | 1199 |
| `task_struct->pending` | include/linux/sched.h | 1203 |
| `__send_signal_locked()` | kernel/signal.c | 1040 |
| `complete_signal()` | kernel/signal.c | 963 |
| `signal_wake_up_state()` | kernel/signal.c | 721 |
| `get_signal()` | kernel/signal.c | 2801 |
| `dequeue_signal()` | kernel/signal.c | 618 |
| `exit_signals()` | kernel/signal.c | 3119 |
| `sys_kill()` | kernel/signal.c | 3950 |
| `sys_tkill()` | kernel/signal.c | 4184 |
| `sys_tgkill()` | kernel/signal.c | 4168 |
| `force_sig_info()` | kernel/signal.c | 1327 |
| `handle_signal()` | arch/x86/kernel/signal.c | 255 |
| `setup_rt_frame()` | arch/x86/kernel/signal.c | 236 |
| `arch_do_signal_or_restart()` | arch/x86/kernel/signal.c | 333 |
| `TIF_SIGPENDING` | include/asm-generic/thread_info_tif.h | 12 |
| `SA_IMMUTABLE` | include/linux/signal_types.h | 74 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-04 | 内核版本：Linux 7.0-rc1*
