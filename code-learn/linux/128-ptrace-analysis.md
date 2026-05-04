# Linux ptrace 机制深度分析

## 概述

ptrace（process trace）是 Linux 内核提供的进程跟踪和调试接口。它允许一个进程（tracer）观察和控制另一个进程（tracee）的执行，读取/写入其寄存器和内存。ptrace 是 gdb、strace、rr、perf 等所有调试和追踪工具的基础设施。

ptrace 的核心设计思想是**信号转发模型**：tracer 通过捕获 tracee 的信号来取得控制权，所有 ptrace 操作要么发生在信号拦截的上下文中，要么通过显式的 `PTRACE_SYSCALL`/`PTRACE_CONT` 等请求恢复执行。

## 核心数据结构

### task_struct 中的 ptrace 字段

（`include/linux/sched.h`，L1190~1210 附近）

```c
unsigned int            ptrace;             // 当前进程的 ptrace 状态位
struct list_head        ptraced;            // 被该 tracer tracer 的进程列表
struct list_head        ptrace_entry;       // 该进程在 tracer 的 ptraced 链表中的节点
struct task_struct __rcu *parent;           // ptrace 时会指向 tracer（重定向父进程）
```

关键 ptrace 状态位（`include/linux/ptrace.h`）：

```c
#define PT_PTRACED      0x00000001  // 正在被跟踪
#define PT_TRACESYSGOOD 0x00000002  // 系统调用 stop 时设置 0x80 位
#define PT_SEIZED       0x00010000  // 使用 PTRACE_SEIZE（现代粘性 attach）
#define PT_EXITKILL     0x20000000  // tracee 退出时 kill tracer
```

### PTRACE_EVENT / ptrace_options

（`include/uapi/linux/ptrace.h`）

```c
// ptrace 请求类型 — 作为 sys_ptrace() 的第一个参数
#define PTRACE_TRACEME     0       // 子进程主动请求被跟踪
#define PTRACE_PEEKTEXT    1       // 读取内存
#define PTRACE_POKETEXT    4       // 写入内存
#define PTRACE_CONT        7       // 继续执行
#define PTRACE_KILL        8       // 发送 SIGKILL
#define PTRACE_SINGLESTEP  9       // 单步执行
#define PTRACE_ATTACH      16      // 附加到目标进程
#define PTRACE_DETACH      17      // 分离
#define PTRACE_SYSCALL     24      // 跟踪系统调用
#define PTRACE_SETOPTIONS  0x4200  // 设置 ptrace 选项
#define PTRACE_GETEVENTMSG 0x4201  // 获取事件消息
#define PTRACE_GETSIGINFO  0x4202  // 获取信号信息
#define PTRACE_SEIZE       0x4206  // 粘性附加（不暂停 tracee）
#define PTRACE_INTERRUPT   0x4207  // 中断 tracee
#define PTRACE_LISTEN      0x4208  // 监听 tracee（与 SEIZE 配合）
```

## ptrace 操作分类

`sys_ptrace()`（`kernel/ptrace.c` L1388）根据 request 参数分发操作：

### 1. Attach/Detach 类

| 操作 | 函数 | 效果 |
|------|------|------|
| `PTRACE_TRACEME`（0） | 由子进程主动调用 | 将当前进程标记为被父进程跟踪 |
| `PTRACE_ATTACH`（16） | `ptrace_attach()` | 附加到目标进程，发送 SIGSTOP |
| `PTRACE_SEIZE`（0x4206） | `ptrace_attach()` | 粘性附加，不发送 SIGSTOP |
| `PTRACE_DETACH`（17） | `ptrace_detach()` | 分离 tracer，发送指定信号恢复执行 |

### 2. 读写类

| 操作 | 处理器 | 功能 |
|------|--------|------|
| `PTRACE_PEEKTEXT/PTRACE_PEEKDATA` | `ptrace_access_vm()` | 从 tracee 地址空间读一个字 |
| `PTRACE_PEEKUSER` | 通过 task_regset_view | 读 tracee 的 USER 区域（寄存器） |
| `PTRACE_POKETEXT/POKEDATA` | `access_process_vm()` | 写 tracee 地址空间 |
| `PTRACE_POKEUSER` | 寄存器写 | 写 tracee 寄存器 |

### 3. 执行控制类

| 操作 | 功能 |
|------|------|
| `PTRACE_CONT`（7） | 继续执行，可选择是否递送信号 |
| `PTRACE_SINGLESTEP`（9） | 单步执行一条指令 |
| `PTRACE_SYSCALL`（24） | 跟踪系统调用入口和返回 |
| `PTRACE_SYSEMU`（31） | 系统调用模拟（不真正执行） |
| `PTRACE_SYSEMU_SINGLESTEP`（32） | 单步 + 系统调用模拟 |
| `PTRACE_LISTEN`（0x4208） | 从 group-stop 恢复（用于 SEIZE） |
| `PTRACE_INTERRUPT`（0x4207） | 中断 tracee（用于 SEIZE 模式） |

### 4. 信息获取类

| 操作 | 功能 |
|------|------|
| `PTRACE_GETREGSET/SETREGSET` | 批量读写寄存器组（NT_PRSTATUS 等） |
| `PTRACE_GETSIGINFO/SETSIGINFO` | 获取/设置信号信息（可修改传给 tracee 的信号） |
| `PTRACE_GETEVENTMSG` | 获取事件消息（如 PTRACE_EVENT_EXIT 的退出码） |
| `PTRACE_GETSIGMASK/SETSIGMASK` | 获取/设置 tracee 的信号屏蔽集 |

## ptrace 两种 Attach 模式

### PTRACE_TRACEME — 子进程主动跟踪

这是最简单的方式，fork 后在子进程中使用：

```c
if (fork() == 0) {
    ptrace(PTRACE_TRACEME, 0, 0, 0);  // 子进程主动标记
    execl("/bin/ls", "ls", NULL);
}
```

`ptrace(PTRACE_TRACEME, ...)` 的内部逻辑（`kernel/ptrace.c`）：
1. 检查当前进程是否已被跟踪（`current->ptrace & PT_PTRACED`）
2. 设置 `current->ptrace |= PT_PTRACED`
3. 将当前进程加入父进程的 `ptraced` 链表
4. 将 `current->parent` 设为当前父进程（如果允许多个 tracer 则指向 ptracer）

关键效果：子进程调用 `execve()` 时会触发 `ptrace_stop()`，父进程在 `wait()` 后获得控制权。

### PTRACE_ATTACH — 追踪者主动附着

```c
ptrace(PTRACE_ATTACH, target_pid, 0, 0);
```

`ptrace_attach()`（`kernel/ptrace.c` L409）的完整流程：

1. **权限检查**（L415~432）：
   - 目标必须是 tracer 本身可见的进程（PID 命名空间检查）
   - 必须是 `same_thread_group(tracee, tracer)` 或 `PTRACE_MODE_ATTACH_REALCREDS` 权限（通常需要 CAP_SYS_PTRACE 或同一用户的非 dumpable 进程）
   - 检查 tracer 是否已有 `RLIMIT_NPROC` 限制

2. **安全审计**（L434~439）：
   - `security_ptrace_access_check()` — LSM 钩子（SELinux/Apparmor）
   - `ptrace_attach()` 审计记录

3. **加入跟踪关系**（L442~472）：
   - `__ptrace_link(task, new_parent)` — L86：将 tracee 的 parent 指向 tracer
   - 设置 `task->ptrace |= PT_PTRACED`

4. **发送停止信号**（L475~490）：
   - `send_sig_info(SIGSTOP, SEND_SIG_PRIV, task)` — 发送 SIGSTOP 使 tracee 进入 `TASK_TRACED`

### PTRACE_SEIZE — 粘性附着

（`kernel/ptrace.c` L492~536）

PTRACE_SEIZE 与 ATTACH 的核心区别：

| 特性 | PTRACE_ATTACH | PTRACE_SEIZE |
|------|--------------|--------------|
| 发送 SIGSTOP | ✅ 是 | ❌ 否 |
| tracee 是否被暂停 | ✅ 是（立即 TASK_TRACED） | ❌ 否（需要通过 PTRACE_INTERRUPT 请求暂停） |
| 设置 PT_SEIZED | ❌ | ✅ |
| 支持 PTRACE_LISTEN | ❌ | ✅ |
| 对 dumpable 进程的权限检查 | 更严格 | 更宽松 |
| 对已跟踪进程的 attach | 拒绝（EBUSY） | 允许（可多个 tracer） |

## 信号模型与 ptrace_stop

ptrace 的整个执行控制基于信号模型。当 tracee 遇到需要 tracer 介入的事件时，调用 `ptrace_stop()` 进入 `TASK_TRACED` 状态。

### ptrace_stop()

（`kernel/signal.c` L2351~2421）

```c
static int ptrace_stop(int exit_code, int why, unsigned long message,
                       kernel_siginfo_t *info)
```

进入条件（在 `get_signal()` 的循环中）：

```
get_signal(ksig)                         // kernel/signal.c L2801
  └─ 如果跟踪标志被设置（JOBCTL_TRAP_*）→ ptrace_stop()
  └─ 如果有信号到达 → 检查是否在 ptrace 下 → 调用 ptrace_stop()
```

`ptrace_stop()` 的执行流程：

1. **架构相关停止准备**（L2358~2370）：
   ```c
   if (arch_ptrace_stop_needed()) {
       release_sighand_irqreclaim(current, &flags);
       arch_ptrace_stop();      // 例如 x86 上的调试寄存器保存
   }
   ```

2. **设置 tracee 为 TASK_TRACED**（L2380~2421）：
   - 唤醒 tracer：`wake_up_interruptible(&current->signal->wait_chldexit)`
   - 设置 `current->__state = TASK_TRACED`
   - 用 `schedule()` 让出 CPU
   - 从 schedule() 返回时表示 tracer 已通过 PTRACE_CONT/SYSCALL/SINGLESTEP 等恢复执行

3. **清理**：
   ```c
   task_clear_jobctl_pending(current, JOBCTL_TRAP_STOP);   // L2419
   task_clear_jobctl_pending(current, JOBCTL_TRAP_NOTIFY); // L2421
   ```

tracer 观察到 tracee 停止的方式是 `wait4()` 系统调用返回一个状态字，其中 `WIFSTOPPED(status)` 为真，且停止原因（`WSTOPSIG(status)`）或 `PTRACE_EVENT_*` 编码指示了具体类型。

### tracer 的信息获取

tracee 进入 `TASK_TRACED` 后，tracer 可以执行所有非执行类的 ptrace 操作：
- 读/写寄存器：`PTRACE_GETREGSET` / `PTRACE_SETREGSET`
- 读/写内存：`PTRACE_PEEKDATA` / `PTRACE_POKEDATA`
- 获取信号信息：`PTRACE_GETSIGINFO`
- 获取事件消息：`PTRACE_GETEVENTMSG`

这些操作通过 `ptrace_request()` 分发到各处理器函数，最终通过 `access_process_vm()`（访问用户空间内存）或 `copy_regset_from_user()`（访问寄存器）完成。

### 恢复执行

tracer 通过以下操作恢复 tracee 执行：

```
PTRACE_CONT(sig)     — 继续执行，进程收到 sig 信号（0 表示不发送信号）
PTRACE_SYSCALL(sig)  — 继续执行，但在下一次系统调用入口/返回时再次停止
PTRACE_SINGLESTEP(sig) — 执行一条指令后再次停止
```

内部逻辑：
1. 清除 `TASK_TRACED` 状态，设置 `TASK_RUNNING`
2. 修改 tracee 的 `ptrace_message` 或体系结构相关的单步标志（`TIF_SINGLESTEP`）
3. tracee 从 `ptrace_stop()` 的 `schedule()` 调用返回，继续执行

## 系统调用跟踪：PTRACE_SYSCALL

PTRACE_SYSCALL 是最常用的跟踪模式（strace 的核心）。其实现涉及两个关键通知点：

### 系统调用入口通知（syscall_enter_from_user_mode -> ptrace_notify）

```c
// arch/x86/entry/common.c 附近
do_syscall_64(regs)
  └─ 如果当前进程被 ptrace 且启用了系统调用跟踪：
       └─ 保存寄存器状态
       └─ 设置寄存器以指示系统调用编号
       └─ ptrace_notify(PTRACE_EVENT_SYSCALL_ENTER, ...)
            └─ ptrace_stop(PTRACE_EVENT_SYSCALL_ENTER, CLD_TRAPPED, ...)
```

### 系统调用返回通知（syscall_exit_to_user_mode -> ptrace_notify）

```c
syscall_exit_work(regs)
  └─ 如果有 TIF_SYSCALL_TRACEPOINT 或 ptrace 跟踪：
       └─ ptrace_notify(PTRACE_EVENT_SYSCALL_EXIT, ...)
            └─ ptrace_stop(PTRACE_EVENT_SYSCALL_EXIT, CLD_TRAPPED, ...)
```

在入口处，tracer 可以：
- 通过 `PTRACE_SETREGSET` 修改系统调用编号和参数
- 设置为陌生系统调用号 → `ENOSYS` 返回

在返回处，tracer 可以：
- 通过 `PTRACE_GETREGSET` 查看返回值
- 通过 `PTRACE_SETREGSET` 修改返回值

此机制通过 `task_thread_info(current)->flags & _TIF_SYSCALL_TRACE` 启动，该标志在 `ptrace(PTRACE_SYSCALL, ...)` 时设置。

## PTRACE_EVENT 机制

除了信号停止和系统调用停止外，ptrace 还定义了若干特殊事件：

| 事件 | 触发时机 | 事件消息 |
|------|---------|---------|
| `PTRACE_EVENT_FORK` | tracee 调用 fork/clone | 子进程 PID |
| `PTRACE_EVENT_VFORK` | tracee 调用 vfork | 子进程 PID |
| `PTRACE_EVENT_CLONE` | tracee 调用 clone | 子进程 PID |
| `PTRACE_EVENT_EXEC` | tracee 调用 execve | 无 |
| `PTRACE_EVENT_EXIT` | tracee 退出前 | 退出码 |
| `PTRACE_EVENT_STOP` | tracee 首次因 PTRACE_SEIZE 停止 | 无 |

这些事件通过 `ptrace_event()`（`kernel/signal.c` L2513~2516）触发：

```c
int ptrace_event(int event, unsigned long message)
{
    return ptrace_stop(event, CLD_TRAPPED, message, NULL);
}
```

tracer 通过 `PTRACE_SETOPTIONS` 设置 `PTRACE_O_TRACEFORK`/`PTRACE_O_TRACEEXEC` 等标志来控制监听哪些事件。

## ptrace 与 execve 的交互

当被跟踪的进程调用 `execve()` 时，会触发一系列 ptrace 相关的操作：

1. **ptrace 检测**：`begin_new_exec()`（`fs/exec.c` L1091）中检查 `current->ptrace & PT_PTRACED`
2. **exec 前停止**：如果设置了 `PTRACE_O_TRACEEXEC`，在 exec 完成后但返回用户空间前停止
3. **架构相关处理**：`ptrace_attach()` 的执行环境重置
4. **`PTRACE_EVENT_EXEC`**：tracee 进入 stop，tracer 可以检查新程序的状态

关键安全设计：`PTRACE_TRACEME` 常用于 gdb 调试子进程。如果子进程在 fork 后立即 exec，tracer 通过 PTRACE_EVENT_EXEC 停止获得控制权，此时地址空间已被替换，tracer 可以设置断点后再让程序启动。

## 调试寄存器与单步执行

### 单步执行（PTRACE_SINGLESTEP）

单步执行在 x86 上利用 EFLAGS 的 TF 位（Trap Flag）：

```
ptrace(PTRACE_SINGLESTEP, child, 0, 0)
  └─ sys_ptrace() → arch_ptrace()
       └─ tracee 的 regs->flags |= X86_EFLAGS_TF
```

当 tracee 执行一条指令后，CPU 因 TF=1 触发 debug exception（`#DB`）：
- vector: 1
- 在 `do_debug()` 异常处理程序中检查 TF 位
- 进入 `ptrace_stop()` → tracer 被通知

### 硬件断点（PTRACE_POKEUSER 操作 DR* 寄存器）

x86 的调试寄存器 DR0-DR7 可用于设置硬件断点：
- DR0-DR3：4 个断点地址
- DR6：断点状态寄存器（哪个断点被触发）
- DR7：控制寄存器（类型、长度、启用/禁用）

tracer 通过 `PTRACE_POKEUSER` 设置这些寄存器，通过 `PTRACE_GETREGSET NT_PRSTATUS` 读取，与单步配合可实现复杂的调试策略。

## 关键设计决策分析

### 1. 为什么 ptrace 使用信号模型而不是独立调度接口

ptrace 选择了信号作为事件传递机制，而不是创建一个新的 IPC 或事件通道，原因：
- **复用 wait4() 基础设施**：tracer 不需要新的系统调用即可等待 tracee 事件
- **与进程生命周期自然集成**：信号已经在处理进程间事件通知（SIGCHLD 等）
- **简单性**：`TASK_TRACED` 是一个简明的调度状态，在原有的调度框架下工作

代价是**信号延迟**：tracee 可能在其他信号处理路径中被长时间阻塞，影响调试响应。

### 2. PTRACE_ATTACH vs PTRACE_SEIZE 的设计演进

PTRACE_ATTACH 是原始设计：
- 在 attach 时发送 SIGSTOP → 强制 tracee 进入 TASK_TRACED
- SIGSTOP 是不可忽略的 → 强制停止
- 但破坏了原有信号交付状态

PTRACE_SEIZE 是后来（Linux 3.4）的改进：
- 不发送任何信号 → tracee 完全不知道被 attach
- `PT_INTERRUPT` 操作可以请求停止但不发送信号
- `PTRACE_LISTEN` 可以从 group-stop 恢复而不发送 SIGCONT
- 多个 tracer 可以同时 attach

### 3. ptrace 的权限模型

ptrace 的权限检查经历过多轮加固（特别是 CVE-2019-13272 等漏洞后）：

```c
// kernel/ptrace.c ptrace_attach()
security_ptrace_access_check();          // LSM 钩子
```

检查层次：
1. **CAP_SYS_PTRACE**：拥有该 capability 可以跟踪任何进程
2. **相同 uid**：同一个用户的进程（除非 tracee 是 `dumpable=0`）
3. **`/proc/sys/kernel/yama/ptrace_scope`**：Yama LSM 的额外控制：
   - 0：任意进程（默认，用于传统桌面）
   - 1：只能跟踪子进程（REC 模式，现代桌面默认）
   - 2：只有 CAP_SYS_PTRACE 可以（管理员模式）
   - 3：完全禁止（不可恢复，直到下次启动）

### 4. PTRACE_EVENT_EXIT 的时机

`PTRACE_EVENT_EXIT` 在 `do_exit()` 中 `exit_notify()` 之后发送：
- 此时大部分资源已经释放
- tracer 仍可以通过 `PTRACE_GETREGSET` 读取最后的寄存器状态
- tracer 无法阻止退出，只能观察

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `sys_ptrace()` | kernel/ptrace.c | 1388 |
| `ptrace_attach()` | kernel/ptrace.c | 409 |
| `ptrace_detach()` | kernel/ptrace.c | 564 |
| `ptrace_check_attach()` | kernel/ptrace.c | 239 |
| `ptrace_request()` | kernel/ptrace.c | 872 |
| `__ptrace_link()` | kernel/ptrace.c | 69 |
| `__ptrace_unlink()` | kernel/ptrace.c | 117 |
| `ptrace_stop()` | kernel/signal.c | 2351 |
| `ptrace_notify()` | kernel/signal.c | 2516 |
| `ptrace_event()` | kernel/signal.c | 2513 |
| `arch_ptrace()` | arch/x86/kernel/ptrace.c | 730 |
| `DO_SYSCALL_64` | arch/x86/entry/common.c | (系统调用入口) |
| `ptrace_access_vm()` | kernel/ptrace.c | 44 |
| `struct task_struct` | include/linux/sched.h | 820 |
| ptrace 状态位 | include/linux/ptrace.h | (PT_PTRACED 等) |
| PTRACE_EVENT_* | include/uapi/linux/ptrace.h | (全部事件定义) |
| `access_process_vm()` | mm/memory.c | 7153 |

## 调试工具对 ptrace 的使用模式

| 工具 | 使用模式 | 内核交互 |
|------|---------|---------|
| gdb | `PTRACE_TRACEME` + `PTRACE_CONT`/`PTRACE_SINGLESTEP` + 硬件断点 | 最标准的使用者 |
| strace | `PTRACE_SYSCALL` + `PTRACE_GETREGSET` 读取调用参数 | 系统调用追踪 |
| rr | `PTRACE_SEIZE` + `PT_READSIGINFO` + FTRACE 记录 | 确定性重放调试 |
| perf | `PTRACE_EVENT_FORK` + `PERF_EVENT_IOC_SET_FILTER` | 性能调优 |
| gdb-server (gdbserver) | `PTRACE_ATTACH` + 通过 gdb RSP 协议代理 | 远程调试 |
