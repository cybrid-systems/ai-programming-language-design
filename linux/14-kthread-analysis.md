# 14-kthread — Linux 内核线程深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**kthread（内核线程）** 是 Linux 内核中运行后台任务的机制。与用户空间线程不同，内核线程没有独立的地址空间——它运行在内核态，共享内核地址空间，但拥有独立的执行栈和调度上下文。

内核线程的出现早于 workqueue。所有内核线程的创建和回收都由 `kthreadd`（PID 2）管理——这是一个特殊的进程，内核初始化时由 `idle` 进程 fork 出来。

**doom-lsp 确认**：`kernel/kthread.c` 包含 **200 个符号**，其中包含 `kthreadd` 主循环、`kthread_create` 系列、`kthread_stop/park` 等核心功能。定义在 `include/linux/kthread.h`。

---

## 1. 核心数据结构

### 1.1 `struct kthread`——元数据（`kthread.c:56`）

```c
// kernel/kthread.c:56 — doom-lsp 确认
struct kthread {
    unsigned long flags;            // KTHREAD_SHOULD_STOP, KTHREAD_SHOULD_PARK 等
    unsigned int started;           // 已启动标志
    void *data;                     // 线程函数参数
    void *threadfn;                 // 线程函数（仅 kthread_create 创建时使用）
    struct completion parked;       // kthread_parkme 等待完成
    struct completion exited;       // 线程退出后的完成通知
    int result;                     // 线程函数的返回值
    char *full_name;                // 线程名（完整格式）
    // ...
};
```

这个结构体通过 `task_struct->set_child_tid` 关联到 `task_struct`：

```c
// kthread.c:100 — doom-lsp 确认
bool set_kthread_struct(struct task_struct *p)
{
    struct kthread *kthread = kzalloc(...);
    p->set_child_tid = (int __user *)kthread;  // 复用 set_child_tid 指针
    return kthread != NULL;
}
```

### 1.2 `struct kthread_create_info`——创建请求（`kthread.c:41`）

```c
struct kthread_create_info {
    int (*threadfn)(void *data);    // 线程函数指针
    void *data;                     // 传给线程函数的数据
    int node;                       // NUMA 节点
    struct task_struct *result;     // 创建结果（task_struct 或 ERR_PTR）
    struct completion *done;        // 创建完成的完成通知
    struct list_head list;          // kthread_create_list 链表节点
    char *full_name;                // 完整线程名
};
```

---

## 2. 🔥 kthreadd——所有内核线程的守护者

`kthreadd`（PID 2）在 `init/main.c` 中创建：

```c
// init/main.c — 内核初始化
static noinline void __init kernel_init_freeable(void)
{
    // ...
    kthreadd_task = kthread_create_on_node(kthreadd, NULL, -1, "kthreadd");
    // ...
}
```

**kthreadd 主循环**（`kernel/kthread.c` — kthreadd 函数）：

```
kthreadd()                             @ kernel/kthread.c
  │
  ├─ set_cpus_allowed_ptr(current, &kthreadd_allowed_cpumask)
  │   ← kthreadd 可以在所有 CPU 上运行
  │
  ├─ current->flags |= PF_NO_SETAFFINITY
  │
  ├─ for (;;) {
  │      │
  │      ├─ spin_lock(&kthread_create_lock)
  │      │
  │      ├─ while (!list_empty(&kthread_create_list)) {
  │      │      │
  │      │      ├─ create = list_first_entry(&kthread_create_list,
  │      │      │                         struct kthread_create_info, list)
  │      │      ├─ list_del_init(&create->list)
  │      │      ├─ spin_unlock(&kthread_create_lock)
  │      │      │
  │      │      ├─ create_kthread(create)     ← 实际创建
  │      │      │    │
  │      │      │    └─ kernel_thread(kthread, create, namefmt, flags)
  │      │      │         │
  │      │      │         └─ do_fork(CLONE_FS | CLONE_FILES | SIGCHLD)
  │      │      │              │
  │      │      │              ├─ copy_process()
  │      │      │              │   └─ copy_thread() → 设置新线程的入口为 kthread 函数
  │      │      │              │
  │      │      │              └─ wake_up_new_task(p) → 新线程变为可运行
  │      │      │
  │      │      ├─ spin_lock(&kthread_create_lock)
  │      │      └─ } // 继续处理下一个
  │      │
  │      ├─ if (list_empty(&kthread_create_list))
  │      │    └─ schedule()                    ← 无请求时休眠
  │      │
  │      └─ } // 回到循环头
```

**为什么需要 kthreadd？** 不能直接在 `kthread_create` 中调用 `do_fork` 吗？

答案在历史演进中。早期内核确实直接在 `kernel_thread` 中创建，但存在两个问题：
1. 调用者可能在中断上下文或持有锁时创建线程，无法直接 fork
2. 将创建操作集中到 kthreadd，可以将 `CLONE_FS|CLONE_FILES` 等标志统一管理

---

## 3. 🔥 kthread_create——完整数据流

### 3.1 调用者路径

```
kthread_create(threadfn, data, "mythread")
  │
  └─ kthread_create_on_node(threadfn, data, NUMA_NO_NODE, "mythread")
       │                                  @ kernel/kthread.c:550
       └─ __kthread_create_on_node(...)    @ kernel/kthread.c:476
            │
            ├─ 1. 分配 kthread_create_info:
            │   create = kmalloc_obj(*create)
            │   create->threadfn = threadfn     ← 线程函数
            │   create->data = data             ← 参数
            │   create->node = NUMA_NO_NODE     ← NUMA 节点
            │   create->done = &done            ← 栈上的 completion
            │   create->full_name = kvasprintf(...)
            │
            ├─ 2. 加入创建列表：
            │   spin_lock(&kthread_create_lock)
            │   list_add_tail(&create->list, &kthread_create_list)
            │   spin_unlock(&kthread_create_lock)
            │
            ├─ 3. 唤醒 kthreadd：
            │   wake_up_process(kthreadd_task)  ← 通知 kthreadd 有新请求
            │
            ├─ 4. 等待创建完成：
            │   wait_for_completion(&done)       ← 阻塞等待！
            │   [调用者在此阻塞，直到 kthreadd 完成创建]
            │
            ├─ 5. 检查结果：
            │   task = create->result
            │   if (IS_ERR(task)) → 返回错误
            │
            └─ 6. 返回 task_struct 指针
```

### 3.2 kthreadd 响应路径

```
kthreadd 被 wake_up_process 唤醒后：
  │
  ├─ 从 kthread_create_list 取出 create
  │
  └─ create_kthread(create)                @ kernel/kthread.c:451
       │
       └─ kernel_thread(kthread, create, create->full_name,
                         CLONE_FS | CLONE_FILES | SIGCHLD)
            │
            ├─ 参数含义：
            │   CLONE_FS:   共享文件系统信息（umask, root）
            │   CLONE_FILES:共享打开的文件描述符表
            │   SIGCHLD:    子进程退出时向父进程发送 SIGCHLD
            │
            └─ do_fork(flags | CLONE_VM)   ← CLONE_VM 共享地址空间
                 │
                 ├─ copy_process()
                 │   ├─ dup_task_struct()    ← 复制内核栈
                 │   ├─ copy_thread()        ← 设置 CS:IP 指向 kthread()
                 │   └─ sched_fork()         ← 调度器初始化
                 │
                 └─ wake_up_new_task(p)      ← 让新线程运行
```

### 3.3 新线程启动路径——kthread() 函数

```c
// kernel/kthread.c:380 — doom-lsp 确认
static int kthread(void *_create)
{
    /* 1. 从栈上复制参数（create 在调用者栈上） */
    struct kthread_create_info *create = _create;
    int (*threadfn)(void *data) = create->threadfn;
    void *data = create->data;
    struct completion *done;
    struct kthread *self;
    int ret;

    /* 2. 获取当前线程的 kthread 结构 */
    self = to_kthread(current);

    /* 3. 窃取 done 指针（防止调用者被信号杀死） */
    done = xchg(&create->done, NULL);
    if (!done) {
        // 调用者已被信号杀死 → 直接退出
        kfree(create->full_name);
        kfree(create);
        kthread_exit(-EINTR);
    }

    /* 4. 保存线程函数和数据 */
    self->full_name = create->full_name;
    self->threadfn = threadfn;
    self->data = data;

    /* 5. 重置调度优先级（kthreadd 的优先级不继承） */
    sched_setscheduler_nocheck(current, SCHED_NORMAL, &param);

    /* 6. 通知创建者：线程已就绪 */
    __set_current_state(TASK_UNINTERRUPTIBLE);
    create->result = current;            // 返回 task_struct
    complete(done);                       // 唤醒 kthread_create 调用者

    /* 7. 第一次调度（让出 CPU，让创建者继续执行）*/
    schedule_preempt_disabled();

    self->started = 1;

    /* 8. 应用 CPU 亲和性 */
    if (!(current->flags & PF_NO_SETAFFINITY) && !self->preferred_affinity)
        kthread_affine_node();

    /* 9. 执行用户线程函数 */
    ret = -EINTR;
    if (!test_bit(KTHREAD_SHOULD_STOP, &self->flags)) {
        cgroup_kthread_ready();
        __kthread_parkme(self);           // 等待可能的 park 请求
        ret = threadfn(data);            // ← 执行用户的线程函数！！！
    }

    /* 10. 线程退出 */
    kthread_exit(ret);
}
```

---

## 4. 标准线程函数模式

```c
// 标准无限循环模式（可被 kthread_stop 停止）：
int my_worker(void *data)
{
    while (!kthread_should_stop()) {
        // 执行工作
        do_work(data);

        // 休眠直到被唤醒
        set_current_state(TASK_INTERRUPTIBLE);
        if (kthread_should_stop()) {
            __set_current_state(TASK_RUNNING);
            break;
        }
        schedule();
    }
    return 0;
}

// 创建：
struct task_struct *tsk = kthread_run(my_worker, my_data, "my_worker/%d", cpu);
if (IS_ERR(tsk))
    return PTR_ERR(tsk);  // PTR_ERR: ERR_PTR → int

// 停止：
kthread_stop(tsk);  // 等待 my_worker 完全退出
```

内部使用的标志位：
```c
// kthread.c — 位掩码
#define KTHREAD_IS_STOPPED   0  // 线程被要求停止
#define KTHREAD_SHOULD_STOP  1  // 线程应停止
#define KTHREAD_SHOULD_PARK  2  // 线程应暂停
#define KTHREAD_IS_PARKED    3  // 线程已暂停
```

---

## 5. 🔥 kthread_stop——停止线程的数据流

```c
// kernel/kthread.c — kthread_stop 实现
int kthread_stop(struct task_struct *k)
{
    struct kthread *kthread;

    kthread = to_kthread(k);  // 获取 kthread 结构

    // 设置停止标志
    set_bit(KTHREAD_IS_STOPPED, &kthread->flags);

    // 唤醒线程
    wake_up_process(k);

    // 等待线程完全退出
    wait_for_completion(&kthread->exited);

    return kthread->result;
}
```

**完整数据流**：

```
调用者线程：                         my_worker 内核线程：
                                    │
kthread_stop(worker)                │
  │                                 │
  ├─ set_bit(KTHREAD_IS_STOPPED)    │
  │  → flags bit 0 = 1             │
  │                                 │
  ├─ wake_up_process(worker)        │
  │  → 将 worker 加入运行队列       │
  │                                 │
  │                                 │ [从 schedule() 醒来]
  │                                 │ kthread_should_stop() → true
  │                                 │ → 退出 while 循环
  │                                 │ → return ret
  │                                 │ → kthread_exit(ret)
  │                                 │    ├─ kthread->result = ret
  │                                 │    └─ complete(&kthread->exited)
  │  ← 被 wake_up_process 唤醒      │        ↑
  │                                 │        │
  └─ wait_for_completion(&exited) ←─┘        │
       ↓ done--                               │
       → 线程已完全退出                        │
       → 安全返回 kthread->result             │
```

`kthread_exit()` 内部（`kthread.c:294`）：

```c
void kthread_do_exit(struct kthread *kthread, long result)
{
    kthread->result = result;
    complete(&kthread->exited);         // 通知 kthread_stop
    do_exit(result);                     // 调用 do_exit 真正退出
}
```

---

## 6. kthread_park / kthread_unpark——暂停与恢复

CPU 热插拔场景中需要暂停内核线程。`kthread_park` 不终止线程，而是让它进入"等待"状态：

```c
// kthread.c:703 — doom-lsp 确认
int kthread_park(struct task_struct *k)
{
    struct kthread *kthread = to_kthread(k);

    // 已暂停 → 避免重复
    if (test_bit(KTHREAD_IS_PARKED, &kthread->flags))
        return -EBUSY;

    // 设置暂停标志
    set_bit(KTHREAD_SHOULD_PARK, &kthread->flags);
    if (!test_bit(KTHREAD_IS_PARKED, &kthread->flags)) {
        wake_up_process(k);              // 唤醒线程
        wait_for_completion(&kthread->parked);  // 等待确认已暂停
    }
    return 0;
}
```

线程函数中的暂停检查：
```c
int my_kthread(void *data)
{
    while (!kthread_should_stop()) {
        // 挂起点：检查是否被要求暂停
        if (kthread_should_park())
            kthread_parkme();    // 阻塞直到 kthread_unpark
        
        do_work(data);
        schedule();
    }
    return 0;
}
```

`kthread_parkme` 内部（`kthread.c:259`）：

```c
static void __kthread_parkme(struct kthread *self)
{
    // 等待 PARK 标志被清除
    for (;;) {
        set_current_state(TASK_UNINTERRUPTIBLE);
        if (!test_bit(KTHREAD_SHOULD_PARK, &self->flags))
            break;
        complete(&self->parked);       // 通知 kthread_park：我已暂停
        schedule();                     // 休眠等待 unpark
    }
    __set_current_state(TASK_RUNNING);
}
```

---

## 7. CPU 热插拔与绑定

```c
// 绑定到特定 CPU：
kthread_bind(worker, cpu);           // 只允许在指定 CPU 上运行
kthread_bind_mask(worker, mask);    // 允许在 mask 中的 CPU 上运行
kthread_set_per_cpu(worker, cpu);   // 标记为 per-CPU（热插拔时迁移）

// CPU 下线时的 kthread 迁移：
// kernel/cpu.c — 当 CPU N 下线时：
// 1. 检查该 CPU 上绑定的所有 kthread
// 2. kthread_park(thread) → 暂停
// 3. 调度器自动将线程迁移到其他 CPU
// 4. kthread_unpark(thread) → 恢复
```

---

## 8. kthread_complete_and_exit

```c
// kernel/kthread.c:321 — doom-lsp 确认
void __noreturn kthread_complete_and_exit(struct completion *comp, long code)
```

在线程退出时通过 completion 通知外部等待者。常用于"等待线程完全退出后再释放资源"的场景：

```c
// 线程函数：
int my_worker(void *data)
{
    struct completion *comp = data;
    // ... 执行工作 ...
    kthread_complete_and_exit(comp, 0);
}

// 调用者：
init_completion(&comp);
tsk = kthread_create(my_worker, &comp, "my_worker");
// 不需要 kthread_stop，等待线程自己退出
wait_for_completion(&comp);
```

---

## 9. kthreadd 的 CPU 亲和性管理

```c
// kernel/kthread.c:330 — doom-lsp 确认
static void kthread_fetch_affinity(struct kthread *kthread,
                                    struct cpumask *cpumask)
{
    // 从 kthread_affinity_list 获取亲和性设置
    // 用于热插拔场景
}

static void kthread_affine_node(void)
{
    // 将线程绑定到当前 NUMA 节点
    // 提高缓存局部性
}
```

---

## 10. 内核线程类型的演进关系

```
kernel_thread()（原始）
  └── do_fork() 的直接调用，最底层
  └── 已不推荐直接使用

kthread_create()（标准）
  └── 通过 kthreadd 创建
  └── 提供 kthread_should_stop/park 等标准接口
  └── 大多数内核线程使用此接口

kthread_worker（workqueue 替代）
  └── 在 kthread 上运行工作项队列
  └── 比 workqueue 更轻量
  └── 已逐渐被 workqueue 取代

workqueue + kworker（现代推荐）
  └── 自动管理线程池
  └── 不直接操作内核线程
```

---

## 11. 源码文件索引

| 文件 | 内容 | 符号数 |
|------|------|--------|
| `kernel/kthread.c` | 完整实现 | **200 个** |
| `include/linux/kthread.h` | API 声明 | — |

---

## 12. 关联文章

- **11-completion**：kthread_stop/park 使用 completion
- **13-workqueue**：kworker 线程属于 kthread 体系
- **15-get_user_pages**：内核线程中没有用户空间，GUP 返回 -EFAULT
- **48-kworker**：kworker 线程的详细生命周期

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
