# 14-kthread — 内核线程深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/kthread.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**kthread** 是 Linux 内核的轻量级线程机制，专门用于在后台执行长时间运行的任务。与用户态线程不同，kthread 运行在内核空间，可以访问内核数据结构和资源。

---

## 1. 核心数据结构

### 1.1 struct kthread — kthread 描述符

```c
// kernel/kthread.c — kthread
struct kthread {
    struct task_struct       *task;           // 真实的 task_struct
    void                     *data;           // 传递给线程函数的参数
    int (*threadfn)(void *data);             // 线程函数
    const char              *name;            // 线程名（/proc 显示）

    // 停止机制
    int                       should_stop;   // 停止标志（kthread_should_stop）
    struct completion         done;          // 创建完成通知

    // CPU 亲和性
    struct cpumask            *cpumask;      // CPU 掩码
};
```

### 1.2 kthread vs task_struct

```
task_struct：内核调度实体（进程/线程的调度单元）
kthread：更高级的封装，提供停止机制和创建辅助
         内部持有一个 task_struct
```

---

## 2. 创建线程

### 2.1 kthread_create — 创建线程（不启动）

```c
// kernel/kthread.c — kthread_create
struct task_struct *kthread_create(int (*threadfn)(void *data),
                                   void *data,
                                   const char *namefmt, ...)
{
    struct kthread *kthread;
    struct task_struct *task;

    // 1. 分配 kthread 结构
    kthread = kzalloc(sizeof(*kthread), GFP_KERNEL);
    if (!kthread)
        return ERR_PTR(-ENOMEM);

    // 2. 初始化 completion（用于同步创建完成）
    init_completion(&kthread->done);

    // 3. 创建内核线程
    //    kthread_worker_fn 是入口函数
    task = kthread_create_on_node(
        kthread_worker_fn,    // 入口函数
        kthread,              // 参数（kthread 作为参数传递）
        NUMA_NO_NODE,        // 节点
        namefmt, args...       // 名称
    );

    if (IS_ERR(task))
        return ERR_CAST(task);

    // 4. 设置线程函数和参数
    kthread->task = task;
    kthread->threadfn = threadfn;
    kthread->data = data;

    return task;
}
```

### 2.2 kthread_run — 创建并立即启动

```c
// kernel/kthread.c — kthread_run
#define kthread_run(threadfn, data, namefmt, ...) ({ \
    struct task_struct *__k; \
    __k = kthread_create(threadfn, data, namefmt, ##__VA_ARGS__); \
    if (!IS_ERR(__k)) \
        wake_up_process(__k);  /* 创建后立即启动 */ \
    __k; \
})
```

---

## 3. 线程入口（kthread_worker_fn）

### 3.1 kthread_worker_fn — 入口函数

```c
// kernel/kthread.c — kthread_worker_fn
static int kthread_worker_fn(void *data)
{
    struct kthread *self = data;

    // 1. 设置当前进程的 kthread 指针
    current->kthread = self;

    // 2. 设置进程名
    strlcpy(current->comm, self->name, sizeof(current->comm));

    // 3. 通知创建者线程已启动
    complete(&self->done);

    // 4. 执行实际的线程函数
    while (!kthread_should_stop()) {
        if (self->threadfn)
            self->threadfn(self->data);
    }

    return 0;
}
```

---

## 4. 停止机制

### 4.1 kthread_should_stop — 检查是否应停止

```c
// kernel/kthread.c — kthread_should_stop
bool kthread_should_stop(void)
{
    return test_bit(KTHREAD_SHOULD_STOP_BIT, &current->kthread_mask);
    // current->kthread 是 kthread_should_stop 检查的关键
}

// 使用模式：
int my_thread_fn(void *arg)
{
    while (!kthread_should_stop()) {
        do_work();
        schedule();
    }
    return 0;
}
```

### 4.2 kthread_stop — 停止线程

```c
// kernel/kthread.c — kthread_stop
void kthread_stop(struct task_struct *k)
{
    struct kthread *ktask = k->kthread;
    unsigned long flags;

    // 1. 设置停止标志
    set_bit(KTHREAD_SHOULD_STOP_BIT, &ktask->should_stop_mask);

    // 2. 唤醒线程（如果正在等待）
    wake_up_process(k);

    // 3. 等待线程退出（使用 completion）
    wait_for_completion(&ktask->done);

    // 4. 清理
    put_task_struct(k);
}
```

---

## 5. CPU 亲和性

```c
// 设置 CPU 亲和性
struct kthread *k = kthread_create(my_fn, NULL, "my-kthread");

// 绑定到特定 CPU
kthread_bind(k, cpu_id);
wake_up_process(k->task);

// 或者通过 cpumask
set_cpus_allowed_ptr(k->task, cpumask_of(cpu));

// 设置 CPU 掩码
k->cpumask = &my_cpumask;
```

---

## 6. 生命周期图

```
kthread_create()
      │
      │ (线程创建，不启动)
      ↓
    [kthread] ← task_struct 关联
      │
      │ wake_up_process()
      ↓
  kthread_worker_fn()
      │
      │ complete(&done) 通知创建者
      ↓
  用户注册的 threadfn()
      │
      │ (正常工作循环)
      ↓
  kthread_should_stop() == true?
      │
      ├─Yes→ 退出
      └─No→ 继续工作
      │
      ↓
    线程结束
```

---

## 7. kthread vs workqueue

| 特性 | kthread | workqueue |
|------|---------|---------|
| 控制粒度 | 细粒度（完全控制线程生命周期）| 粗粒度（提交 work，由 worker 执行）|
| 独立性 | 独立线程 | worker 线程池共享 |
| 资源 | 每个 kthread 一个 task_struct | 一个池服务多个 work |
| 适用 | 长期运行任务 | 短期异步任务 |
| API 复杂度 | 高 | 低 |

---

## 8. 内核使用案例

### 8.1 kworker（工作队列的 worker）

```c
// kernel/workqueue.c
// 每个 CPU 有一组 kworker：
//   worker_pool[cpu][0] — normal workers
//   worker_pool[cpu][1] — high priority workers

// worker 线程是 kthread：
//   worker_thread() → process_one_work()
```

### 8.2 migration 线程

```c
// kernel/sched/core.c — migration_thread
// 每个 CPU 有一个 migration 线程
// 负责在 CPU 之间迁移进程（负载均衡）
// 由 kthread_run() 创建
```

---

## 9. 设计决策总结

| 设计决策 | 原因 |
|---------|------|
| completion 用于启动同步 | 确保线程创建完成后再使用 |
| kthread_should_stop() | 让线程自行决定何时退出 |
| should_stop 位图 | 比信号量更高效（原子操作）|
| kthread_bind | 允许限制 CPU 亲和性 |

---

## 10. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/kthread.c` | `struct kthread` |
| `kernel/kthread.c` | `kthread_create`、`kthread_run`、`kthread_should_stop`、`kthread_stop` |
| `kernel/kthread.c` | `kthread_worker_fn` |

---

## 11. 西游记类比

**kthread** 就像"取经队伍的专属徒弟"——

> 每个 kthread 就像一个专门指派的徒弟（task_struct），有自己独立的任务（threadfn）。创建时（kthread_create），徒弟先登记报到（在 kthread 结构里记录），然后发一个完成信号（completion）告诉师父"我准备好了"。师父可以决定让这个徒弟绑在哪个山头（kthread_bind CPU 亲和性），或者让它自由跑（unbound）。师父要收徒弟时（kthread_stop），就在徒弟的"任务本"上打个勾（should_stop），然后叫醒他（wake_up_process）。徒弟看到任务本上的勾（kthread_should_stop），就收拾行李退出。师父最后等他完全退出（wait_for_completion），收工。

---

## 12. 关联文章

- **completion**（article 11）：kthread_stop 使用 completion 同步
- **workqueue**（article 13）：workqueue 中的 worker 是 kthread
- **schedule**（调度部分）：kthread 调度相关