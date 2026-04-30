# kworker — 内核工作线程深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/workqueue.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**kworker** 是内核工作队列（workqueue）的线程池，处理 `struct work_struct` 回调。分为：
- **bound**：绑定到特定 CPU 的 kworker
- **unbound**：可在任何 CPU 运行的 kworker（一般使用这个）

---

## 1. 核心数据结构

### 1.1 worker — 工作线程

```c
// kernel/workqueue.c — worker
struct worker {
    // 基础
    struct worker           *next;         // 链表
    struct work_struct      *current_pwq;  // 当前执行的 work_struct

    // 线程
    struct task_struct      *task;         // 线程描述符
    struct workqueue_struct *wq;          // 所属工作队列
    struct pool             *pool;         // 所属内存池

    // 状态
    unsigned long           flags;         // WORKER_* 标志
    int                     id;            // 线程 ID

    // 管理
    struct list_head        entry;         // 接入 idle/active 链表
    struct list_head        scheduled;      // 等待执行的 work 链表
};
```

### 1.2 workqueue_struct — 工作队列

```c
// kernel/workqueue.c — workqueue_struct
struct workqueue_struct {
    const char              *name;         // "events" "kblockd" 等
    unsigned long           flags;         // WQ_* 标志

    // CPU 绑定
    struct workqueue_attrs  *attrs;        // 属性（是否 unbound）
    bool                    unbound;       // true = unbound workqueue

    // 内存池（per-CPU）
    struct pool             *pool;         // unbound 时使用共享池

    // Per-CPU 池（bound 时）
    struct cpu_workqueue_struct  *cpu_pwqs; // per-CPU 工作队列
};
```

### 1.3 work_struct — 工作项

```c
// include/linux/workqueue.h — work_struct
struct work_struct {
    atomic_long_t           data;          // 编码：指针 + pending 位
    struct list_head        entry;         // 接入链表
    work_func_t             func;          // 处理函数（回调）
};

typedef void (*work_func_t)(struct work_struct *work);
```

### 1.4 data 编码

```c
// include/linux/workqueue.h
// data 编码：
//   WORK_STRUCT_PENDING_BIT = 0 (1=待执行)
//   WORK_STRUCT_LINKED_BIT  = 1 (1=链接到其他 work)
//   WORK_STRUCT_COLOR_SHIFT = 2

#define work_data_bits(work) ((unsigned long *)(&(work)->data))

static inline void set_work_pwq(struct work_struct *work, void *pwq, unsigned long bits)
{
    work->data = (unsigned long)pwq | bits;
}

static inline void *get_work_pwq(struct work_struct *work)
{
    return (void *)(work->data & WORK_STRUCT_WQ_DATA_MASK);
}
```

---

## 2. worker_thread — 工作线程主循环

```c
// kernel/workqueue.c — worker_thread
static int worker_thread(void *data)
{
    struct worker *worker = data;
    struct work_struct *work;

    while (!kthread_should_stop()) {
        // 1. 等待 work
        schedule();
        cond_resched();

        // 2. 获取待执行的 work
        work = drain_workqueue(worker->pool);
        if (!work)
            continue;

        // 3. 执行 work->func
        worker->current_pwq = get_work_pwq(work);
        work->func(work);
        worker->current_pwq = NULL;
    }

    return 0;
}
```

---

## 3. queue_work — 提交 work

```c
// kernel/workqueue.c — queue_work
bool queue_work(struct workqueue_struct *wq, struct work_struct *work)
{
    struct worker_pool *pool = get_work_pool(work);
    struct worker *worker;
    bool ret;

    // 1. 检查是否已在队列中
    if (test_and_set_bit(WORK_STRUCT_PENDING_BIT, work_data_bits(work)))
        return false;

    // 2. 加入 pool 的 pending 链表
    spin_lock(&pool->lock);
    list_add_tail(&work->entry, &pool->pending);
    spin_unlock(&pool->lock);

    // 3. 唤醒 worker
    wake_up_worker(pool);

    return true;
}
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/workqueue.c` | `struct worker`、`worker_thread`、`queue_work` |
| `include/linux/workqueue.h` | `struct work_struct`、`work_func_t` |