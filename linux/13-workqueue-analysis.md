# 13-workqueue — 工作队列深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/workqueue.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**workqueue** 是内核的延迟工作执行机制：将回调函数排队，由工作线程异步执行。核心：`INIT_WORK` 注册 → `queue_work` 排队 → worker 线程执行。

---

## 1. 核心数据结构

### 1.1 struct work_struct — 工作项

```c
// include/linux/workqueue.h:78 — work_struct
struct work_struct {
    atomic_long_t           data;     // 编码：pending bit + 指针 + 工作函数
    struct list_head        entry;    // 接入工作队列的链表
    work_func_t            func;     // 工作函数回调
};

// data 字段编码：
//   bits[63:1] = worker_pool 指针 或 func 指针
//   bit[0] = WORK_STRUCT_PENDING（待执行）
//   bit[1] = WORK_STRUCT_LINKED（链接到其他 work）
//   bit[2] = WORK_STRUCT_PWQ（使用 per-cpu workqueue）

typedef void (*work_func_t)(struct work_struct *work);
```

### 1.2 struct worker — 工作线程

```c
// kernel/workqueue.c — worker
struct worker {
    // 链表
    struct list_head        entry;           // 接入 idle/active 链表
    struct list_head        scheduled;        // 待执行的 work 链表

    // 线程
    struct task_struct      *task;            // 内核线程
    struct worker_pool      *pool;           // 所属池
    struct workqueue_struct *wq;            // 所属工作队列

    // 状态
    unsigned long           flags;            // WORKER_* 标志
    //   WORKER_PREP      = 0x01  // 准备运行
    //   WORKER_RUNNING   = 0x02  // 正在运行
    //   WORKER_IDLE      = 0x04  // 空闲
    //   WORKER_PENDING   = 0x08  // 有工作待执行

    // 当前执行的 work
    struct work_struct      *current_pwq;     // 当前执行的工作
    int                     id;              // worker ID
};
```

### 1.3 struct worker_pool — 线程池

```c
// kernel/workqueue.c — worker_pool
struct worker_pool {
    struct list_head        worklist;       // 待执行的工作链表
    struct list_head        workers;         // worker 链表

    // CPU 绑定
    int                     cpu;             // -1 = unbound（非绑定）

    // 工作线程管理
    int                     nr_running;       // 运行中的 worker 数
    int                     nr_idle;          // 空闲的 worker 数

    // 管理
    spinlock_t              lock;             // 保护
    struct list_head        pending;          // 未处理的工作链表
};
```

### 1.4 struct workqueue_struct — 工作队列

```c
// kernel/workqueue.c — workqueue_struct
struct workqueue_struct {
    const char              *name;           // "events" "kblockd" 等

    // 类型
    bool                    unbound;          // true = unbound（可在任意 CPU）
    struct worker_pool      *pool;           // unbound 的共享池

    struct cpu_workqueue_struct *cpu_pwqs;   // per-CPU 的 pwq

    // 属性
    unsigned long           flags;            // WQ_* 标志
    //   WQ_UNBOUND      = 0x02  // unbound workqueue
    //   WQ_FREEZABLE   = 0x04  // 可冻结（suspend 时停止）
    //   WQ_MEM_RECLAIM = 0x08  // 内存回收期间保持运行
};
```

---

## 2. queue_work — 提交工作

### 2.1 queue_work

```c
// kernel/workqueue.c — queue_work
bool queue_work(struct workqueue_struct *wq, struct work_struct *work)
{
    struct worker_pool *pool;
    struct worker *worker;
    int ret = false;

    // 1. 检查是否已在队列中（防止重复提交）
    //    WORK_STRUCT_PENDING bit 检测
    if (!test_and_set_bit(WORK_STRUCT_PENDING_BIT, work_data_bits(work)))
        goto out;

    // 2. 选择 worker_pool
    pool = get_work_pool(work);

    spin_lock(&pool->lock);

    // 3. 加入 pending 链表
    list_add_tail(&work->entry, &pool->pending);

    // 4. 唤醒/创建 worker
    wake_up_worker(pool);

    spin_unlock(&pool->lock);

    ret = true;
out:
    return ret;
}
```

### 2.2 schedule_work — 全局排队

```c
// include/linux/workqueue.h — schedule_work
static inline bool schedule_work(struct work_struct *work)
{
    return queue_work(system_wq, work);  // 使用全局 system_wq
}

// system_wq 是全局工作队列，所有 CPU 共享
// 用于一般延迟工作
```

---

## 3. worker_thread — 工作线程主循环

```c
// kernel/workqueue.c — worker_thread
static int worker_thread(void *data)
{
    struct worker *worker = data;
    struct worker_pool *pool = worker->pool;

    for (;;) {
        // 1. 检查是否有工作
        if (!list_empty(&pool->worklist) || worker->current_pwq) {
            // 有工作，处理 pending 链表
            process_one_work(worker, worker->current_pwq);
            worker->current_pwq = NULL;
        }

        // 2. 等待新工作
        schedule();
        cond_resched();

        // 3. 检查是否应停止
        if (kthread_should_stop())
            break;
    }

    return 0;
}
```

### 3.1 process_one_work — 执行单个工作

```c
// kernel/workqueue.c — process_one_work
static void process_one_work(struct worker *worker, struct work_struct *work)
{
    // 1. 保存当前 work
    worker->current_pwq = work;

    // 2. 清除 pending bit
    clear_bit(WORK_STRUCT_PENDING_BIT, work_data_bits(work));

    // 3. 执行工作函数
    work->func(work);

    // 4. 清理
    worker->current_pwq = NULL;
}
```

---

## 4. 延迟工作（delayed_work）

### 4.1 struct delayed_work

```c
// include/linux/workqueue.h — delayed_work
struct delayed_work {
    struct work_struct       work;          // 基类（包含 work_struct）
    struct timer_list        timer;          // 定时器
};
```

### 4.2 queue_delayed_work — 延迟排队

```c
// kernel/workqueue.c — queue_delayed_work
bool queue_delayed_work(struct workqueue_struct *wq, struct delayed_work *dwork, unsigned long delay)
{
    // 1. 设置定时器
    timer->expires = jiffies + delay;
    timer->function = delayed_work_timer;

    // 2. 启动定时器
    add_timer(timer);
}

// delayed_work_timer：
//   timer_function → queue_work(system_wq, &dwork->work);
```

---

## 5. unbound workqueue — 非绑定工作队列

```c
// unbound vs bound：
//   bound:   worker 绑定到特定 CPU（cache 友好）
//   unbound: worker 可在任意 CPU 运行（负载均衡）

// system_unbound_wq — unbound 版本的 system_wq
// 用于阻塞时间较长的工作，避免绑定一个 CPU

// 创建 unbound workqueue：
struct workqueue_struct *wq = alloc_workqueue(name,
    WQ_UNBOUND | WQ_MEM_RECLAIM, 1);
```

---

## 6. 全局工作队列

```c
// kernel/workqueue.c — 全局工作队列
struct workqueue_struct *system_wq = ...;       // bound workqueue
struct workqueue_struct *system_unbound_wq;    // unbound workqueue
struct workqueue_struct *system_freezable_wq;  // 可冻结的 workqueue

// 常见全局队列：
//   system_wq：一般工作
//   kblockd_wq：块设备工作（磁盘 I/O）
//   events_freezable_wq：可冻结事件队列
```

---

## 7. 内存布局图

```
queue_work(system_wq, &my_work) 流程：

用户空间/内核代码
      │
      │ queue_work()
      ↓
system_wq.cpu_pwqs[cpu]  ← per-CPU 工作队列
      │
      │ wake_up_worker()
      ↓
worker_pool (cpu=N)  ← worker 线程池
      │
      │ schedule() → worker_thread()
      ↓
process_one_work()
      │
      │ work->func(work)
      ↓
my_work.func(my_work)  ← 用户注册的工作函数
```

---

## 8. 设计决策总结

| 设计决策 | 原因 |
|---------|------|
| work_struct data 编码 | 一个指针的空间存状态和指针 |
| unbound vs bound | unbound 避免阻塞特定 CPU |
| WORKER_PENDING 检测 | 防止同一 work 重复排队 |
| timer 延迟工作 | 不需要额外的定时器基础设施 |
| per-CPU workqueue | cache 友好（数据在同一 CPU）|

---

## 9. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/workqueue.h` | `struct work_struct`、`struct delayed_work`、`schedule_work` |
| `kernel/workqueue.c` | `queue_work`、`worker_thread`、`process_one_work` |
| `kernel/workqueue.c` | `struct worker`、`struct worker_pool`、`struct workqueue_struct` |

---

## 10. 西游记类比

**workqueue** 就像"取经队伍的待办清单"——

> 悟空（worker）有一份待办清单（worklist），上面写着要完成的任务（work_struct）。每个任务有具体的执行人（work_func_t）和任务描述（data）。唐僧（用户代码）只要把任务交给总调度员（queue_work），调度员就会把任务加到悟空的清单上（pending list），然后叫醒悟空（wake_up_worker）。悟空醒来看清单，挑一个任务做（process_one_work → work->func()），做完了继续看清单。清单空了，悟空就睡觉（schedule），等下次有任务再被叫醒。如果唐僧要延迟执行，就给任务贴个定时器标签（delayed_work），定时器响了再加到清单上。

---

## 11. 关联文章

- **kthread**（article 14）：worker 是 kthread 的一种用法
- **wait_queue**（article 07）：worker 线程内部使用 wait_queue 睡眠
- **kworker**（相关）：workqueue 的实际工作线程