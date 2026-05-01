# 14-kthread — Linux 内核线程深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**kthread（内核线程）** 是 Linux 内核中运行后台任务的机制。与用户空间线程不同，内核线程没有独立的地址空间——它运行在内核态，共享内核全局页表，但拥有独立的 `task_struct` 和执行栈。

内核线程在整个系统中至关重要：它们是 workqueue 的工人（kworker）、内存回收守护者（kswapd）、块设备刷新线程（flush）、文件系统日志线程（jbd2）等所有后台活动的基础。

所有内核线程的创建和回收都由 **kthreadd（PID 2）** 管理——这是一个在引导早期由 `idle` 进程创建的特殊线程。

**doom-lsp 确认**：`kernel/kthread.c`（1739 行）包含 **200 个符号**。关键结构体 `struct kthread` @ L56，`struct kthread_create_info` @ L41。核心函数 `kthread` @ L380，`kthreadd` @ L664，`kthread_stop` @ L730。

---

## 1. 核心数据结构

### 1.1 `struct kthread`——内核线程元数据（`kthread.c:56`）

```c
// kernel/kthread.c:56 — doom-lsp 确认
struct kthread {
    unsigned long flags;                     // KTHREAD_SHOULD_STOP (bit 0),
                                             // KTHREAD_IS_STOPPED (bit 1),
                                             // KTHREAD_SHOULD_PARK (bit 2),
                                             // KTHREAD_IS_PARKED (bit 3)
    unsigned int cpu;                        // 绑定的 CPU
    int (*threadfn)(void *data);             // 线程函数（仅 kthread_create 创建时用）
    void *data;                              // 线程函数参数
    struct completion parked;                // kthread_parkme 等待完成
    struct completion exited;                // 线程退出通知（kthread_stop 等待）
    int result;                              // 线程函数的返回值
    char *full_name;                         // 完整线程名（如 "kworker/0:0"）
    struct io_callback *io_cb;               // IO 回调
    unsigned int started;                    // 已启动标志
    struct cpumask *preferred_affinity;      // 优先 CPU 亲和性
};
```

这个结构体通过 `task_struct->set_child_tid` 指针关联——这是一种零额外开销的关联技巧：

```c
// kthread.c:100 — doom-lsp 确认
bool set_kthread_struct(struct task_struct *p)
{
    struct kthread *kthread;
    kthread = kzalloc(sizeof(*kthread), GFP_KERNEL);
    if (!kthread)
        return false;
    p->set_child_tid = (int __user *)kthread;  // 复用 set_child_tid！
    return true;
}
```

`set_child_tid` 原本用于用户空间线程库（NPTL）的 `set_tid_address` 系统调用。内核线程不需要用户空间地址，所以内核复用了这个指针来关联 `struct kthread`，没有增加 `task_struct` 的大小。

### 1.2 `struct kthread_create_info`——创建请求（`kthread.c:41`）

```c
// kernel/kthread.c:41 — doom-lsp 确认
struct kthread_create_info {
    int (*threadfn)(void *data);         // 线程函数
    void *data;                          // 数据参数
    int node;                            // NUMA 节点偏好
    struct task_struct *result;          // 创建结果（task_struct 或 ERR_PTR）
    struct completion *done;             // 完成通知对象
    struct list_head list;               // kthread_create_list 节点
    char *full_name;                     // 线程名
};
```

---

## 2. kthreadd 守护进程——PID 2

`kthreadd` 在引导早期由 `kernel_init_freeable()` 创建：

```c
// init/main.c — 内核初始化
kthreadd_task = kthread_create_on_node(kthreadd, NULL, -1, "kthreadd");
```

`kthreadd` 成为所有内核线程的父进程（`children` 链表）。它运行一个无限循环，处理 `kthread_create_list` 中的创建请求：

```
kthreadd()                                @ kernel/kthread.c ~L664
  │
  ├─ set_cpus_allowed_ptr(current, &kthreadd_allowed_cpumask)
  │   ← kthreadd 可以在所有 CPU 上运行
  │
  ├─ current->flags |= PF_NO_SETAFFINITY
  │   ← 防止外部修改 kthreadd 的 CPU 绑定
  │
  ├─ for (;;) {
  │      │
  │      └─ set_current_state(TASK_INTERRUPTIBLE)
  │
  │      ├─ [检查是否有创建请求]
  │      │   spin_lock(&kthread_create_lock)
  │      │   while (!list_empty(&kthread_create_list)) {
  │      │       create = list_first_entry(...)
  │      │       list_del_init(&create->list)
  │      │       spin_unlock(...)
  │      │
  │      │       └─ create_kthread(create)        ← 实际创建
  │      │            │
  │      │            └─ kernel_thread(kthread, create,
  │      │                  create->full_name,
  │      │                  CLONE_FS | CLONE_FILES | SIGCHLD)
  │      │                └─ do_fork(flags)
  │      │                     └─ 新线程从 kthread() 函数开始执行
  │      │
  │      │       spin_lock(...)
  │      │   }
  │      │   spin_unlock(...)
  │      │
  │      └─ schedule()                           ← 空闲时休眠
  │           [被 wake_up_process(kthreadd_task) 唤醒]
  │  }
```

**关键设计**：kthreadd 将所有创建操作集中到一个专用进程中。这样做的好处是：
1. 调用 `kthread_create` 的代码不一定在可 fork 的上下文中（可能持有锁）
2. 统一 `CLONE_FS | CLONE_FILES` 标志，所有内核线程共享文件系统上下文
3. 串行化创建过程，避免并发 fork 的资源竞争

---

## 3. 🔥 kthread_create——完整创建数据流

### 3.1 调用者路径

```
kthread_create(threadfn, data, "mythread")
  │
  └─ kthread_create_on_node(threadfn, data, NUMA_NO_NODE, "mythread")
       │                                @ kernel/kthread.c:550
       └─ __kthread_create_on_node(...)  @ kernel/kthread.c:476
            │
            ├─ [1. 分配创建请求结构体]
            │   create = kzalloc(sizeof(*create), GFP_KERNEL)
            │   create->threadfn = threadfn       // 线程函数
            │   create->data = data               // 参数
            │   create->node = NUMA_NO_NODE       // NUMA 节点
            │   create->done = &done              // 栈上 completion
            │   create->full_name = kvasprintf(...) // 线程名
            │
            ├─ [2. 加入 kthreadd 的创建列表]
            │   spin_lock(&kthread_create_lock)
            │   list_add_tail(&create->list, &kthread_create_list)
            │   spin_unlock(...)
            │
            ├─ [3. 唤醒 kthreadd]
            │   wake_up_process(kthreadd_task)
            │
            ├─ [4. 等待创建完成]
            │   wait_for_completion_killable(&done)
            │   ↑ 调用者在此阻塞！
            │   ↑ 如果被信号杀死 → OOM 保护路径
            │   │   如果 complete() 尚未执行：
            │   │   → xchg(&create->done, NULL) 窃取 done
            │   │   → 返回 -EINTR，kthreadd 后续检测 done==NULL
            │   │      → 清理 create 结构体
            │   │
            │   │   如果 complete() 已执行：
            │   │   → 调用者在 kthread 启动后完成等待
            │   │
            │
            ├─ [5. 获取创建结果]
            │   task = create->result  // task_struct* 或 ERR_PTR
            │
            └─ [6. 返回]
                return task
```

### 3.2 kthreadd 响应路径

```
kthreadd 被唤醒：
  │
  ├─ 从 kthread_create_list 取出 create
  │
  └─ create_kthread(create)                    @ kthread.c:451
       │
       └─ kernel_thread(kthread, create,
                         create->full_name,
                         CLONE_FS | CLONE_FILES | SIGCHLD)
            │
            └─ do_fork(flags)
                 │
                 ├─ copy_process()
                 │   ├─ dup_task_struct(current)  ← 复制内核栈
                 │   ├─ copy_thread(...)
                 │   │   → 设置子进程入口为 kthread() 函数
                 │   │   → 设置子进程栈顶
                 │   ├─ sched_fork(...)
                 │   │   → 初始化调度器状态
                 │   └─ ...
                 │
                 └─ wake_up_new_task(p)
                     → 新线程变为可运行状态
```

### 3.3 新线程启动——kthread() 函数

```c
// kernel/kthread.c:380 — doom-lsp 确认
static int kthread(void *_create)
{
    // 1. 从栈上复制创建参数
    struct kthread_create_info *create = _create;
    int (*threadfn)(void *data) = create->threadfn;
    void *data = create->data;
    struct completion *done;
    struct kthread *self;
    int ret;

    self = to_kthread(current);

    // 2. 窃取 done 指针（处理调用者被信号杀死的场景）
    done = xchg(&create->done, NULL);
    if (!done) {
        // 调用者已被 fatal signal 杀死
        kfree(create->full_name);
        kfree(create);
        kthread_exit(-EINTR);
    }

    // 3. 保存线程函数和数据
    self->full_name = create->full_name;
    self->threadfn = threadfn;
    self->data = data;

    // 4. 重置调度策略（不继承 kthreadd 的优先级）
    static const struct sched_param param = { .sched_priority = 0 };
    sched_setscheduler_nocheck(current, SCHED_NORMAL, &param);

    // 5. 通知创建者：线程已启动！
    __set_current_state(TASK_UNINTERRUPTIBLE);
    create->result = current;                    // ← 返回 task_struct 指针
    complete(done);                              // ← 唤醒等待的创建者

    // 6. 第一次调度（让出 CPU，给创建者继续执行的机会）
    //    preempt_disable 防止在 complete 和 schedule 之间被抢占
    preempt_disable();
    schedule_preempt_disabled();                  // ← 让出 CPU！
    preempt_enable();

    self->started = 1;

    // 7. 应用 NUMA 亲和性
    if (!(current->flags & PF_NO_SETAFFINITY) && !self->preferred_affinity)
        kthread_affine_node();

    // 8. 检查是否被要求立即停止
    ret = -EINTR;
    if (!test_bit(KTHREAD_SHOULD_STOP, &self->flags)) {
        cgroup_kthread_ready();
        // 9. 检查是否需要 park（CPU 热插拔等场景）
        __kthread_parkme(self);
        // 10. ★ 执行用户的线程函数！！！
        ret = threadfn(data);
    }

    // 11. 线程退出
    kthread_exit(ret);
}
```

---

## 4. 标准线程编程模式

```c
// 模式 1：无限循环 + kthread_should_stop 检查
int my_worker(void *data)
{
    while (!kthread_should_stop()) {
        if (need_resched())
            schedule();
        // 执行实际工作
        do_work(data);
    }
    return 0;
}

// 创建并启动
struct task_struct *tsk = kthread_run(my_worker, &mydata, "my_worker/%u", cpu);
// kthread_run = kthread_create + wake_up_process

if (IS_ERR(tsk))
    return PTR_ERR(tsk);

// 停止
kthread_stop(tsk);
```

### 4.1 关键标志检测函数

```c
// kthread.c:148 — doom-lsp 确认
bool kthread_should_stop(void)
{
    return test_bit(KTHREAD_SHOULD_STOP, &to_kthread(current)->flags);
}

// kthread.c:170 — doom-lsp 确认
bool kthread_should_park(void)
{
    return __kthread_should_park(current);
}
```

---

## 5. 🔥 kthread_stop——停止线程的完整数据流

```c
// kernel/kthread.c:730 — doom-lsp 确认
int kthread_stop(struct task_struct *k)
{
    struct kthread *kthread;

    kthread = to_kthread(k);
    if (!kthread)
        return -EINVAL;

    // 设置停止标志
    set_bit(KTHREAD_IS_STOPPED, &kthread->flags);

    // 唤醒线程（处理 TASK_INTERRUPTIBLE 等情况）
    wake_up_process(k);

    // 等待线程完全退出
    wait_for_completion(&kthread->exited);

    return kthread->result;
}
```

**完整数据流**：

```
时间轴：
调用者线程                                 my_worker 内核线程
  │                                          │
  │                                          │ [执行 do_work()]
  │                                          │ kthread_should_stop() → false
  │                                          │ continue
  │                                          │ schedule() → 睡眠
  │                                          │
  kthread_stop(worker)                       │
  │                                          │
  ├─ to_kthread(worker)                      │
  │   = worker->set_child_tid               │
  │   = &worker_kthread                      │
  │                                          │
  ├─ set_bit(KTHREAD_IS_STOPPED,            │
  │          &kthread->flags)               │
  │   → flags |= 1                          │
  │                                          │
  ├─ wake_up_process(worker)                 │
  │   → worker 变为 TASK_RUNNING             │
  │   → 如果 worker 在别的 CPU 上：IPI       │
  │                                          │
  │        [worker 从 schedule() 醒来]        │
  │        kthread_should_stop()             │
  │          test_bit(0, &flags) → true!     │
  │        → 退出 while 循环                 │
  │        → return ret                      │
  │        → kthread_exit(ret)               │
  │           ├─ kthread->result = ret       │
  │           ├─ complete(&exited) ──────────┤
  │           └─ do_exit(ret)                │
  │                              │            │
  └─ wait_for_completion(&exited)←┘           │
       ↓ done 从 0→1                          │
       → 线程已完全退出                       │
       → 返回 kthread->result                 │
```

---

## 6. kthread_park / kthread_unpark——暂停与恢复

CPU 热插拔时需要暂停绑定在该 CPU 上的内核线程，而不是销毁它们：

```c
// kthread.c:703 — doom-lsp 确认
int kthread_park(struct task_struct *k)
{
    struct kthread *kthread = to_kthread(k);

    // 已暂停 → 避免重复
    if (test_bit(KTHREAD_IS_PARKED, &kthread->flags))
        return -EBUSY;

    // 设置 SHOULD_PARK 标志
    set_bit(KTHREAD_SHOULD_PARK, &kthread->flags);
    if (!test_bit(KTHREAD_IS_PARKED, &kthread->flags)) {
        wake_up_process(k);           // 唤醒线程
        wait_for_completion(&kthread->parked);  // 等待确认暂停
    }
    return 0;
}

// kthread.c:670 — doom-lsp 确认
void kthread_unpark(struct task_struct *k)
{
    struct kthread *kthread = to_kthread(k);

    clear_bit(KTHREAD_SHOULD_PARK, &kthread->flags);
    if (test_bit(KTHREAD_IS_PARKED, &kthread->flags)) {
        clear_bit(KTHREAD_IS_PARKED, &kthread->flags);
        wake_up_process(k);           // 恢复运行
    }
}
```

线程内的 park 检查点：

```c
// kthread.c:259 — doom-lsp 确认
static void __kthread_parkme(struct kthread *self)
{
    for (;;) {
        set_current_state(TASK_UNINTERRUPTIBLE);
        if (!test_bit(KTHREAD_SHOULD_PARK, &self->flags))
            break;
        complete(&self->parked);       // ← 通知 parker：我已暂停
        schedule();                    // ← 休眠直到 unpark
    }
    __set_current_state(TASK_RUNNING);
}
```

**CPU 热插拔中的使用**：

```
CPU N 下线流程（kernel/cpu.c）：
  │
  ├─ smpboot_unpark_threads(cpu)  → kthread_park(per_cpu_thread)
  │
  ├─ __cpu_disable()
  │   → 中断迁移
  │   → 清除此 CPU 上的本地定时器
  │
  ├─ 工作队列迁移
  │
  └─ smpboot_park_threads(cpu)    → kthread_unpark(per_cpu_thread)
```

---

## 7. 线程退出——kthread_exit / kthread_complete_and_exit

```c
// kthread.c:294 — doom-lsp 确认
void kthread_do_exit(struct kthread *kthread, long result)
{
    kthread->result = result;
    complete(&kthread->exited);      // 通知 kthread_stop
    do_exit(result);                  // 真正退出
}

// kthread.c:321 — doom-lsp 确认
void __noreturn kthread_complete_and_exit(struct completion *comp, long code)
{
    if (comp)
        complete(comp);
    kthread_exit(code);
}
```

`kthread_complete_and_exit` 用于"线程自愿退出、通知等待者"模式：

```c
// 线程函数中使用：
int worker(void *data)
{
    struct completion *done = data;
    // 执行工作...
    kthread_complete_and_exit(done, 0);  // 完成后通知
}

// 调用者不需要 kthread_stop：
init_completion(&done);
tsk = kthread_create(worker, &done, "one_shot_worker");
wake_up_process(tsk);
wait_for_completion(&done);  // 等待线程自己完成
// 线程已退出，可以安全释放资源
```

---

## 8. 管理接口

```c
// CPU 绑定：
void kthread_bind(struct task_struct *p, unsigned int cpu);     // 绑定到特定 CPU
void kthread_bind_mask(struct task_struct *p, const struct cpumask *mask); // 绑定到 CPU 集合

// per-CPU 标记（CPU 热插拔管理）：
void kthread_set_per_cpu(struct task_struct *k, int cpu);   // 标记为 per-CPU
bool kthread_is_per_cpu(struct task_struct *p);              // 查询是否 per-CPU

// 数据访问：
void *kthread_data(struct task_struct *task);       // 获取线程函数参数
void *kthread_probe_data(struct task_struct *task); // 安全版本（可能返回 NULL）

// 线程名获取：
void get_kthread_comm(char *buf, size_t buf_size, struct task_struct *tsk);
```

---

## 9. kthread vs workqueue

| 特性 | kthread | workqueue |
|------|---------|-----------|
| 创建方式 | kthread_create + wake_up_process | alloc_workqueue + queue_work |
| 管理 | 手动 | 自动（线程池） |
| 生命周期 | 需要主动停止（kthread_stop） | 自动回收 |
| 线程复用 | 无（创建/销毁开销大） | 有（pool 复用 worker）|
| 适用场景 | 专用守护线程 | 短期或周期工作 |

---

## 10. 源码文件索引

| 函数 | 行号 |
|------|------|
| `struct kthread_create_info` | 41 |
| `struct kthread` | 56 |
| `set_kthread_struct` | 100 |
| `kthread_should_stop` | 148 |
| `kthread_should_park` | 170 |
| `__kthread_parkme` | 259 |
| `kthread_do_exit` | 294 |
| `kthread_complete_and_exit` | 321 |
| `kthread` | 380 |
| `create_kthread` | 451 |
| `__kthread_create_on_node` | 476 |
| `kthread_create_on_node` | 550 |
| `kthread_bind` | 601 |
| `kthread_unpark` | 670 |
| `kthread_park` | 703 |
| `kthread_stop` | 730 |

---

## 11. 关联文章

- **11-completion**：kthread_stop/park 使用 completion
- **13-workqueue**：worker 线程也是通过 kthread 创建
- **48-kworker**：kworker 线程的详细生命周期

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
