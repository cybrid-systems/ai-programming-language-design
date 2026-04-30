# workqueue — 内核工作队列深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/workqueue.h` + `kernel/workqueue.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**workqueue** 是内核**延迟执行**的核心机制，允许将工作（函数）排队，稍后由内核线程执行。

---

## 1. 核心数据结构

### 1.1 work_struct — 工作项

```c
// include/linux/workqueue.h — work_struct
struct work_struct {
    atomic_long_t           data;          // 编码：pool_id | flags | pending
    struct list_head        entry;         // 接入工作链表
    work_func_t            func;          // 回调函数
};
```

**data 字段编码**：
```
bit 0: WORK_STRUCT_PENDING      // 待执行
bit 1: WORK_STRUCT_INACTIVE    // 未激活
bit 2: WORK_STRUCT_PWQ         // 指向 pwq
bit 3: WORK_STRUCT_LINKED     // 链接到下一个 work
bits 4-7: COLOR              // flush 颜色
bits 8+: pool_id              // 所属 worker_pool ID
```

### 1.2 delayed_work — 延迟工作

```c
// include/linux/workqueue.h — delayed_work
struct delayed_work {
    struct work_struct work;        // 基础 work_struct
    struct timer_list timer;         // 定时器（触发延迟）
};
```

### 1.3 worker — 执行者线程

```c
// kernel/workqueue.c — worker
struct worker {
    struct pool_workqueue  *pool;     // 所属 pool
    struct list_head        entry;     // 接入 pool 的 idle/busy 链表
    struct list_head        scheduled;  // 已调度的 work 链表
    struct task_struct     *task;      // 实际的内核线程
    unsigned long          flags;       // WORKER_* 标志
    int                    id;          // worker ID
};
```

### 1.4 pool_workqueue — 每个 CPU 的工作池

```c
// kernel/workqueue.c — pool_workqueue
struct pool_workqueue {
    struct worker_pool      *pool;      // 底层 worker pool
    struct workqueue_struct *wq;       // 所属 workqueue
    struct list_head        delayed_works; // 延迟 work 链表
    int                    nr_active;   // 活跃 work 数
    int                    max_active;  // 最大活跃数
};
```

### 1.5 worker_pool — 每个 CPU 的工作线程池

```c
// kernel/workqueue.c — worker_pool
struct worker_pool {
    spinlock_t              lock;        // 保护 pool
    int                    cpu;          // 绑定 CPU（-1 = unbound）
    int                    id;           // pool ID
    struct list_head        worklist;    // 待处理 work 链表
    struct list_head        workers;     // worker 链表
    struct task_struct     *manager;     // 管理器（创建/销毁 worker）
    struct timer_list      idle_timer;   // 空闲超时定时器
    struct work_struct     *maybe_free_pool; // 释放 pool 的延迟 work
};
```

---

## 2. 核心 API

### 2.1 INIT_WORK — 初始化 work

```c
// include/linux/workqueue.h
#define INIT_WORK(_work, _func)                    \
    do {                                         \
        __INIT_WORK((_work), (_func), 0);         \
    } while (0)

#define __INIT_WORK(_work, _func, _onstack)       \
    do {                                         \
        (_work)->data = (atomic_long_t)WORK_DATA_INIT(); \
        INIT_LIST_HEAD(&(_work)->entry);          \
        (_work)->func = (_func);                 \
    } while (0)
```

### 2.2 schedule_work — 调度 work

```c
// kernel/workqueue.c — schedule_work
bool schedule_work(struct work_struct *work)
{
    return queue_work(system_wq, work);   // 排队到 system_wq
}

bool queue_work(struct workqueue_struct *wq, struct work_struct *work)
{
    // 1. 标记为待执行
    set_work_pool_and_clear_pending(work, wq->pool->id);

    // 2. 加入 pool 的 worklist
    spin_lock(&pool->lock);
    list_add_tail(&work->entry, &pool->worklist);

    // 3. 唤醒 idle worker
    if (pool->nr_workers == pool->nr_idle)
        wake_up_process(pool->manager->task);

    spin_unlock(&pool->lock);

    return true;
}
```

### 2.3 worker_thread — worker 循环

```c
// kernel/workqueue.c — worker_thread
static int worker_thread(void *arg)
{
    struct worker *worker = arg;

    while (!kthread_should_stop()) {
        // 1. 如果没有待处理 work，睡眠
        if (list_empty(&pool->worklist))
            schedule();

        // 2. 取出一个 work
        work = list_first_entry(&pool->worklist, struct work_struct, entry);
        list_del(&work->entry);

        // 3. 执行回调
        work->func(work);
    }
}
```

---

## 3. workqueue 类型

### 3.1 系统 workqueue

```c
// kernel/workqueue.c
struct workqueue_struct *system_wq     = 全局系统 workqueue
struct workqueue_struct *system_unbound_wq = 不绑定 CPU 的 workqueue
struct workqueue_struct *system_highpri_wq = 高优先级 workqueue
```

### 3.2 创建自定义 workqueue

```c
struct workqueue_struct *wq = alloc_workqueue("my_wq", WQ_FREEZABLE, 1);
// WQ_UNBOUND: 不绑定特定 CPU
// WQ_MEM_RECLAIM: 内存回收时仍处理
// WQ_HIGHPRI: 高优先级
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/workqueue.h` | `struct work_struct`、`INIT_WORK`、`schedule_work` |
| `kernel/workqueue.c` | `struct worker`、`struct worker_pool`、`worker_thread`、`queue_work` |
