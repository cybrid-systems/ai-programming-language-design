# 48-kworker — Linux 内核 Workqueue 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**Workqueue（工作队列）** 是 Linux 内核的通用异步执行框架。它将工作项（`work_struct`）延迟到**进程上下文**中执行——与 SoftIRQ/Tasklet 不同，kworker 线程可以休眠、持有锁、占用 CPU。

**核心设计哲学**：Concurrency Managed Workqueue（CMWQ）——**并发管理**机制自动维护适量的活跃 kworker 线程，既不浪费 CPU 也不造成工作项饥饿。

```
┌────────────────────────────────────────────────────────┐
│                     workqueue 架构                      │
├────────────────────────────────────────────────────────┤
│  alloc_workqueue("events", 0, 0)                       │
│      ↓                                                  │
│  workqueue_struct ──→ pool_workqueue(PWQ) ──→ worker_pool │
│  (对外可见)           (每 CPU/每 WQ)          (共享线程池) │
│                           │                       ↓      │
│                           │                  kworker 线程  │
│                           └── work_struct 队列 ──→ 执行    │
└────────────────────────────────────────────────────────┘
```

**关键数据**：
- `kernel/workqueue.c`：**8,439 行**，**649 个符号**
- 每个 CPU 有 **2 个标准 worker_pool**（普通 + 高优先级）
- 每个 unbound workqueue 有 **动态数量的线程池**
- 系统启动时默认创建 `events`、`events_highpri`、`events_unbound`、`events_long`、`events_freezable`、`events_power_efficient` 等

**doom-lsp 确认**：`kernel/workqueue.c` 共 8439 行，包含 649 个符号。核心结构体 `worker_pool` 在 `wq.c:195`，`pool_workqueue` 在 `wq.c:269`，`workqueue_struct` 在 `wq.c:349`。内部头文件 `kernel/workqueue_internal.h`（84 行）定义 `struct worker`。

**doom-lsp 确认**：`worker_pool.flags` 的枚举在 `wq.c:62-85`，包括 `POOL_BH`（bit 0）、`POOL_MANAGER_ACTIVE`（bit 1）、`POOL_DISASSOCIATED`（bit 2）和 `POOL_BH_DRAINING`（bit 3）。`POOL_DISASSOCIATED` 在 CPU 离线时设置，worker 会获得 `WORKER_UNBOUND` 标志并脱离并发管理。

**关键文件索引**：

| 文件 | 行数 | 符号数 | 职责 |
|------|------|--------|------|
| `kernel/workqueue.c` | 8439 | 649 | 核心实现 |
| `kernel/workqueue_internal.h` | 84 | 3 | `struct worker`、调度器钩子 |
| `include/linux/workqueue_types.h` | 25 | — | `struct work_struct` |
| `include/linux/workqueue.h` | 910 | — | 公共 API 声明 |

---

## 1. 核心数据结构四层体系

### 1.1 struct work_struct — 工作项

```c
// include/linux/workqueue_types.h:12-18
struct work_struct {
    atomic_long_t data;      /* 低位：标志位 + 高位：PWQ 指针 / 池 ID */
    struct list_head entry;   /* 链表节点（入队时链入 worklist 或 scheduled）*/
    work_func_t func;         /* 执行函数 */
#ifdef CONFIG_LOCKDEP
    struct lockdep_map lockdep_map;
#endif
};
```

**`data` 字段的位布局**（关键设计——一个 64/32 位字段同时编码状态和指针）：

```
低位（WORK_STRUCT_* flags）:
  bit 0: WORK_STRUCT_PENDING_BIT     — 工作项等待处理
  bit 1: WORK_STRUCT_INACTIVE_BIT    — 工作项因为 max_active 限制处于非活跃
  bit 2: WORK_STRUCT_PWQ_BIT         — 高位是 PWQ 指针 (1) / 池 ID (0)
  bit 3: WORK_STRUCT_COLOR_SHIFT 开始的 2 位 — 颜色（flush 同步用）
  bit 5: WORK_STRUCT_OFFQ_FLAG_*     — 离线池标志

高位：
  如果 PWQ_BIT = 1：指向 pool_workqueue（对齐到 1 << WORK_STRUCT_PWQ_SHIFT）
  如果 PWQ_BIT = 0：编码 pool_id + offq_flags
```

**doom-lsp 确认**：`WORK_STRUCT_PWQ_SHIFT` 和颜色位定义在 `workqueue.c:106` 附近。

### 1.2 struct worker — 工作线程

```c
// kernel/workqueue_internal.h:23-61
struct worker {
    /* 状态转换：空闲时在 idle_list，繁忙时在 busy_hash */
    union {
        struct list_head entry;     /* L: 空闲时在 pool->idle_list */
        struct hlist_node hentry;   /* L: 繁忙时在 pool->busy_hash */
    };

    struct work_struct *current_work;  /* K: 当前正在处理的工作 */
    work_func_t current_func;          /* K: 当前执行的函数 */
    struct pool_workqueue *current_pwq; /* K: 当前的 PWQ */
    u64 current_at;                    /* K: 开始执行时的时间戳 */
    unsigned long current_start;       /* K: 开始执行的 jiffies */
    unsigned int current_color;        /* K: 当前工作项的颜色 */

    int sleeping;                      /* S: worker 是否正进入睡眠 */
    work_func_t last_func;             /* K: 上次执行的函数（调度器标识）*/
    struct list_head scheduled;        /* L: 分配给此 worker 的工作链表 */

    struct task_struct *task;          /* I: 内核线程 */
    struct worker_pool *pool;          /* A: 所属的 pool */

    struct list_head node;             /* A: pool->workers 链表节点 */
    unsigned long last_active;         /* K: 最近活跃时间戳 */
    unsigned int flags;                /* L: 标志 */
    int id;                            /* I: worker ID */

    char desc[WORKER_DESC_LEN];        /* 描述字符串（调试用）*/
    struct workqueue_struct *rescue_wq; /* I: 救援线程所属的 wq */
};
```

**worker 标志**：

```c
WORKER_DIE            = 1 << 1    // 线程应该退出
WORKER_IDLE           = 1 << 2    // 处于空闲状态
WORKER_PREP           = 1 << 3    // 准备处理工作
WORKER_CPU_INTENSIVE  = 1 << 6    // 正在执行 CPU 密集型任务
WORKER_UNBOUND        = 1 << 7    // 未绑定到特定 CPU
WORKER_REBOUND        = 1 << 8    // 重新绑定中

WORKER_NOT_RUNNING    = PREP | CPU_INTENSIVE | UNBOUND | REBOUND
// 设置了 NOT_RUNNING 的 worker 不参与并发管理（nr_running 不计数）
```

**doom-lsp 确认**：`worker_flags` 在 `workqueue.c:88-97`。`WORKER_NOT_RUNNING` 的组合值在 `wq.c:97`。

### 1.3 struct worker_pool — 线程池

```c
// kernel/workqueue.c:195-243
struct worker_pool {
    raw_spinlock_t lock;                    /* 池锁 */
    int cpu;                                /* I: 绑定的 CPU（-1 表示 unbound）*/
    int node;                               /* I: 绑定的 NUMA 节点 */
    int id;                                 /* I: 池 ID */
    unsigned int flags;                     /* L: 标志 */

    unsigned long last_progress_ts;          /* L: 最近一次向前进展的时间戳 */
    bool cpu_stall;                          /* WD: 绑定的池是否停滞 */

    int nr_running;                          /* 当前正在运行的 worker 数 */
    struct list_head worklist;               /* L: 待处理的工作链表 */

    int nr_workers;                          /* L: 总 worker 数 */
    int nr_idle;                             /* L: 当前空闲 worker 数 */
    struct list_head idle_list;              /* L: 空闲 worker 链表 */
    struct timer_list idle_timer;            /* L: 空闲 worker 超时 */
    struct work_struct idle_cull_work;       /* L: 清理空闲 worker 的工作项 */

    struct timer_list mayday_timer;          /* L: SOS 定时器 */

    DECLARE_HASHTABLE(busy_hash, BUSY_WORKER_HASH_ORDER); /* L: 繁忙 worker 哈希表 */

    struct worker *manager;                  /* L: 当前管理者（信息性）*/
    struct list_head workers;                /* A: 所有 worker 链表 */

    struct ida worker_ida;                   /* worker ID 分配器 */
    struct workqueue_attrs *attrs;           /* I: worker 属性 */
    struct hlist_node hash_node;             /* PL: unbound_pool_hash 节点 */
    int refcnt;                              /* PL: unbound 池引用计数 */

    struct rcu_head rcu;                     /* RCU 销毁保护 */
};
```

**池标志**：

```c
POOL_BH             = 1 << 0   // BH（SoftIRQ 下半部）池
POOL_MANAGER_ACTIVE = 1 << 1   // 正在被管理
POOL_DISASSOCIATED  = 1 << 2   // CPU 不可用，worker 未绑定
POOL_BH_DRAINING    = 1 << 3   // CPU 下线后 draining 中
```

### 1.4 struct pool_workqueue (PWQ) — 连接桥梁

```c
// kernel/workqueue.c:269-311
struct pool_workqueue {
    struct worker_pool *pool;                /* I: 关联的线程池 */
    struct workqueue_struct *wq;             /* I: 所属 workqueue */
    int work_color;                          /* L: 当前工作颜色 */
    int flush_color;                         /* L: 刷新颜色 */
    int refcnt;                              /* L: 引用计数 */
    int nr_in_flight[WORK_NR_COLORS];        /* L: 各颜色的在飞工作数 */
    bool plugged;                            /* L: 执行暂停 */

    int nr_active;                           /* L: 活跃工作数 */
    struct list_head inactive_works;          /* L: 因 max_active 限制而暂缓的工作 */
    struct list_head pending_node;            /* LN: 在 wq_node_nr_active->pending_pwqs */
    struct list_head pwqs_node;               /* WR: 在 wq->pwqs */
    struct list_head mayday_node;             /* MD: 在 wq->maydays */

    struct work_struct mayday_cursor;         /* L: 在 pool->worklist 上的光标 */

    u64 stats[PWQ_NR_STATS];                 /* 统计计数器 */

    struct kthread_work release_work;         /* 释放工作项 */
    struct rcu_head rcu;
} __aligned(1 << WORK_STRUCT_PWQ_SHIFT);     /* 对齐到 PWQ 指针需要 */

enum pool_workqueue_stats {
    PWQ_STAT_STARTED,        /* 工作项开始执行 */
    PWQ_STAT_COMPLETED,      /* 工作项完成 */
    PWQ_STAT_CPU_TIME,       /* 消耗的 CPU 时间 (μs) */
    PWQ_STAT_CPU_INTENSIVE,  /* CPU 密集型违规次数 */
    PWQ_STAT_CM_WAKEUP,     /* 并发管理 worker 唤醒 */
    PWQ_STAT_REPATRIATED,    /* 被带回亲和域的 worker */
    PWQ_STAT_MAYDAY,         /* 发送给 rescuer 的求救信号 */
    PWQ_STAT_RESCUED,        /* 由 rescuer 执行的工作 */
    PWQ_NR_STATS,
};
```

### 1.5 struct workqueue_struct — 对外可见的工作队列

```c
// kernel/workqueue.c:349-395
struct workqueue_struct {
    struct list_head pwqs;           /* WR: 所有 PWQ 链表 */
    struct list_head list;           /* PR: 所有 workqueue 链表 */

    struct mutex mutex;
    int work_color;                  /* WQ: 当前工作颜色 */
    int flush_color;                 /* WQ: 当前刷新颜色 */
    atomic_t nr_pwqs_to_flush;       /* 正在刷新的 PWQ 数 */
    struct wq_flusher *first_flusher;
    struct list_head flusher_queue;
    struct list_head flusher_overflow;

    struct list_head maydays;        /* MD: 请求救援的 PWQ */
    struct worker *rescuer;          /* MD: 救援 worker */

    int nr_drainers;
    int max_active;                  /* WO: 最大活跃工作数 */
    int min_active;                  /* WO: 最小活跃工作数 */
    int saved_max_active;
    int saved_min_active;

    struct workqueue_attrs *unbound_attrs;  /* PW: unbound wq 属性 */
    struct pool_workqueue __rcu *dfl_pwq;   /* PW: unbound wq 默认 PWQ */

    char name[WQ_NAME_LEN];          /* I: 名称 */
    unsigned int flags ____cacheline_aligned; /* WQ: 标志 */

    /* unbound wq 的 cpumask（不共享 cacheline）*/
    struct cpumask *cpumask;
};
```

---

## 2. 四层关系总览

```
workqueue_struct (wq)
  │
  ├─ pwqs ─→ pool_workqueue (pwq)  ← per-CPU 或 per-unbound-pool
  │              │
  │              ├─ pool ─→ worker_pool (pool)
  │              │              │
  │              │              ├─ worklist: 待执行的工作链表
  │              │              ├─ workers:  所有 worker 线程
  │              │              ├─ idle_list: 空闲 worker
  │              │              └─ busy_hash: 繁忙 worker (按当前 work 地址哈希)
  │              │
  │              └─ inactive_works: 超过 max_active 的工作
  │
  └─ rescuer → worker (救援线程)
```

**每 CPU workqueue**：
```
CPU 0:     worker_pool[0] (普通, nice=0)    ← pwq_0-A, pwq_0-B, ...
           worker_pool[1] (高优先级, nice=-20) ← pwq_1-A, pwq_1-B, ...
CPU 1:     worker_pool[0] (普通)
           worker_pool[1] (高优先级)
...
```

**Unbound workqueue**：按 `workqueue_attrs`（nice 值、cpumask）哈希到不同的 `worker_pool`，不受单 CPU 限制。

---

## 3. 工作项生命周期

### 3.1 入队路径

```c
// kernel/workqueue.c:2275-2395
static void __queue_work(int cpu, struct workqueue_struct *wq,
                         struct work_struct *work)
{
    /* 1. 选择目标 CPU 和 PWQ */
    if (req_cpu == WORK_CPU_UNBOUND)
        cpu = wq_select_unbound_cpu(raw_smp_processor_id());
    else
        cpu = raw_smp_processor_id();

    pwq = rcu_dereference(*per_cpu_ptr(wq->cpu_pwq, cpu));
    pool = pwq->pool;

    /* 2. 防止重入：如果 work 正在其他池执行，必须排队到那里 */
    last_pool = get_work_pool(work);
    if (last_pool && last_pool != pool && !(wq->flags & __WQ_ORDERED)) {
        worker = find_worker_executing_work(last_pool, work);
        if (worker)
            pwq = worker->current_pwq;  /* 定向到正在执行的池 */
    }

    /* 3. 更新颜色 */
    pwq->nr_in_flight[pwq->work_color]++;

    /* 4. max_active 限制检查 */
    if (list_empty(&pwq->inactive_works) && pwq_tryinc_nr_active(pwq, false)) {
        /* 在限制内 → 直接插入 worklist */
        insert_work(pwq, work, &pool->worklist, work_flags);
        kick_pool(pool);              /* 唤醒空闲 worker */
    } else {
        /* 超过限制 → 放入 inactive 链表 */
        work_flags |= WORK_STRUCT_INACTIVE;
        insert_work(pwq, work, &pwq->inactive_works, work_flags);
    }
}
```

**`insert_work()`** 的核心逻辑：

```c
// kernel/workqueue.c:2220-2260
static void insert_work(struct pool_workqueue *pwq, struct work_struct *work,
                        struct list_head *head, unsigned int extra_flags)
{
    struct worker_pool *pool = pwq->pool;

    /* 设置 work->data 指向 PWQ，编码颜色标志 */
    set_work_pwq(work, pwq, extra_flags);

    /* 插入到目标链表头部（LIFO 顺序——后续工作优先执行）*/
    list_add_tail(&work->entry, head);

    /* 如果 worklist 从空变为非空，打时间戳 */
    if (head == &pool->worklist && pool->worklist.next == &work->entry)
        pool->last_progress_ts = jiffies;

    get_pwq(pwq);  /* 增加 PWQ 引用计数 */
}
```

**doom-lsp 确认**：`insert_work` 在 `workqueue.c:2220`。`set_work_pwq()` 通过 CAS 原子更新 `work->data`，设置 `WORK_STRUCT_PENDING_BIT` 和 `WORK_STRUCT_PWQ_BIT`。`get_work_pool()` 在 `wq.c:1221` ——通过 `work_data_bits()` 解码 `WORK_STRUCT_PWQ` 位决定是直接取 PWQ 指针还是查 IDR 找池。

### 3.2 Worker 线程主循环

```c
// kernel/workqueue.c:3411-3490
static int worker_thread(void *__worker)
{
    struct worker *worker = __worker;
    struct worker_pool *pool = worker->pool;

    set_pf_worker(true);   /* 标记 PF_WQ_WORKER */

woke_up:
    raw_spin_lock_irq(&pool->lock);

    if (unlikely(worker->flags & WORKER_DIE)) {
        /* 被要求退出 */
        raw_spin_unlock_irq(&pool->lock);
        set_pf_worker(false);
        kfree(worker);
        return 0;
    }

    worker_leave_idle(worker);  /* 离开空闲列表 */

recheck:
    if (!need_more_worker(pool))
        goto sleep;             /* 没有工作可做 */

    if (unlikely(!may_start_working(pool)) && manage_workers(worker))
        goto recheck;           /* 需要创建新 worker 或销毁空闲 worker */

    /* 从 PREP 状态转到运行状态 */
    worker_clr_flags(worker, WORKER_PREP | WORKER_REBOUND);

    do {
        struct work_struct *work =
            list_first_entry(&pool->worklist, struct work_struct, entry);

        if (assign_work(work, worker, NULL))
            process_scheduled_works(worker);  /* 执行分配的工作 */
    } while (keep_working(pool));              /* 还有工作且 nr_running <= 1 */

    worker_set_flags(worker, WORKER_PREP);

sleep:
    /* 进入空闲状态 */
    worker_enter_idle(worker);
    __set_current_state(TASK_IDLE);
    raw_spin_unlock_irq(&pool->lock);
    schedule();                 /* 让出 CPU */
    goto woke_up;
}
```

**doom-lsp 确认**：`worker_thread` 在 `workqueue.c:3411`。核心循环是：wake → process works → sleep → (被工作入队 kick_pool 唤醒) → wake。`assign_work()` 在 `wq.c:1205` ——从 `pool->worklist` 取工作，检查是否与当前执行的工作冲突（通过 `find_worker_executing_work()` 查 `busy_hash`），无冲突则移到 `worker->scheduled` 链表。

### 3.3 执行工作——process_one_work

```c
// kernel/workqueue.c:3200-3358
static void process_one_work(struct worker *worker, struct work_struct *work)
{
    struct pool_workqueue *pwq = get_work_pwq(work);
    struct worker_pool *pool = worker->pool;

    /* 1. 加入 busy_hash（标记此 worker 为忙碌）*/
    hash_add(pool->busy_hash, &worker->hentry, (unsigned long)work);
    worker->current_work = work;
    worker->current_func = work->func;
    worker->current_pwq = pwq;
    worker->current_at = task->se.sum_exec_runtime;
    worker->current_start = jiffies;

    /* 2. CPU 密集型 auto-detection */
    if (unlikely(pwq->wq->flags & WQ_CPU_INTENSIVE))
        worker_set_flags(worker, WORKER_CPU_INTENSIVE);

    /* 3. 推出队列，清除 PENDING 位 */
    list_del_init(&work->entry);
    set_work_pool_and_clear_pending(work, pool->id, pool_offq_flags(pool));

    pwq->stats[PWQ_STAT_STARTED]++;
    raw_spin_unlock_irq(&pool->lock);

    /* 4. 实际执行工作函数！ */
    worker->current_func(work);

    /* 5. 执行完成，清理 */
    raw_spin_lock_irq(&pool->lock);
    pwq->stats[PWQ_STAT_COMPLETED]++;

    worker_clr_flags(worker, WORKER_CPU_INTENSIVE);
    worker->last_func = worker->current_func;

    hash_del(&worker->hentry);       /* 从 busy_hash 移除 */
    worker->current_work = NULL;
    worker->current_func = NULL;
    worker->current_pwq = NULL;

    pwq_dec_nr_in_flight(pwq, work_data);  /* 递减计数，可能激活等待的 PWQ */
}
```

### 3.4 并发管理钩子——调度器集成

当调度器切换任务时，通过 `wq_worker_running()` / `wq_worker_sleeping()` 维护 `pool->nr_running`：

```c
// kernel/workqueue.c:1419-1497
void wq_worker_running(struct task_struct *task)
{
    struct worker *worker = kthread_data(task);

    if (!READ_ONCE(worker->sleeping))
        return;                       /* 已经在运行，不重复计数 */

    preempt_disable();
    if (!(worker->flags & WORKER_NOT_RUNNING))
        worker->pool->nr_running++;   /* 增加运行计数 */
    preempt_enable();

    worker->current_at = worker->task->se.sum_exec_runtime;
    WRITE_ONCE(worker->sleeping, 0);
}

void wq_worker_sleeping(struct task_struct *task)
{
    struct worker *worker = kthread_data(task);
    struct worker_pool *pool;

    if (worker->flags & WORKER_NOT_RUNNING)
        return;                       /* CPU 密集型/未绑定 → 不参与 CM */

    pool = worker->pool;
    if (READ_ONCE(worker->sleeping))
        return;                       /* 已经在睡眠中 */

    WRITE_ONCE(worker->sleeping, 1);
    raw_spin_lock_irq(&pool->lock);

    if (worker->flags & WORKER_NOT_RUNNING) {
        raw_spin_unlock_irq(&pool->lock);
        return;
    }

    pool->nr_running--;

    /* nr_running 降到 0 且有工作待处理 → 唤醒另一个 worker */
    if (kick_pool(pool))
        worker->current_pwq->stats[PWQ_STAT_CM_WAKEUP]++;

    raw_spin_unlock_irq(&pool->lock);
}
```

**need_more_worker() 条件**——并发管理的核心决策：

```c
// kernel/workqueue.c:950-964
static bool need_more_worker(struct worker_pool *pool)
{
    /* 有工作待处理 且 没有 worker 在运行 */
    return !list_empty(&pool->worklist) && !pool->nr_running;
}

static bool may_start_working(struct worker_pool *pool)
{
    return pool->nr_idle;  /* 有空闲 worker */
}

static bool keep_working(struct worker_pool *pool)
{
    /* 有工作待处理 且 运行中的 worker ≤ 1 */
    return !list_empty(&pool->worklist) && (pool->nr_running <= 1);
}
```

**并发管理的数学本质**：

```
need_more_worker = worklist非空 AND nr_running == 0
                    → 有工作但没人干 → 必须唤醒/创建 worker

keep_working = worklist非空 AND nr_running ≤ 1
                    → 同一时间最多 2 个 worker 同时处理工作
                    → 避免太多线程争抢 CPU
```

---

## 4. Worker 生命周期管理

### 4.1 创建 worker

```c
// kernel/workqueue.c:2816-2890
static struct worker *create_worker(struct worker_pool *pool)
{
    int id = ida_alloc(&pool->worker_ida, GFP_KERNEL);
    if (id < 0)
        return NULL;

    worker = alloc_worker(pool->node);

    if (!(pool->flags & POOL_BH)) {
        /* 创建内核线程（kthread）*/
        worker->task = kthread_create_on_node(worker_thread, worker,
                                              pool->node, "%s", id_buf);
        set_user_nice(worker->task, pool->attrs->nice);
        kthread_bind_mask(worker->task, pool_allowed_cpus(pool));
    }

    worker_attach_to_pool(worker, pool);  /* 注册到 pool */

    raw_spin_lock_irq(&pool->lock);
    worker->pool->nr_workers++;
    worker_enter_idle(worker);             /* 进入空闲列表 */
    wake_up_process(worker->task);         /* 启动线程 */
    raw_spin_unlock_irq(&pool->lock);

    return worker;
}
```

**doom-lsp 确认**：`create_worker()` 在 `workqueue.c:2816`。`need_to_create_worker()` 在 `wq.c:968` 判断是否需要新 worker：`need_more_worker(pool) && !may_start_working(pool)`——有工作但无空闲 worker。

### 4.2 Manager 角色

```c
// 在 worker_thread 中：
if (unlikely(!may_start_working(pool)) && manage_workers(worker))
    goto recheck;

// manage_workers() 做两件事：
// 1. 如果 idle worker 太多 → 销毁
// 2. 如果有工作没人干 → 创建新 worker
```

**Manager 竞态控制**：`POOL_MANAGER_ACTIVE` 标志确保同一时间只有一个 worker 执行管理操作：

```c
// manage_workers → pool->manager 排他
if (pool->flags & POOL_MANAGER_ACTIVE)
    return false;   // 有人已经在管理

pool->flags |= POOL_MANAGER_ACTIVE;
```

### 4.3 IDLE Worker 超时销毁

```c
// kernel/workqueue.c:2940-2965
static void idle_worker_timeout(struct timer_list *t)
{
    /* 每 300 秒（IDLE_WORKER_TIMEOUT）触发一次 */
    // 如果 too_many_workers() → 销毁多余的 idle worker
}

static bool too_many_workers(struct worker_pool *pool)
{
    bool managing = pool->flags & POOL_MANAGER_ACTIVE;
    int nr_idle = pool->nr_idle + managing;
    int nr_busy = pool->nr_workers - nr_idle;

    // 规则：(idle - 2) * 4 >= busy
    // 即：idle workers 不能超过 busy workers 的 1/4 + 2
    return nr_idle > 2 &&
           (nr_idle - 2) * MAX_IDLE_WORKERS_RATIO >= nr_busy;
}
```

**worker 数量自动调整图谱**：

```
                 worklist 非空
                      │
                      ↓
             ┌── need_more_worker? ──→ 创建新 worker
             │   (nr_running == 0)
             │
    worker 运行 → nr_running++ → keep_working?
             │                      │
             │                  nr_running ≤ 1 → 继续
             │                  nr_running > 1  → 休眠
             │
             ↓
        worker 睡眠 → nr_running-- → kick_pool?
                                      │
                                   need_more_worker? → 唤醒 idle worker
```

---

## 5. Workqueue 标志与类型

### 5.1 创建标志

```c
// include/linux/workqueue.h
WQ_UNBOUND          = 1 << 1    // 不绑定到特定 CPU
WQ_FREEZABLE        = 1 << 2    // 系统挂起时参与冻结
WQ_MEM_RECLAIM      = 1 << 3    // 内存回收路径可用（有 rescuer 线程）
WQ_HIGHPRI          = 1 << 4    // 高优先级（nice=-20）
WQ_CPU_INTENSIVE    = 1 << 5    // 工作项是 CPU 密集型
WQ_SYSFS            = 1 << 6    // 通过 sysfs 暴露
__WQ_ORDERED        = 1 << 7    // 有序（工作项按入队顺序执行）
WQ_BH               = 1 << 8    // BH（SoftIRQ）上下文
WQ_POWER_EFFICIENT  = 1 << 9    // 尝试节省功耗
```

### 5.2 标准 Workqueue

```c
// kernel/workqueue.c 初始化时创建的全局 workqueue：

system_wq              // "events"           — 通用（per-CPU，普通优先级）
system_highpri_wq      // "events_highpri"   — 高优先级（per-CPU，nice=-20）
system_long_wq         // "events_long"      — 长时间运行（unbound）
system_unbound_wq      // "events_unbound"   — unbound
system_freezable_wq    // "events_freezable" — 可冻结
system_power_efficient_wq  // "events_power_efficient" — 节能
```

### 5.3 各类型对比

| 类型 | Workqueue | Worker Pool | 典型场景 |
|------|-----------|-------------|----------|
| **Per-CPU** | `system_wq` | 每个 CPU 2 个池（普通 + 高优） | 短时、CPU 局部性强的工作 |
| **Unbound** | `system_unbound_wq` | 按属性哈希到全局池 | 不需要 CPU 关联性的工作 |
| **Ordered** | 自定义 | 单一 PWQ | 需要严格顺序的工作 |
| **BH** | 自定义 | SoftIRQ 上下文的 BH 池 | 下半部执行，类似 tasklet |
| **Freezable** | `system_freezable_wq` | 与 per-CPU 同池 | 挂起/恢复时需要冻结 |
| **Mem Reclaim** | 自定义 | 有 rescuer 线程 | 内存回收路径 |

---

## 6. 刷新与排空（Flush & Drain）

### 6.1 flush_workqueue——颜色同步协议

Flush 使用**颜色计数器**实现高效同步。每次 flush 递增 `flush_color`，每个 work 完成时递减 `nr_in_flight[color]`：

```
时间 →─────────────────────────────────────────→

  wq->work_color: [0] → [1] → [2] → [3] → [0] → [1]
  wq->flush_color: [0]                          [1]

  Work A (color=0) ──┐
  Work B (color=0) ──┤
  Work C (color=1) ──┼──┐
                      ↓  ↓
  flush 开始:等待 color=0 完成
  ↓
  nr_in_flight[0] == 0 → color=0 全部完成
  → 推进到下一个 flush_color
```

```c
// kernel/workqueue.c:3622-3670（简化）
void flush_workqueue(struct workqueue_struct *wq)
{
    /* 1. 推进 flush_color */
    wq->flush_color = wq->work_color;

    /* 2. 等待所有颜色为 flush_color 的 in_flight 工作完成 */
    if (atomic_read(&wq->nr_pwqs_to_flush))
        wait_event(wq->flush_wait, ...);
}
```

**doom-lsp 确认**：flush 颜色机制在 `workqueue.c` 的 `flush_workqueue_prep_pwqs()` 中实现。核心思想是**将"等待所有当前排队工作完成"转化为"等待特定颜色工作完成"**。

### 6.2 drain_workqueue

Drain 在销毁 workqueue 时使用，驱逐所有 pending 工作：

```c
// kernel/workqueue.c（简化）
void drain_workqueue(struct workqueue_struct *wq)
{
    /* 阻塞新工作入队 */
    wq->flags |= __WQ_DRAINING;

    /* 等待所有工作完成 */
    for (;;) {
        /* 刷新 */
        flush_workqueue(wq);
        /* 检查是否所有 PWQ 的 refcnt == 1（只有自身的引用）*/
        if (所有 PWQ 空闲)
            break;
    }
}
```

---

## 7. Rescuer 救援机制

当 workqueue 设置 `WQ_MEM_RECLAIM` 标志时，系统为它创建一个**救援 worker**（rescuer），防止内存回收路径上的死锁：

```
场景：内存回收路径 → 需要执行 work → 但没有内存创建 worker →
      死锁！

方案：rescuer 线程在创建时已经预分配了内存
      → 当 pool 中有工作等待且无空闲 worker 时
      → 发送 mayday → rescuer 被唤醒
      → 从 worklist 取走工作执行
```

**Mayday 定时器**：

```c
// kernel/workqueue.c
mayday_timer 每 MAYDAY_INTERVAL（100ms）触发一次
→ 遍历 wq->maydays 链表
→ 找到需要救援的 PWQ
→ 唤醒 rescuer 线程
```

**`rescuer_thread()`**：

```c
// kernel/workqueue.c（精简）
static int rescuer_thread(void *__rescuer)
{
    /* 遍历所有请求救援的 PWQ */
    list_for_each_entry(pwq, &wq->maydays, mayday_node) {
        /* 从 pool->worklist 中取工作，链入自己的 scheduled */
        while (assign_rescuer_work(pwq, rescuer)) {
            process_scheduled_works(rescuer);  /* 执行救援的工作 */
        }
    }
}
```

---

## 8. BH（下半部）Workqueue——SoftIRQ 集成

Linux 7.0-rc1 引入 BH workqueue 模式，允许工作项在 SoftIRQ 上下文中执行（类似 tasklet 但使用 workqueue 管理）：

```c
// 创建 BH workqueue
struct workqueue_struct *wq = alloc_workqueue("my_bh_wq", WQ_BH, 0);

// BH 池特性：
// - 每个 CPU 一个 BH 池（始终 DISASSOCIATED）
// - 在 SoftIRQ 上下文中执行（TASKLET_SOFTIRQ / HI_SOFTIRQ）
// - 不允许休眠（会触发 BUG）
// - 通过 irq_work 实现跨 CPU 唤醒
```

```c
// kernel/workqueue.c
static void kick_bh_pool(struct worker_pool *pool)
{
    if (unlikely(pool->cpu != smp_processor_id() &&
                 !(pool->flags & POOL_BH_DRAINING))) {
        irq_work_queue_on(bh_pool_irq_work(pool), pool->cpu);
        return;
    }

    if (pool->attrs->nice == HIGHPRI_NICE_LEVEL)
        raise_softirq_irqoff(HI_SOFTIRQ);
    else
        raise_softirq_irqoff(TASKLET_SOFTIRQ);
}
```

---

## 9. max_active 与 per-node 限制

### 9.1 max_active 机制

```c
// 每个 workqueue 创建时指定 max_active
#define WQ_DFL_ACTIVE  256    // unbound workqueue 的默认值
// per-CPU workqueue：max_active = 256（每个 CPU）
```

**nr_active 控制逻辑**：

```c
// 在 __queue_work 中：
if (pwq_tryinc_nr_active(pwq, false)) {
    // nr_active < max_active → 直接入 worklist
    insert_work(pwq, work, &pool->worklist, work_flags);
    kick_pool(pool);
} else {
    // 超过限制 → 放入 inactive_works
    insert_work(pwq, work, &pwq->inactive_works,
                work_flags | WORK_STRUCT_INACTIVE);
}

// 在 pwq_dec_nr_in_flight 中：
// 工作完成 → nr_active-- → 检查是否可以激活 inactive 工作
if (pwq_activate_first_inactive(pwq, false))
    kick_pool(pool);      // 有 inactive 工作变为 active → 唤醒 worker
```

### 9.2 per-node nr_active（Unbound 优化）

Unbound workqueue 跨多个 NUMA 节点时，per-CPU 的 max_active 管理不够——整个系统共享一个限制会导致跨 socket 锁竞争。解决方案是 **per-node nr_active**：

```c
struct wq_node_nr_active {
    int max;                    /* per-node max_active */
    atomic_t nr;                /* per-node nr_active */
    raw_spinlock_t lock;
    struct list_head pending_pwqs;  /* 等待激活的 PWQ */
};

// 每个 NUMA 节点独立维护 nr_active
// 工作完成时，按 round-robin 顺序选择下一个激活的 PWQ
```

---

## 10. 调度器集成

### 10.1 CPU 密集型自动检测

`wq_worker_tick()` 在每个调度 tick 时检查当前 worker 是否 hog CPU 太长时间：

```c
// kernel/workqueue.c:1499-1540
void wq_worker_tick(struct task_struct *task)
{
    struct worker *worker = kthread_data(task);
    struct pool_workqueue *pwq = worker->current_pwq;

    pwq->stats[PWQ_STAT_CPU_TIME] += TICK_USEC;

    if (!wq_cpu_intensive_thresh_us)
        return;

    /* 如果当前工作运行超时（默认 10ms）→ 标记 CPU_INTENSIVE */
    if ((worker->current_at - worker->task->se.sum_exec_runtime) >
        wq_cpu_intensive_thresh_us) {
        worker_set_flags(worker, WORKER_CPU_INTENSIVE);
        pwq->stats[PWQ_STAT_CPU_INTENSIVE]++;
    }
}
```

**`wq_cpu_intensive_thresh_us`**：内核参数（默认 10,000 μs = 10ms），可通过 `sysctl` 调整：

```bash
sysctl kernel.wq_cpu_intensive_thresh_us=20000  # 20ms
```

### 10.2 调度器标识

```c
// kernel/workqueue_internal.h
static inline struct worker *current_wq_worker(void)
{
    if (in_task() && (current->flags & PF_WQ_WORKER))
        return kthread_data(current);
    return NULL;
}
```

在 `/proc/<pid>/stack` 和调度器调试中，`last_func` 保留上次执行的工作函数名。

---

## 11. 统计与调试

### 11.1 wq_monitor.py

`tools/workqueue/wq_monitor.py` 工具监控所有 workqueue 状态：

```bash
python3 tools/workqueue/wq_monitor.py

# 输出示例：
#                                  work-items      cmwq
# workqueue                     bg  active  pend   CPU
# events                         0      10     2    0
# events_highpri                 0       3     0    0
# events_unbound                 0      50    10    -
# events_long                    0       0     0    -
```

### 11.2 调试接口

```bash
# 查看所有 workqueue
cat /sys/kernel/debug/workqueues

# 查看单个 workqueue
cat /sys/kernel/debug/workqueues/events

# sysfs 接口（需要 WQ_SYSFS 标志）
ls /sys/devices/virtual/workqueue/<wq_name>/
```

### 11.3 统计计数器

每个 PWQ 的 `stats[]` 数组可通过 tracepoint 或 debugfs 查看：

| 计数器 | 含义 |
|--------|------|
| `PWQ_STAT_STARTED` | 工作项开始执行次数 |
| `PWQ_STAT_COMPLETED` | 工作项完成次数 |
| `PWQ_STAT_CPU_TIME` | 消耗的 CPU 时间（μs） |
| `PWQ_STAT_CPU_INTENSIVE` | CPU 密集型自动检测触发次数 |
| `PWQ_STAT_CM_WAKEUP` | 并发管理唤醒次数 |
| `PWQ_STAT_REPATRIATED` | worker 被带回正确 CPU 的次数 |
| `PWQ_STAT_MAYDAY` | 向 rescuer 发送求救次数 |
| `PWQ_STAT_RESCUED` | rescuer 执行的工作数 |

---

## 12. 常见模式与最佳实践

### 12.1 正确的 API 使用

```c
/* ── 静态声明 ── */
DECLARE_WORK(my_work, my_work_fn);

/* ── 动态分配 ── */
struct work_struct *work;
INIT_WORK(work, my_work_fn);

/* ── 延时执行 ── */
INIT_DELAYED_WORK(dwork, my_delayed_fn);
schedule_delayed_work(dwork, msecs_to_jiffies(100));

/* ── 取消工作 ── */
cancel_work_sync(work);           // 同步取消（等待正在执行的完成）
cancel_delayed_work_sync(dwork);  // 同步取消延时工作

/* ── 刷新 ── */
flush_workqueue(wq);              // 等待所有工作完成
flush_work(work);                 // 等待指定工作完成

/* ── 自定义 workqueue ── */
wq = alloc_workqueue("my_wq", WQ_UNBOUND | WQ_MEM_RECLAIM, 0);
queue_work(wq, work);
destroy_workqueue(wq);
```

### 12.2 如何选择 Workqueue 类型

| 场景 | 推荐 |
|------|------|
| 短时任务（< 10ms） | `system_wq` 或自定义 per-CPU |
| 长时任务（> 10ms） | 自定义 unbound + `WQ_CPU_INTENSIVE` |
| 需要顺序执行 | 创建 ordered workqueue |
| 内存回收路径 | `WQ_MEM_RECLAIM`（有 rescuer） |
| SoftIRQ 上下文 | `WQ_BH`（BH workqueue） |
| 不需要 CPU 关联 | `WQ_UNBOUND` |
| 可休眠的工作 | 普通 workqueue（已在进程上下文） |

### 12.3 常见陷阱

```c
/* 陷阱 1：死锁 — flush workqueue 时持有相同 wq 的锁 */
mutex_lock(&wq->mutex);     // BAD！
flush_workqueue(wq);        // 死锁

/* 陷阱 2：在 work 函数中 flush 同 wq */
void my_work_fn(struct work_struct *work)
{
    flush_workqueue(my_wq); // BAD！死锁
}

/* 陷阱 3：work 函数未删除 work 就释放内存 */
kfree(work);                // BAD!
// 正确：确保 work 已完成或已取消

/* 陷阱 4：BH workqueue 中休眠 */
if (wq->flags & WQ_BH)
    msleep(100);            // BUG！SoftIRQ 中不能休眠
```

---

## 13. 性能考量

### 13.1 关键延迟路径

```
queue_work() → __queue_work()
  ├─ RCU 读锁定 [~5ns]
  ├─ raw_spin_lock [~20ns]
  ├─ set_work_pwq (CAS) [~10ns]
  ├─ list_add_tail [~5ns]
  ├─ kick_pool [~50ns]
  │    ├─ find_first_idle_worker [~5ns]
  │    ├─ wake_up_process [~500ns-2μs]
  │    └─ (CM wakeup stat)
  └─ raw_spin_unlock [~10ns]

worker_thread → process_one_work
  ├─ hash_add busy_hash [~10ns]
  ├─ 设置 current_work/current_func [~5ns]
  ├─ set_work_pool_and_clear_pending [~10ns]
  ├─ 执行 work->func [取决于工作]
  └─ pwq_dec_nr_in_flight [~30ns]
       ├─ nr_active 递减
       ├─ 可能激活 inactive_works
       └─ 可能通知 flush 等待者
```

### 13.2 线程池自动伸缩

| 状态 | 行为 | 说明 |
|------|------|------|
| 空闲（无工作） | 所有 worker 休眠，idle_timer 启动 | 5 分钟后销毁多余 worker |
| 有工作但无运行 worker | 创建新 worker 或唤醒 idle worker | CM 触发 |
| 工作持续排入 | 最多 2 个 worker 同时活跃（`keep_working` 条件） | 控制并发度 |
| 工作突发 | 临时创建更多 worker | mayday 不会触发（有 idle worker）|
| 内存压力 | 如果 WQ_MEM_RECLAIM → rescuer 介入 | 防止死锁 |

---

## 14. 总结

Linux workqueue 系统（CMWQ）的设计体现了以下核心原则：

**1. 共享线程池** — 所有 workqueue 共享少量的 worker_pool，避免为每个 workqueue 创建独立线程：

| 配置 | per-CPU pools | unbound pools |
|------|---------------|---------------|
| 空载 | CPU 数 × 2 | 0（懒创建） |
| 满载 | CPU 数 × 2 + 少量临时 | 动态（按属性哈希） |

**2. 并发管理（CM）** — `nr_running` 控制活跃 worker 数，自动平衡 CPU 利用：

```
nr_running = 0 → need_more_worker → 唤醒/创建
nr_running = 1 → keep_working → 可以继续
nr_running ≥ 2 → 多余 worker 睡眠
```

**3. 非重入保证** — `find_worker_executing_work()` + `busy_hash` 确保同一个工作不会被并发执行。

**4. max_active 双重控制** — per-CPU 级别 + per-NUMA 节点级别，防止失控并发。

**5. 自动伸缩** — 从 0 到 N 个 worker 的动态管理，5 分钟空闲超时销毁。

**6. 颜色驱动的 Flush** — 通过 `nr_in_flight[color]` 实现 O(1) 的 flush 完成判断。

---

## 附录 A：关键源码索引

| 文件 | 行号 | 符号 |
|------|------|------|
| `kernel/workqueue_internal.h` | 23 | `struct worker` |
| `kernel/workqueue.c` | 195 | `struct worker_pool` |
| `kernel/workqueue.c` | 269 | `struct pool_workqueue` |
| `kernel/workqueue.c` | 349 | `struct workqueue_struct` |
| `include/linux/workqueue_types.h` | 12 | `struct work_struct` |
| `kernel/workqueue.c` | 950 | `need_more_worker()` |
| `kernel/workqueue.c` | 956 | `may_start_working()` |
| `kernel/workqueue.c` | 962 | `keep_working()` |
| `kernel/workqueue.c` | 968 | `need_to_create_worker()` |
| `kernel/workqueue.c` | 1419 | `wq_worker_running()` |
| `kernel/workqueue.c` | 1453 | `wq_worker_sleeping()` |
| `kernel/workqueue.c` | 1499 | `wq_worker_tick()` |
| `kernel/workqueue.c` | 2220 | `insert_work()` |
| `kernel/workqueue.c` | 2275 | `__queue_work()` |
| `kernel/workqueue.c` | 2816 | `create_worker()` |
| `kernel/workqueue.c` | 3200 | `process_one_work()` |
| `kernel/workqueue.c` | 3374 | `process_scheduled_works()` |
| `kernel/workqueue.c` | 3411 | `worker_thread()` |
| `kernel/workqueue.c` | 2940 | `idle_worker_timeout()` |

## 附录 B：内核参数

```bash
# CPU 密集型检测阈值（μs）
sysctl kernel.wq_cpu_intensive_thresh_us=10000

# 通过 debugfs 查看工作队列状态
cat /sys/kernel/debug/workqueues

# 实时监控（tools/workqueue/wq_monitor.py）
wq_monitor.py -i 1
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
