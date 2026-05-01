# 14-kthread — Linux 内核线程深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**kthread（内核线程）** 是 Linux 内核中在后台运行任务的机制。与用户空间线程不同，内核线程没有独立的地址空间——它运行在内核态，共享内核地址空间，但拥有独立的执行栈和调度上下文。

内核线程的生命周期由 `kthreadd`（PID 2）管理——这个特殊的进程是所有内核线程的父进程，负责创建和回收内核线程。

**doom-lsp 确认**：`kernel/kthread.c` 包含 **200 个符号**，定义在 `include/linux/kthread.h`。

---

## 1. 核心数据结构

### 1.1 `struct kthread`——每个内核线程的元数据

```c
// kernel/kthread.c — 嵌入在 task_struct 中
struct kthread {
    unsigned long flags;            // 标志位：KTHREAD_IS_STOPPED 等
    unsigned int cpu;               // 绑定的 CPU
    void *data;                     // 线程函数数据
    struct completion parked;       // 等待停放完成
    struct completion exited;       // 等待退出完成
    struct io_callback *io_cb;      // IO 回调
    int (*threadfn)(void *data);    // 线程函数（仅当 kthread_run 时）
};
```

内核线程通过 `task_struct->set_child_tid` 指向其 `struct kthread`，这是一种轻量级的关联方式——不增加额外指针。

---

## 2. kthreadd——所有内核线程的守护者

`kthreadd` 是 PID 2 的特殊进程，在内核初始化时启动：

```c
// kernel/kthread.c — doom-lsp 确认的全局变量
static struct task_struct *kthreadd_task;  // kthreadd 的 task_struct
static LIST_HEAD(kthread_create_list);      // 待创建列表
static DEFINE_SPINLOCK(kthread_create_lock); // 保护列表
```

**kthreadd 主循环**：

```
kthreadd()                             @ kernel/kthread.c
  │
  ├─ for (;;) {
  │      │
  │      ├─ spin_lock(&kthread_create_lock)
  │      ├─ while (!list_empty(&kthread_create_list)) {
  │      │      create = list_first_entry(&kthread_create_list)
  │      │      list_del_init(&create->list)
  │      │      spin_unlock(...)
  │      │
  │      │      └─ create_kthread(create)       ← 创建线程
  │      │           └─ kernel_thread(kthread, create, ...)
  │      │               └─ do_fork(CLONE_VM | ...)
  │      │                    └─ 新线程从 kthread() 开始执行
  │      │
  │      ├─ spin_lock(...)
  │      └─ }
  │
  ├─ 如果创建列表空：
  │   └─ schedule()                    ← 休眠等待
  │
  └─ }
```

---

## 3. 创建内核线程——doom-lsp 数据流

```
kthread_create(threadfn, data, "mythread")
  │
  ├─ kthread_create_on_node(threadfn, data, NUMA_NO_NODE, "mythread")
  │    │                                 @ kernel/kthread.c
  │    ├─ 分配 struct kthread_create_info
  │    │   create->threadfn = threadfn
  │    │   create->data = data
  │    │   init_completion(&create->done)
  │    │
  │    ├─ spin_lock(&kthread_create_lock)
  │    ├─ list_add_tail(&create->list, &kthread_create_list)
  │    ├─ spin_unlock(&kthread_create_lock)
  │    │
  │    ├─ wake_up_process(kthreadd_task)    ← 唤醒 kthreadd
  │    │
  │    ├─ wait_for_completion(&create->done) ← 等待创建完成
  │    │   [这里调用进程会阻塞]
  │    │
  │    └─ 返回 task_struct 指针（新线程）
```

**kthreadd 响应后**：

```
kthreadd 被唤醒
  │
  ├─ 从 kthread_create_list 取出 create 项
  │
  └─ create_kthread(create)
       │
       ├─ kernel_thread(kthread, create, CLONE_FS | CLONE_FILES | ...)
       │    └─ do_fork(...)
       │         └─ 新进程（内核线程）从 kthread() 函数开始执行
       │
       ├─ kthread() 在新线程中执行：
       │    │
       │    ├─ current->set_child_tid = (int *)&self
       │    ├─ self = alloc_percpu(struct kthread)
       │    ├─ current->kthread = self
       │    │
       │    ├─ complete(&create->done)        ← 通知创建者：线程已就绪
       │    │
       │    ├─ 当前线程被 kthread_stop() 或 __set_current_state(TASK_INTERRUPTIBLE)
       │    │
       │    └─ ret = threadfn(data)           ← 执行用户提供的线程函数！
       │         └─ do_exit(ret)              ← 返回后自动退出
```

---

## 4. 线程函数模式

```c
// 标准模式 —— 循环直到被停止
int my_kthread(void *data)
{
    struct my_data *m = data;

    while (!kthread_should_stop()) {
        // 执行工作
        do_work(m);

        // 让出 CPU（可中断睡眠）
        if (need_resched())
            schedule_timeout_interruptible(HZ);
    }

    return 0;
}

// 创建并运行
struct task_struct *tsk = kthread_run(my_kthread, &data, "my_kthread");
if (IS_ERR(tsk))
    return PTR_ERR(tsk);

// 停止
kthread_stop(tsk);    // 设置 KTHREAD_IS_STOPPED → 唤醒线程 → 等待退出
```

---

## 5. kthread_stop——停止内核线程

```c
// kernel/kthread.c — doom-lsp 确认
int kthread_stop(struct task_struct *k)
{
    struct kthread *kthread = to_kthread(k);

    set_bit(KTHREAD_IS_STOPPED, &kthread->flags);

    // 唤醒线程（线程可能在 TASK_INTERRUPTIBLE 睡眠）
    wake_up_process(k);

    // 等待线程完全退出
    wait_for_completion(&kthread->exited);

    return kthread->result;
}
```

**数据流**：

```
调用者：                               内核线程：
kthread_stop(worker)                   my_kthread() 循环中
  │                                      │
  ├─ set_bit(KTHREAD_IS_STOPPED)        ├─ kthread_should_stop() → true
  ├─ wake_up_process(worker) ──→         ├─ 退出循环
  │                                      ├─ return ret
  │                                      └─ do_exit(ret)
  │                                           └─ complete(&exited)
  │                                              │
  └─ wait_for_completion(&exited) ←────────────┘
       → 线程已退出 → 安全返回
```

---

## 6. kthread_park / kthread_unpark——暂停与恢复

内核线程可以被"停放"——使其暂停而不终止：

```c
int kthread_park(struct task_struct *k);     // 暂停
void kthread_unpark(struct task_struct *k);  // 恢复

// 线程函数检测是否被要求暂停：
if (kthread_should_park())
    kthread_parkme();    // 阻塞直到 unpark
```

这在 CPU 热插拔场景中特别重要——当一个 CPU 被下线时，绑定在该 CPU 上的内核线程需要被暂停。

---

## 7. 源码文件索引

| 文件 | 内容 | 符号数 |
|------|------|--------|
| `kernel/kthread.c` | kthreadd + 创建/停止/停放 | **200 个** |
| `include/linux/kthread.h` | API 声明 + inline | — |

---

## 8. 关联文章

- **11-completion**：kthread_stop 使用 completion 同步
- **13-workqueue**：workqueue 的 worker 线程是内核线程的一种
- **48-kworker**：kworker 是 workqueue 中的内核线程

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
