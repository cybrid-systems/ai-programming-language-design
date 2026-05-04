# Linux 信号处理机制深度分析

## 概述

信号（Signal）是 Linux 内核提供的最古老、最基础的进程间通信（IPC）和异常处理机制。从 Unix V7（1979 年）继承至今，信号处理已从简单的软件中断演化为一个涵盖同步异常、异步通知、调试陷阱、资源限制的完整子系统。

与大多数其他内核子系统不同，信号处理横跨三个执行域：
- **系统调用入口**：`kill/tkill/tgkill` 发送、`sigaction/sigprocmask` 设置
- **内核中断/异常返回路径**：`arch_do_signal_or_restart` → `get_signal`
- **架构相关帧处理**：`setup_rt_frame` 在用户栈上构造 sigframe

## 核心数据结构

### task_struct 信号相关字段

（`include/linux/sched.h`，L1197~1203）

```c
struct signal_struct      *signal;        // L1197 — 进程组共享的信号状态
struct sighand_struct __rcu *sighand;     // L1198 — 信号处理函数表
sigset_t                  blocked;        // L1199 — 当前屏蔽的信号集
sigset_t                  real_blocked;   // L1200 — 临时保存的原始屏蔽集（SA_NODEFER 等设计）
struct sigpending         pending;        // L1203 — 该线程的私有待处理信号队列
```

每个线程有独立的 `pending` 和 `blocked`。进程组的共享信号在 `signal_struct.shared_pending`。

### signal_struct — 进程组信号状态

（`include/linux/sched/signal.h`，L94~124）

```c
struct signal_struct {
    refcount_t          sigcnt;             // L95  — 引用计数
    atomic_t            live;               // L96  — 存活线程数
    int                 nr_threads;         // L97  — 线程组线程数
    int                 quick_threads;      // L98  — 非 PTRACED 线程数（用于快速信号投递）
    struct list_head    thread_head;        // L99  — 线程链表头
    wait_queue_head_t   wait_chldexit;      // L101 — wait4() 等待队列
    struct task_struct  *curr_target;       // L104 — 当前信号投递目标
    struct sigpending   shared_pending;     // L107 — 进程组共享待处理信号
    struct hlist_head   multiprocess;       // L110 — 多进程 fork 信号收集
    int                 group_exit_code;    // L113 — 组退出码
    int                 notify_count;      // L115 — 待通知线程数
    struct task_struct  *group_exec_task;  // L116 — exec 线程
    int                 group_stop_count;  // L119 — 组停止计数
    unsigned int        flags;             // L120 — SIGNAL_* 标志
    struct core_state   *core_state;       // L122 — coredump 状态
    // ... 后续有 rlimit、itimers、posix 定时器、tty、CPU 时间统计等
};
```

关键设计：`curr_target` 实现轮询（round-robin）信号投递，避免同一线程反复处理 SIGIO/SIGURG 等频繁信号。

### sighand_struct — 信号处理函数表

（`include/linux/sched/signal.h`，L21~26）

```c
struct sighand_struct {
    spinlock_t          siglock;            // L22 — 信号处理自旋锁
    refcount_t          count;              // L23 — 引用计数（CLONE_SIGHAND 共享）
    wait_queue_head_t   signalfd_wqh;       // L24 — signalfd 等待队列
    struct k_sigaction  action[_NSIG];      // L25 — 每个信号的处理动作
};
```

`action[]` 数组以信号编号为索引。`_NSIG` 在 x86-64 上为 65（常规信号 1-31 + 实时信号 32-64）。`struct k_sigaction` 包裝了 `sigaction`（用户态看到的处理函数+标志+屏蔽集）。

### sigpending 与 sigqueue — 信号排队

（`include/linux/signal_types.h`）

```c
// L32
struct sigpending {
    struct list_head    list;       // 信号队列链表
    sigset_t            signal;     // 位图：哪些信号有待处理
};

// L22
struct sigqueue {
    struct list_head    list;       // 链表节点
    int                 flags;      // SIGQUEUE_PREALLOC 等
    kernel_siginfo_t    info;       // 信号的附加信息（pid、uid、errno 等）
    struct ucounts      *ucounts;   // 用户命名空间计数
};
```

`sigpending.signal` 是一个位图，与链表 `list` 配合：位图可以 O(1) 判断是否有信号待处理，链表用于遍历和去重。对于标准信号（1-31），相同的信号只会在链表中出现一次（如果已有同信号 pending，不会重复入队）；而实时信号（32-64）支持排队，每个实例独立入队。

### ksignal — 信号传递的中间结构

（`include/linux/signal_types.h`，L62）

```c
struct ksignal {
    struct k_sigaction  ka;         // 处理函数信息
    kernel_siginfo_t    info;       // 信号附加信息
    int                 sig;        // 信号编号
};
```

`get_signal()` 将信号从 pending 队列取出后填充此结构，然后传给架构相关的 `handle_signal()`。

## 信号生命周期：从发送到处理的完整数据流

### 第一阶段：信号生成（Generation）

信号可以来自多种源头：

| 源 | 内核函数（行号） | 备注 |
|----|----------------|------|
| 系统调用 sys_kill | `SYSCALL_DEFINE2(kill, pid_t, pid, int, sig)` — L3950 | 发送给进程（PIDTYPE_TGID） |
| 系统调用 sys_tkill | `SYSCALL_DEFINE2(tkill, pid_t, pid, int, sig)` — L4184 | 发送给线程（PIDTYPE_PID） |
| 系统调用 sys_tgkill | `SYSCALL_DEFINE3(tgkill, pid_t, tgid, pid_t, pid, int, sig)` — L4168 | 安全版本，检查 tgid |
| 系统调用 pidfd_send_signal | L4066 | 通过 pidfd 发送 |
| 内核自身（如 SIGSEGV） | `force_sig_fault()` → `force_sig_info()` — L1327 | 同步异常 |
| 定时器到期 | `send_signal_locked()` — L1181 | POSIX 定时器 |
| 子进程退出 | `__send_signal_locked()` — L2261 | SIGCHLD 发送给父进程 |

以最常见的 `sys_kill` 为例的信号生成路径：

```
sys_kill()                            // L3950
  └─ kill_something_info(sig, info, pid)
       └─ kill_pid_info(sig, info, pid)  // PID 转 task_struct
            └─ group_send_sig_info(sig, info, p, type)  // L1407
                 └─ do_send_sig_info(sig, info, p, type)  // L1260
                      └─ check_kill_permission(sig, info, p)
                      └─ send_signal_locked(sig, info, p, type)  // L1181
                           └─ __send_signal_locked(sig, info, p, type, force)  // L1040
                                └─ (标准信号) 同号 pending 则跳过入队，只更新位图
                                └─ (实时信号) 分配 sigqueue 入队
                                └─ complete_signal(sig, p, type)   // L963
```

### 第二阶段：信号投递决策（complete_signal）

（`kernel/signal.c`，L963~1031）

`complete_signal()` 是信号投递的核心决策点：

```c
static void complete_signal(int sig, struct task_struct *p, enum pid_type type)
```

其决策过程：

1. **SIGKILL 优先处理**：如果是 SIGKILL，立即设置 `SIGNAL_GROUP_EXIT` 标志，唤醒所有线程准备退出

2. **选择目标线程**（L978~1020）：
   - 如果信号是 `PIDTYPE_PID`（tkill），目标就是指定的线程
   - 否则在进程中选一个线程：
     - 先尝试信号未被屏蔽的线程（`!sigismember(&t->blocked, sig)`）
     - 再尝试 `signal->curr_target` 的下一个（round-robin 轮转）
     - 更新 `curr_target` 指向被选中的线程

3. **唤醒线程**（L1021~1031）：
   ```c
   signal_wake_up(t, sig == SIGKILL);  // L1021
   signal_wake_up(t, 0);               // L1031（非 SIGKILL）
   ```

`signal_wake_up()`（L721）设置 `TIF_SIGPENDING` 标志并唤醒目标线程。如果准备 kill 线程（SIGKILL 或已经 `SIGNAL_GROUP_EXIT`），使用 `wake_up_state(t, TASK_INTERRUPTIBLE)` 强制唤醒——即使是 TASK_KILLABLE 的睡眠也要醒来。

### 第三阶段：信号递送（Delivery）

当目标线程被调度运行时，在 `ret_from_user` 返回用户空间前会检查 `TIF_SIGPENDING`：

```
do_syscall_64() → 系统调用处理结束
exit_to_user_mode_loop() → 检查 TIF_SIGPENDING
  └─ arch_do_signal_or_restart(regs)   // arch/x86/kernel/signal.c L333
       └─ get_signal(&ksig)            // kernel/signal.c L2801
            └─ dequeue_signal()         // L618 — 从 pending 队列取出一个信号
       └─ handle_signal(ksig, regs)    // arch/x86 L255
            └─ setup_rt_frame(ksig, regs) // arch/x86 L236
```

#### get_signal() — 信号调度（L2801）

信号调度的核心逻辑，按优先级处理：

1. **SIGKILL**：最高优先级，直接 `do_group_exit(0)` 终止进程
2. **SIGSTOP**：将进程置为 `TASK_STOPPED`，通知父进程
3. **调试/跟踪信号**：如果进程被 ptrace，信号会先交给调试器
4. **忽略的信号（SIG_IGN）**：直接丢弃，继续取下一个
5. **被屏蔽的信号**：暂不处理，等屏蔽解除
6. **默认动作的信号（SIG_DFL）**：按默认动作处理（terminate/ignore/core/stop）
7. **用户自定义处理（signal handler）**：填充 `ksig` 结构，返回给 `handle_signal`

#### handle_signal() — 架构相关处理（arch/x86/kernel/signal.c L255）

用户自定义信号处理需要在内核态和用户态之间切换执行栈。关键是 **sigframe** 的构造：

```c
static void handle_signal(struct ksignal *ksig, struct pt_regs *regs)
{
    /* 在用户栈上分配 sigframe 空间 */
    failed = (setup_rt_frame(ksig, regs) < 0);

    /* 设置 blocked mask：当前信号加入屏蔽集（除非 SA_NODEFER） */
    sigorsets(&blocked, &ksig->ka.sa.sa_mask, &sigmask(ksig->sig));
    set_current_blocked(&blocked);
}
```

`setup_rt_frame()`（L236）构造 rt_sigframe 结构：

```
用户栈布局（高地址 → 低地址）：
┌─────────────────────────────┐
│ 前一个栈帧                   │
├─────────────────────────────┤
│ struct rt_sigframe          │
│  ├─ char __user *pretcode    │ ← 信号处理返回地址（restorer）
│  ├─ struct ucontext uc       │ ← 保存的寄存器上下文（regs 副本）
│  │   └─ struct sigcontext    │
│  └─ struct siginfo info      │ ← 信号附加信息
├─────────────────────────────┤
│ fpu/xstate 保存区            │
└─────────────────────────────┘ SP → (regs->sp - sizeof(struct rt_sigframe))
```

信号处理函数返回时，执行 restorer 代码（通常为 `__NR_rt_sigreturn` 系统调用）恢复到内核，内核再恢复 sigframe 中的寄存器上下文，继续原程序执行。

### 第四阶段：信号清理（sigreturn）

```
sys_rt_sigreturn() → restore_sigframe(regs, frame)
                    → set_current_blocked(&set)  // 恢复原始 signal mask
                    → restore_fpu_state()
                    → 返回用户空间，继续原程序执行
```

`sys_rt_sigreturn`（L4630 附近）利用 sigframe 中保存的 `ucontext` 完整恢复寄存器状态和信号屏蔽集，然后 return 到中断发生时的代码位置。

## 关键设计决策分析

### 1. 信号屏蔽集的实现：blocked vs real_blocked

每个 `task_struct` 有两个 `sigset_t`：

- `blocked`：当前生效的信号屏蔽集
- `real_blocked`：临时保存的原始屏蔽集

为什么需要两个？因为信号处理函数执行时所挂的屏蔽集 = 原始屏蔽集 ∪ handler 指定的 sa_mask ∪ 当前信号本身。当信号处理返回时需要恢复到原始屏蔽集。这种"保存-恢复"的抽象由信号递送路径自动处理——`handle_signal()` 设置新屏蔽集，`sys_rt_sigreturn()` 从 sigframe 恢复原始屏蔽集。

### 2. 标准信号 vs 实时信号排队

标准信号（1-31）和实时信号（32-64）在排队行为上完全不同：

| 特性 | 标准信号 | 实时信号 |
|------|---------|---------|
| 排队 | 不排队，同号合并 | 排队，每个独立入队 |
| 顺序 | 无序 | FIFO 有序 |
| 信息传递 | 信号编号仅 8 位，无siginfo | 完整 siginfo_t |
| 排队容量 | 1（最多 pending 一个） | 可配置上限（rlimit） |

这个设计反映在 `__send_signal_locked()`（L1040）的关键代码中：

```c
if (!sigismember(&pending->signal, sig))    /* 标准信号：同号跳过入队 */
    ...
else if (!is_si_special(info))              /* 实时信号每次都入队 */
    ...
```

### 3. 信号投递的线程选择策略

`complete_signal()` 中的线程选择（L978~1020）体现了一个经过长期优化的策略：

1. **tkill/tgkill 直接指定线程**：不选择
2. **首选未被屏蔽的线程**：避免信号延迟
3. **非 PTRAECED 线程优先**（`quick_threads`，L98）：简化信号处理路径（不需要和调试器交互）
4. **curr_target 轮转**：避免同一线程反复处理 SIGIO/SIGURG/SIGCHLD 等高频率信号

### 4. TIF_SIGPENDING 检查的频率

`TIF_SIGPENDING` 标志在以下时机检查：
- 系统调用返回用户空间 (`exit_to_user_mode_loop`)
- 中断/异常返回用户空间
- 从 `TASK_INTERRUPTIBLE` 或 `TASK_KILLABLE` 睡眠中唤醒后
- `signal_wake_up()` 显式设置

关键设计：**信号处理不会在系统调用处理中途发生**（除了 TASK_INTERRUPTIBLE 的睡眠被信号打断返回 ERESTARTSYS），而是等到返回用户空间前的一刹那。这与信号处理需要在用户栈上构造 sigframe 的要求一致。

### 5. force_sig 路径（同步信号）

对于 SIGSEGV、SIGBUS、SIGFPE、SIGILL 等同步异常：

```c
force_sig_fault(SIGSEGV, si_code, address);
    └─ force_sig_info(&info)                     // L1327
         └─ do_send_sig_info(sig, info, current, PIDTYPE_PID)  // 发给当前线程
```

与异步信号的区别：
- 使用 `PIDTYPE_PID` 而不是 `PIDTYPE_TGID`：只发给出错的线程，不发给整个进程
- 设置 `force=true`：即使信号被屏蔽也要标记 pending（因为 SIGKILL/SIGSTOP 不能被屏蔽）
- 使用 `current` 作为目标：同步信号总是当前位置

### 6. sigaction 设置与 SA_IMMUTABLE

（`kernel/signal.c`，L4630 `__rt_sigaction`）

```c
SYSCALL_DEFINE4(rt_sigaction, int, sig,
    const struct sigaction __user *, act,
    struct sigaction __user *, oact,
    size_t, sigsetsize)
```

`SA_IMMUTABLE` 标志（`include/linux/signal_types.h` L70）用于防止某些强制信号的处理函数被修改：

```c
/* Used to kill the race between sigaction and forced signals */
#define SA_IMMUTABLE        0x00800000
```

当 `force_sig_info()` 检测到竞争条件时，会将动作置为 `SA_IMMUTABLE`，阻止后续的 `rt_sigaction` 修改该信号的处理函数。

### 7. 退出时的信号处理（exit_signals）

（`kernel/signal.c`，L3119）

```c
void exit_signals(struct task_struct *tsk)
```

在 `do_exit()` 过程中，线程需要清理其信号状态：
1. 将线程自身的 pending 信号合并到进程组的 shared_pending
2. 如果进程组内还有活线程，`live--` 并检查是否需要发送 SIGCHLD
3. 清除 `TIF_SIGPENDING` 标志

## 信号处理效率分析

### 关键设计权衡

**优点：**
- 位图（sigset_t）+ 链表（sigpending）双重结构：O(1) 检查信号是否有待处理，链表用于逐个取出
- RT 信号独立排队：支持可靠实时通信（`sigqueueinfo` 系统调用）
- `curr_target` 轮转：避免单线程热点
- sigframe 保存完整上下文：信号处理函数几乎是透明的（除了一些不可重入的系统调用）

**局限性：**
- 标准信号不可靠（同号合并）—— POSIX 标准要求，不是实现缺陷
- 信号处理函数执行时有大量的 TLB miss/cache miss（sigframe 在用户栈上，而 handler 代码可能在另一个页面）
- 信号嵌套处理受限：标准信号在 handler 执行期间默认被屏蔽（除非 SA_NODEFER），实时信号也默认屏蔽

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct signal_struct` | include/linux/sched/signal.h | 94-124 |
| `struct sighand_struct` | include/linux/sched/signal.h | 21-26 |
| `struct sigpending` | include/linux/signal_types.h | 32 |
| `struct sigqueue` | include/linux/signal_types.h | 22 |
| `struct k_sigaction` | include/linux/signal_types.h | 48 |
| `struct ksignal` | include/linux/signal_types.h | 62 |
| `task_struct->signal` | include/linux/sched.h | 1197 |
| `task_struct->sighand` | include/linux/sched.h | 1198 |
| `task_struct->blocked` | include/linux/sched.h | 1199 |
| `task_struct->pending` | include/linux/sched.h | 1203 |
| `__send_signal_locked()` | kernel/signal.c | 1040 |
| `send_signal_locked()` | kernel/signal.c | 1181 |
| `do_send_sig_info()` | kernel/signal.c | 1260 |
| `force_sig_info()` | kernel/signal.c | 1327 |
| `complete_signal()` | kernel/signal.c | 963 |
| `signal_wake_up_state()` | kernel/signal.c | 721 |
| `get_signal()` | kernel/signal.c | 2801 |
| `dequeue_signal()` | kernel/signal.c | 618 |
| `exit_signals()` | kernel/signal.c | 3119 |
| `__rt_sigaction()` | kernel/signal.c | 4630 |
| `sys_kill()` | kernel/signal.c | 3950 |
| `sys_tkill()` | kernel/signal.c | 4184 |
| `sys_tgkill()` | kernel/signal.c | 4168 |
| `sys_rt_sigreturn()` | kernel/signal.c | 4680 附近 |
| `handle_signal()` | arch/x86/kernel/signal.c | 255 |
| `setup_rt_frame()` | arch/x86/kernel/signal.c | 236 |
| `arch_do_signal_or_restart()` | arch/x86/kernel/signal.c | 333 |
| `TIF_SIGPENDING` | include/linux/sched.h | 788 |
| `SA_IMMUTABLE` | include/linux/signal_types.h | 70 |

## 调用链总览

```
发送端：
  sys_kill()                             [L3950]
    → kill_something_info()
      → kill_pid_info()
        → group_send_sig_info()          [L1407]
          → do_send_sig_info()           [L1260]
            → send_signal_locked()       [L1181]
              → __send_signal_locked()   [L1040]
                → complete_signal()      [L963]
                  → signal_wake_up()     [L721] → TIF_SIGPENDING + wake

接收端（返回用户空间时）：
  exit_to_user_mode_loop()
    → arch_do_signal_or_restart()        [arch/x86 L333]
      → get_signal()                     [kernel L2801]
        → dequeue_signal()               [L618]
      → handle_signal()                  [arch/x86 L255]
        → setup_rt_frame()               [arch/x86 L236] → sigframe

信号处理返回：
  信号处理函数执行 → restorer → sys_rt_sigreturn()
    → restore_sigframe() → 恢复寄存器 → 回到原执行点
```
