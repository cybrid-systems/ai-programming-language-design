# Linux 进程生命周期深度分析：fork → exec → exit

## 概述

进程是 Linux 内核最基本的执行单元抽象。进程的生命周期由三个核心系统调用编织而成：`fork`（或 `clone`/`vfork`）创建进程，`execve` 加载新程序映像，`exit` 终结进程。

这三者在 Linux 7.0-rc1 中分布于三个核心源文件：
- `kernel/fork.c` — 进程创建（copy on write 机制、task_struct 分配、资源继承）
- `fs/exec.c` + `fs/binfmt_elf.c` — 程序加载（可执行格式解析、新旧地址空间替换）
- `kernel/exit.c` — 进程终结（资源回收、僵尸状态、父进程通知）

## 阶段一：进程创建（fork/clone）

### 系统调用入口

Linux 提供多个创建进程的系统调用，最终统一由 `kernel_clone()` 处理：

```
sys_fork()      — kernel/fork.c L2803 → kernel_clone(&args)
sys_vfork()     — kernel/fork.c L2819 → kernel_clone(&args)
sys_clone()     — kernel/fork.c L2799（需要解析寄存器参数）
sys_clone3()    — kernel/fork.c L2784 → kernel_clone(&args)
```

```c
// kernel/fork.c L2672
pid_t kernel_clone(struct kernel_clone_args *args)
```

`struct kernel_clone_args` 是一个统一参数结构，包含：
- `flags`：CLONE_VM / CLONE_THREAD / CLONE_SIGHAND / CLONE_FILES 等几十种标志
- `pidfd` / `child_tid` / `parent_tid`：pidfd 和 tid 地址参数
- `exit_signal`：子进程退出时发送给父进程的信号（通常为 SIGCHLD）
- `stack` / `stack_size`：子进程栈（用于线程创建）
- `tls`：线程本地存储地址
- `set_tid` / `set_tid_size`：指定 PID

`kernel_clone()` 的核心流程（L2672~2730）：

1. **参数验证**：检查 clone flags 合法性
2. **拷贝进程**：`copy_process()` 创建新的 task_struct
3. **唤醒新进程**：
   - `wake_up_new_task(p)` — 将新进程加入调度器就绪队列
   - 如果指定了 pidfd，通过 `pidfd_create()` 返回文件描述符
4. **返回 PID**：通过 `get_task_pid()` 获取并返回

### copy_process() — 进程拷贝的核心

（`kernel/fork.c` L1967~2160）

这是 fork 流程中最复杂的函数，超过 190 行。按顺序完成以下操作：

#### 1. 安全检查与标志处理（L1976~2018）
- 检查 `CLONE_THREAD` 在没有 `CLONE_SIGHAND` 时被拒绝
- 检查信号个数限制（`rlimit(RLIMIT_NPROC)`）
- 审计记录

#### 2. task_struct 分配（L2022~2039）
```c
p = dup_task_struct(current, node);  // L2022
```
`dup_task_struct()` 在内核栈顶部分配新的 `task_struct`，将当前进程的 task_struct 全部拷贝到新 task_struct。这意味着新进程开始时拥有与父进程完全相同的调度参数、信号状态、安全凭证等。然后重置子进程特有的字段：`on_cpu=0`、`p->state = TASK_NEW`、`p->pid` 由 caller 分配等。

#### 3. 资源拷贝（L2046~2160）— 按 flags 选择性共享或深拷贝

每个资源由独立的 `copy_*` 函数处理，clone flags 控制是共享还是深拷贝：

| 函数 | 行号 | 控制标志 | 共享时 | 深拷贝时 |
|------|------|---------|--------|---------|
| `copy_semundo()` | ~2046 | CLONE_SYSVSEM | 共享 sysv 信号量调整 | 不继承 |
| `copy_files()` | ~2052 | CLONE_FILES | 共享 fd 表（`atomic_inc`） | `dup_fd()` 深拷贝 |
| `copy_fs()` | ~2055 | CLONE_FS | 共享 umask/cwd/root | 拷贝引用 |
| `copy_sighand()` | ~2058 | CLONE_SIGHAND | 共享信号处理表 | 拷贝新表 |
| `copy_signal()` | ~2061 | CLONE_THREAD | 共享 signal_struct | 创建新 signal_struct |
| `copy_mm()` | ~2064 | CLONE_VM | 共享地址空间 | `dup_mm()` COW |
| `copy_namespaces()` | ~2066 | CLONE_NEW* | 共享命名空间 | 拷贝命名空间 |
| `copy_io()` | ~2070 | — | 共享 IO 统计 | 零初始化 |
| `copy_thread()` | ~2271 | 架构相关 | — | 设置子进程寄存器 |
| `copy_seccomp()` | ~2072 | — | 继承 seccomp 策略 |
| `copy_cgroup()` | ~2074 | — | 加入同 cgroup |
| `copy_user_events()` | ~2076 | — | 继承 event 订阅 |

#### 4. copy_thread() — 子进程寄存器上下文设置

（`arch/x86/kernel/process.c`，通过 `copy_thread()` 回调）

这是 fork 的架构相关部分，设置子进程的寄存器状态：

```c
int copy_thread(struct task_struct *p, const struct kernel_clone_args *args)
```

关键操作：
- 将父进程的 `pt_regs` 拷贝到子进程内核栈
- **设置返回地址为 `ret_from_fork()`**：子进程首次被调度时，从该函数开始执行
- 设置 `thread.sp`（内核栈指针）为子进程的内核栈顶减去 sizeof(struct pt_regs)
- 如果创建的是用户态线程（clone_flags & CLONE_SETTLS）：设置 FS/GS 基地址
- 如果创建的是内核线程（kernel_thread）：设置入口函数和参数

#### 5. 调度相关初始化（L2149）

```c
rcu_copy_process(p);   // L2149
```

在 copy_thread 之后，设置子进程的 RCU 状态（空回调列表）。

### 写时拷贝（COW）机制

虽然 fork 调用 `copy_mm()` → `dup_mm()` 拷贝了 `mm_struct`，但虚拟地址空间中的物理页面不是立即复制。`dup_mmap()` 遍历 vma 链表时：

```c
// kernel/fork.c 内部 dup_mmap() 逻辑
// 遍历父进程的 vma -> 创建子进程 vma
```

关键操作：
1. 子进程的 `mm->pgd` 使用 `pgd_alloc()` 分配新页全局目录
2. 但 vma 中的页面都标记为 **read-only**（清除 write 位，设置 COW 标志）
3. 父进程的页面也同步标记为 read-only（COW）
4. 谁先写，谁触发 **page fault handler**：
   - `handle_mm_fault()` → `do_wp_page()`（Write-Protect page fault）
   - 复制物理页面，更新两个进程各自的页表，标记为可写

这意味着 fork 之后，父子进程的物理页面是共享的，直到其中一方写入。fork 的代价 ≈ 拷贝 task_struct + mm_struct 等元数据结构 + 分配新的内核栈，而物理页面拷贝延迟到写入时。

## 阶段二：程序加载（execve）

### 系统调用入口

```
execve(filename, argv, envp)    — fs/exec.c L1924
execveat(fd, filename, argv, envp, flags) — fs/exec.c L1934
```

两个入口最终都调用 `bprm_execve()`（L1724）。

### linux_binprm — 加载程序的中间结构

（`include/linux/binfmts.h` L18）

```c
struct linux_binprm {
#ifdef CONFIG_MMU
    struct vm_area_struct *vma;     // L20 — 参数/环境变量映射区
    unsigned long vma_pages;        // L21
    unsigned long argmin;           // L22 — rlimit 标记
#endif
    struct mm_struct *mm;           // L27 — 临时 mm（用于 arg/env 拷贝）
    unsigned long p;                // L28 — 栈顶指针
    unsigned int have_execfd:1,     // L31 — 是否有可执行 fd
                 execfd_creds:1,    // L34 — 脚本的 creds
                 secureexec:1,     // L40 — 权限提升 exec (AT_SECURE)
                 point_of_no_return:1, // L45 — 不可回退标记
                 comm_from_dentry:1;   // L47 — 进程名来自 dentry
    struct file *file;              // 可执行文件
    struct cred *cred;              // 新凭证
    int unsafe;                     // 不安全 exec 标记
    unsigned int per_clear;         // 清除的 per-process 标志
    int argc, envc;                 // 参数/环境变量计数
    const char *filename;           // 文件路径
    const char *interp;             // 解释器（脚本的 #!）
    unsigned long loader, exec;     // 加载器地址
};
```

### exec 完整数据流

```
bprm_execve(filename, argv, envp)          — fs/exec.c L1724
  │
  ├─ 1. 文件准备
  │    alloc_bprm()                          // 分配 linux_binprm
  │    bprm_mmap_vma()                       // 分配临时 VMA
  │    bprm_fill_uid()                       // 检查 setuid/setgid
  │    copy_strings_kernel()                 // 拷贝 filename/argv/envp
  │
  ├─ 2. 加载可执行格式
  │    exec_binprm(bprm)                     — L1679
  │      └─ bprm->file->f_op->handler = load_elf_binary  // 通过二进制格式 handler
  │           └─ load_elf_binary(bprm)       — fs/binfmt_elf.c L832
  │
  ├─ 3. load_elf_binary() 内部
  │      ├─ 3a. 解析 ELF 头部
  │      │     elf_ex = *((struct elfhdr *)bprm->buf)     // 读取 ELF 魔数
  │      │     ei_class（32/64位）、ei_data（大小端）、e_type（ET_EXEC/ET_DYN）
  │      │
  │      ├─ 3b. 处理 #! 脚本
  │      │     load_script() → 递归 exec(/bin/sh, arg, script...)  // L792 附近
  │      │
  │      ├─ 3c. 处理解释器（动态链接器）
  │      │     对于 ET_DYN（PIE/共享库）：
  │      │       找到 .interp 段 → ld-linux 路径
  │      │       另一个 load_elf_binary(ld-linux) → interpreter
  │      │
  │      └─ 3d. 映射加载（ELF 映射）
  │            elf_map(bprm->file, load_bias + e_phdr[i].p_vaddr, &phdr[i])
  │            // 遍历 program headers，MAP_PRIVATE 映射 LOAD 段
  │            // 处理 PT_LOAD（可加载段）、PT_GNU_STACK（栈可执行性）、
  │            // PT_GNU_RELRO（只读重定位）等
  │
  ├─ 4. begin_new_exec()                      — fs/exec.c L1091
  │      ├─ 4a. 安装新 mm
  │      │     exec_mmap(mm)                  // 替换地址空间
  │      │       └─ mmput(oldmm) + mm_init(mm)
  │      │
  │      ├─ 4b. 清理旧资源
  │      │     set_task_vcexec(), flush_old_files()
  │      │     de_thread(tsk)                 // 如果是多线程，退出其他线程
  │      │
  │      ├─ 4c. 安装新凭证
  │      │     commit_creds(bprm->cred)
  │      │     // 检查 setuid/setgid/capabilities
  │      │
  │      ├─ 4d. 初始化新进程状态
  │      │     setup_new_exec(bprm)           — L1266 附近
  │      │     install_exec_creds(bprm)       // 安装 exec 凭证
  │      │     set_dumpable(current, ...)     // 设置 core dump 可用性
  │      │
  │      └─ 4e. 设置 auxv + 栈初始化
  │            create_elf_tables()            // 填充辅助向量 AT_*
  │            // AT_PHDR, AT_ENTRY, AT_BASE(ld), AT_UID, AT_SECURE, ...
  │
  └─ 5. 返回用户空间
       start_thread(regs, elf_entry, bprm->p)
       // 设置 RIP = elf_entry（程序入口），RSP = bprm->p（栈顶）
       // 然后从系统调用返回，用户空间从入口开始执行
```

### execve 的关键设计决策

**1. `point_of_no_return` 标志**（L45）

一旦 `begin_new_exec()` 开始替换地址空间，execve 错误返回变得不可能——旧地址空间已被销毁。此时 `bprm->point_of_no_return = 1`。如果后续步骤（如加载退出处理或设置凭证）失败，内核直接调用 `do_exit(SIGKILL)`。

**2. ELF 加载器架构**

`fs/binfmt_elf.c` 通过 `struct linux_binfmt` 注册：

```c
// fs/binfmt_elf.c L98
static struct linux_binfmt elf_format = {
    .module     = THIS_MODULE,
    .load_binary = load_elf_binary,
    .load_shlib = load_elf_library,
    .core_dump  = elf_core_dump,
    .min_coredump = ELF_EXEC_PAGESIZE,
};
```

内核通过 `exec_binprm()` 遍历已注册的 binfmt 列表，尝试每个 handler 的 `load_binary`。

**3. ET_DYN（PIE）vs ET_EXEC**

现代 Linux 下几乎所有的用户空间程序都是 PIE（ET_DYN），其加载地址需要通过 `load_bias` 计算，并需要加载动态链接器（ld-linux.so）。`load_elf_binary()` 会：
1. 计算 `load_bias` = ELF_ET_DYN_BASE + 随机偏移（ASLR）
2. 映射所有 PT_LOAD 段到 `load_bias + p_vaddr`
3. 从 `.interp` 段获取动态链接器路径，递归加载
4. 设置入口为动态链接器入口，程序入口存入 AT_ENTRY

## 阶段三：进程终结（exit）

### 系统调用入口

```
exit(code)       — kernel/exit.c L1082 → do_exit((error_code & 0xff) << 8)
exit_group(code) — kernel/exit.c L1126 → do_group_exit(error_code & 0xff)
```

### do_exit() — 进程终结的核心

（`kernel/exit.c` L895~1020）

```c
void __noreturn do_exit(long code)
```

分解为以下步骤：

#### 1. 退出前检查（L905~935）
- 如果正在退出（`PF_EXITING`），检查是否需要 kill 自己（`__this_cpu_read(admind_must_exit)`）
- 如果重复调用（already PF_EXITING），`relax()` 等待
- 设置 `PF_EXITING` 标志

#### 2. 退出通知（L940~950）
- `exit_signals()`：将线程 pending 信号合并到进程组
- `exit_itimers()`：释放 POSIX 定时器

#### 3. 资源清理（L950~985）
按顺序释放进程持有的资源：

```c
exit_mm();            // 释放地址空间（mmput）
exit_sem();           // 释放 IPC 信号量
__exit_files(tsk);    // 释放文件描述符表
__exit_fs(tsk);       // 释放文件系统上下文（cwd, root, umask）
exit_namespace(tsk);  // 释放命名空间引用
exit_task_work(tsk);  // 执行待处理 task_work
exit_taskstack(tsk);  // 释放内核栈 + thread_info
```

#### 4. 退出通知与状态存储（L988~1010）
- `exit_notify(tsk)`：关键函数，处理父子关系
   - 将子进程托管给 init、subreaper 或线程组内其他线程
   - 如果父进程设置了 `WAIT_CHLD`，发送 SIGCHLD
   - 如果子进程是线程组最后一个线程，更新进程组的退出状态
   - 决定是否进入**僵尸状态**：如果父进程已经 wait，直接释放；否则保留 task_struct

#### 5. 调度器接管（L1018）
```c
schedule();
// 永远不再执行到这里
BUG();
```

### exit_notify() — 僵尸状态与子进程托管

（`kernel/exit.c`）

关键逻辑：

1. **子进程托管**：将当前进程的子进程 re-parent 给另一个进程：
   - 如果有同线程组内的其他线程（CLONE_THREAD），托管给那个线程
   - 否则，找到最近的 subreaper（`child_subreaper`）或 init 进程
   - 通知新父进程（发送 SIGCHLD）

2. **僵尸状态判断**（`do_notify_parent()`）：
   - 如果父进程不想知道（SIGCHLD 被忽略），释放 task_struct
   - 如果父进程已 wait 完毕，释放
   - **否则保留 task_struct → 僵尸进程**（状态为 TASK_DEAD）

3. **僵尸进程的清理时机**：
   - `wait4()` 系统调用 → `wait_task_zombie()`（`kernel/exit.c`）释放僵尸
   - 僵尸进程持有：task_struct、内核栈、thread_struct、signal_struct
   - 已释放：mm_struct、files_struct、fs_struct、namespace 等主要资源

### do_group_exit() — 线程组退出

（`kernel/exit.c` L1092~1117）

```c
void do_group_exit(int exit_code)
```

1. 检查 `SIGNAL_GROUP_EXIT` 标志
2. 如果尚未设置，获取 `siglock`，设置标志和 `group_exit_code`
3. 调用 `do_exit(exit_code)`，由当前线程带头退出
4. 其他线程在 `get_signal()` 时发现 `SIGNAL_GROUP_EXIT`，会自动退出

## 进程状态的完整状态机

```
                    fork()
   [不存在] ──────────────────→ [TASK_NEW]
                                   │
                              wake_up_new_task()
                                   │
                                   ↓
                             [TASK_RUNNING] ←── schedule() 选择执行
                                   │
                      ┌────────────┼────────────┐
                      │            │            │
                 do_exit()   sleep(TASK_*)   信号打断
                      │            │            │
                      ↓            ↓            │
                 [TASK_DEAD]  [TASK_RUNNING]    │
                      │            │            │
                  exit_notify()    └────────────┘
                      │
        ┌─────────────┼──────────────┐
        │             │              │
   父进程 wait    父进程没 wait   子进程托管
        │             │              │
        ↓             ↓              ↓
   释放 task    [僵尸 TASK_DEAD]    init 回收
   (彻底终结)    ↑ 直到 wait()
```

## 进程生命周期中的关键共享模式

fork 的共享策略通过 clone flags 精确控制：

| 资源 | 独立（深拷贝） | 共享（引用计数） |
|------|--------------|----------------|
| 地址空间（mm_struct） | `!CLONE_VM` | `CLONE_VM`（线程） |
| 文件描述符（files_struct） | `!CLONE_FILES` | `CLONE_FILES` |
| 信号处理器（sighand_struct） | `!CLONE_SIGHAND` | `CLONE_SIGHAND` |
| 进程组信号（signal_struct） | `!CLONE_THREAD` | `CLONE_THREAD` |
| 文件系统上下文（fs_struct） | `!CLONE_FS` | `CLONE_FS` |
| PID 命名空间 | `!CLONE_NEWPID` | 共享 |
| 网络命名空间 | `!CLONE_NEWNET` | 共享 |
| 挂载命名空间 | `!CLONE_NEWNS` | 共享 |

## execve 中的地址空间替换机制

`execve()` 最核心的操作是 `exec_mmap()` 替换当前进程的地址空间：

1. **创建新 mm**：`mm_alloc()` 初始化一个空地址空间
2. **设置为 active**：`get_mm(mm)` 增加引用，设置 `current->mm` 为新的 mm
3. **释放旧 mm**：`mmput(old_mm)` 减少引用，如果引用归零则调用 `exit_mmap()`
4. **页表切换**：后续访问触发 page fault → 按需加载 ELF 段的物理页面

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `kernel_clone()` | kernel/fork.c | 2672 |
| `copy_process()` | kernel/fork.c | 1967 |
| `dup_task_struct()` | kernel/fork.c | 911 |
| `copy_thread()` | arch/x86/kernel/process.c | (通过函数指针) |
| `wake_up_new_task()` | kernel/sched/core.c | 4824 |
| `do_exit()` | kernel/exit.c | 895 |
| `do_group_exit()` | kernel/exit.c | 1092 |
| `exit_signals()` | kernel/exit.c | 3119 |
| `exit_notify()` | kernel/exit.c | 相关逻辑 |
| `sys_fork()` | kernel/fork.c | 2803 |
| `sys_clone3()` | kernel/fork.c | 2784 |
| `sys_execve()` | fs/exec.c | 1924 |
| `sys_execveat()` | fs/exec.c | 1934 |
| `bprm_execve()` | fs/exec.c | 1724 |
| `exec_binprm()` | fs/exec.c | 1679 |
| `load_elf_binary()` | fs/binfmt_elf.c | 832 |
| `begin_new_exec()` | fs/exec.c | 1091 |
| `struct linux_binprm` | include/linux/binfmts.h | 18 |
| `struct task_struct` | include/linux/sched.h | 820 |
| `struct kernel_clone_args` | include/linux/sched/task.h | 18 附近 |
